"""Descriptive comparisons of isolated sweep outputs, with retained exports."""
from __future__ import annotations

from _workbench_indexed import image_index

import copy
import csv
import io
import math
import uuid

ENGINE_VERSION = "sweep-reports-1"
MAX_CELL_VISITS = 2_000_000
MAX_REPORT_BYTES = 16 * 1024 ** 2
FORMATS = [
    {"id": "results-json", "name": "Sweep comparison (JSON)", "extension": "json", "mediaType": "application/json",
     "description": "All combinations and input rows with settings, currentness, missing results and provenance."},
    {"id": "results-csv", "name": "Sweep input measurements (CSV)", "extension": "csv", "mediaType": "text/csv",
     "description": "One row per combination and input; incomplete or changed results keep explicit status and empty metrics."},
]


def catalogue():
    return {"formats": copy.deepcopy(FORMATS)}


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    return [
        _op("sweep.results", "Compare current completed scientific checkpoints across parameter combinations without ranking accuracy.",
            _object({"sweepId": _ID, "offset": {"type": "integer", "minimum": 0, "default": 0},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 500, "default": 100}}, ["sweepId"])),
        _op("sweep.export.catalogue", "Describe complete sweep comparison export formats.", _object(), project=False),
        _op("sweep.export", "Retain and publish a complete descriptive sweep comparison, including missing and stale input rows.",
            _object({"sweepId": _ID, "format": {"type": "string", "enum": [item["id"] for item in FORMATS]},
                     "destination": _STRING}, ["sweepId", "format", "destination"]), True),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _mean(values):
    if not values:
        return None
    if any(type(value) not in (int, float) or not math.isfinite(value) for value in values):
        fail("invalid-measurements", "A saved sweep measurement is not finite.")
    scale = max(1., max(abs(value) for value in values))
    value = math.fsum((item / scale) / len(values) for item in values) * scale
    return value if math.isfinite(value) else None


def _metrics(image, analysis, target, remaining):
    import _workbench_volume as volume
    cells = analysis["cells"]
    remaining[0] -= len(cells)
    if remaining[0] < 0:
        fail("sweep-report-limit", "Sweep comparison exceeds two million object observations; select a smaller saved sweep.")
    size_key, physical_key = ("voxelCount", "volumeUm3") if target == "volume" else ("areaPx", "areaUm2")
    sizes = [cell[size_key] for cell in cells]
    if any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0 for value in sizes):
        fail("invalid-measurements", "A saved sweep object has an invalid size.")
    physical = [cell[physical_key] for cell in cells]
    calibrated = all(volume.calibration(image)[axis] is not None for axis in ("xyz" if target == "volume" else "xy"))
    physical_mean = _mean(physical) if calibrated and all(value is not None for value in physical) else None
    physical_total = physical_mean * len(cells) if physical_mean is not None else (0. if calibrated and not cells else None)
    if physical_total is not None and not math.isfinite(physical_total):
        physical_total = None
    return {
        "objectCount": len(cells), "foregroundSamples": sum(sizes),
        "meanObjectSizeSamples": _mean(sizes), "totalPhysicalSize": physical_total,
        "meanObjectPhysicalSize": physical_mean, "physicalSizeUnit": "um3" if target == "volume" else "um2",
        "meanObjectIntensity": _mean([cell["meanIntensity"] for cell in cells]),
    }


def _selection(workflow, checkpoint):
    import _workbench_workflows as workflows
    if checkpoint.get("sourceSelection"):
        source = copy.deepcopy(checkpoint["sourceSelection"])
    elif workflows.is_volume(workflow):
        source = {"target": "volume", "timeIndex": checkpoint["timeIndex"], "channel": checkpoint["channel"]}
    else:
        segmentation = workflows.segmentation_step(workflow)
        parameters = segmentation.get("sourceParameters", segmentation.get("parameters", {}))
        source = {"target": "plane", "channel": parameters["channel"], "zProjection": parameters["zProjection"]}
    return source, copy.deepcopy(checkpoint.get("workingSelection", source))


def build(store, document, sweep_id):
    from _workbench_core import _current_analysis
    from _workbench_schema import WorkbenchError
    from _workbench_plugins import checkpoint_outputs_current
    import _workbench_sweeps as sweeps
    import _workbench_workflows as workflows
    import _workbench_support as support
    import _workbench_volume as volume
    group = sweeps.get(document, sweep_id)
    jobs = sweeps._jobs(document, group)
    images = image_index(document)
    plugin_runs = {item["runId"]: item for item in document.get("pluginRuns", [])}
    assay_runs = {item["runId"]: item for item in document.get("assayRuns", [])}
    stale_sources = set(sweeps.stale_sources(document, group))
    references, verified = {}, set()
    remaining = [MAX_CELL_VISITS]
    rows, combinations = [], []

    def retain(path, checksum):
        if path in references and references[path] != checksum:
            fail("project-corrupt", "An artifact path has conflicting hashes in the sweep.")
        identity = (path, checksum)
        if identity not in verified:
            store.verify_artifact(path, checksum)
            verified.add(identity)
        references[path] = checksum

    for combination, job in zip(group["combinations"], jobs):
        originals = {mapping["imageId"]: mapping["sourceImageId"] for mapping in combination["variants"]}
        reference_stale = bool(workflows.stale_reference_ids(document, job))
        combination_rows = []
        if job.get("kind") == "dag":
            combination_rows = _graph_rows(store, document, combination, job, originals, stale_sources, remaining, retain)
            rows.extend(combination_rows)
        else:
            for checkpoint in job["checkpoints"]:
                source_id = originals.get(checkpoint["imageId"])
                if source_id is None:
                    fail("project-corrupt", "A sweep checkpoint has no original acquisition mapping.")
                original = images.get(source_id)
                working_id = checkpoint.get("workingImageId", checkpoint["imageId"])
                image = images.get(working_id)
                source_selection, selection = _selection(job["workflow"], checkpoint)
                target = selection["target"]
                row = {
                    "combinationIndex": combination["index"], "jobId": job["id"],
                    "sourceImageId": source_id, "sourceName": original["name"] if original else source_id,
                    "variantImageId": checkpoint["imageId"], "workingImageId": working_id,
                    "target": target, "sourceSelection": source_selection, "selection": selection,
                    "checkpointStatus": checkpoint["status"], "status": "pending", "reason": None,
                    "analysisRevision": None, "measurementRevision": None, "labelsSha256": None,
                    "sourceHash": image["sourceHash"] if image else None,
                    "voxelSizeUm": volume.calibration(image) if image else None,
                    "intensityUnits": "processed-source" if image and image.get("derivation") else "raw-source",
                    "metrics": None,
                }
                if source_id in stale_sources or reference_stale:
                    row.update({"status": "stale", "reason": "Original acquisition, calibration, support or paired reference changed."})
                elif image is None:
                    row.update({"status": "unavailable", "reason": "The retained working image is unavailable."})
                elif not workflows.checkpoint_current(images, checkpoint):
                    row.update({"status": "stale", "reason": "The source, working image or saved correction changed after this checkpoint."})
                elif (not checkpoint_outputs_current(document, checkpoint, plugin_runs)
                      or not workflows.assay_outputs_current(document, checkpoint, assay_runs)):
                    row.update({"status": "stale", "reason": "A retained plugin or assay output changed after this checkpoint."})
                elif checkpoint["status"] != "completed":
                    row.update({"status": "pending" if checkpoint.get("nextStep", 0) == 0 else "incomplete",
                                "reason": "The scientific checkpoint has not completed."})
                else:
                    try:
                        analysis = (volume.current_frame(store, image, selection["timeIndex"], selection["channel"], verify=False)
                                    if target == "volume" else _current_analysis(store, image, verify_files=False))
                        retain(image["sourcePath"], image["sourceHash"])
                        retain(analysis["labelsPath"], analysis["labelsHash"])
                        support_value = support.descriptor(image)
                        if support_value:
                            retain(support_value["path"], support_value["hash"])
                        metrics = _metrics(image, analysis, target, remaining)
                        row.update({"status": "current", "metrics": metrics,
                                    "analysisRevision": analysis["analysisRevision"],
                                    "measurementRevision": analysis["measurementRevision"],
                                    "labelsSha256": analysis["labelsHash"]})
                    except WorkbenchError as exc:
                        if exc.code in ("sweep-report-limit", "project-corrupt"):
                            raise
                        row.update({"status": "unavailable", "reason": exc.message, "errorCode": exc.code})
                    except (OSError, ValueError, OverflowError) as exc:
                        row.update({"status": "unavailable", "reason": str(exc)[:1000]})
                rows.append(row)
                combination_rows.append(row)
        current = [row for row in combination_rows if row["status"] == "current"]
        complete = len(current) == len(combination_rows)
        available = sum(row["metrics"]["objectCount"] or 0 for row in current)
        branch_results = []
        if job.get("kind") == "dag":
            for node in job["workflow"]["graph"]["nodes"]:
                from _workbench_graphs import SEGMENTATION, raw_assay
                if node["type"] not in SEGMENTATION and not raw_assay(node):
                    continue
                selected_rows = [row for row in combination_rows if row["nodeId"] == node["id"]]
                current_rows = [row for row in selected_rows if row["status"] == "current"]
                branch_complete = len(current_rows) == len(selected_rows)
                objects_available = node["type"] in SEGMENTATION
                observations = sum(row["metrics"]["objectCount"] or 0 for row in current_rows)
                branch_results.append({"nodeId": node["id"], "nodeName": node.get("name", node["id"]),
                    "totalInputs": len(selected_rows), "currentInputs": len(current_rows),
                    "pendingInputs": sum(row["status"] in ("pending", "incomplete") for row in selected_rows),
                    "staleInputs": sum(row["status"] in ("stale", "unavailable") for row in selected_rows),
                    "objectObservations": observations if branch_complete and objects_available else None,
                    "objectsAvailable": objects_available, "availableObjectObservations": observations if objects_available else None, "comparisonComplete": branch_complete})
        combinations.append({
            "index": combination["index"], "jobId": job["id"], "status": job["status"],
            "values": copy.deepcopy(combination["values"]), "totalInputs": len(combination_rows),
            "currentInputs": len(current),
            "pendingInputs": sum(row["status"] in ("pending", "incomplete") for row in combination_rows),
            "staleInputs": sum(row["status"] in ("stale", "unavailable") for row in combination_rows),
            "objectObservations": available if complete and job.get("kind") != "dag" else None,
            "availableObjectObservations": available if job.get("kind") != "dag" else None, "comparisonComplete": complete,
            **({"branchResults": branch_results} if job.get("kind") == "dag" else {}),
        })
    result = {
        "schemaVersion": 1, "engineVersion": ENGINE_VERSION,
        "sweepId": group["id"], "name": group["name"], "sourceRevision": document["revision"],
        "definitionHash": group["definitionHash"],
        "baseWorkflow": {key: group["baseWorkflow"][key] for key in ("id", "name", "version", "kind") if key in group["baseWorkflow"]},
        "limits": {"objectObservations": MAX_CELL_VISITS, "exportBytes": MAX_REPORT_BYTES, "pageRows": 500},
        "sourceInputsCurrent": not stale_sources,
        "complete": not stale_sources and all(item["comparisonComplete"] for item in combinations),
        "combinations": combinations, "rows": rows,
        "notes": [
            "Linear rows describe completed scientific checkpoints; graph rows describe segmentation and raw-assay nodes separately (raw assays never invent object counts). A graph may still be awaiting downstream assays, summary or export.",
            "Combinations reuse acquisitions; image variants and time points are not independent biological replicates.",
            "Graph rows identify each segmentation branch. Per-branch counts remain separate; overall graph object totals are null rather than pooling alternative masks.",
            "Object observations sum detected objects across selected inputs; a tracked cell observed in multiple frames contributes more than once.",
            "Combination totals remain unknown until every input has current measurements. Available observations are explicitly partial.",
            "Changed or unavailable outputs retain their input rows with empty metrics; replacement masks are never silently substituted.",
            "Counts, size and intensity describe results; they do not measure segmentation accuracy or rank parameter quality.",
            "Mean object intensity gives each detected object equal weight. Intensities across channels or preprocessing recipes may have different meanings.",
            "Physical metrics require the relevant axis calibration. Unavailable values remain null in JSON and empty in CSV.",
            "Results use retained canonical object measurements without rerunning segmentation or rendering previews.",
        ],
    }
    return result, references


def read(store, document, arguments):
    report, _ = build(store, document, arguments["sweepId"])
    offset, limit = arguments.get("offset", 0), arguments.get("limit", 100)
    total = len(report["rows"])
    report["rows"] = report["rows"][offset:offset + limit]
    report["pagination"] = {"offset": offset, "limit": limit, "total": total,
                            "nextOffset": offset + limit if offset + limit < total else None}
    return report


def _csv(report, provenance_hash):
    from _workbench_exports import _csv_safe
    from _workbench_store import canonical
    columns = [
        "sweep_id", "sweep_name", "source_revision", "sweep_definition_sha256", "provenance_sha256",
        "combination_index", "job_id", "job_status", "parameter_values_json",
        "source_image_id", "source_image_name", "variant_image_id", "working_image_id",
        "node_id", "node_name", "target", "source_selection_json", "working_selection_json", "checkpoint_status", "result_status", "reason",
        "source_sha256", "labels_sha256", "analysis_revision", "measurement_revision",
        "voxel_size_x_um", "voxel_size_y_um", "voxel_size_z_um",
        "object_count", "foreground_samples", "mean_object_size_samples",
        "total_physical_size", "mean_object_physical_size", "physical_size_unit", "mean_object_intensity", "intensity_units",
    ]
    combinations = {item["index"]: item for item in report["combinations"]}
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(columns)
    for row in report["rows"]:
        combination = combinations[row["combinationIndex"]]
        metrics, scale = row["metrics"] or {}, row.get("voxelSizeUm") or {}
        values = [
            report["sweepId"], report["name"], report["sourceRevision"], report["definitionHash"], provenance_hash,
            row["combinationIndex"], row["jobId"], combination["status"], canonical(combination["values"]),
            row["sourceImageId"], row["sourceName"], row["variantImageId"], row["workingImageId"],
            row.get("nodeId"), row.get("nodeName"), row["target"], canonical(row["sourceSelection"]), canonical(row["selection"]),
            row["checkpointStatus"], row["status"], row["reason"],
            row["sourceHash"], row["labelsSha256"], row["analysisRevision"], row["measurementRevision"],
            *[scale.get(axis) for axis in "xyz"],
            *[metrics.get(key) for key in ("objectCount", "foregroundSamples", "meanObjectSizeSamples",
                                         "totalPhysicalSize", "meanObjectPhysicalSize", "physicalSizeUnit", "meanObjectIntensity")],
            row["intensityUnits"],
        ]
        writer.writerow([_csv_safe(value) for value in values])
    return output.getvalue().encode("utf-8")


def prepare_export(store, document, arguments, revision, request_id, actor):
    from _workbench_exports import _destination, _stage_publication, MAX_EXPORTS
    from _workbench_store import canonical, utc_now
    import _workbench_sweeps as sweeps
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "A project retains at most 1,000 built-in scientific exports.")
    definition = next(item for item in FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    report, references = build(store, document, arguments["sweepId"])
    group = sweeps.get(document, arguments["sweepId"])
    encoded = (canonical(report) + "\n").encode("utf-8")
    if len(encoded) > MAX_REPORT_BYTES:
        fail("sweep-report-limit", "The complete sweep report exceeds its 16 MiB output budget.")
    report_path, report_hash = store.put_bytes(encoded, ".sweep-report.json")
    provenance = {
        "schemaVersion": 1, "engineVersion": ENGINE_VERSION, "exportId": str(uuid.uuid4()),
        "projectId": document["id"], "sourceRevision": document["revision"], "exportRevision": revision,
        "sweepId": group["id"], "sweepDefinitionHash": group["definitionHash"],
        "format": definition["id"], "createdAt": utc_now(), "requestId": request_id, "actor": copy.deepcopy(actor),
        "reportSha256": report_hash, "inputCount": len(report["rows"]), "combinationCount": len(report["combinations"]),
        "complete": report["complete"], "sourceInputsCurrent": report["sourceInputsCurrent"],
        "baseWorkflow": report["baseWorkflow"], "notes": report["notes"] + [
            "Export includes every input row, independent of the desktop's current page.",
            "CSV combination indices are zero-based. JSON parameter columns preserve the exact varied settings.",
            "CSV strings that could be interpreted as spreadsheet formulas are prefixed with an apostrophe.",
        ],
    }
    provenance_path, provenance_hash = store.put_bytes(
        (canonical(provenance) + "\n").encode("utf-8"), ".sweep-report-provenance.json")
    contents = ((canonical({"schemaVersion": 1, "format": "cellcounter-sweep-results", "report": report,
                            "provenance": provenance, "provenanceSha256": provenance_hash}) + "\n").encode("utf-8")
                if definition["id"] == "results-json" else _csv(report, provenance_hash))
    if len(contents) > MAX_REPORT_BYTES:
        fail("sweep-report-limit", "The complete sweep export exceeds its 16 MiB output budget.")
    file_path, checksum = store.put_bytes(contents, ".sweep-export." + definition["extension"])
    item = {
        "exportId": provenance["exportId"], "kind": "sweep", "sweepId": group["id"], "format": definition["id"],
        "createdAt": provenance["createdAt"], "revision": revision,
        "filePath": file_path, "fileHash": checksum, "provenancePath": provenance_path, "provenanceHash": provenance_hash,
        "reportPath": report_path, "reportHash": report_hash,
        "inputReferences": [{"path": path, "hash": value} for path, value in sorted(references.items())],
        "destination": str(destination), "mediaType": definition["mediaType"], "bytes": len(contents),
    }
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {
        "exportId": item["exportId"], "destination": str(destination), "sha256": checksum,
        "format": definition["id"], "mediaType": definition["mediaType"], "bytes": len(contents),
        "sweepId": group["id"], "provenance": provenance, "provenanceSha256": provenance_hash,
    }, publish, temporary, publication


def _graph_rows(store, document, combination, job, originals, stale_sources, remaining, retain):
    """Describe each segmentation branch without pooling alternative masks."""
    import _workbench_graphs as graphs
    import _workbench_volume as volume
    import _workbench_support as support
    from _workbench_core import _current_analysis
    from _workbench_schema import WorkbenchError
    images = image_index(document)
    definitions = {node["id"]: node for node in job["workflow"]["graph"]["nodes"]}
    _, stale_nodes = graphs._stale(document, job)
    changed = {(item["checkpointIndex"], item["nodeId"]) for item in stale_nodes}
    rows = []
    for checkpoint_index, checkpoint in enumerate(job["checkpoints"]):
        source_id = originals.get(checkpoint["imageId"])
        if source_id is None:
            fail("project-corrupt", "A graph sweep source lacks its original-acquisition mapping.")
        original = images.get(source_id)
        saved_nodes = {item["nodeId"]: item for item in checkpoint["nodes"]}
        for node in job["workflow"]["graph"]["nodes"]:
            if node["type"] not in graphs.SEGMENTATION and not graphs.raw_assay(node):
                continue
            saved = saved_nodes[node["id"]]
            bound = saved.get("outputBinding")
            image = images.get(bound["imageId"]) if bound else None
            processed, parent = False, node["input"]
            while parent != graphs.SOURCE:
                ancestor = definitions[parent]
                processed = processed or ancestor["type"] == "preprocessing"
                parent = ancestor["input"]
            intended = copy.deepcopy(checkpoint["sourceSelection"])
            if processed:
                intended = ({"target": "volume", "timeIndex": 0, "channel": 0} if intended["target"] == "volume" else
                            {"target": "plane", "channel": 0, "zProjection": "max"})
            selection = copy.deepcopy(bound["selection"] if bound else intended)
            row = {"combinationIndex": combination["index"], "jobId": job["id"],
                   "nodeId": node["id"], "nodeName": node.get("name", node["id"]),
                   "sourceImageId": source_id, "sourceName": original["name"] if original else source_id,
                   "variantImageId": checkpoint["imageId"], "workingImageId": bound["imageId"] if bound else None,
                   "target": selection["target"], "sourceSelection": copy.deepcopy(checkpoint["sourceSelection"]),
                   "selection": selection, "checkpointStatus": saved["status"], "status": "pending", "reason": None,
                   "analysisRevision": None, "measurementRevision": None, "labelsSha256": None,
                   "sourceHash": image["sourceHash"] if image else None,
                   "voxelSizeUm": volume.calibration(image) if image else None,
                   "intensityUnits": "processed-source" if processed or (image or original or {}).get("derivation") else "raw-source",
                   "metrics": None}
            if source_id in stale_sources:
                row.update({"status": "stale", "reason": "The original acquisition, calibration or valid support changed."})
            elif saved["status"] != "completed":
                row["reason"] = "The segmentation branch checkpoint has not completed."
            elif (checkpoint_index, node["id"]) in changed:
                row.update({"status": "stale", "reason": "The retained branch input, mask or scientific result changed."})
            elif image is None:
                row.update({"status": "unavailable", "reason": "The exact retained branch acquisition is unavailable."})
            else:
                try:
                    retain(image["sourcePath"], image["sourceHash"])
                    if graphs.raw_assay(node):
                        import _workbench_assays as assays
                        from _workbench_assay_summary import _extract
                        import json
                        identifier = next(item["assayRunId"] for item in saved["stepResults"] if item.get("assayRunId"))
                        run = next(item for item in document.get("assayRuns", []) if item["runId"] == identifier)
                        if not assays._current(document, run):
                            raise WorkbenchError("stale-assay-output", "This source-intensity assay is no longer current.")
                        retain(run["outputPath"], run["outputHash"])
                        output_path = store.artifact_path(run["outputPath"])
                        if output_path.stat().st_size > 16 * 1024 ** 2:
                            fail("sweep-report-limit", "An assay report exceeds its retained read bound.")
                        row.update({"status": "current", "assayRunId": identifier,
                                    "assayMetrics": _extract(json.loads(output_path.read_text())),
                                    "metrics": {"objectCount": None, "foregroundSamples": None, "meanObjectSizeSamples": None,
                                                "totalPhysicalSize": None, "meanObjectPhysicalSize": None,
                                                "physicalSizeUnit": None, "meanObjectIntensity": None},
                                    "objectsAvailable": False})
                        for path, checksum in assays.artifact_references({"assayRuns": [run]}).items(): retain(path, checksum)
                        rows.append(row)
                        continue
                    analysis = (volume.current_frame(store, image, selection["timeIndex"], selection["channel"], verify=False)
                                if selection["target"] == "volume" else _current_analysis(store, image, verify_files=False))
                    retain(analysis["labelsPath"], analysis["labelsHash"])
                    if support.descriptor(image):
                        retain(support.descriptor(image)["path"], support.descriptor(image)["hash"])
                    row.update({"status": "current", "metrics": _metrics(image, analysis, selection["target"], remaining),
                                "analysisRevision": analysis["analysisRevision"], "measurementRevision": analysis["measurementRevision"],
                                "labelsSha256": analysis["labelsHash"]})
                except WorkbenchError as exc:
                    if exc.code in ("sweep-report-limit", "project-corrupt"):
                        raise
                    row.update({"status": "unavailable", "reason": exc.message, "errorCode": exc.code})
                except (OSError, ValueError, OverflowError) as exc:
                    row.update({"status": "unavailable", "reason": str(exc)[:1000]})
            rows.append(row)
    return rows
