"""Verified, bounded analysis packages; importing an archive never runs code."""
from __future__ import annotations

from _workbench_indexed import RecordList

import copy
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import sys
import tempfile
import uuid
import zipfile

MAX_ARCHIVE_BYTES = 2 * 1024 ** 3
MAX_EXPANDED_BYTES = 4 * 1024 ** 3
MAX_MEMBER_BYTES = 512 * 1024 ** 2
MAX_CELLPOSE4_CHECKPOINT_BYTES = 2 * 1024 ** 3
MAX_METADATA_BYTES = 64 * 1024 ** 2
MAX_MEMBERS = 10000
MAX_DIRECTORY_BYTES = 8 * 1024 ** 2
RUNTIME_PACKAGES = ("numpy", "scipy", "Pillow", "scikit-image", "tifffile")
_HASH = re.compile(r"^[0-9a-f]{64}$")
_ARTIFACT = re.compile(r"^artifacts/([0-9a-f]{64})\.[A-Za-z0-9._-]{1,32}$")


def operations():
    from _workbench_schema import _object, _op, _STRING
    return [
        _op("package.inspect", "Verify an analysis ZIP, inspect its contents and report runtime dependencies without running code.",
            _object({"path": _STRING}, ["path"]), project=False),
        _op("package.restore", "Restore a verified analysis ZIP into a new project directory; executable plugins remain disabled.",
            _object({"path": _STRING, "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["path"]), True),
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _json(data, name):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                fail("invalid-package", f"Duplicate JSON field in {name}.")
            result[key] = value
        return result

    def invalid_constant(value):
        fail("invalid-package", f"Non-finite JSON value in {name}.")

    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError) as exc:
        fail("invalid-package", f"Cannot read {name}: {exc}")


def runtime_versions():
    packages = {}
    for name in RUNTIME_PACKAGES:
        try:
            packages[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    return {"python": ".".join(map(str, sys.version_info[:3])), "packages": packages}


def dependency_report(provenance, document):
    current = runtime_versions()
    recorded = provenance.get("runtimeDependencies", {})
    required = recorded.get("packages", {})
    runtime = []
    warnings = []
    for name in ("python", *RUNTIME_PACKAGES):
        installed = current["python"] if name == "python" else current["packages"][name]
        expected = recorded.get("python") if name == "python" else required.get(name)
        status = ("missing" if installed is None else "unrecorded" if expected is None
                  else "available" if installed == expected else "version-mismatch")
        runtime.append({"name": name, "requiredVersion": expected,
                        "installedVersion": installed, "status": status})
    if not recorded:
        warnings.append("This package predates recorded runtime dependency versions; exact reproduction cannot be established.")
    if any(item["status"] == "version-mismatch" for item in runtime):
        warnings.append("Installed runtime versions differ from those used to export this package.")
    plugins = [{
        "id": item.get("pluginId"), "name": item.get("manifest", {}).get("name"),
        "version": item.get("manifest", {}).get("version"), "status": "disabled-after-restore",
        "wasEnabled": bool(item.get("enabled")), "sourceHash": item.get("sourceHash"),
        "externalDependencies": "not-declared",
    } for item in document.get("plugins", [])]
    if plugins:
        warnings.append("Retained plugin code is never executed during inspection or restoration. Enable each trusted plugin explicitly before use.")
        warnings.append("Plugin manifests do not declare external Python dependencies; their availability cannot be verified without execution.")
    models = [{"id": item["id"], "name": item["name"], "backend": item["backend"],
               "checkpointHash": item["checkpointHash"], "pythonPath": item["pythonPath"],
               "status": "disabled-after-restore", "interpreterBinding": "unverified",
               "environmentDependencies": "probe-required"}
              for item in document.get("models", [])]
    if models:
        warnings.append("Registered model checkpoints are retained, but local interpreter bindings must be explicitly enabled or rebound after restore.")
    return {"runtime": runtime, "plugins": plugins, "models": models,
            "canReexecute": all(item["status"] != "missing" for item in runtime) and not plugins and not models,
            "exactRuntimeMatch": all(item["status"] == "available" for item in runtime),
            "warnings": warnings}


def store_json_reader(store):
    def read_json(name, digest, max_bytes=32 * 1024 ** 2):
        path = store.verify_artifact(name, digest)
        if path.stat().st_size > max_bytes:
            fail("artifact-too-large", "A retained dependency node exceeds its metadata bound.")
        return _json(path.read_bytes(), name)
    return read_json


def directory_json_reader(root):
    """Read already extracted immutable artifact metadata without a live database."""
    def read_json(name, digest, max_bytes=32 * 1024 ** 2):
        if not _ARTIFACT.fullmatch(name) or _ARTIFACT.fullmatch(name).group(1) != digest:
            fail("invalid-artifact", "A dependency node must be hash-named inside artifacts.")
        path = root / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > max_bytes:
            fail("invalid-artifact", "A dependency node is absent, linked or oversized.")
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            fail("package-integrity", "A retained dependency node changed after extraction.")
        return _json(data, name)
    return read_json


def artifact_references(document, read_json=None):
    """Collect every retained immutable data reference, including extension data."""
    references = {}
    runtime = document.get("packageRuntimeEvidence")
    if runtime is not None:
        references[runtime["environmentPath"]] = runtime["environmentHash"]
    for image in document["images"]:
        references[image["sourcePath"]] = image["sourceHash"]
        versions = ([image["analysis"]] if image.get("analysis") else []) + image.get("undoStack", [])
        for frame in image.get("volumeFrames", []):
            versions.append(frame)
            versions.extend(frame.get("undoStack", []))
        for version in versions:
            references[version["labelsPath"]] = version["labelsHash"]
        for track in image.get("volumeTracks", []):
            for frame in track.get("frameReferences", []):
                references[frame["labelsPath"]] = frame["labelsHash"]
            if track.get("sourcePath"):
                references[track["sourcePath"]] = track["sourceHash"]
    import _workbench_plugins as plugins
    import _workbench_adaptation as adaptation
    import _workbench_models as models
    import _workbench_review as review
    import _workbench_sources as sources
    import _workbench_lineages as lineages
    import _workbench_registration as registration
    import _workbench_support as support
    import _workbench_assays as assays
    import _workbench_exports as image_exports
    import _workbench_label_import as label_imports
    import _workbench_annotations as annotations
    import _workbench_display_preset_io as display_preset_io
    import _workbench_distributed as distributed
    import _workbench_refresh as refresh
    import _workbench_graphs as graphs
    import _workbench_migration as migration
    import _workbench_workspace as workspaces
    import _workbench_library as library
    import _workbench_zarr as zarr_sources
    import _workbench_tiled as tiled
    references.update(plugins.artifact_references(document))
    references.update(adaptation.artifact_references(document))
    references.update(models.artifact_references(document))
    references.update(review.artifact_references(document))
    references.update(sources.artifact_references(document))
    references.update(lineages.artifact_references(document))
    references.update(registration.artifact_references(document))
    references.update(support.artifact_references(document))
    references.update(assays.artifact_references(document))
    import _workbench_assay_series as assay_series
    references.update(assay_series.artifact_references(document))
    references.update(image_exports.artifact_references(document))
    references.update(label_imports.artifact_references(document))
    references.update(annotations.artifact_references(document))
    references.update(display_preset_io.artifact_references(document))
    references.update(distributed.artifact_references(document))
    references.update(refresh.artifact_references(document))
    references.update(graphs.artifact_references(document))
    references.update(migration.artifact_references(document))
    references.update(workspaces.artifact_references(document))
    references.update(library.artifact_references(document))
    references.update(zarr_sources.artifact_references(document, read_json))
    import _workbench_omero as omero
    references.update(omero.artifact_references(document))
    references.update(tiled.artifact_references(document, read_json))
    import _workbench_statistics as statistical
    references.update(statistical.artifact_references(document))
    import _workbench_experiment_layouts as experiment_layouts
    references.update(experiment_layouts.artifact_references(document))
    import _workbench_temporal as temporal
    references.update(temporal.artifact_references(document))
    import _workbench_indexed as indexed
    references.update(indexed.artifact_references(document))
    return references


def _preflight_directory(stream):
    """Bound the central directory before zipfile allocates its member list."""
    stream.seek(0, os.SEEK_END)
    size = stream.tell()
    if size > MAX_ARCHIVE_BYTES:
        fail("package-too-large", "Analysis packages are limited to 2 GiB compressed.")
    stream.seek(max(0, size - 65557))
    tail = stream.read(65557)
    index = tail.rfind(b"PK\x05\x06")
    if index < 0 or len(tail) - index < 22:
        fail("invalid-package", "The archive has no valid ZIP directory.")
    _, disk, start_disk, disk_count, count, directory_bytes, offset, comment = struct.unpack(
        "<4s4H2LH", tail[index:index + 22])
    if (disk or start_disk or disk_count != count or count > MAX_MEMBERS
            or directory_bytes > MAX_DIRECTORY_BYTES or index + 22 + comment != len(tail)
            or offset + directory_bytes > size):
        fail("package-too-large", "Unsupported multi-part, oversized or inconsistent ZIP directory.")
    stream.seek(0)


def _members(archive):
    infos = archive.infolist()
    if len(infos) > MAX_MEMBERS:
        fail("package-too-large", "An analysis package may contain at most 10,000 files.")
    members = {}
    total = 0
    for info in infos:
        name = info.filename
        path = PurePosixPath(name)
        mode = info.external_attr >> 16
        if (not name or len(name) > 256 or "\\" in name or "\x00" in name or ":" in name
                or path.is_absolute() or str(path) != name or ".." in path.parts
                or info.is_dir() or stat.S_ISLNK(mode)
                or (stat.S_IFMT(mode) not in (0, stat.S_IFREG))
                or name in members or info.flag_bits & 1):
            fail("invalid-package", "Archive members must be distinct, ordinary relative files.",
                 {"member": name})
        if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            fail("invalid-package", "Only stored and deflated ZIP entries are supported.")
        # This provisional exception is authorized against the hash-verified
        # project model records before any large member is opened.
        maximum = MAX_CELLPOSE4_CHECKPOINT_BYTES if _ARTIFACT.fullmatch(name) and name.endswith((".cp4", ".microsam")) else MAX_MEMBER_BYTES
        if info.file_size > maximum or info.file_size > max(1, info.compress_size) * 10000:
            fail("package-too-large", "An archive member exceeds the size or expansion budget.",
                 {"member": name})
        total += info.file_size
        if total > MAX_EXPANDED_BYTES:
            fail("package-too-large", "Expanded analysis packages are limited to 4 GiB.")
        members[name] = info
    for required in ("manifest.json", "project.json", "provenance.json"):
        if required not in members or members[required].file_size > MAX_METADATA_BYTES:
            fail("invalid-package", f"Missing or oversized {required}.")
    return members, total


def _validate_document(document, manifest, read_json=None):
    if (not isinstance(document, dict) or document.get("schemaVersion") != 1
            or not isinstance(document.get("id"), str) or not isinstance(document.get("name"), str)
            or type(document.get("revision")) is not int or document["revision"] < 0
            or not isinstance(document.get("images"), (list, RecordList)) or len(document["images"]) > (100000 if document.get("storageFormat") == 2 else 1000)
            or not isinstance(document.get("history"), (list, RecordList))):
        fail("invalid-package", "The project snapshot has an unsupported structure.")
    image_ids = set()
    for image in document["images"]:
        required = ("id", "name", "sourcePath", "sourceHash", "width", "height", "channels",
                    "pxPerUm", "axes", "shape", "dtype", "zCount", "timeCount", "importedAt")
        if not isinstance(image, dict) or any(key not in image for key in required):
            fail("invalid-package", "An image in the project snapshot is incomplete.")
        if not isinstance(image["id"], str) or image["id"] in image_ids:
            fail("invalid-package", "Image identities must be distinct strings.")
        image_ids.add(image["id"])
        if any(type(image[key]) is not int or image[key] < 1 for key in
               ("width", "height", "channels", "zCount", "timeCount")):
            fail("invalid-package", "Image dimensions must be positive integers.")
        if image["channels"] > 32:
            fail("invalid-package", "The image channel count exceeds the runtime limit.")
    if "displayPresets" in document or "displayPresetImports" in document:
        from _workbench_schema import WorkbenchError
        import _workbench_display_presets as display_presets
        try:
            display_presets.validate_document(document)
        except (WorkbenchError, TypeError, KeyError, AttributeError) as exc:
            fail("invalid-package", f"Invalid display preset history: {exc}")
    if any(key in document for key in ("distributions", "distributedTask", "distributedExecution", "distributionPublications")):
        import _workbench_distributed as distributed
        distributed.validate_document(document)
    import _workbench_models as models
    try:
        models.validate_environment_records(document)
        models.validate_model_artifacts(document)
        import _workbench_model_cards as model_cards
        model_cards.validate_document(document)
        import _workbench_adaptation as adaptation
        adaptation.validate_document(document)
        import _workbench_refresh as refresh
        refresh.validate_document(document)
        import _workbench_graphs as graphs
        graphs.validate_document(document)
        import _workbench_migration as migration
        migration.validate_document(document)
        import _workbench_workspace as workspaces
        workspaces.validate_document(document)
        import _workbench_library as library
        library.validate_document(document)
        import _workbench_zarr as zarr_sources
        zarr_sources.validate_document(document)
        import _workbench_omero as omero
        omero.validate_document(document)
        import _workbench_tiled as tiled
        tiled.validate_document(document)
        import _workbench_statistics as statistical
        statistical.validate_document(document)
        import _workbench_experiment_layouts as experiment_layouts
        experiment_layouts.validate_document(document)
        import _workbench_temporal as temporal
        temporal.validate_document(document)
        import _workbench_assay_series as assay_series
        assay_series.validate_document(document)
    except (TypeError, KeyError, AttributeError) as exc:
        fail("invalid-package", f"Invalid observed environment or downstream refresh metadata: {exc}")
    try:
        references = artifact_references(document, read_json)
    except (TypeError, KeyError, AttributeError) as exc:
        fail("invalid-package", f"Invalid retained artifact references: {exc}")
    for name, digest in references.items():
        match = _ARTIFACT.fullmatch(name) if isinstance(name, str) else None
        if not match or match.group(1) != digest or manifest.get(name) != digest:
            fail("invalid-package", "A project artifact reference is missing or inconsistent.",
                 {"artifact": name})
    for name in manifest:
        if name.startswith("artifacts/") and name not in references:
            fail("invalid-package", "The package contains an unreferenced executable or data artifact.",
                 {"artifact": name})
    if "sweeps" in document:
        import _workbench_sweeps as sweeps
        records = document["sweeps"]
        if not isinstance(records, (list, RecordList)) or len(records) > sweeps.MAX_SWEEPS:
            fail("invalid-package", "The retained sweep catalogue exceeds its supported bounds.")
        try:
            identities = [item["id"] for item in records]
            if len(set(identities)) != len(identities):
                fail("invalid-package", "Sweep group identities must be unique.")
            for item in records:
                if not 1 <= len(item["combinations"]) <= sweeps.MAX_COMBINATIONS:
                    fail("invalid-package", "A retained sweep exceeds its combination limit.")
                sweeps.get(document, item["id"])
                sweeps._jobs(document, item)
                if any(mapping["imageId"] not in image_ids for combination in item["combinations"]
                       for mapping in combination["variants"]):
                    fail("invalid-package", "A retained sweep refers to a missing image variant.")
        except (TypeError, KeyError, AttributeError) as exc:
            fail("invalid-package", f"Invalid sweep metadata: {exc}")
    return references


def _verify(path, artifact_destination=None):
    import _workbench_package2 as package2
    if package2.is_package2(path): return package2.verify_document(path, artifact_destination)
    from _workbench_schema import absolute_path
    source = absolute_path(path, "path")
    if not source.is_file():
        fail("invalid-path", "Select an existing analysis ZIP file.")
    try:
        with source.open("rb") as stream:
            original_stat = os.fstat(stream.fileno())
            _preflight_directory(stream)
            with zipfile.ZipFile(stream) as archive:
                members, total = _members(archive)
                manifest = _json(archive.read("manifest.json"), "manifest.json")
                if (not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1
                        or not isinstance(manifest.get("files"), dict)):
                    fail("invalid-package", "Unsupported package manifest.")
                hashes = manifest["files"]
                if set(hashes) != set(members) - {"manifest.json"}:
                    fail("invalid-package", "The manifest must describe every archive member exactly once.")
                project_bytes = archive.read("project.json")
                if hashlib.sha256(project_bytes).hexdigest() != hashes["project.json"]:
                    fail("package-integrity", "The project snapshot failed its SHA-256 integrity check.")
                document = _json(project_bytes, "project.json")
                def archive_json_reader(name, digest, max_bytes=32 * 1024 ** 2):
                    member = members.get(name)
                    if member is None or hashes.get(name) != digest or member.file_size > max_bytes:
                        fail("invalid-package", "A retained dependency node is missing, mismatched or oversized.")
                    data = archive.read(member)
                    if len(data) != member.file_size or hashlib.sha256(data).hexdigest() != digest:
                        fail("package-integrity", "A retained dependency node failed its content identity check.")
                    return _json(data, name)
                _validate_document(document, hashes, archive_json_reader)
                retained_large_models = set()
                model_records = document.get("models", [])
                if not isinstance(model_records, (list, RecordList)) or len(model_records) > 128:
                    fail("invalid-package", "The registered model catalogue exceeds its supported bounds.")
                for model in model_records:
                    if not isinstance(model, dict) or model.get("backend") not in ("cellpose3", "cellpose4", "stardist2d", "omnipose", "micro-sam"):
                        fail("invalid-package", "A retained model has an unsupported backend.")
                    name, digest = model.get("checkpointPath"), model.get("checkpointHash")
                    suffix = {"cellpose4": ".cp4", "micro-sam": ".microsam"}.get(model["backend"])
                    if suffix and isinstance(name, str) and name == f"artifacts/{digest}{suffix}" and hashes.get(name) == digest:
                        retained_large_models.add(name)
                    for item in model.get("modelArtifacts", []):
                        member = members.get(item["path"])
                        if member is None or member.file_size != item["bytes"]:
                            fail("invalid-package", "A compound model artifact has a missing or inconsistent retained byte length.")
                        if item["role"] in ("config", "thresholds"):
                            if member.file_size > 1024 ** 2:
                                fail("package-too-large", "Specialist model JSON artifacts are limited to 1 MiB.")
                            config = archive_json_reader(item["path"], item["hash"], 1024 ** 2)
                            if not isinstance(config, dict):
                                fail("invalid-package", "A specialist configuration must contain a JSON object.")
                            if item["role"] == "config" and (config.get("n_dim", 2) != 2 or config.get("axes", "YXC") != "YXC"
                                    or config.get("n_classes") not in (None, 0) or config.get("n_channel_in") != model["registrationConfig"].get("inputChannels")):
                                fail("invalid-package", "Retained StarDist configuration bytes differ from the registered channel/dimension identity.")
                            if item["role"] == "thresholds" and (set(config) != {"prob", "nms"} or any(type(value) not in (int, float) or not 0 < value < 1 for value in config.values())):
                                fail("invalid-package", "Retained StarDist thresholds must be finite probabilities strictly between zero and one.")
                for name, member in members.items():
                    if member.file_size > MAX_MEMBER_BYTES and name not in retained_large_models:
                        fail("package-too-large", "Only an explicitly retained Cellpose 4 or micro-SAM primary checkpoint may exceed 512 MiB.",
                             {"member": name})
                for imported in document.get("displayPresetImports", []):
                    if members[imported["filePath"]].file_size > 1024 * 1024:
                        fail("package-too-large", "A retained display-preset import exceeds its 1 MiB bound.")
                import _workbench_distributed as distributed
                snapshots = distributed.snapshot_references(document)
                if any(members[name].file_size > MAX_METADATA_BYTES for name in snapshots):
                    fail("package-too-large", "An isolated distributed project snapshot exceeds 64 MiB.")
                environment_files = {name for name in hashes if name.startswith("artifacts/") and
                                     name.endswith((".model-environment.json", ".python-environment.json"))}
                if any(members[name].file_size > 2 * 1024 ** 2 for name in environment_files):
                    fail("package-too-large", "An observed Python environment exceeds its 2 MiB bound.")
                import _workbench_models as models
                import _workbench_refresh as refresh
                environment_bindings = [*models.environment_bindings(document), *distributed.environment_bindings(document),
                                        *refresh.environment_bindings(document)]
                environment_summaries = {}
                metadata = {"project.json": project_bytes}
                for name, digest in hashes.items():
                    if not isinstance(digest, str) or not _HASH.fullmatch(digest):
                        fail("invalid-package", "The manifest contains an invalid SHA-256 digest.")
                    if name == "project.json":
                        continue
                    maximum = MAX_CELLPOSE4_CHECKPOINT_BYTES if name in retained_large_models else MAX_MEMBER_BYTES
                    checksum = hashlib.sha256()
                    size = 0
                    saved = bytearray() if name in ("project.json", "provenance.json") or name in snapshots or name in environment_files else None
                    output = None
                    try:
                        if artifact_destination is not None and name.startswith("artifacts/"):
                            if not _ARTIFACT.fullmatch(name):
                                fail("invalid-package", "Invalid immutable artifact filename.")
                            output = (artifact_destination / name).open("xb")
                        with archive.open(members[name]) as entry:
                            for block in iter(lambda: entry.read(1024 * 1024), b""):
                                size += len(block)
                                if size > members[name].file_size or size > maximum:
                                    fail("package-too-large", "An archive entry expanded beyond its declared size.")
                                checksum.update(block)
                                if saved is not None:
                                    saved.extend(block)
                                if output is not None:
                                    output.write(block)
                        if size != members[name].file_size or checksum.hexdigest() != digest:
                            fail("package-integrity", "An archive member failed its SHA-256 integrity check.",
                                 {"member": name})
                        if output is not None:
                            output.flush()
                            os.fsync(output.fileno())
                        if name in snapshots:
                            environment_bindings.extend(distributed.validate_snapshot(document, name, bytes(saved), hashes, read_json=archive_json_reader))
                        elif name in environment_files:
                            import _workbench_environment as environments
                            import _workbench_models as models
                            try:
                                inventory = environments.validate(_json(bytes(saved), name))
                            except ValueError as exc:
                                fail("invalid-package", f"Invalid observed environment: {exc}")
                            environment_summaries[name] = {"hash": inventory["hash"], "summary": environments.summary(inventory)}
                        elif saved is not None:
                            metadata[name] = bytes(saved)
                    finally:
                        if output is not None:
                            output.close()
                for binding in environment_bindings:
                    observed = environment_summaries.get(binding["inventoryPath"])
                    if observed != {key: binding[key] for key in ("hash", "summary")}:
                        fail("invalid-package", "An observed environment artifact differs from its retained capture or task binding.")
                document = _json(metadata["project.json"], "project.json")
                provenance = _json(metadata["provenance.json"], "provenance.json")
                if (not isinstance(provenance, dict) or provenance.get("schemaVersion") != 1
                        or provenance.get("projectId") != document["id"]
                        or provenance.get("sourceRevision") != document["revision"]):
                    fail("invalid-package", "Project snapshot and provenance do not identify the same revision.")
            # Hash the same descriptor that supplied all verified archive bytes.
            stream.seek(0)
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
            archive_hash = digest.hexdigest()
            final_stat = os.fstat(stream.fileno())
            if (original_stat.st_size, original_stat.st_mtime_ns, original_stat.st_ctime_ns) != (
                    final_stat.st_size, final_stat.st_mtime_ns, final_stat.st_ctime_ns):
                fail("package-changed", "The package changed during verification. Retry with a stable file.")
    except (zipfile.BadZipFile, zipfile.LargeZipFile, EOFError, NotImplementedError) as exc:
        fail("invalid-package", f"Cannot read the analysis ZIP: {exc}")
    package = {"path": str(source), "sha256": archive_hash,
               "projectId": document["id"], "name": document["name"],
               "sourceRevision": document["revision"], "imageCount": len(document["images"]),
               "volumeFrameCount": sum(len(image.get("volumeFrames", [])) for image in document["images"]),
               "files": sorted(members), "uncompressedBytes": total}
    return {"package": package, "dependencies": dependency_report(provenance, document),
            "integrity": {"verified": True, "fileCount": len(members)}}, document


def inspect(path):
    return _verify(path)[0]


def restore(request, actor, inspection):
    """Prepare privately, then claim a new directory and publish SQLite last."""
    from _workbench_schema import absolute_path
    from _workbench_store import ProjectStore, DB_NAME, canonical, request_hash, sync_directory, utc_now, file_hash
    root = absolute_path(request["projectPath"], "projectPath")
    if root.exists():
        if (root / DB_NAME).is_file():
            replay = ProjectStore(str(root)).replay(request)
            if replay is not None:
                return replay
        fail("project-exists", "Package restoration requires a new project directory.")
    if not root.parent.is_dir():
        fail("invalid-path", "The new project's parent directory must exist.")
    temporary = Path(tempfile.mkdtemp(dir=root.parent, prefix=".cellcounter-restore-"))
    staged = temporary / "project"
    try:
        staged.mkdir()
        (staged / "artifacts").mkdir()
        report, original = _verify(request["arguments"]["path"], staged)
        document = copy.deepcopy(original)
        now = utc_now()
        document["restoredHistory"] = [
            *document.get("restoredHistory", []),
            *[{**item, "projectId": original["id"]} for item in original["history"]],
        ]
        document["restoredFrom"] = {key: report["package"][key] for key in
                                    ("path", "sha256", "projectId", "name", "sourceRevision")}
        document.update({"id": str(uuid.uuid4()), "name": request["arguments"].get("name", original["name"]),
                         "revision": 0, "createdAt": now, "updatedAt": now,
                         "history": [{"revision": 0, "operation": "package.restore",
                                      "requestId": request["requestId"], "actor": actor, "at": now,
                                      "arguments": request["arguments"]}]})
        for plugin in document.get("plugins", []):
            plugin["enabledBeforeRestore"] = bool(plugin.get("enabled"))
            plugin["enabled"] = False
        for model in document.get("models", []):
            model["enabledBeforeRestore"] = bool(model.get("enabled"))
            model["enabled"] = False
        for job in document.get("trainingJobs", []):
            if job["status"] != "collected":
                job["status"] = "interrupted"
                job["error"] = {"code": "restored-training-job",
                                "message": "Training processes are local to their original project. Start a new job explicitly."}
        for job in document.get("jobs", []):
            if job["status"] in ("pending", "running"):
                job["status"] = "paused"
                job["pausedReason"] = "restored-package"
        for refresh in document.get("refreshJobs", []):
            if refresh["status"] in ("pending", "running"):
                refresh["status"] = "paused"
                refresh["pauseReason"] = "Restored packages require explicit resume and runtime compatibility."
        for analysis in document.get("tiledAnalyses", []):
            if analysis["status"] in ("pending", "running"):
                analysis["status"] = "paused"
                analysis["pauseReason"] = "Restored tiled analyses require explicit source authorization and resume."
        from _workbench_jobs import restored_records
        restored_records(document)
        if document.get("legacyMigration", {}).get("status") in ("pending", "running"):
            document["legacyMigration"]["status"] = "paused"
            document["legacyMigration"]["pauseReason"] = "Restored migration requires explicit source-path authorization and resume."
        result = {**inspection(document), "restoredFrom": document["restoredFrom"],
                  "dependencies": report["dependencies"]}
        response = {"schemaVersion": 1, "ok": True, "operation": "package.restore",
                    "requestId": request["requestId"], "revision": 0, "result": result}
        # Construct metadata using the same store initializer, separately from
        # staged artifacts, so no target appears before verification completes.
        metadata_path = temporary / "metadata"
        ProjectStore.create(str(metadata_path), document, request, response)
        # Indexed creation may retain measurement tables for older packages that
        # stored cells inline. Carry those exact newly indexed artifacts too.
        for artifact in (metadata_path / "artifacts").iterdir():
            target = staged / "artifacts" / artifact.name
            try: os.link(str(artifact), str(target))
            except FileExistsError:
                if file_hash(artifact) != file_hash(target): fail("package-integrity", "An indexed measurement artifact conflicts with retained package bytes.")
        sync_directory(staged / "artifacts")
        try:
            root.mkdir()
        except FileExistsError:
            fail("project-exists", "Another operation created the restore destination.")
        # Exclusive directory creation ensures that no existing project or
        # unrelated destination file can ever be overwritten.
        (root / ".restore-in-progress.json").write_text(canonical({
            "schemaVersion": 1, "requestHash": request_hash(request),
            "archiveHash": report["package"]["sha256"],
        }), encoding="utf-8")
        os.rename(staged / "artifacts", root / "artifacts")
        os.rename(metadata_path / DB_NAME, root / DB_NAME)
        sync_directory(root)
        (root / ".restore-in-progress.json").unlink()
        sync_directory(root.parent)
        return response
    finally:
        # A partially published target is retained for diagnosis. It is never
        # adopted or replaced by another restore request.
        shutil.rmtree(temporary)
