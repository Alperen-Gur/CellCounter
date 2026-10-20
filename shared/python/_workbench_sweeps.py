"""Bounded parameter combinations expressed as ordinary workflows and jobs."""
from __future__ import annotations

from _workbench_indexed import base_metadata_bytes, CombinedRows

from _workbench_indexed import image_capacity

from _workbench_indexed import image_index

import copy
import itertools
import math
from pathlib import Path
import uuid

MAX_AXES = 6
MAX_VALUES = 16
MAX_COMBINATIONS = 64
MAX_SWEEPS = 128
MAX_CHECKPOINTS = 5000
MAX_PLAN_BYTES = 8 * 1024 ** 2


def limits():
    return {"axes": MAX_AXES, "valuesPerAxis": MAX_VALUES, "combinations": MAX_COMBINATIONS,
            "sweeps": MAX_SWEEPS, "projectImages": 1000, "projectJobs": 1000,
            "checkpoints": MAX_CHECKPOINTS, "planBytes": MAX_PLAN_BYTES}


def notes():
    return [
        "Combinations are analysis variants of the same acquisitions, not independent biological replicates.",
        "Each combination starts with independent empty masks; specimen, well, review and adaptation assignments are not copied.",
        "Null omits an optional parameter before the ordinary workflow validator applies its defaults.",
        "Advance executes one canonical job unit. Group advancement completes scientific units before complete-project exports.",
        "sweep.worker.start continues the whole group through the same canonical checkpoints; job.worker.stop pauses after the current unit.",
    ]


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    selection = {"workflowId": _ID, "workflowVersion": {"type": "integer", "minimum": 1}}
    scalar = {"type": ["number", "boolean", "string", "null"], "maxLength": 4096, "minLength": 0}
    axis = _object({"stepIndex": {"type": "integer", "minimum": 0, "maximum": 19},
                    "nodeId": {"type": "string", "minLength": 1, "maxLength": 64},
                    "path": {"type": "string", "maxLength": 150},
                    "values": {"type": "array", "items": scalar, "minItems": 1, "maxItems": MAX_VALUES}},
                   ["path", "values"])
    spec = {**selection,
            "imageIds": {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000},
            "timeIndices": {"type": "array", "items": {"type": "integer", "minimum": 0},
                            "minItems": 1, "maxItems": 1000},
            "axes": {"type": "array", "items": axis, "minItems": 1, "maxItems": MAX_AXES},
            "exportDirectory": _STRING}
    return [
        _op("sweep.parameters", "Discover supported scalar parameter paths from one saved workflow and its exact model/plugin schemas.",
            _object(selection, ["workflowId"])),
        _op("sweep.preview", "Validate a bounded Cartesian parameter sweep and its acquisition/job budgets without changing the project.",
            _object(spec, ["workflowId", "imageIds", "axes"])),
        _op("sweep.create", "Retain isolated image variants, frozen concrete workflows and ordinary jobs for a parameter sweep.",
            _object({**spec, "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["workflowId", "imageIds", "axes"]), True),
        _op("sweep.get", "Inspect a sweep's frozen combinations, currentness and canonical job progress.",
            _object({"sweepId": _ID}, ["sweepId"])),
        _op("sweep.list", "List parameter sweep groups and their aggregate progress.", _object()),
        *[_op("sweep." + action, description, _object({
            "sweepId": _ID, **({"reason": {"type": "string", "minLength": 1, "maxLength": 500},
                               "controlRequestId": _ID} if action == "pause" else {})}, ["sweepId"]), True)
          for action, description in (
              ("advance", "Execute one canonical checkpoint across the sweep's remaining jobs."),
              ("pause", "Pause the sweep and its remaining runnable jobs between checkpoints."),
              ("resume", "Resume paused sweep jobs after checking retained sources and outputs."),
              ("retry", "Retry failed sweep jobs without repeating completed checkpoints."),
              ("cancel", "Cancel remaining sweep jobs while preserving completed variants and results."),
          )],
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _digest(value):
    from _workbench_workflows import _digest as digest
    return digest(value)


def _source_fingerprint(image):
    import _workbench_support as support
    return _digest({key: copy.deepcopy(image.get(key)) for key in (
        "sourceHash", "shape", "axes", "width", "height", "channels", "zCount", "timeCount",
        "pxPerUm", "voxelSizeUm", "timeStepSeconds", "derivation", "sourceRegion"
    )} | {"validSupport": support.fingerprint(image)})


def get(document, sweep_id):
    value = next((item for item in document.get("sweeps", []) if item["id"] == sweep_id), None)
    if value is None:
        fail("sweep-not-found", "This project has no sweep with the requested ID.")
    definition = {key: value[key] for key in ("baseWorkflow", "axes", "imageIds", "combinations", "sourceInputs")}
    if _digest(definition) != value["definitionHash"]:
        fail("project-corrupt", "The immutable sweep definition changed.")
    return value


def _workflow(document, args):
    from _workbench_workflows import get_workflow
    workflow = get_workflow(document, args["workflowId"], args.get("workflowVersion"))
    return workflow


def parameters(document, args):
    from _workbench_schema import _PARAMETERS
    from _workbench_volume import parameter_schema
    from _workbench_models import _model, schema_for_model
    from _workbench_plugins import _record
    from _workbench_workflows import _assay_definition
    from _workbench_preprocessing import recipe_schema, catalogue
    workflow = _workflow(document, args)
    graph = workflow.get("kind") == "dag"
    candidates = []

    def add(index, prefix, fields, current, required=()):
        for name, schema in fields.items():
            types = schema.get("type")
            if types not in ("number", "integer", "boolean", "string") and not isinstance(types, list):
                continue
            path = prefix + name
            identity = {"nodeId": index, "nodeName": node_names[index]} if graph else {"stepIndex": index}
            entry = {**identity, "path": path, "label": schema.get("title", name),
                     "schema": copy.deepcopy(schema), "present": name in current, "canOmit": name not in required}
            if name in current:
                entry["currentValue"] = copy.deepcopy(current[name])
            candidates.append(entry)

    node_names = {node["id"]: node.get("name", node["id"]) for node in workflow["graph"]["nodes"]} if graph else {}
    steps = [(node["id"], node) for node in workflow["graph"]["nodes"]] if graph else enumerate(workflow["steps"])
    for index, step in steps:
        kind = step["type"]
        if kind in ("analysis", "volume-analysis"):
            schema = _PARAMETERS if kind == "analysis" else parameter_schema()
            fields = {key: value for key, value in schema["properties"].items()
                      if not graph or key not in ("channel", "zProjection")}
            add(index, "parameters.", fields, step["parameters"], schema.get("required", []))
        if not graph and kind in ("volume-analysis", "plugin-segmentation") and "channel" in step:
            add(index, "", {"channel": {"type": "integer", "minimum": 0, "maximum": 31, "default": 0}}, step)
        if not graph and kind in ("plugin-segmentation", "model-segmentation") and "sourceParameters" in step:
            add(index, "sourceParameters.", {key: _PARAMETERS["properties"][key] for key in ("channel", "zProjection")},
                step["sourceParameters"])
        if kind == "model-segmentation":
            schema = schema_for_model(_model(document, step["modelId"]))
            add(index, "modelParameters.", schema["properties"], step["modelParameters"], schema.get("required", []))
        if kind.startswith("plugin-"):
            schema = _record(document, step["pluginId"])["manifest"]["parameters"]
            add(index, "pluginParameters.", schema["properties"], step["pluginParameters"], schema.get("required", []))
        if kind == "assay":
            schema = _assay_definition(step["assay"])["parameters"]
            # Reference identities are part of the workflow, not scalar tuning controls.
            add(index, "assayParameters.", {key: item for key, item in schema["properties"].items()
                                           if key not in ("nuclearImageId", "somaImageId")},
                step["assayParameters"], schema.get("required", []))
        if kind == "preprocessing":
            filters = {item["method"]: item for item in catalogue()["filters"]}
            schemas = recipe_schema()["items"]["properties"]
            for recipe_index, item in enumerate(step["recipe"]):
                add(index, f"recipe.{recipe_index}.",
                    {name: schemas[name] for name in filters[item["method"]]["defaults"]}, item)
    return {"workflow": {key: workflow[key] for key in ("id", "name", "version", "kind") if key in workflow},
            "candidatePaths": candidates, "limits": limits(), "notes": notes()}


def _assign(step, path, value):
    segments = path.split(".")
    parent = step
    for key in segments[:-1]:
        parent = parent[int(key)] if isinstance(parent, list) else parent[key]
    key = segments[-1]
    if value is None:
        parent.pop(key, None)
    else:
        parent[key] = value


def preview(document, args):
    from _workbench_schema import absolute_path
    from _workbench_store import canonical
    import _workbench_workflows as workflows
    from _workbench_schema import WorkbenchError
    workflow = _workflow(document, args)
    if workflow.get("kind") == "dag":
        return _preview_graph(document, args, workflow)
    discovery = parameters(document, args)
    allowed = {(item["stepIndex"], item["path"]): item for item in discovery["candidatePaths"]}
    axes = args["axes"]
    if any("stepIndex" not in axis or "nodeId" in axis for axis in axes):
        fail("invalid-sweep-axis", "Linear workflow axes require stepIndex and cannot contain nodeId.")
    identifiers = [(axis["stepIndex"], axis["path"]) for axis in axes]
    if len(set(identifiers)) != len(identifiers):
        fail("invalid-sweep", "Each parameter path may appear in only one axis.")
    count = math.prod(len(axis["values"]) for axis in axes)
    if count > MAX_COMBINATIONS:
        fail("sweep-too-large", "A sweep supports at most 64 Cartesian parameter combinations.", {"combinationCount": count})
    for axis in axes:
        candidate = allowed.get((axis["stepIndex"], axis["path"]))
        if candidate is None:
            fail("invalid-sweep-path", "Choose a parameter path returned by sweep.parameters.",
                 {"stepIndex": axis["stepIndex"], "path": axis["path"]})
        if len({_digest(value) for value in axis["values"]}) != len(axis["values"]):
            fail("invalid-sweep", "An axis cannot contain duplicate values.")
        for value in axis["values"]:
            if value is None:
                if not candidate["canOmit"]:
                    fail("invalid-sweep", "This required parameter cannot be omitted.", {"path": axis["path"]})
    image_ids = args["imageIds"]
    if len(set(image_ids)) != len(image_ids):
        fail("invalid-sweep", "Sweep source image IDs must be unique.")
    images = [workflows._image(document, image_id) for image_id in image_ids]
    variant_count = count * len(images)
    if len(document.get("jobs", [])) + count > 1000 or len(document.get("workflows", [])) + count > 1000:
        fail("project-too-large", "The sweep would exceed 1,000 retained jobs or saved workflow versions.")
    export_required = any(step["type"] == "export" for step in workflow["steps"])
    if "exportDirectory" in args:
        if not export_required:
            fail("invalid-sweep", "exportDirectory applies only to a workflow containing an export step.")
        destination = absolute_path(args["exportDirectory"], "exportDirectory")
        if not destination.is_dir():
            fail("invalid-path", "Choose an existing export directory.")
    processed_count = 0
    checkpoint_count = 0
    plan_bytes = 0
    combinations = []
    seen = set()
    # A cheap metadata-only projection checks the same job-create path that
    # will validate real independent variants, without copying masks or arrays.
    projected = [{key: value for key, value in image.items() if key not in
                  ("analysis", "volumeFrames", "undoStack", "volumeTracks", "volumeLineages")}
                 | {"id": f"sweep-preview-{index}"} for index, image in enumerate(images)]
    projected_ids = [image["id"] for image in projected]
    for index, values in enumerate(itertools.product(*(axis["values"] for axis in axes))):
        steps = copy.deepcopy(workflow["steps"])
        selected = []
        for axis, value in zip(axes, values):
            _assign(steps[axis["stepIndex"]], axis["path"], value)
            selected.append({"stepIndex": axis["stepIndex"], "path": axis["path"], "value": value})
        try:
            steps = workflows._validated_steps(steps, document)
            # Each actual export gets a new destination at creation. A saved
            # template destination never gets reused across combinations.
            for step in steps:
                if step["type"] == "export":
                    step.pop("destination", None)
            normalized = _digest(steps)
            if normalized in seen:
                fail("duplicate-sweep-combination", "Different axis values normalize to the same executable workflow. Remove redundant values.")
            seen.add(normalized)
            temporary = {**workflow, "id": "sweep-preview", "version": 1,
                         "steps": [step for step in steps if step["type"] != "export"]}
            projection = {**document, "images": CombinedRows(document["images"], projected),
                          "workflows": [temporary], "jobs": []}
            job_args = {"workflowId": temporary["id"], "imageIds": projected_ids}
            if "timeIndices" in args:
                job_args["timeIndices"] = args["timeIndices"]
            planned = workflows.apply(projection, "job.create", job_args)["job"]
        except WorkbenchError as exc:
            fail(exc.code, f"Combination {index + 1}: {exc.message}",
                 {"combinationIndex": index, "values": selected, "cause": exc.details})
        if workflows.has_preprocessing(temporary):
            processed_count += len(planned["checkpoints"])
        checkpoint_count += len(planned["checkpoints"])
        if checkpoint_count > MAX_CHECKPOINTS:
            fail("sweep-too-large", "A complete sweep supports at most 5,000 image/frame checkpoints.",
                 {"checkpointCount": checkpoint_count})
        plan_bytes += len(canonical(steps).encode())
        if plan_bytes > MAX_PLAN_BYTES:
            fail("sweep-too-large", "The combined concrete workflow definitions exceed 8 MiB. Reduce the parameter sweep.")
        combinations.append({"index": index, "values": selected, "steps": steps,
                             "checkpointCount": len(planned["checkpoints"]),
                             "target": "volume" if workflows.is_volume(temporary) else "plane"})
    total = variant_count + processed_count
    if len(document["images"]) + total > image_capacity(document):
        fail("project-too-large", "The sweep variants and retained preprocessing outputs would exceed 1,000 acquisitions.",
             {"existingImageCount": len(document["images"]), "requiredImageCount": total})
    from _workbench_variants import acquisition_snapshot
    from _workbench_store import MAX_PROJECT_JSON_BYTES
    estimated_bytes = (base_metadata_bytes(document) + plan_bytes * 2 +
                       count * sum(len(canonical(acquisition_snapshot(image)).encode()) + 2048 for image in images) +
                       checkpoint_count * 2048 + len(canonical(workflow).encode()) +
                       len(canonical(axes).encode()) + 16384)
    if estimated_bytes > MAX_PROJECT_JSON_BYTES:
        fail("project-too-large", "The sweep's retained workflows, variants and checkpoints would exceed the project metadata budget. Reduce the sweep or use a new project.",
             {"estimatedMetadataBytes": estimated_bytes, "maximumBytes": MAX_PROJECT_JSON_BYTES})
    return {"combinationCount": count, "requiredVariantCount": variant_count,
            "requiredProcessedCount": processed_count, "requiredImageCount": total, "checkpointCount": checkpoint_count,
            "requiresExportDirectory": export_required, "combinations": combinations,
            **{key: discovery[key] for key in ("candidatePaths", "limits", "notes")}}


def _jobs(document, sweep):
    import _workbench_workflows as workflows
    result = []
    for item in sweep["combinations"]:
        job = workflows.get_job(document, item["jobId"])
        if job["definitionHash"] != item["jobDefinitionHash"]:
            fail("project-corrupt", "A sweep combination's immutable job definition changed.")
        result.append(job)
    return result


def stale_sources(document, sweep):
    images = image_index(document)
    return [item["imageId"] for item in sweep["sourceInputs"]
            if item["imageId"] not in images or _source_fingerprint(images[item["imageId"]]) != item["fingerprint"]]


def status(document, sweep, jobs=None):
    jobs = jobs if jobs is not None else _jobs(document, sweep)
    if sweep.get("controlState") in ("paused", "cancelled"):
        return sweep["controlState"]
    for state in ("blocked", "failed", "awaiting-review", "paused", "cancelled"):
        if any(job["status"] == state for job in jobs):
            return state
    if all(job["status"] == "completed" for job in jobs):
        return "completed"
    if stale_sources(document, sweep):
        return "blocked"
    return "running" if any(job["status"] != "pending" for job in jobs) else "pending"


def next_job(document, sweep, jobs=None):
    from _workbench_workflows import next_unit
    jobs = jobs if jobs is not None else _jobs(document, sweep)
    if status(document, sweep, jobs) not in ("pending", "running"):
        return None
    remaining = [job for job in jobs if job["status"] in ("pending", "running")]
    scientific = [job for job in remaining if (next_unit(job) or {}).get("type") != "export"]
    return (scientific or remaining or [None])[0]


def describe(document, sweep, compact=False, job_descriptors=None):
    import _workbench_workflows as workflows
    jobs = _jobs(document, sweep)
    if job_descriptors is None:
        fingerprints = workflows._ImageFingerprints(document)
        project_fingerprint = workflows.project_fingerprint(document, fingerprints) if any(job.get("export", {}).get("projectInputFingerprint") for job in jobs) else None
        descriptors = [workflows.describe_job(job, document, compact=True, image_fingerprints=fingerprints,
                                              current_project_fingerprint=project_fingerprint) for job in jobs]
    else:
        descriptors = [job_descriptors[job["id"]] for job in jobs]
    selected = next_job(document, sweep, jobs)
    stale = stale_sources(document, sweep)
    result = {key: copy.deepcopy(value) for key, value in sweep.items()
              if key not in ("sourceInputs", "definitionHash")}
    result.update({"status": status(document, sweep, jobs),
                   "progress": {"completed": sum(job["progress"]["completed"] for job in descriptors),
                                "total": sum(job["progress"]["total"] for job in descriptors)},
                   "completedCombinations": sum(job["status"] == "completed" for job in jobs),
                   "combinationCount": len(jobs), "nextJobId": selected["id"] if selected else None,
                   "sourceInputsCurrent": not stale, "staleSourceImageIds": stale,
                   "outputsCurrent": not stale and all(job["outputsCurrent"] for job in descriptors),
                   "jobs": descriptors, "notes": notes()})
    if compact:
        result["baseWorkflow"] = {key: sweep["baseWorkflow"][key] for key in ("id", "name", "version", "kind") if key in sweep["baseWorkflow"]}
        for key in ("jobs", "combinations", "axes"):
            result.pop(key, None)
    return result


def inspect_sweeps(document, job_descriptors=None):
    if not document.get("sweeps"):
        return []
    from _workbench_workflows import inspect_jobs
    descriptors = job_descriptors if job_descriptors is not None else inspect_jobs(document)
    indexed = {item["id"]: item for item in descriptors}
    return [describe(document, get(document, item["id"]), compact=True, job_descriptors=indexed)
            for item in document["sweeps"]]


def check_advance(document, sweep):
    import _workbench_workflows as workflows
    stale = stale_sources(document, sweep)
    if stale:
        fail("stale-sweep-input", "An original acquisition, calibration or support changed. Create a new sweep to use those changes.",
             {"imageIds": stale})
    job = next_job(document, sweep)
    if job is None:
        fail("invalid-sweep-state", f"Cannot advance a {status(document, sweep)} sweep. Resume or retry eligible jobs explicitly.")
    # A changed completed variant invalidates the group's remaining work too.
    for item in _jobs(document, sweep):
        workflows.check_inputs(document, item)
    return job


def execute(store, document, operation, args, revision, hooks):
    import _workbench_workflows as workflows
    from _workbench_store import utc_now
    if operation == "sweep.parameters":
        return parameters(document, args)
    if operation == "sweep.preview":
        return preview(document, args)
    if operation == "sweep.list":
        return {"sweeps": inspect_sweeps(document)}
    if operation == "sweep.create":
        import _workbench_variants as variants
        if len(document.get("sweeps", [])) >= MAX_SWEEPS:
            fail("sweep-limit", "A project retains at most 128 sweep groups.")
        plan = preview(document, args)
        if plan["requiresExportDirectory"] and not args.get("exportDirectory"):
            fail("export-directory-required", "Choose an existing exportDirectory for this sweep's distinct complete-project ZIPs.")
        base = copy.deepcopy(_workflow(document, args))
        sweep_id = str(uuid.uuid4())
        name = args.get("name", base["name"][:180] + " · sweep")
        originals = [workflows._image(document, image_id) for image_id in args["imageIds"]]
        for source_path, source_hash in {image["sourcePath"]: image["sourceHash"] for image in originals}.items():
            store.verify_artifact(source_path, source_hash)
        created = []
        for combination in plan["combinations"]:
            number = combination["index"] + 1
            if "graph" in combination:
                from _workbench_graphs import save
                concrete = save(document, {"name": name[:170] + f" · {number}", "graph": combination["graph"]})["workflow"]
            else:
                concrete = workflows.apply(document, "workflow.save", {
                    "name": name[:170] + f" · {number}", "steps": combination["steps"]})["workflow"]
            mappings = []
            for image in originals:
                duplicated = variants.execute(store, document, {
                    "imageId": image["id"], "name": image["name"][:160] + f" · sweep {number}",
                    "copyAnalysis": False}, revision, hooks, verify_source=False)
                retained = workflows._image(document, duplicated["imageId"])
                retained["sweepOrigin"] = {"sweepId": sweep_id, "combinationIndex": combination["index"],
                                           "sourceImageId": image["id"]}
                mappings.append({"sourceImageId": image["id"], "imageId": retained["id"]})
            job_args = {"workflowId": concrete["id"], "workflowVersion": concrete["version"],
                        "imageIds": [item["imageId"] for item in mappings]}
            if "timeIndices" in args:
                job_args["timeIndices"] = args["timeIndices"]
            if plan["requiresExportDirectory"]:
                job_args["exportDestination"] = str(Path(args["exportDirectory"]) / f"sweep-{sweep_id}-{number:03d}.zip")
            job = workflows.apply(document, "job.create", job_args)["job"]
            created.append({"index": combination["index"], "values": copy.deepcopy(combination["values"]),
                            "jobId": job["id"], "jobDefinitionHash": job["definitionHash"],
                            "workflowId": concrete["id"], "workflowVersion": concrete["version"],
                            "variants": mappings})
        sweep = {"id": sweep_id, "name": name, "baseWorkflow": base,
                 "axes": copy.deepcopy(args["axes"]), "imageIds": list(args["imageIds"]),
                 "combinations": created,
                 "sourceInputs": [{"imageId": image["id"], "fingerprint": _source_fingerprint(image)} for image in originals],
                 "createdAt": utc_now(), "createdRevision": revision, "controlState": "ready"}
        sweep["definitionHash"] = _digest({key: sweep[key] for key in
                                          ("baseWorkflow", "axes", "imageIds", "combinations", "sourceInputs")})
        document.setdefault("sweeps", []).append(sweep)
        return {"sweep": describe(document, sweep)}
    sweep = get(document, args["sweepId"])
    if operation == "sweep.get":
        return {"sweep": describe(document, sweep)}
    action = operation.split(".")[-1]
    if action not in ("pause", "resume", "retry", "cancel"):
        fail("unknown-operation", "Unknown sweep operation.")
    if (status(document, sweep) == "completed" or sweep.get("controlState") == "cancelled" or
            (status(document, sweep) == "cancelled" and action != "cancel")):
        fail("invalid-sweep-state", "Completed or cancelled sweeps cannot be restarted. Create a new sweep.")
    jobs = _jobs(document, sweep)
    if action in ("resume", "retry"):
        stale = stale_sources(document, sweep)
        if stale:
            fail("stale-sweep-input", "Original sweep inputs changed. Create a new sweep.", {"imageIds": stale})
        for job in jobs:
            workflows.check_inputs(document, job)
    eligible = {"pause": ("pending", "running"), "resume": ("paused",),
                "retry": ("failed", "blocked") if sweep["baseWorkflow"].get("kind") == "dag" else ("failed",),
                "cancel": ("pending", "running", "paused", "blocked", "failed", "awaiting-review")}[action]
    if action in ("resume", "retry") and not any(job["status"] in eligible for job in jobs):
        fail("invalid-sweep-state", f"No sweep job is eligible for {action}.")
    for job in jobs:
        if job["status"] in eligible:
            controls = ({key: args[key] for key in ("reason", "controlRequestId") if key in args}
                        if action == "pause" else {})
            workflows.apply(document, "job." + action, {"jobId": job["id"], **controls})
    sweep["controlState"] = {"pause": "paused", "cancel": "cancelled"}.get(action, "ready")
    if action == "pause":
        sweep["pausedReason"] = args.get("reason", "Requested by the client")
        if "controlRequestId" in args:
            sweep["pauseControlRequestId"] = args["controlRequestId"]
    sweep["updatedAt"] = utc_now()
    return {"sweep": describe(document, sweep)}


def _preview_graph(document, arguments, workflow):
    """Budget Cartesian DAG definitions through the ordinary graph validator."""
    import _workbench_graphs as graphs
    from _workbench_schema import WorkbenchError, absolute_path
    from _workbench_store import canonical, MAX_PROJECT_JSON_BYTES
    discovery = parameters(document, arguments)
    axes = arguments["axes"]
    if any("nodeId" not in axis or "stepIndex" in axis for axis in axes):
        fail("invalid-sweep-axis", "Graph axes require nodeId and cannot contain compatibility stepIndex values.")
    keys = [(axis["nodeId"], axis["path"]) for axis in axes]
    if len(set(keys)) != len(keys):
        fail("invalid-sweep-axis", "Select each graph node parameter once.")
    allowed = {(item["nodeId"], item["path"]): item for item in discovery["candidatePaths"]}
    for axis in axes:
        control = allowed.get((axis["nodeId"], axis["path"]))
        if control is None:
            fail("invalid-sweep-path", "Choose a graph node parameter returned by sweep.parameters.",
                 {"nodeId": axis["nodeId"], "path": axis["path"]})
        if len({_digest(value) for value in axis["values"]}) != len(axis["values"]):
            fail("invalid-sweep", "An axis cannot contain duplicate values.")
        if None in axis["values"] and not control["canOmit"]:
            fail("invalid-sweep", "This required graph parameter cannot be omitted.")
    count = math.prod(len(axis["values"]) for axis in axes)
    if count > MAX_COMBINATIONS:
        fail("sweep-too-large", "A graph sweep supports at most 64 Cartesian combinations.")
    if len(document.get("jobs", [])) + count > 1000 or len(document.get("workflows", [])) + count > 1000:
        fail("project-too-large", "The sweep would exceed 1,000 retained jobs or workflow versions.")
    export_required = any(node["type"] == "export" for node in workflow["graph"]["nodes"])
    if "exportDirectory" in arguments:
        if not export_required:
            fail("invalid-sweep", "exportDirectory applies only to a graph with an export node.")
        if not absolute_path(arguments["exportDirectory"], "exportDirectory").is_dir():
            fail("invalid-path", "Choose an existing export directory.")
    combinations, seen = [], set()
    processed, branch_images, checkpoints, node_checkpoints, plan_bytes = 0, 0, 0, 0, 0
    assay_outputs, plugin_outputs = 0, 0
    for index, values in enumerate(itertools.product(*(axis["values"] for axis in axes))):
        graph = copy.deepcopy(workflow["graph"])
        by_id = {node["id"]: node for node in graph["nodes"]}
        selected = []
        for axis, value in zip(axes, values):
            _assign(by_id[axis["nodeId"]], axis["path"], value)
            selected.append({"nodeId": axis["nodeId"], "nodeName": by_id[axis["nodeId"]].get("name", axis["nodeId"]),
                             "path": axis["path"], "value": value})
        for node in graph["nodes"]:
            if node["type"] == "export":
                node.pop("destination", None)
        try:
            response = graphs.preview(document, {"graph": graph, **{key: arguments[key] for key in ("imageIds", "timeIndices") if key in arguments}})
        except WorkbenchError as exc:
            fail(exc.code, f"Combination {index + 1}: {exc.message}",
                 {"combinationIndex": index, "values": selected, "cause": exc.details})
        graph, plan = response["graph"], response["plan"]
        identity = _digest(graph)
        if identity in seen:
            fail("duplicate-sweep-combination", "Different values normalize to the same graph. Remove redundant axis values.")
        seen.add(identity)
        per_source = plan["checkpointCount"]
        processed += per_source * sum(node["type"] == "preprocessing" for node in graph["nodes"])
        branch_images += per_source * (plan["segmentationBranchCount"] + sum(node["type"] == "mask-merge" for node in graph["nodes"]))
        checkpoints += per_source
        node_checkpoints += plan["nodeCheckpointCount"]
        if node_checkpoints > MAX_CHECKPOINTS:
            fail("sweep-too-large", "A graph sweep supports at most 5,000 total scientific node checkpoints.")
        assay_outputs += per_source * sum(node["type"] == "assay" for node in graph["nodes"])
        plugin_outputs += per_source * sum(node["type"].startswith("plugin-") for node in graph["nodes"])
        plan_bytes += len(canonical(graph).encode())
        if plan_bytes > MAX_PLAN_BYTES:
            fail("sweep-too-large", "Concrete graph definitions exceed the 8 MiB bound.")
        combinations.append({"index": index, "values": selected, "graph": graph,
                             "steps": [graphs.step_of(node) for node in graph["nodes"]],
                             "checkpointCount": per_source, "nodeCheckpointCount": plan["nodeCheckpointCount"],
                             "segmentationBranchCount": plan["segmentationBranchCount"], "target": graph["target"]})
    variants = count * len(arguments["imageIds"])
    total = variants + processed + branch_images
    if len(document["images"]) + total > image_capacity(document):
        fail("project-too-large", "Isolated sweep sources, processing outputs and segmentation branches would exceed 1,000 acquisitions.",
             {"requiredImageCount": total, "requiredBranchImageCount": branch_images})
    if len(document.get("assayRuns", [])) + assay_outputs > 1000 or len(document.get("pluginRuns", [])) + plugin_outputs > 1000:
        fail("sweep-too-large", "The complete graph sweep would exceed retained assay/plugin history limits.")
    estimated = base_metadata_bytes(document) + plan_bytes * 4 + node_checkpoints * 4096 + total * 4096
    if estimated > MAX_PROJECT_JSON_BYTES:
        fail("project-too-large", "The graph sweep exceeds its projected retained metadata budget. Reduce combinations or sources.")
    return {"combinationCount": count, "requiredVariantCount": variants, "requiredProcessedCount": processed,
            "requiredBranchImageCount": branch_images, "requiredImageCount": total, "checkpointCount": checkpoints,
            "nodeCheckpointCount": node_checkpoints, "requiresExportDirectory": export_required,
            "combinations": combinations, **{key: discovery[key] for key in ("candidatePaths", "limits", "notes")}}
