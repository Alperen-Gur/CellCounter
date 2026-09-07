fn main() {
    // Keep the scripts in the executable as well as the installer resources.
    // A fresh launch must not depend on an installer's resource layout or the
    // working directory of a Windows shortcut. Missing sources fail the build.
    let python =
        std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../python");
    let manifest = python.join("runtime-files.txt");
    println!("cargo:rerun-if-changed={}", manifest.display());
    let mut embedded = String::from("const EMBEDDED_FILES: &[(&str, &[u8])] = &[\n");
    let mut seen = std::collections::BTreeSet::new();
    for name in std::fs::read_to_string(&manifest).unwrap().lines() {
        let name = name.trim();
        if name.is_empty() || name.starts_with('#') {
            continue;
        }
        assert!(
            !name.contains(['/', '\\']) && name != "." && name != "..",
            "Python runtime entries must be filenames: {name}"
        );
        assert!(
            seen.insert(name.to_string()),
            "Duplicate Python resource: {name}"
        );
        let source = python.join(name);
        assert!(source.is_file(), "Missing Python runtime resource: {name}");
        println!("cargo:rerun-if-changed={}", source.display());
        embedded.push_str(&format!("({name:?}, include_bytes!({:?})),\n", source));
    }
    assert!(!seen.is_empty(), "The Python runtime manifest is empty");
    embedded.push_str("];\n");
    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    std::fs::write(out.join("python_runtime.rs"), embedded).unwrap();
    tauri_build::build()
}
