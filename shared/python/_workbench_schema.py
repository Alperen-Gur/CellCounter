"""Versioned command descriptions and validation for the local workbench.

The operation catalogue is shared by graphical clients, CLI and MCP. Its
``inputSchema`` describes the command's arguments, not the transport envelope.
"""
from __future__ import annotations

import copy
import math
from pathlib import Path


class WorkbenchError(Exception):
    def __init__(self, code: str, message: str, details=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


def _object(properties=None, required=()):
    return {"type": "object", "properties": properties or {},
            "required": list(required), "additionalProperties": False}


_STRING = {"type": "string", "minLength": 1, "maxLength": 4096}
_ID = {"type": "string", "minLength": 1, "maxLength": 256}
_SCALE = {"type": "number", "exclusiveMinimum": 0, "maximum": 1000000}
_POINT = {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}
_PARAMETERS = _object({
    "method": {"type": "string", "enum": ["otsu", "manual", "triangle", "li", "yen", "mean", "adaptive"], "default": "otsu"},
    "threshold": {"type": "number", "description": "Threshold in raw source intensity units."},
    "polarity": {"type": "string", "enum": ["bright", "dark", "auto"], "default": "bright"},
    "adaptiveBlockSize": {"type": "integer", "minimum": 3, "maximum": 501, "default": 51,
                          "description": "Odd source-pixel neighbourhood; adaptive method only."},
    "adaptiveOffsetMode": {"type": "string", "enum": ["auto", "manual"], "default": "auto"},
    "adaptiveOffset": {"type": "number", "minimum": 0, "description": "Nonnegative source-intensity offset; manual adaptive offset mode only."},
    "fillHoles": {"type": "boolean", "default": False},
    "minAreaPx": {"type": "integer", "minimum": 1, "maximum": 16000000, "default": 9},
    "minDistancePx": {"type": "integer", "minimum": 1, "maximum": 4096, "default": 8},
    "channel": {"type": "integer", "minimum": 0, "maximum": 31, "default": 0},
    "zProjection": {"type": "string", "enum": ["max", "mean", "middle"], "default": "max"},
})


def _op(name, description, schema, mutating=False, project=True):
    return {"name": name, "description": description, "inputSchema": schema,
            "mutating": mutating, "requiresProject": project}


OPERATIONS = [
    _op("capabilities", "Inspect available operations and image-processing dependencies.", _object(), project=False),
    _op("project.create", "Create a new persistent local workbench project.",
        _object({"name": {"type": "string", "minLength": 1, "maxLength": 200}}, ["name"]), True),
    _op("project.inspect", "Read current project images, revisions and operation history.", _object()),
    _op("image.import", "Copy source images into the project without altering their pixels.",
        _object({"paths": {"type": "array", "items": _STRING, "minItems": 1, "maxItems": 100},
                 "pxPerUm": _SCALE}, ["paths"]), True),
    _op("image.preview", "Read a bounded raw source display preview using the selected channel and projection.",
        _object({"imageId": _ID, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048,
                                           "default": 768},
                 "parameters": _PARAMETERS}, ["imageId"])),
    _op("calibration.set", "Set pixels per micrometre and recalculate current physical measurements.",
        _object({"imageId": _ID, "pxPerUm": _SCALE}, ["imageId", "pxPerUm"]), True),
    _op("analysis.preview", "Preview classical segmentation without changing saved results.",
        _object({"imageId": _ID, "parameters": _PARAMETERS,
                 "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048}}, ["imageId"])),
    _op("analysis.run", "Segment an image and save exact labels and raw-intensity measurements.",
        _object({"imageId": _ID, "parameters": _PARAMETERS}, ["imageId"]), True),
    _op("mask.edit", "Delete, merge or paint polygon labels and recompute their measurements.",
        _object({"imageId": _ID, "action": {"type": "string", "enum": ["delete", "merge", "polygon"]},
                 "labelIds": {"type": "array", "items": {"type": "integer", "minimum": 1,
                                                       "maximum": 4294967295},
                              "minItems": 1, "maxItems": 10000},
                 "labelId": {"type": "integer", "minimum": 1, "maximum": 4294967295},
                 "polygon": {"type": "array", "items": _POINT, "minItems": 3,
                             "maxItems": 10000}}, ["imageId", "action"]), True),
    _op("mask.undo", "Restore the previous mask state and remeasure it with current calibration.",
        _object({"imageId": _ID}, ["imageId"]), True),
    _op("measurements.get", "Read measurements from the current saved labels and calibration.",
        _object({"imageId": _ID}, ["imageId"])),
    _op("summary.get", "Read descriptive per-image and project summaries, without inferential tests.", _object()),
    _op("project.export", "Write a new ZIP containing immutable sources, masks, measurements and provenance.",
        _object({"destination": _STRING}, ["destination"]), True),
]
from _workbench_workflows import operations as _workflow_operations
from _workbench_sweeps import operations as _sweep_operations
from _workbench_sweep_reports import operations as _sweep_report_operations
from _workbench_jobs import operations as _worker_operations
from _workbench_experiments import operations as _experiment_operations
from _workbench_volume import operations as _volume_operations
from _workbench_packages import operations as _package_operations
from _workbench_plugins import operations as _plugin_operations
from _workbench_adaptation import operations as _adaptation_operations
from _workbench_models import operations as _model_operations
from _workbench_review import operations as _review_operations
from _workbench_sources import operations as _source_operations
from _workbench_lineages import operations as _lineage_operations
from _workbench_registration import operations as _registration_operations
from _workbench_comparison import operations as _comparison_operations
from _workbench_composite import operations as _composite_operations
from _workbench_composite_exports import operations as _composite_export_operations
from _workbench_display_presets import operations as _display_preset_operations
from _workbench_display_preset_io import operations as _display_preset_io_operations
from _workbench_assays import operations as _assay_operations
from _workbench_assay_summary import operations as _assay_summary_operations
from _workbench_preprocessing import operations as _preprocessing_operations
from _workbench_variants import operations as _variant_operations
from _workbench_exports import operations as _export_operations
from _workbench_label_import import operations as _label_import_operations
from _workbench_annotations import operations as _annotation_operations
from _workbench_distributed import operations as _distribution_operations
from _workbench_refresh import operations as _refresh_operations
from _workbench_refresh_reports import operations as _refresh_report_operations
from _workbench_graphs import operations as _graph_operations
from _workbench_migration import operations as _migration_operations
from _workbench_workspace import operations as _workspace_operations
from _workbench_sessions import operations as _session_operations
from _workbench_library import operations as _library_operations
from _workbench_zarr import operations as _zarr_operations
from _workbench_omero import operations as _omero_operations
from _workbench_tiled import operations as _tiled_operations
from _workbench_temporal import operations as _temporal_operations
from _workbench_statistics import operations as _statistics_operations
from _workbench_statistics_exports import operations as _statistics_export_operations
OPERATIONS.extend(_workflow_operations())
OPERATIONS.extend(_sweep_operations())
OPERATIONS.extend(_sweep_report_operations())
OPERATIONS.extend(_worker_operations())
OPERATIONS.extend(_experiment_operations())
from _workbench_experiment_layouts import operations as _experiment_layout_operations
OPERATIONS.extend(_experiment_layout_operations())
OPERATIONS.extend(_volume_operations())
OPERATIONS.extend(_package_operations())
OPERATIONS.extend(_plugin_operations())
OPERATIONS.extend(_adaptation_operations())
OPERATIONS.extend(_model_operations())
from _workbench_model_cards import operations as _model_card_operations
OPERATIONS.extend(_model_card_operations())
OPERATIONS.extend(_review_operations())
OPERATIONS.extend(_source_operations())
OPERATIONS.extend(_lineage_operations())
OPERATIONS.extend(_registration_operations())
OPERATIONS.extend(_comparison_operations())
OPERATIONS.extend(_composite_operations())
OPERATIONS.extend(_composite_export_operations())
OPERATIONS.extend(_display_preset_operations())
OPERATIONS.extend(_display_preset_io_operations())
OPERATIONS.extend(_assay_operations())
OPERATIONS.extend(_assay_summary_operations())
OPERATIONS.extend(_preprocessing_operations())
OPERATIONS.extend(_variant_operations())
OPERATIONS.extend(_export_operations())
OPERATIONS.extend(_label_import_operations())
OPERATIONS.extend(_annotation_operations())
OPERATIONS.extend(_distribution_operations())
OPERATIONS.extend(_refresh_operations())
OPERATIONS.extend(_refresh_report_operations())
OPERATIONS.extend(_graph_operations())
OPERATIONS.extend(_migration_operations())
OPERATIONS.extend(_workspace_operations())
OPERATIONS.extend(_session_operations())
OPERATIONS.extend(_library_operations())
OPERATIONS.extend(_zarr_operations())
OPERATIONS.extend(_omero_operations())
OPERATIONS.extend(_tiled_operations())
OPERATIONS.extend(_temporal_operations())
OPERATIONS.extend(_statistics_operations())
OPERATIONS.extend(_statistics_export_operations())
from _workbench_discovery import operations as _discovery_operations
OPERATIONS.extend(_discovery_operations())
from _workbench_pages import operations as _page_operations
OPERATIONS.extend(_page_operations())
from _workbench_catalogues import operations as _catalogue_operations
OPERATIONS.extend(_catalogue_operations())
from _workbench_runtimes import operations as _runtime_operations
OPERATIONS.extend(_runtime_operations())
from _workbench_assay_series import operations as _assay_series_operations
OPERATIONS.extend(_assay_series_operations())
from _workbench_package2 import operations as _package2_operations
OPERATIONS.extend(_package2_operations())
_CELL_RESPONSE_OPERATIONS = {
    "analysis.preview", "analysis.run", "calibration.set", "mask.edit", "mask.undo",
    "volume.analysis.preview", "volume.analysis.run", "volume.calibration.set",
    "volume.mask.edit", "volume.mask.undo", "model.run", "plugin.run",
    "mask.import.preview", "mask.import.run",
}
for _entry in OPERATIONS:
    if _entry["name"] in _CELL_RESPONSE_OPERATIONS:
        _entry["inputSchema"]["properties"]["cellLimit"] = {
            "type": "integer", "minimum": 1, "maximum": 1000,
            "description": "Limit returned measurement rows only; complete labels, measurements and display overlays are preserved. Omit for the compatible complete response.",
        }
_BY_NAME = {entry["name"]: entry for entry in OPERATIONS}


def operation_catalog():
    return copy.deepcopy(OPERATIONS)


def operation_descriptor(name):
    entry = _BY_NAME.get(name)
    return copy.deepcopy(entry) if entry is not None else None


def _bounded_json(value, field, depth=0, budget=None):
    budget = [1024] if budget is None else budget
    budget[0] -= 1
    if depth > 8 or budget[0] < 0:
        raise WorkbenchError("invalid-arguments", f"{field} exceeds the JSON complexity budget.")
    if value is None or type(value) is bool:
        return
    if type(value) in (int, float) and math.isfinite(value):
        return
    if isinstance(value, str) and len(value) <= 4096 and "\x00" not in value:
        return
    if isinstance(value, (dict, list)) and len(value) <= 64:
        for key, item in (value.items() if isinstance(value, dict) else enumerate(value)):
            if isinstance(value, dict) and (not isinstance(key, str) or not key or len(key) > 256 or "\x00" in key):
                raise WorkbenchError("invalid-arguments", f"{field} contains an invalid field name.")
            _bounded_json(item, field, depth + 1, budget)
        return
    raise WorkbenchError("invalid-arguments", f"{field} must contain bounded finite JSON values.")


def validate_value(value, schema, field="arguments"):
    kind = schema.get("type")
    if isinstance(kind, list):
        for alternative in kind:
            try:
                validate_value(value, {**schema, "type": alternative}, field)
                return
            except WorkbenchError:
                pass
        raise WorkbenchError("invalid-arguments", f"{field} must match one of the supported types: {kind}.")
    if kind == "null" and value is None:
        return
    valid = (
        (kind == "object" and isinstance(value, dict)) or
        (kind == "array" and isinstance(value, list)) or
        (kind == "string" and isinstance(value, str)) or
        (kind == "integer" and type(value) is int) or
        (kind == "number" and type(value) in (int, float) and math.isfinite(value))
        or (kind == "boolean" and type(value) is bool)
    )
    if not valid:
        raise WorkbenchError("invalid-arguments", f"{field} must be a finite {kind}.")
    if "enum" in schema and value not in schema["enum"]:
        raise WorkbenchError("invalid-arguments", f"{field} must be one of {schema['enum']}.")
    if kind == "object":
        if len(value) > schema.get("maxProperties", 64):
            raise WorkbenchError("invalid-arguments", f"{field} has too many fields.")
        for key in schema.get("required", ()):
            if key not in value:
                raise WorkbenchError("invalid-arguments", f"{field}.{key} is required.")
        for key, item in value.items():
            if not isinstance(key, str) or not key or len(key) > 256 or "\x00" in key:
                raise WorkbenchError("invalid-arguments", f"{field} contains an invalid field name.")
            properties = schema.get("properties", {})
            if key in properties:
                item_schema = properties[key]
            elif isinstance(schema.get("additionalProperties"), dict):
                item_schema = schema["additionalProperties"]
            elif schema.get("additionalProperties") is True:
                _bounded_json(item, f"{field}.{key}")
                continue
            else:
                raise WorkbenchError("invalid-arguments", f"Unknown field {field}.{key}.")
            validate_value(item, item_schema, f"{field}.{key}")
    elif kind == "array":
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", len(value)):
            raise WorkbenchError("invalid-arguments", f"{field} has an invalid number of items.")
        for index, item in enumerate(value):
            validate_value(item, schema["items"], f"{field}[{index}]")
    elif kind == "string":
        if ((schema.get("minLength", 1) > 0 and not value.strip())
                or len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", 4096)):
            raise WorkbenchError("invalid-arguments", f"{field} must be a bounded string matching its minimum length.")
        if "\x00" in value:
            raise WorkbenchError("invalid-arguments", f"{field} contains an invalid character.")
        if "pattern" in schema:
            import re
            if re.search(schema["pattern"], value) is None:
                raise WorkbenchError("invalid-arguments", f"{field} does not match its declared format.")
    elif kind != "boolean":
        if value < schema.get("minimum", -math.inf) or value > schema.get("maximum", math.inf):
            raise WorkbenchError("invalid-arguments", f"{field} is outside the supported range.")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            raise WorkbenchError("invalid-arguments", f"{field} must be greater than {schema['exclusiveMinimum']}.")


def absolute_path(value, field):
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise WorkbenchError("invalid-path", f"{field} must be an absolute filesystem path.")
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise WorkbenchError("invalid-path", f"{field} must be absolute.")
    return path.resolve()


def validate_request(request):
    if not isinstance(request, dict):
        raise WorkbenchError("invalid-request", "Request must be a JSON object.")
    if type(request.get("schemaVersion")) is not int or request["schemaVersion"] != 1:
        raise WorkbenchError("unsupported-schema", "This runtime supports schemaVersion 1.")
    operation = request.get("operation")
    if not isinstance(operation, str) or operation not in _BY_NAME:
        raise WorkbenchError("unknown-operation", "Operation is not supported.", {"operation": operation})
    request_id = request.get("requestId")
    if not isinstance(request_id, str) or not request_id.strip() or len(request_id) > 256 or "\x00" in request_id:
        raise WorkbenchError("invalid-request", "requestId must be a nonempty string of at most 256 characters.")
    entry = _BY_NAME[operation]
    arguments = request.get("arguments", {})
    validate_value(arguments, entry["inputSchema"])
    if entry["requiresProject"]:
        absolute_path(request.get("projectPath"), "projectPath")
    revision = request.get("expectedRevision")
    if revision is not None and (type(revision) is not int or revision < 0):
        raise WorkbenchError("invalid-request", "expectedRevision must be a nonnegative integer.")
    if (entry["mutating"] and entry.get("requiresExpectedRevision", True) and
            operation not in ("project.create", "package.restore") and revision is None):
        raise WorkbenchError("revision-required", "Mutating operations require expectedRevision. Inspect the project first.")
    actor = request.get("actor", {"kind": "api", "name": "Unspecified client"})
    validate_value(actor, _object({
        "kind": {"type": "string", "enum": ["human", "agent", "cli", "gui", "api", "mcp", "test"]},
        "name": {"type": "string", "minLength": 1, "maxLength": 200},
    }, ["kind", "name"]), "actor")
    return entry, arguments, actor


def analysis_parameters(arguments):
    supplied = arguments.get("parameters", {})
    result = {name: schema["default"] for name, schema in _PARAMETERS["properties"].items()
              if "default" in schema and name not in ("adaptiveBlockSize", "adaptiveOffsetMode", "fillHoles")}
    result.update(supplied)
    if result["method"] == "manual" and "threshold" not in result:
        raise WorkbenchError("invalid-arguments", "A manual threshold in raw intensity units is required.")
    if result["method"] != "manual" and "threshold" in result:
        raise WorkbenchError("invalid-arguments", "threshold only applies to method manual.")
    adaptive_fields = {"adaptiveBlockSize", "adaptiveOffsetMode", "adaptiveOffset"}
    if result["method"] == "adaptive":
        result.setdefault("adaptiveBlockSize", 51)
        result.setdefault("adaptiveOffsetMode", "auto")
        if result["adaptiveBlockSize"] % 2 != 1:
            raise WorkbenchError("invalid-arguments", "adaptiveBlockSize must be odd.")
        if (result["adaptiveOffsetMode"] == "manual") != ("adaptiveOffset" in result):
            raise WorkbenchError("invalid-arguments", "Supply adaptiveOffset exactly when adaptiveOffsetMode is manual.")
    elif adaptive_fields & set(result):
        raise WorkbenchError("invalid-arguments", "Adaptive controls apply only to method adaptive.")
    return result
