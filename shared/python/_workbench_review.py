"""Deterministic QC samples, declared reviewers and immutable review evidence."""
from __future__ import annotations

from _workbench_indexed import image_index

import copy
import hashlib
import heapq
import itertools
import math
import uuid

MAX_SESSIONS = 100
MAX_SAMPLES = 1000
MAX_CANDIDATES = 200000
MAX_EVENTS = 10000
MAX_FLAGS = 20000


def operations():
    from _workbench_schema import _object, _op, _ID
    images = {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000}
    selection = {"imageIds": images, "target": {"type": "string", "enum": ["plane", "volume"]},
                 "timeIndices": {"type": "array", "items": {"type": "integer", "minimum": 0},
                                 "minItems": 1, "maxItems": 1000},
                 "channel": {"type": "integer", "minimum": 0, "maximum": 31}}
    reason = {"type": "string", "minLength": 1, "maxLength": 2000}
    identity = _object({"id": _ID, "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                       ["id", "name"])
    item = {"sessionId": _ID, "itemId": _ID}
    return [
        _op("review.flag", "Mark current analyzed inputs accepted, needing review, or unclassified; record the declared actor.",
            _object({**selection, "state": {"type": "string", "enum": ["accepted", "needs-review", "unclassified"]},
                     "reason": reason}, ["imageIds", "state"]), True),
        _op("review.session.create", "Freeze a deterministic random sample of current images or detected cells for independent review.",
            _object({**selection, "name": {"type": "string", "minLength": 1, "maxLength": 200},
                     "unit": {"type": "string", "enum": ["image", "cell"]},
                     "sampleSize": {"type": "integer", "minimum": 1, "maximum": MAX_SAMPLES},
                     "seed": {"type": "integer", "minimum": 0, "maximum": 4294967295},
                     "acceptedOnly": {"type": "boolean"}, "blinded": {"type": "boolean"},
                     "requiredReviews": {"type": "integer", "minimum": 1, "maximum": 2},
                     "reviewers": {"type": "array", "items": identity, "minItems": 1, "maxItems": 5}},
                    ["name", "unit", "sampleSize", "seed", "reviewers", "requiredReviews"]), True),
        _op("review.session.list", "Read review session progress and currentness.", _object()),
        _op("review.session.get", "Read the review queue with presentation blinding for a declared reviewer.",
            _object({"sessionId": _ID, "reviewerId": _ID}, ["sessionId"])),
        _op("review.item.preview", "Read exact frozen source and mask pixels for a sampled review item.",
            _object({**item, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048},
                     "plane": {"type": "string", "enum": ["xy", "xz", "yz"]},
                     "index": {"type": "integer", "minimum": 0}}, ["sessionId", "itemId"])),
        _op("review.decision", "Append a decision attributed to a declared reviewer; prior decisions remain in history.",
            _object({**item, "reviewerId": _ID,
                     "decision": {"type": "string", "enum": ["accept", "reject", "uncertain"]},
                     "reason": reason, "errorType": {"type": "string", "enum": [
                         "none", "missed-object", "false-positive", "boundary", "merge", "split", "other"]}},
                    ["sessionId", "itemId", "reviewerId", "decision"]), True),
        _op("review.adjudicate", "Append an adjudicated decision after the required independent declared reviewers have responded.",
            _object({**item, "decision": {"type": "string", "enum": ["accept", "reject"]}, "reason": reason},
                    ["sessionId", "itemId", "decision", "reason"]), True),
        _op("review.reveal", "End presentation blinding for a session and record the reason and actor.",
            _object({"sessionId": _ID, "reason": reason}, ["sessionId", "reason"]), True),
        _op("review.summary", "Report sampled review workload, disagreement, rejection and stale-input counts.",
            _object({"sessionId": _ID})),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def _target_key(image_id, target, time_index=None, channel=None):
    return _digest([image_id, target, time_index, channel])


def _targets(document, args):
    selected = args.get("imageIds", [image["id"] for image in document["images"]])
    if len(selected) != len(set(selected)):
        fail("invalid-selection", "Select each image only once.")
    known = image_index(document)
    if set(selected) - set(known):
        fail("image-not-found", "A selected image is not part of this project.")
    target = args.get("target", "plane")
    if target == "plane" and any(key in args for key in ("channel", "timeIndices")):
        fail("invalid-selection", "Plane review uses each saved analysis source selection.")
    times = args.get("timeIndices")
    if times is not None and len(times) != len(set(times)):
        fail("invalid-selection", "Select each time index only once.")
    for image_id in sorted(selected):
        image = known[image_id]
        if target == "plane":
            if image.get("analysis"):
                yield image, image["analysis"], {"target": "plane"}, _target_key(image_id, target)
        else:
            for frame in sorted(image.get("volumeFrames", []), key=lambda value: (value["timeIndex"], value["channel"])):
                if times is not None and frame["timeIndex"] not in times:
                    continue
                if "channel" in args and frame["channel"] != args["channel"]:
                    continue
                selection = {"target": "volume", "timeIndex": frame["timeIndex"], "channel": frame["channel"]}
                yield image, frame, selection, _target_key(image_id, target, frame["timeIndex"], frame["channel"])


def _analysis_current(store, image, analysis, selection):
    if selection["target"] == "plane":
        from _workbench_core import _current_analysis
        return _current_analysis(store, image)
    from _workbench_volume import current_frame
    return current_frame(store, image, selection["timeIndex"], selection["channel"])


def _current(document, target, images=None):
    from _workbench_core import _fingerprint
    from _workbench_volume import analysis_fingerprint
    image = (images.get(target["imageId"]) if images is not None else
             next((image for image in document["images"] if image["id"] == target["imageId"]), None))
    if image is None:
        return False
    if target["selection"]["target"] == "plane":
        analysis = image.get("analysis")
        return bool(analysis and _fingerprint(image, analysis) == target["fingerprint"])
    selection = target["selection"]
    frame = next((frame for frame in image.get("volumeFrames", [])
                  if frame["timeIndex"] == selection["timeIndex"] and frame["channel"] == selection["channel"]), None)
    return bool(frame and analysis_fingerprint(image, frame) == target["fingerprint"])


def _latest_flags(document):
    return {item["targetId"]: item for item in document.get("reviewFlags", [])}


def flags_by_image(document):
    result = {}
    images = image_index(document)
    for flag in _latest_flags(document).values():
        value = {key: copy.deepcopy(value) for key, value in flag.items() if key != "actor"}
        value["stale"] = not _current(document, flag, images)
        result.setdefault(flag["imageId"], []).append(value)
    return result


def _flag(store, document, args, revision, actor):
    from _workbench_store import utc_now
    targets = list(_targets(document, args))
    if not targets:
        fail("analysis-required", "No current analyzed planes or volumes match the flag selection.")
    flags = document.setdefault("reviewFlags", [])
    if len(flags) + len(targets) > MAX_FLAGS:
        fail("review-limit", "A project supports at most 20,000 immutable classification events.")
    output = []
    for image, analysis, selection, key in targets:
        _analysis_current(store, image, analysis, selection)
        value = {"id": str(uuid.uuid4()), "targetId": key, "imageId": image["id"],
                 "selection": selection, "state": args["state"], "reason": args.get("reason"),
                 "fingerprint": analysis["inputFingerprint"], "analysisRevision": analysis["analysisRevision"],
                 "revision": revision, "at": utc_now(), "actor": copy.deepcopy(actor)}
        flags.append(value)
        output.append(copy.deepcopy(value))
    return {"flags": output}


def _freeze_target(image, analysis, selection, key):
    metadata = {name: copy.deepcopy(image[name]) for name in (
        "id", "name", "sourcePath", "sourceHash", "width", "height", "channels", "pxPerUm",
        "axes", "shape", "dtype", "zCount", "timeCount", "importedAt") if name in image}
    for name in ("voxelSizeUm", "timeStepSeconds", "derivation", "validSupport"):
        if name in image:
            metadata[name] = copy.deepcopy(image[name])
    saved = {name: copy.deepcopy(analysis[name]) for name in (
        "labelsPath", "labelsHash", "parameters", "analysisRevision", "measurementRevision",
        "inputFingerprint", "engineVersion", "imageStats", "timeIndex", "channel") if name in analysis}
    if analysis.get("model"):
        saved["model"] = copy.deepcopy(analysis["model"])
    return {"id": key, "imageId": image["id"], "imageName": image["name"], "selection": selection,
            "fingerprint": analysis["inputFingerprint"], "image": metadata, "analysis": saved}


def _create(store, document, args, revision, actor):
    from _workbench_store import utc_now, canonical
    sessions = document.setdefault("reviewSessions", [])
    if len(sessions) >= MAX_SESSIONS:
        fail("review-limit", "A project supports at most 100 retained review sessions.")
    reviewers = args["reviewers"]
    if (len({item["id"] for item in reviewers}) != len(reviewers)
            or len({item["name"].strip().casefold() for item in reviewers}) != len(reviewers)):
        fail("duplicate-reviewer", "Reviewer identifiers and declared names must be distinct.")
    if len(reviewers) < args["requiredReviews"]:
        fail("reviewer-required", "Register enough distinct declared reviewers for the required decisions.")
    flags = _latest_flags(document)
    reservoir = []
    count = 0
    population = hashlib.sha256()
    accepted_only = args.get("acceptedOnly", True)
    for image, analysis, selection, key in _targets(document, args):
        if accepted_only:
            flag = flags.get(key)
            if not flag or flag["state"] != "accepted" or not _current(document, flag):
                continue
        _analysis_current(store, image, analysis, selection)
        candidates = analysis["cells"] if args["unit"] == "cell" else [None]
        for cell in candidates:
            label = cell["labelId"] if cell is not None else None
            identity = canonical([key, label, analysis["inputFingerprint"]])
            population.update(identity.encode())
            rank = int(_digest([args["seed"], key, label]), 16)
            candidate = (-rank, key, label or 0)
            if len(reservoir) < args["sampleSize"]:
                heapq.heappush(reservoir, candidate)
            elif candidate > reservoir[0]:
                heapq.heapreplace(reservoir, candidate)
            count += 1
            if count > MAX_CANDIDATES:
                fail("review-limit", "Select a smaller population of at most 200,000 candidate units.")
    if not count:
        fail("empty-review-population", "No current units match the population. Mark results accepted or explicitly include all analyzed results.")
    if count < args["sampleSize"]:
        fail("sample-too-large", f"The selected population contains only {count} eligible {args['unit']} units.")
    chosen = sorted(reservoir, key=lambda item: (-item[0], item[1], item[2]))
    target_keys = {item[1] for item in chosen}
    selected_targets = {key: _freeze_target(image, analysis, selection, key)
                        for image, analysis, selection, key in _targets(document, args) if key in target_keys}
    items = [{"id": str(uuid.uuid4()), "code": f"R{index + 1:04d}", "targetId": key,
              **({"labelId": label} if args["unit"] == "cell" else {})}
             for index, (_, key, label) in enumerate(chosen)]
    session = {"id": str(uuid.uuid4()), "name": args["name"], "unit": args["unit"], "seed": args["seed"],
               "target": args.get("target", "plane"),
               "selection": {"target": args.get("target", "plane"),
                             **{key: copy.deepcopy(args[key]) for key in ("channel", "timeIndices") if key in args}},
               "populationSize": count, "sampleSize": len(items), "acceptedOnly": accepted_only,
               "blinded": args.get("blinded", True), "requiredReviews": args["requiredReviews"],
               "reviewers": copy.deepcopy(reviewers), "createdAt": utc_now(), "createdRevision": revision,
               "createdBy": copy.deepcopy(actor), "sampling": {
                   "method": "sha256-ranked-simple-random-sample-without-replacement",
                   "version": 1, "populationFingerprint": population.hexdigest()},
               "targets": [selected_targets[key] for key in sorted(target_keys)], "items": items, "events": []}
    session["snapshotHash"] = _digest({key: session[key] for key in ("sampling", "targets", "items")})
    sessions.append(session)
    return {"session": describe(document, session)}


def _session(document, session_id):
    session = next((item for item in document.get("reviewSessions", []) if item["id"] == session_id), None)
    if session is None:
        fail("review-session-not-found", "The selected review session does not exist.")
    if session["snapshotHash"] != _digest({key: session[key] for key in ("sampling", "targets", "items")}):
        fail("review-snapshot-changed", "The immutable review population snapshot has changed.")
    return session


def _item(session, item_id):
    item = next((item for item in session["items"] if item["id"] == item_id), None)
    if item is None:
        fail("review-item-not-found", "The item is not part of this review session.")
    target = next(target for target in session["targets"] if target["id"] == item["targetId"])
    return item, target


def _reviewer(session, reviewer_id):
    reviewer = next((value for value in session["reviewers"] if value["id"] == reviewer_id), None)
    if reviewer is None:
        fail("reviewer-not-found", "Select one of this session's declared reviewer identities.")
    return reviewer


def _decisions(session, item_id):
    latest = {}
    for event in session["events"]:
        if event.get("itemId") == item_id and event["type"] == "decision":
            latest[event["reviewer"]["id"]] = event
    return latest


def _adjudication(session, item_id, decisions):
    expected = sorted(item["id"] for item in decisions.values())
    for event in reversed(session["events"]):
        if event.get("itemId") == item_id and event["type"] == "adjudication":
            return event if sorted(event["decisionIds"]) == expected else None
    return None


def _context(document, session):
    decisions, adjudications = {}, {}
    for event in session["events"]:
        if event["type"] == "decision":
            decisions.setdefault(event["itemId"], {})[event["reviewer"]["id"]] = event
        elif event["type"] == "adjudication":
            adjudications[event["itemId"]] = event
    for item_id, adjudication in list(adjudications.items()):
        if sorted(adjudication["decisionIds"]) != sorted(value["id"] for value in decisions.get(item_id, {}).values()):
            del adjudications[item_id]
    images = image_index(document)
    return {"decisions": decisions, "adjudications": adjudications,
            "current": {target["id"]: _current(document, target, images) for target in session["targets"]}}


def _state(session, item, target, document, context=None):
    decisions = context["decisions"].get(item["id"], {}) if context else _decisions(session, item["id"])
    adjudication = context["adjudications"].get(item["id"]) if context else _adjudication(session, item["id"], decisions)
    values = {entry["decision"] for entry in decisions.values()}
    decision = None
    if adjudication:
        status, decision = "adjudicated", adjudication["decision"]
    elif len(decisions) < session["requiredReviews"]:
        status = "pending" if not decisions else "in-review"
    elif len(values - {"uncertain"}) > 1:
        status = "conflict"
    elif "uncertain" in values:
        status = "uncertain"
    else:
        decision = next(iter(values))
        status = "accepted" if decision == "accept" else "rejected"
    return {"id": item["id"], "code": item["code"], "unit": session["unit"], "status": status,
            "reviewCount": len(decisions), "requiredReviews": session["requiredReviews"],
            "stale": not (context["current"][target["id"]] if context else _current(document, target)),
            **({"decision": decision} if decision else {})}


def _item_view(session, item, target, document, reviewer_id=None, context=None):
    state = _state(session, item, target, document, context)
    decisions = context["decisions"].get(item["id"], {}) if context else _decisions(session, item["id"])
    own = decisions.get(reviewer_id)
    blinded = session["blinded"] and not session.get("revealedAt")
    if own:
        state["ownDecision"] = copy.deepcopy(own)
    if not blinded or own:
        state["decisions"] = [copy.deepcopy(value) for value in decisions.values()]
        adjudication = context["adjudications"].get(item["id"]) if context else _adjudication(session, item["id"], decisions)
        if adjudication:
            state["adjudication"] = copy.deepcopy(adjudication)
    if blinded and not own:
        # Completion/disagreement categories themselves can reveal another
        # reviewer's judgment, so blind queues show only personal progress.
        state["status"] = "pending"
        state.pop("decision", None)
    if not blinded:
        state.update({"imageId": target["imageId"], "imageName": target["imageName"],
                      "selection": copy.deepcopy(target["selection"]),
                      **({"labelId": item["labelId"]} if "labelId" in item else {})})
    return state


def describe(document, session, detail=False, reviewer_id=None, disclose_outcomes=False):
    if reviewer_id is not None:
        _reviewer(session, reviewer_id)
    targets = {target["id"]: target for target in session["targets"]}
    context = _context(document, session)
    states = [_state(session, item, targets[item["targetId"]], document, context) for item in session["items"]]
    progress = {"total": len(states), "reviewed": sum(item["reviewCount"] > 0 for item in states),
                "resolved": sum("decision" in item for item in states),
                "accepted": sum(item.get("decision") == "accept" for item in states),
                "rejected": sum(item.get("decision") == "reject" for item in states),
                "conflicts": sum(item["status"] == "conflict" for item in states),
                "uncertain": sum(item["status"] == "uncertain" for item in states),
                "stale": sum(item["stale"] for item in states)}
    result = {key: copy.deepcopy(session[key]) for key in (
        "id", "name", "unit", "seed", "populationSize", "sampleSize", "acceptedOnly",
        "requiredReviews", "reviewers", "createdAt", "createdRevision", "sampling", "target", "selection")}
    result.update({"blinded": bool(session["blinded"] and not session.get("revealedAt")), "progress": progress,
                   "identityAssurance": "declared-local-identities; no authentication",
                   "blindingScope": "review-presentation; project owners and exports retain source identities"})
    if result["blinded"] and not disclose_outcomes:
        for key in ("accepted", "rejected", "conflicts", "uncertain"):
            result["progress"][key] = None
        result["outcomesHidden"] = True
    if detail:
        result["items"] = [_item_view(session, item, targets[item["targetId"]], document, reviewer_id, context)
                           for item in session["items"]]
        if not result["blinded"]:
            result["events"] = copy.deepcopy(session["events"])
    return result


def _event(document, session, args, revision, actor, adjudicate=False):
    from _workbench_store import utc_now
    if len(session["events"]) >= MAX_EVENTS:
        fail("review-limit", "The session has reached 10,000 retained evidence events.")
    item, target = _item(session, args["itemId"])
    if not _current(document, target):
        fail("stale-review-input", "The current analysis changed after sampling. Start a new sample to judge the corrected result.")
    decisions = _decisions(session, item["id"])
    event = {"id": str(uuid.uuid4()), "type": "adjudication" if adjudicate else "decision",
             "itemId": item["id"], "decision": args["decision"], "reason": args.get("reason"),
             "at": utc_now(), "revision": revision, "actor": copy.deepcopy(actor),
             "fingerprint": target["fingerprint"],
             "analysisRevision": target["analysis"]["analysisRevision"]}
    reviewer_id = None
    if adjudicate:
        if len(decisions) < session["requiredReviews"]:
            fail("independent-reviews-required", "Complete the required distinct declared reviews before adjudication.")
        event["decisionIds"] = sorted(value["id"] for value in decisions.values())
    else:
        reviewer_id = args["reviewerId"]
        event["reviewer"] = copy.deepcopy(_reviewer(session, reviewer_id))
        event["presentationBlinded"] = bool(session["blinded"] and not session.get("revealedAt")
                                           and reviewer_id not in decisions)
        event["priorResponsesAvailable"] = bool(not session["blinded"] or session.get("revealedAt")
                                                or reviewer_id in decisions)
        event["errorType"] = args.get("errorType", "none" if args["decision"] == "accept" else "other")
        if args["decision"] == "accept" and event["errorType"] != "none":
            fail("invalid-review-decision", "Accepted decisions must use errorType 'none'.")
        if args["decision"] != "accept" and not args.get("reason"):
            fail("review-reason-required", "Record a reason for a rejected or uncertain decision.")
        if reviewer_id in decisions:
            event["supersedes"] = decisions[reviewer_id]["id"]
    session["events"].append(event)
    state = _state(session, item, target, document)
    queue_state = ("needs-review" if state.get("decision") == "reject" or state["status"] in ("conflict", "uncertain")
                   else "accepted" if session["unit"] == "image" and state.get("decision") == "accept" else None)
    if queue_state:
        flags = document.setdefault("reviewFlags", [])
        if len(flags) >= MAX_FLAGS:
            fail("review-limit", "The project has reached its retained classification event limit.")
        flags.append({"id": str(uuid.uuid4()), "targetId": target["id"], "imageId": target["imageId"],
                      "selection": copy.deepcopy(target["selection"]), "state": queue_state,
                      "reason": "Review consensus or adjudication", "fingerprint": target["fingerprint"],
                      "analysisRevision": target["analysis"]["analysisRevision"], "revision": revision,
                      "at": event["at"], "actor": copy.deepcopy(actor),
                      "sessionId": session["id"], "itemId": item["id"], "eventId": event["id"]})
    if adjudicate:
        return {"sessionId": session["id"], "item": {
            **_state(session, item, target, document), "adjudication": copy.deepcopy(event),
            "decisions": [copy.deepcopy(value) for value in decisions.values()]}}
    return {"sessionId": session["id"], "item": _item_view(session, item, target, document, reviewer_id)}


def _preview(store, document, session, args):
    from _workbench_core import _source, _labels
    import _workbench_volume as volume
    import _workbench_imaging as imaging
    np, = imaging.require("numpy")
    item, target = _item(session, args["itemId"])
    image, analysis = target["image"], target["analysis"]
    selection = target["selection"]
    plane_name = args.get("plane", "xy")
    if selection["target"] == "plane":
        if "plane" in args or "index" in args:
            fail("invalid-selection", "A plane review item does not have orthogonal slice coordinates.")
        raw = _source(store, image, analysis["parameters"])
        labels = _labels(store, image, analysis)
        plane_index = None
    else:
        raw = volume.load_source(store, image, selection["timeIndex"], selection["channel"])
        labels = volume.read_labels(store, image, analysis)
        axis = {"xy": 0, "xz": 1, "yz": 2}[plane_name]
        if "index" in args:
            plane_index = args["index"]
        elif "labelId" in item:
            coordinates = np.argwhere(labels == item["labelId"])
            plane_index = int(np.median(coordinates[:, axis])) if coordinates.size else raw.shape[axis] // 2
        else:
            plane_index = raw.shape[axis] // 2
        if plane_index >= raw.shape[axis]:
            fail("invalid-selection", "The slice index is outside the frozen source volume.")
        slice_count = raw.shape[axis]
        raw = np.take(raw, plane_index, axis=axis)
        labels = np.take(labels, plane_index, axis=axis)
    height, width = raw.shape
    x, y, w, h = 0, 0, width, height
    if "labelId" in item:
        coordinates = np.argwhere(labels == item["labelId"])
        labels = np.where(labels == item["labelId"], labels, 0).astype(np.uint32)
        if coordinates.size:
            y0, x0 = coordinates.min(axis=0)
            y1, x1 = coordinates.max(axis=0) + 1
            margin = max(12, int(max(x1 - x0, y1 - y0) * .5))
            x, y = max(0, int(x0) - margin), max(0, int(y0) - margin)
            w, h = min(width, int(x1) + margin) - x, min(height, int(y1) + margin) - y
            raw, labels = raw[y:y+h, x:x+w], labels[y:y+h, x:x+w]
    maximum = args.get("maxSize", 768)
    return {"sessionId": session["id"], "itemId": item["id"], "code": item["code"],
            **imaging.preview_data(raw, max_size=maximum),
            "overlayDataUrl": imaging.preview_data(raw, labels, max_size=maximum)["dataUrl"],
            "region": {"x": x, "y": y, "width": w, "height": h},
            "stale": not _current(document, target),
            **({"plane": plane_name, "index": plane_index, "sliceCount": slice_count}
               if plane_index is not None else {})}


def _wilson(rejected, count):
    if not count:
        return None
    z = 1.959963984540054
    proportion = rejected / count
    denominator = 1 + z*z/count
    midpoint = (proportion + z*z/(2*count)) / denominator
    half = z * math.sqrt(proportion*(1-proportion)/count + z*z/(4*count*count)) / denominator
    return [max(0, midpoint-half), min(1, midpoint+half)]


def summary(document, session_id=None):
    output = []
    sessions = [_session(document, session_id)] if session_id else document.get("reviewSessions", [])
    for session in sessions:
        described = describe(document, session, disclose_outcomes=True)
        counts = described["progress"]
        targets = {target["id"]: target for target in session["targets"]}
        context = _context(document, session)
        current_resolved, current_rejected = 0, 0
        comparisons, agreements = 0, 0
        for item in session["items"]:
            state = _state(session, item, targets[item["targetId"]], document, context)
            if "decision" in state and not state["stale"]:
                current_resolved += 1
                current_rejected += state["decision"] == "reject"
            if not state["stale"]:
                for left, right in itertools.combinations(context["decisions"].get(item["id"], {}).values(), 2):
                    comparisons += 1
                    agreements += left["decision"] == right["decision"]
        output.append({"sessionId": session["id"], "name": session["name"], "unit": session["unit"],
                       "populationSize": session["populationSize"], "sampleSize": session["sampleSize"],
                       **counts,
                       "rejection": {"resolvedCount": current_resolved, "rejectedCount": current_rejected,
                                     "fraction": current_rejected/current_resolved if current_resolved else None,
                                     "confidence95Wilson": _wilson(current_rejected, current_resolved),
                                     "completeSample": current_resolved == session["sampleSize"]},
                       "agreement": {"pairedComparisons": comparisons, "agreements": agreements,
                                     "fraction": agreements/comparisons if comparisons else None,
                                     "basis": "latest declared responses; revised decisions may follow exposure"},
                       "notes": [
                           "Only decisions on current inputs enter rejection and agreement summaries.",
                           "The Wilson interval is an approximate descriptive interval over resolved sampled units; unresolved items can bias it.",
                           "Declared reviewer identities are recorded locally and are not authenticated.",
                           "Detected-cell sampling cannot estimate the number of cells missed by every detector.",
                           "Image, time-frame and detected-cell units are not biological replicates.",
                       ]})
        if session["blinded"] and not session.get("revealedAt"):
            result = output[-1]
            result["outcomesHidden"] = True
            for key in ("accepted", "rejected", "conflicts", "uncertain"):
                result[key] = None
            for key in ("rejectedCount", "fraction", "confidence95Wilson"):
                result["rejection"][key] = None
            for key in ("agreements", "fraction"):
                result["agreement"][key] = None
            result["notes"].append("Use the explicit recorded reveal operation to view aggregate outcomes.")
    return {"sessions": output, "sourceRevision": document["revision"]}


def artifact_references(document):
    import _workbench_support as support
    references = {}
    for session in document.get("reviewSessions", []):
        for target in session["targets"]:
            references[target["image"]["sourcePath"]] = target["image"]["sourceHash"]
            references[target["analysis"]["labelsPath"]] = target["analysis"]["labelsHash"]
            if support.descriptor(target["image"]):
                value = support.descriptor(target["image"])
                references[value["path"]] = value["hash"]
    return references


def execute(store, document, operation, args, revision, actor):
    if operation == "review.flag":
        return _flag(store, document, args, revision, actor)
    if operation == "review.session.create":
        return _create(store, document, args, revision, actor)
    if operation == "review.session.list":
        return {"sessions": [describe(document, session) for session in document.get("reviewSessions", [])]}
    if operation == "review.summary":
        return summary(document, args.get("sessionId"))
    session = _session(document, args["sessionId"])
    if operation == "review.session.get":
        return {"session": describe(document, session, True, args.get("reviewerId"))}
    if operation == "review.item.preview":
        return _preview(store, document, session, args)
    if operation in ("review.decision", "review.adjudicate"):
        return _event(document, session, args, revision, actor, operation == "review.adjudicate")
    if operation == "review.reveal":
        from _workbench_store import utc_now
        if len(session["events"]) >= MAX_EVENTS:
            fail("review-limit", "The session has reached its retained evidence event limit.")
        if not session.get("revealedAt"):
            session["revealedAt"] = utc_now()
            session["events"].append({"id": str(uuid.uuid4()), "type": "reveal", "at": session["revealedAt"],
                                      "revision": revision, "reason": args["reason"], "actor": copy.deepcopy(actor)})
        return {"session": describe(document, session, True)}
    fail("unknown-operation", "Unsupported review operation.")
