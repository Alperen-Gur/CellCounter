"""Versioned project display settings, independent of scientific image selection."""
from __future__ import annotations

from _workbench_indexed import RecordList

import copy
import hashlib
import re
import uuid

MAX_PRESETS = 100
MAX_VERSIONS = 1000
_DEFINITION_FIELDS = ("name", "notes", "channels", "maxSize", "maxDimension", "intensityUnits")
_VERSION_FIELDS = ("id", "version", *_DEFINITION_FIELDS, "createdAt", "createdRevision", "actor")


def mapping_schema():
    from _workbench_schema import _object
    index = {"type": "integer", "minimum": 0, "maximum": 31}
    return {"type": "array", "minItems": 1, "maxItems": 8,
            "items": _object({"source": index, "target": index}, ["source", "target"])}


def reference_schema():
    from _workbench_schema import _ID, _object
    return _object({
        "id": _ID, "version": {"type": "integer", "minimum": 1, "maximum": MAX_VERSIONS},
        "hash": {"type": "string", "minLength": 64, "maxLength": 64},
        "name": {"type": "string", "minLength": 1, "maxLength": 200},
        "channelMapping": mapping_schema(),
    }, ["id", "version", "hash", "name", "channelMapping"])


def definition_schema():
    from _workbench_schema import _object
    import _workbench_composite as composite
    return _object({
        "name": {"type": "string", "minLength": 1, "maxLength": 200},
        "notes": {"type": "string", "minLength": 0, "maxLength": 4000},
        "channels": composite.argument_schema()["properties"]["channels"],
        "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048, "default": 768},
        "maxDimension": {"type": "integer", "minimum": 16, "maximum": 128, "default": 128},
        "intensityUnits": {"type": "string", "enum": ["raw-source", "processed-source"]},
    }, ["name", "channels", "intensityUnits"])


def operations():
    from _workbench_schema import _ID, _object, _op
    save = definition_schema()
    save["properties"]["presetId"] = _ID
    identity = {"presetId": _ID,
                "version": {"type": "integer", "minimum": 1, "maximum": MAX_VERSIONS}}
    return [
        _op("display.preset.save", "Append an immutable named version of display-only channel settings.", save, True),
        _op("display.preset.list", "List current display presets, optionally including archived presets.",
            _object({"includeArchived": {"type": "boolean", "default": False}})),
        _op("display.preset.get", "Read an exact saved display preset version and its provenance.",
            _object(identity, ["presetId"])),
        _op("display.preset.archive", "Archive or restore a display preset without deleting historical versions.",
            _object({"presetId": _ID, "archived": {"type": "boolean"}}, ["presetId", "archived"]), True),
        _op("display.preset.resolve", "Resolve saved channel indices against an image, enforcing display-unit compatibility.",
            _object({**identity, "imageId": _ID, "channelMapping": mapping_schema()}, ["presetId", "imageId"])),
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def limits():
    return {"presets": MAX_PRESETS, "versions": MAX_VERSIONS, "channels": 8}


def normalize_definition(arguments):
    from _workbench_schema import validate_value
    import _workbench_composite as composite
    validate_value(arguments, definition_schema())
    return {
        "name": arguments["name"].strip(), "notes": arguments.get("notes", "").strip(),
        "channels": composite._channel_settings({"channels": 32}, arguments["channels"]),
        "maxSize": arguments.get("maxSize", 768), "maxDimension": arguments.get("maxDimension", 128),
        "intensityUnits": arguments["intensityUnits"],
    }


def _hash(version):
    from _workbench_store import canonical
    value = {"schemaVersion": 1, **{key: version[key] for key in _VERSION_FIELDS}}
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def _records(document):
    records = document.get("displayPresets", [])
    if (not isinstance(records, (list, RecordList)) or len(records) > MAX_PRESETS
            or any(not isinstance(item, dict) or not isinstance(item.get("versions"), (list, RecordList)) for item in records)):
        fail("invalid-display-presets", "The display preset catalogue exceeds its supported bounds.")
    return records


def _record(document, preset_id):
    record = next((item for item in _records(document) if item.get("id") == preset_id), None)
    if record is None:
        fail("preset-not-found", "The display preset is unavailable. Refresh the preset catalogue.", {"presetId": preset_id})
    if not isinstance(record.get("versions"), (list, RecordList)) or not 1 <= len(record["versions"]) <= MAX_VERSIONS:
        fail("invalid-display-presets", "The display preset has invalid version history.")
    return record


def _version(record, version=None):
    number = len(record["versions"]) if version is None else version
    if type(number) is not int or not 1 <= number <= len(record["versions"]):
        fail("preset-version-not-found", "Choose an existing display preset version.",
             {"presetId": record["id"], "latestVersion": len(record["versions"])})
    value = record["versions"][number - 1]
    if value.get("id") != record["id"] or value.get("version") != number or value.get("hash") != _hash(value):
        fail("preset-integrity", "The saved display preset version failed its integrity check.")
    return value


def get(document, preset_id, version=None, *, include_import=True):
    record = _record(document, preset_id)
    value = copy.deepcopy(_version(record, version))
    result = {**value, "archived": record.get("archived", False),
              "latestVersion": len(record["versions"]), "versionCount": len(record["versions"])}
    if include_import:
        imported = next((item for item in document.get("displayPresetImports", [])
                         if item["presetId"] == preset_id and item["version"] == value["version"]), None)
        if imported:
            result["importOrigin"] = {"importId": imported["id"], "sourceName": imported["sourceName"],
                                      "fileHash": imported["fileHash"], "origin": copy.deepcopy(imported["origin"])}
    return result


def describe(document, preset_id):
    value = get(document, preset_id, include_import=False)
    channels = value.pop("channels")
    value.pop("actor", None)
    value.update({"channelCount": len(channels), "hasFixedWindows": any("lower" in item for item in channels)})
    return value


def inspect_presets(document, include_archived=True):
    return [describe(document, item["id"]) for item in _records(document)
            if include_archived or not item.get("archived", False)]


def _mapping(channels, supplied):
    from _workbench_schema import validate_value
    sources = [item["channel"] for item in channels]
    if supplied is None:
        return [{"source": channel, "target": channel} for channel in sources]
    validate_value(supplied, mapping_schema(), "channelMapping")
    found = {}
    for entry in supplied:
        if entry["source"] in found:
            fail("invalid-channel-mapping", "Map each saved channel exactly once.")
        found[entry["source"]] = entry["target"]
    if set(found) != set(sources):
        fail("invalid-channel-mapping", "An explicit mapping must include every saved channel and no additional channels.",
             {"sourceChannels": sources})
    if len(set(found.values())) != len(found):
        fail("invalid-channel-mapping", "Distinct saved channels must map to distinct target channels.")
    return [{"source": channel, "target": found[channel]} for channel in sources]


def resolve(document, image, arguments):
    import _workbench_composite as composite
    preset = get(document, arguments["presetId"], arguments.get("version"))
    mapping = _mapping(preset["channels"], arguments.get("channelMapping"))
    if any(item["target"] >= image["channels"] for item in mapping):
        fail("preset-channel-unavailable", "This image lacks a required channel. Supply an explicit channel mapping or choose another preset.",
             {"availableChannels": image["channels"], "sourceChannels": [item["source"] for item in mapping]})
    target_units = "processed-source" if image.get("derivation") else "raw-source"
    warnings = []
    if target_units != preset["intensityUnits"]:
        if any("lower" in item for item in preset["channels"]):
            fail("preset-intensity-units", "Fixed display windows cannot be transferred between raw and processed intensities. Save a new preset with automatic windows or limits chosen for the target units.",
                 {"sourceIntensityUnits": preset["intensityUnits"], "targetIntensityUnits": target_units})
        warnings.append("The preset and image use different intensity units. Automatic windows will be recalculated from the selected source; no fixed limits are transferred.")
    if preset["archived"]:
        warnings.append("This preset is archived. Its exact historical version remains available for explicit reuse.")
    warnings.append("Channel mappings use numeric indices; fluorophore or channel-name equivalence is not inferred.")
    mapped = [{**copy.deepcopy(channel), "channel": item["target"]}
              for channel, item in zip(preset["channels"], mapping)]
    mapped = composite._channel_settings(image, mapped)
    reference = {"id": preset["id"], "version": preset["version"], "hash": preset["hash"],
                 "name": preset["name"], "channelMapping": mapping}
    return {
        "settings": {"channels": mapped, "maxSize": preset["maxSize"], "maxDimension": preset["maxDimension"],
                     "intensityUnits": target_units},
        "presetRef": reference,
        "compatibility": {"compatible": True, "sourceIntensityUnits": preset["intensityUnits"],
                          "targetIntensityUnits": target_units, "warnings": warnings},
        "notes": ["Resolving a preset changes no images, analysis settings or display state.",
                  "Automatic window omission is retained; rendering computes the effective limits for its plane or volume."],
    }


def bind_render(document, image, arguments, kind):
    """Accept a preset claim only when the exact retained settings were applied."""
    import _workbench_composite as composite
    from _workbench_schema import validate_value
    reference = arguments.get("presetRef")
    if reference is None:
        return None
    if document is None:
        fail("preset-context-required", "A project snapshot is required to resolve display preset provenance.")
    validate_value(reference, reference_schema(), "presetRef")
    resolved = resolve(document, image, {"presetId": reference["id"], "version": reference["version"],
                                        "channelMapping": reference["channelMapping"]})
    expected = resolved["presetRef"]
    if reference["hash"] != expected["hash"] or reference["name"] != expected["name"]:
        fail("preset-reference-mismatch", "The display preset reference does not identify the retained version. Resolve it again.")
    normalized = composite._channel_settings(image, arguments["channels"])
    bound = "maxDimension" if kind == "volume" else "maxSize"
    default = 128 if kind == "volume" else 768
    if normalized != resolved["settings"]["channels"] or arguments.get(bound, default) != resolved["settings"][bound]:
        fail("preset-settings-mismatch", "Display settings differ from the referenced preset. Resolve and apply that version, or omit presetRef for edited settings.")
    return {"presetRef": expected, "presetCompatibility": resolved["compatibility"]}


def execute(store, document, operation, arguments, revision, actor):
    from _workbench_store import utc_now
    if operation == "display.preset.list":
        return {"presets": inspect_presets(document, arguments.get("includeArchived", False)), "limits": limits()}
    if operation == "display.preset.get":
        return {"preset": get(document, arguments["presetId"], arguments.get("version"))}
    if operation == "display.preset.resolve":
        from _workbench_core import _image
        return resolve(document, _image(document, arguments["imageId"]), arguments)
    if operation == "display.preset.archive":
        record = _record(document, arguments["presetId"])
        record.update({"archived": arguments["archived"], "archiveUpdatedAt": utc_now(),
                       "archiveRevision": revision, "archiveActor": copy.deepcopy(actor)})
        return {"preset": get(document, record["id"])}
    if operation != "display.preset.save":
        fail("unknown-operation", "The display preset operation is unavailable.")
    definition = normalize_definition({key: value for key, value in arguments.items() if key != "presetId"})
    records = _records(document)
    if sum(len(item["versions"]) for item in records) >= MAX_VERSIONS:
        fail("preset-version-limit", "The project retains at most 1,000 display preset versions.")
    preset_id = arguments.get("presetId")
    record = _record(document, preset_id) if preset_id is not None else None
    if record is not None and record.get("archived", False):
        fail("preset-archived", "Unarchive this display preset before saving another version.")
    if record is None:
        if len(records) >= MAX_PRESETS:
            fail("preset-limit", "The project retains at most 100 display preset identities, including archived presets.")
        record = {"id": str(uuid.uuid4()), "archived": False, "versions": []}
    value = {"id": record["id"], "version": len(record["versions"]) + 1, **definition,
             "createdAt": utc_now(), "createdRevision": revision, "actor": copy.deepcopy(actor)}
    value["hash"] = _hash(value)
    record["versions"].append(value)
    if preset_id is None:
        document.setdefault("displayPresets", []).append(record)
    return {"preset": get(document, record["id"])}


def validate_document(document):
    """Validate retained definitions and immutable hashes before package restoration."""
    from _workbench_schema import _ID, _object, validate_value
    records = _records(document)
    if sum(len(item.get("versions", [])) for item in records if isinstance(item, dict)) > MAX_VERSIONS:
        fail("invalid-display-presets", "The package exceeds 1,000 display preset versions.")
    actor_schema = _object({"kind": {"type": "string", "enum": ["human", "agent", "cli", "gui", "api", "mcp", "test"]},
                            "name": {"type": "string", "minLength": 1, "maxLength": 200}}, ["kind", "name"])
    version_schema = definition_schema()
    version_schema["properties"].update({
        "id": _ID, "version": {"type": "integer", "minimum": 1, "maximum": MAX_VERSIONS},
        "hash": {"type": "string", "minLength": 64, "maxLength": 64},
        "createdAt": {"type": "string", "minLength": 1, "maxLength": 100},
        "createdRevision": {"type": "integer", "minimum": 0}, "actor": actor_schema,
    })
    version_schema["required"] = [*_VERSION_FIELDS, "hash"]
    record_schema = _object({
        "id": _ID, "archived": {"type": "boolean"},
        "versions": {"type": "array", "items": version_schema, "minItems": 1, "maxItems": MAX_VERSIONS},
        "archiveUpdatedAt": {"type": "string", "minLength": 1, "maxLength": 100},
        "archiveRevision": {"type": "integer", "minimum": 0}, "archiveActor": actor_schema,
    }, ["id", "archived", "versions"])
    identities = set()
    for record in records:
        validate_value(record, record_schema, "displayPresets")
        if record["id"] in identities:
            fail("invalid-display-presets", "Display preset identities must be unique.")
        identities.add(record["id"])
        for number, value in enumerate(record["versions"], 1):
            normalized = normalize_definition({key: value[key] for key in _DEFINITION_FIELDS})
            if any(value[key] != normalized[key] for key in _DEFINITION_FIELDS):
                fail("invalid-display-presets", "Retained display settings must be in canonical form.")
            if not re.fullmatch(r"[0-9a-f]{64}", value["hash"]):
                fail("preset-integrity", "The retained display preset hash is invalid.")
            _version(record, number)
    imports = document.get("displayPresetImports", [])
    if not isinstance(imports, (list, RecordList)) or len(imports) > 1000:
        fail("invalid-display-presets", "The package exceeds the display-preset import limit.")
    hash_schema = {"type": "string", "minLength": 64, "maxLength": 64}
    import_schema = _object({
        "id": _ID, "presetId": _ID, "version": {"type": "integer", "minimum": 1, "maximum": 1},
        "createdAt": {"type": "string", "minLength": 1, "maxLength": 100},
        "revision": {"type": "integer", "minimum": 0}, "actor": actor_schema,
        "sourceName": {"type": "string", "minLength": 1, "maxLength": 1024},
        "filePath": {"type": "string", "minLength": 1, "maxLength": 4096}, "fileHash": hash_schema,
        "previewFingerprint": hash_schema,
        "origin": _object({"projectId": _ID, "presetId": _ID,
                           "version": {"type": "integer", "minimum": 1}, "presetHash": hash_schema},
                          ["projectId", "presetId", "version", "presetHash"]),
    }, ["id", "presetId", "version", "createdAt", "revision", "actor", "sourceName", "filePath", "fileHash", "previewFingerprint", "origin"])
    import_ids, imported_versions = set(), set()
    for imported in imports:
        validate_value(imported, import_schema, "displayPresetImports")
        identity = (imported["presetId"], imported["version"])
        if imported["id"] in import_ids or identity in imported_versions:
            fail("invalid-display-presets", "Preset imports must identify distinct local versions and import records.")
        import_ids.add(imported["id"])
        imported_versions.add(identity)
        value = get(document, *identity, include_import=False)
        if value["createdRevision"] != imported["revision"] or value["actor"] != imported["actor"]:
            fail("invalid-display-presets", "The preset import does not identify the version created by that operation.")
        for checksum in (imported["fileHash"], imported["previewFingerprint"], imported["origin"]["presetHash"]):
            if not re.fullmatch(r"[0-9a-f]{64}", checksum):
                fail("invalid-display-presets", "A retained preset import checksum is invalid.")
        if imported["filePath"] != f"artifacts/{imported['fileHash']}.display-preset-import.json":
            fail("invalid-display-presets", "The retained preset import source does not match its immutable artifact identity.")
