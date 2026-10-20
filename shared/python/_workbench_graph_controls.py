"""Artifact-bound review gates and correction continuation for canonical DAG jobs."""
from __future__ import annotations

from _workbench_indexed import image_capacity

from _workbench_indexed import image_index
import copy
import uuid


def operations():
    from _workbench_schema import _op, _object, _ID, _STRING
    key = {"jobId": _ID, "checkpointIndex": {"type": "integer", "minimum": 0, "maximum": 4999}, "nodeId": _ID}
    bound = {**key, "inputFingerprint": _ID, "reason": {"type": "string", "minLength": 1, "maxLength": 2000}}
    continuation = {"jobId": _ID, "checkpointIndex": key["checkpointIndex"],
                    "corrections": {"type": "array", "minItems": 1, "maxItems": 8,
                                    "items": _object({"nodeId": _ID, "imageId": _ID}, ["nodeId", "imageId"])},
                    "exportDestination": _STRING}
    return [
        _op("job.graph.review.get", "Read a pending artifact-bound gate, retained recommendations and decisions.", _object(key, list(key))),
        _op("job.graph.review.recommend", "Retain an agent or reviewer recommendation without completing a review gate.",
            _object({**bound, "recommendation": {"type": "string", "enum": ["approve", "revise", "reject"]}}, list(bound) + ["recommendation"]), True),
        _op("job.graph.review.decide", "Record a self-declared reviewer decision against exact retained input artifacts.",
            _object({**bound, "decision": {"type": "string", "enum": ["approve", "reject"]},
                     "reviewerKind": {"type": "string", "enum": ["human", "agent"]}}, list(bound) + ["decision", "reviewerKind"]), True),
        _op("job.graph.continue.preview", "Plan a new DAG job from exact corrected branch masks and still-current immutable ancestors.",
            _object(continuation, ["jobId", "checkpointIndex", "corrections"])),
        _op("job.graph.continue.run", "Create an independent corrected continuation without rewriting historical checkpoints or resegmenting corrected masks.",
            _object({**continuation, "previewFingerprint": _ID}, ["jobId", "checkpointIndex", "corrections", "previewFingerprint"]), True),
    ]


def _lookup(document, args):
    import _workbench_graphs as graphs
    from _workbench_workflows import get_job
    job = get_job(document, args["jobId"])
    if job.get("kind") != "dag" or args["checkpointIndex"] >= len(job["checkpoints"]):
        graphs.fail("graph-checkpoint-not-found", "Select a retained graph source/time checkpoint.")
    checkpoint = job["checkpoints"][args["checkpointIndex"]]
    return job, checkpoint


def _gate(document, args):
    import _workbench_graphs as graphs
    job, checkpoint = _lookup(document, args)
    node = next((node for node in graphs.scientific_nodes(job["workflow"]) if node["id"] == args["nodeId"]), None)
    saved = next((row for row in checkpoint["nodes"] if row["nodeId"] == args["nodeId"]), None)
    if node is None or node["type"] != "review" or saved is None or not saved.get("review"):
        graphs.fail("review-not-ready", "Advance this source/time checkpoint to its review gate first.", args["nodeId"])
    return job, checkpoint, node, saved


def review_descriptor(document, job, checkpoint_index, node, saved):
    import _workbench_graphs as graphs
    from _workbench_workflows import _image
    record = saved["review"]
    try:
        current = graphs.binding(_image(document, record["inputBinding"]["imageId"]), record["inputBinding"]["selection"], True) == record["inputBinding"]
    except Exception:
        current = False
    return {"jobId": job["id"], "checkpointIndex": checkpoint_index, "nodeId": node["id"],
            "prompt": node.get("prompt", "Review the exact saved mask before continuing."), "requireHuman": node.get("requireHuman", True),
            "inputBinding": copy.deepcopy(record["inputBinding"]), "inputFingerprint": record["inputFingerprint"],
            "inputsCurrent": current, "recommendations": copy.deepcopy(record.get("recommendations", [])),
            "decisions": copy.deepcopy(record.get("decisions", [])),
            "decision": copy.deepcopy(record.get("decisions", [None])[-1]) if record.get("decisions") else None,
            "nextActions": (["recommend", "decide", "continue-with-corrections"] if current and saved["status"] == "awaiting-review" else
                            ["continue-with-corrections"] if not current else []),
            "identityNote": "Actor and reviewer roles are self-declared records, not authenticated identity or independent verification."}


def pending_review(document, job):
    for index, checkpoint in enumerate(job["checkpoints"]):
        for saved in checkpoint["nodes"]:
            if saved["status"] == "awaiting-review":
                node = next(node for node in job["workflow"]["graph"]["nodes"] if node["id"] == saved["nodeId"])
                return review_descriptor(document, job, index, node, saved)
    return None


def enter_review(job, checkpoint, node, saved, incoming, revision):
    from _workbench_graphs import digest
    from _workbench_store import utc_now
    if not saved.get("review"):
        saved["review"] = {"inputBinding": copy.deepcopy(incoming), "inputFingerprint": digest(incoming),
                           "recommendations": [], "decisions": [], "openedRevision": revision, "openedAt": utc_now()}
    saved["status"] = "awaiting-review"
    checkpoint["status"] = "awaiting-review"
    job["status"] = "awaiting-review"


def execute_review(document, operation, args, revision, actor):
    import _workbench_graphs as graphs
    from _workbench_store import utc_now
    job, checkpoint, node, saved = _gate(document, args)
    result = review_descriptor(document, job, args["checkpointIndex"], node, saved)
    if operation.endswith(".get"):
        return {"review": result}
    if job["status"] not in ("awaiting-review", "blocked") or saved["status"] != "awaiting-review":
        graphs.fail("review-closed", "This gate is no longer awaiting a decision. Its historical evidence remains immutable.", node["id"])
    if not result["inputsCurrent"] or args["inputFingerprint"] != result["inputFingerprint"]:
        graphs.fail("stale-review-input", "The mask/source binding changed. Create a corrected continuation and review its new gate.", node["id"])
    total = sum(len(row.get("review", {}).get("recommendations", [])) + len(row.get("review", {}).get("decisions", []))
                for item in document.get("jobs", []) if item.get("kind") == "dag" for point in item["checkpoints"] for row in point["nodes"])
    if total >= 5000:
        graphs.fail("review-history-limit", "This project retains at most 5,000 graph recommendations and decisions.")
    record = {"id": str(uuid.uuid4()), "actor": copy.deepcopy(actor), "reason": args["reason"], "at": utc_now(),
              "revision": revision, "inputFingerprint": result["inputFingerprint"]}
    if operation.endswith(".recommend"):
        record["recommendation"] = args["recommendation"]
        saved["review"]["recommendations"].append(record)
    else:
        if node.get("requireHuman", True) and args["reviewerKind"] != "human":
            graphs.fail("human-review-required", "This gate requires a human-labelled decision. Agent recommendations remain separate.", node["id"])
        if args["reviewerKind"] == "human" and actor["kind"] in ("agent", "mcp"):
            graphs.fail("reviewer-role-mismatch", "An agent-labelled actor cannot record itself as a human reviewer; record a recommendation instead.", node["id"])
        graphs.check_inputs(document, job)
        record.update({"decision": args["decision"], "reviewerKind": args["reviewerKind"]})
        saved["review"]["decisions"].append(record)
        if args["decision"] == "approve":
            saved.update({"status": "completed", "inputBinding": copy.deepcopy(result["inputBinding"]),
                          "outputBinding": copy.deepcopy(result["inputBinding"]), "completedRevision": revision, "completedAt": record["at"],
                          "stepResults": [{"type": "review", "nodeId": node["id"], "decisionId": record["id"], "completedRevision": revision}]})
            checkpoint["status"] = "completed" if all(row["status"] == "completed" for row in checkpoint["nodes"]) else "running"
            job["status"] = "running"
            job.pop("error", None)
        else:
            job["status"] = "blocked"
            job["error"] = {"code": "review-rejected", "message": "Review rejected this exact mask. Correct it and create a continuation, or retain a subsequent explicit review decision.", "nodeId": node["id"]}
    job["updatedAt"] = utc_now()
    return {"review": review_descriptor(document, job, args["checkpointIndex"], node, saved), "job": graphs.describe(job, document)}


def compatible(left, right, *, ignore_channel=True):
    """A coordinate/support identity comparison, never a dimension-only match."""
    keys = ("sourceHash", "sourceFingerprint", "derivationHash", "supportHash")
    if ignore_channel:
        # Source fingerprints include the display/analysis channel. Explicitly
        # compare acquisition identity/calibration in paired_images instead.
        keys = ("sourceHash", "derivationHash", "supportHash")
    return all(left.get(key) == right.get(key) for key in keys) and all(
        left["selection"].get(key) == right["selection"].get(key) for key in ("target", "timeIndex", "zProjection"))


def paired_images(document, left, right):
    import _workbench_graphs as graphs
    from _workbench_workflows import _image
    from _workbench_recompute import grid_identity
    images = image_index(document)
    first, second = (_image(document, item["imageId"]) for item in (left, right))
    if (not compatible(left, right) or graphs.digest(grid_identity(first, images)) != graphs.digest(grid_identity(second, images)) or
            any(first.get(key) != second.get(key) for key in ("axes", "shape", "pxPerUm", "voxelSizeUm", "timeStepSeconds"))):
        graphs.fail("graph-grid-mismatch", "Paired masks require the same acquisition ancestry, source bytes, grid, calibration, projection/time and valid support.")
    return first, second


def merge_masks(store, document, node, incoming, secondary, revision, hooks):
    import numpy as np
    from scipy import ndimage
    import _workbench_graphs as graphs
    import _workbench_volume as volume
    import _workbench_variants as variants
    left, right = paired_images(document, incoming, secondary)
    selected = incoming["selection"]
    if selected["target"] == "volume":
        first_frame = volume.current_frame(store, left, selected["timeIndex"], selected["channel"])
        other = secondary["selection"]
        second_frame = volume.current_frame(store, right, other["timeIndex"], other["channel"])
        labels = volume.read_labels(store, left, first_frame)
        other_labels = volume.read_labels(store, right, second_frame)
    else:
        first_frame = hooks["current_analysis"](store, left)
        second_frame = hooks["current_analysis"](store, right)
        labels = hooks["labels"](store, left, first_frame)
        other_labels = hooks["labels"](store, right, second_frame)
    foreground = (labels > 0) | (other_labels > 0) if node["mode"] == "union" else (labels > 0) & (other_labels > 0)
    structure = ndimage.generate_binary_structure(labels.ndim, labels.ndim if node["connectivity"] == "full" else 1)
    merged, count = ndimage.label(foreground, structure=structure, output=np.uint32)
    if count > 20000:
        graphs.fail("too-many-objects", "Merged connected components exceed the canonical 20,000-object bound.", node["id"])
    created = variants.execute(store, document, {"imageId": left["id"], "name": (left["name"][:95] + " · " + node.get("name", node["id"]))[:200], "copyAnalysis": False}, revision, hooks)
    image = hooks["image"](document, created["imageId"])
    provenance = {"mode": node["mode"], "connectivity": node["connectivity"], "inputs": [copy.deepcopy(incoming), copy.deepcopy(secondary)],
                  "identityPolicy": "New connected-component IDs; no review, tracking, or lineage decisions transferred."}
    image["maskMergeOrigin"] = provenance
    if selected["target"] == "volume":
        raw = volume.load_source(store, image, selected["timeIndex"], selected["channel"])
        volume.save_frame(store, image, raw, merged, first_frame["parameters"], selected["timeIndex"], selected["channel"], revision,
                          {"maskMerge": provenance}, undo=False)
    else:
        raw = hooks["source"](store, image, first_frame["parameters"])
        hooks["set_analysis"](store, image, merged, raw, first_frame["parameters"], revision, {"maskMerge": provenance})
    return image, {"cellCount": int(count), "merge": provenance}


def continuation_preview(store, document, args):
    import _workbench_graphs as graphs
    from _workbench_workflows import _image
    job, checkpoint = _lookup(document, args)
    if len(document.get("jobs", [])) >= 1000:
        graphs.fail("project-too-large", "A project retains at most 1,000 jobs.")
    nodes = graphs.scientific_nodes(job["workflow"])
    definitions = {node["id"]: node for node in nodes}
    saved = {node["nodeId"]: node for node in checkpoint["nodes"]}
    corrections = {}
    for correction in args["corrections"]:
        identifier = correction["nodeId"]
        node = definitions.get(identifier)
        old = saved.get(identifier)
        if identifier in corrections or node is None or node["type"] not in graphs.SEGMENTATION | {"mask-merge"} or old["status"] != "completed":
            graphs.fail("invalid-correction-node", "Select each completed segmentation/merge branch once.", identifier)
        image = _image(document, correction["imageId"])
        current = graphs.binding(image, old["outputBinding"]["selection"], True)
        paired_images(document, old["outputBinding"], current)
        if not compatible(old["outputBinding"], current, ignore_channel=False):
            graphs.fail("correction-source-changed", "A corrected continuation must preserve the exact source, calibration, support and selected channel/time; only masks may change.", identifier)
        for prefix in ("source", "labels", "support"):
            if current.get(prefix + "Path"): store.verify_artifact(current[prefix + "Path"], current[prefix + "Hash"])
        corrections[identifier] = {**correction, "inputBinding": current}
    source = _image(document, checkpoint["imageId"])
    from _workbench_preprocessing import _source_fingerprint
    if _source_fingerprint(source, checkpoint["sourceSelection"]) != checkpoint["sourceFingerprint"]:
        graphs.fail("continuation-source-changed", "The original acquisition selection changed. Save a new ordinary job for changed source inputs.")
    reused, reset, available = [], [], {graphs.SOURCE}
    altered = set()
    for node in nodes:
        identifier = node["id"]
        old = saved[identifier]
        parents = graphs.parents(node)
        if identifier in corrections:
            if any(parent not in available or parent in altered for parent in parents):
                graphs.fail("correction-ancestor-unavailable", "A corrected branch needs unchanged reusable ancestors; select the first corrected node on each branch.", identifier)
            available.add(identifier); altered.add(identifier)
            continue
        parent_ready = all(parent in available for parent in parents)
        current = old["status"] == "completed" and parent_ready and not any(parent in altered for parent in parents)
        if current:
            for field in ("inputBinding", "outputBinding"):
                bound = old[field]
                try:
                    current = current and graphs.binding(_image(document, bound["imageId"]), bound["selection"], bound["analyzed"]) == bound
                except Exception:
                    current = False
            from _workbench_workflows import assay_outputs_current
            from _workbench_plugins import checkpoint_outputs_current
            current = current and assay_outputs_current(document, old) and checkpoint_outputs_current(document, old)
        if current:
            reused.append(identifier); available.add(identifier)
        else:
            reset.append(identifier); altered.add(identifier)
    # Every corrected branch is preserved, other pending science uses the same engine.
    new_images = len(corrections) + sum(definitions[identifier]["type"] in graphs.SEGMENTATION | {"preprocessing", "mask-merge"} for identifier in reset)
    if len(document["images"]) + new_images > image_capacity(document):
        graphs.fail("project-too-large", "The corrected continuation would exceed the 1,000-acquisition bound.")
    export = next((node for node in job["workflow"]["graph"]["nodes"] if node["type"] == "export"), None)
    if export:
        from _workbench_schema import absolute_path
        if not args.get("exportDestination"):
            graphs.fail("export-destination-required", "Choose a new exportDestination for this corrected continuation.")
        path = absolute_path(args["exportDestination"], "exportDestination")
        if path.suffix.lower() != ".zip" or not path.parent.is_dir() or path.exists():
            graphs.fail("invalid-path", "The continuation export needs a new .zip destination in an existing directory.")
    elif args.get("exportDestination"):
        graphs.fail("invalid-arguments", "This graph has no export node.")
    plan = {"sourceJobId": job["id"], "checkpointIndex": args["checkpointIndex"], "sourceImageId": checkpoint["imageId"],
            "sourceSelection": copy.deepcopy(checkpoint["sourceSelection"]), "corrections": list(corrections.values()),
            "reusedNodeIds": reused, "resetNodeIds": reset, "newImageCount": new_images,
            "notes": ["One new source/time job is created. Original checkpoints and review decisions remain historical.",
                      "Corrected masks are copied exactly into independent branches. Descendant analyses and gates run anew; biological assignments are not copied."]}
    fingerprint = graphs.digest({"plan": plan, "definitionHash": job["definitionHash"], "checkpoint": checkpoint,
                                 "exportDestination": args.get("exportDestination")})
    return {"plan": plan, "previewFingerprint": fingerprint}


def continue_job(store, document, args, revision, actor):
    import _workbench_graphs as graphs
    import _workbench_core as core
    import _workbench_variants as variants
    from _workbench_store import utc_now
    response = continuation_preview(store, document, args)
    if args["previewFingerprint"] != response["previewFingerprint"]:
        graphs.fail("stale-continuation-preview", "Inputs or branch evidence changed. Preview the corrected continuation again.")
    previous, original = _lookup(document, args)
    plan = response["plan"]
    workflow = copy.deepcopy(previous["workflow"])
    if args.get("exportDestination"):
        next(node for node in workflow["graph"]["nodes"] if node["type"] == "export")["destination"] = args["exportDestination"]
        workflow["steps"] = [graphs.step_of(node) for node in workflow["graph"]["nodes"]]
    checkpoint = {key: copy.deepcopy(value) for key, value in original.items() if key not in ("nodes", "status")}
    checkpoint.update({"status": "pending", "nodes": []})
    corrected = {row["nodeId"]: row for row in plan["corrections"]}
    job = {"id": str(uuid.uuid4()), "kind": "dag", "name": previous["name"][:170] + " · corrected",
           "workflow": workflow, "definitionHash": graphs.digest(workflow), "imageIds": [original["imageId"]],
           "checkpoints": [checkpoint], "status": "pending", "createdAt": utc_now(), "updatedAt": utc_now(), "createdRevision": revision,
           "continuation": {"sourceJobId": previous["id"], "checkpointIndex": args["checkpointIndex"],
                            "corrections": copy.deepcopy(plan["corrections"]), "reusedNodeIds": list(plan["reusedNodeIds"]),
                            "actor": copy.deepcopy(actor), "reason": "Explicit correction continuation of exact retained branch masks."}}
    for old in original["nodes"]:
        identifier = old["nodeId"]
        if identifier in corrected:
            bound = corrected[identifier]["inputBinding"]
            created = variants.execute(store, document, {"imageId": bound["imageId"], "copyAnalysis": False}, revision,
                                       {"image": core._image, "current_analysis": core._current_analysis})
            image = core._image(document, created["imageId"])
            source = core._image(document, bound["imageId"])
            if bound["selection"]["target"] == "volume":
                import _workbench_volume as volume
                selected = bound["selection"]
                original_analysis = volume.current_frame(store, source, selected["timeIndex"], selected["channel"])
                copied = copy.deepcopy(original_analysis)
                copied.update({"analysisRevision": revision, "measurementRevision": revision, "undoStack": [],
                               "copiedFrom": {"imageId": source["id"], "analysisRevision": original_analysis["analysisRevision"]}})
                image["volumeFrames"] = [copied]
            else:
                original_analysis = core._current_analysis(store, source)
                copied = copy.deepcopy(original_analysis)
                copied.update({"analysisRevision": revision, "measurementRevision": revision,
                               "copiedFrom": {"imageId": source["id"], "analysisRevision": original_analysis["analysisRevision"]}})
                image["analysis"] = copied
            image["variantCopiedAnalysis"] = True
            image["workflowBranch"] = {"jobId": job["id"], "nodeId": identifier, "sourceImageId": checkpoint["imageId"], "sourceSelection": checkpoint["sourceSelection"]}
            item = {"nodeId": identifier, "status": "completed", "inputBinding": copy.deepcopy(old["inputBinding"]),
                    "outputBinding": graphs.binding(image, bound["selection"], True), "completedRevision": revision, "completedAt": utc_now(),
                    "correctionOrigin": {"sourceJobId": previous["id"], "checkpointIndex": args["checkpointIndex"], "nodeId": identifier,
                                         "correctedInputBinding": copy.deepcopy(bound), "previousOutputBinding": copy.deepcopy(old["outputBinding"])},
                    "stepResults": [{"type": "corrected-mask", "nodeId": identifier, "completedRevision": revision}]}
            if old.get("secondaryInputBindings"): item["secondaryInputBindings"] = copy.deepcopy(old["secondaryInputBindings"])
        elif identifier in plan["reusedNodeIds"]:
            item = copy.deepcopy(old)
            item["reusedFrom"] = {"jobId": previous["id"], "checkpointIndex": args["checkpointIndex"], "nodeId": identifier}
        else:
            item = {"nodeId": identifier, "status": "pending"}
        checkpoint["nodes"].append(item)
    document.setdefault("jobs", []).append(job)
    return {"job": graphs.describe(job, document)}
