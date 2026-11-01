// Builds the list of screenshots in docs/screenshots/ into the server (see src/docs.rs).
use std::{env, fs, path::Path};

fn main() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../docs/screenshots");
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut names: Vec<String> = fs::read_dir(&dir)
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.ends_with(".webp")).collect())
        .unwrap_or_default();
    names.sort();
    let rows: String = names
        .iter()
        .map(|n| format!("    ({n:?}, include_bytes!({:?})),\n", dir.join(n).display().to_string()))
        .collect();
    let out = Path::new(&env::var("OUT_DIR").unwrap()).join("screenshots.rs");
    fs::write(out, format!("const SCREENSHOTS: &[(&str, &[u8])] = &[\n{rows}];\n")).unwrap();
}
