"""Image-level assay metrics and descriptive biological-specimen summaries."""
from __future__ import annotations

import copy
import hashlib
import json
import math
import re
import statistics

MAX_OUTPUT_BYTES = 16 * 1024 ** 2
MAX_READ_BYTES = 256 * 1024 ** 2
MAX_METRICS = 256
MAX_DEPTH = 6
MAX_FIELDS = 4096
_SEGMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# Arrays are never traversed. These dictionary/scalar fields describe settings
# or individual objects rather than an image-level assay outcome.
_EXCLUDED = frozenset({
    "parameters", "params_used", "channelMap", "channel", "channel_a", "channel_b",
    "dna_channel", "live_channel", "dead_channel", "threshold", "thresholds",
    "threshold_a", "threshold_b", "live_threshold", "dead_threshold",
    "threshold_detail", "live_threshold_detail", "dead_threshold_detail",
    "gate_width", "gates", "histogram", "measurements", "per_cell", "cells",
    "spots", "objects", "labels", "schemaVersion", "validSupport", "supportCrop", "sourceSelection",
})


def operations():
    from _workbench_schema import _object, _op, _ID
    return [
        _op("assay.metrics", "List finite scalar image-summary metrics from one retained assay output.",
            _object({"runId": _ID}, ["runId"])),
        _op("experiment.assay.summary",
            "Average compatible current assay values within specimens, then equally weight complete biological specimens.",
            _object({
                "runId": _ID, "metricPath": {"type": "string", "minLength": 1, "maxLength": 200},
                "imageIds": {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000},
            }, ["runId", "metricPath"])),
    ]


def _fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _canonical(value):
    from _workbench_store import canonical
    return canonical(value)


def _finite(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _selection(run):
    result = {"target": run.get("target", "plane")}
    if result["target"] == "volume":
        args = run["arguments"]
        result.update({key: args[key] for key in ("timeIndex", "channel")})
    elif "sourceParameters" in run.get("arguments", {}):
        result["sourceParameters"] = copy.deepcopy(run["arguments"]["sourceParameters"])
    return result


def _signature(run):
    # Saved assay parameters already contain their declared defaults. Treat a
    # numeric JSON spelling such as 0 versus 0.0 as the same configured value.
    parameters = {key: float(value) if type(value) in (int, float) else value
                  for key, value in run["parameters"].items()}
    return _canonical({"assay": run["assay"], "parameters": parameters, **_selection(run)})


def _output_notes(output):
    notes = output.get("notes", [])
    notes = [item[:1000] for item in notes[:24] if isinstance(item, str)] if isinstance(notes, list) else []
    for key in ("message", "caveat", "definition", "convention"):
        value = output.get(key)
        if isinstance(value, str) and value:
            notes.append(value[:1000])
    return list(dict.fromkeys(notes))


def _extract(output):
    fields, units = {}, {}
    visited = 0
    truncated = False

    def walk(value, path=(), depth=0):
        nonlocal visited, truncated
        if not isinstance(value, dict):
            return
        if depth > MAX_DEPTH:
            truncated = True
            return
        for key in sorted(value):
            visited += 1
            if visited > MAX_FIELDS:
                truncated = True
                return
            if not isinstance(key, str) or not _SEGMENT.fullmatch(key):
                continue
            child = value[key]
            joined = ".".join((*path, key))
            if len(joined) > 200:
                truncated = True
                continue
            if key.lower().endswith(("unit", "units")):
                # Unit declarations may be strings, numeric scales, or small
                # dictionaries; retain their exact finite JSON identity.
                if not isinstance(child, list):
                    try:
                        encoded = _canonical(child)
                    except (ValueError, TypeError):
                        encoded = None
                    if encoded is not None and len(encoded) <= 4096:
                        units[joined] = copy.deepcopy(child)
                continue
            if key in _EXCLUDED:
                continue
            if isinstance(child, dict):
                walk(child, (*path, key), depth + 1)
            elif child is None or type(child) in (int, float):
                if len(fields) >= MAX_METRICS:
                    truncated = True
                    continue
                fields[joined] = child
            # Lists, booleans and strings cannot become aggregate metrics.

    walk(output)
    return {"fields": fields, "units": units, "notes": _output_notes(output), "truncated": truncated}


class _Context:
    def __init__(self, store, document):
        self.store, self.document = store, document
        from _workbench_indexed import image_index
        self.images = image_index(document)
        self.output_cache = {}
        self.artifact_cache = {}
        self.fingerprints = {}
        self.read_bytes = 0
        self.recipe_cache = {}

    def output(self, run):
        key = run["outputPath"], run["outputHash"]
        if key in self.output_cache:
            return self.output_cache[key]
        path = self.store.artifact_path(key[0])
        size = path.stat().st_size
        if size > MAX_OUTPUT_BYTES:
            _fail("invalid-assay-output", "A retained assay output exceeds its 16 MiB limit.")
        if self.read_bytes + size > MAX_READ_BYTES:
            _fail("assay-summary-limit", "Selected assay outputs exceed the 256 MiB read budget. Select fewer imageIds.")
        with path.open("rb") as stream:
            data = stream.read(MAX_OUTPUT_BYTES + 1)
        self.read_bytes += len(data)
        if len(data) > MAX_OUTPUT_BYTES or hashlib.sha256(data).hexdigest() != key[1]:
            _fail("artifact-changed", "A retained assay output no longer matches its recorded hash.")
        try:
            def reject_constant(value):
                raise ValueError(value)
            output = json.loads(data, parse_constant=reject_constant)
        except (ValueError, UnicodeError, RecursionError):
            _fail("invalid-assay-output", "The retained assay output is not bounded valid JSON.")
        if not isinstance(output, dict):
            _fail("invalid-assay-output", "The retained assay output must be a JSON object.")
        result = _extract(output)
        self.output_cache[key] = result
        return result

    def current(self, run):
        from _workbench_assays import _fingerprint
        from _workbench_schema import WorkbenchError
        for dependency in run["dependencies"]:
            image = self.images.get(dependency["imageId"])
            if image is None:
                return False, "A source image or paired reference is no longer present."
            key = (image["id"], dependency.get("target", "plane"),
                   dependency.get("timeIndex"), dependency.get("channel"),
                   dependency.get("rawSourceOnly", False), _canonical(dependency.get("sourceParameters")))
            if key not in self.fingerprints:
                self.fingerprints[key] = _fingerprint(image, dependency)
            if self.fingerprints[key] != dependency["fingerprint"]:
                return False, "The saved assay's source pixels, masks, selection or calibration changed."
            for prefix in ("source", "labels"):
                if prefix + "Path" not in dependency:
                    continue
                artifact = dependency[prefix + "Path"], dependency[prefix + "Hash"]
                if artifact not in self.artifact_cache:
                    try:
                        self.store.verify_artifact(*artifact)
                        self.artifact_cache[artifact] = True
                    except (WorkbenchError, OSError):
                        self.artifact_cache[artifact] = False
                if not self.artifact_cache[artifact]:
                    return False, "A retained source or mask artifact is missing or changed."
        return True, None

    @staticmethod
    def frozen_processing_identity(provenance):
        """Compare the recipe, without treating acquisition IDs as settings."""
        stages = []
        for derivation in provenance["stages"]:
            if derivation.get("kind") == "workspace":
                # Generated coordinate systems and multi-parent workflow bindings
                # are part of method identity; never flatten them to one source.
                stages.append({"kind": "workspace", "engineVersion": derivation["engineVersion"],
                    "runtimeManifestHash": derivation.get("runtimeManifestHash"),
                    "workflow": copy.deepcopy(derivation["workflow"]),
                    "generation": copy.deepcopy(derivation["generation"]),
                    "pixelToWorkspace": copy.deepcopy(derivation["pixelToWorkspace"]),
                    "outputCalibration": copy.deepcopy(derivation.get("outputCalibration")),
                    "parents": [{"selection": copy.deepcopy(parent["binding"].get("selection")),
                                 "region": copy.deepcopy(parent["binding"].get("region")),
                                 "scale": copy.deepcopy(parent["binding"].get("scale")),
                                 "translation": copy.deepcopy(parent["binding"].get("translation")),
                                 "processing": _Context.frozen_processing_identity(parent["processing"]) if parent.get("processing") else None}
                                for parent in derivation.get("parents", [])]})
                continue
            selected = derivation["selection"]
            source_selection = {"target": selected.get("target", "plane")}
            if source_selection["target"] == "volume":
                source_selection.update({key: selected[key] for key in ("timeIndex", "channel")})
            else:
                parameters = selected.get("sourceParameters", selected)
                source_selection.update({key: parameters[key] for key in ("channel", "zProjection")})
                if "timeIndex" in selected:
                    source_selection["timeIndex"] = selected["timeIndex"]
            stage = {"kind": derivation.get("kind", "preprocessing"),
                     "engineVersion": derivation["engineVersion"], "selection": source_selection}
            if stage["kind"] == "registration":
                registration = derivation["registration"]
                stage["registration"] = {key: registration[key] for key in
                                         ("shiftPx", "interpolation", "fillValue", "outputGrid")}
            else:
                stage["recipe"] = derivation["recipe"]
            stages.append(stage)
        return {"intensityUnits": provenance["intensityUnits"], "stages": stages}

    def processing_identity(self, image):
        from _workbench_assays import processing_provenance
        if image["id"] in self.recipe_cache:
            return self.recipe_cache[image["id"]]
        identity = self.frozen_processing_identity(processing_provenance(self.document, image, self.images))
        self.recipe_cache[image["id"]] = identity
        return identity

    def compatibility(self, run, output):
        image = self.images.get(run["imageId"])
        if image is None:
            _fail("image-not-found", "The assay image is no longer part of this project.")
        primary = next((item for item in run["dependencies"] if item["imageId"] == run["imageId"]), None)
        frozen = primary.get("sourceProvenance") if primary else None
        identity = (self.frozen_processing_identity(frozen["processing"]) if frozen
                    else self.processing_identity(image))
        declared = output["units"].get("intensityUnits")
        if declared is not None and declared != identity["intensityUnits"]:
            _fail("invalid-assay-output", "The output intensity units disagree with the image's processing lineage.")
        result = {"units": output["units"], "processing": identity}
        if frozen:
            valid_support = frozen.get("validSupport")
        else:
            from _workbench_support import descriptor
            valid_support = descriptor(image)
        result["supportPolicy"] = (valid_support.get("policy", "exclude-unsupported-samples-v1")
                                   if valid_support else "full-acquired-domain")
        if run.get("target", "plane") == "plane":
            if frozen:
                result["sourceProjection"] = frozen["selection"]["zProjection"]
            elif image.get("analysis"):
                result["sourceProjection"] = image["analysis"]["parameters"]["zProjection"]
        return result


def _find_run(document, run_id):
    for run in document.get("assayRuns", []):
        if run["runId"] == run_id:
            return run
    _fail("assay-not-found", "The selected assay run does not exist.")


def _mean(values):
    if not values:
        return None
    # Scaling first avoids overflow when finite values have a large magnitude.
    scale = max(abs(value) for value in values)
    return 0.0 if scale == 0 else statistics.fmean(value / scale for value in values) * scale


def _sd(values):
    if len(values) < 2:
        return None
    scale = max(abs(value) for value in values)
    result = 0.0 if scale == 0 else statistics.stdev(value / scale for value in values) * scale
    return result if _finite(result) else None


def _metrics(context, run):
    output = context.output(run)
    current, reason = context.current(run)
    notes = list(output["notes"])
    notes.append("Metrics are scalar image summaries; object arrays and parameter controls are excluded.")
    if output["truncated"]:
        notes.append("The metric catalogue is limited to 256 fields, six nested dictionary levels and 200-character paths.")
    if reason:
        notes.append(reason)
    return {
        "runId": run["runId"], "assay": run["assay"], "parameters": copy.deepcopy(run["parameters"]),
        "selection": _selection(run), "current": current,
        "metrics": [{"path": key, "value": value} for key, value in sorted(output["fields"].items()) if _finite(value)],
        "notes": notes,
    }


def _summarize(context, exemplar, args):
    from _workbench_experiments import describe
    from _workbench_schema import WorkbenchError
    metric_path = args["metricPath"]
    if not all(_SEGMENT.fullmatch(segment) for segment in metric_path.split(".")):
        _fail("invalid-metric-path", "Use a dot-separated dictionary path returned by assay.metrics.")
    exemplar_current, reason = context.current(exemplar)
    if not exemplar_current:
        _fail("stale-assay-reference", "Choose a current exemplar assay before comparing its output units and source selection. " + reason)
    reference_output = context.output(exemplar)
    if metric_path not in reference_output["fields"]:
        _fail("metric-not-found", "The selected metric is not an image-summary field of the exemplar assay.")
    reference = context.compatibility(exemplar, reference_output)
    signature = _signature(exemplar)
    selection = _selection(exemplar)
    requested = args.get("imageIds", list(context.images))
    if len(requested) != len(set(requested)):
        _fail("invalid-arguments", "Summary imageIds must be unique.")
    if any(image_id not in context.images for image_id in requested):
        _fail("image-not-found", "Every selected image must belong to this project.")
    scope = set(requested)
    design = describe(context.document)
    from _workbench_experiment_layouts import effective_exclusions
    policy = effective_exclusions(context.document)
    assignments = {item["imageId"]: item["specimenId"] for item in design["assignments"]}
    specimen_ids = {item["id"] for item in design["specimens"]}
    candidate_runs = {}
    for index, run in enumerate(context.document.get("assayRuns", [])):
        if run["imageId"] in scope and _signature(run) == signature:
            candidate_runs.setdefault(run["imageId"], []).append((run.get("revision", 0), index, run))
    rows = []
    for image_id in requested:
        image = context.images[image_id]
        specimen_id = assignments.get(image_id)
        row = {"imageId": image_id, "name": image["name"], "status": "missing",
               "assignmentStatus": "assigned" if specimen_id in specimen_ids else "unassigned"}
        if specimen_id in specimen_ids:
            row["specimenId"] = specimen_id
        for key in ("variantOf", "variantRootId", "sourceRegion"):
            if key in image:
                row[key] = copy.deepcopy(image[key])
        if image.get("derivation"):
            row["derivedFromImageId"] = image["derivation"]["sourceImageId"]
        exclusion = policy["image"].get(image_id) or policy["specimen"].get(specimen_id)
        if exclusion:
            row.update({"status": "excluded", "reason": exclusion["reason"], "exclusion": exclusion})
            rows.append(row)
            continue
        candidates = sorted(candidate_runs.get(image_id, []), key=lambda item: item[:2], reverse=True)
        selected_run = None
        for _, _, candidate in candidates:
            current, reason = context.current(candidate)
            if current:
                selected_run = candidate
                break
            row.update({"status": "stale", "reason": reason})
        if selected_run is None:
            row.setdefault("reason", "No saved assay matches the exemplar's parameters and exact selection.")
            rows.append(row)
            continue
        row["runId"] = selected_run["runId"]
        try:
            output = context.output(selected_run)
            comparable = context.compatibility(selected_run, output)
            if _canonical(comparable) != _canonical(reference):
                row.update({"status": "incompatible",
                            "reason": "Output units, source projection, support policy or the complete processing recipe differ from the exemplar."})
            elif metric_path not in output["fields"]:
                row.update({"status": "missing-metric", "reason": "The selected current assay has no matching image-summary field."})
            elif not _finite(output["fields"][metric_path]):
                row.update({"status": "nonfinite-metric", "reason": "The selected current assay metric is missing or non-finite."})
            else:
                row.update({"status": "measured", "value": output["fields"][metric_path]})
                row.pop("reason", None)
        except (WorkbenchError, OSError) as exc:
            if isinstance(exc, WorkbenchError) and exc.code == "assay-summary-limit":
                raise
            row.update({"status": "invalid-output", "reason": str(exc)})
        rows.append(row)
    rows_by_specimen = {}
    assigned_counts = {}
    for image_id, specimen_id in assignments.items():
        if image_id in context.images and image_id not in policy["image"]:
            assigned_counts[specimen_id] = assigned_counts.get(specimen_id, 0) + 1
    for row in rows:
        if "specimenId" in row:
            rows_by_specimen.setdefault(row["specimenId"], []).append(row)
    specimens = []
    for specimen in design["specimens"]:
        selected = rows_by_specimen.get(specimen["id"], [])
        if "imageIds" in args and not selected:
            continue
        eligible = [row for row in selected if row["imageId"] not in policy["image"]]
        included = specimen["id"] not in policy["specimen"]
        values = [row["value"] for row in eligible if row["status"] == "measured"]
        image_count = assigned_counts.get(specimen["id"], 0)
        complete = included and image_count > 0 and len(eligible) == image_count and len(values) == image_count
        specimens.append({
            **specimen, "included": included, "exclusionReason": policy["specimen"].get(specimen["id"], {}).get("reason"),
            "excludedImageIds": [row["imageId"] for row in selected if row["imageId"] in policy["image"]], "imageCount": image_count, "selectedImageCount": len(selected),
            "measuredImageCount": len(values), "complete": complete,
            "mean": _mean(values) if complete else None,
        })
    groups = {}
    for specimen in specimens:
        groups.setdefault((specimen["experiment"], specimen["condition"]), []).append(specimen)
    conditions = []
    for (experiment, condition), members in sorted(groups.items()):
        values = [member["mean"] for member in members if member["complete"]]
        conditions.append({
            "experiment": experiment, "condition": condition, "role": members[0]["role"],
            "specimenCount": len(members), "biologicalN": len(values),
            "excludedIncompleteSpecimens": sum(row["included"] and not row["complete"] for row in members),
            "excludedByPolicySpecimens": sum(not row["included"] for row in members),
            "mean": _mean(values), "sd": _sd(values),
            "specimenIds": [member["id"] for member in members],
        })
    notes = [
        "Reasoned specimen/field exclusions enter these inputs explicitly; archiving an image does not exclude it.",
        "Each complete specimen is the equal-weight mean of its assigned image values; conditions equally weight complete specimens.",
        "Biological n counts specimens, never images, objects, mask variants or regions of interest.",
        "Missing, stale, incompatible or non-finite measurements make their specimen incomplete and exclude it from condition statistics.",
        "A specimen selected through imageIds remains incomplete if any of its assigned images are outside that scope.",
        "Unassigned images are listed but never enter specimen or condition statistics; assignment metadata defines replicate identity.",
        "Mask variants, derived images and ROIs retain their explicit image identities; select and assign the intended representation of each observation.",
        "Assay parameters and target/time/channel match exactly. Output units, source projection, support policy and the complete processing recipe must also match.",
        "Condition SD is sample SD between complete specimens, and is unavailable for fewer than two specimens or unrepresentable finite arithmetic.",
        "These are descriptive summaries without inferential tests or automatic field-area, background or acquisition-gain normalization.",
    ]
    if exemplar["assay"] == "nuclear_cytoplasmic":
        notes.append("The nuclearImageId binding is part of exact parameter matching; different nuclear references form separate assay cohorts.")
    return {
        "runId": exemplar["runId"], "assay": exemplar["assay"],
        "parameters": copy.deepcopy(exemplar["parameters"]), "metricPath": metric_path,
        "sourceRevision": context.document["revision"], "selection": selection,
        "inputFingerprint": hashlib.sha256(_canonical({"design": design, "exclusions": policy, "images": rows,
             "runInputs": [{key: run.get(key) for key in ("runId", "outputHash", "dependencies")}
                           for run in context.document.get("assayRuns", []) if run["runId"] in {row.get("runId") for row in rows}],
             "comparison": reference, "metricPath": metric_path, "selection": selection}).encode()).hexdigest(),
        "comparison": reference, "images": rows, "specimens": specimens, "conditions": conditions, "effectiveExclusions": policy,
        "unassignedImageCount": sum(row["assignmentStatus"] == "unassigned" for row in rows),
        "aggregation": "equal-images-within-complete-biological-specimens",
        "notes": notes + reference_output["notes"],
    }


def execute(store, document, operation, args):
    context = _Context(store, document)
    exemplar = _find_run(document, args["runId"])
    if operation == "assay.metrics":
        return _metrics(context, exemplar)
    if operation == "experiment.assay.summary":
        return _summarize(context, exemplar, args)
    _fail("unknown-operation", "Unknown assay summary operation.")
