"""Local Cellpose 3/4 inference and Cellpose 3 training; no model downloads."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import inspect
import json
import logging
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time

# Isolated interpreter execution still needs the shipped metrics module.
sys.path.insert(0, str(Path(__file__).resolve().parent))


class EarlyStopped(Exception):
    pass


class TrainingCancelled(Exception):
    pass


class EnvironmentChanged(Exception):
    def __init__(self, expected, actual):
        super().__init__("The model's observed Python/package environment changed. Capture and explicitly bind the intended environment before starting new work; existing frozen jobs require their recorded environment.")
        self.expected = expected
        self.actual = actual


def _write(path, value):
    path = Path(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".progress-", delete=False) as output:
            temporary = Path(output.name)
            output.write(json.dumps(value, allow_nan=False).encode())
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class TrainingLog(logging.Handler):
    """Observe actual Cellpose validation events while retaining one optimizer."""
    def __init__(self, model, total, best_path, early_stop, cancel_path=None, progress=None):
        super().__init__()
        self.model, self.total, self.best_path, self.early_stop = model, total, best_path, early_stop
        self.cancel_path, self.progress = cancel_path, progress
        self.started = time.monotonic()
        self.best = math.inf
        self.stale = 0
        self.epoch = 0
        self.history = []

    def emit(self, record):
        if self.cancel_path and Path(self.cancel_path).exists():
            raise TrainingCancelled("Training cancelled at a Cellpose logging boundary.")
        match = re.search(r"^(\d+), train_loss=([\deE.+-]+), test_loss=([\deE.+-]+), LR=([\deE.+-]+)",
                          record.getMessage())
        if not match:
            return
        epoch = int(match[1]) + 1
        train_loss, val_loss, learning_rate = map(float, match.groups()[1:])
        if not all(math.isfinite(value) for value in (train_loss, val_loss, learning_rate)):
            raise ValueError("Training produced non-finite losses.")
        self.epoch = epoch
        self.history.append({"epoch": epoch, "trainLoss": train_loss,
                             "validationLoss": val_loss, "learningRate": learning_rate})
        elapsed = time.monotonic() - self.started
        eta = int(elapsed / epoch * max(0, self.total - epoch))
        print(f"EPOCH {epoch} train={train_loss} val={val_loss} eta={eta} lr={learning_rate}", flush=True)
        if val_loss < self.best:
            self.best, self.stale = val_loss, 0
            self.model.net.save_model(str(self.best_path))
        else:
            self.stale += 1
        if self.progress:
            self.progress({"epoch": epoch, "totalEpochs": self.total, "trainLoss": train_loss,
                           "validationLoss": val_loss, "learningRate": learning_rate,
                           "etaSeconds": eta})
        if self.early_stop and self.stale >= 5:
            raise EarlyStopped()


def require_checkpoint(path, backend="cellpose3"):
    path = Path(path)
    maximum = 2 * 1024 ** 3 if backend == "cellpose4" else 512 * 1024 ** 2
    if not path.is_file() or path.is_symlink() or not 1024 <= path.stat().st_size <= maximum:
        raise ValueError("Cellpose did not provide a bounded usable checkpoint.")


def _runtime(backend="cellpose3"):
    if backend not in ("cellpose3", "cellpose4"):
        raise ValueError("The requested Cellpose backend is unsupported.")
    version = importlib.metadata.version("cellpose")
    major = "4" if backend == "cellpose4" else "3"
    if version.split(".")[0] != major:
        raise ValueError(f"This registered {backend} adapter requires Cellpose {major}.x; found {version}. Rebind the corresponding local environment.")
    import numpy as np
    import torch
    from cellpose import models
    # A registered checkpoint is always supplied. A request for any model
    # download is an implementation error and is refused explicitly.
    def no_download(*args, **kwargs):
        raise RuntimeError("Automatic model downloads are disabled. Register a local checkpoint.")
    import cellpose.utils
    cellpose.utils.download_url_to_file = no_download
    if hasattr(models, "download_url_to_file"):
        models.download_url_to_file = no_download
    # Refuse aliases/cache fallbacks as well as the normal URL download helper.
    # An existing absolute checkpoint path requires neither operation.
    if hasattr(models, "cache_model_path"):
        models.cache_model_path = no_download
    required = {"diameter", "flow_threshold", "cellprob_threshold", "min_size", "normalize"}
    if backend == "cellpose3":
        required.add("channels")
    missing = required - set(inspect.signature(models.CellposeModel.eval).parameters)
    constructor = {"gpu", "device", "pretrained_model"} - set(inspect.signature(models.CellposeModel.__init__).parameters)
    if missing or constructor:
        raise ValueError("Installed Cellpose lacks explicit controls required by this adapter: " +
                         ", ".join(sorted(missing | constructor)) + ". Choose a compatible local environment.")
    return version, np, torch, models


def _device(torch, requested):
    if requested == "cpu":
        return torch.device("cpu")
    return torch.device("cuda" if torch.cuda.is_available() else
                        "mps" if hasattr(torch.backends, "mps") and torch.backends.mps.is_available() else "cpu")


def _model(request):
    backend = request.get("backend", "cellpose3")
    version, np, torch, models = _runtime(backend)
    checkpoint = Path(request["checkpointPath"])
    require_checkpoint(checkpoint, backend)
    if _hash(checkpoint) != request["checkpointHash"]:
        raise ValueError("Registered checkpoint bytes changed.")
    device = _device(torch, request.get("parameters", {}).get("device", "auto"))
    model = models.CellposeModel(gpu=device.type != "cpu", device=device, pretrained_model=str(checkpoint))
    loaded = getattr(model, "pretrained_model", None)
    if not isinstance(loaded, (str, os.PathLike)) or Path(loaded).resolve() != checkpoint.resolve():
        raise ValueError("Cellpose did not confirm the exact registered checkpoint; model substitution is refused.")
    return version, np, torch, models, model, device


def _labels(np, values, shape):
    values = np.asarray(values)
    if values.shape != tuple(shape) or values.dtype.kind not in "iu" or np.any(values < 0):
        raise ValueError("Cellpose labels differ from the original input geometry.")
    unique = np.unique(values)
    if len(unique) - int(0 in unique) > 20000 or int(values.max(initial=0)) > 4294967295:
        raise ValueError("Cellpose returned too many labels.")
    return values.astype(np.uint32)


def _infer(request, output):
    version, np, _, _, model, device = _model(request)
    raw = np.load(request["rawPath"], allow_pickle=False, mmap_mode="r", max_header_size=4096)
    if raw.ndim != 2 or raw.size > 16000000 or not np.isfinite(raw).all():
        raise ValueError("Model inference requires a finite bounded source plane.")
    params = request["parameters"]
    backend = request.get("backend", "cellpose3")
    diameter = params.get("rescaleDiameterPx") if backend == "cellpose4" else params["diameterPx"]
    scale = 1.0 if diameter is None else 30.0 / diameter
    if raw.size * scale * scale > 64000000 or max(raw.shape) * scale > 32768:
        raise ValueError("The requested diameter would exceed 64 million rescaled pixels or a 32,768-pixel side. Use native scale, a larger diameter, or a bounded crop.")
    controls = {"diameter": diameter, "flow_threshold": params["flowThreshold"],
                "cellprob_threshold": params["cellprobThreshold"], "min_size": params["minSize"],
                "normalize": True}
    if backend == "cellpose3":
        controls["channels"] = [0, 0]
    predicted = model.eval(raw, **controls)[0]
    labels = _labels(np, predicted, raw.shape)
    np.save(output / "labels.npy", labels, allow_pickle=False)
    return {"backend": backend, "adapterVersion": backend + "-plane-1", "cellposeVersion": version,
            "device": device.type, "labelsHash": _hash(output / "labels.npy"),
            "inputMode": "selected-grayscale-plane", "normalization": "cellpose-normalize-true",
            "rescaleDiameterPx": diameter, "nativeScale": diameter is None,
            "checkpointHash": request["checkpointHash"], "modelSubstitution": False}


def _train(request, output):
    if request.get("backend", "cellpose3") != "cellpose3":
        raise ValueError("Shared training supports Cellpose 3 only. Use Cellpose 4 for inference.")
    from cellpose import train
    from _workbench_metrics import evaluate_masks, aggregate_metrics
    version, np, torch, models, model, device = _model(request)
    params = request["parameters"]
    np.random.seed(params["seed"] % 2 ** 32)
    torch.manual_seed(params["seed"] % 2 ** 32)
    samples = request["samples"]
    groups, sources = {}, set()
    splits = {"train": [], "validation": [], "test": []}
    total_bytes = 0
    for sample in samples:
        partition, specimen = sample["partition"], sample["specimenId"]
        if partition not in splits or groups.get(specimen, partition) != partition:
            raise ValueError("Training specimens overlap dataset partitions.")
        groups[specimen] = partition
        if sample["sourceHash"] in sources:
            raise ValueError("Duplicate source content in training dataset.")
        sources.add(sample["sourceHash"])
        for kind in ("raw", "labels"):
            if _hash(sample[kind + "Path"]) != sample[kind + "Hash"]:
                raise ValueError("Frozen dataset bytes changed.")
        raw = np.load(sample["rawPath"], allow_pickle=False, mmap_mode="r", max_header_size=4096)
        truth = np.load(sample["labelsPath"], allow_pickle=False, mmap_mode="r", max_header_size=4096)
        if raw.ndim != 2 or raw.shape != truth.shape or list(raw.shape) != sample["shape"] or not np.isfinite(raw).all():
            raise ValueError("A frozen raw plane and its labels have inconsistent geometry.")
        truth = _labels(np, truth, raw.shape)
        if not np.any(truth):
            raise ValueError("Cellpose training requires at least one reviewed instance per sample.")
        # Cellpose requires consecutive labels even when correction IDs are sparse.
        _, dense = np.unique(truth, return_inverse=True)
        dense = dense.reshape(truth.shape).astype(np.int32)
        if 0 not in truth:
            dense += 1
        total_bytes += raw.size * 8
        if total_bytes > 256 * 1024 ** 2:
            raise ValueError("The selected training planes exceed the 256 MiB input budget.")
        splits[partition].append((np.asarray(raw, dtype=np.float32), dense, sample))
    if not all(splits.values()):
        raise ValueError("Train, validation and test partitions must all contain specimens.")
    cancel = output / "cancel.requested"
    status_path = output / "status.json"
    def progress(value):
        _write(status_path, {"status": "running", "phase": "training", "progress": value})
    best = output / "best.checkpoint"
    handler = TrainingLog(model, params["epochs"], best, params["earlyStop"], cancel, progress)
    logger = logging.getLogger("cellpose.train")
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    progress({"epoch": 0, "totalEpochs": params["epochs"]})
    try:
        if cancel.exists():
            raise TrainingCancelled("Training cancelled before starting.")
        trained, losses, validation_losses = train.train_seg(
            model.net, train_data=[item[0] for item in splits["train"]],
            train_labels=[item[1] for item in splits["train"]],
            test_data=[item[0] for item in splits["validation"]],
            test_labels=[item[1] for item in splits["validation"]],
            n_epochs=params["epochs"], learning_rate=params["learningRate"],
            batch_size=params["batchSize"], channels=[0, 0], normalize=True,
            rescale=False, scale_range=1.0 if params["augment"] else 0.0,
            min_train_masks=1, save_path=str(output), model_name="last",
            save_every=params["epochs"], weight_decay=1e-5, SGD=False)
        if not np.isfinite(losses).all() or not np.isfinite(validation_losses).all():
            raise ValueError("Cellpose returned non-finite training losses.")
        require_checkpoint(trained)
    except EarlyStopped:
        pass
    finally:
        logger.removeHandler(handler)
    if cancel.exists():
        raise TrainingCancelled("Training cancelled before checkpoint collection.")
    require_checkpoint(best)
    selected = models.CellposeModel(gpu=device.type != "cpu", device=device, pretrained_model=str(best))
    checkpoint = output / "checkpoint.cp3"
    selected.net.save_model(str(checkpoint))
    require_checkpoint(checkpoint)
    handler.model = None
    del selected, model
    final = models.CellposeModel(gpu=device.type != "cpu", device=device, pretrained_model=str(checkpoint))
    reports = []
    for index, (raw, truth, sample) in enumerate(splits["test"]):
        if cancel.exists():
            raise TrainingCancelled("Training cancelled during held-out evaluation.")
        _write(status_path, {"status": "running", "phase": "evaluating",
                            "progress": {"epoch": handler.epoch, "totalEpochs": params["epochs"],
                                         "testImage": index, "testImages": len(splits["test"])}})
        predicted = _labels(np, final.eval(raw, channels=[0, 0], diameter=None)[0], raw.shape)
        prediction_file = f"prediction-{index}.npy"
        np.save(output / prediction_file, predicted, allow_pickle=False)
        reports.append({"imageId": sample["imageId"], "specimenId": sample["specimenId"],
                        "metrics": evaluate_masks([predicted], [truth]),
                        "predictionFile": prediction_file,
                        "predictionHash": _hash(output / prediction_file)})
    return {"schemaVersion": 1, "backend": "cellpose3", "cellposeVersion": version,
            "device": device.type, "checkpointHash": _hash(checkpoint),
            "runtimeVersions": {"python": sys.version.split()[0], "numpy": np.__version__,
                                "torch": torch.__version__, "cellpose": version},
            "datasetFingerprint": request["datasetFingerprint"], "history": handler.history,
            "selectedValidationLoss": handler.best, "epochsCompleted": handler.epoch,
            "metrics": aggregate_metrics([item["metrics"] for item in reports]), "images": reports,
            "checkpointValidated": True, "validationSelection": "minimum-measured-validation-loss",
            "testUsage": "after-selection-only"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    request = json.loads(Path(args.request).read_text())
    if request["mode"] == "train":
        started = time.monotonic()
        cancel_seen = [None]
        def monitor():
            while True:
                (output / ".heartbeat").touch()
                reason = None
                if time.monotonic() - started > request["parameters"]["timeoutSeconds"]:
                    reason = ("failed", "training-timeout", "Training exceeded its configured time budget.")
                if sum(path.stat().st_size for path in (output / "stdout.log", output / "stderr.log")
                       if path.exists()) > 4 * 1024 ** 2:
                    reason = ("failed", "training-log-limit", "Training exceeded its log budget.")
                if (output / "cancel.requested").exists():
                    cancel_seen[0] = cancel_seen[0] or time.monotonic()
                    # First allow normal logging-boundary cancellation; a
                    # stalled model call is then stopped inside its own process.
                    if time.monotonic() - cancel_seen[0] > 10:
                        reason = ("cancelled", "training-cancelled", "Training stopped after cancellation was requested.")
                if reason:
                    _write(output / "status.json", {"status": reason[0],
                                                    "error": {"code": reason[1], "message": reason[2]}})
                    os._exit(124)
                time.sleep(1)
        _write(output / "status.json", {"status": "running", "phase": "loading",
                                       "progress": {"epoch": 0, "totalEpochs": request["parameters"]["epochs"]}})
        threading.Thread(target=monitor, daemon=True).start()
    try:
        from _workbench_environment import capture
        environment = capture()
        expected_environment = request.get("expectedEnvironmentHash")
        if expected_environment is not None:
            if not isinstance(expected_environment, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_environment):
                raise ValueError("The expected model environment hash is invalid.")
            if environment["hash"] != expected_environment:
                raise EnvironmentChanged(expected_environment, environment["hash"])
        if request["mode"] == "environment":
            result = {"environment": environment}
        elif request["mode"] == "probe":
            backend = request.get("backend", "cellpose3")
            version, _, torch, _ = _runtime(backend)
            result = {"available": True, "cellposeVersion": version, "pythonVersion": sys.version.split()[0],
                      "backend": backend, "apiCompatible": True, "checkpointLoaded": False,
                      "supportsTraining": backend == "cellpose3",
                      "cuda": bool(torch.cuda.is_available()),
                      "mps": bool(hasattr(torch.backends, "mps") and torch.backends.mps.is_available())}
        else:
            result = _train(request, output) if request["mode"] == "train" else _infer(request, output)
        result["environment"] = environment
        _write(output / "result.json", result)
        _write(output / "status.json", {"status": "completed", "phase": "complete"})
        return 0
    except TrainingCancelled as exc:
        _write(output / "status.json", {"status": "cancelled", "error": {"code": "training-cancelled", "message": str(exc)}})
        return 2
    except EnvironmentChanged as exc:
        _write(output / "status.json", {"status": "failed", "error": {
            "code": "model-environment-changed", "message": str(exc),
            "details": {"expectedEnvironmentHash": exc.expected, "observedEnvironmentHash": exc.actual}}})
        return 2
    except Exception as exc:
        _write(output / "status.json", {"status": "failed", "error": {"code": "model-runtime-error", "message": str(exc)[:2000]}})
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
