"""Versioned biological-replicate designs and bounded, explicit inference.

All observations come from retained canonical measurements. This module never
segments pixels, treats objects as biological n, or evaluates a formula string.
"""
from __future__ import annotations

from _workbench_indexed import RecordList

from _workbench_indexed import image_index

import copy
import hashlib
import json
import math
import re
import uuid

ENGINE = "replicate-statistics-1"
LIMITS = {"designs": 100, "versions": 1000, "runs": 1000, "specimens": 1000,
          "factors": 16, "levels": 32, "columns": 64, "contrasts": 64,
          "artifactBytes": 16 * 1024 ** 2}
METRICS = {"count": (None, "objects/image"), "meanAreaPx": ("areaPx", "pixel²"),
           "meanAreaUm2": ("areaUm2", "µm²"), "meanVolumeVox": ("voxelCount", "voxel"),
           "meanVolumeUm3": ("volumeUm3", "µm³"), "meanIntensity": ("meanIntensity", "source intensity")}
NOTES = [
    "One table row is one biological specimen/sample. Subject IDs link samples for pairing; they are not specimen IDs.",
    "Each included specimen equally weights all assigned image values; objects and alternative branches never increase biological n.",
    "Exclusions require an explicit reason. Missing/stale measurements block an included specimen rather than silently removing it.",
    "Subject/block fixed effects are ordinary linear-model coefficients, not random effects or a general repeated-measures covariance model.",
    "Confidence intervals are pointwise. Multiple-testing adjustment applies to the declared result family, not to confidence intervals.",
    "Inference assumes the chosen biological sampling and residual-independence model is appropriate; software cannot establish that assumption.",
]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def definition_schema():
    from _workbench_schema import _object, _ID
    text = {"type": "string", "minLength": 1, "maxLength": 200}
    factor = _object({"id": _ID, "name": text, "kind": {"type": "string", "enum": ["categorical", "numeric"]},
                      "levels": {"type": "array", "items": text, "minItems": 2, "maxItems": 32},
                      "referenceLevel": text, "unit": text}, ["id", "name", "kind"])
    outcome = _object({"kind": {"type": "string", "enum": ["measurement", "assay", "assay-series"]},
                       "metric": {"type": "string", "enum": list(METRICS)},
                       "target": {"type": "string", "enum": ["plane", "volume"]},
                       "timeIndex": {"type": "integer", "minimum": 0, "maximum": 10000},
                       "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                       "runId": _ID, "metricPath": text}, ["kind"])
    row = _object({"specimenId": _ID, "subjectId": _ID, "blockId": _ID,
                   "values": {"type": "object", "properties": {}, "maxProperties": 16,
                              "additionalProperties": {"type": ["string", "number"], "maxLength": 200}}},
                  ["specimenId", "values"])
    return _object({"name": text, "outcome": outcome,
                    "factors": {"type": "array", "items": factor, "minItems": 1, "maxItems": 16},
                    "rows": {"type": "array", "items": row, "minItems": 1, "maxItems": 1000},
                    "exclusions": {"type": "array", "maxItems": 1000, "items":
                                   _object({"specimenId": _ID, "reason": {"type": "string", "minLength": 1, "maxLength": 2000}},
                                           ["specimenId", "reason"])}}, ["name", "outcome", "factors", "rows"])


def analysis_schema():
    from _workbench_schema import _object, _ID
    contrast = _object({"id": _ID, "factorId": _ID, "reference": _ID, "comparison": _ID},
                       ["id", "factorId", "reference", "comparison"])
    return _object({"method": {"type": "string", "enum": ["welch-t", "paired-t", "linear-model"]},
                    "contrasts": {"type": "array", "items": contrast, "maxItems": 64},
                    "terms": {"type": "array", "items": _ID, "maxItems": 16},
                    "interactions": {"type": "array", "maxItems": 32,
                                     "items": {"type": "array", "items": _ID, "minItems": 2, "maxItems": 2}},
                    "blocking": {"type": "string", "enum": ["none", "subject", "block"], "default": "none"},
                    "covariance": {"type": "string", "enum": ["classical", "HC3"], "default": "classical"},
                    "confidenceLevel": {"type": "number", "minimum": .8, "maximum": .999, "default": .95},
                    "multiplicity": {"type": "string", "enum": ["none", "holm", "benjamini-hochberg"], "default": "holm"}}, ["method"])


def operations():
    from _workbench_schema import _object, _op, _ID
    selection = {"designId": _ID, "version": {"type": "integer", "minimum": 1}}
    save = copy.deepcopy(definition_schema())
    save["properties"].update({"designId": _ID, "previewFingerprint": _ID})
    save["required"].append("previewFingerprint")
    result = [_op("statistics.catalogue", "Describe supported replicate designs, inference methods and assumptions.", _object(), project=False),
              _op("statistics.design.preview", "Resolve an explicit design to complete biological-replicate inputs without computing inference.", definition_schema()),
              _op("statistics.design.save", "Freeze a versioned design and its exact specimen-level input table.", save, True),
              _op("statistics.design.get", "Read a saved design, frozen inputs and currentness.", _object(selection, ["designId"])),
              _op("statistics.design.list", "List current design versions without loading retained input tables.", _object()),
              _op("statistics.preview", "Calculate declared inference from a current frozen replicate table without retaining a run.",
                  _object({**selection, "analysis": analysis_schema()}, ["designId", "analysis"])),
              _op("statistics.run", "Retain the preview-bound inference, assumptions, coefficients and plot table.",
                  _object({**selection, "analysis": analysis_schema(), "previewFingerprint": _ID},
                          ["designId", "analysis", "previewFingerprint"]), True),
              _op("statistics.get", "Read a retained statistical result and its exact input table.", _object({"runId": _ID}, ["runId"])),
              _op("statistics.list", "List retained statistical runs and their currentness.", _object())]
    for name, mutate in (("preview", False), ("run", True)):
        props = {"runId": _ID}
        if mutate:
            props["previewFingerprint"] = _ID
        result.append(_op("statistics.recompute." + name,
                          "Resolve the saved design against current measurements and preserve its previous result.",
                          _object(props, list(props)), mutate))
    return result


def catalogue():
    return {"engineVersion": ENGINE, "definitionSchema": definition_schema(), "analysisSchema": analysis_schema(),
            "outcomes": [{"id": key, "units": value[1],
                          "targets": ["volume"] if "Volume" in key else ["plane"] if "Area" in key else ["plane", "volume"]}
                         for key, value in METRICS.items()],
            "seriesOutcomes": [{"metricPath": key, "units": value} for key, value in SERIES_METRICS.items()],
            "methods": [{"id": "welch-t", "name": "Independent Welch contrasts", "assumptions": ["Independent biological specimens", "Approximately normal replicate means; unequal variances allowed"]},
                        {"id": "paired-t", "name": "Paired subject contrasts", "assumptions": ["Independent subjects", "One sample per contrasted level per subject", "Approximately normal within-subject differences"]},
                        {"id": "linear-model", "name": "Typed factorial linear model", "assumptions": ["Full-rank declared design", "Independent residuals", "Classical homoskedastic or HC3 asymptotic variance"]}],
            "limits": copy.deepcopy(LIMITS), "notes": NOTES + ["Mixed/random-effects, permutation and nonparametric methods are not implemented by these operations."]}


def normalize_definition(args):
    from _workbench_schema import validate_value
    value = {key: copy.deepcopy(args[key]) for key in definition_schema()["properties"] if key in args}
    validate_value(value, definition_schema())
    value["name"] = value["name"].strip()
    value.setdefault("exclusions", [])
    factors = {}
    for factor in value["factors"]:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", factor["id"]):
            fail("invalid-statistical-factor", "Factor IDs must start with a letter and contain up to 64 letters, digits or underscores.")
        if factor["id"] in factors:
            fail("duplicate-statistical-factor", "Every factor ID must be unique.")
        factors[factor["id"]] = factor
        if factor["kind"] == "categorical":
            if "levels" not in factor or len(set(factor["levels"])) != len(factor["levels"]):
                fail("invalid-statistical-factor", "Categorical factors require at least two distinct declared levels.")
            factor.setdefault("referenceLevel", factor["levels"][0])
            if factor["referenceLevel"] not in factor["levels"]:
                fail("invalid-statistical-factor", "The reference level must be one of the declared categorical levels.")
        elif "levels" in factor or "referenceLevel" in factor:
            fail("invalid-statistical-factor", "Numeric factors use finite values and an optional unit, without categorical levels.")
    row_ids = set()
    for row in value["rows"]:
        if row["specimenId"] in row_ids:
            fail("duplicate-statistical-specimen", "Use exactly one input row per specimen; pair different samples with subjectId.")
        row_ids.add(row["specimenId"])
        if set(row["values"]) != set(factors):
            fail("incomplete-factor-values", "Every specimen requires exactly one value for each declared factor.")
        for key, factor in factors.items():
            item = row["values"][key]
            if factor["kind"] == "numeric":
                if type(item) not in (int, float) or not math.isfinite(item):
                    fail("invalid-factor-value", f"Factor {key} requires finite numeric specimen values.")
            elif item not in factor["levels"]:
                fail("invalid-factor-value", f"Factor {key} has a specimen value outside its declared levels.")
    excluded = set()
    for row in value["exclusions"]:
        if row["specimenId"] not in row_ids or row["specimenId"] in excluded:
            fail("invalid-statistical-exclusion", "Exclusions must identify distinct specimens in this design.")
        excluded.add(row["specimenId"])
    outcome = value["outcome"]
    if outcome["kind"] == "measurement":
        if "metric" not in outcome or "target" not in outcome or set(outcome) - {"kind", "metric", "target", "timeIndex", "channel"}:
            fail("invalid-statistical-outcome", "Measurement outcomes require metric and target; assay fields are not accepted.")
        if outcome["target"] == "volume":
            outcome.setdefault("timeIndex", 0); outcome.setdefault("channel", 0)
            if "Area" in outcome["metric"]:
                fail("invalid-statistical-outcome", "Area measurements require a plane outcome; use a volume metric for volume objects.")
        elif "Volume" in outcome["metric"] or "timeIndex" in outcome or "channel" in outcome:
            fail("invalid-statistical-outcome", "Plane outcomes use each image's saved plane selector and do not accept time/channel overrides.")
    elif set(outcome) != {"kind", "runId", "metricPath"}:
        fail("invalid-statistical-outcome", "Assay and series outcomes require only kind, runId and metricPath.")
    if outcome["kind"] == "assay-series" and outcome["metricPath"] not in SERIES_METRICS:
        fail("invalid-statistical-outcome", "Choose a declared scratch-series rate metric from statistics.catalogue.")
    return value


def _mean(values):
    if not values:
        return None
    scale = max(abs(value) for value in values)
    result = 0.0 if scale == 0 else math.fsum(value / scale for value in values) / len(values) * scale
    if not math.isfinite(result):
        fail("statistics-numeric-range", "The replicate mean cannot be represented as a finite number.")
    return result


def _root(image, images):
    seen = set()
    while True:
        if image["id"] in seen:
            fail("invalid-acquisition-lineage", "An image's acquisition ancestry contains a cycle.")
        seen.add(image["id"])
        parent = image.get("variantOf") or image.get("derivation", {}).get("sourceImageId")
        if parent and parent in images:
            image = images[parent]
            continue
        region = image.get("sourceRegion", {})
        return ("source:" + str(region["sourceId"])) if region.get("sourceId") else "image:" + image.get("variantRootId", image["id"])


def _dependency(image, outcome, analysis=None):
    from _workbench_assays import _fingerprint
    target = {"target": outcome.get("target", "plane")}
    if outcome.get("rawSourceOnly"):
        target.update({key: copy.deepcopy(outcome[key]) for key in ("rawSourceOnly", "sourceParameters", "timeIndex", "region") if key in outcome})
    if target["target"] == "volume":
        target.update({key: outcome[key] for key in ("timeIndex", "channel")})
    return {"imageId": image["id"], "selection": target, "fingerprint": _fingerprint(image, target),
            "sourceHash": image["sourceHash"], "labelsHash": analysis.get("labelsHash") if analysis else None}


def _reference_images(document, dependencies):
    images = image_index(document)
    refs = {}
    import _workbench_support as support
    for dep in dependencies:
        image = images[dep["imageId"]]
        refs[image["sourcePath"]] = image["sourceHash"]
        if dep.get("labelsHash"):
            candidates = ([image.get("analysis")] if image.get("analysis") else []) + image.get("volumeFrames", [])
            for analysis in candidates:
                if analysis["labelsHash"] == dep["labelsHash"]:
                    refs[analysis["labelsPath"]] = analysis["labelsHash"]
        if support.descriptor(image):
            refs.update(support.artifact_references({"images": [image]}))
    return refs


def _state(document, definition, dependencies):
    """Metadata-only dependency identity; no image decode or artifact read on inspect."""
    from _workbench_assays import _fingerprint
    images = image_index(document)
    design = document.get("experimentalDesign", {})
    ids = {row["specimenId"] for row in definition["rows"]}
    state = {"specimens": [row for row in design.get("specimens", []) if row["id"] in ids],
             "assignments": [row for row in design.get("assignments", []) if row["specimenId"] in ids], "images": []}
    from _workbench_experiment_layouts import effective_exclusions
    policy = effective_exclusions(document)
    involved = {row["imageId"] for row in state["assignments"]}
    state["exclusions"] = {"specimen": {key: value for key, value in policy["specimen"].items() if key in ids},
                           "image": {key: value for key, value in policy["image"].items() if key in involved}}
    for dep in dependencies:
        image = images.get(dep["imageId"])
        state["images"].append({"imageId": dep["imageId"], "fingerprint": _fingerprint(image, dep["selection"]) if image else None})
    # A new matching current assay can supersede a historical measured output.
    if definition["outcome"]["kind"] == "assay":
        from _workbench_assay_summary import _find_run, _signature
        try:
            exemplar = _find_run(document, definition["outcome"]["runId"])
            sig = _signature(exemplar)
            involved = {row["imageId"] for row in state["assignments"]}
            state["assays"] = [{key: run.get(key) for key in ("runId", "imageId", "outputHash", "dependencies", "replacementRunId")}
                               for run in document.get("assayRuns", []) if run["imageId"] in involved and _signature(run) == sig]
        except Exception:
            state["assays"] = None
    if definition["outcome"]["kind"] == "assay-series":
        import _workbench_assay_series as series
        try:
            signature = _series_signature(series._find(document, definition["outcome"]["runId"]))
            state["series"] = [{key: run.get(key) for key in ("runId", "outputHash", "dependencies", "specimen", "predecessorRunId")}
                               for run in document.get("assaySeriesRuns", []) if _series_signature(run) == signature
                               and any(dep["imageId"] in involved for dep in run["dependencies"])]
        except (KeyError, ValueError):
            state["series"] = None
    return digest(state)


SERIES_METRICS = {
    "rates.gapAreaPx.slopePerSecond": "px²/s",
    "rates.gapAreaUm2.slopePerSecond": "µm²/s",
    "rates.closureFraction.slopePerSecond": "1/s",
}


def _series_signature(run):
    """Method/time-window identity, without using specimen or source IDs as settings."""
    from _workbench_assay_summary import _Context
    frames = run["arguments"]["frames"]
    origin = next((row["timeSeconds"] for row in frames if row["timeSeconds"] is not None), 0)
    return digest({"engine": run["engineVersion"], "parameters": run["parameters"], "baselineIndex": run["baselineIndex"],
                   "frames": [{"timeSeconds": row["timeSeconds"] - origin if row["timeSeconds"] is not None else None,
                               "measured": "imageId" in row, "sourceParameters": row.get("sourceParameters"),
                               "regionExtent": {key: row.get("region", {}).get(key) for key in ("width", "height")}}
                              for row in frames],
                   "sources": [{"calibration": dep["sourceProvenance"]["calibration"],
                                "processing": _Context.frozen_processing_identity(dep["sourceProvenance"]["processing"])}
                               for dep in run["dependencies"]]})


def _resolve_series(store, document, definition):
    """One retained series rate per biological specimen, never one row per frame."""
    import _workbench_assay_series as series
    from _workbench_experiment_layouts import effective_exclusions
    from _workbench_schema import WorkbenchError
    images = image_index(document)
    experiment = document.get("experimentalDesign", {})
    specimens = {row["id"]: row for row in experiment.get("specimens", [])}
    assignments = {row["imageId"]: row["specimenId"] for row in experiment.get("assignments", [])}
    policy = effective_exclusions(document)
    exclusions = {key: value["reason"] for key, value in policy["specimen"].items()}
    exclusions.update({row["specimenId"]: row["reason"] for row in definition["exclusions"]})
    outcome = definition["outcome"]
    exemplar = series._find(document, outcome["runId"])
    signature = _series_signature(exemplar)
    runs = document.get("assaySeriesRuns", [])
    replaced = {run["predecessorRunId"] for run in runs if run.get("predecessorRunId")}
    latest = {}
    for run in runs:
        if run["runId"] not in replaced and _series_signature(run) == signature:
            latest[digest({key: value for key, value in run["arguments"].items() if key != "name"})] = run
    groups = {}
    for run in latest.values():
        identities = {assignments.get(dep["imageId"]) for dep in run["dependencies"]}
        for identity in identities - {None}:
            groups.setdefault(identity, []).append(run)
    rows, image_rows, dependencies, refs, blockers = [], [], [], {}, []
    coverage = None; read_bytes = 0; verified = set()
    for entry in definition["rows"]:
        identifier = entry["specimenId"]
        row = {**copy.deepcopy(entry), "name": specimens.get(identifier, {}).get("name", identifier),
               "included": identifier not in exclusions, "value": None, "imageIds": [], "excludedImageIds": [], "observationKind": "one-series-rate"}
        rows.append(row)
        if not row["included"]:
            row["reason"] = exclusions[identifier]; continue
        try:
            if identifier not in specimens: fail("specimen-not-found", "The design refers to an unknown biological specimen.")
            candidates = groups.get(identifier, [])
            if len(candidates) != 1:
                fail("series-selection-required", "Each included specimen requires exactly one latest compatible series; missing or multiple distinct series must be resolved explicitly.", {"specimenId": identifier, "runIds": [run["runId"] for run in candidates]})
            run = candidates[0]
            row["runId"] = run["runId"]
            row["imageIds"] = list(dict.fromkeys(dep["imageId"] for dep in run["dependencies"]))
            row["excludedImageIds"] = [item for item in row["imageIds"] if item in policy["image"]]
            row["otherAssignedImageIds"] = [image_id for image_id, specimen_id in assignments.items() if specimen_id == identifier and image_id not in row["imageIds"]]
            if not series.current(document, run) or not run["specimen"].get("inferentiallyEligible") or run["specimen"].get("specimen", {}).get("id") != identifier:
                fail("incomplete-series-input", "The series is stale, excluded or does not belong to one coherent specimen. Refresh or correct its explicit assignments first.")
            path = store.verify_artifact(run["outputPath"], run["outputHash"])
            read_bytes += path.stat().st_size
            if read_bytes > 256 * 1024 ** 2: fail("statistics-input-limit", "Selected series reports exceed 256 MiB; use a smaller specimen cohort.")
            output = series.read_output(store, run)
            candidate = {key: output["commonSupport"][key] for key in ("shape", "samples", "policy")}
            candidate["measuredExtent"] = {key: output["commonSupport"]["sourceRegion"][key] for key in ("width", "height")}
            candidate["measuredAreaUm2"] = output["commonSupport"].get("areaUm2")
            if coverage is not None and candidate != coverage:
                fail("incompatible-series-coverage", "Series rate comparisons require the same measured grid/physical extent and coverage policy; absolute field origins may differ.")
            coverage = candidate
            value = output
            for key in outcome["metricPath"].split("."): value = value[key]
            if type(value) not in (int, float) or not math.isfinite(value):
                fail("series-rate-unavailable", "This series has no finite rate for the requested metric; inspect its known-time points, baseline and calibration.")
            row["value"] = value
            row["seriesCoverage"] = copy.deepcopy(output["commonSupport"])
            refs.update(series.artifact_references({"assaySeriesRuns": [run]}))
            for dep in run["dependencies"]:
                for prefix in ("source", "support"):
                    if prefix + "Path" in dep:
                        key = dep[prefix + "Path"], dep[prefix + "Hash"]
                        if key not in verified: store.verify_artifact(*key); verified.add(key)
                dependencies.append(_dependency(images[dep["imageId"]], dep))
            image_rows.extend({"imageId": frame["imageId"], "runId": run["runId"], "seriesIndex": frame["index"],
                               "timeSeconds": frame["timeSeconds"], "status": "series-observation", "value": None,
                               "note": "Repeated observation; does not contribute an independent replicate."}
                              for frame in output["frames"] if frame.get("imageId"))
        except (WorkbenchError, OSError, KeyError) as exc:
            row["reason"] = str(exc)
            blockers.append({"specimenId": identifier, "code": getattr(exc, "code", "invalid-series-input"), "message": str(exc)})
    if sum(row["included"] for row in rows) < 2:
        blockers.append({"code": "insufficient-specimens", "message": "At least two included biological specimens are required."})
    dependencies = list({digest({"imageId": dep["imageId"], "selection": dep["selection"]}): dep for dep in dependencies}.values())
    state_hash = _state(document, definition, dependencies)
    involved = {image_id for row in rows for image_id in row["imageIds"]}
    table = {"schemaVersion": 1, "engineVersion": ENGINE, "definition": definition, "rows": rows, "imageRows": image_rows,
             "blockers": blockers, "ready": not blockers, "units": SERIES_METRICS[outcome["metricPath"]],
             "comparison": {"seriesSignature": signature, "commonSupport": coverage, "aggregation": "one-current-series-rate-per-biological-specimen"},
             "dependencies": dependencies, "dependencyFingerprint": state_hash,
             "notes": NOTES + ["Only one series rate per specimen enters inference. Its frames and other assigned images never increase n; incompatible time schedules or coverage block the design."],
             "effectiveExclusions": {"specimen": {key: value for key, value in policy["specimen"].items() if key in {row["specimenId"] for row in definition["rows"]}},
                                     "image": {key: value for key, value in policy["image"].items() if key in involved}},
             "inputReferences": [{"path": path, "hash": checksum} for path, checksum in sorted(refs.items())]}
    table["inputFingerprint"] = digest({key: table[key] for key in ("definition", "rows", "imageRows", "dependencies", "dependencyFingerprint", "comparison", "units")})
    table["previewFingerprint"] = digest({"revision": document["revision"], "inputFingerprint": table["inputFingerprint"], "blockers": blockers})
    return table


def resolve(store, document, definition):
    if definition["outcome"]["kind"] == "assay-series":
        return _resolve_series(store, document, definition)
    from _workbench_schema import WorkbenchError
    from _workbench_assays import processing_provenance
    from _workbench_assay_summary import _Context, _find_run, _summarize
    from _workbench_core import _current_analysis
    from _workbench_volume import current_frame
    images = image_index(document)
    experiment = document.get("experimentalDesign", {})
    specimens = {row["id"]: row for row in experiment.get("specimens", [])}
    assigned = {}
    for item in experiment.get("assignments", []):
        assigned.setdefault(item["specimenId"], []).append(item["imageId"])
    from _workbench_experiment_layouts import effective_exclusions
    policy = effective_exclusions(document)
    exclusions = {key: value["reason"] for key, value in policy["specimen"].items()}
    exclusions.update({row["specimenId"]: row["reason"] for row in definition["exclusions"]})
    excluded_fields = policy["image"]
    selected_ids = [identifier for row in definition["rows"] if row["specimenId"] not in exclusions
                    for identifier in assigned.get(row["specimenId"], []) if identifier not in excluded_fields]
    outcome, image_rows, dependencies, refs, blockers = definition["outcome"], [], [], {}, []
    assay_summary = None
    if outcome["kind"] == "assay" and selected_ids:
        try:
            assay_summary = _summarize(_Context(store, document), _find_run(document, outcome["runId"]),
                                       {"runId": outcome["runId"], "metricPath": outcome["metricPath"], "imageIds": selected_ids})
        except WorkbenchError as exc:
            blockers.append({"code": exc.code, "message": str(exc)})
    assay_rows = {row["imageId"]: row for row in (assay_summary or {}).get("images", [])}
    assay_runs = {run["runId"]: run for run in document.get("assayRuns", [])}
    compatibility, units, roots = None, None, {}
    for identifier in selected_ids:
        image = images.get(identifier)
        row = {"imageId": identifier, "status": "blocked", "value": None}
        try:
            if image is None:
                fail("image-not-found", "An assigned image is missing from this project.")
            row["name"] = image["name"]
            root = _root(image, images)
            if root in roots:
                fail("alternative-acquisition-input", "Multiple selected images are alternatives/ROIs of one acquisition. Assign only the intended representation before inference.", {"imageIds": [roots[root], identifier]})
            roots[root] = identifier
            row["acquisitionRoot"] = root
            if outcome["kind"] == "assay":
                measured = assay_rows.get(identifier, {})
                if measured.get("status") != "measured":
                    fail("incomplete-assay-input", measured.get("reason", "No compatible current assay measurement is available."))
                run = assay_runs[measured["runId"]]
                row.update({"value": measured["value"], "runId": run["runId"]})
                units = (assay_summary or {}).get("comparison", {}).get("units", {})
                for dep in run["dependencies"]:
                    dependency_image = images[dep["imageId"]]
                    selected = {"target": dep.get("target", "plane"), **{key: dep[key] for key in ("timeIndex", "channel") if key in dep}}
                    dep_record = _dependency(dependency_image, dep if dep.get("rawSourceOnly") else selected)
                    dependencies.append(dep_record)
                refs[run["outputPath"]] = run["outputHash"]
                # Assay dependency references freeze the precise input labels and sources too.
                from _workbench_assays import artifact_references
                refs.update(artifact_references({"assayRuns": [run]}))
            else:
                analysis = (current_frame(store, image, outcome["timeIndex"], outcome["channel"])
                            if outcome["target"] == "volume" else _current_analysis(store, image))
                cells, metric = analysis["cells"], outcome["metric"]
                values = [cell.get(METRICS[metric][0]) for cell in cells] if metric != "count" else []
                if metric == "count":
                    row["value"] = len(cells)
                elif not values or any(type(value) not in (int, float) or not math.isfinite(value) for value in values):
                    fail("measurement-unavailable", "This mean requires nonempty objects and finite calibrated measurements for every object.")
                else:
                    row["value"] = _mean(values)
                dependency = _dependency(image, outcome, analysis)
                dependencies.append(dependency)
                row["analysisRevision"] = analysis["analysisRevision"]
                row["measurementRevision"] = analysis["measurementRevision"]
                row["labelsHash"] = analysis["labelsHash"]
                row["selection"] = copy.deepcopy(analysis["parameters"] if outcome["target"] == "plane" else dependency["selection"])
                processing = processing_provenance(document, image, images)
                # Identical recipes may come from different sources. Source IDs/hashes are identities, not comparability rules.
                recipe = [{key: value for key, value in stage.items() if key in ("recipe", "engineVersion", "selection", "interpolation", "transform", "parameters")}
                          for stage in processing["stages"]]
                selected = {key: analysis["parameters"].get(key) for key in ("channel", "zProjection")} if outcome["target"] == "plane" else dependency["selection"]
                candidate = {"intensityUnits": processing["intensityUnits"], "recipe": recipe, "selection": selected,
                             "supportPolicy": "valid-support-only"}
                if metric in ("meanAreaPx", "meanVolumeVox", "count"):
                    candidate["grid"] = {key: image.get(key) for key in ("width", "height", "voxelSizeUm", "pxPerUm")}
                if compatibility is not None and digest(compatibility) != digest(candidate):
                    fail("incompatible-statistical-input", "Selected source projection/channel, processing recipe, or count/pixel measurement grids differ. Define a comparable cohort explicitly.")
                compatibility = candidate
                units = processing["intensityUnits"] if metric == "meanIntensity" else METRICS[metric][1]
            row["status"] = "measured"
        except (WorkbenchError, OSError, KeyError) as exc:
            row["reason"] = str(exc)
            blockers.append({"imageId": identifier, "code": getattr(exc, "code", "invalid-input"), "message": str(exc)})
        image_rows.append(row)
    involved = {identifier for row in definition["rows"] for identifier in assigned.get(row["specimenId"], [])}
    image_rows.extend({"imageId": identifier, "name": images.get(identifier, {}).get("name", identifier), "status": "excluded",
                       "reason": excluded_fields[identifier]["reason"], "exclusion": copy.deepcopy(excluded_fields[identifier]), "value": None}
                      for identifier in sorted(involved & set(excluded_fields)))
    by_image = {row["imageId"]: row for row in image_rows}
    rows = []
    for entry in definition["rows"]:
        identifier = entry["specimenId"]
        row = {**copy.deepcopy(entry), "imageIds": sorted(item for item in assigned.get(identifier, []) if item not in excluded_fields),
               "excludedImageIds": sorted(item for item in assigned.get(identifier, []) if item in excluded_fields), "included": identifier not in exclusions,
               "value": None, "name": specimens.get(identifier, {}).get("name", identifier)}
        if identifier not in specimens:
            blockers.append({"specimenId": identifier, "code": "specimen-not-found", "message": "The design references an unknown specimen."})
        if not row["included"]:
            row["reason"] = exclusions[identifier]
        elif not row["imageIds"]:
            blockers.append({"specimenId": identifier, "code": "no-assigned-images", "message": "An included specimen has no assigned images."})
        else:
            values = [by_image[item]["value"] for item in row["imageIds"] if item in by_image and by_image[item]["status"] == "measured"]
            if len(values) == len(row["imageIds"]):
                row["value"] = _mean(values)
        rows.append(row)
    if sum(row["included"] for row in rows) < 2:
        blockers.append({"code": "insufficient-specimens", "message": "At least two included specimens are required."})
    refs.update(_reference_images(document, dependencies))
    # Store one exact dependency per scientific selection, including assay reference images.
    unique = {digest({"imageId": item["imageId"], "selection": item["selection"]}): item for item in dependencies}
    dependencies = list(unique.values())
    state_hash = _state(document, definition, dependencies)
    table = {"schemaVersion": 1, "engineVersion": ENGINE, "definition": definition, "rows": rows,
             "imageRows": image_rows, "blockers": blockers, "ready": not blockers, "units": units,
             "comparison": compatibility or (assay_summary or {}).get("comparison"), "dependencies": dependencies,
             "dependencyFingerprint": state_hash, "notes": NOTES,
             "effectiveExclusions": {"specimen": {key: value for key, value in policy["specimen"].items() if key in {row["specimenId"] for row in definition["rows"]}},
                                     "image": {key: value for key, value in policy["image"].items() if key in involved}},
             "inputReferences": [{"path": path, "hash": checksum} for path, checksum in sorted(refs.items())]}
    table["inputFingerprint"] = digest({key: table[key] for key in ("definition", "rows", "imageRows", "dependencies", "dependencyFingerprint", "comparison", "units")})
    table["previewFingerprint"] = digest({"revision": document["revision"], "inputFingerprint": table["inputFingerprint"], "blockers": blockers})
    return table


def _read(store, path, checksum):
    location = store.verify_artifact(path, checksum)
    if location.stat().st_size > LIMITS["artifactBytes"]:
        fail("statistics-artifact-limit", "A retained statistical table exceeds its 16 MiB limit.")
    return json.loads(location.read_text())


def _put(store, value, suffix):
    from _workbench_store import canonical
    data = (canonical(value) + "\n").encode()
    if len(data) > LIMITS["artifactBytes"]:
        fail("statistics-artifact-limit", "The statistical input/result exceeds its 16 MiB bound. Select a smaller design.")
    return store.put_bytes(data, suffix)


def _design(document, identifier, version=None):
    matches = [item for item in document.get("statisticsDesigns", []) if item["id"] == identifier and (version is None or item["version"] == version)]
    if not matches:
        fail("statistics-design-not-found", "The selected statistical design/version is not in this project.")
    return max(matches, key=lambda item: item["version"])


def _run(document, identifier):
    item = next((item for item in document.get("statisticsRuns", []) if item["id"] == identifier), None)
    if item is None:
        fail("statistics-run-not-found", "The selected statistical result is not in this project.")
    return item


def current(document, record):
    try:
        return record["dependencyFingerprint"] == _state(document, record["definition"], record["dependencies"])
    except (KeyError, TypeError, ValueError):
        return False


def describe_design(document, item):
    return {"id": item["id"], "name": item["name"], "version": item["version"],
            "latestVersion": max(row["version"] for row in document.get("statisticsDesigns", [item]) if row["id"] == item["id"]),
            "inputFingerprint": item["inputFingerprint"], "inputsCurrent": current(document, item),
            "rowCount": item["rowCount"], "includedCount": item["includedCount"],
            "inputStatus": item.get("inputStatus", "ready"), "blockerCount": item.get("blockerCount", 0),
            "definition": copy.deepcopy(item["definition"]), "createdAt": item["createdAt"]}


def inspect_designs(document):
    latest = {}
    for item in document.get("statisticsDesigns", []):
        if item["id"] not in latest or latest[item["id"]]["version"] < item["version"]:
            latest[item["id"]] = item
    return [describe_design(document, item) for item in latest.values()]


def describe_run(document, item):
    return {key: copy.deepcopy(item[key]) for key in ("id", "designId", "designVersion", "name", "method", "modelStatus", "createdAt", "predecessorRunId", "replacementRunId") if key in item} | {"outputsCurrent": current(document, item)}


def _normalize_analysis(definition, value):
    from _workbench_schema import validate_value
    validate_value(value, analysis_schema())
    value = copy.deepcopy(value)
    for key, default in (("confidenceLevel", .95), ("multiplicity", "holm"), ("blocking", "none"), ("covariance", "classical"), ("contrasts", []), ("terms", []), ("interactions", [])):
        value.setdefault(key, default)
    factors = {item["id"]: item for item in definition["factors"]}
    if len({row["id"] for row in value["contrasts"]}) != len(value["contrasts"]):
        fail("duplicate-statistical-contrast", "Contrast IDs must be unique.")
    for contrast in value["contrasts"]:
        factor = factors.get(contrast["factorId"])
        if factor is None or factor["kind"] != "categorical" or contrast["reference"] not in factor["levels"] or contrast["comparison"] not in factor["levels"] or contrast["reference"] == contrast["comparison"]:
            fail("invalid-statistical-contrast", "Contrasts require two different levels of a declared categorical factor.")
    if value["method"] != "linear-model":
        if not value["contrasts"] or value["terms"] or value["interactions"] or value["blocking"] != "none" or value["covariance"] != "classical":
            fail("invalid-statistical-method", "Welch/paired tests require explicit contrasts and do not accept linear terms, blocking or HC3 covariance.")
    else:
        if not value["terms"] or len(value["terms"]) != len(set(value["terms"])) or any(key not in factors for key in value["terms"]):
            fail("invalid-statistical-terms", "Linear models require unique declared factor IDs as main-effect terms.")
        pairs = set()
        for pair in value["interactions"]:
            key = tuple(sorted(pair))
            if len(set(pair)) != 2 or not set(pair).issubset(value["terms"]) or key in pairs:
                fail("invalid-statistical-interaction", "Two-factor interactions require two distinct included main effects, without duplicates.")
            pairs.add(key)
        if any(row["factorId"] not in value["terms"] for row in value["contrasts"]):
            fail("invalid-statistical-contrast", "Linear-model contrasts must refer to an included main effect.")
    return value


def _inference_row(identifier, estimate, variance, df, confidence, scipy_stats, **extra):
    if not math.isfinite(estimate) or not math.isfinite(variance) or variance < 0 or not math.isfinite(df) or df <= 0:
        fail("statistics-numeric-range", "The selected inference cannot be represented with finite positive residual degrees of freedom.")
    result = {"id": identifier, "estimate": float(estimate), "standardError": math.sqrt(variance), "degreesOfFreedom": float(df),
              "confidenceLevel": confidence, "confidenceInterval": None, "pValue": None, "adjustedPValue": None,
              "status": "degenerate-variance" if variance == 0 else "estimated", **extra}
    if variance > 0:
        critical = float(scipy_stats.t.ppf((1 + confidence) / 2, df))
        error = critical * result["standardError"]
        low, high = estimate - error, estimate + error
        if not all(math.isfinite(value) for value in (critical, low, high)):
            fail("statistics-numeric-range", "The confidence interval exceeds finite numerical limits.")
        statistic = estimate / result["standardError"]
        if not math.isfinite(statistic):
            fail("statistics-numeric-range", "The test statistic exceeds finite numerical limits.")
        result.update({"confidenceInterval": [float(low), float(high)], "statistic": float(statistic),
                       "pValue": float(2 * scipy_stats.t.sf(abs(statistic), df))})
    return result


def _adjust(rows, method):
    valid = sorted([(row["pValue"], index) for index, row in enumerate(rows) if row["pValue"] is not None])
    total = len(valid)
    if method == "none":
        for p, index in valid:
            rows[index]["adjustedPValue"] = p
    elif method == "holm":
        previous = 0.0
        for rank, (p, index) in enumerate(valid):
            previous = max(previous, min(1.0, (total - rank) * p))
            rows[index]["adjustedPValue"] = previous
    else:
        previous = 1.0
        for rank in range(total - 1, -1, -1):
            p, index = valid[rank]
            previous = min(previous, p * total / (rank + 1))
            rows[index]["adjustedPValue"] = previous
    for row in rows:
        row["multiplicity"] = method
        row["familySize"] = total


def _contrasts(rows, analysis, factors, np, scipy_stats):
    results = []
    for contrast in analysis["contrasts"]:
        factor = contrast["factorId"]
        groups = [[row for row in rows if row["values"][factor] == level] for level in (contrast["reference"], contrast["comparison"])]
        a, b = ([row["value"] for row in group] for group in groups)
        if min(len(a), len(b)) < 2:
            fail("insufficient-contrast-replicates", "Each contrasted level requires at least two biological specimens.", {"contrastId": contrast["id"], "counts": [len(a), len(b)]})
        if analysis["method"] == "paired-t":
            pairs = []
            maps = []
            for group in groups:
                mapping = {}
                for row in group:
                    subject = row.get("subjectId")
                    if not subject or subject in mapping:
                        fail("ambiguous-pairing", "Paired tests require one and only one specimen per subject at each contrasted level.")
                    mapping[subject] = row
                maps.append(mapping)
            if set(maps[0]) != set(maps[1]):
                fail("incomplete-pairing", "Every subject must have exactly one specimen in both levels; use explicit specimen exclusions to define complete pairs.")
            for subject in sorted(maps[0]):
                left, right = maps[0][subject], maps[1][subject]
                if any(left["values"][key] != right["values"][key] for key in factors if key != factor):
                    fail("confounded-pairing", "Other declared factors differ within a pair. Use an explicitly specified factorial model or revise the design.")
                difference = right["value"] - left["value"]
                if not math.isfinite(difference):
                    fail("statistics-numeric-range", "A paired difference exceeds finite numerical limits.")
                pairs.append(difference)
            variance = float(np.var(pairs, ddof=1)) / len(pairs)
            estimate, df = _mean(pairs), len(pairs) - 1
            extra = {"subjectCount": len(pairs), "subjectIds": sorted(maps[0]), "paired": True}
        else:
            subjects = [row.get("subjectId") for group in groups for row in group if row.get("subjectId")]
            if len(subjects) != len(set(subjects)):
                fail("nonindependent-subjects", "Independent Welch contrasts cannot include repeated subjects; use paired tests or an explicit supported model.")
            va, vb = float(np.var(a, ddof=1)) / len(a), float(np.var(b, ddof=1)) / len(b)
            variance = va + vb
            df = ((va + vb) ** 2 / (va ** 2 / (len(a) - 1) + vb ** 2 / (len(b) - 1))) if variance > 0 else len(a) + len(b) - 2
            estimate, extra = _mean(b) - _mean(a), {"paired": False}
        results.append(_inference_row(contrast["id"], estimate, variance, df, analysis["confidenceLevel"], scipy_stats,
                                     **copy.deepcopy({key: contrast[key] for key in ("factorId", "reference", "comparison")}),
                                     referenceN=len(a), comparisonN=len(b), referenceMean=_mean(a), comparisonMean=_mean(b), **extra))
    return results, [], {"status": "estimated", "method": analysis["method"]}, []


def _linear(rows, analysis, factors, np, scipy_stats):
    bases, columns, specifications = {}, ["Intercept"], [("intercept",)]
    for key in analysis["terms"]:
        factor = factors[key]
        if factor["kind"] == "numeric":
            bases[key] = [(key, ("numeric", key))]
        else:
            observed = {row["values"][key] for row in rows}
            if set(factor["levels"]) != observed:
                fail("unobserved-factor-level", f"Factor {key} has an unobserved declared level. Exclude unused levels explicitly before fitting.")
            bases[key] = [(key + "[" + level + "]", ("categorical", key, level)) for level in factor["levels"] if level != factor["referenceLevel"]]
        for label, spec in bases[key]:
            columns.append(label); specifications.append(spec)
    for left, right in analysis["interactions"]:
        for lname, lspec in bases[left]:
            for rname, rspec in bases[right]:
                columns.append(lname + ":" + rname); specifications.append(("interaction", lspec, rspec))
    block_key = {"subject": "subjectId", "block": "blockId"}.get(analysis["blocking"])
    block_levels = []
    if block_key:
        if any(not row.get(block_key) for row in rows):
            fail("missing-block-identity", "Every included specimen requires the selected subject/block identity.")
        block_levels = sorted({row[block_key] for row in rows})
        for level in block_levels[1:]:
            columns.append(block_key + "[" + level + "]"); specifications.append(("block", block_key, level))
    elif len([row["subjectId"] for row in rows if row.get("subjectId")]) != len({row["subjectId"] for row in rows if row.get("subjectId")}):
        fail("repeated-subject-model-required", "Repeated subject identities require explicit subject fixed effects; this model does not provide mixed/repeated covariance estimation.")
    if len(columns) > LIMITS["columns"]:
        fail("statistics-column-limit", "Categorical expansion/interactions exceed 64 design-matrix columns.")
    def encode(spec, row):
        kind = spec[0]
        if kind == "intercept": return 1.0
        if kind == "numeric": return float(row["values"][spec[1]])
        if kind == "categorical": return float(row["values"][spec[1]] == spec[2])
        if kind == "block": return float(row.get(spec[1]) == spec[2])
        return encode(spec[1], row) * encode(spec[2], row)
    def vector(row): return [encode(spec, row) for spec in specifications]
    x = np.asarray([vector(row) for row in rows], dtype=np.float64)
    y = np.asarray([row["value"] for row in rows], dtype=np.float64)
    if not np.isfinite(x).all() or not np.isfinite(y).all():
        fail("statistics-numeric-range", "The design matrix contains unrepresentable values or interaction products.")
    rank = int(np.linalg.matrix_rank(x))
    condition = float(np.linalg.cond(x))
    df = len(rows) - rank
    if rank != x.shape[1] or df <= 0:
        fail("nonestimable-statistical-design", "The model is rank deficient or has no residual degrees of freedom. Remove confounded/redundant terms or collect more independent specimens.", {"rank": rank, "columns": len(columns), "specimens": len(rows)})
    if not math.isfinite(condition) or condition > 1e12:
        fail("ill-conditioned-statistical-design", "The design matrix is ill-conditioned. Rescale numeric factor units and remove nearly redundant terms.", {"conditionNumber": condition})
    beta, _, _, _ = np.linalg.lstsq(x, y, rcond=None)
    residual = y - x @ beta
    pinv = np.linalg.pinv(x)
    if analysis["covariance"] == "classical":
        covariance = float(residual @ residual / df) * (pinv @ pinv.T)
    else:
        leverage = np.sum(x * pinv.T, axis=1)
        if np.any(1 - leverage <= 1e-10):
            fail("hc3-leverage-limit", "HC3 covariance is undefined for observations with unit leverage; simplify the model or add replication.")
        weighted = pinv * (residual / (1 - leverage))[None, :]
        covariance = weighted @ weighted.T
    if not np.isfinite(covariance).all() or not np.isfinite(beta).all():
        fail("statistics-numeric-range", "The fitted coefficients/covariance exceed finite numerical limits.")
    coefficients = [_inference_row(label, float(beta[index]), max(0.0, float(covariance[index, index])), df,
                                  analysis["confidenceLevel"], scipy_stats, role=specifications[index][0])
                    for index, label in enumerate(columns)]
    profile = {"values": {key: (_mean([row["values"][key] for row in rows]) if factor["kind"] == "numeric" else factor["referenceLevel"])
                          for key, factor in factors.items()}}
    if block_key: profile[block_key] = block_levels[0]
    results = []
    for contrast in analysis["contrasts"]:
        left, right = copy.deepcopy(profile), copy.deepcopy(profile)
        left["values"][contrast["factorId"]] = contrast["reference"]
        right["values"][contrast["factorId"]] = contrast["comparison"]
        difference = np.asarray(vector(right)) - np.asarray(vector(left))
        results.append(_inference_row(contrast["id"], float(difference @ beta), max(0.0, float(difference @ covariance @ difference)), df,
                                     analysis["confidenceLevel"], scipy_stats, **{key: contrast[key] for key in ("factorId", "reference", "comparison")},
                                     interpretation="conditional-comparison-minus-reference", referenceProfile=copy.deepcopy(profile)))
    if not results:
        results = [copy.deepcopy(row) for row in coefficients if row["role"] not in ("intercept", "block")]
    fitted_values = x @ beta
    fitted = [{"specimenId": row["specimenId"], "observed": row["value"], "fitted": float(fitted_values[index]), "residual": float(residual[index])}
              for index, row in enumerate(rows)]
    status = {"status": "estimated", "method": "linear-model", "rank": rank, "columns": columns,
              "conditionNumber": condition, "residualDegreesOfFreedom": df, "covariance": analysis["covariance"],
              "blocking": analysis["blocking"], "referenceProfile": profile,
              "residualIndependenceAssumed": True, "mixedEffects": False}
    return results, coefficients, status, fitted


def calculate(document, table, analysis, design_id, version):
    from _workbench_imaging import require
    from _workbench_schema import WorkbenchError
    np, scipy_stats = require("numpy", "scipy.stats")
    analysis = _normalize_analysis(table["definition"], analysis)
    import sys
    from importlib.metadata import version as installed_version
    result = {"runtime": {"python": sys.version.split()[0], "numpy": np.__version__, "scipy": installed_version("scipy"), "engineVersion": ENGINE}, "status": "blocked", "modelStatus": {"status": "not-estimated"}, "results": [], "coefficients": [],
              "plotTable": [], "fittedTable": [], "notes": list(NOTES), "blockers": copy.deepcopy(table["blockers"]),
              "inputFingerprint": table["inputFingerprint"], "analysis": analysis, "designId": design_id,
              "designVersion": version, "units": table["units"], "biologicalN": sum(row["included"] for row in table["rows"])}
    if not result["blockers"]:
        rows = [row for row in table["rows"] if row["included"]]
        factors = {row["id"]: row for row in table["definition"]["factors"]}
        try:
            with np.errstate(over="raise", invalid="raise", divide="raise"):
                computed = (_linear if analysis["method"] == "linear-model" else _contrasts)(rows, analysis, factors, np, scipy_stats)
            results, coefficients, status, fitted = computed
            _adjust(results, analysis["multiplicity"])
            result.update({"status": "ready", "results": results, "coefficients": coefficients, "modelStatus": status, "fittedTable": fitted,
                           "plotTable": [{"id": row["id"], "estimate": row["estimate"], "confidenceInterval": row["confidenceInterval"],
                                          "status": row["status"], "units": table["units"]} for row in results]})
            if any(row["status"] != "estimated" for row in results):
                result["modelStatus"]["status"] = "contains-degenerate-variance"
                result["notes"].append("Zero observed variance does not establish certainty; affected t tests, confidence intervals and p-values are unavailable.")
            if analysis["method"] == "linear-model":
                result["notes"].append("Categorical terms use declared reference levels. Contrasts hold other categories at reference and numeric factors at observed specimen means; interactions make this conditional effect profile-specific.")
                if analysis["covariance"] == "HC3":
                    result["notes"].append("HC3 is a heteroskedasticity-robust approximation using residual-df t intervals; it does not correct subject correlation or establish finite-sample exactness.")
        except WorkbenchError as exc:
            result["blockers"].append({"code": exc.code, "message": str(exc), "details": getattr(exc, "details", None)})
        except (FloatingPointError, OverflowError, np.linalg.LinAlgError):
            result["blockers"].append({"code": "statistics-numeric-range", "message": "The chosen numerical scale or design is not estimable with finite arithmetic. Rescale the outcome/factors or simplify the design."})
    result["previewFingerprint"] = digest({"revision": document["revision"], "inputFingerprint": table["inputFingerprint"], "analysis": analysis, "engineVersion": ENGINE,
                                          "designId": design_id, "designVersion": version, "runtime": result["runtime"], "modelStatus": result["modelStatus"], "results": result["results"]})
    return result


def _save_design(store, document, table, identifier, revision, actor):
    from _workbench_store import utc_now
    records = document.setdefault("statisticsDesigns", [])
    if len(records) >= LIMITS["versions"] or (not identifier and len({item["id"] for item in records}) >= LIMITS["designs"]):
        fail("statistics-design-limit", "This project has reached its statistical design/version limit.")
    version = _design(document, identifier)["version"] + 1 if identifier else 1
    identifier = identifier or str(uuid.uuid4())
    path, checksum = _put(store, table, ".statistics-inputs.json")
    record = {"id": identifier, "name": table["definition"]["name"], "version": version, "createdAt": utc_now(), "revision": revision,
              "actor": copy.deepcopy(actor), "engineVersion": ENGINE, "definition": copy.deepcopy(table["definition"]),
              "inputPath": path, "inputHash": checksum, "inputStatus": "ready" if table["ready"] else "draft",
              "blockerCount": len(table["blockers"]), "rowCount": len(table["rows"]), "includedCount": sum(row["included"] for row in table["rows"]),
              **{key: copy.deepcopy(table[key]) for key in ("dependencies", "dependencyFingerprint", "inputFingerprint", "inputReferences")}}
    records.append(record)
    return record


def _retain_run(store, document, design, table, result, revision, actor, predecessor=None):
    from _workbench_store import utc_now
    if len(document.get("statisticsRuns", [])) >= LIMITS["runs"]:
        fail("statistics-run-limit", "This project retains at most 1,000 statistical results.")
    if result["status"] != "ready":
        fail("statistics-plan-blocked", "Resolve the listed design/inference blockers before saving this result.", {"blockers": result["blockers"]})
    input_path, input_hash = _put(store, table, ".statistics-inputs.json")
    path, checksum = _put(store, result, ".statistics-result.json")
    record = {"id": str(uuid.uuid4()), "name": design["name"], "designId": design["id"], "designVersion": design["version"],
              "createdAt": utc_now(), "revision": revision, "actor": copy.deepcopy(actor), "engineVersion": ENGINE,
              "method": result["analysis"]["method"], "modelStatus": copy.deepcopy(result["modelStatus"]), "analysis": copy.deepcopy(result["analysis"]),
              "resultPath": path, "resultHash": checksum, "inputPath": input_path, "inputHash": input_hash,
              "definition": copy.deepcopy(table["definition"]), **{key: copy.deepcopy(table[key]) for key in ("dependencies", "dependencyFingerprint", "inputFingerprint", "inputReferences")}}
    record["reexecution"] = {"operation": "statistics.recompute.run", "arguments": {"runId": record["id"]},
                             "previewOperation": "statistics.recompute.preview", "method": copy.deepcopy(record["analysis"]),
                             "definitionHash": digest(record["definition"]), "inputFingerprint": record["inputFingerprint"],
                             "updatesMasks": False, "scope": "complete-biological-specimens"}
    if predecessor:
        if predecessor.get("replacementRunId"):
            fail("statistics-already-replaced", "This historical result already has a replacement; recompute its latest replacement instead.")
        record["predecessorRunId"] = predecessor["id"]
        predecessor["replacementRunId"] = record["id"]
    document.setdefault("statisticsRuns", []).append(record)
    return record


def get_run(store, document, identifier):
    run = _run(document, identifier)
    return {**describe_run(document, run), "inputFingerprint": run["inputFingerprint"], "reexecution": copy.deepcopy(run["reexecution"]),
            "result": _read(store, run["resultPath"], run["resultHash"]), "inputTable": _read(store, run["inputPath"], run["inputHash"])}


def execute(store, document, operation, args, revision, actor):
    if operation == "statistics.design.list":
        return {"designs": inspect_designs(document)}
    if operation == "statistics.list":
        return {"runs": [describe_run(document, item) for item in document.get("statisticsRuns", [])]}
    if operation in ("statistics.design.preview", "statistics.design.save"):
        table = resolve(store, document, normalize_definition(args))
        if operation.endswith("preview"):
            return {"plan": table, "sourceRevision": document["revision"]}
        if args["previewFingerprint"] != table["previewFingerprint"]:
            fail("statistics-preview-changed", "The design, assignments or scientific inputs changed; preview the design again.")
        item = _save_design(store, document, table, args.get("designId"), revision, actor)
        return {"design": {**describe_design(document, item), "inputTable": table}}
    if operation == "statistics.design.get":
        item = _design(document, args["designId"], args.get("version"))
        return {"design": {**describe_design(document, item), "inputTable": _read(store, item["inputPath"], item["inputHash"])}}
    if operation == "statistics.get":
        return {"run": get_run(store, document, args["runId"])}
    predecessor = None
    if operation.startswith("statistics.recompute."):
        predecessor = _run(document, args["runId"])
        if predecessor.get("replacementRunId"):
            fail("statistics-already-replaced", "Choose the latest replacement rather than refreshing a historical predecessor.")
        design = _design(document, predecessor["designId"], predecessor["designVersion"])
        table = resolve(store, document, copy.deepcopy(predecessor["definition"]))
        analysis = predecessor["analysis"]
    else:
        design = _design(document, args["designId"], args.get("version"))
        if not current(document, design):
            fail("statistics-inputs-stale", "The frozen input table is stale. Preview/save a new design version or recompute a previous result.")
        table = _read(store, design["inputPath"], design["inputHash"])
        for ref in table["inputReferences"]:
            store.verify_artifact(ref["path"], ref["hash"])
        analysis = args["analysis"]
    result = calculate(document, table, analysis, design["id"], design["version"])
    if operation.endswith("preview"):
        return {"preview": result}
    if args["previewFingerprint"] != result["previewFingerprint"]:
        fail("statistics-preview-changed", "The scientific inputs or inference settings changed; calculate a new preview.")
    record = _retain_run(store, document, design, table, result, revision, actor, predecessor)
    return {"run": {**describe_run(document, record), "result": result, "inputTable": table}}


def artifact_references(document):
    refs = {}
    for record in document.get("statisticsDesigns", []) + document.get("statisticsRuns", []):
        refs[record["inputPath"]] = record["inputHash"]
        if record.get("resultPath"):
            refs[record["resultPath"]] = record["resultHash"]
        for ref in record.get("inputReferences", []):
            refs[ref["path"]] = ref["hash"]
    return refs


def validate_document(document):
    designs, runs = document.get("statisticsDesigns", []), document.get("statisticsRuns", [])
    if not isinstance(designs, (list, RecordList)) or not isinstance(runs, (list, RecordList)) or len(designs) > LIMITS["versions"] or len(runs) > LIMITS["runs"]:
        fail("invalid-statistics-package", "Statistical record counts exceed their bounds.")
    keys = set()
    for item in designs:
        key = (item["id"], item["version"])
        if key in keys or type(item["version"]) is not int or item["version"] < 1:
            fail("invalid-statistics-package", "Statistical design versions must have unique positive identities.")
        keys.add(key)
        normalize_definition(item["definition"])
    identifiers = {item["id"] for item in runs}
    if len(identifiers) != len(runs):
        fail("invalid-statistics-package", "Statistical result IDs must be unique.")
    for item in designs + runs:
        for name in ("inputHash", "inputFingerprint", "dependencyFingerprint"):
            if not re.fullmatch(r"[0-9a-f]{64}", item[name]):
                fail("invalid-statistics-package", "Statistical input identities must be SHA256 values.")
        if not isinstance(item["dependencies"], (list, RecordList)) or len(item["dependencies"]) > 2000 or len(item.get("inputReferences", [])) > 10000:
            fail("invalid-statistics-package", "Statistical dependencies exceed their bounds.")
    for item in runs:
        if (item["designId"], item["designVersion"]) not in keys or any(item.get(key) and item[key] not in identifiers for key in ("predecessorRunId", "replacementRunId")):
            fail("invalid-statistics-package", "A statistical run references a missing design or replacement.")
        normalize_definition(item["definition"])
        _normalize_analysis(item["definition"], item["analysis"])
