"""Portable checkpoint tasks using isolated projects and the canonical job engine."""
from __future__ import annotations

from _workbench_indexed import RecordList

from _workbench_indexed import image_index

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

MAX_GROUPS = 32
MAX_TASKS = 128
MAX_TOTAL_TASKS = 1000
MAX_TEMPLATE_BYTES = 32 * 1024 ** 2
MAX_PUBLICATIONS = 1000


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    selection = {"workflowId": _ID, "workflowVersion": {"type": "integer", "minimum": 1},
                 "imageIds": {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000},
                 "timeIndices": {"type": "array", "items": {"type": "integer", "minimum": 0},
                                 "minItems": 1, "maxItems": 1000}}
    identity = {"distributionId": _ID, "taskId": _ID}
    result_file = {**identity, "path": _STRING}
    return [
        _op("distribution.preview", "Partition a complete saved workflow into bounded independent image/time tasks.",
            _object(selection, ["workflowId", "imageIds"])),
        _op("distribution.create", "Freeze portable task identities, inputs and complete workflow definitions without executing them.",
            _object({**selection, "name": {"type": "string", "minLength": 1, "maxLength": 200}}, ["workflowId", "imageIds"]), True),
        _op("distribution.list", "List distributed task groups and isolated result collection status.", _object()),
        _op("distribution.get", "Read frozen distributed tasks and current coordinator input status.",
            _object({"distributionId": _ID}, ["distributionId"])),
        _op("distribution.bundle.export", "Publish one immutable isolated task project for execution on another machine.",
            _object({**identity, "destination": _STRING}, ["distributionId", "taskId", "destination"]), True),
        _op("distribution.task.get", "Inspect a restored portable task and its canonical job, without executing or trusting code.", _object()),
        _op("distribution.task.prepare", "Bind explicitly trusted local runtimes and create one canonical job for a restored task.",
            _object({"exportDestination": _STRING, "allowRuntimeDifferences": {"type": "boolean", "default": False}}), True),
        _op("distribution.result.preview", "Verify an isolated completed task package and its coordinator input bindings.",
            _object(result_file, ["distributionId", "taskId", "path"])),
        _op("distribution.result.collect", "Retain exact verified result artifacts as an isolated project without replacing coordinator analyses.",
            _object({**result_file, "previewFingerprint": {"type": "string", "minLength": 64, "maxLength": 64}},
                    ["distributionId", "taskId", "path", "previewFingerprint"]), True),
        _op("distribution.result.export", "Publish a collected isolated result project for restoration and inspection.",
            _object({**identity, "destination": _STRING}, ["distributionId", "taskId", "destination"]), True),
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def limits():
    return {"groups": MAX_GROUPS, "tasksPerGroup": MAX_TASKS, "totalTasks": MAX_TOTAL_TASKS,
            "templateBytes": MAX_TEMPLATE_BYTES}


def notes():
    return [
        "Each task runs the complete saved workflow for one image/time checkpoint in an isolated project.",
        "Restore does not execute or trust code. Enable exact plugins and rebind models explicitly before preparing a task.",
        "Collection retains an isolated result project; original masks, annotations and biological assignments are not merged.",
        "Task copies are analysis variants, not additional biological replicates.",
        "Observed shared Python/package metadata, plugin bytes and model checkpoint/backend bindings are retained. Explicit model environment captures are compared when present; uncaptured model environments remain unrecorded. These inventories are not binary or driver lockfiles.",
        "Integrity and frozen-definition checks establish consistency, not proof of execution by an authenticated machine.",
    ]


def model_environment_hashes(document, model_ids):
    from _workbench_models import _model, active_environment_hash
    return {identifier: active_environment_hash(_model(document, identifier)) for identifier in model_ids}


def runtime_signature(store=None, model_environments=None, inventory=None):
    from _workbench_packages import runtime_versions
    from _workbench_store import file_hash, canonical
    import _workbench_environment as environments
    modules = {path.name: file_hash(path) for path in sorted(Path(__file__).parent.glob("_workbench_*.py"))}
    inventory = environments.capture() if inventory is None else inventory
    encoded = (canonical(inventory) + "\n").encode("utf-8")
    checksum = hashlib.sha256(encoded).hexdigest()
    reference = f"artifacts/{checksum}.python-environment.json"
    if store is not None:
        store.put_bytes(encoded, ".python-environment.json")
    return {"codeHash": digest(modules), "modules": modules, **runtime_versions(),
            "environment": environments.summary(inventory), "environmentPath": reference, "environmentHash": checksum,
            "modelEnvironmentHashes": dict(model_environments or {})}


def runtime_differences(expected, actual):
    differences = []
    if expected.get("codeHash") != actual.get("codeHash"):
        differences.append("The shared workbench runtime source differs from the coordinator.")
    if expected.get("python") != actual.get("python"):
        differences.append(f"Python: coordinator {expected.get('python')}, local {actual.get('python')}.")
    for name in sorted(set(expected.get("packages", {})) | set(actual.get("packages", {}))):
        left, right = expected.get("packages", {}).get(name), actual.get("packages", {}).get(name)
        if left != right:
            differences.append(f"{name}: coordinator {left or 'unavailable'}, local {right or 'unavailable'}.")
    if expected.get("environment", {}).get("hash") != actual.get("environment", {}).get("hash"):
        differences.append("The observed shared Python/platform/package inventory differs; full metadata records are retained in the task package.")
    old_models, new_models = expected.get("modelEnvironmentHashes", {}), actual.get("modelEnvironmentHashes", {})
    for identifier in sorted(set(old_models) | set(new_models)):
        if old_models.get(identifier) != new_models.get(identifier):
            differences.append(f"Model {identifier}: observed environment coordinator {old_models.get(identifier) or 'unrecorded'}, local {new_models.get(identifier) or 'unrecorded'}.")
    return differences


def scientific_hash(workflow):
    graph = copy.deepcopy(workflow.get("graph")) if workflow.get("kind") == "dag" else None
    steps = graph["nodes"] if graph is not None else copy.deepcopy(workflow["steps"])
    for step in steps:
        if step["type"] == "model-segmentation":
            step.pop("pythonPath", None)
            step.pop("pythonHash", None)
            step.pop("environmentHash", None)
        if step["type"] == "export":
            step.pop("destination", None)
    return digest({"kind": "dag", "graph": graph}) if graph is not None else digest(steps)


def requirements(workflow):
    return {"pluginIds": sorted({step["pluginId"] for step in workflow["steps"] if step["type"].startswith("plugin-")}),
            "modelIds": sorted({step["modelId"] for step in workflow["steps"] if step["type"] == "model-segmentation"}),
            "requiresExportDestination": any(step["type"] == "export" for step in workflow["steps"])}


def source_fingerprint(image, kind="acquisition"):
    if kind == "reference":
        return digest(image)
    from _workbench_sweeps import _source_fingerprint
    return _source_fingerprint(image)


def _image(document, image_id):
    from _workbench_workflows import _image as image
    return image(document, image_id)


def _task_hash(value):
    return digest({key: item for key, item in value.items() if key != "definitionHash"})


def _task_definition(document):
    task = document.get("distributedTask")
    if task is None:
        return None
    if task.get("schemaVersion") != 1 or task.get("definitionHash") != _task_hash(task):
        fail("task-integrity", "The portable task definition has changed.")
    if scientific_hash(task["workflow"]) != task["scientificHash"]:
        fail("task-integrity", "The portable task's scientific workflow has changed.")
    return task


def _check_local_inputs(document, task):
    for item in task["localInputs"]:
        image = _image(document, item["imageId"])
        if source_fingerprint(image, item["kind"]) != item["fingerprint"]:
            fail("stale-task-input", "A task acquisition, calibration, support mask or fixed reference changed.",
                 {"imageId": item["imageId"]})


def _groups(document):
    groups = document.get("distributions", [])
    if not isinstance(groups, (list, RecordList)) or len(groups) > MAX_GROUPS:
        fail("distribution-limit", "The project supports at most 32 distributed task groups.")
    return groups


def _group_hash(group):
    return digest({key: group[key] for key in ("id", "name", "workflow", "sourceInputs", "taskDefinitions")})


def get_group(document, distribution_id):
    group = next((item for item in _groups(document) if item["id"] == distribution_id), None)
    if group is None:
        fail("distribution-not-found", "The distributed task group is unavailable.")
    if group["definitionHash"] != _group_hash(group):
        fail("distribution-integrity", "The frozen distributed task group changed.")
    return group


def get_task(group, task_id):
    task = next((item for item in group["tasks"] if item["id"] == task_id), None)
    if task is None:
        fail("task-not-found", "The selected task does not belong to this distribution.")
    frozen = next((item for item in group["taskDefinitions"] if item["id"] == task_id), None)
    if frozen is None or any(task.get(key) != value for key, value in frozen.items()):
        fail("task-integrity", "The task identity or frozen snapshot changed.")
    return task


def stale_inputs(document, group):
    images = image_index(document)
    return [item["imageId"] for item in group["sourceInputs"]
            if item["imageId"] not in images or source_fingerprint(images[item["imageId"]], item["kind"]) != item["fingerprint"]]


def _check_coordinator(document, group):
    stale = stale_inputs(document, group)
    if stale:
        fail("stale-distribution-input", "Coordinator source, calibration, support or fixed reference inputs changed. Create a new distribution.",
             {"imageIds": stale})


def _public_task(task):
    return {key: copy.deepcopy(task[key]) for key in (
        "id", "index", "sourceImageId", "imageId", "target", "timeIndex", "channel", "status", "bundle", "result") if key in task}


def describe_group(document, group, compact=False):
    stale = stale_inputs(document, group)
    collected = sum(item["status"] == "collected" for item in group["tasks"])
    result = {key: copy.deepcopy(group[key]) for key in ("id", "name", "createdAt", "createdRevision")}
    result.update({"workflow": {key: group["workflow"][key] for key in ("id", "name", "version", "kind") if key in group["workflow"]},
                   "taskCount": len(group["tasks"]), "collectedCount": collected,
                   "sourceInputsCurrent": not stale, "staleImageIds": stale,
                   "status": "collected" if collected == len(group["tasks"]) else "partial" if collected else "pending",
                   "notes": notes()})
    if not compact:
        result["tasks"] = [_public_task(task) for task in group["tasks"]]
    return result


def inspect_groups(document):
    return [describe_group(document, get_group(document, group["id"]), compact=True) for group in _groups(document)]


def preview(document, arguments):
    import _workbench_workflows as workflows
    import _workbench_volume as volume
    import _workbench_imaging as imaging
    if document.get("distributedTask"):
        fail("nested-distribution", "Create distributed groups in a coordinator project, not inside a portable task.")
    workflow = copy.deepcopy(workflows.get_workflow(document, arguments["workflowId"], arguments.get("workflowVersion")))
    if workflow.get("kind") == "dag":
        import _workbench_graphs as graphs
        graph, _ = graphs.normalize(document, workflow["graph"])
        if graph != workflow["graph"]:
            fail("workflow-changed", "Save a new graph version before distributing changed normalized settings.")
        sources = graphs._sources(document, graph, arguments)
        if len(sources) > MAX_TASKS:
            fail("distribution-too-large", "A group supports at most 128 whole-graph image/time tasks.")
        nodes = graphs.scientific_nodes(workflow)
        created = sum(node["type"] in ("preprocessing", "mask-merge") or node["type"] in graphs.SEGMENTATION for node in nodes)
        branches = sum(node["type"] in graphs.SEGMENTATION for node in nodes)
        tasks = [{"index": index, "sourceImageId": item["imageId"], "imageName": _image(document, item["imageId"])["name"],
                  **copy.deepcopy(item["sourceSelection"]), "nodeCheckpointCount": len(nodes),
                  "newImageCount": created, "segmentationBranchCount": branches}
                 for index, item in enumerate(sources)]
        return {"plan": {"workflow": {key: workflow[key] for key in ("id", "name", "version", "kind")},
                         "taskCount": len(tasks), "tasks": tasks, "requirements": requirements(workflow),
                         "nodeCheckpointCount": len(tasks) * len(nodes), "referenceImageIds": [],
                         "limits": limits(), "notes": notes() + graphs.notes()}}
    normalized = workflows._validated_steps(workflow["steps"], document)
    if normalized != workflow["steps"]:
        fail("workflow-changed", "The saved workflow no longer matches this runtime. Save a new workflow version.")
    ids = arguments["imageIds"]
    if len(set(ids)) != len(ids):
        fail("invalid-arguments", "Select each source image once.")
    reference_inputs = workflows._reference_inputs(document, workflow, ids)
    is_volume = workflows.is_volume(workflow)
    first = workflows.segmentation_step(workflow)
    if not is_volume and "timeIndices" in arguments:
        fail("invalid-arguments", "timeIndices applies only to volume workflows.")
    if "timeIndices" in arguments and len(set(arguments["timeIndices"])) != len(arguments["timeIndices"]):
        fail("invalid-arguments", "Select each time point once.")
    tasks = []
    for image_id in ids:
        image = _image(document, image_id)
        indices = sorted(arguments.get("timeIndices", range(image.get("timeCount", 1)))) if is_volume else [None]
        for time_index in indices:
            entry = {"index": len(tasks), "sourceImageId": image_id, "imageName": image["name"],
                     "target": "volume" if is_volume else "plane"}
            if is_volume:
                volume.selection(image, time_index, first["channel"])
                entry.update({"timeIndex": time_index, "channel": first["channel"]})
            else:
                params = first.get("sourceParameters", first.get("parameters", {}))
                imaging._check_plane_selection(image, params, None)
            tasks.append(entry)
            if len(tasks) > MAX_TASKS:
                fail("distribution-too-large", "A group supports at most 128 image/time tasks. Select fewer inputs or times.")
    return {"plan": {"workflow": {key: workflow[key] for key in ("id", "name", "version")},
                     "taskCount": len(tasks), "tasks": tasks, "requirements": requirements(workflow),
                     "referenceImageIds": [item["imageId"] for item in reference_inputs],
                     "limits": limits(), "notes": notes()}}


def _load_snapshot(store, path, checksum):
    from _workbench_packages import MAX_METADATA_BYTES, _json
    source = store.verify_artifact(path, checksum)
    if source.stat().st_size > MAX_METADATA_BYTES:
        fail("distribution-too-large", "The retained isolated project exceeds its metadata bound.")
    return _json(source.read_bytes(), "isolated-project.json")


def create(store, document, arguments, revision, actor):
    import _workbench_workflows as workflows
    import _workbench_packages as packages
    import _workbench_variants as variants
    from _workbench_store import canonical, utc_now
    from _workbench_core import _current_analysis
    plan = preview(document, arguments)["plan"]
    groups = _groups(document)
    if len(groups) >= MAX_GROUPS or sum(len(group["tasks"]) for group in groups) + plan["taskCount"] > MAX_TOTAL_TASKS:
        fail("distribution-limit", "The project supports 32 groups and 1,000 total distributed tasks.")
    workflow = copy.deepcopy(workflows.get_workflow(document, arguments["workflowId"], arguments.get("workflowVersion")))
    refs = [_image(document, identifier) for identifier in plan["referenceImageIds"]]
    for reference in refs:
        _current_analysis(store, reference)
    originals = [_image(document, identifier) for identifier in arguments["imageIds"]]
    source_inputs = [{"imageId": item["id"], "kind": "acquisition", "fingerprint": source_fingerprint(item)} for item in originals]
    source_inputs.extend({"imageId": item["id"], "kind": "reference", "fingerprint": source_fingerprint(item, "reference")} for item in refs)
    group_id, now = str(uuid.uuid4()), utc_now()
    name = arguments.get("name", workflow["name"][:175] + " · distributed")
    runtime = runtime_signature(store, model_environment_hashes(document, plan["requirements"]["modelIds"]))
    group = {"id": group_id, "name": name, "workflow": workflow, "sourceInputs": source_inputs,
             "createdAt": now, "createdRevision": revision, "tasks": [], "taskDefinitions": []}
    total_bytes = 0
    verified = set()
    for unit in plan["tasks"]:
        original = _image(document, unit["sourceImageId"])
        task_id, image_id, project_id = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        variant = {**variants.acquisition_snapshot(original), "id": image_id,
                   "name": original["name"][:160] + " · distributed task", "importedAt": now, "undoStack": [],
                   "variantOf": original["id"], "variantRootId": original.get("variantRootId", original["id"])}
        local_inputs = [{"imageId": image_id, "kind": "acquisition", "fingerprint": source_fingerprint(variant)}]
        local_inputs.extend({"imageId": item["id"], "kind": "reference", "fingerprint": source_fingerprint(item, "reference")} for item in refs)
        task = {"schemaVersion": 1, "id": task_id, "distributionId": group_id,
                "coordinatorProjectId": document["id"], "coordinatorRevision": revision,
                "templateProjectId": project_id, "sourceImageId": original["id"], "imageId": image_id,
                "target": unit["target"], **{key: unit[key] for key in ("timeIndex", "channel") if key in unit},
                "workflow": workflow, "scientificHash": scientific_hash(workflow), "localInputs": local_inputs,
                "requirements": plan["requirements"], "runtime": runtime}
        task["definitionHash"] = _task_hash(task)
        child = {"schemaVersion": 1, "id": project_id, "name": name[:160] + f" · task {unit['index'] + 1}",
                 "revision": 0, "createdAt": now, "updatedAt": now,
                 "images": [variant, *copy.deepcopy(refs)], "history": [],
                 "workflows": [copy.deepcopy(workflow)], "distributedTask": task,
                 "plugins": [copy.deepcopy(item) for item in document.get("plugins", []) if item["pluginId"] in plan["requirements"]["pluginIds"]],
                 "models": [copy.deepcopy(item) for item in document.get("models", []) if item["id"] in plan["requirements"]["modelIds"]]}
        for record in [*child["plugins"], *child["models"]]:
            record["enabled"] = False
        references = packages.artifact_references(child, packages.store_json_reader(store))
        for path, checksum in references.items():
            if (path, checksum) not in verified:
                store.verify_artifact(path, checksum)
                verified.add((path, checksum))
        encoded = (canonical(child) + "\n").encode("utf-8")
        total_bytes += len(encoded)
        if total_bytes > MAX_TEMPLATE_BYTES:
            fail("distribution-too-large", "Task snapshots exceed the 32 MiB group metadata budget. Partition fewer inputs.")
        path, checksum = store.put_bytes(encoded, ".distributed-template.json")
        frozen = {"id": task_id, "index": unit["index"], "sourceImageId": original["id"], "imageId": image_id,
                  "target": unit["target"], **{key: unit[key] for key in ("timeIndex", "channel") if key in unit},
                  "definitionHash": task["definitionHash"], "templatePath": path, "templateHash": checksum,
                  "templateArtifacts": references}
        group["taskDefinitions"].append(copy.deepcopy(frozen))
        group["tasks"].append({**frozen, "status": "pending"})
    group["definitionHash"] = _group_hash(group)
    document.setdefault("distributions", []).append(group)
    return {"distribution": describe_group(document, group)}


def _execution(document, task):
    execution = document.get("distributedExecution")
    if execution is None:
        return None
    if (execution.get("schemaVersion") != 1 or execution.get("taskId") != task["id"] or
            execution.get("taskDefinitionHash") != task["definitionHash"] or
            execution.get("bindingHash") != digest({key: value for key, value in execution.items() if key != "bindingHash"})):
        fail("task-integrity", "The prepared task's execution binding changed.")
    return execution


def describe_task(document, include_local_runtime=False):
    import _workbench_workflows as workflows
    task = _task_definition(document)
    if task is None:
        return None
    execution = _execution(document, task)
    result = {key: copy.deepcopy(task[key]) for key in (
        "id", "distributionId", "coordinatorProjectId", "definitionHash", "workflow", "sourceImageId", "imageId",
        "timeIndex", "channel", "target", "requirements") if key in task}
    def public_runtime(value):
        return {key: copy.deepcopy(item) for key, item in value.items()
                if key not in ("environmentPath", "environmentHash", "modules")}
    runtime = {"coordinator": public_runtime(task["runtime"]), "differences": []}
    if execution:
        runtime.update({"prepared": public_runtime(execution["runtime"]),
                        "differences": copy.deepcopy(execution["runtimeDifferences"])})
    if include_local_runtime:
        current = runtime_signature(model_environments=model_environment_hashes(document, task["requirements"]["modelIds"]))
        runtime["current"] = public_runtime(current)
        runtime["currentDifferences"] = runtime_differences(execution["runtime"] if execution else task["runtime"], current)
        if not execution:
            runtime["differences"] = list(runtime["currentDifferences"])
    result.update({"prepared": execution is not None, "jobId": execution["jobId"] if execution else None,
                   "job": workflows.describe_job(workflows.get_job(document, execution["jobId"]), document) if execution else None,
                   "runtime": runtime, "notes": notes()})
    return result


def prepare_task(store, document, arguments, revision, actor):
    import _workbench_workflows as workflows
    import _workbench_models as models
    import _workbench_plugins as plugins
    from _workbench_store import utc_now
    task = _task_definition(document)
    if task is None:
        fail("not-distributed-task", "Restore a portable task bundle into a new project before preparing it.")
    if _execution(document, task):
        fail("task-already-prepared", "This task already has a canonical job. Resume or retry that job; restore the original task bundle to bind a different machine.")
    if document.get("jobs"):
        fail("task-has-unrelated-jobs", "Prepare a task before creating unrelated jobs in its isolated project.")
    _check_local_inputs(document, task)
    runtime = runtime_signature(store, model_environment_hashes(document, task["requirements"]["modelIds"]))
    differences = runtime_differences(task["runtime"], runtime)
    if differences and not arguments.get("allowRuntimeDifferences", False):
        fail("runtime-difference", "The local shared runtime differs from the coordinator. Inspect the differences and explicitly allow them to prepare this task.",
             {"differences": differences})
    graph = copy.deepcopy(task["workflow"].get("graph")) if task["workflow"].get("kind") == "dag" else None
    steps = graph["nodes"] if graph is not None else copy.deepcopy(task["workflow"]["steps"])
    for step in steps:
        if step["type"].startswith("plugin-"):
            record = plugins._record(document, step["pluginId"])
            if not record.get("enabled"):
                fail("plugin-disabled", "Explicitly enable the task's exact trusted plugin before preparing it.", {"pluginId": step["pluginId"]})
            plugins._verified(store, record)
        if step["type"] == "model-segmentation":
            model = models._model(document, step["modelId"])
            if (model["checkpointHash"] != step["checkpointHash"] or model["backend"] != step.get("backend", "cellpose3")
                    or any(step.get(key) != value for key, value in models.binding_fields(model).items())
                    or step.get("inferenceSchemaHash", models.model_schema_hash(model)) != models.model_schema_hash(model)):
                fail("model-changed", "The task requires its exact retained checkpoint and model backend.")
            models._verified(store, model)
            step.update({key: model[key] for key in ("pythonPath", "pythonHash")})
            environment_hash = models.active_environment_hash(model)
            if "environmentHash" in step and environment_hash is None:
                fail("model-environment-required", "This task froze an observed model environment. Explicitly capture the rebound interpreter before preparing it.", {"modelId": model["id"]})
            if environment_hash is not None:
                step["environmentHash"] = environment_hash
        if step["type"] == "export":
            # A coordinator filesystem destination is never a worker default.
            step.pop("destination", None)
    proposed = {"kind": "dag", "graph": graph} if graph is not None else {"steps": steps}
    if scientific_hash(proposed) != task["scientificHash"]:
        fail("task-integrity", "Local preparation would change the scientific workflow.")
    if task["requirements"]["requiresExportDestination"] and "exportDestination" not in arguments:
        fail("export-destination-required", "This complete workflow contains an export step. Supply a fresh local exportDestination, separate from the final result package.")
    if graph is not None:
        from _workbench_graphs import save
        workflow = save(document, {"name": task["workflow"]["name"], "graph": graph})["workflow"]
    else:
        workflow = workflows.apply(document, "workflow.save", {"name": task["workflow"]["name"], "steps": steps})["workflow"]
    if scientific_hash(workflow) != task["scientificHash"]:
        fail("workflow-changed", "This runtime normalizes the saved workflow differently. Use the coordinator's runtime; no scientific steps were executed.")
    job_args = {"workflowId": workflow["id"], "workflowVersion": workflow["version"], "imageIds": [task["imageId"]]}
    if task["target"] == "volume":
        job_args["timeIndices"] = [task["timeIndex"]]
    if "exportDestination" in arguments:
        job_args["exportDestination"] = arguments["exportDestination"]
    job_id = workflows.apply(document, "job.create", job_args)["job"]["id"]
    job = workflows.get_job(document, job_id)
    execution = {"schemaVersion": 1, "taskId": task["id"], "taskDefinitionHash": task["definitionHash"],
                 "jobId": job_id, "workflowHash": job["definitionHash"], "scientificHash": task["scientificHash"],
                 "runtime": runtime, "runtimeDifferences": differences,
                 "allowRuntimeDifferences": arguments.get("allowRuntimeDifferences", False),
                 "preparedAt": utc_now(), "preparedRevision": revision, "actor": copy.deepcopy(actor)}
    execution["bindingHash"] = digest(execution)
    document["distributedExecution"] = execution
    return {"task": describe_task(document), "job": workflows.describe_job(job, document)}


def _bound_job(document, task):
    import _workbench_workflows as workflows
    execution = _execution(document, task)
    if execution is None:
        fail("task-not-prepared", "Prepare this portable task before advancing a canonical job.")
    job = workflows.get_job(document, execution["jobId"])
    if (job["definitionHash"] != execution["workflowHash"] or scientific_hash(job["workflow"]) != task["scientificHash"] or
            execution["scientificHash"] != task["scientificHash"] or job["imageIds"] != [task["imageId"]] or
            len(job["checkpoints"]) != 1):
        fail("task-integrity", "The prepared job no longer matches the complete frozen task definition.")
    checkpoint = job["checkpoints"][0]
    if job.get("kind") == "dag":
        from _workbench_graphs import _selection
        selected = _selection(task["workflow"]["graph"])
        if selected["target"] == "volume":
            selected["timeIndex"] = task["timeIndex"]
        if checkpoint["imageId"] != task["imageId"] or checkpoint["sourceSelection"] != selected:
            fail("task-integrity", "The graph task's originating acquisition/time/channel binding changed.")
        return job, execution
    if checkpoint["imageId"] != task["imageId"] or any(checkpoint.get(key) != task.get(key) for key in ("timeIndex", "channel")):
        fail("task-integrity", "The job checkpoint does not match the task's source selection.")
    if workflows.has_preprocessing(job["workflow"]):
        first = workflows.segmentation_step(task["workflow"])
        parameters = first.get("sourceParameters", first.get("parameters", {}))
        expected = ({"target": "volume", "timeIndex": task["timeIndex"], "channel": task["channel"]}
                    if task["target"] == "volume" else
                    {"target": "plane", "channel": parameters["channel"], "zProjection": parameters["zProjection"]})
        if checkpoint.get("sourceImageId") != task["imageId"] or checkpoint.get("sourceSelection") != expected:
            fail("task-integrity", "The processed task's originating selection changed.")
    return job, execution


def guard_job(store, document, job):
    """Called by the one canonical checkpoint engine, including background workers."""
    task = _task_definition(document)
    if task is None:
        return
    _check_local_inputs(document, task)
    bound, execution = _bound_job(document, task)
    if bound["id"] != job["id"]:
        fail("unrelated-task-job", "Only this portable task's prepared canonical job may execute in its isolated project.")
    current_runtime = runtime_signature(model_environments=model_environment_hashes(document, task["requirements"]["modelIds"]))
    if current_runtime != execution["runtime"]:
        fail("prepared-runtime-changed", "The runtime changed after preparation. Resume in the original runtime, or restore the original task bundle into a new project and explicitly prepare it again.")
    import _workbench_models as models
    import _workbench_plugins as plugins
    for step in job["workflow"]["steps"]:
        if step["type"] == "model-segmentation":
            model = models._model(document, step["modelId"])
            if (any(model.get(key) != step.get(key) for key in ("checkpointHash", "pythonPath", "pythonHash", "backend"))
                    or any(step.get(key) != value for key, value in models.binding_fields(model).items())
                    or step.get("inferenceSchemaHash", models.model_schema_hash(model)) != models.model_schema_hash(model)):
                fail("prepared-runtime-changed", "The model binding changed after task preparation. Use its original binding or restore and prepare a fresh task bundle.")
        elif step["type"].startswith("plugin-") and plugins._record(document, step["pluginId"])["packageHash"] != step["packageHash"]:
            fail("plugin-changed", "The task's exact plugin version changed.")


def _validate_completed(document, expected_task):
    import _workbench_workflows as workflows
    task = _task_definition(document)
    if task is None or task != expected_task:
        fail("foreign-task-result", "The result does not contain this exact coordinator task definition.")
    if document.get("distributions"):
        fail("nested-distribution", "A result task cannot contain nested distribution groups.")
    _check_local_inputs(document, task)
    job, execution = _bound_job(document, task)
    if len(document.get("jobs", [])) != 1:
        fail("foreign-task-result", "A result must retain only its one prepared canonical job.")
    if job["status"] != "completed":
        fail("incomplete-task-result", "Export the isolated project after its canonical job is completed. A workflow's own intermediate export is not a completed task result.")
    description = workflows.describe_job(job, document)
    if not description["outputsCurrent"]:
        fail("stale-task-result", "The completed task's outputs or fixed references changed. Export a current completed result.")
    workflows.check_inputs(document, job)
    allowed = {item["imageId"] for item in task["localInputs"]}
    checkpoint = job["checkpoints"][0]
    if checkpoint.get("workingImageId"):
        allowed.add(checkpoint["workingImageId"])
    if job.get("kind") == "dag":
        allowed.update(node["outputBinding"]["imageId"] for node in checkpoint["nodes"])
    if {image["id"] for image in document["images"]} != allowed:
        fail("foreign-task-result", "The result contains additional or missing acquisitions outside this task and its frozen references.")
    differences = runtime_differences(task["runtime"], execution["runtime"])
    if differences != execution["runtimeDifferences"] or (differences and not execution.get("allowRuntimeDifferences")):
        fail("task-integrity", "Runtime differences were not explicitly accepted in the retained preparation record.")
    return task, description, execution


def _result(store, document, arguments, artifact_destination=None):
    import _workbench_packages as packages
    group = get_group(document, arguments["distributionId"])
    task = get_task(group, arguments["taskId"])
    _check_coordinator(document, group)
    if task["status"] == "collected":
        fail("duplicate-task-result", "This task already has a collected isolated result. Create a new distribution for another execution.")
    template = _load_snapshot(store, task["templatePath"], task["templateHash"])
    report, result_document = packages._verify(arguments["path"], artifact_destination)
    _, job, execution = _validate_completed(result_document, _task_definition(template))
    fingerprint = digest({"projectId": document["id"], "revision": document["revision"],
                          "groupDefinitionHash": group["definitionHash"], "taskDefinitionHash": task["definitionHash"],
                          "packageHash": report["package"]["sha256"], "resultProjectId": result_document["id"],
                          "resultRevision": result_document["revision"]})
    response = {"taskId": task["id"], "previewFingerprint": fingerprint, "collectionMode": "isolated-project",
                "package": report["package"], "job": job, "summary": copy.deepcopy(job.get("summary")),
                "runtimeDifferences": execution["runtimeDifferences"], "notes": notes()}
    return response, result_document, group, task


def collect(store, document, arguments, revision, actor):
    import _workbench_packages as packages
    from _workbench_store import canonical, utc_now
    # Extraction and retention share the exact package bytes verified here; no
    # second file read can substitute a different result after preview.
    with tempfile.TemporaryDirectory(prefix="cellcounter-result-") as directory:
        root = Path(directory)
        (root / "artifacts").mkdir()
        preview_result, child, group, task = _result(store, document, arguments, root)
        if preview_result["previewFingerprint"] != arguments["previewFingerprint"]:
            fail("stale-result-preview", "The package or coordinator revision changed. Preview the result again before collecting it.")
        refs = packages.artifact_references(child, packages.directory_json_reader(root))
        large_checkpoints = {item["checkpointPath"] for item in child.get("models", [])
                             if item.get("backend") in ("cellpose4", "micro-sam")}
        for path, checksum in refs.items():
            store.retain_verified_file(root / path, path, checksum,
                                       maximum_bytes=2 * 1024 ** 3 if path in large_checkpoints else 512 * 1024 ** 2)
        encoded = (canonical(child) + "\n").encode("utf-8")
        if len(encoded) > packages.MAX_METADATA_BYTES:
            fail("distribution-too-large", "The isolated result exceeds the retained metadata bound.")
        snapshot_path, snapshot_hash = store.put_bytes(encoded, ".distributed-result.json")
    result = {"snapshotHash": snapshot_hash, "sourcePackageHash": preview_result["package"]["sha256"],
              "summary": preview_result["summary"], "jobId": preview_result["job"]["id"],
              "sourceProjectId": child["id"], "collectedAt": utc_now(), "revision": revision,
              "collectionMode": "isolated-project", "runtimeDifferences": preview_result["runtimeDifferences"]}
    task.update({"status": "collected", "result": result,
                 "resultSnapshotPath": snapshot_path, "resultSnapshotHash": snapshot_hash,
                 "resultArtifacts": refs, "collectedBy": copy.deepcopy(actor)})
    return {"distribution": describe_group(document, group), "task": _public_task(task), "result": copy.deepcopy(result)}


def prepare_export(store, document, operation, arguments, revision, request_id, actor):
    from _workbench_core import _prepare_export
    from _workbench_store import utc_now
    group = get_group(document, arguments["distributionId"])
    task = get_task(group, arguments["taskId"])
    publications = document.setdefault("distributionPublications", [])
    if len(publications) >= MAX_PUBLICATIONS:
        fail("distribution-limit", "The project supports at most 1,000 distributed package publications.")
    if operation == "distribution.bundle.export":
        _check_coordinator(document, group)
        if task["status"] == "collected":
            fail("task-already-collected", "This task already has a result. Export that isolated result or create a new distribution.")
        child = _load_snapshot(store, task["templatePath"], task["templateHash"])
    else:
        if task["status"] != "collected":
            fail("result-not-collected", "Collect this task's completed result before exporting its isolated project.")
        child = _load_snapshot(store, task["resultSnapshotPath"], task["resultSnapshotHash"])
    exported, publish, temporary = _prepare_export(
        store, child, {"requestId": request_id, "arguments": {"destination": arguments["destination"]}},
        preserve_worker_records=True)
    try:
        publication = {"destination": exported["destination"], "sha256": exported["sha256"]}
        record = {**publication, "exportedAt": utc_now(), "revision": revision,
                  "distributionId": group["id"], "taskId": task["id"], "kind": operation,
                  "actor": copy.deepcopy(actor)}
        publications.append(record)
        if operation == "distribution.bundle.export":
            task["bundle"] = {key: record[key] for key in ("destination", "sha256", "exportedAt", "revision")}
            task["status"] = "bundled"
        return {**exported, "distribution": describe_group(document, group), "task": _public_task(task)}, publish, temporary, publication
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def artifact_references(document):
    references = {}
    for key in ("distributedTask", "distributedExecution"):
        runtime = document.get(key, {}).get("runtime", {})
        if runtime.get("environmentPath"):
            references[runtime["environmentPath"]] = runtime["environmentHash"]
    for group in document.get("distributions", []):
        for task in group["tasks"]:
            references[task["templatePath"]] = task["templateHash"]
            references.update(task["templateArtifacts"])
            if task.get("resultSnapshotPath"):
                references[task["resultSnapshotPath"]] = task["resultSnapshotHash"]
                references.update(task["resultArtifacts"])
    return references


def snapshot_references(document):
    """Bound metadata snapshots that a package reader must validate as data."""
    result = {}
    for group in document.get("distributions", []):
        for task in group["tasks"]:
            result[task["templatePath"]] = (task, False)
            if task.get("resultSnapshotPath"):
                result[task["resultSnapshotPath"]] = (task, True)
    return result


def environment_bindings(document):
    records = []
    for key in ("distributedTask", "distributedExecution"):
        runtime = document.get(key, {}).get("runtime", {})
        if runtime.get("environmentPath"):
            records.append({"inventoryPath": runtime["environmentPath"], "hash": runtime["environment"]["hash"],
                            "summary": copy.deepcopy(runtime["environment"])})
    return records


def validate_document(document):
    from _workbench_schema import WorkbenchError, validate_value
    from _workbench_workflows import operations as workflow_operations
    try:
        groups = _groups(document)
        if len({group["id"] for group in groups}) != len(groups) or sum(len(group["tasks"]) for group in groups) > MAX_TOTAL_TASKS:
            fail("invalid-package", "Distributed group identities or total task counts are invalid.")
        task_ids = set()
        for candidate in groups:
            group = get_group(document, candidate["id"])
            if not 1 <= len(group["tasks"]) <= MAX_TASKS or len(group["tasks"]) != len(group["taskDefinitions"]):
                fail("invalid-package", "The retained distribution has an invalid task count.")
            for record in group["tasks"]:
                task = get_task(group, record["id"])
                if task["id"] in task_ids or task["status"] not in ("pending", "bundled", "collected"):
                    fail("invalid-package", "Task identities must be unique and states supported.")
                task_ids.add(task["id"])
                if task["templatePath"] != f"artifacts/{task['templateHash']}.distributed-template.json":
                    fail("invalid-package", "A task template must be an immutable project snapshot.")
                if not isinstance(task["templateArtifacts"], dict) or len(task["templateArtifacts"]) > 10000:
                    fail("invalid-package", "Task template artifact references exceed their bound.")
                if task["status"] == "collected":
                    if (task["resultSnapshotPath"] != f"artifacts/{task['resultSnapshotHash']}.distributed-result.json" or
                            task["result"]["snapshotHash"] != task["resultSnapshotHash"] or
                            task["result"]["collectionMode"] != "isolated-project" or
                            not isinstance(task["resultArtifacts"], dict) or len(task["resultArtifacts"]) > 10000):
                        fail("invalid-package", "The collected isolated result has inconsistent artifact metadata.")
                elif any(key in task for key in ("result", "resultSnapshotPath", "resultSnapshotHash", "resultArtifacts")):
                    fail("invalid-package", "Only a collected task may retain an isolated result.")
        if len(document.get("distributionPublications", [])) > MAX_PUBLICATIONS:
            fail("invalid-package", "Distributed publication history exceeds its bound.")
        task = _task_definition(document)
        if task:
            if groups:
                fail("invalid-package", "Nested distributed coordinator projects are unsupported.")
            if task["target"] not in ("plane", "volume") or not isinstance(task["localInputs"], (list, RecordList)) or not 1 <= len(task["localInputs"]) <= 33:
                fail("invalid-package", "The portable task source selection is unsupported.")
            if task["requirements"] != requirements(task["workflow"]):
                fail("invalid-package", "The portable task's executable requirements changed.")
            if task["workflow"].get("kind") == "dag":
                from _workbench_graphs import _validate_retained_graph, schemas
                _validate_retained_graph(task["workflow"], schemas()[1])
            else:
                step_schema = workflow_operations()[0]["inputSchema"]["properties"]["steps"]
                validate_value(task["workflow"].get("steps"), step_schema, "task.workflow.steps")
            if document.get("distributedExecution"):
                _bound_job(document, task)
        elif document.get("distributedExecution"):
            fail("invalid-package", "A prepared execution must belong to a portable task.")
    except (TypeError, KeyError, AttributeError, ValueError, WorkbenchError) as exc:
        fail("invalid-package", f"Invalid portable task metadata: {exc}")


def validate_snapshot(document, path, content, manifest, read_json=None):
    """Validate one hash-verified nested project without restoring or executing it."""
    import _workbench_packages as packages
    records = snapshot_references(document)
    if path not in records:
        return
    task, is_result = records[path]
    child = packages._json(content, path)
    if child.get("distributions"):
        fail("invalid-package", "Nested distributed coordinator snapshots are unsupported.")
    refs = packages.artifact_references(child, read_json)
    expected_refs = task["resultArtifacts"] if is_result else task["templateArtifacts"]
    if refs != expected_refs:
        fail("invalid-package", "Isolated snapshot artifact references differ from the coordinator's retained manifest.")
    packages._validate_document(child, refs, read_json)
    definition = _task_definition(child)
    if definition is None or definition["id"] != task["id"] or definition["definitionHash"] != task["definitionHash"]:
        fail("invalid-package", "Isolated snapshot task identity differs from the coordinator record.")
    if is_result:
        _, job, _ = _validate_completed(child, definition)
        if job["id"] != task["result"]["jobId"] or child["id"] != task["result"]["sourceProjectId"]:
            fail("invalid-package", "The retained result does not match its recorded canonical job.")
    elif child.get("distributedExecution") or child.get("jobs"):
        fail("invalid-package", "A task template must not contain a prepared or executed job.")
    for reference, checksum in refs.items():
        if manifest.get(reference) != checksum:
            fail("invalid-package", "The isolated snapshot names an unretained artifact.")
    from _workbench_models import environment_bindings as model_environment_bindings
    from _workbench_refresh import environment_bindings as refresh_environment_bindings
    return [*environment_bindings(child), *model_environment_bindings(child), *refresh_environment_bindings(child)]


def execute(store, document, operation, arguments, revision, actor):
    if operation == "distribution.preview":
        return preview(document, arguments)
    if operation == "distribution.create":
        return create(store, document, arguments, revision, actor)
    if operation == "distribution.list":
        return {"distributions": inspect_groups(document), "limits": limits()}
    if operation == "distribution.get":
        return {"distribution": describe_group(document, get_group(document, arguments["distributionId"]))}
    if operation == "distribution.task.get":
        return {"task": describe_task(document, include_local_runtime=True)}
    if operation == "distribution.task.prepare":
        return prepare_task(store, document, arguments, revision, actor)
    if operation == "distribution.result.preview":
        return _result(store, document, arguments)[0]
    if operation == "distribution.result.collect":
        return collect(store, document, arguments, revision, actor)
    fail("unknown-operation", "Unsupported distributed task operation.")
