"""Portable, non-executable display presets with retained import/export evidence."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import stat
import uuid

MAX_FILE_BYTES = 1024 * 1024
MAX_IMPORTS = 1000
FORMAT = "cellcounter-display-preset"
FORMATS = [{"id": "preset-json", "name": "Display preset (JSON)", "extension": "json",
            "mediaType": "application/json",
            "description": "Portable channel colors, contrast settings and display bounds with exact version provenance."}]


def catalogue():
    return {"formats": copy.deepcopy(FORMATS)}


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    return [
        _op("display.preset.export.catalogue", "Describe portable display-preset exports.", _object(), project=False),
        _op("display.preset.export", "Retain and publish one exact display-preset version without overwriting files.",
            _object({"presetId": _ID, "version": {"type": "integer", "minimum": 1},
                     "format": {"type": "string", "enum": ["preset-json"]}, "destination": _STRING},
                    ["presetId", "format", "destination"]), True),
        _op("display.preset.import.preview", "Inspect a portable display preset without creating or applying it.",
            _object({"path": _STRING}, ["path"])),
        _op("display.preset.import.run", "Create a new local display preset from the exact previewed file; no image is changed.",
            _object({"path": _STRING, "previewFingerprint": {"type": "string", "minLength": 64, "maxLength": 64},
                     "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["path", "previewFingerprint"]), True),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _definition(preset):
    import _workbench_display_presets as presets
    return presets.normalize_definition({key: copy.deepcopy(preset[key]) for key in (
        "name", "notes", "channels", "maxSize", "maxDimension", "intensityUnits")})


def _encoded(value):
    from _workbench_store import canonical
    return (canonical(value) + "\n").encode("utf-8")


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def prepare_export(store, document, arguments, revision, request_id, actor):
    from _workbench_exports import _destination, _stage_publication, MAX_EXPORTS
    from _workbench_store import utc_now
    import _workbench_display_presets as presets
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "A project retains at most 1,000 built-in exports.")
    destination = _destination(arguments, FORMATS[0])
    preset = presets.get(document, arguments["presetId"], arguments.get("version"))
    definition = _definition(preset)
    definition_hash = _digest(definition)
    origin = {"projectId": document["id"], "presetId": preset["id"],
              "version": preset["version"], "presetHash": preset["hash"]}
    provenance = {
        "schemaVersion": 1, "engineVersion": "display-preset-io-1", "exportId": str(uuid.uuid4()),
        "format": "preset-json", "projectId": document["id"], "sourceRevision": document["revision"],
        "exportRevision": revision, "createdAt": utc_now(), "requestId": request_id,
        "actor": copy.deepcopy(actor), "origin": origin, "definitionSha256": definition_hash,
        "displayOnly": True,
        "notes": ["Channel identities are zero-based indices; fluorophore equivalence is not inferred.",
                  "Automatic windows remain automatic. Fixed windows retain their source-intensity units.",
                  "Import creates a new local preset; applying and rendering it are separate actions."],
    }
    provenance_path, provenance_hash = store.put_bytes(_encoded(provenance), ".display-preset-provenance.json")
    definition_path, retained_hash = store.put_bytes(_encoded(definition), ".display-preset-definition.json")
    contents = _encoded({"schemaVersion": 1, "format": FORMAT, "preset": definition,
                         "definitionSha256": definition_hash, "origin": origin,
                         "provenance": provenance, "provenanceSha256": provenance_hash})
    if len(contents) > MAX_FILE_BYTES:
        fail("preset-export-limit", "The display preset exceeds the 1 MiB interchange budget.")
    file_path, checksum = store.put_bytes(contents, ".display-preset-export.json")
    item = {
        "exportId": provenance["exportId"], "kind": "display-preset", "presetId": preset["id"],
        "presetVersion": preset["version"], "presetHash": preset["hash"], "format": "preset-json",
        "createdAt": provenance["createdAt"], "revision": revision,
        "filePath": file_path, "fileHash": checksum, "provenancePath": provenance_path,
        "provenanceHash": provenance_hash, "reportPath": definition_path, "reportHash": retained_hash,
        "destination": str(destination), "mediaType": FORMATS[0]["mediaType"], "bytes": len(contents),
    }
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {"exportId": item["exportId"], "destination": str(destination), "sha256": checksum,
            "format": "preset-json", "mediaType": FORMATS[0]["mediaType"], "bytes": len(contents),
            "presetId": preset["id"], "version": preset["version"], "provenance": provenance,
            "provenanceSha256": provenance_hash}, publish, temporary, publication


def _read_file(value):
    from _workbench_schema import absolute_path
    path = absolute_path(value, "path")
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0))
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE_BYTES:
            fail("invalid-preset-file", "Choose a regular display-preset JSON file no larger than 1 MiB.")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            data = stream.read(MAX_FILE_BYTES + 1)
            after = os.fstat(stream.fileno())
        if len(data) > MAX_FILE_BYTES or (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns) or len(data) != after.st_size:
            fail("preset-file-changed", "The preset file changed while being read. Preview it again.")
    except OSError as exc:
        fail("invalid-preset-file", f"Cannot read the selected preset: {str(exc)[:300]}")
    finally:
        if descriptor is not None:
            os.close(descriptor)

    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                fail("invalid-preset-file", "The preset JSON contains a duplicate field.")
            result[key] = item
        return result

    def constant(value):
        fail("invalid-preset-file", "The preset JSON contains a non-finite number.")

    try:
        parsed = json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, UnicodeError, RecursionError):
        fail("invalid-preset-file", "The selected file is not bounded UTF-8 preset JSON.")
    return path, data, parsed


def _validate_file(parsed):
    from _workbench_schema import _object, _ID, validate_value, WorkbenchError
    import _workbench_display_presets as presets
    fields = {"schemaVersion", "format", "preset", "definitionSha256", "origin", "provenance", "provenanceSha256"}
    if not isinstance(parsed, dict) or set(parsed) != fields or type(parsed.get("schemaVersion")) is not int or parsed["schemaVersion"] != 1 or parsed.get("format") != FORMAT:
        fail("invalid-preset-file", "Choose a CellCounter display-preset JSON export with schema version 1.")
    try:
        definition = presets.normalize_definition(parsed["preset"])
        validate_value(parsed["origin"], _object({"projectId": _ID, "presetId": _ID,
                       "version": {"type": "integer", "minimum": 1},
                       "presetHash": {"type": "string", "minLength": 64, "maxLength": 64}},
                      ["projectId", "presetId", "version", "presetHash"]))
    except (WorkbenchError, TypeError, KeyError):
        fail("invalid-preset-file", "The preset definition or origin has invalid fields.")
    if not re.fullmatch(r"[0-9a-f]{64}", parsed["origin"]["presetHash"]):
        fail("invalid-preset-file", "The original preset hash must be a lowercase SHA256 digest.")
    if definition != parsed["preset"] or _digest(definition) != parsed["definitionSha256"]:
        fail("invalid-preset-file", "The preset definition does not match its recorded digest.")
    provenance = parsed["provenance"]
    if not isinstance(provenance, dict) or provenance.get("origin") != parsed["origin"] or provenance.get("definitionSha256") != parsed["definitionSha256"]:
        fail("invalid-preset-file", "The preset provenance does not match its definition and origin.")
    try:
        if hashlib.sha256(_encoded(provenance)).hexdigest() != parsed["provenanceSha256"]:
            fail("invalid-preset-file", "The preset provenance digest is inconsistent.")
    except (ValueError, TypeError, RecursionError):
        fail("invalid-preset-file", "The preset provenance contains invalid values.")
    return definition


def preview(document, arguments):
    path, data, parsed = _read_file(arguments["path"])
    definition = _validate_file(parsed)
    checksum = hashlib.sha256(data).hexdigest()
    fingerprint = _digest({"projectId": document["id"], "revision": document["revision"],
                           "fileSha256": checksum, "definition": definition})
    result = {
        "source": {"name": path.name, "sha256": checksum, "bytes": len(data), "format": FORMAT},
        "preset": definition, "origin": copy.deepcopy(parsed["origin"]), "previewFingerprint": fingerprint,
        "notes": ["Import creates a new local preset and does not apply it to any image.",
                  "Channel indices and fixed intensity units are checked against the target when applying settings.",
                  "Foreign origin metadata is retained as an attribution claim; digests establish consistency, not authorship."],
    }
    return result, data


def execute(store, document, operation, arguments, revision, actor):
    import _workbench_display_presets as presets
    from _workbench_store import utc_now
    result, data = preview(document, arguments)
    if operation == "display.preset.import.preview":
        return result
    if operation != "display.preset.import.run":
        fail("unknown-operation", "The display-preset interchange operation is unknown.")
    if result["previewFingerprint"] != arguments["previewFingerprint"]:
        fail("stale-preset-preview", "The preset file or project changed after preview. Preview it again before importing.")
    if len(document.get("displayPresetImports", [])) >= MAX_IMPORTS:
        fail("preset-import-limit", "A project retains at most 1,000 display-preset imports.")
    definition = copy.deepcopy(result["preset"])
    if "name" in arguments:
        definition["name"] = arguments["name"]
    saved = presets.execute(store, document, "display.preset.save", definition, revision, actor)
    file_path, checksum = store.put_bytes(data, ".display-preset-import.json")
    import_id = str(uuid.uuid4())
    document.setdefault("displayPresetImports", []).append({
        "id": import_id, "presetId": saved["preset"]["id"], "version": saved["preset"]["version"],
        "createdAt": utc_now(), "revision": revision, "actor": copy.deepcopy(actor),
        "sourceName": result["source"]["name"], "filePath": file_path, "fileHash": checksum,
        "origin": result["origin"], "previewFingerprint": result["previewFingerprint"],
    })
    return {"preset": presets.get(document, saved["preset"]["id"], saved["preset"]["version"]),
            "source": result["source"], "importId": import_id}


def artifact_references(document):
    return {item["filePath"]: item["fileHash"] for item in document.get("displayPresetImports", [])}
