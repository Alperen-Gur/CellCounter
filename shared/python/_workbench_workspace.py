"""Versioned microscopy layers and journals in the canonical project store.

The shared TypeScript engine validates and executes workspace algorithms. This
module binds those documents to canonical acquisitions/masks, retains outputs,
and enforces revision, provenance and publication boundaries.
"""
from __future__ import annotations

from _workbench_indexed import RecordList

import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import uuid

MAX_WORKSPACES = 100
MAX_VERSIONS = 1000
MAX_OUTPUTS = 1000
MAX_DOCUMENT = 32 * 1024 ** 2


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    number = {"type": "number"}
    index = {"type": "integer", "minimum": 0, "maximum": 64000000}
    identity = {"workspaceId": _ID}
    selection = _object({"target": {"type": "string", "enum": ["plane", "volume"]},
                         "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                         "timeIndex": index, "zIndex": index,
                         "zProjection": {"type": "string", "enum": ["max", "mean", "middle"]}}, ["target", "channel"])
    binding = {**identity, "layerId": _ID, "imageId": _ID,
               "role": {"type": "string", "enum": ["raw-source", "instance-labels"]}, "selection": selection,
               "followPosition": {"type": "boolean", "default": False}}
    import_args = {"path": _STRING, "format": {"type": "string", "enum": ["portable", "native"]}}
    position = {"type": "object", "maxProperties": 16, "additionalProperties": index}
    step = _object({"type": {"type": "string", "enum": ["visibility", "opacity", "translate", "position", "register", "stitch"]},
                    "layerID": _ID, "visible": {"type": "boolean"}, "opacity": {"type": "number", "minimum": 0, "maximum": 1},
                    "x": number, "y": number, "axisID": _ID, "index": index, "referenceID": _ID, "movingID": _ID,
                    "maxShift": {"type": "integer", "minimum": 0, "maximum": 512},
                    "layerIDs": {"type": "array", "minItems": 2, "maxItems": 16, "items": _ID},
                    "columns": {"type": "integer", "minimum": 1, "maximum": 16},
                    "overlap": {"type": "number", "minimum": 0, "maximum": .95}, "outputName": _STRING}, ["type"])
    size = {"type": "integer", "minimum": 64, "maximum": 2048, "default": 768}
    zarr_binding = {**identity, "layerId": _ID, "sourceId": _ID, "arrayPath": _STRING,
                    **{key: {"type": "integer", "minimum": 0} for key in ("x", "y", "timeIndex", "channel", "zIndex")},
                    **{key: {"type": "integer", "minimum": 1, "maximum": 4000000} for key in ("width", "height")},
                    "followPosition": {"type": "boolean", "default": True}, "name": _STRING}
    return [
        _op("workspace.zarr.add", "Add an exact selected-level NGFF ROI with explicit source position following; no acquisition is extracted.",
            _object({key: value for key, value in zarr_binding.items() if key != "layerId"}, ["workspaceId", "sourceId", "arrayPath", "x", "y", "width", "height"]), True),
        _op("workspace.zarr.bind", "Explicitly attach a registered NGFF level/ROI and new retained source identity to an existing image layer.",
            _object(zarr_binding, ["workspaceId", "layerId", "sourceId", "arrayPath", "x", "y", "width", "height"]), True),
        _op("workspace.catalogue", "Describe the configured shared microscopy engine and workspace operation limits.", _object(), project=False),
        _op("workspace.create", "Create a versioned layered microscopy document in this project.", _object({"name": _STRING}, ["name"]), True),
        _op("workspace.list", "List retained workspace versions and source-binding freshness without rendering.", _object()),
        _op("workspace.get", "Read a retained workspace document and its explicit canonical source bindings.",
            _object({**identity, "version": {"type": "integer", "minimum": 1}}, ["workspaceId"])),
        _op("workspace.import.preview", "Validate portable/native workspace metadata and report unresolved raster sources without creating images.",
            _object(import_args, ["path", "format"])),
        _op("workspace.import.run", "Retain a previewed workspace and original file; never infer missing source paths or exact masks from journals.",
            _object({**import_args, "previewFingerprint": _ID, "name": _STRING}, ["path", "format", "previewFingerprint"]), True),
        _op("workspace.layer.update", "Change presentation metadata without resampling canonical images or masks.",
            _object({**identity, "layerId": _ID, "name": _STRING, "visible": {"type": "boolean"},
                     "opacity": {"type": "number", "minimum": 0, "maximum": 1},
                     "blendMode": {"type": "string", "enum": ["normal", "additive", "multiply", "screen", "difference"]},
                     "transform": _object({key: number for key in ("a", "b", "c", "d", "tx", "ty")}, ("a", "b", "c", "d", "tx", "ty")),
                     "display": _object({"min": number, "max": number,
                         "gamma": {"type": "number", "exclusiveMinimum": 0, "maximum": 10},
                         "color": {"type": "array", "minItems": 3, "maxItems": 3,
                                   "items": {"type": "integer", "minimum": 0, "maximum": 255}}}, ["min", "max", "gamma", "color"])},
                    ["workspaceId", "layerId"]), True),
        _op("workspace.source.bind", "Explicitly bind a layer to an exact canonical acquisition or current instance-mask selection.",
            _object(binding, ["workspaceId", "layerId", "imageId", "role", "selection"]), True),
        _op("workspace.layer.add", "Add a new layer with an explicit canonical acquisition or instance-mask binding.",
            _object({**{key: value for key, value in binding.items() if key != "layerId"}, "name": _STRING},
                    ["workspaceId", "imageId", "role", "selection"]), True),
        _op("workspace.document.set", "Validate and retain complete workspace metadata/journals while preserving only unchanged source identities.",
            _object({**identity, "path": _STRING}, ["workspaceId", "path"]), True),
        _op("workspace.document.update", "Save an explicitly edited shared document and journals as a new version; scientific raster bindings remain separately validated.",
            _object({**identity, "workspaceVersion": {"type": "integer", "minimum": 1}, "documentJson": {"type": "string", "maxLength": 3 * 1024 ** 2}},
                    ["workspaceId", "workspaceVersion", "documentJson"]), True),
        _op("workspace.operation.run", "Execute one closed layer operation using the shared replay engine and exact resolved source positions.",
            _object({**identity, "step": step}, ["workspaceId", "step"]), True),
        _op("workspace.layer.samples", "Read a bounded exact float32 source plane and acquired support at an explicitly resolved workspace position.",
            _object({**identity, "layerId": _ID, "position": position}, ["workspaceId", "layerId"])),
        _op("workspace.materialize.preview", "Preview promotion of a retained generated intensity grid with acquired support and all parent identities.",
            _object({**identity, "layerId": _ID, "name": _STRING}, ["workspaceId", "layerId"])),
        _op("workspace.materialize.run", "Create an independent scientific acquisition from the exact previewed generated grid, preserving all source coordinates and support.",
            _object({**identity, "layerId": _ID, "name": _STRING, "previewFingerprint": _ID}, ["workspaceId", "layerId", "previewFingerprint"]), True),
        _op("workspace.undo", "Retain the previous workspace version as a new revision without changing canonical masks.", _object(identity, identity), True),
        _op("workspace.preview", "Compose presentation layers through the existing engine using exact current source bindings.",
            _object({**identity, "width": size, "height": size}, identity)),
        _op("workspace.layer.preview", "Read one exact untransformed source-grid layer for direct journal editing; display pixels may be reduced.",
            _object({**identity, "layerId": _ID, "maxSize": size}, ["workspaceId", "layerId"])),
        _op("workspace.replay", "Run one saved closed layer workflow through the existing engine and retain its output document/planes.",
            _object({**identity, "workflowId": _ID}, ["workspaceId", "workflowId"]), True),
        _op("semantic.render", "Render a semantic-class paint journal to retained uint16 labels and TIFF; these are not instance masks.",
            _object({**identity, "layerId": _ID}, ["workspaceId", "layerId"]), True),
        _op("pointlineage.build", "Associate retained point observations using the shared bounded point-lineage engine.",
            _object({**identity, "maxDistance": {"type": "number", "exclusiveMinimum": 0},
                     "maxDistanceEvaluations": {"type": "integer", "minimum": 1, "maximum": 10000000}}, ["workspaceId", "maxDistance"]), True),
        _op("animation.render", "Retain a presentation GIF from a saved animation plan and supported bound source positions.",
            _object({**identity, "planId": _ID, "width": size, "height": size}, ["workspaceId", "planId"]), True),
        _op("workspace.output.list", "List retained semantic, animation and presentation outputs with currentness.", _object(identity, identity)),
        _op("workspace.export", "Publish a portable workspace JSON with supported explicit raster snapshots and retained provenance.",
            _object({**identity, "destination": _STRING}, ["workspaceId", "destination"]), True),
        _op("workspace.output.export", "Publish one exact retained workspace output artifact without recomputing it.",
            _object({"outputId": _ID, "artifactId": _ID, "destination": _STRING}, ["outputId", "artifactId", "destination"]), True),
    ]


def catalogue():
    import _workbench_microscopy_runtime as runtime
    return {"runtime": runtime.describe(), "operations": operations(),
            "limits": {"workspaces": MAX_WORKSPACES, "versions": MAX_VERSIONS, "documentBytes": MAX_DOCUMENT, "outputs": MAX_OUTPUTS},
            "notes": ["The existing shared microscopy engine supplies layer composition, semantic painting, point lineages, closed layer workflow replay and animation.",
                      "Canonical acquisition/mask bindings are explicit and revision-specific. Display transforms do not resample scientific inputs.",
                      "Semantic uint16 class values are not instance IDs. Native journals retain their original bytes; rendering uses the shared engine's documented brush geometry.",
                      "Fixed plane snapshots cannot silently supply other time/Z/channel positions. Acquired slice bindings and registered NGFF ROIs may explicitly follow workspace axes.",
                      "NGFF layers use the maintained Python reader at an exact chosen resolution/ROI; external byte ranges are checked when read, not by catalogue inspection."]}


def _record(document, workspace_id):
    item = next((item for item in document.get("workspaces", []) if item["id"] == workspace_id), None)
    if item is None:
        fail("workspace-not-found", "The selected canonical workspace is unavailable.")
    return item


def _version(record, number=None):
    number = record["currentVersion"] if number is None else number
    item = next((item for item in record["versions"] if item["version"] == number), None)
    if item is None:
        fail("workspace-version-not-found", "The selected immutable workspace version is unavailable.")
    return item


def _load(store, version):
    from _workbench_packages import _json
    path = store.verify_artifact(version["documentPath"], version["documentHash"])
    if path.stat().st_size > MAX_DOCUMENT:
        fail("workspace-document-limit", "A workspace document exceeds 32 MiB.")
    return _json(path.read_bytes(), "workspace document")


def _binding_identity(image, role, selection):
    from _workbench_store import canonical
    import _workbench_support as support
    import _workbench_volume as volume
    body = {"imageId": image["id"], "sourceHash": image["sourceHash"], "sourceSupport": support.fingerprint(image),
            "voxelSizeUm": volume.calibration(image), "timeStepSeconds": image.get("timeStepSeconds"), "role": role, "selection": selection}
    if role == "instance-labels":
        if selection["target"] == "volume":
            analysis = next((frame for frame in image.get("volumeFrames", []) if frame["timeIndex"] == selection["timeIndex"] and frame["channel"] == selection["channel"]), None)
        else:
            analysis = image.get("analysis")
            if analysis and any(analysis["parameters"][key] != selection[key] for key in ("channel", "zProjection")):
                fail("workspace-label-selection", "The saved instance mask uses a different channel/projection. Bind its exact selection.")
        if analysis is None:
            fail("workspace-labels-unavailable", "The requested exact saved instance labels are unavailable.")
        body["labelsHash"] = analysis["labelsHash"]
        body["labelsPath"] = analysis["labelsPath"]
    return {**body, "inputFingerprint": hashlib.sha256(canonical(body).encode()).hexdigest()}


def _current(document, binding):
    if binding.get("sourceKind") == "zarr":
        source = next((item for item in document.get("zarrSources", []) if item["id"] == binding["sourceId"]), None)
        return source is not None and source["metadataHash"] == binding["metadataHash"]
    from _workbench_schema import WorkbenchError
    image = next((image for image in document["images"] if image["id"] == binding.get("imageId")), None)
    if image is None:
        return False
    try:
        return _binding_identity(image, binding["role"], binding["selection"])["inputFingerprint"] == binding["inputFingerprint"]
    except (WorkbenchError, KeyError):
        return False


def describe(document, record, version=None):
    version = _version(record) if version is None else version
    changed = [binding["layerId"] for binding in version.get("bindings", []) if not _current(document, binding)]
    return {"id": record["id"], "name": version["name"], "version": version["version"], "latestVersion": record["versions"][-1]["version"],
            "layerCount": version["layerCount"], "sourceBindingsCurrent": False if changed else None if any(item.get("sourceKind") == "zarr" for item in version.get("bindings", [])) else True, "staleLayerIds": changed,
            "sourceVerificationScope": "external ranges checked when used" if any(item.get("sourceKind") == "zarr" for item in version.get("bindings", [])) else "retained-acquisition-identities",
            "missingSourceCount": len(version.get("missingSources", [])), "updatedAt": version["createdAt"],
            "documentHash": version["documentHash"], "undoAvailable": bool(record.get("undoStack")),
            "notes": copy.deepcopy(version.get("notes", []))}


def inspect_workspaces(document):
    return [describe(document, record) for record in document.get("workspaces", [])]


def _missing(workspace, bindings, planes):
    available = {item["layerId"] for item in [*bindings, *planes]}
    return [{"layerId": layer["id"], "name": layer["name"], "sourceKind": layer["source"]["identity"]["kind"],
             "reason": "An explicit canonical source binding or retained snapshot is required."}
            for layer in workspace["layers"] if layer["kind"] in ("image", "labels") and layer["id"] not in available
            and layer["id"] not in workspace.get("paintDocuments", {})]


def _validate(workspace):
    import _workbench_microscopy_runtime as runtime
    with runtime.invoke("workspace.validate", {"workspaceInput": "workspace"}, documents={"workspace": workspace}) as executed:
        return executed["result"]["summary"]


def _retain_output(store, output):
    suffix = {"float32-plane": ".workspace.f32", "semantic-labels": ".semantic.u16", "semantic-label-tiff": ".semantic.tif",
              "presentation-gif": ".workspace.gif", "microscopy-project": ".microscopy-project.json",
              "microscopy-workspace": ".workspace.json", "display-rgba": ".workspace.rgba", "valid-support": ".workspace-support.u8"}.get(output["kind"], ".workspace-output.bin")
    reference = "artifacts/" + output["sha256"] + suffix
    store.retain_verified_file(output["absolutePath"], reference, output["sha256"], maximum_bytes=256 * 1024 ** 2)
    return {"id": output["id"], "path": reference, "hash": output["sha256"], "bytes": output["bytes"],
            "kind": output["kind"], **{key: copy.deepcopy(output[key]) for key in ("dtype", "shape") if key in output}}


def _save(store, document, workspace, revision, *, record=None, bindings=None, planes=None, notes=None, origin=None, push_undo=True):
    from _workbench_store import canonical, utc_now
    if sum(len(item["versions"]) for item in document.get("workspaces", [])) >= MAX_VERSIONS:
        fail("workspace-version-limit", "The project retains at most 1,000 immutable workspace versions.")
    if record is None:
        if len(document.get("workspaces", [])) >= MAX_WORKSPACES:
            fail("workspace-limit", "The project retains at most 100 workspaces.")
        record = {"id": str(uuid.uuid4()), "versions": [], "undoStack": []}
        if origin is not None:
            record["origin"] = origin
        document.setdefault("workspaces", []).append(record)
    bindings, planes = copy.deepcopy(bindings or []), copy.deepcopy(planes or [])
    raw = canonical(workspace).encode()
    if len(raw) > MAX_DOCUMENT:
        fail("workspace-document-limit", "A workspace document exceeds 32 MiB.")
    path, checksum = store.put_bytes(raw, ".workspace.json")
    if record["versions"] and push_undo:
        record["undoStack"].append(record["currentVersion"])
    version = {"version": len(record["versions"]) + 1, "name": workspace["name"], "documentPath": path, "documentHash": checksum,
               "layerCount": len(workspace["layers"]), "bindings": bindings, "planes": planes,
               "missingSources": _missing(workspace, bindings, planes), "notes": copy.deepcopy(notes or []),
               "createdAt": utc_now(), "createdRevision": revision}
    record["versions"].append(version)
    record["currentVersion"] = version["version"]
    return {"workspace": describe(document, record)}


def _read_json_file(path):
    from _workbench_schema import absolute_path
    from _workbench_packages import _json
    source = absolute_path(path, "path")
    if not source.is_file() or source.stat().st_size > MAX_DOCUMENT:
        fail("workspace-document-limit", "Select a regular workspace JSON file of at most 32 MiB.")
    raw = source.read_bytes()
    return raw, _json(raw, "workspace import")


def _import(args, store=None):
    import _workbench_microscopy_runtime as runtime
    from _workbench_store import canonical
    from _workbench_packages import _json
    raw, value = _read_json_file(args["path"])
    planes, notes = [], []
    if args["format"] == "native":
        from _workbench_native_workspace import convert_native_workspace
        converted = convert_native_workspace(value)
        workspace, notes = converted["document"], converted["notes"]
        summary = _validate(workspace)
    else:
        with runtime.invoke("workspace.import", {"inputId": "original"}, documents={"original": raw}) as result:
            workspace = _json(result["outputs"][result["result"]["workspaceOutput"]]["absolutePath"].read_bytes(), "imported workspace")
            summary = result["result"]["summary"]
            for plane in result["result"].get("planes", []):
                output = result["outputs"][plane["outputId"]]
                metadata = {key: copy.deepcopy(plane[key]) for key in ("layerId", "width", "height", "calibration", "position") if key in plane}
                metadata.update(_retain_output(store, output) if store is not None else {"hash": output["sha256"], "bytes": output["bytes"]})
                if plane.get("supportOutput"):
                    supported = result["outputs"][plane["supportOutput"]]
                    metadata["support"] = (_retain_output(store, supported) if store is not None else
                                           {"hash": supported["sha256"], "bytes": supported["bytes"]})
                planes.append(metadata)
    missing = converted["missingSources"] if args["format"] == "native" else _missing(workspace, [], planes)
    original_hash = hashlib.sha256(raw).hexdigest()
    fingerprint = hashlib.sha256(canonical({"originalHash": original_hash, "document": workspace,
        "planes": [{**{key: item[key] for key in ("layerId", "hash", "bytes")},
                    "supportHash": item.get("support", {}).get("hash")} for item in planes],
        "format": args["format"], "runtimeManifestHash": runtime.describe()["manifestHash"]}).encode()).hexdigest()
    report = {"previewFingerprint": fingerprint, "summary": summary, "missingSources": missing, "notes": notes,
              "originalHash": original_hash, "format": args["format"]}
    return report, workspace, planes, raw


def _selection(image, supplied):
    selected = copy.deepcopy(supplied)
    if selected["channel"] >= image["channels"]:
        fail("channel-unavailable", "The layer's selected source channel is unavailable.")
    if selected["target"] == "plane":
        if "zIndex" in selected:
            fail("workspace-selection", "Use target volume and an explicit zIndex for an exact source slice.")
        selected.setdefault("zProjection", "max")
        selected.setdefault("timeIndex", 0)
    else:
        if "zProjection" in selected:
            fail("workspace-selection", "A volume layer slice uses zIndex, not a projection.")
        selected.setdefault("timeIndex", 0)
        selected.setdefault("zIndex", 0)
        if selected["zIndex"] >= image["zCount"]:
            fail("slice-unavailable", "The selected source slice is unavailable.")
    if selected["timeIndex"] >= image["timeCount"]:
        fail("time-unavailable", "The selected source time point is unavailable.")
    return selected


def _plane(store, image, role, selected, source_cache=None):
    import _workbench_imaging as imaging
    import _workbench_volume as volume
    from _workbench_core import _labels, _current_analysis
    np, = imaging.require("numpy")
    if role == "instance-labels":
        if selected["target"] == "volume":
            frame = volume.current_frame(store, image, selected["timeIndex"], selected["channel"])
            values = volume.read_labels(store, image, frame)[selected["zIndex"]]
        else:
            _current_analysis(store, image)
            values = _labels(store, image)
    elif selected["target"] == "volume":
        cache = source_cache if source_cache is not None else {}
        if cache.get("key") != image["sourceHash"]:
            cache.clear()
            cache["source"] = imaging.load_array(store.verify_artifact(image["sourcePath"], image["sourceHash"]))
            cache["key"] = image["sourceHash"]
        values, metadata = cache["source"]
        axes = metadata["axes"].replace("S", "C")
        for axis, index in (("T", selected["timeIndex"]), ("C", selected["channel"]), ("Z", selected["zIndex"])):
            if axis in axes:
                slices = [slice(None)] * values.ndim
                slices[axes.index(axis)] = index
                values = values[tuple(slices)]
                axes = axes.replace(axis, "")
        if axes != "YX" or values.shape != (image["height"], image["width"]):
            fail("workspace-grid-mismatch", "The acquired exact slice differs from its retained YX grid.")
    else:
        source = store.verify_artifact(image["sourcePath"], image["sourceHash"])
        values, _ = imaging.load_plane(source, selected, time_index=selected["timeIndex"])
    if not np.isfinite(values).all():
        fail("nonfinite-source", "Layer inputs must contain finite acquired values.")
    converted = values.astype("<f4")
    if not np.array_equal(converted.astype(values.dtype), values):
        fail("workspace-precision", "The existing workspace engine uses float32 planes. This source cannot be represented exactly; no implicit numerical conversion is permitted.")
    return converted


def _zarr_selected(document, binding, workspace, position):
    import _workbench_zarr as zarr
    value = zarr.source(document, binding["sourceId"])
    if value["metadataHash"] != binding["metadataHash"]:
        fail("workspace-source-stale", "The registered NGFF metadata differs from this workspace binding. Explicitly reattach the intended source.")
    selected = copy.deepcopy(binding["selection"])
    axes = {axis["id"]: axis for axis in workspace["axes"]}
    for field, axis_id in binding.get("positionAxes", {}).items():
        if axis_id not in axes or axes[axis_id]["kind"] != {"timeIndex": "time", "zIndex": "z", "channel": "channel"}.get(field):
            fail("workspace-axis-binding", "A source-bound workspace axis changed. Restore it or rebind the NGFF source.")
        selected[field] = position.get(axis_id, 0)
    if not binding.get("positionAxes") and any(position.get(key, 0) != index for key, index in binding.get("position", {}).items()):
        fail("workspace-position-unavailable", "This NGFF layer is bound to a fixed time/Z/channel position.")
    return value, selected


def _zarr_values(store, document, binding, workspace, position):
    import _workbench_zarr as zarr
    import _workbench_imaging as imaging
    from _workbench_store import canonical
    np, = imaging.require("numpy")
    source, selected = _zarr_selected(document, binding, workspace, position)
    region = binding["region"]
    if region["width"] * region["height"] > 4_000_000:
        fail("workspace-grid-limit", "Select an exact NGFF level/ROI with at most four million pixels; overview samples are not source planes.")
    values, identity = zarr.read_grid(source, {"arrayPath": binding["arrayPath"], **selected},
        np.arange(region["x"], region["x"] + region["width"]), np.arange(region["y"], region["y"] + region["height"]))
    converted = values.astype("<f4")
    if not np.array_equal(converted.astype(values.dtype), values):
        fail("workspace-precision", "These NGFF samples cannot be represented exactly as float32. No lossy workspace conversion is performed.")
    identity["region"] = copy.deepcopy(region)
    selection_key = hashlib.sha256(canonical({"arrayPath": binding["arrayPath"], "selection": selected, "region": region}).encode()).hexdigest()
    known = next((item for item in binding.get("observedReads", []) if item["selectionKey"] == selection_key), None)
    if known is None and binding.get("observationScope") and binding.get("bindingId"):
        record = _record(document, binding["observationScope"])
        known = record.get("sourceObservations", {}).get(binding["bindingId"] + ":" + selection_key)
    if known:
        prior = zarr.load_json(store, {"path": known["readIdentity"]["path"], "sha256": known["readIdentity"]["hash"]})
        if canonical(prior) != canonical(identity):
            fail("workspace-source-changed", "NGFF source ranges changed at a previously retained layer position. Explicitly bind a new source state before generating another result.", {"layerId": binding["layerId"]})
    descriptor = zarr.array_descriptor(source, binding["arrayPath"])
    calibration = descriptor["voxelSizeUm"]
    calibration = {"x": calibration["x"], "y": calibration["y"], "unit": "µm"} if calibration.get("x") is not None and calibration.get("y") is not None else None
    resolved = {"sourceKind": "zarr", "sourceId": source["id"], "role": "raw-source", "layerId": binding["layerId"],
                "metadataHash": source["metadataHash"], "metadataReference": copy.deepcopy(binding["metadataReference"]),
                "arrayPath": binding["arrayPath"], "region": copy.deepcopy(region), "selection": selected,
                "position": copy.deepcopy(position), "selectionKey": selection_key, "readSetHash": identity["readSetHash"],
                "sourceAxes": copy.deepcopy(descriptor["axes"]), "scale": descriptor["scale"], "translation": descriptor["translation"],
                "voxelSizeUm": descriptor["voxelSizeUm"], "timeStepSeconds": descriptor["timeStepSeconds"],
                "supportPolicy": "selected-ngff-dataset-domain", "_readIdentity": identity,
                "bindingId": binding.get("bindingId"), "observationScope": binding.get("observationScope")}
    if known:
        resolved["readIdentity"] = copy.deepcopy(known["readIdentity"])
    return converted, None, calibration, resolved


def _retain_resolved(store, document, bindings, resolved_inputs):
    import _workbench_zarr as zarr
    from _workbench_store import canonical
    for item in resolved_inputs:
        identity = item.pop("_readIdentity", None)
        if identity is None:
            continue
        binding = next((value for value in bindings if value["layerId"] == item["layerId"]), None)
        if item.get("readIdentity") is None:
            record = _record(document, item["observationScope"]) if item.get("observationScope") else None
            observations = record.setdefault("sourceObservations", {}) if record is not None else None
            key = item.get("bindingId", "") + ":" + item["selectionKey"]
            if observations is not None and key not in observations and len(observations) >= 4096:
                fail("workspace-read-limit", "This workspace retains at most 4,096 exact external source positions. Start a new workspace for additional positions.")
            # Source relocation checks all retained observations. A standalone
            # identity also travels with derived images that omit the catalogue.
            zarr.retain_identity(store, zarr.source(document, item["sourceId"]), identity)
            path, checksum = store.put_bytes(canonical(identity).encode(), ".workspace-zarr-read.json")
            item["readIdentity"] = {"path": path, "hash": checksum}
            observation = {"selectionKey": item["selectionKey"], "readIdentity": copy.deepcopy(item["readIdentity"])}
            if observations is not None:
                observations[key] = observation
            if binding is not None and not binding.get("observedReads"):
                binding["observedReads"] = [observation]


def _verify_resolved(store, document, binding):
    if not _current(document, binding):
        fail("workspace-source-stale", "A workspace parent identity changed; select the intended current source explicitly.")
    if binding.get("sourceKind") == "zarr":
        import _workbench_zarr as zarr
        reference = binding.get("readIdentity")
        if not reference:
            fail("workspace-read-identity", "The generated result has no retained exact NGFF read identity.")
        identity = zarr.load_json(store, {"path": reference["path"], "sha256": reference["hash"]})
        source = zarr.source(document, binding["sourceId"])
        zarr.verify_reads(source["path"], source["metadataReadSet"])
        zarr.verify_reads(source["path"], identity["readSet"])


def verify_materialized_inputs(store, document, image):
    for binding in materialized_dependencies(image):
        _verify_resolved(store, document, binding)
    return True


def external_source_paths(document, args=None):
    """Read grants include only explicitly bound registered directories."""
    args = args or {}
    if args.get("sourceId"):
        import _workbench_zarr as zarr
        return [zarr.source(document, args["sourceId"])["path"]]
    bindings = []
    if args.get("workspaceId"):
        version = _version(_record(document, args["workspaceId"]))
        bindings = list(version.get("bindings", []))
        pending = list(version.get("planes", []))
        seen = set()
        while pending:
            plane = pending.pop()
            identity = (plane.get("path"), plane.get("hash"))
            if identity in seen:
                continue
            seen.add(identity)
            if len(seen) > 256:
                fail("workspace-provenance-limit", "The workspace has more than 256 generated parent planes.")
            provenance = plane.get("provenance", {})
            bindings.extend(provenance.get("resolvedInputs", []))
            pending.extend(provenance.get("parentPlanes", []))
    elif args.get("outputId"):
        # Publishing retained bytes needs no external source access.
        return []
    else:
        return []
    ids = {item["sourceId"] for item in bindings if item.get("sourceKind") == "zarr"}
    return [item["path"] for item in document.get("zarrSources", []) if item["id"] in ids]


def _bind_zarr(store, document, record, version, workspace, args, revision):
    import _workbench_zarr as zarr
    from _workbench_store import utc_now
    source = zarr.source(document, args["sourceId"])
    descriptor = zarr.array_descriptor(source, args["arrayPath"])
    axes = {axis["name"]: extent for axis, extent in zip(descriptor["axes"], descriptor["shape"])}
    region = {key: args[key] for key in ("x", "y", "width", "height")}
    if region["width"] * region["height"] > 4_000_000 or region["x"] + region["width"] > axes["x"] or region["y"] + region["height"] > axes["y"]:
        fail("workspace-grid-limit", "Choose an exact selected-level ROI within its bounds and at most four million pixels.")
    selected = {"target": "volume", **{key: args.get(key, 0) for key in ("timeIndex", "channel", "zIndex")}}
    dimensions = {"timeCount": axes.get("t", 1), "zCount": axes.get("z", 1), "channels": axes.get("c", 1),
                  "voxelSizeUm": descriptor["voxelSizeUm"], "pxPerUm": None, "timeStepSeconds": descriptor["timeStepSeconds"]}
    _selection(dimensions, selected)
    if args.get("layerId"):
        layer = next((item for item in workspace["layers"] if item["id"] == args["layerId"]), None)
        if layer is None:
            fail("workspace-layer-not-found", "Choose a saved layer to attach this source.")
        if layer["id"] in workspace.get("paintDocuments", {}):
            fail("workspace-binding-role", "Attach NGFF intensity to an image layer; semantic journals keep their own exact grid.")
    else:
        layer = {"id": str(uuid.uuid4()), "name": args.get("name", source["name"][:160] + " · " + descriptor["path"]),
                 "kind": "image", "axisIDs": [], "visible": True, "opacity": 1, "blendMode": "normal",
                 "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": region["x"], "ty": region["y"]},
                 "display": {"min": 0, "max": 1, "gamma": 1, "color": [255, 255, 255]}}
        workspace["layers"].append(layer)
    mapping = _position_axes(workspace, dimensions, selected, "raw-source") if args.get("followPosition", True) else {}
    layer["axisIDs"] = list(mapping.values())
    layer["kind"] = "image"
    layer["source"] = {"identity": {"id": source["id"], "name": source["name"], "kind": "zarr", "metadataSha256": source["metadataHash"]},
                       "arrayPath": descriptor["path"], "level": descriptor["level"]}
    binding = {"sourceKind": "zarr", "sourceId": source["id"], "metadataHash": source["metadataHash"],
               "metadataReference": {"path": source["metadataPath"], "hash": source["metadataSha256"]},
               "layerId": layer["id"], "role": "raw-source", "bindingId": str(uuid.uuid4()), "observationScope": record["id"], "arrayPath": descriptor["path"], "region": region,
               "selection": selected, "positionAxes": mapping, "position": copy.deepcopy(workspace["position"]), "observedReads": []}
    values, _, _, resolved = _zarr_values(store, document, binding, workspace, workspace["position"])
    _retain_resolved(store, document, [binding], [resolved])
    layer["display"].update({"min": float(values.min()), "max": float(values.max()) if values.max() > values.min() else float(values.min()) + max(1, abs(float(values.min())) * 1e-6)})
    bindings = [item for item in version["bindings"] if item["layerId"] != layer["id"]] + [binding]
    planes = [item for item in version["planes"] if item["layerId"] != layer["id"]]
    workspace["modifiedAt"] = utc_now()
    _validate(workspace)
    return _save(store, document, workspace, revision, record=record, bindings=bindings, planes=planes,
        notes=[*version["notes"], "NGFF layers read exact selected-level ROIs; overview samples never become scientific source pixels. External ranges are verified when used; absence of a new read is not a currentness check."])


def _position_axes(workspace, image, selection, role):
    """An explicit opt-in maps workspace positions to acquired T/Z/C indices."""
    if role != "raw-source":
        fail("workspace-position-role", "Position-following applies to acquired intensity. Bind each saved instance mask to its exact selection.")
    if selection["target"] != "volume":
        fail("workspace-position-selection", "Position-following requires exact source slices (target volume), not a projected plane.")
    import _workbench_volume as volume
    calibration = volume.calibration(image)
    mapping = {}
    for kind, length, field in (("time", image["timeCount"], "timeIndex"), ("z", image["zCount"], "zIndex"), ("channel", image["channels"], "channel")):
        existing = [axis for axis in workspace["axes"] if axis["kind"] == kind]
        if len(existing) > 1:
            fail("workspace-axis-ambiguous", "Use one time, Z and channel axis when attaching position-following sources.")
        if existing:
            axis = existing[0]
            if axis["length"] > length:
                fail("workspace-axis-range", "The source cannot supply every position on the workspace axis.", {"axisId": axis["id"], "sourceLength": length})
        else:
            axis_id = kind
            while any(axis["id"] == axis_id for axis in workspace["axes"]):
                axis_id += "-source"
            scale = image.get("timeStepSeconds") if kind == "time" else calibration["z"] if kind == "z" else None
            axis = {"id": axis_id, "name": {"time": "Time", "z": "Z", "channel": "Channel"}[kind], "kind": kind,
                    "length": length, "scale": scale if scale is not None and scale > 0 else 1, "calibrated": scale is not None and scale > 0}
            if axis["calibrated"]:
                axis["unit"] = "s" if kind == "time" else "µm"
            workspace["axes"].append(axis)
            workspace["position"][axis_id] = selection[field]
        mapping[field] = axis["id"]
    return mapping


def _position(workspace, supplied=None):
    position = copy.deepcopy(workspace["position"])
    axes = {axis["id"]: axis for axis in workspace["axes"]}
    for key, value in (supplied or {}).items():
        if key not in axes or type(value) is not int or value < 0 or value >= axes[key]["length"]:
            fail("workspace-position", "Choose an existing workspace axis and an index within its exact extent.", {"axisId": key})
        position[key] = value
    return position


def _resolved_binding(document, binding, workspace, position, *, enforce_fixed=True):
    if not _current(document, binding):
        fail("workspace-source-stale", "The layer source, calibration or saved mask changed. Explicitly rebind it before execution.", {"layerId": binding["layerId"]})
    if binding.get("sourceKind") == "zarr":
        _, selected = _zarr_selected(document, binding, workspace, position)
        return None, {**copy.deepcopy(binding), "selection": selected, "position": copy.deepcopy(position)}
    image = next(image for image in document["images"] if image["id"] == binding["imageId"])
    selected = copy.deepcopy(binding["selection"])
    mapping = binding.get("positionAxes", {})
    if mapping:
        if binding["role"] != "raw-source" or selected["target"] != "volume":
            fail("workspace-position-role", "Only acquired exact source slices can follow workspace positions.")
        axes = {axis["id"]: axis for axis in workspace["axes"]}
        for field, axis_id in mapping.items():
            expected_kind = {"timeIndex": "time", "zIndex": "z", "channel": "channel"}.get(field)
            if expected_kind is None or axis_id not in axes or axes[axis_id]["kind"] != expected_kind:
                fail("workspace-axis-binding", "The draft changed a source-bound axis identity. Restore that axis or rebind the source.")
            selected[field] = position.get(axis_id, 0)
        selected = _selection(image, selected)
    elif enforce_fixed and (any(position.get(key, 0) != value for key, value in binding.get("position", {}).items()) or any(
            position.get(axis["id"], 0) != binding.get("position", {}).get(axis["id"], selected.get({"time": "timeIndex", "z": "zIndex", "channel": "channel"}.get(axis["kind"], ""), 0))
            for axis in workspace["axes"] if axis["kind"] in ("time", "z", "channel"))):
        fail("workspace-position-unavailable", "This layer is a fixed source snapshot. Attach an acquired slice with Follow workspace positions to browse other positions.", {"layerId": binding["layerId"]})
    return image, {**_binding_identity(image, binding["role"], selected), "layerId": binding["layerId"],
                   "sourcePath": image["sourcePath"], "position": copy.deepcopy(position)}


def _layer_values(store, document, version, workspace, layer_id, position, source_cache=None):
    import _workbench_imaging as imaging
    import _workbench_support as support
    import _workbench_volume as volume
    np, = imaging.require("numpy")
    binding = next((item for item in version["bindings"] if item["layerId"] == layer_id), None)
    retained = next((item for item in version["planes"] if item["layerId"] == layer_id), None)
    if binding and binding.get("sourceKind") == "zarr":
        return _zarr_values(store, document, binding, workspace, position)
    if binding:
        image, resolved = _resolved_binding(document, binding, workspace, position)
        values = _plane(store, image, binding["role"], resolved["selection"], source_cache)
        selected = resolved["selection"]
        mask = support.load(store, image, values.shape, selected) if selected["target"] == "plane" else support.load(store, image)
        if mask is not None and mask.ndim == 3:
            mask = mask[selected["zIndex"]]
        measured = volume.calibration(image)
        calibration = {"x": measured["x"], "y": measured["y"], "unit": "µm"} if measured["x"] is not None and measured["y"] is not None else None
    elif retained:
        if any(position.get(key, 0) != value for key, value in retained.get("position", {}).items()):
            fail("workspace-position-unavailable", "A retained generated plane is a fixed position. Recompute its generating operation for this position.", {"layerId": layer_id})
        width, height = retained["width"], retained["height"]
        if width * height > 4_000_000 or retained["bytes"] != width * height * 4:
            fail("workspace-grid-limit", "The exact workspace plane exceeds four million pixels or its retained byte span.")
        values = np.frombuffer(store.verify_artifact(retained["path"], retained["hash"]).read_bytes(), dtype="<f4").reshape(height, width)
        mask = None
        if retained.get("support"):
            item = retained["support"]
            if item["bytes"] != width * height:
                fail("workspace-support-grid", "Retained support dimensions differ from the generated plane.")
            mask = np.frombuffer(store.verify_artifact(item["path"], item["hash"]).read_bytes(), dtype=np.uint8).reshape(height, width).astype(bool)
        calibration = retained.get("calibration")
        resolved = {"layerId": layer_id, "role": "derived-source", "path": retained["path"], "hash": retained["hash"], "position": copy.deepcopy(position)}
    else:
        fail("workspace-source-missing", "Attach an exact canonical source or import an embedded source plane.", {"layerId": layer_id})
    if values.size > 4_000_000 or mask is not None and mask.shape != values.shape:
        fail("workspace-grid-limit", "Exact layer samples require a matching support grid and at most four million pixels.")
    return values, mask, calibration, resolved


def layer_samples(store, document, record, version, workspace, args):
    position = _position(workspace, args.get("position"))
    values, mask, calibration, resolved = _layer_values(store, document, version, workspace, args["layerId"], position)
    return {"workspaceId": record["id"], "version": version["version"], "layerId": args["layerId"], "position": position,
            "width": int(values.shape[1]), "height": int(values.shape[0]), "dtype": "float32-le", "order": "yx",
            "dataBase64": base64.b64encode(values.astype("<f4", copy=False).tobytes()).decode(),
            "supportBase64": None if mask is None else base64.b64encode(mask.astype("uint8").tobytes()).decode(),
            "calibration": calibration, "sourceBinding": resolved, "sourceCurrent": True, "untransformed": True}


def layer_grids(document, version):
    images = {image["id"]: image for image in document["images"]}
    result = [{"layerId": item["layerId"], "width": item["width"], "height": item["height"],
               "position": copy.deepcopy(item.get("position", {})), "sourceKind": "retained"} for item in version["planes"]]
    for binding in version["bindings"]:
        if binding.get("sourceKind") == "zarr":
            result.append({"layerId": binding["layerId"], "width": binding["region"]["width"], "height": binding["region"]["height"], "position": copy.deepcopy(binding["position"]), "sourceKind": "zarr"})
            continue
        image = images.get(binding["imageId"])
        if image:
            result.append({"layerId": binding["layerId"], "width": image["width"], "height": image["height"],
                           "position": copy.deepcopy(binding["position"]), "sourceKind": "canonical"})
    return result


def layer_preview(store, document, record, version, args):
    import _workbench_imaging as imaging
    import _workbench_support as support
    from _workbench_composite import _effective_window, _mix_samples, _rgba
    np, = imaging.require("numpy")
    imaging.require("PIL")
    from PIL import Image
    workspace = _load(store, version)
    position = _position(workspace, args.get("position"))
    values, mask, _, binding = _layer_values(store, document, version, workspace, args["layerId"], position)
    height, width = values.shape
    scale = min(1, args.get("maxSize", 768) / max(width, height))
    display_width, display_height = max(1, round(width * scale)), max(1, round(height * scale))
    xs = np.minimum(width - 1, np.floor((np.arange(display_width) + .5) * width / display_width).astype(int))
    ys = np.minimum(height - 1, np.floor((np.arange(display_height) + .5) * height / display_height).astype(int))
    sampled = values[np.ix_(ys, xs)].astype(np.float64)
    acquired = mask[np.ix_(ys, xs)] if mask is not None else None
    settings = _effective_window({"enabled": True, "opacity": 1, "gamma": 1, "color": "#FFFFFF"}, values, mask,
                                 int(mask.sum()) if mask is not None else values.size, np)
    mixed = np.zeros((*sampled.shape, 3), dtype=np.float32)
    _mix_samples(mixed, sampled, acquired, settings, np)
    output = Image.fromarray(_rgba(mixed, acquired, np), "RGBA")
    encoded = io.BytesIO()
    output.save(encoded, format="PNG")
    return {"workspaceId": record["id"], "workspaceVersion": version["version"], "version": version["version"],
            "layerId": args["layerId"], "width": int(width), "height": int(height),
            "previewWidth": display_width, "previewHeight": display_height, "position": copy.deepcopy(position),
            "sourceBinding": copy.deepcopy(binding), "sourceCurrent": True, "untransformed": True,
            "displayRange": [settings["lower"], settings["upper"]],
            "dataUrl": "data:image/png;base64," + base64.b64encode(encoded.getvalue()).decode()}


def _inputs(store, document, version, workspace, temporary, *, processing=False, positions=None, requests=None):
    from _workbench_store import file_hash, canonical
    inputs, planes, resolved_inputs = {}, [], []
    positions = positions or [workspace["position"]]
    unique = {canonical(_position(workspace, item)): _position(workspace, item) for item in positions}
    total = 0
    source_cache = {}
    for layer in workspace["layers"]:
        selected_positions = [_position(workspace, item["position"]) for item in requests if item["layerId"] == layer["id"]] if requests is not None else unique.values()
        for position in selected_positions:
            layer_id = layer["id"]
            if layer["kind"] not in ("image", "labels") or layer_id in workspace.get("paintDocuments", {}):
                continue
            if not processing and not layer["visible"]:
                continue
            if len(planes) >= 256:
                fail("workspace-input-limit", "A workspace execution resolves at most 256 exact layer/position planes. Shorten the animation or workflow.")
            values, mask, calibration, resolved = _layer_values(store, document, version, workspace, layer_id, position, source_cache)
            total += values.nbytes + (mask.size if mask is not None else 0)
            if total > 96 * 1024 ** 2:
                fail("workspace-input-limit", "Resolved exact planes and support exceed 96 MiB. Reduce positions, visible layers or image size.")
            identity = "plane-" + str(len(planes))
            path = temporary / (identity + ".f32")
            values.tofile(path)
            inputs[identity] = (path, file_hash(path), values.nbytes)
            item = {"layerId": layer_id, "inputId": identity, "width": int(values.shape[1]), "height": int(values.shape[0]), "position": copy.deepcopy(position)}
            if calibration:
                item["calibration"] = calibration
            if mask is not None:
                support_id = "support-" + str(len(planes))
                support_path = temporary / (support_id + ".u8")
                mask.astype("uint8").tofile(support_path)
                inputs[support_id] = (support_path, file_hash(support_path), mask.size)
                item["supportInput"] = support_id
            planes.append(item)
            resolved_inputs.append(resolved)
    return inputs, planes, resolved_inputs


def execute(store, document, operation, args, revision):
    from _workbench_store import utc_now, canonical
    from _workbench_packages import _json
    import _workbench_microscopy_runtime as runtime
    if operation == "workspace.list":
        return {"workspaces": inspect_workspaces(document)}
    if operation == "workspace.create":
        with runtime.invoke("workspace.create", {"name": args["name"]}) as result:
            workspace = _json(result["outputs"][result["result"]["workspaceOutput"]]["absolutePath"].read_bytes(), "workspace")
            return _save(store, document, workspace, revision)
    if operation.startswith("workspace.import."):
        report, workspace, planes, raw = _import(args, store if operation.endswith(".run") else None)
        if operation.endswith(".preview"):
            return report
        if report["previewFingerprint"] != args["previewFingerprint"]:
            fail("workspace-preview-changed", "The import file or engine identity changed. Preview it again before import.")
        if args.get("name"):
            workspace["name"] = args["name"]
            _validate(workspace)
        path, checksum = store.put_bytes(raw, ".original-workspace.json")
        return _save(store, document, workspace, revision, planes=planes, notes=report["notes"],
                     origin={"path": path, "hash": checksum, "format": args["format"]})
    record = _record(document, args["workspaceId"])
    version = _version(record, args.get("version"))
    if operation == "workspace.output.list":
        return {"outputs": [describe_output(document, item) for item in document.get("workspaceOutputs", []) if item["workspaceId"] == record["id"]]}
    workspace = _load(store, version)
    if operation == "workspace.get":
        return {"workspace": describe(document, record, version), "document": workspace,
                "layerBindings": copy.deepcopy(version["bindings"]), "missingSources": copy.deepcopy(version["missingSources"]),
                "layerGrids": layer_grids(document, version),
                "generatedLayers": [{"layerId": item["layerId"], "width": item["width"], "height": item["height"],
                    "hasSupport": bool(item.get("support")), "generated": bool(item.get("generation")),
                    "calibration": copy.deepcopy(item.get("calibration")),
                    "materializable": bool(item.get("generation") and item.get("support") and item.get("provenance"))}
                    for item in version["planes"]]}
    if operation in ("workspace.zarr.add", "workspace.zarr.bind"):
        return _bind_zarr(store, document, record, version, workspace, args, revision)
    if operation == "workspace.layer.samples":
        return layer_samples(store, document, record, version, workspace, args)
    if operation == "workspace.layer.preview":
        return layer_preview(store, document, record, version, args)
    if operation.startswith("workspace.materialize."):
        plan, values, mask, provenance = _materialization(store, document, record, version, workspace, args)
        if operation.endswith(".preview"):
            return plan
        if plan["previewFingerprint"] != args["previewFingerprint"]:
            fail("workspace-preview-changed", "The generated plane, parents or workspace changed. Preview materialization again.")
        return _materialize(store, document, plan, values, mask, provenance, revision)
    if operation == "workspace.undo":
        if not record.get("undoStack"):
            fail("workspace-undo-empty", "There is no earlier workspace state to restore.")
        previous = _version(record, record["undoStack"].pop())
        return _save(store, document, _load(store, previous), revision, record=record, bindings=previous["bindings"], planes=previous["planes"], notes=previous["notes"], push_undo=False)
    bindings, planes = copy.deepcopy(version["bindings"]), copy.deepcopy(version["planes"])
    if operation in ("workspace.document.set", "workspace.document.update"):
        if operation == "workspace.document.update":
            if args["workspaceVersion"] != version["version"]:
                fail("workspace-version-conflict", "The saved workspace changed. Retain your draft and reload the current version before saving.")
            raw = args["documentJson"].encode("utf8")
            if len(raw) > 3 * 1024 ** 2:
                fail("workspace-document-limit", "Inline workspace drafts support 3 MiB. Export the draft metadata to JSON and use workspace.document.set for a file up to 32 MiB; the local draft is preserved.")
            changed = _json(raw, "workspace draft")
        else:
            _, changed = _read_json_file(args["path"])
        _validate(changed)
        if changed.get("id") != workspace.get("id"):
            fail("workspace-identity", "A workspace draft must preserve its document identity. Import another document as a new workspace.")
        old = {layer["id"]: layer for layer in workspace["layers"]}
        stable = {layer["id"] for layer in changed["layers"] if layer["id"] in old and layer["source"] == old[layer["id"]]["source"]}
        image_map = {image["id"]: image for image in document["images"]}
        retained_grids = {item["layerId"]: (item["width"], item["height"]) for item in planes}
        for binding in bindings:
            image = image_map.get(binding.get("imageId"))
            if image:
                retained_grids[binding["layerId"]] = (image["width"], image["height"])
        for layer_id, paint in changed.get("paintDocuments", {}).items():
            if layer_id in stable and layer_id in retained_grids and retained_grids[layer_id] != (paint["width"], paint["height"]):
                fail("workspace-grid-mismatch", "The edited semantic journal grid differs from its retained source. Rebind an exact matching grid; strokes are never implicitly rescaled.", {"layerId": layer_id})
        for item in bindings:
            if item["layerId"] in stable:
                _resolved_binding(document, item, changed, changed["position"], enforce_fixed=False)
        return _save(store, document, changed, revision, record=record, bindings=[item for item in bindings if item["layerId"] in stable],
                     planes=[item for item in planes if item["layerId"] in stable], notes=version["notes"])
    if operation in ("workspace.layer.update", "workspace.layer.add", "workspace.source.bind"):
        if operation == "workspace.layer.add":
            layer = {"id": str(uuid.uuid4()), "name": args.get("name", "Image layer"), "kind": "image", "axisIDs": [],
                     "source": {"identity": {"id": args["imageId"], "name": args.get("name", "Image layer"), "kind": "local"}},
                     "visible": True, "opacity": 1, "blendMode": "normal", "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
                     "display": {"min": 0, "max": 1, "gamma": 1, "color": [255, 255, 255]}}
            workspace["layers"].append(layer)
        else:
            layer = next((item for item in workspace["layers"] if item["id"] == args["layerId"]), None)
            if layer is None:
                fail("workspace-layer-not-found", "The selected workspace layer is unavailable.")
        if operation == "workspace.layer.update":
            layer.update({key: copy.deepcopy(args[key]) for key in ("name", "visible", "opacity", "blendMode", "transform", "display") if key in args})
        else:
            from _workbench_core import _image
            image = _image(document, args["imageId"])
            selected = _selection(image, args["selection"])
            values = _plane(store, image, args["role"], selected)
            paint = workspace.get("paintDocuments", {}).get(layer["id"])
            if paint and (paint["width"] != values.shape[1] or paint["height"] != values.shape[0]):
                fail("workspace-grid-mismatch", "The semantic journal grid differs from this acquisition. Strokes are never implicitly rescaled.")
            axis_mapping = _position_axes(workspace, image, selected, args["role"]) if args.get("followPosition", False) else {}
            if axis_mapping:
                layer["axisIDs"] = list(axis_mapping.values())
            binding = {**_binding_identity(image, args["role"], selected), "sourcePath": image["sourcePath"],
                       "layerId": layer["id"], "position": copy.deepcopy(workspace["position"]), "positionAxes": axis_mapping}
            bindings = [item for item in bindings if item["layerId"] != layer["id"]] + [binding]
            planes = [item for item in planes if item["layerId"] != layer["id"]]
            layer["source"] = {"identity": {"id": image["id"], "name": image["name"], "kind": "local", "sha256": image["sourceHash"]}}
            if not paint:
                layer["kind"] = "labels" if args["role"] == "instance-labels" else "image"
            if operation == "workspace.layer.add":
                low, high = float(values.min()), float(values.max())
                layer["display"].update({"min": low, "max": high if high > low else low + max(1, abs(low) * 1e-6)})
        workspace["modifiedAt"] = utc_now()
        _validate(workspace)
        return _save(store, document, workspace, revision, record=record, bindings=bindings, planes=planes, notes=version["notes"])
    if operation == "pointlineage.build":
        worker_args = {"inputId": "observations", "maxDistance": args["maxDistance"]}
        if "maxDistanceEvaluations" in args:
            worker_args["maxDistanceEvaluations"] = args["maxDistanceEvaluations"]
        with runtime.invoke("lineage.build", worker_args, documents={"observations": workspace["lineage"]["nodes"]}) as result:
            workspace["lineage"] = _json(result["outputs"][result["result"]["graphOutput"]]["absolutePath"].read_bytes(), "point lineage")
        workspace["modifiedAt"] = utc_now()
        _validate(workspace)
        return _save(store, document, workspace, revision, record=record, bindings=bindings, planes=planes, notes=version["notes"])
    transient_workflow_id = None
    if operation == "workspace.operation.run":
        transient_workflow_id = str(uuid.uuid4())
        workflow = {"id": transient_workflow_id, "name": "Explicit layer operation", "createdAt": utc_now(), "steps": [copy.deepcopy(args["step"])]}
        workspace["workflows"].append(workflow)
        _validate(workspace)
        args = {**args, "workflowId": transient_workflow_id}
    worker_operation = {"workspace.operation.run": "workspace.replay", "workspace.preview": "workspace.compose", "workspace.replay": "workspace.replay",
                        "semantic.render": "semantic.render", "animation.render": "animation.gif"}.get(operation)
    if worker_operation is None:
        fail("unknown-workspace-operation", "Unsupported workspace operation.")
    with tempfile.TemporaryDirectory(prefix="cellcounter-workspace-planes-") as directory:
        worker_args = {"workspaceInput": "workspace"}
        inputs, resolved_inputs = {}, []
        if operation != "semantic.render":
            positions, requests = None, None
            if operation in ("workspace.replay", "workspace.operation.run", "animation.render"):
                position_args = {"workspaceInput": "workspace", **{key: args[key] for key in ("workflowId", "planId") if key in args}}
                with runtime.invoke("workspace.positions", position_args, documents={"workspace": workspace}) as planned:
                    positions, requests = planned["result"]["positions"], planned["result"]["requests"]
            inputs, plane_args, resolved_inputs = _inputs(store, document, version, workspace, Path(directory),
                processing=operation in ("workspace.replay", "workspace.operation.run", "animation.render"), positions=positions, requests=requests)
            worker_args["planes"] = plane_args
        if operation != "workspace.preview":
            _retain_resolved(store, document, bindings, resolved_inputs)
        worker_args.update({key: args[key] for key in ("width", "height", "workflowId", "layerId", "planId") if key in args})
        if operation in ("workspace.preview", "animation.render"):
            worker_args.setdefault("width", 768)
            worker_args.setdefault("height", 768)
        with runtime.invoke(worker_operation, worker_args, documents={"workspace": workspace}, inputs=inputs) as result:
            if operation == "workspace.preview":
                from PIL import Image
                width, height = result["result"]["width"], result["result"]["height"]
                raw = result["outputs"][result["result"]["rgbaOutput"]]["absolutePath"].read_bytes()
                image = Image.frombytes("RGBA", (width, height), raw)
                encoded = io.BytesIO()
                image.save(encoded, format="PNG")
                return {"dataUrl": "data:image/png;base64," + base64.b64encode(encoded.getvalue()).decode(), "width": width, "height": height,
                        "workspaceId": record["id"], "version": version["version"], "sourceBindings": bindings, "presentationOnly": True}
            if operation in ("workspace.replay", "workspace.operation.run"):
                changed = _json(result["outputs"][result["result"]["workspaceOutput"]]["absolutePath"].read_bytes(), "replayed workspace")
                if transient_workflow_id:
                    changed["workflows"] = [item for item in changed["workflows"] if item["id"] != transient_workflow_id]
                retained = {item["layerId"]: item for item in planes}
                provenance = {"workspaceId": record["id"], "workspaceVersion": version["version"],
                    "documentPath": version["documentPath"], "documentHash": version["documentHash"],
                    "workflow": copy.deepcopy(next(item for item in workspace["workflows"] if item["id"] == args["workflowId"])),
                    "resolvedInputs": resolved_inputs, "sourceBindings": copy.deepcopy(bindings), "parentPlanes": copy.deepcopy(planes),
                    "engineVersion": result["engineVersion"], "runtimeManifestHash": result["runtimeManifestHash"]}
                for plane in result["result"].get("planes", []):
                    # Canonical input planes remain source-bound. Only generated
                    # output layers become separately retained workspace planes.
                    if any(binding["layerId"] == plane["layerId"] for binding in bindings):
                        continue
                    if plane["layerId"] in retained:
                        continue
                    retained[plane["layerId"]] = {"provenance": copy.deepcopy(provenance), "generation": copy.deepcopy(plane.get("derivation")), **{key: plane[key] for key in ("layerId", "width", "height", "position", "calibration") if key in plane},
                                                   **_retain_output(store, result["outputs"][plane["outputId"]])}
                    if plane.get("supportOutput"):
                        retained[plane["layerId"]]["support"] = _retain_output(store, result["outputs"][plane["supportOutput"]])
                return _save(store, document, changed, revision, record=record, bindings=bindings, planes=list(retained.values()),
                             notes=[*version["notes"], "Replayed layer transforms are presentation metadata; generated planes retain their own engine provenance and are not silently substituted for acquired pixels."])
            if len(document.get("workspaceOutputs", [])) >= MAX_OUTPUTS:
                fail("workspace-output-limit", "The project retains at most 1,000 workspace render outputs.")
            output = {"id": str(uuid.uuid4()), "workspaceId": record["id"], "workspaceVersion": version["version"],
                      "documentPath": version["documentPath"], "documentHash": version["documentHash"],
                      "operation": operation, "arguments": copy.deepcopy(args), "sourceBindings": bindings, "resolvedInputs": resolved_inputs,
                      "files": [_retain_output(store, item) for item in result["outputs"].values()], "metadata": result["result"],
                      "engineVersion": result["engineVersion"], "runtimeManifestHash": result["runtimeManifestHash"],
                      "createdAt": utc_now(), "createdRevision": revision}
            document.setdefault("workspaceOutputs", []).append(output)
            return {"output": describe_output(document, output)}


def materialized_dependencies(image):
    derivation = image.get("derivation", {})
    return copy.deepcopy(derivation.get("resolvedInputs", [])) if derivation.get("kind") == "workspace" else []


def inspect_materialized(document, image):
    derivation = image.get("derivation", {})
    dependencies = materialized_dependencies(image)
    changed = [item.get("imageId", item.get("sourceId")) for item in dependencies if not _current(document, item)]
    external = any(item.get("sourceKind") == "zarr" for item in dependencies)
    return {"imageId": image["id"], "derived": derivation.get("kind") == "workspace",
            "parentInputsCurrent": False if changed else None if external else True, "staleParentImageIds": sorted(set(changed)),
            "sourceVerificationRequired": external,
            "geometry": "retained-generated-grid", "intensityUnits": "processed-source",
            "coordinateIdentity": derivation.get("coordinateIdentity"), "derivation": copy.deepcopy(derivation)}


def _materialization(store, document, record, version, workspace, args):
    from _workbench_store import canonical
    import _workbench_imaging as imaging
    np, = imaging.require("numpy")
    layer = next((item for item in workspace["layers"] if item["id"] == args["layerId"]), None)
    plane = next((item for item in version["planes"] if item["layerId"] == args["layerId"]), None)
    if layer is None or layer["kind"] != "image" or not plane or not plane.get("provenance") or not plane.get("generation"):
        fail("workspace-materialization-source", "Select an intensity plane generated by a retained closed layer operation. Imported display snapshots and semantic classes cannot become acquired intensity implicitly.")
    if not plane.get("support"):
        fail("workspace-materialization-support", "This generated plane predates exact acquired-support retention. Rerun its generating operation before scientific materialization.")
    provenance = copy.deepcopy(plane["provenance"])
    parents = [item for item in provenance.get("resolvedInputs", []) if item.get("imageId") or item.get("sourceKind") == "zarr"]
    # Include the ancestors of generated input planes, retaining each exact selection.
    seen = set()
    pending = list(provenance.get("parentPlanes", []))
    while pending:
        parent = pending.pop()
        key = (parent.get("path"), parent.get("hash"))
        if key in seen:
            continue
        seen.add(key)
        if len(seen) > 256:
            fail("workspace-provenance-limit", "The generated plane has more than 256 retained parent planes.")
        origin = parent.get("provenance", {})
        parents.extend(item for item in origin.get("resolvedInputs", []) if item.get("imageId") or item.get("sourceKind") == "zarr")
        pending.extend(origin.get("parentPlanes", []))
    parents = list({canonical(item): copy.deepcopy(item) for item in parents}.values())
    if not parents:
        fail("workspace-materialization-provenance", "Scientific materialization requires retained canonical acquisition parents.")
    if any(item.get("role") != "raw-source" for item in parents):
        fail("workspace-materialization-role", "A generated intensity grid must come from acquired intensity parents, not instance or semantic class values.")
    changed = [item.get("imageId", item.get("sourceId")) for item in parents if not _current(document, item)]
    if changed:
        fail("workspace-source-stale", "A generating parent changed. Rerun the closed operation before materializing its grid.", {"imageIds": sorted(set(changed))})
    for parent in parents:
        _verify_resolved(store, document, parent)
    values, mask, calibration, _ = _layer_values(store, document, version, workspace, plane["layerId"], plane.get("position", {}))
    if mask is None or not mask.any() or not np.isfinite(values).all():
        fail("workspace-materialization-support", "A finite generated plane and a nonempty exact support mask are required.")
    if calibration and calibration["unit"] not in ("µm", "um", "μm"):
        fail("workspace-materialization-unit", "Scientific materialization currently requires micrometre calibration or explicitly unknown physical spacing.")
    origin = plane["generation"]["origin"]
    pixel_to_workspace = {"a": 1, "b": 0, "c": 0, "d": 1, "tx": origin["x"], "ty": origin["y"]}
    coordinate = {"schemaVersion": 1, "width": int(values.shape[1]), "height": int(values.shape[0]),
                  "pixelToWorkspace": pixel_to_workspace, "generation": plane["generation"], "calibration": calibration,
                  "supportHash": plane["support"]["hash"], "workflow": provenance["workflow"],
                  "parents": [{key: item[key] for key in ("imageId", "sourceHash", "selection", "voxelSizeUm", "sourceSupport", "sourceKind", "sourceId", "metadataHash", "arrayPath", "region", "scale", "translation", "sourceAxes", "readSetHash") if key in item} for item in parents]}
    provenance.update({"resolvedInputs": parents, "workspaceId": record["id"], "workspaceVersion": version["version"],
                       "layerId": layer["id"], "planePath": plane["path"], "planeHash": plane["hash"],
                       "planeSupport": copy.deepcopy(plane["support"]), "generation": copy.deepcopy(plane["generation"]),
                       "pixelToWorkspace": pixel_to_workspace, "coordinateIdentity": hashlib.sha256(canonical(coordinate).encode()).hexdigest(),
                       "outputCalibration": calibration, "position": copy.deepcopy(plane.get("position", {})),
                       "reexecution": {"operation": "workspace-materialize", "schemaVersion": 1}})
    name = args.get("name", layer["name"][:170] + " · scientific grid")
    body = {"workspaceId": record["id"], "workspaceVersion": version["version"], "layerId": layer["id"], "name": name,
            "width": int(values.shape[1]), "height": int(values.shape[0]), "dtype": "float32", "calibration": calibration,
            "validSamples": int(mask.sum()), "totalSamples": int(mask.size), "pixelToWorkspace": pixel_to_workspace,
            "coordinateIdentity": provenance["coordinateIdentity"], "parents": parents,
            "notes": ["Creates an independent single-channel/time-point scientific acquisition; no biological assignment is copied.",
                      "Retained generated pixels and support are used exactly. Subsequent display transforms are not applied.",
                      "Unknown physical calibration remains unknown. Pixel coordinates refer to the generated grid."]}
    body["previewFingerprint"] = hashlib.sha256(canonical({"plan": body, "provenance": provenance, "sourceRevision": document["revision"]}).encode()).hexdigest()
    return body, values, mask, provenance


def _materialize(store, document, plan, values, mask, provenance, revision):
    from _workbench_store import utc_now
    import _workbench_imaging as imaging
    import _workbench_support as support
    import _workbench_preprocessing as preprocessing
    if len(document["images"]) >= 1000:
        fail("project-too-large", "This project retains at most 1,000 scientific acquisitions.")
    tifffile, = imaging.require("tifffile")
    calibration = plan["calibration"]
    voxels = {"x": calibration["x"] if calibration else None, "y": calibration["y"] if calibration else None, "z": None}
    metadata = {"axes": "YX"}
    if calibration:
        for axis in "xy":
            metadata["PhysicalSize" + axis.upper()] = calibration[axis]
            metadata["PhysicalSize" + axis.upper() + "Unit"] = "µm"
    output = io.BytesIO()
    tifffile.imwrite(output, values, ome=True, photometric="minisblack", metadata=metadata)
    raw = output.getvalue()
    path, checksum = store.put_bytes(raw, ".workspace-derived.ome.tif")
    retained_support = support.retain(store, mask, {"kind": "workspace-generated", "coordinateIdentity": provenance["coordinateIdentity"], "planeHash": provenance["planeHash"]})
    from _workbench_store import canonical
    first = next((item for item in provenance["resolvedInputs"] if item.get("imageId")), provenance["resolvedInputs"][0])
    parent = next((item for item in document["images"] if item["id"] == first.get("imageId")), None)
    created = utc_now()
    derivation = {**copy.deepcopy(provenance), "kind": "workspace", "createdRevision": revision, "createdAt": created,
                  "sourceImageId": first.get("imageId"), "sourceHash": first.get("sourceHash", first.get("metadataHash")), "selection": copy.deepcopy(first["selection"]),
                  "sourceFingerprint": preprocessing._source_fingerprint(parent, first["selection"]) if parent else hashlib.sha256(canonical(provenance["resolvedInputs"]).encode()).hexdigest(),
                  "outputHash": checksum, "intensityUnits": "processed-source", "validSupport": retained_support}
    image = {"id": str(uuid.uuid4()), "name": plan["name"], "sourcePath": path, "sourceHash": checksum, "sourceBytes": len(raw),
             "width": plan["width"], "height": plan["height"], "channels": 1, "axes": "YX", "shape": [plan["height"], plan["width"]],
             "dtype": "float32", "zCount": 1, "timeCount": 1, "pxPerUm": 1 / voxels["x"] if voxels["x"] is not None else None,
             "voxelSizeUm": voxels, "timeStepSeconds": None, "calibrationSource": "frozen-workspace-parents" if calibration else "unknown",
             "importedAt": created, "undoStack": [], "validSupport": retained_support, "derivation": derivation}
    document["images"].append(image)
    return {"derivedImageId": image["id"], "image": {key: value for key, value in image.items() if key != "sourcePath"},
            "workspaceId": plan["workspaceId"], "layerId": plan["layerId"], "coordinateIdentity": provenance["coordinateIdentity"], "notes": plan["notes"]}


def reexecute(store, document, image, revision, replacements):
    """Replay frozen generated-plane ancestry through the same fixed TS engine."""
    import _workbench_microscopy_runtime as runtime
    from _workbench_packages import _json
    from _workbench_store import canonical
    derivation = image["derivation"]
    replacement_map = replacements or {}
    memo = {}

    def replay_plane(plane, depth=0):
        if depth > 16 or len(memo) >= 256:
            fail("workspace-reexecution-limit", "Workspace generation ancestry exceeds its bounded replay depth/count.")
        key = (plane["path"], plane["hash"])
        if key in memo:
            return memo[key]
        origin = copy.deepcopy(plane.get("provenance"))
        if not origin:
            memo[key] = copy.deepcopy(plane)
            return memo[key]
        if origin["runtimeManifestHash"] != runtime.describe()["manifestHash"]:
            fail("workspace-runtime-changed", "The frozen microscopy runtime changed. Explicitly run a new workspace operation before using different code.")
        source = store.verify_artifact(origin["documentPath"], origin["documentHash"])
        workspace = _json(source.read_bytes(), "frozen workspace replay")
        bindings = copy.deepcopy(origin.get("sourceBindings", []))
        if not bindings:
            fail("workspace-reexecution-unavailable", "This generated plane predates complete source-binding retention. Rerun its workspace operation explicitly.")
        for binding in bindings:
            if binding.get("sourceKind") == "zarr":
                if not _current(document, binding):
                    fail("workspace-source-stale", "A frozen external source binding is unavailable or changed. Reattach it explicitly before replay.")
                continue
            old_id = binding["imageId"]
            next_id = replacement_map.get(old_id, old_id)
            parent = next((item for item in document["images"] if item["id"] == next_id), None)
            if parent is None:
                fail("workspace-source-missing", "A frozen replay parent is missing.")
            selected = _selection(parent, binding["selection"])
            binding.update(_binding_identity(parent, binding["role"], selected))
            binding["sourcePath"] = parent["sourcePath"]
            layer = next(item for item in workspace["layers"] if item["id"] == binding["layerId"])
            layer["source"]["identity"].update({"id": parent["id"], "sha256": parent["sourceHash"], "name": parent["name"]})
        parents = [replay_plane(parent, depth + 1) for parent in origin.get("parentPlanes", [])]
        workflow = copy.deepcopy(origin["workflow"])
        workspace["workflows"] = [item for item in workspace["workflows"] if item["id"] != workflow["id"]] + [workflow]
        _validate(workspace)
        with runtime.invoke("workspace.positions", {"workspaceInput": "workspace", "workflowId": workflow["id"]}, documents={"workspace": workspace}) as planned:
            positions, requests = planned["result"]["positions"], planned["result"]["requests"]
        with tempfile.TemporaryDirectory(prefix="cellcounter-workspace-reexecute-") as directory:
            inputs, plane_args, resolved = _inputs(store, document, {"bindings": bindings, "planes": parents}, workspace, Path(directory), processing=True, positions=positions, requests=requests)
            _retain_resolved(store, document, bindings, resolved)
            with runtime.invoke("workspace.replay", {"workspaceInput": "workspace", "workflowId": workflow["id"], "planes": plane_args}, documents={"workspace": workspace}, inputs=inputs) as executed:
                candidate = next((item for item in executed["result"].get("planes", []) if item.get("derivation", {}).get("stepIndex") == plane["generation"]["stepIndex"]), None)
                if candidate is None or not candidate.get("supportOutput"):
                    fail("workspace-reexecution-output", "The frozen generating step did not return its exact intensity/support grid.")
                doc_path, doc_hash = store.put_bytes(canonical(workspace).encode(), ".workspace.json")
                updated = {**{key: candidate[key] for key in ("width", "height", "position", "calibration") if key in candidate},
                           "layerId": plane["layerId"], **_retain_output(store, executed["outputs"][candidate["outputId"]]),
                           "support": _retain_output(store, executed["outputs"][candidate["supportOutput"]]), "generation": copy.deepcopy(candidate["derivation"]),
                           "provenance": {**origin, "documentPath": doc_path, "documentHash": doc_hash, "sourceBindings": bindings,
                                          "resolvedInputs": resolved, "parentPlanes": parents}}
                memo[key] = updated
                return updated

    plane = {"layerId": derivation["layerId"], "path": derivation["planePath"], "hash": derivation["planeHash"],
             "generation": derivation["generation"], "provenance": derivation}
    regenerated = replay_plane(plane)
    synthetic_workspace = {"layers": [{"id": regenerated["layerId"], "name": image["name"], "kind": "image"}], "position": regenerated.get("position", {}), "axes": []}
    version = {"version": derivation["workspaceVersion"], "bindings": [], "planes": [regenerated]}
    plan, values, mask, provenance = _materialization(store, document, {"id": derivation["workspaceId"]}, version, synthetic_workspace,
                                                    {"layerId": regenerated["layerId"], "name": image["name"]})
    return _materialize(store, document, plan, values, mask, provenance, revision)


def describe_output(document, output):
    current = _version(_record(document, output["workspaceId"]))
    return {**{key: copy.deepcopy(output[key]) for key in ("id", "workspaceId", "workspaceVersion", "operation", "metadata", "createdAt", "engineVersion")},
            "outputsCurrent": (None if any(binding.get("sourceKind") == "zarr" for binding in output["sourceBindings"]) else True)
                if current["documentHash"] == output["documentHash"] and all(_current(document, binding) for binding in output["sourceBindings"]) else False,
            "sourceVerificationRequired": any(binding.get("sourceKind") == "zarr" for binding in output["sourceBindings"]),
            "files": [{key: copy.deepcopy(item[key]) for key in ("id", "kind", "bytes", "hash", "dtype", "shape") if key in item} for item in output["files"]]}


def prepare_export(store, document, operation, args, revision, request_id, actor):
    from _workbench_exports import _stage_publication
    from _workbench_schema import absolute_path
    from _workbench_store import canonical, utc_now
    import _workbench_microscopy_runtime as runtime
    destination = absolute_path(args["destination"], "destination")
    if destination.exists() or not destination.parent.is_dir():
        fail("destination-exists", "Choose a new export path with an existing parent directory.")
    if len(document.get("imageExports", [])) >= 1000:
        fail("export-limit", "The project export history is full.")
    references = {}
    if operation == "workspace.output.export":
        output = next((item for item in document.get("workspaceOutputs", []) if item["id"] == args["outputId"]), None)
        if output is None:
            fail("workspace-output-not-found", "The retained workspace output is unavailable.")
        artifact = next((item for item in output["files"] if item["id"] == args["artifactId"]), None)
        if artifact is None:
            fail("workspace-artifact-not-found", "Choose an artifactId from workspace.output.list.files.")
        contents = store.verify_artifact(artifact["path"], artifact["hash"]).read_bytes()
        references[artifact["path"]] = artifact["hash"]
        references[output["documentPath"]] = output["documentHash"]
        provenance = {"workspaceOutput": describe_output(document, output), "artifactId": artifact["id"]}
    else:
        record = _record(document, args["workspaceId"])
        version = _version(record)
        workspace = _load(store, version)
        with tempfile.TemporaryDirectory(prefix="cellcounter-workspace-export-") as directory:
            inputs, planes, resolved_inputs = _inputs(store, document, version, workspace, Path(directory), processing=True)
            _retain_resolved(store, document, copy.deepcopy(version["bindings"]), resolved_inputs)
            with runtime.invoke("workspace.export", {"workspaceInput": "workspace", "planes": planes}, documents={"workspace": workspace}, inputs=inputs) as result:
                artifact = _retain_output(store, result["outputs"][result["result"]["projectOutput"]])
                contents = store.verify_artifact(artifact["path"], artifact["hash"]).read_bytes()
                provenance = {"workspace": describe(document, record), "sourceBindings": version["bindings"], "resolvedInputs": resolved_inputs,
                              "engineVersion": result["engineVersion"], "runtimeManifestHash": result["runtimeManifestHash"]}
        references[version["documentPath"]] = version["documentHash"]
    export_id = str(uuid.uuid4())
    provenance.update({"schemaVersion": 1, "exportId": export_id, "operation": operation, "sourceRevision": document["revision"],
                       "requestId": request_id, "actor": actor,
                       "semanticClasses": operation == "workspace.output.export" and output["operation"] == "semantic.render",
                       "presentationOnly": not (operation == "workspace.output.export" and output["operation"] == "semantic.render")})
    provenance_path, provenance_hash = store.put_bytes(canonical(provenance).encode(), ".workspace-export.json")
    output_path, checksum = store.put_bytes(contents, ".workspace-published.bin")
    record = {"id": export_id, "kind": "workspace", "format": artifact["kind"], "destination": str(destination),
              "sha256": checksum, "bytes": len(contents), "createdAt": utc_now(), "sourceRevision": document["revision"],
              "reportPath": output_path, "reportHash": checksum, "provenancePath": provenance_path, "provenanceHash": provenance_hash,
              "inputReferences": [{"path": path, "hash": digest} for path, digest in references.items()]}
    document.setdefault("imageExports", []).append(record)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {"export": {key: record[key] for key in ("id", "format", "destination", "sha256", "bytes")}}, publish, temporary, publication


def artifact_references(document):
    refs, pending, seen = {}, [], set()
    def add_fields(value):
        for path_key, hash_key in (("path", "hash"), ("documentPath", "documentHash"), ("sourcePath", "sourceHash"),
                                   ("labelsPath", "labelsHash"), ("planePath", "planeHash")):
            if value.get(path_key) is not None:
                path, digest = value[path_key], value.get(hash_key)
                if not isinstance(path, str) or not isinstance(digest, str) or len(digest) != 64:
                    fail("invalid-package", "A workspace provenance artifact reference is invalid.")
                if path in refs and refs[path] != digest:
                    fail("invalid-package", "Workspace provenance contains conflicting artifact hashes.")
                refs[path] = digest
    for record in document.get("workspaces", []):
        if record.get("origin"):
            pending.append(record["origin"])
        pending.extend(record["versions"])
        observations = record.get("sourceObservations", {})
        if not isinstance(observations, dict) or len(observations) > 4096:
            fail("invalid-package", "Workspace source observations exceed their bounded identity catalogue.")
        pending.extend(observations.values())
    pending.extend(document.get("workspaceOutputs", []))
    pending.extend(image["derivation"] for image in document.get("images", []) if image.get("derivation", {}).get("kind") == "workspace")
    while pending:
        item = pending.pop()
        if not isinstance(item, dict):
            fail("invalid-package", "Workspace provenance records must be objects.")
        identity = id(item)
        if identity in seen:
            continue
        seen.add(identity)
        if len(seen) > 256000:
            fail("invalid-package", "Workspace provenance exceeds the bounded retained reference count.")
        add_fields(item)
        for key in ("support", "sourceSupport", "planeSupport", "provenance", "metadataReference", "readIdentity"):
            if item.get(key):
                pending.append(item[key])
        for key in ("planes", "bindings", "files", "sourceBindings", "resolvedInputs", "parentPlanes", "observedReads"):
            children = item.get(key, [])
            if not isinstance(children, (list, RecordList)) or len(children) > 1024:
                fail("invalid-package", "Workspace provenance contains an invalid child reference list.")
            pending.extend(children)
    return refs


def validate_document(document):
    records = document.get("workspaces", [])
    if not isinstance(records, (list, RecordList)) or len(records) > MAX_WORKSPACES or sum(len(item["versions"]) for item in records) > MAX_VERSIONS:
        fail("invalid-package", "Retained workspaces exceed their version/count bounds.")
    ids = set()
    for record in records:
        if record["id"] in ids or not record["versions"] or [item["version"] for item in record["versions"]] != list(range(1, len(record["versions"]) + 1)):
            fail("invalid-package", "Workspace identities/version histories are inconsistent.")
        ids.add(record["id"])
        _version(record)
        for version in record["versions"]:
            if len(version["bindings"]) > 256 or len(version["planes"]) > 256:
                fail("invalid-package", "A retained workspace exceeds its layer binding count.")
    artifact_references(document)
    for output in document.get("workspaceOutputs", []):
        if output["workspaceId"] not in ids:
            fail("invalid-package", "A workspace output references an absent workspace.")
