#!/usr/bin/env python3
"""Copy an already prepared pinned runtime into a macOS app and sign Node.

No downloads, package installation, or compilation occur here. Prepare each
architecture with shared/microscopy-worker/build.mjs and stage-runtime.py first.
This runs before the app's outer signature, so the final signed Node hash is
included in the bundled manifest used by native and canonical runtime binding.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def contained(root: Path, relative: str) -> Path:
    parts = Path(relative).parts
    if not relative or Path(relative).is_absolute() or any(part in ("..", ".") for part in parts) or "\\" in relative:
        raise RuntimeError("Runtime manifest has an unsafe asset path")
    result = root / relative
    if result.is_symlink() or not result.is_file() or not result.resolve().is_relative_to(root.resolve()):
        raise RuntimeError("Runtime asset is missing or not a contained regular file: " + relative)
    return result


def stage(source: Path, destination: Path, platform: str, identity: str, entitlements: Path) -> None:
    manifest_path = source / "microscopy-runtime.json"
    if not manifest_path.is_file():
        raise RuntimeError(
            "Pinned microscopy runtime is missing for " + platform + ". Prepare shared/microscopy-worker/dist/" + platform
            + " with build.mjs and stage-runtime.py using the locally downloaded official Node 24.22.0 archive. No build-time download is performed."
        )
    if manifest_path.stat().st_size > 1024 * 1024:
        raise RuntimeError("Runtime manifest exceeds its metadata bound")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or str(manifest.get("nodeVersion", "")).lstrip("v") != "24.22.0" or manifest["node"]["platform"] != platform:
        raise RuntimeError("Runtime version or architecture does not match this build")
    files = manifest["files"]
    if len(files) > 256:
        raise RuntimeError("Runtime asset count exceeds its bound")
    paths = set()
    for entry in files:
        path = entry["path"]
        if path in paths or path in ("microscopy-runtime.json", manifest["node"]["path"]):
            raise RuntimeError("Runtime contains duplicate or conflicting assets")
        paths.add(path)
        file = contained(source, path)
        if file.stat().st_size != entry["bytes"] or sha256(file) != entry["sha256"]:
            raise RuntimeError("Runtime asset changed after preparation: " + path)
    node_source = contained(source, manifest["node"]["path"])
    if sha256(node_source) != manifest["node"]["sha256"]:
        raise RuntimeError("Prepared Node executable hash does not match its manifest")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".microscopy-stage-", dir=destination.parent))
    try:
        for path in [*sorted(paths), manifest["node"]["path"]]:
            target = temporary / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / path, target)
        node = temporary / manifest["node"]["path"]
        node.chmod(0o755)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", "--entitlements", str(entitlements), str(node)], check=True)
        manifest["node"]["sha256"] = sha256(node)
        manifest["node"]["bytes"] = node.stat().st_size
        (temporary / "microscopy-runtime.json").write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        if destination.exists():
            shutil.rmtree(destination)
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main() -> None:
    source_root = Path(os.environ["SRCROOT"])
    products = Path(os.environ["BUILT_PRODUCTS_DIR"]).resolve()
    resources = products / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "microscopy-runtime"
    if not resources.resolve().is_relative_to(products):
        raise RuntimeError("The runtime destination must be inside this build's app resources")
    architectures = set(os.environ.get("ARCHS", "").split())
    platforms = {"arm64": "darwin-arm64", "x86_64": "darwin-x64"}
    if not architectures or not architectures.issubset(platforms):
        raise RuntimeError("The build must explicitly select arm64 and/or x86_64 for the microscopy runtime")
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "").strip()
    if not identity:
        if os.environ.get("CONFIGURATION") == "Release" and os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
            raise RuntimeError("Release microscopy runtime requires the app's code signing identity")
        identity = "-"
    for architecture in sorted(architectures):
        platform = platforms[architecture]
        stage(source_root / "shared/microscopy-worker/dist" / platform, resources / platform, platform, identity,
              source_root / "CellCounting/BuildSupport/MicroscopyNode.entitlements")


if __name__ == "__main__":
    main()
