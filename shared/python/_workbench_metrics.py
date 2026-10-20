"""Instance-mask comparison shared by training and adaptation evaluation."""
from __future__ import annotations


def evaluate_masks(predictions, truths, *, allow_empty_reference=False):
    """Micro P/R/F1 and mean per-image AP50 = TP/(TP+FP+FN).

    Instances match at IoU >= .5 by maximum bipartite matching. Labels may be
    sparse and their numeric identifiers have no influence on the result.
    Diameter error compares per-image means in source pixels. Negative reference
    images require an explicit opt-in; a jointly empty image has AP50 = 1.
    """
    import numpy as np
    from scipy.sparse import csr_matrix
    from scipy.sparse.csgraph import maximum_bipartite_matching

    if not predictions or len(predictions) != len(truths):
        raise ValueError("Every held-out image requires a successful prediction")
    total_tp = total_fp = total_fn = 0
    aps, diameters = [], []
    for predicted, truth in zip(predictions, truths):
        pred, gt = np.asarray(predicted), np.asarray(truth)
        if pred.shape != gt.shape or pred.ndim != 2:
            raise ValueError("Prediction shape differs from ground truth")
        if (not np.issubdtype(pred.dtype, np.integer) or not np.issubdtype(gt.dtype, np.integer)
                or np.any(pred < 0) or np.any(gt < 0)):
            raise ValueError("Evaluation requires nonnegative integer instance masks")
        pids, pcounts = np.unique(pred[pred > 0], return_counts=True)
        gids, gcounts = np.unique(gt[gt > 0], return_counts=True)
        if max(len(pids), len(gids)) > 20000:
            raise ValueError("Evaluation supports at most 20,000 instances per image")
        if not len(gids) and not allow_empty_reference:
            raise ValueError("A held-out image has no annotated cells")
        overlap = (pred > 0) & (gt > 0)
        pairs, intersections = np.unique(
            np.stack((pred[overlap], gt[overlap]), axis=1), axis=0, return_counts=True,
        )
        if len(pairs):
            rows, columns = np.searchsorted(pids, pairs[:, 0]), np.searchsorted(gids, pairs[:, 1])
            iou = intersections / (pcounts[rows] + gcounts[columns] - intersections)
            keep = iou >= .5
            graph = csr_matrix((np.ones(int(keep.sum())), (rows[keep], columns[keep])),
                               shape=(len(pids), len(gids)))
            tp = int(np.count_nonzero(maximum_bipartite_matching(graph, perm_type="column") >= 0))
        else:
            tp = 0
        fp, fn = len(pids) - tp, len(gids) - tp
        total_tp += tp
        total_fp += fp
        total_fn += fn
        aps.append(tp / (tp + fp + fn) if tp + fp + fn else 1.0)
        pd = float(np.mean(2 * np.sqrt(pcounts / np.pi))) if len(pcounts) else 0.
        gd = float(np.mean(2 * np.sqrt(gcounts / np.pi))) if len(gcounts) else 0.
        diameters.append(abs(pd - gd))
    denominator = 2 * total_tp + total_fp + total_fn
    return {
        "ap50": float(np.mean(aps)), "f1": 2 * total_tp / denominator if denominator else 1.,
        "precision": total_tp / (total_tp + total_fp) if total_tp + total_fp else float(total_fn == 0),
        "recall": total_tp / (total_tp + total_fn) if total_tp + total_fn else 1.,
        "meanDiamError": float(np.mean(diameters)), "testImages": len(truths),
        "truePositives": total_tp, "falsePositives": total_fp, "falseNegatives": total_fn,
    }


def aggregate_metrics(reports):
    """Combine bounded per-image reports without retaining all prediction arrays."""
    if not reports:
        raise ValueError("At least one held-out image is required")
    total = sum(report["testImages"] for report in reports)
    tp = sum(report["truePositives"] for report in reports)
    fp = sum(report["falsePositives"] for report in reports)
    fn = sum(report["falseNegatives"] for report in reports)
    denominator = 2 * tp + fp + fn
    return {
        "ap50": sum(report["ap50"] * report["testImages"] for report in reports) / total,
        "meanDiamError": sum(report["meanDiamError"] * report["testImages"] for report in reports) / total,
        "f1": 2 * tp / denominator if denominator else 1.,
        "precision": tp / (tp + fp) if tp + fp else float(fn == 0),
        "recall": tp / (tp + fn) if tp + fn else 1.,
        "testImages": total, "truePositives": tp, "falsePositives": fp, "falseNegatives": fn,
    }
