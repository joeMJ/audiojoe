// Builds the list of screenshots in docs/screenshots/ into the server (see src/docs.rs).
//
// The directory is taken from CARGO_MANIFEST_DIR when the build script runs, not when it is
// compiled (env!): a build script compiled in a directory that was moved later would otherwise
// look in the old place. Without pictures the build stops – the manual refers to them.
use std::{env, fs, path::PathBuf};

fn main() {
    let dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("../docs/screenshots");
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut names: Vec<String> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("screenshots of the manual not found in {}: {e}", dir.display()))
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".webp"))
        .collect();
    assert!(!names.is_empty(), "no screenshots (*.webp) in {}", dir.display());
    names.sort();
    let rows: String = names
        .iter()
        .map(|n| format!("    ({n:?}, include_bytes!({:?})),\n", dir.join(n).display().to_string()))
        .collect();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("screenshots.rs");
    fs::write(out, format!("const SCREENSHOTS: &[(&str, &[u8])] = &[\n{rows}];\n")).unwrap();
}
