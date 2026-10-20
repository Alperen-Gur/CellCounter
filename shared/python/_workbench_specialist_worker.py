"""Explicit isolated StarDist, Omnipose and micro-SAM inference; no downloads."""
from __future__ import annotations

import argparse
import importlib.metadata
import inspect
import json
import os
from pathlib import Path
import re
import socket
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _workbench_cellpose_worker import _hash, _write, EnvironmentChanged


def _no_network(*_args, **_kwargs):
    raise RuntimeError("Model downloads/network access are disabled. Register the exact local checkpoint and a compatible installed environment.")


def _require_api(function, names, label):
    parameters = inspect.signature(function).parameters
    missing = set(names) - set(parameters)
    if missing:
        raise ValueError(f"The installed {label} API is incompatible: missing {', '.join(sorted(missing))}. Bind a compatible local environment; no fallback model or algorithm is selected.")


def _torch_device(choice):
    import torch
    # Omnipose currently supports CUDA/CPU reliably; micro-SAM chooses the same
    # explicitly bounded device policy instead of an implicit package fallback.
    return torch.device("cuda" if choice == "auto" and torch.cuda.is_available() else "cpu")


def _runtime(request):
    backend = request["backend"]
    if backend == "stardist2d":
        import tensorflow as tf
        from stardist.models import StarDist2D, Config2D
        from csbdeep.utils import normalize
        _require_api(StarDist2D.predict_instances, ["img", "prob_thresh", "nms_thresh"], "StarDist predict_instances")
        return {"backendVersion": importlib.metadata.version("stardist"),
                "versions": {"stardist": importlib.metadata.version("stardist"), "tensorflow": tf.__version__},
                "tensorflowGPU": bool(tf.config.list_physical_devices("GPU"))}, (StarDist2D, Config2D, normalize, tf)
    if backend == "omnipose":
        import torch
        from cellpose_omni.models import CellposeModel
        _require_api(CellposeModel, ["pretrained_model", "model_type", "omni", "nchan", "nclasses", "dim", "net_avg"], "Omnipose constructor")
        _require_api(CellposeModel.eval, ["channels", "channel_axis", "omni", "mask_threshold", "flow_threshold", "resample", "cluster", "diameter", "rescale", "min_size", "net_avg"], "Omnipose eval")
        return {"backendVersion": importlib.metadata.version("omnipose"),
                "versions": {"omnipose": importlib.metadata.version("omnipose"), "torch": torch.__version__},
                "cuda": bool(torch.cuda.is_available()), "mps": False}, CellposeModel
    if backend != "micro-sam":
        raise ValueError("Unknown specialist backend.")
    import torch
    from micro_sam import automatic_segmentation as automatic
    from micro_sam import instance_segmentation as instances
    _require_api(automatic.get_predictor_and_segmenter, ["model_type", "checkpoint", "segmentation_mode", "device", "is_tiled"], "micro-SAM constructor")
    function = getattr(automatic, "automatic_instance_segmentation", None)
    if function is None:
        raise ValueError("This adapter requires micro-SAM's automatic_instance_segmentation API. Bind a compatible local environment; older signature guesses are not used.")
    _require_api(function, ["predictor", "segmenter", "input_path", "ndim", "annotate", "output_path", "embedding_path"], "micro-SAM automatic inference")
    version = importlib.metadata.version("micro-sam")
    mode = request["registrationConfig"]["segmentationMode"]
    match = re.match(r"^(\d+)\.(\d+)", version)
    if mode == "apg" and (not match or tuple(map(int, match.groups())) < (1, 7)):
        raise ValueError("Automatic prompt generation requires micro-SAM 1.7 or later with the supported APG API.")
    class_name = {"amg": "AutomaticMaskGenerator", "ais": "InstanceSegmentationWithDecoder", "apg": "AutomaticPromptGenerator"}[mode]
    generator = getattr(instances, class_name, None)
    if generator is None:
        raise ValueError(f"The installed micro-SAM runtime does not provide the requested {mode.upper()} generator.")
    return {"backendVersion": version, "versions": {"micro-sam": version, "torch": torch.__version__},
            "segmentationMode": mode, "cuda": bool(torch.cuda.is_available()), "mps": False,
            "decoderRequired": mode in ("ais", "apg")}, (automatic.get_predictor_and_segmenter, function, generator)


def _artifacts(request):
    artifacts = {}
    for item in request["modelArtifacts"]:
        path = Path(item["path"])
        if (not path.is_file() or path.is_symlink() or path.stat().st_size != item["bytes"] or _hash(path) != item["hash"]):
            raise ValueError("A retained model artifact changed before inference.")
        artifacts[item["role"]] = path
    primary = next((item for item in request["modelArtifacts"] if item["role"] == "checkpoint"), None)
    if primary is None or primary["hash"] != request["checkpointHash"]:
        raise ValueError("The exact primary checkpoint identity is missing.")
    return artifacts


def _stardist(raw, request, artifacts, api):
    import numpy as np
    Model, Config, normalize, tf = api
    p = request["parameters"]
    if p["device"] == "cpu":
        tf.config.set_visible_devices([], "GPU")
    config = json.loads(artifacts["config"].read_text())
    expected_channels = request["registrationConfig"]["inputChannels"]
    if config.get("n_channel_in") != expected_channels or (raw.ndim == 3 and raw.shape[-1] != expected_channels):
        raise ValueError("StarDist source channels do not match the retained configuration.")
    model = Model(Config(**config), name=None, basedir=None)
    # basedir=None prevents implicit directory weights/threshold selection.
    # load_weights receives the one verified retained file explicitly.
    model.load_weights(str(artifacts["checkpoint"]))
    thresholds = json.loads(artifacts["thresholds"].read_text()) if "thresholds" in artifacts else {"prob": .5, "nms": .4}
    probability, nms = p.get("probThreshold", thresholds["prob"]), p.get("nmsThreshold", thresholds["nms"])
    image = raw.astype(np.float32)
    if p["normalization"] == "percentile":
        image = normalize(image, pmin=p["lowerPercentile"], pmax=p["upperPercentile"], axis=(0, 1), clip=False)
    labels, _ = model.predict_instances(image, axes="YXC" if raw.ndim == 3 else "YX",
                                        prob_thresh=probability, nms_thresh=nms, show_tile_progress=False)
    return labels, {"effectiveThresholds": {"prob": probability, "nms": nms},
                    "normalization": {"method": p["normalization"], "lowerPercentile": p["lowerPercentile"], "upperPercentile": p["upperPercentile"], "perChannel": True}}


def _omnipose(raw, request, artifacts, Model):
    p, config = request["parameters"], request["registrationConfig"]
    device = _torch_device(p["device"])
    if p["diameterPx"] > 0 and raw.shape[0] * raw.shape[1] * (config["diamMean"] / p["diameterPx"]) ** 2 > 64000000:
        raise ValueError("The requested Omnipose rescaling exceeds 64 million pixels. Increase the diameter or use a smaller region.")
    model = Model(pretrained_model=str(artifacts["checkpoint"]), model_type=None, net_avg=False,
                  gpu=device.type == "cuda", device=device, omni=True, nchan=config["nChannels"],
                  nclasses=config["nClasses"], dim=2, diam_mean=config["diamMean"])
    # Explicit None selects the acquired channel axis as supplied; grayscale
    # nchan=1 uses the documented [0,0] selector without inventing a second input.
    kwargs = {"channels": None if raw.ndim == 3 else [0, 0], "channel_axis": -1 if raw.ndim == 3 else None,
              "diameter": p["diameterPx"] or None, "rescale": 1.0 if p["diameterPx"] == 0 else None,
              "omni": True, "mask_threshold": p["maskThreshold"], "flow_threshold": p["flowThreshold"],
              "resample": p["resample"], "cluster": p["cluster"], "min_size": p["minSize"],
              "invert": p["invert"], "normalize": True, "net_avg": False,
              "do_3D": False, "show_progress": False, "verbose": False}
    labels, *_ = model.eval(raw, **kwargs)
    return labels, {"device": str(device), "normalization": {"method": "omnipose-percentile", "lowerPercentile": 1, "upperPercentile": 99},
                    "omni": True, "diameterPx": p["diameterPx"], "nativeScale": p["diameterPx"] == 0}


def _micro_sam(raw, request, artifacts, api):
    construct, infer, generator = api
    p, config = request["parameters"], request["registrationConfig"]
    mode, device = config["segmentationMode"], _torch_device(p["device"])
    constructor = {"points_per_side": p["pointsPerSide"]} if mode == "amg" else {}
    if mode == "amg":
        kwargs = {"pred_iou_thresh": p["predIoUThreshold"], "stability_score_thresh": p["stabilityThreshold"],
                  "box_nms_thresh": p["boxNMSThreshold"], "min_mask_region_area": p["minSize"]}
    else:
        kwargs = {"center_distance_threshold": p["centerDistanceThreshold"], "boundary_distance_threshold": p["boundaryDistanceThreshold"],
                  "foreground_threshold": p["foregroundThreshold"], "min_size": p["minSize"]}
        kwargs.update({"foreground_smoothing": p["foregroundSmoothing"], "distance_smoothing": p["distanceSmoothing"]} if mode == "ais"
                      else {"multimasking": p["multimasking"], "nms_threshold": p["nmsThreshold"], "refine_with_box_prompts": p["refineWithBoxes"]})
    _require_api(generator.generate, kwargs, "micro-SAM " + mode.upper() + " generator")
    predictor, segmenter = construct(model_type=config["modelType"], checkpoint=str(artifacts["checkpoint"]),
                                     device=str(device), segmentation_mode=mode, is_tiled=False, **constructor)
    if not isinstance(segmenter, generator):
        raise ValueError("micro-SAM returned a different segmentation mode than the registered one.")
    labels = infer(predictor=predictor, segmenter=segmenter, input_path=raw,
                   output_path=None, embedding_path=None, ndim=2, annotate=False, verbose=False,
                   output_mode="instance_segmentation", **kwargs)
    return labels, {"device": str(device), "segmentationMode": mode, "modelType": config["modelType"],
                    "normalization": {"method": "micro-sam-image-conversion", "implementation": "registered-runtime"},
                    "embeddingCache": "per-call", "headless": True}


def _infer(request, output, api):
    import numpy as np
    artifacts = _artifacts(request)
    raw = np.load(request["rawPath"], allow_pickle=False)
    if (raw.ndim not in (2, 3) or raw.shape[0] * raw.shape[1] > 16000000 or
            (raw.ndim == 3 and raw.shape[-1] not in (2, 3)) or not np.isfinite(raw).all()):
        raise ValueError("A specialist model requires a finite bounded source plane with explicit acquired channels.")
    function = {"stardist2d": _stardist, "omnipose": _omnipose, "micro-sam": _micro_sam}[request["backend"]]
    labels, details = function(raw, request, artifacts, api)
    labels = np.asarray(labels)
    if (labels.shape != raw.shape[:2] or not np.issubdtype(labels.dtype, np.integer) or
            (labels.size and (labels.min() < 0 or labels.max() > np.iinfo(np.uint32).max))):
        raise ValueError("The model returned incompatible labels; no resizing, contour rasterization or relabeling is performed.")
    labels = labels.astype(np.uint32)
    if request["backend"] == "stardist2d" and request["parameters"]["minSize"] > 0:
        identities, counts = np.unique(labels, return_counts=True)
        remove = identities[(identities != 0) & (counts < request["parameters"]["minSize"])]
        labels[np.isin(labels, remove)] = 0
        details["removedBelowMinimumSize"] = int(len(remove))
    np.save(output / "labels.npy", labels, allow_pickle=False)
    return {**details, "labelsHash": _hash(output / "labels.npy"), "shape": list(labels.shape),
            "backend": request["backend"], "coordinateSpace": "source-pixel-edges"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True); parser.add_argument("--output", required=True)
    args = parser.parse_args(); output = Path(args.output)
    try:
        request = json.loads(Path(args.request).read_text())
        from _workbench_environment import capture
        environment = capture()
        expected = request.get("expectedEnvironmentHash")
        if expected is not None and environment["hash"] != expected:
            raise EnvironmentChanged(expected, environment["hash"])
        if request["mode"] == "environment":
            result = {}
        else:
            socket.create_connection = _no_network
            socket.socket.connect = _no_network
            socket.socket.connect_ex = _no_network
            os.environ["HF_HUB_OFFLINE"] = "1"; os.environ["TRANSFORMERS_OFFLINE"] = "1"
            metadata, api = _runtime(request)
            if request["mode"] == "probe":
                result = {**metadata, "available": True, "apiCompatible": True, "checkpointLoaded": False,
                          "supportsTraining": False, "pythonVersion": sys.version.split()[0],
                          "notes": ["Compatibility probe checks the installed API; checkpoint architecture and decoder compatibility are checked during explicit inference."]}
            elif request["mode"] == "infer":
                result = {**metadata, **_infer(request, output, api)}
            else:
                raise ValueError("Specialist adapters support compatibility probe, environment capture and inference only.")
        result["environment"] = environment
        _write(output / "result.json", result); _write(output / "status.json", {"status": "completed"})
        return 0
    except EnvironmentChanged as exc:
        _write(output / "status.json", {"status": "failed", "error": {"code": "model-environment-changed", "message": str(exc),
            "details": {"expectedEnvironmentHash": exc.expected, "observedEnvironmentHash": exc.actual}}})
    except Exception as exc:
        _write(output / "status.json", {"status": "failed", "error": {"code": "model-runtime-error", "message": str(exc)[:2000]}})
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
