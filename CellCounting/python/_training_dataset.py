"""Validation and metrics for immutable corrected-mask training datasets.

Train, validation (checkpoint selection), and test (final report only) are
separate specimen groups. No invalid sample is silently dropped.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import numpy as np


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_manifest(path):
    manifest = json.loads(Path(path).read_text())
    if manifest.get("version") != 1:
        raise ValueError("Unsupported training dataset version")
    entries = manifest.get("samples", [])
    groups, hashes, ids = {}, set(), set()
    counts = dict(train=0, validation=0, test=0)
    for entry in entries:
        partition, group = entry["partition"], entry["group"].strip()
        if partition not in counts or not group:
            raise ValueError("Every image needs a specimen group and a valid split")
        if group in groups and groups[group] != partition:
            raise ValueError("Specimen group leaks between dataset splits")
        groups[group] = partition
        if entry["id"] in ids:
            raise ValueError("Duplicate image identifier")
        ids.add(entry["id"])
        digest = file_hash(entry["imagePath"])
        if digest != entry["sourceHash"]:
            raise ValueError("Source image changed after dataset staging")
        if digest in hashes:
            raise ValueError("Duplicate image content in dataset")
        hashes.add(digest)
        if file_hash(entry["labelsPath"]) != entry["labelsHash"]:
            raise ValueError("Corrected labels changed after dataset staging")
        read_labels(entry)
        if entry.get("zProjection", "max") not in ("max", "mean", "sum", "none"):
            raise ValueError("Invalid Z projection")
        channel = entry.get("segmentChannel")
        if channel is not None and (not isinstance(channel, int) or channel < 0):
            raise ValueError("Invalid source channel")
        counts[partition] += 1
    if not all(counts.values()):
        raise ValueError("Training, validation and held-out test each require images")
    return manifest


def read_labels(entry):
    height, width = entry["height"], entry["width"]
    if (not isinstance(height, int) or not isinstance(width, int) or
            min(height, width) < 1 or width * height > 64_000_000):
        raise ValueError("Invalid label dimensions")
    path = Path(entry["labelsPath"])
    if path.stat().st_size != width * height * 4:
        raise ValueError("Label byte count does not match image dimensions")
    labels = np.fromfile(path, dtype="<u4").reshape(height, width)
    values = np.unique(labels)
    nonzero = values[values > 0]
    if not len(nonzero) or not np.array_equal(nonzero, np.arange(1, len(nonzero) + 1)):
        raise ValueError("Instance labels must be consecutive positive integers")
    return labels.astype(np.int32)


def primary_plane(image, meta, channel, rgb_luminance=False):
    if rgb_luminance and meta.get("is_rgb") and image.shape[-1] >= 3:
        # Same source luminance coefficients as the shared detection reader.
        return image[..., 0] * 0.299 + image[..., 1] * 0.587 + image[..., 2] * 0.114
    if channel is not None:
        if channel >= image.shape[-1] or channel < 0:
            raise ValueError("Selected source channel is missing")
        return image[..., channel]
    return image.mean(axis=-1)


def load_dataset(manifest, loader):
    """The injected reader loads raw source planes with the reviewed projection."""
    splits = {name: [] for name in ("train", "validation", "test")}
    for entry in manifest["samples"]:
        image, meta = loader(entry["imagePath"], z_project=entry.get("zProjection", "max"),
                             channel=None)
        image = np.asarray(image)
        if image.ndim == 2:
            image = image[..., None]
        if image.ndim != 3 or image.shape[:2] != (entry["height"], entry["width"]):
            raise ValueError(f"Source plane and corrected masks differ: {entry['name']}")
        image = primary_plane(image, meta, entry.get("segmentChannel"), entry.get("useRGBLuminance", False))
        if not np.all(np.isfinite(image)):
            raise ValueError(f"Non-finite source pixels: {entry['name']}")
        splits[entry["partition"]].append((image, read_labels(entry), entry))
    return splits


def evaluate_masks(predictions, truths):
    """Micro P/R/F1 and mean per-image Cellpose AP50 (TP/(TP+FP+FN)).

    Diameter error is the absolute difference of image mean equivalent-area
    diameters, in source pixels; no physical calibration is inferred.
    Uses maximum bipartite matching, independent of arbitrary instance IDs.
    """
    if not predictions or len(predictions) != len(truths):
        raise ValueError("Every held-out image requires a successful prediction")
    total_tp = total_fp = total_fn = 0
    aps, diameters = [], []
    for predicted, truth in zip(predictions, truths):
        pred, gt = np.asarray(predicted), np.asarray(truth)
        if pred.shape != gt.shape or pred.ndim != 2:
            raise ValueError("Prediction shape differs from ground truth")
        if (not np.issubdtype(pred.dtype, np.integer) or
                not np.issubdtype(gt.dtype, np.integer) or np.any(pred < 0) or np.any(gt < 0)):
            raise ValueError("Evaluation requires nonnegative integer instance masks")
        pids, pcounts = np.unique(pred[pred > 0], return_counts=True)
        gids, gcounts = np.unique(gt[gt > 0], return_counts=True)
        if not len(gids):
            raise ValueError("A held-out image has no annotated cells")
        pc = dict(zip(pids.tolist(), pcounts.tolist()))
        gc = dict(zip(gids.tolist(), gcounts.tolist()))
        overlap = (pred > 0) & (gt > 0)
        pairs, intersections = np.unique(np.stack((pred[overlap], gt[overlap]), axis=1), axis=0, return_counts=True)
        edges = {int(pid): [] for pid in pids}
        for (pid, gid), intersection in zip(pairs, intersections):
            iou = int(intersection) / (pc[pid] + gc[gid] - int(intersection))
            if iou >= 0.5:
                edges[int(pid)].append(int(gid))
        # At IoU >= .5 label partitions have very sparse candidate edges.
        matches = {}
        def match(pid, seen):
            for gid in sorted(edges[pid]):
                if gid in seen:
                    continue
                seen.add(gid)
                if gid not in matches or match(matches[gid], seen):
                    matches[gid] = pid
                    return True
            return False
        tp = sum(match(int(pid), set()) for pid in pids)
        fp, fn = len(pids) - tp, len(gids) - tp
        total_tp += tp; total_fp += fp; total_fn += fn
        aps.append(tp / (tp + fp + fn))
        pd = float(np.mean(2 * np.sqrt(pcounts / np.pi))) if len(pcounts) else 0.0
        gd = float(np.mean(2 * np.sqrt(gcounts / np.pi)))
        diameters.append(abs(pd - gd))
    precision = total_tp / max(1, total_tp + total_fp)
    recall = total_tp / max(1, total_tp + total_fn)
    return dict(ap50=float(np.mean(aps)), f1=2 * total_tp / max(1, 2 * total_tp + total_fp + total_fn),
                precision=precision, recall=recall, meanDiamError=float(np.mean(diameters)),
                testImages=len(truths), truePositives=total_tp, falsePositives=total_fp, falseNegatives=total_fn)


def prepare_preview(image_path, output, z_project="max", channel=None, rgb_luminance=False):
    from _imageio import load_planes
    from PIL import Image
    image, meta = load_planes(image_path, z_project=z_project, channel=None)
    plane = primary_plane(image, meta, channel, rgb_luminance)
    if not np.all(np.isfinite(plane)):
        raise ValueError("Source contains non-finite pixels")
    low, high = np.percentile(plane, [1, 99])
    display = np.clip((plane - low) / max(float(high - low), 1e-8), 0, 1)
    Image.fromarray((display * 255).astype(np.uint8)).save(output)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--z-project", default="max")
    parser.add_argument("--channel", type=int)
    parser.add_argument("--rgb-luminance", action="store_true")
    args = parser.parse_args()
    try:
        prepare_preview(args.preview, args.output, args.z_project, args.channel, args.rgb_luminance)
    except Exception as exc:
        import sys
        print(str(exc), file=sys.stderr, flush=True)
        sys.exit(2)
