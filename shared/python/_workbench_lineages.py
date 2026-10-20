"""Explicit, reversible lineage graphs over immutable volumetric observations.

The one-to-one tracker remains independent. Reviewed decisions and explicitly
requested temporal inference retain distinct event provenance.
"""
from __future__ import annotations

import copy
import hashlib
import itertools
import json
import math
import uuid

MAX_NODES = 20000
MAX_SNAPSHOTS = 500
MAX_GRAPH_BYTES = 16 * 1024 * 1024
MAX_NEIGHBOURS = 12
MAX_PAIR_VISITS = 50000


def operations():
    from _workbench_schema import _object, _ID, _op
    integer = {"type": "integer", "minimum": 0, "maximum": 64000000}
    label = {"type": "integer", "minimum": 1, "maximum": 4294967295}
    reason = {"type": "string", "minLength": 1, "maxLength": 4096}
    base = {"imageId": _ID, "channel": integer}
    link = {**base, "sourceTimeIndex": integer, "sourceLabelId": label,
            "targetTimeIndex": integer, "targetLabelId": label, "reason": reason}
    return [
        _op("lineage.initialize", "Initialize a separate lineage graph from current one-to-one tracks; retain prior history.",
            _object({**base, "reason": reason}, list(base)), True),
        _op("lineage.get", "Read lineage branches, exact observations, correction history and input currentness.",
            _object(base, list(base))),
        _op("lineage.division.set", "Record or correct one parent and exactly two daughters at a later time.",
            _object({**base, "divisionId": _ID, "parentTimeIndex": integer, "parentLabelId": label,
                     "daughterTimeIndex": integer,
                     "daughterLabelIds": {"type": "array", "items": label, "minItems": 2, "maxItems": 2},
                     "replaceExisting": {"type": "boolean"}, "reason": reason},
                    list(base) + ["parentTimeIndex", "parentLabelId", "daughterTimeIndex",
                                  "daughterLabelIds", "reason"]), True),
        _op("lineage.division.remove", "Remove both daughter links from a recorded division without deleting observations.",
            _object({**base, "divisionId": _ID, "reason": reason}, list(base) + ["divisionId", "reason"]), True),
        *[_op("lineage." + action, "Explicitly " + action + " a continuation in the lineage graph.",
              _object(link, list(link)), True) for action in ("link", "unlink")],
        _op("lineage.undo", "Restore the preceding lineage graph when its exact source inputs are still current.",
            _object({**base, "reason": reason}, list(base) + ["reason"]), True),
        _op("lineage.summary", "Read observed per-track and per-lineage measurements with explicit calibration limits.",
            _object(base, list(base))),
        _op("lineage.suggest", "Rank bounded daughter pairs by centroid distance and combined voxel count; never infer a confirmed division.",
            _object({**base, "parentTimeIndex": integer, "daughterTimeIndex": integer,
                     "maxDistance": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000000},
                     "units": {"type": "string", "enum": ["voxel", "um"]},
                     "minCombinedVolumeRatio": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
                     "maxCombinedVolumeRatio": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 100}},
                    list(base) + ["parentTimeIndex", "daughterTimeIndex", "maxDistance", "units"])),
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def node_id(time, label):
    return f"t{time}-l{label}"


def record_for(image, channel):
    return next((record for record in image.get("volumeLineages", []) if record["channel"] == channel), None)


def snapshot_for(record, identifier=None):
    identifier = identifier or record.get("currentSnapshotId")
    snapshot = next((value for value in record["snapshots"] if value["id"] == identifier), None)
    if snapshot is None:
        fail("lineage-corrupt", "A lineage snapshot reference is missing.")
    return snapshot


def tracking_fingerprint(image, channel):
    import _workbench_volume as volume
    base = volume.get_tracks(image, channel)
    if base is None:
        return None
    return digest({key: base.get(key) for key in
                   ("channel", "timeIndices", "timeSelection", "parameters", "edges", "inputFingerprint")})


def snapshot_current(image, snapshot):
    import _workbench_volume as volume
    channel = snapshot["channel"]
    if snapshot.get("bindingKind") == "temporal":
        binding = {"channel": channel, "timeIndices": snapshot["timeIndices"], "timeSelection": "explicit"}
        return (snapshot["sourceHash"] == image["sourceHash"] and
                snapshot["inputFingerprint"] == volume.tracks_fingerprint(image, binding))
    base = volume.get_tracks(image, channel)
    if base is None or base["inputFingerprint"] != volume.tracks_fingerprint(image, base):
        return False
    return (snapshot["baseTrackingFingerprint"] == tracking_fingerprint(image, channel) and
            snapshot["inputFingerprint"] == base["inputFingerprint"] and
            snapshot["sourceHash"] == image["sourceHash"])


def describe(image, record):
    snapshot = snapshot_for(record)
    return {"imageId": image["id"], "channel": record["channel"],
            "status": "current" if snapshot_current(image, snapshot) else "stale",
            "graphRevision": snapshot["revision"], "snapshotId": snapshot["id"],
            "undoAvailable": bool(record.get("undoStack")),
            **copy.deepcopy(snapshot["counts"])}


def load_graph(store, snapshot):
    path = store.verify_artifact(snapshot["graphPath"], snapshot["graphHash"])
    if path.stat().st_size > MAX_GRAPH_BYTES:
        fail("lineage-too-large", "Saved lineage graph exceeds its allocation bound.")
    try:
        graph = json.loads(path.read_text("utf-8"))
    except (UnicodeError, ValueError):
        fail("lineage-corrupt", "Saved lineage graph is not valid JSON.")
    validate_graph(graph)
    return graph


def validate_graph(graph):
    """Validate the complete directed forest, including two-edge divisions."""
    nodes = graph.get("nodes", [])
    edges = graph.get("edges", [])
    divisions = graph.get("divisions", [])
    if len(nodes) > MAX_NODES or len(edges) > MAX_NODES or len(divisions) > MAX_NODES // 2:
        fail("lineage-too-large", "Lineage graphs support at most 20,000 observations.")
    by_id = {node["id"]: node for node in nodes}
    if len(by_id) != len(nodes):
        fail("lineage-corrupt", "Lineage observation identifiers must be unique.")
    for node in nodes:
        if (node["id"] != node_id(node["timeIndex"], node["labelId"]) or
                type(node["timeIndex"]) is not int or node["timeIndex"] < 0 or
                type(node["labelId"]) is not int or node["labelId"] < 1 or
                any(not math.isfinite(node[key]) for key in ("cx", "cy", "cz")) or
                node["voxelCount"] <= 0):
            fail("lineage-corrupt", "Lineage observation coordinates or identity are invalid.")
    outgoing, incoming = {}, {}
    division_by_id = {item["id"]: item for item in divisions}
    if len(division_by_id) != len(divisions):
        fail("lineage-corrupt", "Division identifiers must be unique.")
    for edge in edges:
        source, target = edge["sourceNodeId"], edge["targetNodeId"]
        if source not in by_id or target not in by_id:
            fail("lineage-corrupt", "A lineage correspondence references an unavailable observation.")
        if by_id[source]["timeIndex"] >= by_id[target]["timeIndex"]:
            fail("invalid-link", "Lineage correspondences must point strictly forward in time.")
        if target in incoming:
            fail("link-conflict", "An observation can have only one incoming lineage correspondence.")
        if edge["kind"] not in ("continuation", "division"):
            fail("lineage-corrupt", "Unknown lineage correspondence kind.")
        if edge["kind"] == "division" and edge.get("divisionId") not in division_by_id:
            fail("lineage-corrupt", "A division correspondence lacks its recorded event.")
        incoming[target] = edge
        outgoing.setdefault(source, []).append(edge)
    for source, children in outgoing.items():
        if len(children) > 2 or (len(children) == 2 and
                                (any(edge["kind"] != "division" for edge in children) or
                                 children[0]["divisionId"] != children[1]["divisionId"])):
            fail("link-conflict", "A parent can continue once or have exactly two recorded daughters.")
        if len(children) == 1 and children[0]["kind"] == "division":
            fail("lineage-corrupt", "A division must retain both daughter correspondences.")
    for division in divisions:
        parent = node_id(division["parent"]["timeIndex"], division["parent"]["labelId"])
        daughters = division["daughters"]
        targets = {node_id(item["timeIndex"], item["labelId"]) for item in daughters}
        if (len(daughters) != 2 or len(targets) != 2 or
                daughters[0]["timeIndex"] != daughters[1]["timeIndex"]):
            fail("invalid-division", "A division needs two distinct daughters at the same later time.")
        matching = [edge for edge in outgoing.get(parent, []) if edge.get("divisionId") == division["id"]]
        if len(matching) != 2 or {edge["targetNodeId"] for edge in matching} != targets:
            fail("lineage-corrupt", "Division events and graph correspondences disagree.")
    return by_id, outgoing, incoming


def edge_between(source, target, kind="continuation", division_id=None):
    result = {"sourceNodeId": source["id"], "targetNodeId": target["id"],
              "sourceTimeIndex": source["timeIndex"], "sourceLabelId": source["labelId"],
              "targetTimeIndex": target["timeIndex"], "targetLabelId": target["labelId"], "kind": kind}
    if division_id is not None:
        result["divisionId"] = division_id
    return result


def graph_measurements(graph):
    by_id, outgoing, incoming = validate_graph(graph)
    nodes = sorted(by_id.values(), key=lambda item: (item["timeIndex"], item["labelId"]))
    starts = [node for node in nodes if node["id"] not in incoming or
              incoming[node["id"]]["kind"] == "division"]
    spacing = graph["voxelSizeUm"]
    factors = [spacing.get(axis) for axis in "xyz"]
    calibrated = all(value is not None for value in factors)
    step = graph.get("timeStepSeconds")
    temporal = graph.get("temporalInference")
    drift = {item["timeIndex"]: [item[axis] for axis in "xyz"]
             for item in (temporal or {}).get("drift", {}).get("offsets", [])}
    tracks, node_track = [], {}
    for start in starts:
        observations = [start]
        while outgoing.get(observations[-1]["id"]):
            edges = outgoing[observations[-1]["id"]]
            if len(edges) != 1 or edges[0]["kind"] != "continuation":
                break
            observations.append(by_id[edges[0]["targetNodeId"]])
        identifier = "segment-" + start["id"]
        for node in observations:
            node_track[node["id"]] = identifier
        elapsed = observations[-1]["timeIndex"] - start["timeIndex"]
        voxel_path = 0.0
        physical_path = 0.0 if calibrated else None
        corrected_voxel_path = 0.0 if temporal else None
        corrected_physical_path = 0.0 if temporal and calibrated else None
        for first, second in zip(observations, observations[1:]):
            delta = [second[key] - first[key] for key in ("cx", "cy", "cz")]
            voxel_path += math.sqrt(sum(value * value for value in delta))
            if calibrated:
                physical_path += math.sqrt(sum((value * scale) ** 2 for value, scale in zip(delta, factors)))
            if temporal:
                first_drift = drift.get(first["timeIndex"], [0, 0, 0])
                second_drift = drift.get(second["timeIndex"], [0, 0, 0])
                corrected = [value - (b - a) for value, a, b in zip(delta, first_drift, second_drift)]
                corrected_voxel_path += math.sqrt(sum(value * value for value in corrected))
                if calibrated:
                    corrected_physical_path += math.sqrt(sum((value * scale) ** 2 for value, scale in zip(corrected, factors)))
        seconds = elapsed * step if step is not None else None
        physical_volumes = [node["volumeUm3"] for node in observations]
        tracks.append({"id": identifier, "lineageId": None, "parentTrackId": None, "daughterTrackIds": [],
                       "observations": observations,
                       "summary": {"observationCount": len(observations), "startTimeIndex": start["timeIndex"],
                                   "endTimeIndex": observations[-1]["timeIndex"], "elapsedFrames": elapsed,
                                   "elapsedSeconds": seconds, "pathLengthVoxels": voxel_path,
                                   "pathLengthUm": physical_path,
                                   "driftCorrectedPathLengthVoxels": corrected_voxel_path,
                                   "driftCorrectedPathLengthUm": corrected_physical_path,
                                   "driftCorrectedMeanSpeedUmPerSecond": corrected_physical_path / seconds
                                   if corrected_physical_path is not None and seconds is not None and seconds > 0 else None,
                                   "meanSpeedUmPerSecond": physical_path / seconds
                                   if physical_path is not None and seconds is not None and seconds > 0 else None,
                                   "meanVolumeUm3": sum(physical_volumes) / len(physical_volumes)
                                   if all(value is not None for value in physical_volumes) else None}})
    by_track = {track["id"]: track for track in tracks}
    for division in graph["divisions"]:
        parent = node_track[node_id(division["parent"]["timeIndex"], division["parent"]["labelId"])]
        children = [node_track[node_id(child["timeIndex"], child["labelId"])] for child in division["daughters"]]
        by_track[parent]["daughterTrackIds"] = children
        for child in children:
            by_track[child]["parentTrackId"] = parent
    lineages = {}
    # Starts are time sorted, so each parent segment has already been assigned.
    for track in tracks:
        parent = track["parentTrackId"]
        lineage_id = by_track[parent]["lineageId"] if parent else "lineage-" + track["id"]
        track["lineageId"] = lineage_id
        lineage = lineages.setdefault(lineage_id, {
            "id": lineage_id, "rootTrackId": track["id"], "trackIds": [], "divisionCount": 0,
            "terminalTrackIds": [], "startTimeIndex": track["summary"]["startTimeIndex"],
            "endTimeIndex": track["summary"]["endTimeIndex"], "observationCount": 0})
        lineage["trackIds"].append(track["id"])
        lineage["divisionCount"] += int(bool(track["daughterTrackIds"]))
        if not track["daughterTrackIds"]:
            lineage["terminalTrackIds"].append(track["id"])
        lineage["endTimeIndex"] = max(lineage["endTimeIndex"], track["summary"]["endTimeIndex"])
        lineage["observationCount"] += len(track["observations"])
    summary = {"trackCount": len(tracks), "lineageCount": len(lineages),
               "divisionCount": len(graph["divisions"]), "observationCount": len(nodes),
               "calibratedXYZ": calibrated, "timeCalibrated": step is not None,
               "voxelSizeUm": copy.deepcopy(spacing), "timeStepSeconds": step,
               "notes": ["Track spans describe observed endpoints; they do not establish birth, death or cell-cycle duration.",
                         "Division origins distinguish reviewed decisions from algorithmically inferred, unconfirmed events.",
                         "Ordinary path lengths use observed source centroids; separately named drift-corrected fields subtract retained offsets.",
                         "Path lengths join observed centroids across any gaps; unobserved motion is not inferred."]}
    return tracks, list(lineages.values()), summary


def get(store, image, channel, summary_only=False):
    record = record_for(image, channel)
    if record is None:
        return {"imageId": image["id"], "channel": channel, "status": "none", "graphRevision": None,
                "snapshotId": None, "undoAvailable": False, "nodes": [], "edges": [], "divisions": [],
                "tracks": [], "lineages": [], "history": [],
                "summary": {"trackCount": 0, "lineageCount": 0, "divisionCount": 0, "observationCount": 0}}
    graph = load_graph(store, snapshot_for(record))
    tracks, lineages, summary = graph_measurements(graph)
    result = {**describe(image, record), "tracks": tracks, "lineages": lineages, "summary": summary,
              "history": [{key: item[key] for key in ("id", "revision", "operation", "actor", "at", "reason")}
                          for item in record["snapshots"]]}
    if summary_only:
        result["tracks"] = [{key: value for key, value in track.items() if key != "observations"} for track in tracks]
    else:
        result.update({key: graph[key] for key in ("nodes", "edges", "divisions")})
    if graph.get("temporalInference"):
        result["temporalInference"] = copy.deepcopy(graph["temporalInference"])
    if result["status"] == "stale":
        result["summary"]["notes"].append("These are historical measurements; source geometry, calibration or baseline tracking changed.")
    return result


def save(store, image, record, graph, revision, operation, actor, reason, undo_stack=None):
    from _workbench_store import canonical, utc_now
    if len(record["snapshots"]) >= MAX_SNAPSHOTS:
        fail("lineage-history-full", "This channel retains the maximum 500 lineage snapshots; export the project before continuing in a new variant.")
    tracks, lineages, summary = graph_measurements(graph)
    graph["trackSummaries"] = [{key: value for key, value in track.items() if key != "observations"}
                              for track in tracks]
    graph["lineageSummaries"] = lineages
    graph["summary"] = summary
    encoded = (canonical(graph) + "\n").encode("utf-8")
    if len(encoded) > MAX_GRAPH_BYTES:
        fail("lineage-too-large", "The lineage graph exceeds its 16 MiB allocation budget.")
    path, hashed = store.put_bytes(encoded, ".lineage.json")
    snapshot = {"id": str(uuid.uuid4()), "channel": record["channel"],
                "graphPath": path, "graphHash": hashed,
                "sourcePath": graph["sourcePath"], "sourceHash": graph["sourceHash"],
                "frameReferences": copy.deepcopy(graph["frameReferences"]),
                "inputFingerprint": graph["inputFingerprint"],
                "baseTrackingFingerprint": graph["baseTrackingFingerprint"],
                "revision": revision, "operation": operation, "actor": copy.deepcopy(actor),
                "at": utc_now(), "reason": reason,
                "counts": {key: summary[key] for key in ("trackCount", "lineageCount", "divisionCount", "observationCount")}}
    if graph.get("validSupport"):
        snapshot["validSupport"] = copy.deepcopy(graph["validSupport"])
    if graph.get("bindingKind") == "temporal":
        snapshot.update({"bindingKind": "temporal", "timeIndices": list(graph["timeIndices"])})
    if undo_stack is None:
        undo_stack = list(record.get("undoStack", []))
        if record.get("currentSnapshotId"):
            undo_stack.append(record["currentSnapshotId"])
    record["undoStack"] = undo_stack
    record["snapshots"].append(snapshot)
    record["currentSnapshotId"] = snapshot["id"]
    return get(store, image, record["channel"])


def initialize(store, image, args, revision, actor):
    import _workbench_volume as volume
    import _workbench_support as support
    channel = args["channel"]
    volume.selection(image, 0, channel)
    base = volume.get_tracks(image, channel)
    if base is None:
        fail("tracks-required", "Create current one-to-one tracks before initializing the lineage graph.")
    if base["inputFingerprint"] != volume.tracks_fingerprint(image, base):
        fail("stale-tracks", "Recompute the baseline tracks from current saved masks before initializing lineages.")
    nodes, refs = [], []
    store.verify_artifact(image["sourcePath"], image["sourceHash"])
    for time in base["timeIndices"]:
        frame = volume.current_frame(store, image, time, channel, verify=False)
        store.verify_artifact(frame["labelsPath"], frame["labelsHash"])
        refs.append({"timeIndex": time, "channel": channel, "labelsPath": frame["labelsPath"],
                     "labelsHash": frame["labelsHash"], "inputFingerprint": frame["inputFingerprint"],
                     "analysisRevision": frame["analysisRevision"], "measurementRevision": frame["measurementRevision"]})
        if len(nodes) + len(frame["cells"]) > MAX_NODES:
            fail("lineage-too-large", "A lineage graph supports at most 20,000 observations; select fewer tracked frames.")
        for cell in frame["cells"]:
            nodes.append({"id": node_id(time, cell["labelId"]), "timeIndex": time,
                          **{key: cell[key] for key in
                             ("labelId", "cx", "cy", "cz", "voxelCount", "volumeUm3", "meanIntensity")}})
    by_id = {node["id"]: node for node in nodes}
    edges = []
    for base_edge in base["edges"]:
        source = by_id.get(node_id(base_edge["sourceTimeIndex"], base_edge["sourceLabelId"]))
        target = by_id.get(node_id(base_edge["targetTimeIndex"], base_edge["targetLabelId"]))
        if source is None or target is None:
            fail("tracks-corrupt", "A baseline correspondence has no saved volume observation.")
        edge = edge_between(source, target)
        edge["baseline"] = copy.deepcopy(base_edge)
        edges.append(edge)
    graph = {"schemaVersion": 1, "imageId": image["id"], "channel": channel,
             "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
             "frameReferences": refs, "inputFingerprint": base["inputFingerprint"],
             "baseTrackingFingerprint": tracking_fingerprint(image, channel),
             "timeIndices": list(base["timeIndices"]), "voxelSizeUm": volume.calibration(image),
             "timeStepSeconds": image.get("timeStepSeconds"), "nodes": nodes, "edges": edges, "divisions": []}
    if support.descriptor(image):
        graph["validSupport"] = copy.deepcopy(support.descriptor(image))
    record = record_for(image, channel)
    if record is None:
        record = {"channel": channel, "currentSnapshotId": None, "undoStack": [], "snapshots": []}
        image.setdefault("volumeLineages", []).append(record)
    return save(store, image, record, graph, revision, "lineage.initialize", actor,
                args.get("reason", "Initialized from current one-to-one tracks."))


def current_graph(store, image, channel):
    record = record_for(image, channel)
    if record is None:
        fail("lineage-required", "Initialize the lineage graph before editing or suggesting divisions.")
    snapshot = snapshot_for(record)
    if not snapshot_current(image, snapshot):
        fail("stale-lineage", "Source masks, calibration or baseline tracking changed. Reinitialize lineages from current tracks.")
    store.verify_artifact(snapshot["sourcePath"], snapshot["sourceHash"])
    for frame in snapshot["frameReferences"]:
        store.verify_artifact(frame["labelsPath"], frame["labelsHash"])
    return record, load_graph(store, snapshot)


def selected_node(by_id, time, label):
    node = by_id.get(node_id(time, label))
    if node is None:
        fail("invalid-labels", "The requested time and label are not observations in this lineage graph.")
    return node


def edit(store, image, operation, args, revision, actor):
    from _workbench_store import utc_now
    record, graph = current_graph(store, image, args["channel"])
    by_id, outgoing, incoming = validate_graph(graph)
    reason = args["reason"]
    event = {"operation": operation, "actor": copy.deepcopy(actor), "at": utc_now(), "reason": reason}
    if operation == "lineage.undo":
        stack = list(record.get("undoStack", []))
        if not stack:
            fail("nothing-to-undo", "No previous lineage snapshot is available.")
        previous = snapshot_for(record, stack.pop())
        if not snapshot_current(image, previous):
            fail("stale-lineage-undo", "The previous graph uses different masks or baseline tracks and cannot be restored over current inputs.")
        restored = load_graph(store, previous)
        restored["lastEdit"] = {**event, "restoredSnapshotId": previous["id"]}
        return save(store, image, record, restored, revision, operation, actor, reason, stack)
    if operation == "lineage.division.remove":
        division = next((item for item in graph["divisions"] if item["id"] == args["divisionId"]), None)
        if division is None:
            fail("division-not-found", "The requested division is not in this graph.")
        graph["divisions"] = [item for item in graph["divisions"] if item["id"] != division["id"]]
        graph["edges"] = [edge for edge in graph["edges"] if edge.get("divisionId") != division["id"]]
        event["removedDivision"] = division
    elif operation == "lineage.division.set":
        if args["parentTimeIndex"] >= args["daughterTimeIndex"] or len(set(args["daughterLabelIds"])) != 2:
            fail("invalid-division", "Choose two distinct daughters at the same strictly later time.")
        parent = selected_node(by_id, args["parentTimeIndex"], args["parentLabelId"])
        daughters = [selected_node(by_id, args["daughterTimeIndex"], label)
                     for label in sorted(args["daughterLabelIds"])]
        division_id = args.get("divisionId") or str(uuid.uuid4())
        if "divisionId" in args and not any(item["id"] == division_id for item in graph["divisions"]):
            fail("division-not-found", "The division selected for correction does not exist.")
        existing = [edge for edge in graph["edges"] if edge.get("divisionId") == division_id]
        daughter_ids = {daughter["id"] for daughter in daughters}
        conflicts = [edge for edge in graph["edges"] if edge not in existing and
                     (edge["sourceNodeId"] == parent["id"] or edge["targetNodeId"] in daughter_ids)]
        if conflicts and not args.get("replaceExisting", False):
            fail("link-conflict", "Existing correspondences conflict with this division. Explicit replacement is required.",
                 {"conflictingEdges": conflicts})
        replaced_divisions = {edge["divisionId"] for edge in conflicts if edge["kind"] == "division"}
        removed = [edge for edge in graph["edges"] if edge in existing or edge in conflicts or
                   edge.get("divisionId") in replaced_divisions]
        graph["edges"] = [edge for edge in graph["edges"] if edge not in removed]
        graph["divisions"] = [item for item in graph["divisions"]
                              if item["id"] != division_id and item["id"] not in replaced_divisions]
        division = {"id": division_id,
                    "parent": {key: parent[key] for key in ("timeIndex", "labelId")},
                    "daughters": [{key: daughter[key] for key in ("timeIndex", "labelId")} for daughter in daughters],
                    "reason": reason, "actor": copy.deepcopy(actor), "at": event["at"],
                    "origin": "reviewed", "confirmation": "declared-local-decision"}
        graph["divisions"].append(division)
        graph["edges"].extend(edge_between(parent, daughter, "division", division_id) for daughter in daughters)
        event.update({"divisionId": division_id, "removedEdges": removed,
                      "replacedDivisionIds": sorted(replaced_divisions)})
    else:
        source = selected_node(by_id, args["sourceTimeIndex"], args["sourceLabelId"])
        target = selected_node(by_id, args["targetTimeIndex"], args["targetLabelId"])
        if source["timeIndex"] >= target["timeIndex"]:
            fail("invalid-link", "Lineage correspondences must point strictly forward in time.")
        matching = next((edge for edge in graph["edges"] if edge["sourceNodeId"] == source["id"]
                         and edge["targetNodeId"] == target["id"]), None)
        if operation == "lineage.unlink":
            if matching is None:
                fail("link-not-found", "This continuation is not in the lineage graph.")
            if matching["kind"] != "continuation":
                fail("division-edit-required", "Remove or correct the division event to change its daughter correspondences.")
            graph["edges"].remove(matching)
            event["removedEdges"] = [matching]
        else:
            if outgoing.get(source["id"]) or target["id"] in incoming:
                fail("link-conflict", "Unlink conflicting correspondences before recording this continuation.")
            graph["edges"].append({**edge_between(source, target), "decision": copy.deepcopy(event)})
    graph["lastEdit"] = event
    return save(store, image, record, graph, revision, operation, actor, reason)


def suggest(store, image, args):
    import _workbench_imaging as imaging
    imaging.require("numpy", "scipy")
    import numpy as np
    from scipy.spatial import cKDTree
    _, graph = current_graph(store, image, args["channel"])
    if args["parentTimeIndex"] >= args["daughterTimeIndex"]:
        fail("invalid-time-selection", "Daughter candidates must come from a strictly later frame.")
    if any(time not in graph["timeIndices"] for time in (args["parentTimeIndex"], args["daughterTimeIndex"])):
        fail("invalid-time-selection", "Both frames must be part of the saved lineage graph.")
    minimum = args.get("minCombinedVolumeRatio", 0.5)
    maximum = args.get("maxCombinedVolumeRatio", 2.0)
    if minimum > maximum:
        fail("invalid-arguments", "Minimum combined-volume ratio cannot exceed its maximum.")
    factors = [graph["voxelSizeUm"].get(axis) for axis in "xyz"] if args["units"] == "um" else [1, 1, 1]
    if any(value is None for value in factors):
        fail("calibration-required", "Physical candidate distances require all three voxel dimensions.")
    _, outgoing, incoming = validate_graph(graph)
    parents = [node for node in graph["nodes"] if node["timeIndex"] == args["parentTimeIndex"]]
    children = [node for node in graph["nodes"] if node["timeIndex"] == args["daughterTimeIndex"]]
    candidates = []
    visits = 0
    considered = 0
    truncated = False
    found = 0
    limit = args.get("limit", 50)
    if children:
        points = np.asarray([[node[key] for key in ("cx", "cy", "cz")] for node in children]) * factors
        tree = cKDTree(points)
        for parent in sorted(parents, key=lambda node: node["labelId"]):
            if any(edge["kind"] == "division" for edge in outgoing.get(parent["id"], [])):
                continue
            considered += 1
            point = np.asarray([parent[key] for key in ("cx", "cy", "cz")]) * factors
            distances, indices = tree.query(point, k=min(MAX_NEIGHBOURS + 1, len(children)),
                                            distance_upper_bound=args["maxDistance"])
            neighbours = [(float(distance), int(index)) for distance, index
                          in zip(np.atleast_1d(distances), np.atleast_1d(indices))
                          if math.isfinite(float(distance)) and int(index) < len(children)]
            if len(neighbours) > MAX_NEIGHBOURS:
                truncated = True
            neighbours = neighbours[:MAX_NEIGHBOURS]
            neighbours = [(distance, index) for distance, index in neighbours
                          if children[index]["id"] not in incoming or
                          incoming[children[index]["id"]]["sourceNodeId"] == parent["id"]]
            for first, second in itertools.combinations(neighbours, 2):
                if visits >= MAX_PAIR_VISITS:
                    truncated = True
                    break
                visits += 1
                daughter_nodes = [children[first[1]], children[second[1]]]
                ratio = sum(node["voxelCount"] for node in daughter_nodes) / parent["voxelCount"]
                if not minimum <= ratio <= maximum:
                    continue
                found += 1
                separation = float(np.linalg.norm(points[first[1]] - points[second[1]]))
                candidate = {"parent": {key: parent[key] for key in ("timeIndex", "labelId")},
                             "daughters": [{key: child[key] for key in ("timeIndex", "labelId")}
                                           for child in daughter_nodes],
                             "parentDistances": [first[0], second[0]], "daughterSeparation": separation,
                             "combinedVolumeRatio": ratio, "units": args["units"],
                             "requiresReplacement": bool(outgoing.get(parent["id"])) or
                             any(child["id"] in incoming for child in daughter_nodes),
                             "score": (first[0] + second[0]) / (2 * args["maxDistance"]) + abs(math.log(ratio))}
                candidates.append(candidate)
                # Keep memory bounded while retaining the best encountered pairs.
                if len(candidates) > limit * 2:
                    candidates.sort(key=lambda item: (item["score"], item["parent"]["labelId"],
                                                     [child["labelId"] for child in item["daughters"]]))
                    del candidates[limit:]
            if visits >= MAX_PAIR_VISITS:
                break
    candidates.sort(key=lambda item: (item["score"], item["parent"]["labelId"],
                                     [child["labelId"] for child in item["daughters"]]))
    return {"imageId": image["id"], "channel": args["channel"],
            "parentTimeIndex": args["parentTimeIndex"], "daughterTimeIndex": args["daughterTimeIndex"],
            "candidates": candidates[:limit],
            "criteria": {"maxDistance": args["maxDistance"], "minCombinedVolumeRatio": minimum,
                         "maxCombinedVolumeRatio": maximum, "maxNeighboursPerParent": MAX_NEIGHBOURS,
                         "maxPairVisits": MAX_PAIR_VISITS},
            "counts": {"parentsConsidered": considered, "pairVisits": visits, "candidatesFound": found},
            "truncated": truncated or found > limit,
            "notes": ["Candidates rank geometry and combined voxel count; scores are not division probabilities.",
                      "Only the nearest 12 daughters per parent and 50,000 pair visits are considered.",
                      "Daughters already assigned to another parent are excluded; existing continuations require explicit replacement.",
                      "Combined volume ratio uses voxel counts from the same spatial grid, so constant voxel calibration cancels."]}


def artifact_references(document):
    references = {}
    for image in document["images"]:
        for record in image.get("volumeLineages", []):
            for snapshot in record["snapshots"]:
                references[snapshot["graphPath"]] = snapshot["graphHash"]
                references[snapshot["sourcePath"]] = snapshot["sourceHash"]
                if snapshot.get("validSupport"):
                    value = snapshot["validSupport"]
                    references[value["path"]] = value["hash"]
                for frame in snapshot["frameReferences"]:
                    references[frame["labelsPath"]] = frame["labelsHash"]
    return references


def export(store, document):
    # Full graphs and their track summaries are already immutable package
    # artifacts. Keep this catalogue small even when many images have lineages.
    return {"schemaVersion": 1,
            "lineages": [{**describe(image, record),
                          "graphPath": snapshot_for(record)["graphPath"],
                          "graphHash": snapshot_for(record)["graphHash"]}
                         for image in document["images"] for record in image.get("volumeLineages", [])],
            "graphContents": ["nodes", "edges", "divisions", "trackSummaries", "lineageSummaries",
                              "summary", "frameReferences", "voxelSizeUm", "timeStepSeconds"],
            "identityAssurance": "declared-local-actor-identities; no authentication"}


def execute(store, document, operation, args, revision, actor):
    image = next((item for item in document["images"] if item["id"] == args["imageId"]), None)
    if image is None:
        fail("image-not-found", "Image is not part of this project.")
    import _workbench_volume as volume
    volume.selection(image, 0, args["channel"])
    if operation == "lineage.initialize":
        return initialize(store, image, args, revision, actor)
    if operation in ("lineage.get", "lineage.summary"):
        return get(store, image, args["channel"], summary_only=operation == "lineage.summary")
    if operation == "lineage.suggest":
        return suggest(store, image, args)
    return edit(store, image, operation, args, revision, actor)
