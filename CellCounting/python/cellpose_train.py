#!/usr/bin/env python3
"""Train Cellpose 3.x on staged corrected labels, then evaluate held-out images.

One train_seg call preserves optimizer state. Cellpose's real logging events
supply sparse live losses; no timer, generated metric, or empty checkpoint is a
successful result. Validation selects weights; test is only used after training.
"""
from __future__ import annotations
import argparse
import importlib.metadata
import json
import logging
import math
from pathlib import Path
import re
import sys
import time

from _training_dataset import validate_manifest, load_dataset, evaluate_masks, file_hash


class EarlyStopped(Exception):
    pass


class TrainingLog(logging.Handler):
    """Cellpose 3.x emits real train and validation losses at measured epochs."""
    def __init__(self, model, total, best_path, early_stop):
        super().__init__()
        self.model, self.total, self.best_path, self.early_stop = model, total, best_path, early_stop
        self.started = time.monotonic()
        self.best = math.inf
        self.stale = 0
        self.epoch = 0
        self.history = []

    def emit(self, record):
        match = re.search(r"^(\d+), train_loss=([\deE.+-]+), test_loss=([\deE.+-]+), LR=([\deE.+-]+)", record.getMessage())
        if not match:
            return
        epoch = int(match[1]) + 1
        train_loss, val_loss, lr = map(float, match.groups()[1:])
        if not all(math.isfinite(v) for v in (train_loss, val_loss, lr)):
            raise ValueError("Training produced non-finite loss")
        self.epoch = epoch
        self.history.append(dict(epoch=epoch, trainLoss=train_loss, validationLoss=val_loss, learningRate=lr))
        elapsed = time.monotonic() - self.started
        eta = int(elapsed / epoch * (self.total - epoch))
        print(f"EPOCH {epoch} train={train_loss} val={val_loss} eta={eta} lr={lr}", flush=True)
        if val_loss < self.best:
            self.best, self.stale = val_loss, 0
            self.model.net.save_model(str(self.best_path))
        else:
            self.stale += 1
        # Patience is measured validation checks (Cellpose checks at 0, 5, 10...).
        if self.early_stop and self.stale >= 5:
            raise EarlyStopped()


def require_checkpoint(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_size < 1024:
        raise ValueError("Training did not produce a usable checkpoint")


def run(args):
    manifest = validate_manifest(args.manifest)
    version = importlib.metadata.version("cellpose")
    if version.split(".")[0] != "3":
        raise ValueError("Fine-tuning requires the installed Cellpose 3.x environment")
    import numpy as np
    import torch
    from cellpose import models, train
    from _imageio import load_planes
    if args.epochs < 6 or args.batch_size < 1 or not math.isfinite(args.lr) or args.lr <= 0:
        raise ValueError("Use at least six epochs (Cellpose warm-up and validation), a positive batch size and learning rate")
    np.random.seed(manifest["split"]["seed"] % (2 ** 32))
    torch.manual_seed(manifest["split"]["seed"] % (2 ** 32))
    device = torch.device("cpu" if getattr(args, "device", "auto") == "cpu" else "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu")
    print(f"DEVICE {device.type}", file=sys.stderr, flush=True)
    print("STATUS Loading raw source planes and reviewed labels", flush=True)
    splits = load_dataset(manifest, load_planes)
    if args.resume:
        require_checkpoint(args.resume)
        pretrained = args.resume
    else:
        alias = {"cp-cyto3": "cyto3", "cp-nuclei": "nuclei"}.get(args.base_model)
        if not alias:
            raise ValueError("Choose a Cellpose 3.x base model or a registered Cellpose 3.x checkpoint")
        # Do not initiate an implicit model download from the training wizard.
        candidates = list(Path(models.MODEL_DIR).glob(alias + "*"))
        candidates = [p for p in candidates if p.is_file() and p.stat().st_size >= 1024 and not p.name.endswith(".npy")]
        if not candidates:
            raise ValueError(f"Install {alias} in Models before training")
        pretrained = str(sorted(candidates)[0])
    model = models.CellposeModel(gpu=device.type != "cpu", device=device, pretrained_model=pretrained)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    best = output.with_suffix(".best")
    handler = TrainingLog(model, args.epochs, best, bool(args.early_stop))
    logger = logging.getLogger("cellpose.train")
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    train_images, train_masks, _ = zip(*splits["train"])
    val_images, val_masks, _ = zip(*splits["validation"])
    print("STATUS Training; losses appear when Cellpose measures validation", flush=True)
    try:
        # Official Cellpose 3.1 API: train_seg returns (path, losses, test_losses).
        # 'test_data' here means validation, never the held-out reporting split.
        trained_path, train_losses, val_losses = train.train_seg(
            model.net, train_data=list(train_images), train_labels=list(train_masks),
            test_data=list(val_images), test_labels=list(val_masks), n_epochs=args.epochs,
            learning_rate=args.lr, batch_size=args.batch_size, channels=[0, 0],
            normalize=True, rescale=False, scale_range=1.0 if args.augment else 0.0,
            min_train_masks=1, save_path=str(output.parent), model_name=output.stem + "-last",
            save_every=max(1, args.epochs), weight_decay=1e-5, SGD=False)
        if not np.all(np.isfinite(train_losses)):
            raise ValueError("Training returned non-finite losses")
        require_checkpoint(trained_path)
    except EarlyStopped:
        print(f"EARLY_STOPPED epoch={handler.epoch}", flush=True)
    finally:
        logger.removeHandler(handler)
    # Only validation-selected weights are eligible for the final evaluation.
    require_checkpoint(best)
    selected = models.CellposeModel(gpu=device.type != "cpu", device=device, pretrained_model=str(best))
    selected.net.save_model(str(output))
    require_checkpoint(output)
    # Reload the final saved checkpoint, so the report verifies what is activated.
    final = models.CellposeModel(gpu=device.type != "cpu", device=device, pretrained_model=str(output))
    print("STATUS Evaluating every held-out test image", flush=True)
    predictions, truths = [], []
    for image, mask, entry in splits["test"]:
        predictions.append(final.eval(image, channels=[0, 0], diameter=None)[0])
        truths.append(mask)
    metrics = evaluate_masks(predictions, truths)
    report = dict(version=1, kind="cellpose", cellposeVersion=version, checkpointHash=file_hash(output),
                  dataset=manifest, metrics=metrics, history=handler.history,
                  selectedValidationLoss=handler.best, diameterErrorUnit="px", checkpointValidated=True)
    report_path = output.with_suffix(".json")
    report_path.write_text(json.dumps(report, indent=2, allow_nan=False))
    best.unlink(missing_ok=True)
    print("DONE " + json.dumps(metrics, allow_nan=False), flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--epochs", type=int, required=True)
    parser.add_argument("--lr", type=float, required=True)
    parser.add_argument("--batch-size", type=int, required=True)
    parser.add_argument("--augment", type=int, choices=[0, 1], default=1)
    parser.add_argument("--base-model", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--resume")
    parser.add_argument("--device", choices=["auto", "cpu"], default="auto")
    parser.add_argument("--early-stop", type=int, choices=[0, 1], default=1)
    args = parser.parse_args(argv)
    output = Path(args.output)
    if output.exists() or output.with_suffix(".json").exists():
        print(json.dumps({"error": "Choose a new output path; an existing checkpoint will not be overwritten"}), flush=True)
        return 2
    success = False
    try:
        run(args)
        success = True
        return 0
    except Exception as exc:
        print(json.dumps({"error": str(exc)}), flush=True)
        return 2
    finally:
        output.with_suffix(".best").unlink(missing_ok=True)
        (output.parent / "models" / (output.stem + "-last")).unlink(missing_ok=True)
        if not success:
            output.unlink(missing_ok=True)
            output.with_suffix(".json").unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
