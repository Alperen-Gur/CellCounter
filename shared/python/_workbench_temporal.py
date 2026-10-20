"""Explicit temporal inference and preview-bound exact-label propagation.

Array labels remain authoritative. Drift is observed sample translation in XYZ
voxel units relative to the first selected frame; association subtracts it before
applying the selected spatial metric. Inferred divisions are never confirmations.
"""
from __future__ import annotations

import copy
import hashlib
import itertools
import math
import uuid

ENGINE_VERSION = "temporal-1"
MAX_FRAMES = 1000
MAX_OBSERVATIONS = 20000
MAX_ENDPOINTS = 2000
MAX_PAIR_VISITS = 50000
MAX_NEIGHBOURS = 12
MAX_PROPAGATIONS = 100
MAX_TARGETS = 32
MAX_PROPAGATION_VOXELS = 64000000


def operations():
    from _workbench_schema import _ID, _object, _op
    integer = {"type": "integer", "minimum": 0, "maximum": 64000000}
    label = {"type": "integer", "minimum": 1, "maximum": 4294967295}
    positive = {"type": "number", "exclusiveMinimum": 0, "maximum": 1000000}
    vector = _object({axis: {"type": "number", "minimum": -1000000, "maximum": 1000000}
                      for axis in "xyz"}, list("xyz"))
    reason = {"type": "string", "minLength": 1, "maxLength": 4096}
    fingerprint = {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    base = {"imageId": _ID, "channel": integer}
    drift = _object({"mode": {"type": "string", "enum": ["none", "explicit", "phase-correlation"]},
                     "offsets": {"type": "array", "maxItems": MAX_FRAMES,
                                 "items": _object({"timeIndex": integer, **vector["properties"]}, ["timeIndex", *"xyz"])},
                     "maxShiftVox": positive})
    division = _object({"enabled": {"type": "boolean"}, "minCombinedVolumeRatio": positive,
                        "maxCombinedVolumeRatio": positive, "maxDaughterDistance": positive,
                        "ambiguityMargin": {"type": "number", "minimum": 0, "maximum": 10}})
    tracking = {**base, "timeIndices": {"type": "array", "items": integer, "minItems": 2, "maxItems": MAX_FRAMES},
                "maxDistancePerFrame": positive, "units": {"type": "string", "enum": ["voxel", "um"]},
                "maxGapFrames": {"type": "integer", "minimum": 0, "maximum": 10},
                "drift": drift, "division": division, "replaceGraph": {"type": "boolean"}, "reason": reason}
    target = _object({"timeIndex": integer, "labelId": label, "shiftVox": vector,
                      "replaceLabelIds": {"type": "array", "items": label, "maxItems": 1000},
                      "allowClipping": {"type": "boolean"}, "skip": {"type": "boolean"}}, ["timeIndex"])
    propagation = {**base, "sourceTimeIndex": integer, "sourceLabelId": label,
                   "motion": {"type": "string", "enum": ["lineage-centroid", "drift", "explicit"]},
                   "targets": {"type": "array", "items": target, "minItems": 1, "maxItems": MAX_TARGETS},
                   "reason": reason}
    required = ["imageId", "channel", "sourceTimeIndex", "sourceLabelId", "motion", "targets", "reason"]
    return [
        _op("temporal.catalogue", "Describe bounded temporal inference, drift conventions and reversible correction propagation.", _object({}), project=False),
        _op("temporal.track.preview", "Preview drift-aware gap closing and explicitly inferred divisions without changing masks or graphs.",
            _object(tracking, ["imageId", "channel", "maxDistancePerFrame", "units"])),
        _op("temporal.track.run", "Retain a preview-bound inferred lineage graph with ambiguity and exact source provenance.",
            _object({**tracking, "previewFingerprint": fingerprint}, ["imageId", "channel", "maxDistancePerFrame", "units", "previewFingerprint"]), True),
        _op("temporal.propagate.preview", "Preview exact translated object geometry, collisions, clipping and explicit replacements across time.",
            _object({**propagation, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048},
                     "previewTimeIndex": integer}, required)),
        _op("temporal.propagate.run", "Apply the reviewed temporal correction group in one commit, retaining before/after evidence and skipped targets.",
            _object({**propagation, "previewFingerprint": fingerprint}, required + ["previewFingerprint"]), True),
        _op("temporal.propagate.list", "List retained temporal correction groups and current undo eligibility.", _object({"imageId": _ID}, ["imageId"])),
        _op("temporal.propagate.get", "Read a retained temporal correction group with target-level provenance.",
            _object({"imageId": _ID, "propagationId": _ID}, ["imageId", "propagationId"])),
        _op("temporal.propagate.undo", "Undo a whole correction group only if all target frames still exactly match that group's outputs.",
            _object({"imageId": _ID, "propagationId": _ID, "reason": reason}, ["imageId", "propagationId", "reason"]), True),
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def runtime():
    from _workbench_packages import runtime_versions
    from pathlib import Path
    modules = {}
    for name in ("_workbench_temporal.py", "_workbench_tracking.py", "_workbench_lineages.py", "_workbench_volume.py"):
        modules[name] = hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
    return {"engineVersion": ENGINE_VERSION, "moduleHashes": modules, **runtime_versions()}


def catalogue():
    return {"engineVersion": ENGINE_VERSION,
            "limits": {"frames": MAX_FRAMES, "observations": MAX_OBSERVATIONS, "activeEndpoints": MAX_ENDPOINTS,
                       "divisionPairVisits": MAX_PAIR_VISITS, "divisionNeighbours": MAX_NEIGHBOURS,
                       "propagationTargets": MAX_TARGETS, "propagationVoxels": MAX_PROPAGATION_VOXELS,
                       "propagationGroups": MAX_PROPAGATIONS},
            "notes": ["Drift offsets are observed sample translation in XYZ voxel units relative to the first selected frame. Subtract offsets before association.",
                      "Distances use the selected voxel or micrometre metric; micrometres require known XYZ spacings (XY only for a single Z plane).",
                      "Gap gates scale with elapsed frame count; no unseen intermediate observations are created.",
                      "Divisions are heuristic inferences, not confirmed biological events; ambiguous alternatives remain reported.",
                      "Mask propagation translates existing exact labels; it does not segment images or infer missing identities.",
                      "Single-Z time-series volumes are supported. Separate image-file sequence assembly is not performed."]}


def frame_binding(image, frame):
    import _workbench_volume as volume
    return {"timeIndex": frame["timeIndex"], "channel": frame["channel"], "labelsPath": frame["labelsPath"],
            "labelsHash": frame["labelsHash"], "inputFingerprint": frame["inputFingerprint"],
            "analysisRevision": frame["analysisRevision"], "measurementRevision": frame["measurementRevision"],
            "currentInputFingerprint": volume.input_fingerprint(image, frame["timeIndex"], frame["channel"])}


def track_parameters(args):
    result = {"maxDistancePerFrame": args["maxDistancePerFrame"], "units": args["units"],
              "maxGapFrames": args.get("maxGapFrames", 0),
              "drift": {"mode": "none", **copy.deepcopy(args.get("drift", {}))},
              "division": {"enabled": False, "minCombinedVolumeRatio": .5, "maxCombinedVolumeRatio": 2,
                           "maxDaughterDistance": args["maxDistancePerFrame"], "ambiguityMargin": .15,
                           **copy.deepcopy(args.get("division", {}))}}
    if result["division"]["maxCombinedVolumeRatio"] < result["division"]["minCombinedVolumeRatio"]:
        fail("invalid-division-range", "Maximum combined daughter volume ratio must be at least the minimum.")
    if result["drift"]["mode"] != "explicit" and "offsets" in result["drift"]:
        fail("invalid-drift", "Explicit offsets are only accepted with explicit drift mode.")
    return result


def collect_frames(store, image, args):
    import _workbench_volume as volume
    times = args.get("timeIndices", sorted(frame["timeIndex"] for frame in image.get("volumeFrames", []) if frame["channel"] == args["channel"]))
    if len(times) < 2 or len(times) > MAX_FRAMES or len(times) != len(set(times)):
        fail("invalid-time-selection", "Select between two and 1,000 distinct analyzed time points.")
    times = sorted(times)
    store.verify_artifact(image["sourcePath"], image["sourceHash"])
    frames = []
    for time in times:
        volume.selection(image, time, args["channel"])
        frames.append(volume.current_frame(store, image, time, args["channel"]))
    if any(len(frame["cells"]) > MAX_ENDPOINTS for frame in frames) or sum(len(frame["cells"]) for frame in frames) > MAX_OBSERVATIONS:
        fail("tracking-too-large", "Temporal inference supports 2,000 objects per frame and 20,000 observations in total.")
    return times, frames


def drift_offsets(store, image, times, channel, params):
    import numpy as np
    import _workbench_volume as volume
    import _workbench_support as support
    mode = params["mode"]
    offsets = {time: np.zeros(3, dtype=np.float64) for time in times}
    quality, notes = [], []
    if mode == "explicit":
        supplied = params.get("offsets", [])
        if {item["timeIndex"] for item in supplied} != set(times) or len(supplied) != len(times):
            fail("invalid-drift", "Supply exactly one explicit XYZ offset for every selected time point.")
        offsets = {item["timeIndex"]: np.asarray([item[axis] for axis in "xyz"], dtype=np.float64) for item in supplied}
        origin = offsets[times[0]].copy()
        offsets = {time: value - origin for time, value in offsets.items()}
        if image.get("zCount", 1) == 1 and any(value[2] != 0 for value in offsets.values()):
            fail("invalid-drift", "Single-Z time series require zero relative Z drift.")
        if np.any(origin != 0):
            notes.append("Explicit offsets were rebased to the first selected time point; pairwise displacements are unchanged.")
    elif mode == "phase-correlation":
        from skimage.registration import phase_cross_correlation
        first = volume.load_source(store, image, times[0], channel)
        valid = support.load(store, image, first.shape)
        if valid is not None and not valid.all():
            fail("drift-support-required", "Phase-correlation drift currently requires a fully acquired grid. Use explicit drift offsets for sources with invalid support.")
        step = np.maximum(1, np.ceil(np.asarray(first.shape) / 128).astype(int))
        sampled = tuple(slice(None, None, int(value)) for value in step)
        reference = np.squeeze(first[sampled]).copy()
        if reference.ndim < 2 or float(reference.std()) == 0:
            fail("drift-uninformative", "Drift estimation needs nonconstant source structure in at least two axes.")
        non_single = [index for index, size in enumerate(first[sampled].shape) if size > 1]
        for time in times[1:]:
            moving = np.squeeze(volume.load_source(store, image, time, channel)[sampled])
            if float(moving.std()) == 0:
                fail("drift-uninformative", "A selected frame has constant intensity and cannot support drift estimation.", {"timeIndex": time})
            shift, error, phase = phase_cross_correlation(reference, moving, upsample_factor=10, normalization=None)
            full = np.zeros(3)
            for axis, value in zip(non_single, shift):
                full[axis] = -float(value) * step[axis]
            offset = full[::-1]
            if not np.isfinite(offset).all() or not math.isfinite(float(error)):
                fail("drift-uninformative", "Phase correlation produced no finite drift estimate.", {"timeIndex": time})
            maximum = params.get("maxShiftVox", max(volume.dimensions(image)) / 4)
            if float(np.linalg.norm(offset)) > maximum:
                fail("drift-out-of-range", "Estimated drift exceeds the explicit displacement bound; inspect or supply explicit offsets.", {"timeIndex": time, "offsetVox": offset.tolist(), "maximum": maximum})
            offsets[time] = offset
            quality.append({"timeIndex": time, "phaseError": float(error), "phaseDifferenceRad": float(phase)})
        notes.append("Phase correlation uses origin-aligned source subsampling at strides " + str(list(map(int, step[::-1]))) + "; subpixel estimates are not independent validation of motion.")
    return {"mode": mode, "offsets": [{"timeIndex": time, **dict(zip("xyz", map(float, offsets[time])))} for time in times],
            "convention": "sample-position(t)=reference-position+offsetVox(t); association subtracts offset before applying calibration",
            "quality": quality, "notes": notes}, offsets


def division_candidates(active, target, source_points, target_points, params, visits_remaining):
    import numpy as np
    from scipy.spatial import cKDTree
    settings = params["division"]
    if not settings["enabled"] or not active or len(target["cells"]) < 2:
        return [], [], 0
    tree = cKDTree(target_points)
    proposals, visits, truncated = [], 0, False
    for row, (time, parent) in enumerate(active):
        # Division inference requires an adjacent observed frame. Gap closing is
        # independently available for one-to-one continuations.
        if target["timeIndex"] != time + 1:
            continue
        candidates = tree.query_ball_point(source_points[row], settings["maxDaughterDistance"])
        distances = sorted((float(np.linalg.norm(target_points[col] - source_points[row])), col) for col in candidates)
        if len(distances) > MAX_NEIGHBOURS:
            truncated = True
        for (first_distance, first), (second_distance, second) in itertools.combinations(distances[:MAX_NEIGHBOURS], 2):
            if visits >= visits_remaining:
                truncated = True
                break
            visits += 1
            daughters = [target["cells"][first], target["cells"][second]]
            ratio = sum(child["voxelCount"] for child in daughters) / parent["voxelCount"]
            if not settings["minCombinedVolumeRatio"] <= ratio <= settings["maxCombinedVolumeRatio"]:
                continue
            score = (first_distance + second_distance) / (2 * settings["maxDaughterDistance"]) + abs(math.log(ratio))
            continuation_score = min(distance / settings["maxDaughterDistance"] + abs(math.log(child["voxelCount"] / parent["voxelCount"]))
                                     for distance, child in zip((first_distance, second_distance), daughters))
            proposals.append({"row": row, "columns": [first, second], "score": score,
                              "continuationScore": continuation_score,
                              "parent": {"timeIndex": time, "labelId": parent["labelId"]},
                              "daughters": [{"timeIndex": target["timeIndex"], "labelId": child["labelId"]} for child in daughters],
                              "combinedVolumeRatio": ratio, "parentDistances": [first_distance, second_distance]})
        if visits >= visits_remaining:
            break
    proposals.sort(key=lambda value: (value["score"], value["row"], value["columns"]))
    competing_rows, competing_columns = {}, {}
    for identifier, candidate in enumerate(proposals):
        candidate["candidateIndex"] = identifier
        competing_rows.setdefault(candidate["row"], []).append(identifier)
        for column in candidate["columns"]:
            competing_columns.setdefault(column, []).append(identifier)
    accepted, ambiguities, used_rows, used_columns = [], [], set(), set()
    for candidate in proposals:
        # Lists inherit score order. Their first two entries suffice to find
        # the best distinct competitor, avoiding a quadratic pair scan.
        identifiers = competing_rows[candidate["row"]][:2]
        for column in candidate["columns"]:
            identifiers += competing_columns[column][:2]
        alternatives = [proposals[index]["score"] for index in identifiers if index != candidate["candidateIndex"]]
        alternate = min([candidate["continuationScore"], *alternatives])
        margin = alternate - candidate["score"]
        candidate["alternativeScore"] = alternate
        candidate["scoreMargin"] = margin
        if margin <= settings["ambiguityMargin"]:
            if len(ambiguities) < 1000:
                ambiguities.append({key: value for key, value in candidate.items() if key not in ("row", "columns", "candidateIndex")})
            continue
        if candidate["row"] in used_rows or set(candidate["columns"]) & used_columns:
            continue
        accepted.append(candidate)
        used_rows.add(candidate["row"]); used_columns.update(candidate["columns"])
    if truncated:
        # A truncated neighbourhood cannot establish that a winning hypothesis
        # is unambiguous. Keep it as a reported proposal, not an inferred event.
        ambiguities.extend({**{key: value for key, value in item.items() if key not in ("row", "columns", "candidateIndex")},
                            "reason": "bounded-search-truncated"} for item in accepted[:max(0, 1000 - len(ambiguities))])
        accepted = []
    return accepted, ambiguities, visits


def track_preview(store, image, args):
    import numpy as np
    from scipy.spatial.distance import cdist
    import _workbench_volume as volume
    import _workbench_lineages as lineage
    import _workbench_support as support
    from _workbench_tracking import gated_assignment
    times, frames = collect_frames(store, image, args)
    params = track_parameters(args)
    spacing = volume.calibration(image)
    if params["units"] == "um":
        axes = "xy" if image.get("zCount", 1) == 1 else "xyz"
        if any(spacing[axis] is None for axis in axes):
            fail("calibration-required", "Physical tracking requires all observed spatial dimensions to be calibrated.")
        factors = np.asarray([spacing[axis] if spacing[axis] is not None else 1 for axis in "xyz"])
    else:
        factors = np.ones(3)
    drift, offsets = drift_offsets(store, image, times, args["channel"], params["drift"])
    nodes, edges, divisions, active, ambiguities = [], [], [], [], []
    visits, gap_count = 0, 0
    for frame in frames:
        time = frame["timeIndex"]
        for cell in frame["cells"]:
            nodes.append({"id": lineage.node_id(time, cell["labelId"]), "timeIndex": time,
                          **{key: cell[key] for key in ("labelId", "cx", "cy", "cz", "voxelCount", "volumeUm3", "meanIntensity")}})
        active = [(prior, cell) for prior, cell in active if time - prior - 1 <= params["maxGapFrames"]]
        if len(active) > MAX_ENDPOINTS:
            fail("tracking-too-large", "Gap closing exceeds 2,000 active endpoints; use fewer objects or a smaller gap allowance.")
        if not active or not frame["cells"]:
            active.extend((time, cell) for cell in frame["cells"])
            continue
        source_points = np.asarray([(np.asarray([cell[key] for key in ("cx", "cy", "cz")]) - offsets[prior]) * factors for prior, cell in active])
        target_points = np.asarray([(np.asarray([cell[key] for key in ("cx", "cy", "cz")]) - offsets[time]) * factors for cell in frame["cells"]])
        candidates, uncertain, used_visits = division_candidates(active, frame, source_points, target_points, params, MAX_PAIR_VISITS - visits)
        visits += used_visits; ambiguities.extend(uncertain[:max(0, 1000 - len(ambiguities))])
        consumed_rows, consumed_columns = set(), set()
        for candidate in candidates:
            row, columns = candidate["row"], candidate["columns"]
            prior, cell = active[row]
            event_id = "inferred-" + digest({"parent": candidate["parent"], "daughters": candidate["daughters"]})[:24]
            event = {key: value for key, value in candidate.items() if key not in ("row", "columns", "candidateIndex")}
            event.update({"id": event_id, "origin": "inferred", "confirmation": "unconfirmed",
                          "algorithm": ENGINE_VERSION, "units": params["units"],
                          "reason": "Unambiguous bounded daughter-pair hypothesis under the recorded geometric criteria."})
            divisions.append(event)
            parent_node = {"id": lineage.node_id(prior, cell["labelId"]), "timeIndex": prior, "labelId": cell["labelId"]}
            for column in columns:
                child = frame["cells"][column]
                child_node = {"id": lineage.node_id(time, child["labelId"]), "timeIndex": time, "labelId": child["labelId"]}
                edges.append({**lineage.edge_between(parent_node, child_node, "division", event_id), "origin": "inferred"})
            consumed_rows.add(row); consumed_columns.update(columns)
        rows = [index for index in range(len(active)) if index not in consumed_rows]
        columns = [index for index in range(len(frame["cells"])) if index not in consumed_columns]
        if rows and columns:
            distances = cdist(source_points[rows], target_points[columns])
            gates = np.asarray([(time - active[row][0]) * params["maxDistancePerFrame"] for row in rows])[:, None]
            for local_row, local_column in gated_assignment(distances, gates, normalize=True):
                row, column = rows[local_row], columns[local_column]
                prior, cell = active[row]; child = frame["cells"][column]
                gap = time - prior - 1
                edge = lineage.edge_between({"id": lineage.node_id(prior, cell["labelId"]), "timeIndex": prior, "labelId": cell["labelId"]},
                                            {"id": lineage.node_id(time, child["labelId"]), "timeIndex": time, "labelId": child["labelId"]})
                edge.update({"origin": "inferred", "distance": float(distances[local_row, local_column]),
                             "distancePerFrame": float(distances[local_row, local_column]) / (time - prior),
                             "units": params["units"], "gapFrames": gap, "driftCorrected": params["drift"]["mode"] != "none"})
                edges.append(edge); consumed_rows.add(row); gap_count += int(gap > 0)
        active = [value for index, value in enumerate(active) if index not in consumed_rows]
        active.extend((time, cell) for cell in frame["cells"])
    refs = [frame_binding(image, frame) for frame in frames]
    current_record = lineage.record_for(image, args["channel"])
    existing_snapshot = current_record.get("currentSnapshotId") if current_record else None
    parameters = {**params, "timeIndices": times}
    provenance = {"engineVersion": ENGINE_VERSION, "parameters": parameters, "drift": drift,
                  "ambiguities": ambiguities, "divisionPairVisits": visits, "runtime": runtime(),
                  "reexecution": {"previewOperation": "temporal.track.preview", "operation": "temporal.track.run",
                                  "arguments": {key: copy.deepcopy(value) for key, value in args.items() if key != "previewFingerprint"},
                                  "policy": "explicit-preview-and-graph-replacement", "preservesMasks": True},
                  "notes": catalogue()["notes"]}
    graph = {"schemaVersion": 1, "imageId": image["id"], "channel": args["channel"],
             "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"], "frameReferences": refs,
             "bindingKind": "temporal", "baseTrackingFingerprint": None,
             "inputFingerprint": volume.tracks_fingerprint(image, {"channel": args["channel"], "timeIndices": times, "timeSelection": "explicit"}),
             "timeIndices": times, "voxelSizeUm": spacing, "timeStepSeconds": image.get("timeStepSeconds"),
             "nodes": nodes, "edges": edges, "divisions": divisions, "temporalInference": provenance}
    if support.descriptor(image):
        graph["validSupport"] = copy.deepcopy(support.descriptor(image))
    tracks, lineages, summary = lineage.graph_measurements(graph)
    public_graph = {"imageId": image["id"], "channel": args["channel"], "status": "preview", "graphRevision": None,
                    "snapshotId": None, "undoAvailable": False, "nodes": nodes, "edges": edges, "divisions": divisions,
                    "tracks": tracks, "lineages": lineages, "summary": summary, "temporalInference": provenance, "history": []}
    fingerprint = digest({"graph": graph, "existingSnapshotId": existing_snapshot, "replaceGraph": args.get("replaceGraph", False),
                          "reason": args.get("reason", ""), "engineVersion": ENGINE_VERSION})
    result = {"previewFingerprint": fingerprint, "imageId": image["id"], "channel": args["channel"], "timeIndices": times,
              "parameters": parameters, "drift": drift, "counts": {"observations": len(nodes),
              "continuations": sum(edge["kind"] == "continuation" for edge in edges), "gaps": gap_count,
              "inferredDivisions": len(divisions), "ambiguousDivisions": len(ambiguities)}, "ambiguities": ambiguities,
              "graph": public_graph, "replacesGraph": existing_snapshot is not None, "notes": catalogue()["notes"]}
    return result, graph


def track_run(store, image, args, revision, actor):
    import _workbench_lineages as lineage
    from _workbench_store import utc_now
    preview, graph = track_preview(store, image, args)
    if args["previewFingerprint"] != preview["previewFingerprint"]:
        fail("preview-expired", "Tracking inputs, parameters, runtime or saved graph changed. Preview inference again before applying.")
    record = lineage.record_for(image, args["channel"])
    if record is not None and not args.get("replaceGraph", False):
        fail("graph-replacement-required", "A saved graph already exists. Explicitly allow a new inferred snapshot to replace its active view; prior graph history is retained.")
    if record is None:
        record = {"channel": args["channel"], "currentSnapshotId": None, "undoStack": [], "snapshots": []}
        image.setdefault("volumeLineages", []).append(record)
    now = utc_now()
    graph["temporalInference"].update({"requestedBy": copy.deepcopy(actor), "at": now, "previewFingerprint": preview["previewFingerprint"]})
    for division in graph["divisions"]:
        division["actor"] = copy.deepcopy(actor); division["at"] = now
    graph["temporalInference"].update({"inferredAtRevision": revision,
        "baseTopologyHash": digest({key: graph[key] for key in ("nodes", "edges", "divisions")})})
    saved = lineage.save(store, image, record, graph, revision, "temporal.track.run", actor,
                         args.get("reason", "Explicitly requested automatic temporal inference; inferred divisions remain unconfirmed."))
    return {"graph": saved, "tracking": {key: value for key, value in preview.items() if key != "graph"}}


def _label_cell(frame, label):
    return next((cell for cell in frame["cells"] if cell["labelId"] == label), None)


def _continuation_identity(graph, source_time, source_label, target_time):
    import _workbench_lineages as lineage
    if graph is None:
        fail("target-identity-required", "Supply the exact target label, or create a current lineage with consecutive unique observations.")
    by_id, outgoing, incoming = lineage.validate_graph(graph)
    current = by_id.get(lineage.node_id(source_time, source_label))
    if current is None:
        fail("target-identity-required", "The source label is absent from the current lineage; supply the exact target label.")
    forward = target_time > source_time
    while current["timeIndex"] != target_time:
        if forward:
            edges = outgoing.get(current["id"], [])
            if len(edges) != 1 or edges[0]["kind"] != "continuation":
                fail("target-identity-required", "Propagation cannot infer a target across a division or missing correspondence. Supply its exact label identity.")
            edge = edges[0]
            next_node = by_id[edge["targetNodeId"]]
        else:
            edge = incoming.get(current["id"])
            if edge is None or edge["kind"] != "continuation":
                fail("target-identity-required", "Propagation cannot infer a target across a division or missing correspondence. Supply its exact label identity.")
            next_node = by_id[edge["sourceNodeId"]]
        if abs(next_node["timeIndex"] - current["timeIndex"]) != 1:
            fail("target-identity-required", "A lineage gap contains no observed identity. Supply the exact target label explicitly.")
        if (forward and next_node["timeIndex"] > target_time) or (not forward and next_node["timeIndex"] < target_time):
            fail("target-identity-required", "The requested time has no retained lineage observation. Supply its exact target label.")
        current = next_node
    return current["labelId"]


def _translated_mask(source_mask, shift):
    import numpy as np
    # Integer-label nearest-neighbour translation. Ties round away from zero;
    # no label interpolation and no wraparound are permitted.
    rounded = np.copysign(np.floor(np.abs(shift) + .5), shift).astype(np.int64)
    zyx = rounded[::-1]
    result = np.zeros(source_mask.shape, dtype=bool)
    source_slices, destination_slices = [], []
    for length, delta in zip(source_mask.shape, zyx):
        delta = int(delta)
        if abs(delta) >= length:
            return result, list(map(int, rounded))
        source_slices.append(slice(max(0, -delta), min(length, length - delta)))
        destination_slices.append(slice(max(0, delta), min(length, length + delta)))
    result[tuple(destination_slices)] = source_mask[tuple(source_slices)]
    return result, list(map(int, rounded))


def _propagation_graph(store, image, channel, required=False):
    import _workbench_lineages as lineage
    record = lineage.record_for(image, channel)
    if record is None:
        if required:
            fail("lineage-required", "This propagation mode needs a current saved temporal lineage.")
        return None, None
    snapshot = lineage.snapshot_for(record)
    if not lineage.snapshot_current(image, snapshot):
        if required:
            fail("stale-lineage", "The saved lineage no longer matches current masks or calibration. Supply explicit target identities and explicit shifts, or infer a current graph first.")
        return None, None
    return lineage.load_graph(store, snapshot), snapshot["id"]


def _prepare_propagation(store, image, args):
    import numpy as np
    import _workbench_volume as volume
    channel, source_time = args["channel"], args["sourceTimeIndex"]
    volume.selection(image, source_time, channel)
    targets = args["targets"]
    times = [target["timeIndex"] for target in targets]
    if len(times) != len(set(times)) or source_time in times:
        fail("invalid-time-selection", "Choose distinct target times different from the source time.")
    if math.prod(volume.dimensions(image)) * len(targets) > MAX_PROPAGATION_VOXELS:
        fail("propagation-too-large", "The selected targets exceed the 64-million-voxel propagation working budget; use smaller groups.")
    source = volume.current_frame(store, image, source_time, channel)
    cell = _label_cell(source, args["sourceLabelId"])
    if cell is None:
        fail("invalid-labels", "The selected source object is absent from the saved source frame.")
    mask = np.asarray(volume.read_labels(store, image, source) == args["sourceLabelId"])
    graph, graph_id = _propagation_graph(store, image, channel, required=args["motion"] == "drift")
    drift = {item["timeIndex"]: np.asarray([item[axis] for axis in "xyz"], dtype=np.float64)
             for item in (graph or {}).get("temporalInference", {}).get("drift", {}).get("offsets", [])}
    if args["motion"] == "drift" and source_time not in drift:
        fail("drift-required", "The current temporal graph contains no recorded source drift offset.")
    return {"source": source, "cell": cell, "mask": mask, "sourceCount": int(mask.sum()),
            "graph": graph, "graphId": graph_id, "drift": drift}


def _target_propagation(store, image, args, prepared, requested, *, render=False, max_size=768):
    import numpy as np
    import _workbench_volume as volume
    import _workbench_imaging as imaging
    import _workbench_support as support
    from _workbench_schema import WorkbenchError
    time, channel = requested["timeIndex"], args["channel"]
    result = {"timeIndex": time, "labelId": requested.get("labelId"), "identity": "explicit" if "labelId" in requested else "lineage",
              "status": "skipped" if requested.get("skip", False) else "ready", "shiftVox": None, "appliedShiftVox": None,
              "sourceVoxels": prepared["sourceCount"], "placedVoxels": 0, "clippedVoxels": 0,
              "collisionLabelIds": [], "replacedLabelIds": [], "reasons": [], "warnings": []}
    if requested.get("skip", False):
        result["warnings"].append("This target is explicitly excluded from this correction group.")
        return result, None, None, None
    try:
        volume.selection(image, time, channel)
        frame = volume.current_frame(store, image, time, channel)
        labels = np.asarray(volume.read_labels(store, image, frame))
        label = requested.get("labelId")
        if label is None:
            label = _continuation_identity(prepared["graph"], args["sourceTimeIndex"], args["sourceLabelId"], time)
        result["labelId"] = label
        target_cell = _label_cell(frame, label)
        if args["motion"] == "explicit":
            if "labelId" not in requested or "shiftVox" not in requested:
                fail("target-identity-required", "Explicit motion needs an exact target label and XYZ voxel shift for each target.")
            shift = np.asarray([requested["shiftVox"][axis] for axis in "xyz"], dtype=np.float64)
        elif args["motion"] == "lineage-centroid":
            if "shiftVox" in requested:
                fail("invalid-motion", "Only explicit motion accepts target shiftVox.")
            if target_cell is None:
                fail("target-identity-required", "Centroid motion requires an existing exact target label; use explicit motion to create a new label.")
            shift = np.asarray([target_cell[key] - prepared["cell"][key] for key in ("cx", "cy", "cz")])
        else:
            if "shiftVox" in requested:
                fail("invalid-motion", "Only explicit motion accepts target shiftVox.")
            if time not in prepared["drift"]:
                fail("drift-required", "This target time has no saved drift offset; use explicit motion or include it in a new tracking preview.")
            shift = prepared["drift"][time] - prepared["drift"][args["sourceTimeIndex"]]
        if image.get("zCount", 1) == 1 and shift[2] != 0:
            fail("invalid-motion", "Single-Z time series cannot propagate a nonzero Z shift.")
        result["shiftVox"] = dict(zip("xyz", map(float, shift)))
        moved, rounded = _translated_mask(prepared["mask"], shift)
        result["appliedShiftVox"] = dict(zip("xyz", rounded))
        valid = support.load(store, image, moved.shape)
        if valid is not None:
            moved &= valid
        result["placedVoxels"] = int(moved.sum())
        result["clippedVoxels"] = prepared["sourceCount"] - result["placedVoxels"]
        if result["placedVoxels"] == 0:
            fail("empty-propagation", "Translated geometry contains no acquired target voxels.")
        replacements = sorted(set(requested.get("replaceLabelIds", [])))
        existing = {cell["labelId"] for cell in frame["cells"]}
        if any(item not in existing for item in replacements):
            fail("invalid-replacement", "A replacement label is absent from this exact target frame.")
        overlaps = sorted(int(item) for item in np.unique(labels[moved]) if item != 0)
        collisions = [item for item in overlaps if item not in replacements]
        if label in existing and label not in replacements and label not in collisions:
            collisions.append(label)
        result["collisionLabelIds"] = sorted(collisions)
        result["replacedLabelIds"] = replacements
        if collisions:
            result["reasons"].append({"code": "label-collision", "message": "Explicit replacement is required for every overlapping or already-existing target label."})
        if result["clippedVoxels"] and not requested.get("allowClipping", False):
            result["reasons"].append({"code": "clipping-approval-required", "message": "Geometry leaves the acquired grid/support. Explicitly allow this clipping or choose another target shift."})
        if replacements:
            result["warnings"].append("Replacement removes each named target object in full before placing the source geometry; saved prior masks remain undoable.")
        if result["shiftVox"] != result["appliedShiftVox"]:
            result["warnings"].append("Translation rounds to integer voxels (nearest, half away from zero); no label interpolation is used.")
        output = labels.copy()
        if replacements:
            output[np.isin(output, replacements)] = 0
        # Collision pixels remain intact even in a blocked visual preview.
        paint = moved & ((output == 0) | (output == label))
        output[paint] = label
        if len(np.unique(output)) - int(np.any(output == 0)) > imaging.MAX_CELLS:
            fail("too-many-objects", "The correction would exceed the saved-frame object bound.")
        if result["reasons"]:
            result["status"] = "blocked"
        if render:
            raw = volume.load_source(store, image, time, channel)
            occupied = np.flatnonzero(moved.any(axis=(1, 2)))
            index = int(occupied[len(occupied) // 2]) if occupied.size else raw.shape[0] // 2
            preview = imaging.preview_data(raw[index], output[index], max_size=max_size)
            result.update({"overlayDataUrl": preview["dataUrl"], "previewIndex": index,
                           "width": image["width"], "height": image["height"],
                           "previewWidth": preview["previewWidth"], "previewHeight": preview["previewHeight"]})
        return result, frame, output, frame_binding(image, frame)
    except WorkbenchError as exc:
        result["status"] = "blocked"
        result["reasons"].append({"code": exc.code, "message": exc.message})
        return result, None, None, None


def propagation_preview(store, image, args, *, render=True):
    import _workbench_volume as volume
    import _workbench_support as support
    prepared = _prepare_propagation(store, image, args)
    public, bindings = [], []
    visual_time = args.get("previewTimeIndex", next((target["timeIndex"] for target in args["targets"] if not target.get("skip", False)), None))
    for target in args["targets"]:
        result, _, _, binding = _target_propagation(store, image, args, prepared, target,
                                                   render=render and target["timeIndex"] == visual_time,
                                                   max_size=args.get("maxSize", 768))
        public.append(result)
        if binding is not None:
            bindings.append(binding)
    scientific_args = {key: copy.deepcopy(value) for key, value in args.items() if key not in ("maxSize", "previewTimeIndex", "previewFingerprint")}
    signature = {"engineVersion": ENGINE_VERSION, "runtime": runtime(), "arguments": scientific_args,
                 "sourceHash": image["sourceHash"], "sourceBinding": frame_binding(image, prepared["source"]),
                 "targetBindings": bindings, "graphSnapshotId": prepared["graphId"],
                 "voxelSizeUm": volume.calibration(image), "validSupport": support.fingerprint(image)}
    return {"previewFingerprint": digest(signature), "imageId": image["id"], "channel": args["channel"],
            "source": {"timeIndex": args["sourceTimeIndex"], "labelId": args["sourceLabelId"]},
            "motion": args["motion"], "targets": public,
            "readyCount": sum(target["status"] == "ready" for target in public),
            "blockedCount": sum(target["status"] == "blocked" for target in public),
            "notes": ["Only one selected target overlay is returned per preview; all target collision/support counts use exact full-resolution labels.",
                      "No divisions, merges or missing observations are crossed through inferred identities; provide each target label explicitly when necessary.",
                      "A correction group never mutates the source frame. Every non-skipped target must be ready before applying.",
                      "Propagation makes the previous temporal graph historical until its changed observations are explicitly recomputed."]}, prepared, signature


def _frame_evidence(frame):
    return {key: copy.deepcopy(frame[key]) for key in
            ("timeIndex", "channel", "labelsPath", "labelsHash", "parameters", "engineVersion", "imageStats", "analysisRevision", "measurementRevision")}


def _propagation_current(image, record):
    import _workbench_volume as volume
    import _workbench_support as support
    if (record["sourceHash"] != image["sourceHash"] or record["voxelSizeUm"] != volume.calibration(image)
            or record.get("supportFingerprint") != support.fingerprint(image)):
        return False
    for binding in record["afterBindings"]:
        frame = volume.get_frame(image, binding["timeIndex"], binding["channel"], required=False)
        if frame is None or frame_binding(image, frame) != binding:
            return False
    return True


def describe_propagation(image, record, full=False):
    current = _propagation_current(image, record)
    result = {key: copy.deepcopy(record[key]) for key in
              ("id", "status", "source", "channel", "motion", "createdAt", "createdRevision", "reason", "notes")}
    result.update({"imageId": image["id"], "outputsCurrent": current,
                   "undoAvailable": record["status"] == "applied" and current,
                   "targetCount": len(record["targets"]),
                   "appliedCount": sum(item["status"] == "ready" for item in record["targets"]),
                   "skippedCount": sum(item["status"] == "skipped" for item in record["targets"])})
    if full:
        result.update({key: copy.deepcopy(record[key]) for key in ("targets", "reexecution", "reportPath", "reportHash")})
        for key in ("undoRevision", "undoReason", "undoAt"):
            if key in record:
                result[key] = record[key]
    return result


def describe_propagations(image):
    return [describe_propagation(image, record) for record in image.get("temporalPropagations", [])]


def propagation_run(store, image, args, revision, actor):
    import _workbench_volume as volume
    import _workbench_support as support
    from _workbench_store import canonical, utc_now
    if len(image.get("temporalPropagations", [])) >= MAX_PROPAGATIONS:
        fail("propagation-history-full", "This acquisition retains 100 correction groups. Create a new image variant before adding another group.")
    preview, prepared, signature = propagation_preview(store, image, args, render=False)
    if args["previewFingerprint"] != preview["previewFingerprint"]:
        fail("preview-expired", "Source, target labels, graph, calibration, runtime or correction choices changed. Preview this propagation again.")
    if preview["blockedCount"] or not preview["readyCount"]:
        fail("propagation-blocked", "Resolve every blocked target or explicitly skip it, and retain at least one ready target.", {"targets": preview["targets"]})
    before, after = [], []
    group_id = str(uuid.uuid4())
    # The caller owns one document snapshot and commits it once. All target
    # mutations remain uncommitted until the complete group is calculated.
    for requested in args["targets"]:
        target, frame, labels, _ = _target_propagation(store, image, args, prepared, requested)
        if target["status"] == "skipped":
            continue
        if target["status"] != "ready":
            fail("propagation-changed", "A target no longer matches the reviewed correction plan.", {"target": target})
        before.append(_frame_evidence(frame))
        raw = volume.load_source(store, image, requested["timeIndex"], args["channel"])
        saved = volume.save_frame(store, image, raw, labels, frame["parameters"], requested["timeIndex"], args["channel"], revision,
                                  {"method": "temporal-propagation", "propagationId": group_id,
                                   "sourceTimeIndex": args["sourceTimeIndex"], "sourceLabelId": args["sourceLabelId"],
                                   "appliedShiftVox": target["appliedShiftVox"]})
        after.append(frame_binding(image, saved))
    reexecution = {"previewOperation": "temporal.propagate.preview", "policy": "explicit-preview-only",
                   "arguments": copy.deepcopy(signature["arguments"]), "changesMasks": True}
    record = {"id": group_id, "status": "applied", "source": preview["source"], "sourceHash": image["sourceHash"],
              "sourcePath": image["sourcePath"], "sourceBinding": signature["sourceBinding"],
              "channel": args["channel"], "motion": args["motion"], "targets": preview["targets"],
              "beforeFrames": before, "afterBindings": after, "createdAt": utc_now(), "createdRevision": revision,
              "actor": copy.deepcopy(actor), "reason": args["reason"], "voxelSizeUm": volume.calibration(image),
              "supportFingerprint": support.fingerprint(image), "validSupport": copy.deepcopy(support.descriptor(image)),
              "previewFingerprint": preview["previewFingerprint"], "runtime": signature["runtime"],
              "reexecution": reexecution, "notes": preview["notes"]}
    encoded = (canonical(record) + "\n").encode("utf-8")
    if len(encoded) > 16 * 1024 * 1024:
        fail("propagation-too-large", "Correction provenance exceeds its 16 MiB bound; use a smaller target group.")
    record["reportPath"], record["reportHash"] = store.put_bytes(encoded, ".temporal-propagation.json")
    image.setdefault("temporalPropagations", []).append(record)
    return {"propagation": describe_propagation(image, record, full=True)}


def propagation_record(image, identifier):
    record = next((item for item in image.get("temporalPropagations", []) if item["id"] == identifier), None)
    if record is None:
        fail("propagation-not-found", "The selected correction group is not retained for this acquisition.")
    return record


def propagation_undo(store, image, args, revision, actor):
    import _workbench_volume as volume
    from _workbench_store import utc_now, canonical
    record = propagation_record(image, args["propagationId"])
    if record["status"] != "applied":
        fail("nothing-to-undo", "This correction group has already been undone.")
    if not _propagation_current(image, record):
        fail("propagation-undo-conflict", "A target mask, calibration or support changed after this correction group. Group undo would overwrite later edits and is refused; inspect per-frame history instead.")
    store.verify_artifact(record["reportPath"], record["reportHash"])
    for before in record["beforeFrames"]:
        labels = volume.read_labels(store, image, before)
        raw = volume.load_source(store, image, before["timeIndex"], before["channel"])
        volume.save_frame(store, image, raw, labels, before["parameters"], before["timeIndex"], before["channel"], revision,
                          {**copy.deepcopy(before["imageStats"]), "temporalGroupUndo": record["id"]})
    record.update({"status": "undone", "undoRevision": revision, "undoReason": args["reason"],
                   "undoAt": utc_now(), "undoActor": copy.deepcopy(actor)})
    evidence = {"propagationId": record["id"], "beforeReport": {"path": record["reportPath"], "hash": record["reportHash"]},
                "revision": revision, "reason": args["reason"], "actor": copy.deepcopy(actor),
                "restoredBindings": [frame_binding(image, volume.get_frame(image, item["timeIndex"], item["channel"])) for item in record["beforeFrames"]]}
    record["undoReportPath"], record["undoReportHash"] = store.put_bytes((canonical(evidence) + "\n").encode("utf-8"), ".temporal-undo.json")
    return {"propagation": describe_propagation(image, record, full=True)}


def artifact_references(document):
    references = {}
    for image in document["images"]:
        for record in image.get("temporalPropagations", []):
            for path, hashed in (("reportPath", "reportHash"), ("undoReportPath", "undoReportHash"), ("sourcePath", "sourceHash")):
                if record.get(path):
                    references[record[path]] = record[hashed]
            support = record.get("validSupport")
            if support:
                references[support["path"]] = support["hash"]
            for frame in [record["sourceBinding"], *record["beforeFrames"], *record["afterBindings"]]:
                references[frame["labelsPath"]] = frame["labelsHash"]
    return references


def validate_document(document):
    """Bound retained temporal records before package restoration/allocation."""
    import re
    for image in document.get("images", []):
        records = image.get("temporalPropagations", [])
        if not isinstance(records, list) or len(records) > MAX_PROPAGATIONS:
            fail("invalid-temporal-records", "Retained temporal correction groups exceed their supported bound.")
        identifiers = set()
        for record in records:
            if (not isinstance(record, dict) or not isinstance(record.get("id"), str)
                    or record["id"] in identifiers or record.get("status") not in ("applied", "undone")):
                fail("invalid-temporal-records", "Retained temporal correction group identity or status is invalid.")
            identifiers.add(record["id"])
            for key in ("targets", "beforeFrames", "afterBindings"):
                if not isinstance(record.get(key), list) or not 1 <= len(record[key]) <= MAX_TARGETS:
                    fail("invalid-temporal-records", "Retained correction targets exceed their supported bound.")
            if len(record["beforeFrames"]) != len(record["afterBindings"]):
                fail("invalid-temporal-records", "Retained correction input/output bindings disagree.")
            for path, hash_key in (("reportPath", "reportHash"), ("sourcePath", "sourceHash")):
                if not isinstance(record.get(path), str) or not re.fullmatch(r"[0-9a-f]{64}", str(record.get(hash_key, ""))):
                    fail("invalid-temporal-records", "Retained correction artifact references are malformed.")
            for frame in [record.get("sourceBinding", {}), *record["beforeFrames"], *record["afterBindings"]]:
                if (not isinstance(frame, dict) or type(frame.get("timeIndex")) is not int or frame["timeIndex"] < 0
                        or type(frame.get("channel")) is not int or frame["channel"] < 0
                        or not isinstance(frame.get("labelsPath"), str)
                        or not re.fullmatch(r"[0-9a-f]{64}", str(frame.get("labelsHash", "")))):
                    fail("invalid-temporal-records", "Retained correction frame identity or exact label references are malformed.")


def execute(store, document, operation, args, revision, actor):
    if operation == "temporal.catalogue":
        return catalogue()
    image = next((item for item in document["images"] if item["id"] == args["imageId"]), None)
    if image is None:
        fail("image-not-found", "The selected image is not part of this project.")
    if operation == "temporal.track.preview":
        return track_preview(store, image, args)[0]
    if operation == "temporal.track.run":
        return track_run(store, image, args, revision, actor)
    if operation == "temporal.propagate.preview":
        return propagation_preview(store, image, args)[0]
    if operation == "temporal.propagate.run":
        return propagation_run(store, image, args, revision, actor)
    if operation == "temporal.propagate.list":
        return {"propagations": describe_propagations(image)}
    if operation == "temporal.propagate.get":
        return {"propagation": describe_propagation(image, propagation_record(image, args["propagationId"]), full=True)}
    if operation == "temporal.propagate.undo":
        return propagation_undo(store, image, args, revision, actor)
    fail("unknown-operation", "Unknown temporal operation.")
