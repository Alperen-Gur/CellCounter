"""Read-only legacy capture and resumable evidence-preserving library migration.

Legacy centre/contour records are never represented as exact label rasters.
Native SwiftData decoding belongs to the installed native application, while
Windows SQLite snapshots are decoded here without changing the source library.
"""
from __future__ import annotations

from _workbench_indexed import image_index

import base64
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

MAX_ARCHIVE = 64 * 1024 ** 2
MAX_FILE = 512 * 1024 ** 2
MAX_TOTAL = 4 * 1024 ** 3
LIMITS = {"images": 1000, "files": 10000, "records": 100000,
          "archiveBytes": MAX_ARCHIVE, "fileBytes": MAX_FILE, "totalBytes": MAX_TOTAL}
KINDS = {"cellcounter-native-library": "macos", "cellcounter-windows-library": "windows"}
_native_helper = None


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def configure_native_helper(path):
    """Host-local startup configuration; never accepted from project metadata."""
    global _native_helper
    from _workbench_schema import absolute_path
    from _workbench_store import file_hash
    candidate = absolute_path(path, "nativeHelper")
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        fail("native-helper-unavailable", "The configured native archive helper is not an executable regular file.")
    _native_helper = {"path": str(candidate), "hash": file_hash(candidate)}


def notes():
    return [
        "All archived records and available evidence files are retained, including records outside the selected scientific import scope.",
        "Legacy detections preserve centres, diameters and optional contours. No exact instance mask is implied or reconstructed.",
        "Ground-truth points, inclusion/exclusion ROIs, review decisions, model versions and queued jobs remain archived with their original meaning; no approval, executable trust or job restart is inferred.",
        "Original vendor bytes, normalized analysis TIFFs and display images have separate evidence roles. A display projection never silently replaces a missing analysis source.",
        "Migration advances one bounded file or image at a time. Pause/cancel preserves completed checkpoints and never changes the source library.",
        "Current canonical image and retained-evidence limits are explicit. Larger libraries require a selected import scope or future expanded storage support; no records are silently truncated.",
    ]


def catalogue():
    return {"platforms": [{"id": "windows", "captureAvailable": True, "requiresNativeHelper": False},
                          {"id": "macos", "captureAvailable": sys.platform == "darwin" and _native_helper is not None,
                           "requiresNativeHelper": True}], "limits": dict(LIMITS), "notes": notes()}


def operations():
    from _workbench_schema import _op, _object, _STRING, _ID
    ids = {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000}
    ops = [
        _op("migration.library.catalogue", "Describe legacy capture platforms, evidence retention and import bounds.", _object(), project=False),
        _op("migration.library.capture", "Capture a consistent read-only legacy library archive; macOS requires an explicitly configured installed native helper.",
            _object({"platform": {"type": "string", "enum": ["windows", "macos"]}, "sourceDirectory": _STRING,
                     "destination": _STRING, "selectedImageIds": ids}, ["platform", "sourceDirectory", "destination"]), True, False),
        _op("migration.library.preview", "Inspect a legacy archive and freeze evidence hashes without creating a project or rasterizing geometry.",
            _object({"path": _STRING, "imageIds": ids}, ["path"]), project=False),
        _op("migration.library.run", "Create a new project with a resumable migration plan and exact legacy archive; advance evidence checkpoints explicitly.",
            _object({"path": _STRING, "imageIds": ids, "previewFingerprint": _ID,
                     "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["path", "previewFingerprint", "name"]), True),
        _op("migration.library.get", "Read migration progress, missing evidence and archived legacy identities.", _object()),
        _op("migration.records.get", "Read a bounded page of exact archived entity records, including unsupported legacy settings and histories.",
            _object({"entity": _ID, "offset": {"type": "integer", "minimum": 0, "default": 0},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 100}}, ["entity"])),
        _op("migration.evidence.list", "Read a bounded page of retained, missing and pending legacy evidence without opening source files.",
            _object({"offset": {"type": "integer", "minimum": 0, "default": 0},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 100}})),
        _op("migration.geometry.get", "Read paged legacy centre/contour records without implying exact instance masks.",
            _object({"imageId": _ID, "variantId": _ID, "offset": {"type": "integer", "minimum": 0, "default": 0},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 100}}, ["imageId"])),
    ]
    for action in ("advance", "pause", "resume", "cancel"):
        ops.append(_op("migration.library." + action, "{} the retained migration between bounded evidence checkpoints.".format(action.capitalize()), _object(), True))
    for entry in ops:
        if entry["name"] in ("migration.library.capture", "migration.library.run"):
            entry["requiresExpectedRevision"] = False
    return ops


def _read_archive(path):
    from _workbench_schema import absolute_path
    from _workbench_packages import _json
    source = absolute_path(path, "path")
    if not source.is_file() or source.stat().st_size > MAX_ARCHIVE:
        fail("invalid-migration-archive", "The archive must be a regular JSON file of at most 64 MiB.")
    raw = source.read_bytes()
    if len(raw) > MAX_ARCHIVE:
        fail("migration-limit", "The archive exceeds 64 MiB.")
    archive = _json(raw, "legacy archive")
    if (not isinstance(archive, dict) or archive.get("schemaVersion") != 1 or archive.get("kind") not in KINDS
            or not isinstance(archive.get("records"), dict) or not isinstance(archive.get("files"), list)):
        fail("invalid-migration-archive", "Expected a version 1 native or Windows library archive with records and file evidence.")
    count = 0
    for table, rows in archive["records"].items():
        if not isinstance(table, str) or not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            fail("invalid-migration-archive", "Each archived entity must contain a list of record objects.")
        count += len(rows)
    if count > LIMITS["records"] or len(archive["files"]) > LIMITS["files"]:
        fail("migration-limit", "The archive exceeds the record or evidence-file limit.", LIMITS)
    return source, raw, archive


def evidence_paths(path):
    """MCP authorizes every referenced source before preview opens those bytes."""
    _, _, archive = _read_archive(path)
    return [entry.get("path") for entry in archive["files"]]


def _identifier(row, *keys):
    value = next((row[key] for key in keys if row.get(key) is not None), None)
    if isinstance(value, dict):
        value = value.get("id")
    return str(value) if value is not None else None


def _legacy_images(archive):
    return archive["records"].get("ImageRecord" if KINDS[archive["kind"]] == "macos" else "images", [])


def _calibration(archive, row):
    batch_id = _identifier(row, "batchId", "batch_id", "batch")
    batches = archive["records"].get("BatchRecord", archive["records"].get("batches", []))
    batch = next((item for item in batches if _identifier(item, "id") == batch_id), {})
    value = row.get("sourcePxPerUm", row.get("source_px_per_um"))
    # The batch setting was the effective measurement calibration in both libraries.
    if batch.get("pxPerUm", batch.get("px_per_um")) is not None:
        value = batch.get("pxPerUm", batch.get("px_per_um"))
    return float(value) if type(value) in (int, float) and math.isfinite(value) and 0 < value <= 1e6 else None


def preview(args):
    from _workbench_schema import absolute_path, WorkbenchError
    from _workbench_store import canonical, file_hash
    import _workbench_imaging as imaging
    source, raw, archive = _read_archive(args["path"])
    rows = _legacy_images(archive)
    lookup = {_identifier(row, "id"): row for row in rows}
    if None in lookup or len(lookup) != len(rows) or any(len(key) > 256 for key in lookup if key is not None):
        fail("invalid-migration-archive", "Legacy image identities must be present and unique.")
    selected = args.get("imageIds", archive.get("selectedImageIds")) or list(lookup)
    if (not isinstance(selected, list) or any(not isinstance(item, str) for item in selected)
            or len(set(selected)) != len(selected) or any(item not in lookup for item in selected)):
        fail("invalid-migration-selection", "Selected image IDs must uniquely name archived images.")
    if len(selected) > LIMITS["images"]:
        fail("migration-capacity", "This project can import at most 1,000 image identities. Select an explicit subset; the complete record archive remains retained.",
             {"selectedImages": len(selected), "maximumImages": LIMITS["images"], "archivedImages": len(rows)})
    files, total, hash_cache = [], len(raw), {}
    for index, entry in enumerate(archive["files"]):
        if not isinstance(entry, dict) or not isinstance(entry.get("role"), str):
            fail("invalid-migration-archive", "Each evidence file needs a path and explicit role.")
        path = absolute_path(entry.get("path"), "evidence path")
        item = {"index": index, "name": path.name, "originalPath": str(path), "role": entry["role"],
                "legacyImageId": _identifier(entry, "imageId"), "required": bool(entry.get("required", False)),
                "status": "pending" if path.is_file() else "missing", "bytes": None, "hash": None}
        if path.is_file():
            size = path.stat().st_size
            if size > MAX_FILE:
                fail("migration-capacity", "An evidence file exceeds the 512 MiB retained-member limit; it cannot be silently omitted.",
                     {"path": str(path), "bytes": size, "maximumBytes": MAX_FILE})
            if str(path) not in hash_cache:
                hash_cache[str(path)] = (file_hash(path), size)
                total += size
                if total > MAX_TOTAL:
                    fail("migration-capacity", "Complete available evidence exceeds the 4 GiB migration storage budget.", LIMITS)
            item["hash"], item["bytes"] = hash_cache[str(path)]
        files.append(item)
    images = []
    for image_id in selected:
        row = lookup[image_id]
        candidates = [item for item in files if item["legacyImageId"] == image_id and item["role"] in ("analysis", "original", "source")]
        candidates.sort(key=lambda item: {"analysis": 0, "original": 1, "source": 2}[item["role"]])
        # An explicitly retained analysis file is authoritative. Missing/unsupported
        # analysis cannot be replaced by a display or unrelated original projection.
        chosen = candidates[0] if candidates else None
        item = {"legacyImageId": image_id, "name": str(row.get("fileName", row.get("file_name", image_id))),
                "status": "missing", "sourceRole": chosen["role"] if chosen else None,
                "sourceFileIndex": chosen["index"] if chosen else None, "geometryKind": "legacy-contours-and-centres",
                "exactMask": False, "pxPerUm": _calibration(archive, row)}
        if chosen is None or chosen["status"] == "missing":
            item["reason"] = "The retained acquisition/analysis source is unavailable; display pixels are not substituted."
        else:
            try:
                item["metadata"] = imaging.inspect_source(chosen["originalPath"])
                item["status"] = "importable"
            except WorkbenchError as exc:
                item.update({"status": "archived-only", "reason": exc.message, "errorCode": exc.code})
        images.append(item)
    counts = {"selectedImages": len(images), "archivedImages": len(rows),
              "importableImages": sum(item["status"] == "importable" for item in images),
              "archivedOnlyImages": sum(item["status"] == "archived-only" for item in images),
              "missingImages": sum(item["status"] == "missing" for item in images),
              "files": len(files), "missingFiles": sum(item["status"] == "missing" for item in files)}
    plan = {"platform": KINDS[archive["kind"]], "sourceDirectory": archive.get("sourceDirectory"),
            "archiveHash": hashlib.sha256(raw).hexdigest(), "selectedImageIds": selected, "images": images,
            "files": files, "counts": counts, "totalBytes": total, "notes": notes(),
            "entities": [{"name": key, "recordCount": len(value)} for key, value in archive["records"].items()]}
    plan["previewFingerprint"] = hashlib.sha256(canonical(plan).encode()).hexdigest()
    if len(canonical(plan).encode()) > 16 * 1024 ** 2:
        fail("migration-capacity", "The frozen migration plan exceeds its 16 MiB metadata budget. No records or file identities were truncated.")
    return {"plan": plan}, raw


def _write_new(path, data):
    from _workbench_store import sync_directory
    if not path.parent.is_dir():
        fail("invalid-path", "The destination parent directory must already exist.")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".legacy-capture-", delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            fail("destination-exists", "Capture never overwrites an existing archive.")
        sync_directory(path.parent)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def capture(request):
    from _workbench_schema import absolute_path
    from _workbench_store import canonical, file_hash, request_hash, utc_now
    args = request["arguments"]
    root, destination = absolute_path(args["sourceDirectory"], "sourceDirectory"), absolute_path(args["destination"], "destination")
    if not root.is_dir():
        fail("legacy-library-not-found", "The legacy source directory is unavailable.")
    receipt = destination.with_name(destination.name + ".capture.json")
    if destination.exists():
        if receipt.is_file() and receipt.stat().st_size <= 65536:
            from _workbench_packages import _json
            saved = _json(receipt.read_bytes(), "capture receipt")
            if saved.get("requestHash") == request_hash(request) and file_hash(destination) == saved.get("result", {}).get("archiveHash"):
                return saved["result"]
        fail("destination-exists", "Use a new archive destination; an unrelated or incomplete capture already exists.")
    if args["platform"] == "macos":
        if sys.platform != "darwin" or _native_helper is None:
            fail("native-helper-required", "Configure --native-helper with the installed macOS application executable before native capture.")
        helper = dict(_native_helper)
        if not Path(helper["path"]).is_file() or file_hash(helper["path"]) != helper["hash"]:
            fail("native-helper-changed", "The configured native helper was replaced; explicitly reconfigure its current executable.")
        argv = [helper["path"], "--workbench-archive-library", "--source-directory", str(root), "--destination", str(destination)]
        for image_id in args.get("selectedImageIds", []):
            argv.extend(["--image-id", image_id])
        with tempfile.TemporaryFile() as output:
            try:
                completed = subprocess.run(argv, stdout=output, stderr=output, timeout=300, check=False)
            except subprocess.TimeoutExpired:
                fail("native-capture-timeout", "Native capture exceeded five minutes. Retained evidence is not deleted; choose a new destination after inspecting it.")
            if completed.returncode != 0:
                output.seek(0)
                fail("native-capture-failed", "The native application could not capture this library.",
                     {"exitCode": completed.returncode, "diagnostic": output.read(8192).decode("utf-8", "replace")})
            output.seek(0)
            response_bytes = output.read(65536)
            for line in reversed(response_bytes.splitlines()):
                try:
                    response = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if isinstance(response, dict) and response.get("ok") and isinstance(response.get("helper"), dict):
                    helper["reported"] = response["helper"]
                    break
        if file_hash(helper["path"]) != helper["hash"]:
            fail("native-helper-changed", "The helper changed while capturing. The archive is retained but is not accepted automatically.")
    else:
        helper = None
        _capture_windows(root, destination, args.get("selectedImageIds"))
    _, raw, archive = _read_archive(str(destination))
    result = {"archivePath": str(destination), "archiveHash": hashlib.sha256(raw).hexdigest(),
              "platform": args["platform"], "imageCount": len(_legacy_images(archive)),
              "recordCount": sum(len(value) for value in archive["records"].values()),
              "helper": helper, "createdAt": utc_now()}
    _write_new(receipt, canonical({"requestHash": request_hash(request), "result": result}).encode())
    return result


def _capture_windows(root, destination, selected):
    from _workbench_store import canonical, utc_now
    database = root / "store.sqlite"
    if not database.is_file():
        fail("legacy-library-not-found", "The selected Windows library has no store.sqlite database.")
    evidence = destination.with_name(destination.stem + "-evidence")
    if evidence.exists():
        fail("destination-exists", "The archive's evidence directory already exists. Choose a new destination.")
    evidence.mkdir()
    snapshot = evidence / "store.sqlite"
    started = time.monotonic()

    def progress(status, remaining, total):
        if total * 4096 > MAX_FILE or time.monotonic() - started > 120:
            fail("migration-capacity", "The read-only database snapshot exceeds its size or two-minute capture bound.")

    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=10) as source:
        with sqlite3.connect(str(snapshot)) as output:
            source.backup(output, pages=256, progress=progress, sleep=0.05)
    records, count, record_bytes = {}, 0, 0
    with sqlite3.connect(snapshot.as_uri() + "?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        tables = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        if "images" not in tables or "batches" not in tables:
            fail("unsupported-legacy-store", "This is not a Windows CellCounter library schema; native SwiftData requires the macOS helper.")
        for table in tables:
            quoted = '"' + table.replace('"', '""') + '"'
            rows = []
            for row in connection.execute("SELECT * FROM " + quoted):
                count += 1
                if count > LIMITS["records"]:
                    fail("migration-limit", "The library exceeds the 100,000 archived-record bound; the consistent database snapshot remains retained.")
                value = {key: {"encoding": "base64", "data": base64.b64encode(value).decode("ascii")} if isinstance(value, bytes) else value
                         for key, value in dict(row).items()}
                record_bytes += len(canonical(value).encode()) + 1
                if record_bytes > MAX_ARCHIVE:
                    fail("migration-limit", "The archived record bytes exceed 64 MiB; the consistent database snapshot remains retained.")
                rows.append(value)
            records[table] = rows
    files = [{"role": "other", "path": str(snapshot), "required": True}]
    for row in records["images"]:
        image_id = str(row["id"])
        if not image_id or Path(image_id).name != image_id or image_id in (".", ".."):
            fail("invalid-legacy-identity", "A legacy image identity cannot name a filesystem path.")
        extension = str(row.get("stored_ext") or Path(row.get("file_name") or "").suffix.lstrip(".") or "png").lower().lstrip(".")
        if not extension.isalnum():
            fail("invalid-legacy-extension", "A legacy stored extension is invalid.")
        display = root / "Images" / (image_id + "." + extension)
        analysis = row.get("analysis_path")
        if analysis:
            analysis_path = Path(analysis)
            if not analysis_path.is_absolute():
                analysis_path = root / analysis_path
            files.append({"imageId": image_id, "role": "analysis", "path": str(analysis_path.resolve())})
            files.append({"imageId": image_id, "role": "display", "path": str(display)})
        else:
            # Without a separately stored scientific plane this is the import
            # raster itself, not a guessed display substitute for missing TIFF.
            files.append({"imageId": image_id, "role": "source", "path": str(display)})
        originals = sorted((root / "Originals").glob(image_id + ".*")) if (root / "Originals").is_dir() else []
        for path in originals:
            if path.is_file():
                files.append({"imageId": image_id, "role": "original", "path": str(path)})
    for row in records.get("model_versions", []):
        value = row.get("checkpoint_path")
        if value:
            path = Path(value)
            files.append({"role": "checkpoint", "path": str(path if path.is_absolute() else root / path)})
    archive = {"schemaVersion": 1, "kind": "cellcounter-windows-library", "sourceDirectory": str(root),
               "createdAt": utc_now(), "records": records, "files": files}
    if selected is not None:
        archive["selectedImageIds"] = selected
    data = canonical(archive).encode()
    if len(data) > MAX_ARCHIVE:
        fail("migration-limit", "The record archive exceeds 64 MiB; the consistent database snapshot remains retained.")
    _write_new(destination, data)


def describe(document):
    migration = document.get("legacyMigration")
    if migration is None:
        return None
    result = {key: copy.deepcopy(migration[key]) for key in ("id", "platform", "status", "counts", "createdAt", "updatedAt", "error", "imageMappings", "notes", "entities") if key in migration}
    units = [*migration["files"], *migration["images"]]
    result["progress"] = {"completed": sum(item.get("checkpointStatus") == "completed" for item in units), "total": len(units)}
    pending_file = next((item for item in migration["files"] if item.get("checkpointStatus") != "completed"), None)
    pending_image = next((item for item in migration["images"] if item.get("checkpointStatus") != "completed"), None)
    result["nextUnit"] = ({"type": "file", "name": pending_file["name"], "path": pending_file["originalPath"],
                           "missing": pending_file["status"] == "missing"} if pending_file else
                          {"type": "image", "name": pending_image["name"], "legacyImageId": pending_image["legacyImageId"]} if pending_image else None)
    result["archiveHash"] = migration["archiveHash"]
    result["evidenceComplete"] = migration["status"] == "completed" and migration["counts"]["missingFiles"] == 0
    result["scientificImportComplete"] = migration["status"] == "completed" and migration["counts"]["importableImages"] == migration["counts"]["selectedImages"]
    missing = [item for item in migration["files"] if item["status"] == "missing"]
    result["missingFiles"] = [{key: item[key] for key in ("name", "role", "legacyImageId", "originalPath")} for item in missing[:100]]
    result["missingFilesTruncated"] = len(missing) > 100
    result["imagePlans"] = [{key: item[key] for key in ("legacyImageId", "name", "status", "sourceRole", "reason", "errorCode", "checkpointStatus") if key in item}
                            for item in migration["images"]]
    return result


def start(request, actor):
    from _workbench_schema import absolute_path
    from _workbench_store import ProjectStore, DB_NAME, utc_now, sync_directory
    root = absolute_path(request["projectPath"], "projectPath")
    if root.exists():
        if (root / DB_NAME).is_file():
            replay = ProjectStore(str(root)).replay(request)
            if replay is not None:
                return replay
        fail("project-exists", "Migration requires a new project directory.")
    if not root.parent.is_dir():
        fail("invalid-path", "The new project parent directory must exist.")
    report, raw = preview(request["arguments"])
    plan = report["plan"]
    if plan["previewFingerprint"] != request["arguments"]["previewFingerprint"]:
        fail("migration-preview-changed", "The archive or source evidence changed. Preview the current archive before importing.")
    now = utc_now()
    migration = {**plan, "id": str(uuid.uuid4()), "status": "pending", "createdAt": now, "updatedAt": now,
                 "imageMappings": [], "archivePath": "artifacts/" + plan["archiveHash"] + ".legacy-archive.json"}
    for item in [*migration["files"], *migration["images"]]:
        item["checkpointStatus"] = "pending"
    document = {"schemaVersion": 1, "id": str(uuid.uuid4()), "name": request["arguments"]["name"], "revision": 0,
                "createdAt": now, "updatedAt": now, "images": [], "legacyMigration": migration,
                "history": [{"revision": 0, "operation": request["operation"], "requestId": request["requestId"],
                             "actor": actor, "at": now, "arguments": request["arguments"]}]}
    response = {"schemaVersion": 1, "ok": True, "operation": request["operation"], "requestId": request["requestId"], "revision": 0,
                "result": {"project": {key: document[key] for key in ("id", "name", "revision")}, "migration": describe(document)}}
    temporary = Path(tempfile.mkdtemp(dir=root.parent, prefix=".cellcounter-migration-"))
    try:
        stage = temporary / "project"
        store, _ = ProjectStore.create(str(stage), document, request, response)
        stored, checksum = store.put_bytes(raw, ".legacy-archive.json")
        if stored != migration["archivePath"] or checksum != migration["archiveHash"]:
            fail("migration-archive-changed", "The exact archive retention identity is inconsistent.")
        try:
            root.mkdir()
        except FileExistsError:
            fail("project-exists", "Another operation created the migration destination.")
        os.rename(stage / "artifacts", root / "artifacts")
        os.rename(stage / DB_NAME, root / DB_NAME)
        sync_directory(root)
        sync_directory(root.parent)
        return response
    finally:
        shutil.rmtree(temporary)


def execute(store, document, operation, args, revision):
    from _workbench_schema import WorkbenchError
    from _workbench_store import utc_now
    migration = document.get("legacyMigration")
    if migration is None:
        if operation == "migration.library.get":
            return {"migration": None}
        fail("migration-not-found", "This project has no retained legacy migration.")
    if operation == "migration.library.get":
        return {"migration": describe(document)}
    if operation == "migration.geometry.get":
        return geometry(store, document, args)
    if operation in ("migration.records.get", "migration.evidence.list"):
        from _workbench_packages import _json
        from _workbench_store import canonical
        if operation == "migration.evidence.list":
            rows = migration["files"]
        else:
            archive = _json(store.verify_artifact(migration["archivePath"], migration["archiveHash"]).read_bytes(), "legacy archive")
            rows = archive["records"].get(args["entity"])
            if rows is None:
                fail("legacy-entity-not-found", "Select an entity name from migration.library.get.entities.")
        offset, limit = args.get("offset", 0), args.get("limit", 100)
        page = copy.deepcopy(rows[offset:offset + limit])
        if len(canonical(page).encode()) > 8 * 1024 ** 2:
            fail("legacy-response-limit", "This record page exceeds 8 MiB. Request fewer records; exact bytes remain retained.")
        return {"records" if operation == "migration.records.get" else "files": page,
                "total": len(rows), "offset": offset, "nextOffset": offset + len(page) if offset + len(page) < len(rows) else None,
                "archiveHash": migration["archiveHash"]}
    action = operation.rsplit(".", 1)[1]
    if action == "pause":
        if migration["status"] not in ("pending", "running"):
            fail("migration-state", "Only a pending or running migration can pause.")
        migration["status"] = "paused"
    elif action == "resume":
        if migration["status"] not in ("paused", "failed"):
            fail("migration-state", "Only a paused or failed migration can resume. Restore changed source bytes first.")
        migration["status"] = "pending"
        migration.pop("error", None)
    elif action == "cancel":
        if migration["status"] in ("completed", "cancelled"):
            fail("migration-state", "This migration is already terminal.")
        migration["status"] = "cancelled"
    elif action == "advance":
        if migration["status"] not in ("pending", "running"):
            fail("migration-state", "Resume a paused/failed migration explicitly before advancing.")
        migration["status"] = "running"
        try:
            _advance(store, document, migration, revision)
            if describe(document)["nextUnit"] is None:
                migration["status"] = "completed"
        except (WorkbenchError, OSError, ValueError) as exc:
            migration["status"] = "failed"
            migration["error"] = {"code": exc.code if isinstance(exc, WorkbenchError) else "migration-io-error", "message": str(exc)}
    else:
        fail("unknown-operation", "Unsupported migration operation.")
    migration["updatedAt"] = utc_now()
    return {"migration": describe(document)}


def _advance(store, document, migration, revision):
    from _workbench_store import utc_now
    import _workbench_imaging as imaging
    pending = next((item for item in migration["files"] if item["checkpointStatus"] != "completed"), None)
    if pending is not None:
        if pending["status"] != "missing":
            path = "artifacts/" + pending["hash"] + ".legacy-evidence.bin"
            store.retain_verified_file(pending["originalPath"], path, pending["hash"], maximum_bytes=MAX_FILE)
            pending["artifactPath"] = path
        pending["checkpointStatus"] = "completed"
        pending["completedRevision"] = revision
        return
    pending = next((item for item in migration["images"] if item["checkpointStatus"] != "completed"), None)
    if pending is None:
        return
    image_id = None
    if pending["status"] == "importable":
        if len(document["images"]) >= LIMITS["images"]:
            fail("migration-capacity", "The project image limit was reached. No source records or evidence have been dropped.")
        file = migration["files"][pending["sourceFileIndex"]]
        source = store.verify_artifact(file["artifactPath"], file["hash"])
        suffix = Path(file["originalPath"]).suffix.lower()
        retained = "artifacts/" + file["hash"] + suffix
        # Both names are immutable content-addressed artifacts. A hard link
        # provides the decoder's original suffix without a second full copy.
        try:
            os.link(source, store.root / retained)
        except FileExistsError:
            store.verify_artifact(retained, file["hash"])
        metadata = imaging.inspect_source(store.root / retained)
        if metadata != pending["metadata"]:
            fail("migration-source-changed", "The source metadata changed from the frozen migration preview.")
        image_id = str(uuid.uuid4())
        scale = pending["pxPerUm"] if pending["pxPerUm"] is not None else metadata.get("metadataPxPerUm")
        if pending["pxPerUm"] is not None:
            metadata["voxelSizeUm"]["x"] = metadata["voxelSizeUm"]["y"] = 1 / scale
        document["images"].append({**metadata, "id": image_id, "name": pending["name"], "sourcePath": retained,
            "sourceHash": file["hash"], "sourceBytes": file["bytes"], "pxPerUm": scale, "importedAt": utc_now(),
            "calibrationSource": "legacy-effective" if pending["pxPerUm"] is not None else "metadata" if scale else "unknown",
            "importedFrom": file["originalPath"], "undoStack": [],
            "legacyOrigin": {"migrationId": migration["id"], "legacyImageId": pending["legacyImageId"],
                             "archiveHash": migration["archiveHash"], "sourceRole": file["role"], "exactMask": False,
                             "geometryKind": "legacy-contours-and-centres"}})
    migration["imageMappings"].append({"legacyImageId": pending["legacyImageId"], "imageId": image_id,
                                       "status": pending["status"], "name": pending["name"]})
    pending["checkpointStatus"] = "completed"
    pending["completedRevision"] = revision


def geometry(store, document, args):
    from _workbench_packages import _json
    from _workbench_store import canonical
    migration = document["legacyMigration"]
    mapping = next((item for item in migration["imageMappings"] if item["imageId"] == args["imageId"] or item["legacyImageId"] == args["imageId"]), None)
    if mapping is None:
        fail("legacy-image-not-found", "No migrated or archived image matches this identity.")
    path = store.verify_artifact(migration["archivePath"], migration["archiveHash"])
    archive = _json(path.read_bytes(), "retained legacy archive")
    rows = archive["records"]
    native = migration["platform"] == "macos"
    detections = rows.get("DetectionRecord" if native else "detections", [])
    images = _legacy_images(archive)
    image = next((item for item in images if _identifier(item, "id") == mapping["legacyImageId"]), {})
    detection_id = _identifier(image, "detectionId", "detection")
    variants = rows.get("SegmentationVariantRecord", [])
    if args.get("variantId"):
        selected = next((row for row in variants if _identifier(row, "id") == args["variantId"] and
                         _identifier(row, "imageId", "image") == mapping["legacyImageId"]), None)
    else:
        selected = next((row for row in detections if _identifier(row, "imageId", "image_id", "image") == mapping["legacyImageId"] or
                         (detection_id is not None and _identifier(row, "id") == detection_id)), None)
    cells = []
    if selected is not None:
        value = selected.get("cellsData" if native else "cells_json")
        if isinstance(value, dict) and value.get("encoding") == "base64":
            value = base64.b64decode(value["data"], validate=True)
        if isinstance(value, (str, bytes)):
            cells = _json(value, "legacy cell records")
        if not isinstance(cells, list):
            fail("invalid-legacy-geometry", "Legacy cells are not a JSON list; exact bytes remain in the archive.")
    offset, limit = args.get("offset", 0), args.get("limit", 100)
    page = cells[offset:offset + limit]
    if len(canonical(page).encode()) > 8 * 1024 ** 2:
        fail("legacy-response-limit", "The requested geometry page exceeds 8 MiB. Request fewer records.")
    return {"legacyImageId": mapping["legacyImageId"], "imageId": mapping["imageId"], "geometryKind": "legacy-contours-and-centres",
            "exactMask": False, "cells": page, "total": len(cells), "offset": offset,
            "nextOffset": offset + len(page) if offset + len(page) < len(cells) else None,
            "recordId": _identifier(selected or {}, "id"), "archiveHash": migration["archiveHash"],
            "notes": ["Cell fields retain original units and detector conventions. These are archived geometry records, not canonical raster measurements or approved references."]}


def artifact_references(document):
    migration = document.get("legacyMigration")
    if migration is None:
        return {}
    refs = {migration["archivePath"]: migration["archiveHash"]}
    for item in migration["files"]:
        if item.get("artifactPath"):
            refs[item["artifactPath"]] = item["hash"]
    return refs


def validate_document(document):
    migration = document.get("legacyMigration")
    if migration is None:
        return
    if (not isinstance(migration, dict) or migration.get("platform") not in KINDS.values()
            or migration.get("status") not in ("pending", "running", "paused", "failed", "cancelled", "completed")
            or not isinstance(migration.get("files"), list) or len(migration["files"]) > LIMITS["files"]
            or not isinstance(migration.get("images"), list) or len(migration["images"]) > LIMITS["images"]):
        fail("invalid-package", "Retained migration metadata is invalid or exceeds its limits.")
    images = image_index(document)
    for item in migration.get("imageMappings", []):
        if item.get("imageId") is not None:
            image = images.get(item["imageId"])
            if image is None or image.get("legacyOrigin", {}).get("legacyImageId") != item.get("legacyImageId"):
                fail("invalid-package", "A retained migration image mapping is inconsistent.")
    for item in migration["files"]:
        if item.get("checkpointStatus") == "completed" and item.get("status") != "missing" and not item.get("artifactPath"):
            fail("invalid-package", "Completed migration evidence lacks its retained artifact.")
