//! Administrative commands, run on the server host:
//!
//!   audiojoe-server [--config FILE] user add NAME [--password-file FILE]
//!   audiojoe-server [--config FILE] user passwd NAME [--password-file FILE]
//!   audiojoe-server [--config FILE] user totp-reset NAME
//!   audiojoe-server [--config FILE] user delete NAME
//!   audiojoe-server [--config FILE] user list
//!
//! Without --password-file a random password is generated and printed once.
//! `add` and `totp-reset` print the TOTP secret and the otpauth:// URI for the
//! authenticator app.

use anyhow::{bail, Context, Result};
use rusqlite::OptionalExtension;

use crate::{auth, config::Config, db};

pub fn run(cfg: &Config, args: &[String]) -> Result<()> {
    let conn = db::open(&cfg.database)?;
    let conn = conn.lock().unwrap();
    let arg = |i: usize| args.get(i).map(String::as_str);
    let password_file = args
        .iter()
        .position(|a| a == "--password-file")
        .and_then(|i| args.get(i + 1));

    match (arg(0), arg(1), arg(2)) {
        (Some("user"), Some("list"), _) => {
            let mut stmt = conn.prepare(
                "SELECT u.name, u.created_at, COUNT(s.id) FROM user u LEFT JOIN session s ON s.user_id = u.id
                 GROUP BY u.id ORDER BY u.name",
            )?;
            let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)))?;
            for row in rows {
                let (name, created, sessions) = row?;
                println!("{name}\tcreated {created}\t{sessions} session(s)");
            }
        }
        (Some("user"), Some("add"), Some(name)) => {
            validate_name(name)?;
            let (password, generated) = password(password_file)?;
            let secret = auth::new_totp_secret();
            conn.execute(
                "INSERT INTO user (name, password_hash, totp_secret) VALUES (?1, ?2, ?3)",
                (name, auth::hash_password(&password)?, &secret),
            )
            .with_context(|| format!("cannot create user {name} (exists already?)"))?;
            println!("user {name} created");
            if generated {
                println!("password:    {password}");
            }
            print_totp(&secret, name)?;
        }
        (Some("user"), Some("passwd"), Some(name)) => {
            let (password, generated) = password(password_file)?;
            let n = conn.execute(
                "UPDATE user SET password_hash = ?1 WHERE name = ?2",
                (auth::hash_password(&password)?, name),
            )?;
            if n == 0 {
                bail!("no user {name}");
            }
            conn.execute("DELETE FROM session WHERE user_id = (SELECT id FROM user WHERE name = ?1)", [name])?;
            println!("password of {name} changed, all sessions ended");
            if generated {
                println!("password:    {password}");
            }
        }
        (Some("user"), Some("totp-reset"), Some(name)) => {
            let secret = auth::new_totp_secret();
            let n = conn.execute("UPDATE user SET totp_secret = ?1 WHERE name = ?2", (&secret, name))?;
            if n == 0 {
                bail!("no user {name}");
            }
            conn.execute("DELETE FROM session WHERE user_id = (SELECT id FROM user WHERE name = ?1)", [name])?;
            println!("TOTP of {name} reset, all sessions ended");
            print_totp(&secret, name)?;
        }
        (Some("user"), Some("delete"), Some(name)) => {
            let id: Option<i64> = conn
                .query_row("SELECT id FROM user WHERE name = ?1", [name], |r| r.get(0))
                .optional()?;
            let Some(id) = id else { bail!("no user {name}") };
            conn.execute("DELETE FROM user WHERE id = ?1", [id])?;
            println!("user {name} deleted");
        }
        _ => bail!("unknown command; see `audiojoe-server help`"),
    }
    Ok(())
}

fn validate_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 64
        || !name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
    {
        bail!("user names may contain letters, digits, '.', '_' and '-' (max. 64)");
    }
    Ok(())
}

fn password(file: Option<&String>) -> Result<(String, bool)> {
    match file {
        Some(f) => {
            let p = std::fs::read_to_string(f).with_context(|| format!("cannot read {f}"))?;
            let p = p.trim_end_matches(['\r', '\n']).to_string();
            if p.chars().count() < 12 {
                bail!("password must have at least 12 characters");
            }
            Ok((p, false))
        }
        None => Ok((auth::random_token()[..24].to_string(), true)),
    }
}

fn print_totp(secret: &str, name: &str) -> Result<()> {
    println!("totp secret: {secret}");
    println!("totp uri:    {}", auth::totp(secret, name)?.get_url());
    Ok(())
}
