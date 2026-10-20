"""Versioned workflows and resumable, one-unit-at-a-time jobs.

Jobs never own worker threads. Each advance is one bounded image computation or
one finalization step, committed with the same revision guard as ordinary edits.
"""
from __future__ import annotations

from _workbench_indexed import image_capacity

from _workbench_indexed import image_index

import copy
import hashlib
import uuid
from collections.abc import Mapping

def operations():
    # Imported here after the base schema helpers exist, avoiding a schema cycle.
    from _workbench_schema import _object, _ID, _STRING, _PARAMETERS, _op
    from _workbench_volume import parameter_schema
    from _workbench_plugins import parameter_values_schema
    from _workbench_assays import catalog as assay_catalog
    from _workbench_preprocessing import recipe_schema
    from _workbench_runtimes import binding_schema
    shared_parameters = _object({**_PARAMETERS["properties"], **parameter_schema()["properties"]})
    for key in ("method", "polarity"):
        shared_parameters["properties"][key] = {"type": "string", "enum": list(dict.fromkeys(
            _PARAMETERS["properties"][key]["enum"] + parameter_schema()["properties"][key]["enum"]))}
    checksum = {"type": "string", "minLength": 64, "maxLength": 64}
    step = _object({
        "type": {"type": "string", "enum": ["preprocessing", "analysis", "volume-analysis", "plugin-segmentation",
                                           "model-segmentation", "plugin-measurement", "assay",
                                           "measurements", "summary", "export"]},
        "parameters": shared_parameters, "destination": _STRING,
        "channel": {"type": "integer", "minimum": 0, "maximum": 31},
        "pluginId": _ID, "pluginParameters": parameter_values_schema(),
        "packageHash": checksum, "pluginRuntimeBinding": binding_schema(),
        "usesExecutableCode": {"type": "boolean"},
        "sourceParameters": _PARAMETERS,
        "target": {"type": "string", "enum": ["plane", "volume"]},
        "modelId": _ID, "modelParameters": model_parameter_schema(),
        "checkpointHash": checksum, "pythonHash": checksum, "pythonPath": _STRING,
        "backend": {"type": "string", "enum": ["cellpose3", "cellpose4", "stardist2d", "omnipose", "micro-sam"]}, "inferenceSchemaHash": checksum,
        "artifactSetHash": checksum, "registrationConfigHash": checksum,
        "environmentHash": checksum,
        "assay": {"type": "string", "enum": [item["id"] for item in assay_catalog()]},
        "assayParameters": parameter_values_schema(), "assayDefinitionHash": checksum,
        "recipe": recipe_schema(), "engineVersion": {"type": "string", "maxLength": 100},
    }, ["type"])
    return [
        _op("workflow.save", "Save an immutable preprocessing, segmentation, assay, measurement, summary and optional export workflow.",
            _object({"workflowId": _ID, "name": {"type": "string", "minLength": 1, "maxLength": 200},
                     "steps": {"type": "array", "items": step, "minItems": 3, "maxItems": 20}},
                    ["name", "steps"]), True),
        _op("workflow.get", "Read one saved workflow version.",
            _object({"workflowId": _ID, "version": {"type": "integer", "minimum": 1}}, ["workflowId"])),
        _op("workflow.list", "List the latest version of every saved workflow.", _object()),
        _op("job.create", "Create durable per-image checkpoints from an immutable workflow version.",
            _object({"workflowId": _ID, "workflowVersion": {"type": "integer", "minimum": 1},
                     "imageIds": {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000},
                     "timeIndices": {"type": "array", "items": {"type": "integer", "minimum": 0},
                                     "minItems": 1, "maxItems": 1000},
                     "exportDestination": _STRING}, ["workflowId", "imageIds"]), True),
        _op("job.get", "Read one job, its immutable workflow and exact checkpoints.",
            _object({"jobId": _ID}, ["jobId"])),
        _op("job.list", "List resumable workflow jobs.", _object()),
        *[_op("job." + name, description, _object({
            "jobId": _ID, **({"reason": {"type": "string", "minLength": 1, "maxLength": 500},
                             "controlRequestId": _ID} if name == "pause" else {}),
        }, ["jobId"]), True)
          for name, description in (
              ("advance", "Execute and commit the next bounded image or finalization unit."),
              ("pause", "Pause before the next unit; existing checkpoints remain durable."),
              ("resume", "Resume a paused job after checking that its source inputs and corrections are unchanged."),
              ("retry", "Retry a failed unit without repeating completed checkpoints."),
              ("cancel", "Cancel future units while preserving completed analyses and checkpoints."),
          )],
    ]


def _error(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def model_parameter_schema(backend=None):
    """Use the same controls as direct inference, without a parallel schema."""
    from _workbench_models import inference_schema
    return inference_schema(backend)


def _freeze_model(document, step):
    from _workbench_models import _model, parameters_for_model, model_schema_hash, active_environment_hash, binding_fields
    model = _model(document, step["modelId"])
    if not model.get("pythonPath") or not model.get("pythonHash"):
        _error("model-runtime-required", "Bind a local interpreter before saving this model in a workflow.")
    result = copy.deepcopy(step)
    for key in ("checkpointHash", "pythonHash", "pythonPath"):
        if key in step and step[key] != model[key]:
            _error("model-changed", "The workflow names a different checkpoint or interpreter binding.")
        result[key] = model[key]
    result.update({
        "usesExecutableCode": True,
        "modelParameters": parameters_for_model(model, step.get("modelParameters")),
    })
    bindings = {"backend": model["backend"], "inferenceSchemaHash": model_schema_hash(model), **binding_fields(model)}
    if any(key in step and key not in bindings for key in ("artifactSetHash", "registrationConfigHash")):
        _error("model-changed", "Compound model identities apply only to the exact registered specialist model.")
    if any(step.get(key, value) != value for key, value in bindings.items()):
        _error("model-changed", "The selected model backend or inference controls changed. Save a new workflow version.")
    result.update(bindings)
    environment_hash = active_environment_hash(model)
    if "environmentHash" in step and step["environmentHash"] != environment_hash:
        _error("model-environment-changed", "The workflow's observed model environment is no longer active. Capture the intended environment and save a new workflow version.")
    if environment_hash is not None:
        result["environmentHash"] = environment_hash
    return result


def _assay_definition(assay_id):
    from _workbench_assays import catalog
    for definition in catalog():
        if definition["id"] == assay_id:
            return definition
    _error("invalid-workflow", "The workflow assay is unavailable in this runtime.")


def _freeze_assay(step, dimensions):
    from _workbench_plugins import validate_parameters
    definition = _assay_definition(step["assay"])
    if dimensions not in definition["dimensions"]:
        _error("invalid-workflow", "This assay does not support the workflow's source dimensions.")
    definition_hash = _digest(definition)
    if step.get("assayDefinitionHash", definition_hash) != definition_hash:
        _error("assay-changed", "The saved assay's controls or supported dimensions have changed.")
    return {
        **copy.deepcopy(step), "assayDefinitionHash": definition_hash,
        "assayParameters": validate_parameters({"parameters": definition["parameters"]}, step.get("assayParameters")),
    }


def execute_model_step(store, document, step, checkpoint, revision):
    from _workbench_models import _model, execute, model_schema_hash, active_environment_hash, binding_fields
    model = _model(document, step["modelId"])
    if any(model[key] != step[key] for key in ("checkpointHash", "pythonHash", "pythonPath")):
        _error("model-changed", "The workflow's checkpoint or interpreter binding changed. Save a new workflow version.")
    if (step.get("backend", model["backend"]) != model["backend"] or
            step.get("inferenceSchemaHash", model_schema_hash(model)) != model_schema_hash(model) or
            any(step.get(key) != value for key, value in binding_fields(model).items())):
        _error("model-changed", "The workflow's model backend or inference controls changed. Save a new workflow version.")
    if "environmentHash" in step and step["environmentHash"] != active_environment_hash(model):
        _error("model-environment-changed", "The saved workflow's observed model environment changed. Restore its recorded binding or create a new workflow/job explicitly.")
    # Direct inference verifies enabled state, checkpoint bytes and interpreter
    # bytes immediately before invoking the registered runtime.
    return execute(store, document, "model.run", {
        "modelId": step["modelId"], "imageId": checkpoint["imageId"],
        "parameters": step["modelParameters"], "sourceParameters": step["sourceParameters"],
    }, revision)


def execute_assay_step(store, document, step, checkpoint, revision):
    from _workbench_assays import execute
    if _digest(_assay_definition(step["assay"])) != step["assayDefinitionHash"]:
        _error("assay-changed", "The saved assay's controls or supported dimensions have changed.")
    args = {"imageId": checkpoint["imageId"], "assay": step["assay"],
            "parameters": step["assayParameters"],
            "target": "volume" if "timeIndex" in checkpoint else "plane"}
    if "timeIndex" in checkpoint:
        args.update({key: checkpoint[key] for key in ("timeIndex", "channel")})
    elif _assay_definition(step["assay"]).get("requiresAnalysis", True) is False:
        selection = checkpoint.get("workingSelection", checkpoint.get("sourceSelection"))
        if selection: args["sourceParameters"] = {key: selection[key] for key in ("channel", "zProjection")}
    return execute(store, document, "assay.run", args, revision)


def assay_outputs_current(document, checkpoint, runs=None):
    from _workbench_assays import _current
    runs = runs if runs is not None else {run["runId"]: run for run in document.get("assayRuns", [])}
    for result in checkpoint.get("stepResults", []):
        if "assayRunId" not in result:
            continue
        run = runs.get(result["assayRunId"])
        if (run is None or run["outputHash"] != result["outputHash"] or
                run["inputFingerprint"] != result["inputFingerprint"] or not _current(document, run)):
            return False
    return True


def _reference_inputs(document, workflow, image_ids):
    """Freeze every declared paired-mask input outside the job's own outputs."""
    from _workbench_assays import _fingerprint
    references = {}
    for step in workflow['steps']:
        if step['type'] != 'assay': continue
        for argument in _assay_definition(step['assay']).get('imageReferenceArguments', []):
            image_id = step['assayParameters'][argument]
            if image_id in image_ids: _error('invalid-workflow', 'A paired reference mask must be separate from images this job segments.')
            reference = _image(document, image_id); analysis = reference.get('analysis')
            if not analysis: _error('analysis-required', 'Analyze the paired reference mask before creating this workflow job.')
            first = segmentation_step(workflow)
            source_parameters = first.get('sourceParameters', first.get('parameters', {}))
            for target_id in image_ids:
                target = _image(document, target_id)
                if target['sourceHash'] != reference['sourceHash'] or source_parameters['zProjection'] != analysis['parameters']['zProjection']:
                    _error('source-mismatch', 'Every job image and paired reference must use identical source bytes and Z projection.')
            references[image_id] = {'imageId': image_id, 'target': 'plane', 'fingerprint': _fingerprint(reference, {'target': 'plane'})}
    return list(references.values())


def stale_reference_ids(document, job):
    from _workbench_assays import _fingerprint
    images = image_index(document)
    return [item["imageId"] for item in job.get("assayReferenceInputs", [])
            if item["imageId"] not in images or _fingerprint(images[item["imageId"]], item) != item["fingerprint"]]


class _ImageFingerprints(Mapping):
    def __init__(self, document): self.images = image_index(document)
    def __len__(self): return len(self.images)
    def __iter__(self): return iter(self.images)
    def __getitem__(self, identifier): return image_fingerprint(self.images[identifier])


def image_fingerprint(image):
    analysis = image.get("analysis")
    inputs = {
        "sourceHash": image["sourceHash"], "pxPerUm": image["pxPerUm"],
        "analysis": None if analysis is None else {
            key: analysis[key] for key in
            ("inputFingerprint", "analysisRevision", "measurementRevision")
        },
    }
    if "voxelSizeUm" in image:
        inputs["pixelSizeUm"] = {axis: image["voxelSizeUm"].get(axis) for axis in "xy"}
    from _workbench_support import fingerprint
    valid_support = fingerprint(image)
    if valid_support is not None:
        inputs["validSupport"] = valid_support
    return _digest(inputs)


def checkpoint_fingerprint(image, checkpoint):
    selection = checkpoint.get("workingSelection") if image["id"] == checkpoint.get("workingImageId") else None
    if selection is not None and selection["target"] == "volume":
        from _workbench_volume import input_fingerprint
        return input_fingerprint(image, selection["timeIndex"], selection["channel"])
    if selection is None and "timeIndex" in checkpoint:
        from _workbench_volume import input_fingerprint
        return input_fingerprint(image, checkpoint["timeIndex"], checkpoint["channel"])
    return image_fingerprint(image)


def checkpoint_current(images, checkpoint, fingerprints=None):
    """Keep the original input and a processed checkpoint independently current."""
    source = images.get(checkpoint["imageId"])
    if source is None:
        return False
    if "sourceSelection" in checkpoint:
        from _workbench_preprocessing import _source_fingerprint
        if (_source_fingerprint(source, checkpoint["sourceSelection"]) != checkpoint["sourceFingerprint"] or
                checkpoint_fingerprint(source, checkpoint) != checkpoint["inputFingerprint"]):
            return False
    image = images.get(checkpoint.get("workingImageId", checkpoint["imageId"]))
    if image is None:
        return False
    if checkpoint.get("workingImageId"):
        if _digest(image.get("derivation")) != checkpoint["derivedProvenanceFingerprint"]:
            return False
    current = (fingerprints[image["id"]] if fingerprints is not None and "timeIndex" not in checkpoint
               else checkpoint_fingerprint(image, checkpoint))
    return current == checkpoint.get("outputFingerprint", checkpoint["inputFingerprint"])


def _image(document, image_id):
    image = image_index(document).get(image_id)
    if image is None: _error("image-not-found", "A workflow image is no longer part of this project.", {"imageId": image_id})
    return image


def get_workflow(document, workflow_id, version=None):
    versions = [item for item in document.get("workflows", []) if item["id"] == workflow_id]
    if not versions:
        _error("workflow-not-found", "Saved workflow does not exist.")
    if version is None:
        return max(versions, key=lambda item: item["version"])
    for item in versions:
        if item["version"] == version:
            return item
    _error("workflow-version-not-found", "Saved workflow version does not exist.")


def get_job(document, job_id):
    from _workbench_indexed import collection_index
    job = collection_index(document, "jobs").get(job_id)
    if job is not None:
        if job["definitionHash"] != _digest(job["workflow"]):
            _error("project-corrupt", "A job's immutable workflow definition has changed.")
        return job
    _error("job-not-found", "Workflow job does not exist.")


def next_unit(job):
    if job.get("kind") == "dag":
        from _workbench_graphs import next_unit as graph_next_unit
        return graph_next_unit(job)
    if job["status"] in ("completed", "cancelled"):
        return None
    for checkpoint in job["checkpoints"]:
        if checkpoint["status"] != "completed":
            steps = execution_steps(job["workflow"])
            index = checkpoint.get("nextStep", 0)
            step = steps[index]
            identity = {key: copy.deepcopy(checkpoint[key]) for key in
                        ("imageId", "timeIndex", "channel", "sourceSelection", "workingImageId", "workingSelection")
                        if key in checkpoint}
            if step["type"] == "preprocessing":
                return {"type": "preprocessing", "stepIndex": index, **identity}
            if step["type"].startswith("plugin-"):
                return {"type": "plugin", "stepIndex": index, **identity}
            if step["type"] in ("model-segmentation", "assay"):
                return {"type": "model" if step["type"] == "model-segmentation" else "assay", "stepIndex": index,
                        **identity}
            if "timeIndex" in checkpoint:
                return {"type": "volume", "stepIndex": index, **identity}
            return {"type": "image", "stepIndex": index, **identity}
    if "summary" not in job:
        return {"type": "summary"}
    if any(step["type"] == "export" for step in job["workflow"]["steps"]) and "export" not in job:
        return {"type": "export"}
    return None


def execution_steps(workflow):
    return [step for step in workflow["steps"] if step["type"] in
            ("preprocessing", "analysis", "volume-analysis", "plugin-segmentation", "model-segmentation",
             "plugin-measurement", "assay")]


def segmentation_step(workflow):
    return next(step for step in workflow["steps"] if step["type"] in
                ("analysis", "volume-analysis", "plugin-segmentation", "model-segmentation"))


def has_preprocessing(workflow):
    return bool(workflow["steps"] and workflow["steps"][0]["type"] == "preprocessing")


def is_volume(workflow):
    if workflow.get("kind") == "dag":
        return workflow["graph"]["target"] == "volume"
    first = segmentation_step(workflow)
    return first["type"] == "volume-analysis" or first.get("target") == "volume"


def execution_checkpoint(checkpoint):
    """Project the durable acquisition checkpoint onto its actual output grid."""
    result = {key: checkpoint[key] for key in ("imageId", "timeIndex", "channel") if key in checkpoint}
    if "workingImageId" in checkpoint:
        result["imageId"] = checkpoint["workingImageId"]
        selected = checkpoint["workingSelection"]
        if selected["target"] == "volume":
            result.update({key: selected[key] for key in ("timeIndex", "channel")})
        else:
            result.pop("timeIndex", None)
            result.pop("channel", None)
    return result


def execution_step(step, checkpoint):
    """Normalize selectors after a recipe has retained one selected channel."""
    result = copy.deepcopy(step)
    if "workingImageId" not in checkpoint:
        return result
    if result["type"] == "analysis":
        result["parameters"].update({"channel": 0, "zProjection": "max"})
    elif result["type"] in ("plugin-segmentation", "model-segmentation"):
        if checkpoint["workingSelection"]["target"] == "plane":
            result["sourceParameters"].update({"channel": 0, "zProjection": "max"})
        else:
            result["channel"] = 0
    elif result["type"] == "volume-analysis":
        result["channel"] = 0
    return result


def execute_preprocessing_step(store, document, step, checkpoint, revision, hooks):
    from _workbench_preprocessing import ENGINE_VERSION, execute
    if step["engineVersion"] != ENGINE_VERSION:
        _error("preprocessing-changed", "The saved preprocessing engine changed. Save a new workflow version before running it.")
    if checkpoint.get("workingImageId"):
        _error("project-corrupt", "This preprocessing checkpoint already has a retained output; it cannot be rerun.")
    selected = checkpoint["sourceSelection"]
    args = {"imageId": checkpoint["imageId"], "recipe": step["recipe"], "target": selected["target"]}
    if selected["target"] == "volume":
        args.update({key: selected[key] for key in ("timeIndex", "channel")})
    else:
        args["sourceParameters"] = {key: selected[key] for key in ("channel", "zProjection")}
    result = execute(store, document, "preprocessing.run", args, revision, hooks)
    image = _image(document, result["derivedImageId"])
    working = ({"target": "volume", "timeIndex": 0, "channel": 0} if selected["target"] == "volume"
               else {"target": "plane", "channel": 0, "zProjection": "max"})
    checkpoint.update({"workingImageId": image["id"], "derivedImageId": image["id"], "workingSelection": working,
                       "derivedProvenanceFingerprint": _digest(image["derivation"])})
    return image, {"sourceImageId": checkpoint["imageId"], "derivedImageId": image["id"],
                   "sourceSelection": copy.deepcopy(selected), "workingSelection": copy.deepcopy(working),
                   "sourceHash": image["derivation"]["sourceHash"], "outputHash": image["sourceHash"],
                   "recipeHash": _digest(step["recipe"]), "engineVersion": ENGINE_VERSION,
                   "validSupport": result["summary"]["validSupport"]}


def complete_step(job, checkpoint, image, result, revision):
    from _workbench_store import utc_now
    steps = execution_steps(job["workflow"])
    index = checkpoint.get("nextStep", 0)
    checkpoint.setdefault("stepResults", []).append({"stepIndex": index, "type": steps[index]["type"],
                                                    "completedRevision": revision, **result})
    checkpoint.update({"nextStep": index + 1, "outputFingerprint": checkpoint_fingerprint(image, checkpoint)})
    if index + 1 == len(steps):
        checkpoint.update({"status": "completed", "completedRevision": revision, "completedAt": utc_now()})
    else:
        checkpoint["status"] = "running"


def project_fingerprint(document, image_fingerprints=None):
    from _workbench_volume import calibration, input_fingerprint
    fingerprints = image_fingerprints if image_fingerprints is not None else {
        image["id"]: image_fingerprint(image) for image in document["images"]}
    volume_inputs = {image["id"]: {
        "voxelSizeUm": calibration(image), "timeStepSeconds": image.get("timeStepSeconds"),
        "frames": [input_fingerprint(image, frame["timeIndex"], frame["channel"]) for frame in image.get("volumeFrames", [])],
        "tracks": image.get("volumeTracks", []),
        "lineages": image.get("volumeLineages", []),
        "temporalPropagations": image.get("temporalPropagations", []),
    } for image in document["images"] if image.get("volumeFrames") or image.get("volumeTracks") or image.get("volumeLineages")}
    inputs = {"images": fingerprints, "experimentalDesign": document.get("experimentalDesign", {}),
              "libraryMetadata": {image["id"]: {key: image.get(key) for key in ("name", "notes", "tags", "channelNames", "archived", "sourceLocations")} for image in document["images"]}}
    if volume_inputs:
        inputs["volumes"] = volume_inputs
    for key in ("plugins", "pluginRuns", "adaptationDatasets", "models", "modelCards", "modelActivations", "trainingJobs", "assayRuns", "assaySeriesRuns", "largeSources", "imageExports", "labelImports", "annotations", "sweeps",
                "reviewFlags", "reviewSessions", "displayPresets", "displayPresetImports",
                "distributions", "distributionPublications", "distributedTask", "distributedExecution", "refreshJobs", "legacyMigration", "workspaces", "workspaceOutputs", "collections", "sourceRepairs", "zarrSources", "tiledAnalyses", "statisticsDesigns", "statisticsRuns", "experimentLayouts", "experimentApplications", "acquisitionSessions", "experimentExclusions"):
        if document.get(key):
            inputs[key] = document[key]
    references = {image["id"]: image["adaptationReference"] for image in document["images"]
                  if image.get("adaptationReference")}
    if references:
        inputs["adaptationReferences"] = references
    return _digest(inputs)


def job_progress(job):
    if job.get("kind") == "dag":
        from _workbench_graphs import progress
        return progress(job)
    step_count = len(execution_steps(job["workflow"]))
    count = sum(item.get("nextStep", step_count if item["status"] == "completed" else 0) for item in job["checkpoints"])
    export = any(step["type"] == "export" for step in job["workflow"]["steps"])
    return {"completed": count + int("summary" in job) + int("export" in job),
            "total": len(job["checkpoints"]) * step_count + 1 + int(export)}


def describe_job(job, document, compact=False, image_fingerprints=None, current_project_fingerprint=None):
    if job.get("kind") == "dag":
        from _workbench_graphs import describe
        return describe(job, document, compact, current_project_fingerprint)
    result = copy.deepcopy(job)
    result["nextUnit"] = next_unit(job)
    result["progress"] = job_progress(job)
    fingerprints = image_fingerprints if image_fingerprints is not None else _ImageFingerprints(document)
    images = image_index(document)
    stale = sorted({checkpoint["imageId"] for checkpoint in job["checkpoints"]
                    if not checkpoint_current(images, checkpoint, fingerprints)})
    result["workingImageIds"] = list(dict.fromkeys(checkpoint.get("workingImageId", checkpoint["imageId"])
                                                   for checkpoint in job["checkpoints"]))
    from _workbench_plugins import checkpoint_outputs_current
    from _workbench_indexed import collection_index
    plugin_runs = collection_index(document, "pluginRuns")
    assay_runs = collection_index(document, "assayRuns")
    stale = sorted(set(stale) | {checkpoint["imageId"] for checkpoint in job["checkpoints"]
                                 if not checkpoint_outputs_current(document, checkpoint, plugin_runs) or
                                 not assay_outputs_current(document, checkpoint, assay_runs)})
    result["staleReferenceImageIds"] = stale_reference_ids(document, job)
    export_fingerprint = job.get("export", {}).get("projectInputFingerprint")
    result["exportInputsCurrent"] = (export_fingerprint is None or export_fingerprint ==
                                    (current_project_fingerprint or project_fingerprint(document)))
    result["outputsCurrent"] = not stale and not result["staleReferenceImageIds"] and result["exportInputsCurrent"]
    result["staleImageIds"] = stale
    if compact:
        for key in ("checkpoints", "summary", "export"):
            result.pop(key, None)
    return result


def inspect_jobs(document):
    if not document.get("jobs"): return []
    # Image hashes are shared across jobs; avoid rehashing metadata once for every
    # image in every historical batch during a routine project inspection.
    fingerprints = _ImageFingerprints(document)
    project_inputs = project_fingerprint(document) if any(job.get("export", {}).get("projectInputFingerprint") for job in document.get("jobs", [])) else None
    return [describe_job(job, document, compact=True, image_fingerprints=fingerprints,
                         current_project_fingerprint=project_inputs) for job in document.get("jobs", [])]


def inspect_workflows(document):
    latest = {}
    for workflow in document.get("workflows", []):
        previous = latest.get(workflow["id"])
        if previous is None or workflow["version"] > previous["version"]:
            latest[workflow["id"]] = workflow
    return copy.deepcopy(list(latest.values()))


def check_inputs(document, job):
    """Validate both pending inputs and completed output snapshots before work."""
    if job.get("kind") == "dag":
        from _workbench_graphs import check_inputs as check_graph_inputs
        return check_graph_inputs(document, job)
    from _workbench_plugins import checkpoint_outputs_current
    plugin_runs = {run["runId"]: run for run in document.get("pluginRuns", [])}
    assay_runs = {run["runId"]: run for run in document.get("assayRuns", [])}
    images = image_index(document)
    references = stale_reference_ids(document, job)
    if references:
        _error("stale-job-input", "A paired assay reference mask changed after this job was created.",
               {"imageIds": references})
    for checkpoint in job["checkpoints"]:
        if not checkpoint_current(images, checkpoint):
            _error("stale-job-input", "A source, processed image, calibration, support mask or correction changed after this job checkpoint. Create a new job to use those changes.",
                   {"imageId": checkpoint["imageId"], "workingImageId": checkpoint.get("workingImageId"),
                    "checkpointStatus": checkpoint["status"]})
        if not checkpoint_outputs_current(document, checkpoint, plugin_runs):
            _error("stale-job-input", "A retained plugin output changed after its workflow checkpoint.",
                   {"imageId": checkpoint["imageId"]})
        if not assay_outputs_current(document, checkpoint, assay_runs):
            _error("stale-job-input", "An assay output or one of its source masks changed after its workflow checkpoint.",
                   {"imageId": checkpoint["imageId"]})


def _validated_steps(steps, document):
    from _workbench_schema import absolute_path, analysis_parameters, validate_value, _PARAMETERS
    from _workbench_volume import parameters as volume_parameters
    from _workbench_plugins import freeze_step
    from _workbench_preprocessing import ENGINE_VERSION, normalize_recipe
    types = [step["type"] for step in steps]
    prefix = 1 if types[0] == "preprocessing" else 0
    tail = ["measurements", "summary", "export"] if types[-1] == "export" else ["measurements", "summary"]
    if (len(types) < prefix + 1 + len(tail) or
            types[prefix] not in ("analysis", "volume-analysis", "plugin-segmentation", "model-segmentation") or
            types[-len(tail):] != tail or
            any(kind not in ("plugin-measurement", "assay") for kind in types[prefix + 1:-len(tail)])):
        _error("invalid-workflow", "An optional initial preprocessing recipe precedes analysis, volume-analysis, plugin-segmentation or model-segmentation; optional assay and plugin-measurement nodes then precede measurements, summary and optional export.")
    validated = []
    for step in steps:
        step = copy.deepcopy(step)
        kind = step["type"]
        if kind == "preprocessing":
            if set(step) - {"type", "recipe", "engineVersion"} or "recipe" not in step:
                _error("invalid-workflow", "A preprocessing node needs a recipe only; its source selection comes from segmentation.")
            if step.get("engineVersion", ENGINE_VERSION) != ENGINE_VERSION:
                _error("preprocessing-changed", "The requested preprocessing engine is unavailable. Save a new workflow with the current engine.")
            first = steps[prefix]
            dimensions = 3 if first["type"] == "volume-analysis" or first.get("target") == "volume" else 2
            validated.append({"type": "preprocessing", "recipe": normalize_recipe(step["recipe"], dimensions),
                              "engineVersion": ENGINE_VERSION})
            continue
        if "recipe" in step or "engineVersion" in step:
            _error("invalid-workflow", "A recipe and engineVersion apply only to the initial preprocessing node.")
        if kind == "model-segmentation":
            allowed = {"type", "modelId", "modelParameters", "checkpointHash", "pythonHash",
                       "pythonPath", "usesExecutableCode", "sourceParameters", "backend", "inferenceSchemaHash", "environmentHash", "artifactSetHash", "registrationConfigHash"}
            if set(step) - allowed or "modelId" not in step:
                _error("invalid-workflow", "Model segmentation needs modelId and plane inference controls only.")
            step = _freeze_model(document, step)
            if prefix and any(key.startswith("additionalChannel") for key in step["modelParameters"]):
                _error("incompatible-preprocessing-model", "This recipe retains one selected channel. Multichannel model input requires the original acquisition or an explicitly prepared multichannel source.")
            step["sourceParameters"] = analysis_parameters({"parameters": step.get("sourceParameters", {})})
            validated.append(step)
            continue
        if kind == "assay":
            if set(step) - {"type", "assay", "assayParameters", "assayDefinitionHash"} or "assay" not in step:
                _error("invalid-workflow", "Assay nodes need an assay ID and its declared assayParameters only.")
            frozen = _freeze_assay(step, 3 if is_volume({"steps": validated}) else 2)
            if prefix:
                if frozen["assay"] == "nuclear_cytoplasmic":
                    _error("incompatible-preprocessing-assay", "A preprocessing workflow creates independent images. Run the N:C assay separately after preparing matching processed nuclear and cytoplasmic masks.")
                if frozen["assay"] in ("colocalization", "live_dead"):
                    _error("incompatible-preprocessing-assay", "This recipe retains one selected channel. Run multichannel assays on the original acquisition or a separately prepared multichannel image.")
                for key, value in frozen["assayParameters"].items():
                    if (key == "channel" or key.endswith("_channel") or key.startswith("channel_")) and value != 0:
                        _error("incompatible-preprocessing-assay", "Assays after preprocessing read the processed acquisition's channel 0. Set the assay channel to 0.")
            validated.append(frozen)
            continue
        if kind.startswith("plugin-"):
            allowed = {"type", "pluginId", "pluginParameters", "packageHash", "usesExecutableCode", "pluginRuntimeBinding"}
            if kind == "plugin-segmentation":
                allowed |= {"target", "channel", "sourceParameters"}
            if set(step) - allowed or "pluginId" not in step:
                _error("invalid-workflow", "Plugin nodes require pluginId and their declared plugin controls only.")
            step = freeze_step(document, step)
            if kind == "plugin-segmentation":
                step["target"] = step.get("target", "plane")
                if step["target"] == "plane":
                    if "channel" in step:
                        _error("invalid-workflow", "Plane plugin nodes select channels through sourceParameters.")
                    step["sourceParameters"] = analysis_parameters({"parameters": step.get("sourceParameters", {})})
                else:
                    if "sourceParameters" in step:
                        _error("invalid-workflow", "Volume plugin nodes use channel, without plane sourceParameters.")
                    step["channel"] = step.get("channel", 0)
                dimensions = 3 if step["target"] == "volume" else 2
            else:
                dimensions = 3 if is_volume({"steps": validated}) else 2
            from _workbench_plugins import _record
            if dimensions not in _record(document, step["pluginId"])["manifest"]["supportedDimensions"]:
                _error("invalid-workflow", "Plugin does not support this workflow's source dimensions.")
            validated.append(step)
            continue
        if any(key in step for key in ("pluginId", "pluginParameters", "packageHash", "usesExecutableCode", "pluginRuntimeBinding",
                                       "sourceParameters", "target", "modelId", "modelParameters",
                                       "checkpointHash", "pythonHash", "pythonPath", "assay",
                                       "assayParameters", "assayDefinitionHash", "backend", "inferenceSchemaHash", "environmentHash", "artifactSetHash", "registrationConfigHash")):
            _error("invalid-workflow", "Plugin, model and assay controls apply only to their corresponding nodes.")
        if kind == "analysis":
            if "destination" in step:
                _error("invalid-workflow", "An analysis step cannot have an export destination.")
            validate_value(step.get("parameters", {}), _PARAMETERS, "parameters")
            step["parameters"] = analysis_parameters({"parameters": step.get("parameters", {})})
        elif kind == "volume-analysis":
            step["parameters"] = volume_parameters(step.get("parameters", {}))
            step["channel"] = step.get("channel", 0)
        elif "parameters" in step:
            _error("invalid-workflow", "Only an analysis step may contain segmentation parameters.")
        if kind != "volume-analysis" and "channel" in step:
            _error("invalid-workflow", "Only a volume-analysis step accepts a top-level channel.")
        if kind == "export" and "destination" in step:
            step["destination"] = str(absolute_path(step["destination"], "destination"))
            if not step["destination"].lower().endswith(".zip"):
                _error("invalid-workflow", "A workflow export destination must end in .zip.")
        elif kind != "export" and "destination" in step:
            _error("invalid-workflow", "Only an export step may contain a destination.")
        validated.append(step)
    return validated


def read(document, operation, arguments):
    if operation == "workflow.get":
        return {"workflow": copy.deepcopy(get_workflow(document, arguments["workflowId"], arguments.get("version")))}
    if operation == "workflow.list":
        return {"workflows": inspect_workflows(document)}
    if operation == "job.get":
        return {"job": describe_job(get_job(document, arguments["jobId"]), document)}
    if operation == "job.list":
        return {"jobs": inspect_jobs(document)}
    _error("unknown-operation", "Unknown workflow read operation.")


def apply(document, operation, arguments):
    """Apply metadata mutations. The core executes and commits advance units."""
    from _workbench_store import utc_now
    now = utc_now()
    if operation == "workflow.save":
        versions = document.setdefault("workflows", [])
        if len(versions) >= 1000:
            _error("project-too-large", "A project supports at most 1,000 saved workflow versions.")
        workflow_id = arguments.get("workflowId")
        previous = get_workflow(document, workflow_id) if workflow_id else None
        workflow = {"id": workflow_id or str(uuid.uuid4()), "name": arguments["name"],
                    "version": previous["version"] + 1 if previous else 1,
                    "steps": _validated_steps(arguments["steps"], document), "createdAt": now,
                    "createdRevision": document["revision"] + 1, "execution": "linear"}
        versions.append(workflow)
        return {"workflow": copy.deepcopy(workflow)}
    if operation == "job.create":
        jobs = document.setdefault("jobs", [])
        if len(jobs) >= 1000:
            _error("project-too-large", "A project supports at most 1,000 jobs.")
        image_ids = arguments["imageIds"]
        if len(image_ids) != len(set(image_ids)):
            _error("invalid-arguments", "Job imageIds must be unique.")
        workflow = copy.deepcopy(get_workflow(document, arguments["workflowId"], arguments.get("workflowVersion")))
        if workflow.get("kind") == "dag":
            from _workbench_graphs import create_job
            return create_job(document, workflow, arguments)
        export = next((step for step in workflow["steps"] if step["type"] == "export"), None)
        if "exportDestination" in arguments:
            if export is None:
                _error("invalid-workflow", "This workflow has no export step.")
            from _workbench_schema import absolute_path
            export["destination"] = str(absolute_path(arguments["exportDestination"], "exportDestination"))
        if export is not None:
            from pathlib import Path
            if not export.get("destination"):
                _error("export-destination-required", "Supply exportDestination when creating this job.")
            destination = Path(export["destination"])
            if destination.suffix.lower() != ".zip" or not destination.parent.is_dir():
                _error("invalid-path", "Job export requires a .zip path inside an existing directory.")
            if destination.exists():
                _error("destination-exists", "Choose a new export destination for this job.")
        checkpoints = []
        if is_volume(workflow):
            from _workbench_volume import selection
            for image_id in image_ids:
                image = _image(document, image_id)
                indices = arguments.get("timeIndices", list(range(image.get("timeCount", 1))))
                if len(indices) != len(set(indices)):
                    _error("invalid-arguments", "timeIndices must be unique.")
                for time_index in sorted(indices):
                    channel = segmentation_step(workflow)["channel"]
                    selection(image, time_index, channel)
                    checkpoint = {"imageId": image_id, "timeIndex": time_index, "channel": channel, "status": "pending"}
                    checkpoint["inputFingerprint"] = checkpoint_fingerprint(image, checkpoint)
                    checkpoints.append(checkpoint)
                    if len(checkpoints) > 5000:
                        _error("job-too-large", "A volume job supports at most 5,000 image/time checkpoints.")
        else:
            if "timeIndices" in arguments:
                _error("invalid-arguments", "timeIndices applies only to volume workflows.")
            checkpoints = [{"imageId": image_id, "status": "pending",
                            "inputFingerprint": image_fingerprint(_image(document, image_id))} for image_id in image_ids]
        if has_preprocessing(workflow):
            from _workbench_preprocessing import _source_fingerprint
            if len(document["images"]) + len(checkpoints) > image_capacity(document):
                _error("project-too-large", "This recipe retains one new acquisition per image/frame checkpoint. Reduce the job inputs to stay within 1,000 project acquisitions.")
            first = segmentation_step(workflow)
            for checkpoint in checkpoints:
                image = _image(document, checkpoint["imageId"])
                if "timeIndex" in checkpoint:
                    selected = {"target": "volume", "timeIndex": checkpoint["timeIndex"], "channel": checkpoint["channel"]}
                else:
                    params = first.get("sourceParameters", first.get("parameters", {}))
                    selected = {"target": "plane", "channel": params["channel"], "zProjection": params["zProjection"]}
                checkpoint.update({"sourceImageId": image["id"], "sourceSelection": selected,
                                   "sourceFingerprint": _source_fingerprint(image, selected)})
        job = {"id": str(uuid.uuid4()), "name": workflow["name"], "status": "pending",
               "workflow": workflow, "definitionHash": _digest(workflow),
               "imageIds": list(image_ids), "createdAt": now, "updatedAt": now,
               "createdRevision": document["revision"] + 1,
               "checkpoints": checkpoints}
        reference_inputs = _reference_inputs(document, workflow, image_ids)
        if reference_inputs:
            job["assayReferenceInputs"] = reference_inputs
        jobs.append(job)
        return {"job": describe_job(job, document)}
    job = get_job(document, arguments["jobId"])
    action = operation.split(".")[1]
    allowed = {
        "pause": ("pending", "running"),
        "resume": ("paused",),
        "retry": ("failed", "blocked") if job.get("kind") == "dag" else ("failed",),
        "cancel": ("pending", "running", "paused", "blocked", "failed", "awaiting-review"),
    }
    if action not in allowed or job["status"] not in allowed[action]:
        _error("invalid-job-state", f"Cannot {action} a {job['status']} job.")
    if action in ("resume", "retry"):
        check_inputs(document, job)
        job["status"] = "running"
        job.pop("error", None)
    else:
        job["status"] = "paused" if action == "pause" else "cancelled"
        if action == "pause":
            job["pausedReason"] = arguments.get("reason", "Requested by the client")
            if "controlRequestId" in arguments:
                job["pauseControlRequestId"] = arguments["controlRequestId"]
    job["updatedAt"] = now
    return {"job": describe_job(job, document)}
