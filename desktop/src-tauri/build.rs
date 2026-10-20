fn main() {
    // Keep the scripts in the executable as well as the installer resources.
    // A fresh launch must not depend on an installer's resource layout or the
    // working directory of a Windows shortcut. Missing sources fail the build.
    let python =
        std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../python");
    let shared = python.join("../../shared/python");
    let mut embedded = String::from("const EMBEDDED_FILES: &[(&str, &[u8])] = &[\n");
    let mut seen = std::collections::BTreeSet::new();
    for directory in [&python, &shared] {
        let manifest = directory.join("runtime-files.txt");
        println!("cargo:rerun-if-changed={}", manifest.display());
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
            let source = directory.join(name);
            assert!(source.is_file(), "Missing Python runtime resource: {name}");
            println!("cargo:rerun-if-changed={}", source.display());
            embedded.push_str(&format!("({name:?}, include_bytes!({:?})),\n", source));
        }
    }
    assert!(!seen.is_empty(), "The Python runtime manifest is empty");
    embedded.push_str("];\n");
    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    std::fs::write(out.join("python_runtime.rs"), embedded).unwrap();
    let microscopy = std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("../microscopy-runtime/microscopy-runtime.json");
    println!("cargo:rerun-if-changed={}", microscopy.display());
    if std::env::var("PROFILE").as_deref() == Ok("release") {
        assert!(microscopy.is_file(), "Release packaging requires the pinned microscopy runtime. Run shared/microscopy-worker/build.mjs and stage-runtime.py with a local official archive; no runtime is downloaded automatically.");
    }
    tauri_build::build()
}
