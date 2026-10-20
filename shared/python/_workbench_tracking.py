"""Shared gated assignment kernel for centroid correspondence engines.

Forbidden assignments receive a cardinality-preserving penalty. Callers own
coordinate calibration, displacement gates, endpoint limits and provenance.
"""
from __future__ import annotations


def gated_assignment(distances, gates, *, normalize=False):
    import numpy as np
    from scipy.optimize import linear_sum_assignment
    distances = np.asarray(distances, dtype=np.float64)
    if distances.ndim != 2 or not distances.size:
        return []
    gates = np.broadcast_to(np.asarray(gates, dtype=np.float64), distances.shape)
    valid = np.isfinite(distances) & np.isfinite(gates) & (gates > 0) & (distances <= gates)
    if not valid.any():
        return []
    costs = distances / gates if normalize else distances
    maximum = float(costs[valid].max())
    penalty = (max(distances.shape) + 1) * (maximum + 1)
    rows, columns = linear_sum_assignment(np.where(valid, costs, penalty))
    return [(int(row), int(column)) for row, column in zip(rows, columns) if valid[row, column]]
