"""Declarative identities for exact local specialist segmentation models.

Registration reads bounded JSON and retains bytes; it never imports a model
package or deserializes executable checkpoint formats in the shared runtime.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import re
from pathlib import Path

BACKENDS = ("stardist2d", "omnipose", "micro-sam")
MAX_CONFIG_BYTES = 1024 ** 2


def _fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def _object(fields=None, required=None):
    from _workbench_schema import _object as schema_object
    return schema_object(fields or {}, required or [])


def registration_schema(backend=None):
    omni = {
        "nChannels": {"type": "integer", "enum": [1, 2], "default": 1, "title": "Network input channels"},
        "nClasses": {"type": "integer", "enum": [3, 4], "default": 3, "title": "Network output classes"},
        "diamMean": {"type": "number", "minimum": 0.001, "maximum": 4096, "default": 30,
                     "title": "Checkpoint training diameter (pixels)"},
    }
    sam = {
        "modelType": {"type": "string", "enum": ["vit_b", "vit_l", "vit_h"], "title": "SAM architecture"},
        "segmentationMode": {"type": "string", "enum": ["amg", "ais", "apg"], "title": "Automatic segmentation mode"},
    }
    return _object(omni if backend == "omnipose" else sam if backend == "micro-sam" else
                   {} if backend is not None else {**omni, **sam},
                   list(sam) if backend == "micro-sam" else [])


def inference_schema(backend, config=None):
    config = config or {}
    device = {"device": {"type": "string", "enum": ["auto", "cpu"], "default": "auto", "title": "Execution device"}}
    size = {"type": "integer", "minimum": 0, "maximum": 16000000, "default": 0, "title": "Minimum object area (pixels)"}
    unit = lambda title, default: {"type": "number", "minimum": 0, "maximum": 1, "default": default, "title": title}
    channel = lambda title: {"type": "integer", "minimum": 0, "maximum": 65535, "title": title,
                             "description": "Zero-based acquired source channel index; never synthetic grayscale replication."}
    if backend == "stardist2d":
        values = {**device, "probThreshold": {"type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 1,
                    "title": "Object probability threshold", "description": "Omit to use the retained threshold file, or the explicit StarDist default 0.5."},
                  "nmsThreshold": {"type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 1,
                    "title": "Nonmaximum suppression threshold", "description": "Omit to use the retained threshold file, or the explicit StarDist default 0.4."},
                  "normalization": {"type": "string", "enum": ["percentile", "none"], "default": "percentile", "title": "Input normalization"},
                  "lowerPercentile": {"type": "number", "minimum": 0, "maximum": 100, "default": 1, "title": "Lower normalization percentile"},
                  "upperPercentile": {"type": "number", "minimum": 0, "maximum": 100, "default": 99.8, "title": "Upper normalization percentile"},
                  "minSize": size}
        if config.get("inputChannels") == 3 or not config:
            values.update({"additionalChannel1": channel("Second acquired channel index"),
                           "additionalChannel2": channel("Third acquired channel index")})
        return _object(values, ["additionalChannel1", "additionalChannel2"] if config.get("inputChannels") == 3 else [])
    if backend == "omnipose":
        values = {**device,
                  "diameterPx": {"type": "number", "minimum": 0, "maximum": 4096, "default": 0,
                                 "title": "Rescale diameter (pixels; 0 keeps native scale)"},
                  "maskThreshold": {"type": "number", "minimum": -20, "maximum": 20, "default": 0, "title": "Mask threshold"},
                  "flowThreshold": {"type": "number", "minimum": 0, "maximum": 10, "default": .4, "title": "Flow error threshold"},
                  "resample": {"type": "boolean", "default": True, "title": "Resample flows to the source grid"},
                  "cluster": {"type": "boolean", "default": True, "title": "Cluster flow endpoints"},
                  "minSize": {**size, "default": 15},
                  "invert": {"type": "boolean", "default": False, "title": "Invert intensity for inference"}}
        if config.get("nChannels") == 2 or not config:
            values["additionalChannel1"] = channel("Second acquired channel index")
        return _object(values, ["additionalChannel1"] if config.get("nChannels") == 2 else [])
    if backend != "micro-sam":
        _fail("unsupported-model-backend", "Select a supported exact local model adapter.")
    common = {**device, "minSize": size}
    amg = {"pointsPerSide": {"type": "integer", "minimum": 2, "maximum": 128, "default": 32, "title": "Prompt grid points per side"},
           "predIoUThreshold": unit("Predicted mask IoU threshold", .88),
           "stabilityThreshold": unit("Mask stability threshold", .95),
           "boxNMSThreshold": unit("Bounding-box suppression threshold", .7)}
    decoder = {"centerDistanceThreshold": unit("Center distance threshold", .5),
               "boundaryDistanceThreshold": unit("Boundary distance threshold", .5),
               "foregroundThreshold": unit("Foreground threshold", .5)}
    ais = {**decoder,
           "foregroundSmoothing": {"type": "number", "minimum": 0, "maximum": 32, "default": 1, "title": "Foreground smoothing (pixels)"},
           "distanceSmoothing": {"type": "number", "minimum": 0, "maximum": 32, "default": 1.6, "title": "Distance smoothing (pixels)"}}
    apg = {**decoder, "nmsThreshold": unit("Mask suppression threshold", .9),
           "multimasking": {"type": "boolean", "default": False, "title": "Generate multiple mask candidates"},
           "refineWithBoxes": {"type": "boolean", "default": False, "title": "Refine with derived box prompts"}}
    mode = config.get("segmentationMode")
    return _object({**common, **(amg if mode == "amg" else ais if mode == "ais" else apg if mode == "apg" else {**amg, **ais, **apg})})


def catalog():
    definitions = [
        ("stardist2d", "StarDist 2D", [
            "Exact retained configuration and HDF5 weights; one or three acquired channels according to the configuration.",
            "Probability and NMS thresholds change segmentation. They are separate from display visibility and are not calibrated accuracy estimates."]),
        ("omnipose", "Omnipose 2D", [
            "Exact local cellpose_omni checkpoint with explicitly recorded network channels and classes.",
            "Omnipose dynamics are enabled explicitly. A diameter of zero preserves native scale; no model alias or size predictor is substituted."]),
        ("micro-sam", "micro-SAM 2D", [
            "Exact local SAM checkpoint and explicit architecture/mode; automatic AMG, decoder-based AIS or APG.",
            "AIS/APG require a decoder in that exact checkpoint. Missing decoders or incompatible APIs fail; no automatic mode fallback.",
            "One selected grayscale acquisition is supplied to micro-SAM's documented image conversion; no extra biological channels are invented."]),
    ]
    return [{"id": backend, "name": name, "dimensions": [2], "supportsTraining": False,
             "inferenceSchema": inference_schema(backend), "registrationSchema": registration_schema(backend),
             "fileInputs": ([{"key": "configPath", "name": "StarDist config.json", "required": True},
                             {"key": "thresholdsPath", "name": "StarDist thresholds.json", "required": False}]
                            if backend == "stardist2d" else []),
             "maxCheckpointBytes": 2 * 1024 ** 3 if backend == "micro-sam" else 512 * 1024 ** 2,
             "notes": notes + ["No package installation, model download or substitute checkpoint is performed.",
                               "Inference retains exact source-grid labels; quantitative fluorescence measurements use the selected anchor channel."]}
            for backend, name, notes in definitions]


def _json_file(value, field):
    from _workbench_schema import absolute_path
    path = absolute_path(value, field)
    if not path.is_file() or path.is_symlink() or not 1 <= path.stat().st_size <= MAX_CONFIG_BYTES:
        _fail("invalid-model-config", "Select a regular JSON configuration no larger than 1 MiB.")
    data = path.read_bytes()
    try:
        parsed = json.loads(data)
        json.dumps(parsed, allow_nan=False)
    except (ValueError, UnicodeError, RecursionError):
        _fail("invalid-model-config", "The model configuration must be finite, bounded JSON.")
    if not isinstance(parsed, dict):
        _fail("invalid-model-config", "The model configuration must be a JSON object.")
    return path, parsed, data


def register_extras(store, args, primary):
    from _workbench_plugins import validate_parameters
    backend = args["backend"]
    config = validate_parameters({"parameters": registration_schema(backend)}, args.get("registrationConfig", {}))
    artifacts = [primary]
    if backend == "stardist2d":
        if not args.get("configPath"):
            _fail("model-config-required", "Select the exact StarDist config.json belonging to these weights.")
        path, value, content = _json_file(args["configPath"], "configPath")
        if (type(value.get("n_dim", 2)) is not int or value.get("n_dim", 2) != 2
                or type(value.get("n_channel_in")) is not int or value.get("n_channel_in") not in (1, 3)
                or value.get("n_classes") not in (None, 0) or value.get("axes", "YXC") != "YXC"):
            _fail("unsupported-stardist-config", "This adapter supports two-dimensional YXC StarDist instance models with one or three acquired channels and no separate object-class head.")
        config = {"inputChannels": value["n_channel_in"], "axes": "YXC", "dimensions": 2}
        reference, digest = store.put_bytes(content, ".stardist-config.json")
        size = len(content)
        artifacts.append({"role": "config", "path": reference, "hash": digest, "bytes": size, "filename": "config.json"})
        if args.get("thresholdsPath"):
            path, value, content = _json_file(args["thresholdsPath"], "thresholdsPath")
            if set(value) != {"prob", "nms"} or any(type(v) not in (int, float) or not math.isfinite(v) or not 0 < v < 1 for v in value.values()):
                _fail("invalid-stardist-thresholds", "The threshold file must contain finite prob and nms values strictly between zero and one.")
            reference, digest = store.put_bytes(content, ".stardist-thresholds.json")
            size = len(content)
            artifacts.append({"role": "thresholds", "path": reference, "hash": digest, "bytes": size, "filename": "thresholds.json"})
    elif args.get("configPath") or args.get("thresholdsPath"):
        _fail("unexpected-model-artifact", "Separate config/threshold files apply only to StarDist; this backend uses explicit registration controls.")
    result = {"modelArtifacts": artifacts, "registrationConfig": config, "registrationConfigHash": _digest(config)}
    result["artifactSetHash"] = artifact_set_hash(artifacts)
    return result


def artifact_set_hash(artifacts):
    return _digest([{key: item[key] for key in ("role", "hash", "bytes", "filename")}
                    for item in sorted(artifacts, key=lambda item: item["role"])])


def validate_model_artifacts(document):
    for model in document.get("models", []):
        if model.get("backend") not in BACKENDS:
            if any(key in model for key in ("modelArtifacts", "registrationConfig", "registrationConfigHash", "artifactSetHash")):
                _fail("invalid-package", "Unexpected compound artifact metadata on a legacy Cellpose record.")
            continue
        artifacts = model.get("modelArtifacts")
        config = model.get("registrationConfig")
        if not isinstance(artifacts, list) or not 1 <= len(artifacts) <= 3 or not isinstance(config, dict):
            _fail("invalid-package", "The specialist model has incomplete compound artifact metadata.")
        roles = set()
        for item in artifacts:
            if (not isinstance(item, dict) or set(item) != {"role", "path", "hash", "bytes", "filename"}
                    or item["role"] not in ("checkpoint", "config", "thresholds") or item["role"] in roles
                    or not isinstance(item["hash"], str) or not re.fullmatch(r"[0-9a-f]{64}", item["hash"])
                    or not isinstance(item["path"], str) or not item["path"].startswith("artifacts/" + item["hash"] + ".")
                    or type(item["bytes"]) is not int or not 1 <= item["bytes"] <= (2 * 1024 ** 3 if item["role"] == "checkpoint" and model["backend"] == "micro-sam" else 512 * 1024 ** 2 if item["role"] == "checkpoint" else MAX_CONFIG_BYTES)
                    or item["filename"] not in ("weights.h5", "weights.weights.h5", "checkpoint.pt", "config.json", "thresholds.json")):
                _fail("invalid-package", "A specialist model artifact has invalid identity, role or bounds.")
            roles.add(item["role"])
            allowed = ({"checkpoint": (("weights.h5", ".stardist.h5"), ("weights.weights.h5", ".stardist.weights.h5")),
                        "config": (("config.json", ".stardist-config.json"),),
                        "thresholds": (("thresholds.json", ".stardist-thresholds.json"),)}
                       if model["backend"] == "stardist2d" else
                       {"checkpoint": (("checkpoint.pt", ".omnipose" if model["backend"] == "omnipose" else ".microsam"),)})
            if not any(item["filename"] == filename and item["path"] == "artifacts/" + item["hash"] + suffix
                       for filename, suffix in allowed.get(item["role"], ())):
                _fail("invalid-package", "A specialist artifact filename or retained suffix does not match its backend and role.")
        primary = next((item for item in artifacts if item["role"] == "checkpoint"), None)
        if (primary is None or primary["path"] != model.get("checkpointPath") or primary["hash"] != model.get("checkpointHash")
                or primary["bytes"] != model.get("checkpointBytes") or _digest(config) != model.get("registrationConfigHash")
                or artifact_set_hash(artifacts) != model.get("artifactSetHash")):
            _fail("invalid-package", "The specialist model's retained identity is inconsistent.")
        if model["backend"] == "stardist2d":
            if ("config" not in roles or type(config.get("inputChannels")) is not int or type(config.get("dimensions")) is not int
                    or config not in ({"inputChannels": 1, "axes": "YXC", "dimensions": 2}, {"inputChannels": 3, "axes": "YXC", "dimensions": 2})):
                _fail("invalid-package", "The StarDist source configuration is missing or unsupported.")
        else:
            from _workbench_plugins import validate_parameters
            if roles != {"checkpoint"} or validate_parameters({"parameters": registration_schema(model["backend"])}, config) != config:
                _fail("invalid-package", "The specialist registration controls are invalid.")
