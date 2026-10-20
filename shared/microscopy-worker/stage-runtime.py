#!/usr/bin/env python3
"""Stage an already downloaded official pinned Node archive plus compiled shared JS.

No network access, runtime execution, package installation, or source compilation.
Native signing may update only node.sha256/bytes after signing the nested executable.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import zipfile


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def safe_name(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or any(part in ("", ".", "..") for part in value.split("/")) or "\\" in value or ":" in value:
        raise ValueError("Runtime asset path is unsafe")
    return path


def copy_checked(source, target, sha256, size):
    if source.is_symlink() or not source.is_file() or source.stat().st_size != size or digest(source) != sha256:
        raise ValueError(f"Compiled runtime asset differs from its manifest: {source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as incoming, target.open("xb") as outgoing:
        shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
    if digest(target) != sha256:
        raise ValueError("Runtime source changed during staging")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pins = json.loads(Path(__file__).with_name("node-runtime.json").read_text())
    artifact = pins["artifacts"].get(args.platform)
    if not artifact:
        raise ValueError("Choose a platform from node-runtime.json")
    if args.archive.is_symlink() or not args.archive.is_file() or args.archive.stat().st_size > 256 * 1024 ** 2:
        raise ValueError("Provide a local official bounded Node archive")
    if digest(args.archive) != artifact["sha256"]:
        raise ValueError("The Node archive does not match the pinned official SHA-256")
    build_path = args.assets / "microscopy-build.json"
    build = json.loads(build_path.read_text())
    if build.get("schemaVersion") != 1 or build.get("nodeVersion") != pins["version"] or len(build.get("files", [])) > 100:
        raise ValueError("The compiled-assets manifest is incompatible")
    args.output.mkdir(parents=True, exist_ok=False)
    files, seen = [], set()
    for item in build["files"]:
        path = safe_name(item["path"])
        if str(path) in seen or item["bytes"] > 16 * 1024 ** 2:
            raise ValueError("Duplicate or oversized runtime asset")
        seen.add(str(path))
        source = args.assets / path
        if source.resolve().parent != (args.assets / path.parent).resolve() or not source.resolve().is_relative_to(args.assets.resolve()):
            raise ValueError("Runtime asset leaves the compiled directory")
        copy_checked(source, args.output / path, item["sha256"], item["bytes"])
        files.append(item)
    build_sha = digest(build_path)
    copy_checked(build_path, args.output / "microscopy-build.json", build_sha, build_path.stat().st_size)
    files.append({"path": "microscopy-build.json", "sha256": build_sha, "bytes": build_path.stat().st_size})
    prefix = artifact["executable"].split("/", 1)[0]
    members = {artifact["executable"]: "node/node.exe" if args.platform.startswith("win32") else "node/node", f"{prefix}/LICENSE": "node/LICENSE"}
    node_directory = args.output / "node"
    node_directory.mkdir()
    if args.archive.suffix == ".zip":
        with zipfile.ZipFile(args.archive) as archive:
            for name, relative in members.items():
                info = archive.getinfo(name)
                if info.file_size > 160 * 1024 ** 2 or info.is_dir() or ((info.external_attr >> 16) & 0o170000) == 0o120000:
                    raise ValueError("Pinned archive member is invalid")
                with archive.open(info) as incoming, (args.output / relative).open("xb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
    else:
        with tarfile.open(args.archive, "r:*") as archive:
            for name, relative in members.items():
                info = archive.getmember(name)
                if not info.isfile() or info.size > 160 * 1024 ** 2:
                    raise ValueError("Pinned archive member is not a bounded regular file")
                with archive.extractfile(info) as incoming, (args.output / relative).open("xb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
    node_path = "node/node.exe" if args.platform.startswith("win32") else "node/node"
    node = args.output / node_path
    node.chmod(0o755)
    license_file = args.output / "node/LICENSE"
    files.append({"path": "node/LICENSE", "sha256": digest(license_file), "bytes": license_file.stat().st_size})
    manifest = {"schemaVersion": 1, "engineVersion": build["engineVersion"], "nodeVersion": pins["version"],
                "entrypoint": build["entrypoint"], "node": {"path": node_path, "sha256": digest(node), "bytes": node.stat().st_size,
                "archiveSha256": artifact["sha256"], "archiveUrl": f'https://nodejs.org/download/release/v{pins["version"]}/{artifact["file"]}',
                "platform": args.platform}, "files": files}
    with (args.output / "microscopy-runtime.json").open("x") as output:
        json.dump(manifest, output, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
