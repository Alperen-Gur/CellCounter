"""Shared local import-to-export operations for graphical, CLI and MCP clients.

All public calls enter ``dispatch``. No transport owns scientific calculations or
project state. Computations happen outside SQLite transactions and mutations use
an expected revision when their results are committed.
"""
from __future__ import annotations

import copy
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import uuid
import zipfile

import _workbench_imaging as imaging
import _workbench_workflows as workflows
import _workbench_sweeps as sweeps
import _workbench_sweep_reports as sweep_reports
import _workbench_jobs as batch_jobs
import _workbench_experiments as experiments
import _workbench_experiment_layouts as experiment_layouts
import _workbench_volume as volume
import _workbench_packages as packages
import _workbench_package2 as package2
import _workbench_plugins as plugins
import _workbench_adaptation as adaptation
import _workbench_models as models
import _workbench_model_cards as model_cards
import _workbench_review as review
import _workbench_sources as sources
import _workbench_lineages as lineages
import _workbench_registration as registration
import _workbench_comparison as comparison
import _workbench_composite as composite
import _workbench_composite_exports as composite_exports
import _workbench_display_presets as display_presets
import _workbench_display_preset_io as display_preset_io
import _workbench_distributed as distributed
import _workbench_refresh as refresh
import _workbench_graphs as graphs
import _workbench_migration as migration
import _workbench_workspace as workspaces
import _workbench_sessions as sessions
import _workbench_library as library
import _workbench_zarr as zarr_sources
import _workbench_omero as omero
import _workbench_tiled as tiled
import _workbench_temporal as temporal
import _workbench_statistics as statistical
import _workbench_pages as pages
import _workbench_catalogues as catalogues
import _workbench_runtimes as runtimes
import _workbench_statistics_exports as statistics_exports
import _workbench_refresh_reports as refresh_reports
import _workbench_support as support
import _workbench_assays as assays
import _workbench_assay_series as assay_series
import _workbench_assay_summary as assay_summary
import _workbench_preprocessing as preprocessing
import _workbench_variants as variants
import _workbench_exports as image_exports
import _workbench_label_import as label_imports
import _workbench_annotations as annotations
from _workbench_schema import (WorkbenchError, absolute_path, analysis_parameters,
                               operation_catalog, validate_request)
from _workbench_store import ProjectStore, canonical, file_hash, utc_now, MAX_RESPONSE_BYTES, sync_directory

ENGINE_VERSION = "1.0.0"


def _success(request, result, revision=None):
    from _workbench_indexed import bound_cell_response
    result = bound_cell_response(result, request)
    envelope = {"schemaVersion": 1, "ok": True, "operation": request["operation"],
                "requestId": request["requestId"], "result": result}
    if revision is not None:
        envelope["revision"] = revision
    if len(canonical(envelope).encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise WorkbenchError("result-too-large", "Result exceeds the 24 MiB client response budget.")
    return envelope


def _image(document, image_id):
    from _workbench_indexed import RecordList
    if isinstance(document["images"], RecordList):
        image = document["images"].find(image_id)
        if image is not None: return image
    else:
        image = next((row for row in document["images"] if row["id"] == image_id), None)
        if image is not None: return image
    raise WorkbenchError("image-not-found", "Image is not part of this project.", {"imageId": image_id})

def _image_inspection(document, image, review_flags=None):
    if review_flags is None: review_flags = review.flags_by_image(document)
    entry = {key: image[key] for key in (
        "id", "name", "width", "height", "channels", "pxPerUm", "sourceHash",
        "axes", "shape", "dtype", "zCount", "timeCount", "importedAt",
    )}
    entry.update(library.metadata(image))
    entry["sourceArtifactGeneration"] = image.get("sourceArtifactGeneration", 0)
    analysis = image.get("analysis")
    entry["status"] = "analyzed" if analysis else "imported"
    entry.update({"voxelSizeUm": volume.calibration(image),
                  "timeStepSeconds": image.get("timeStepSeconds"),
                  "volumeFrameCount": len(image.get("volumeFrames", [])),
                  "referenceCurrent": adaptation._reference_current(image)})
    entry["intensityUnits"] = "processed-source" if image.get("derivation") else "raw-source"
    entry["reviewFlags"] = review_flags.get(image["id"], [])
    from _workbench_indexed import RecordList
    annotation_rows = document.get("annotations", [])
    if isinstance(annotation_rows, RecordList) and not (annotation_rows.dirty or annotation_rows.added or annotation_rows.deleted or annotation_rows.reset):
        entry["annotationCount"] = annotation_rows.view.query("SELECT COUNT(*) FROM records WHERE collection=? AND json_extract(payload,'$.imageId')=? AND json_extract(payload,'$.value.deleted')=0", (annotation_rows.collection, image["id"])).fetchone()[0]
    else:
        entry["annotationCount"] = sum(item["imageId"] == image["id"] and not item["value"]["deleted"] for item in annotation_rows)
    if support.descriptor(image):
        entry["validSupport"] = support.summary(image)
    entry["lineages"] = [lineages.describe(image, record) for record in image.get("volumeLineages", [])]
    if image.get("derivation"):
        entry["derivation"] = copy.deepcopy(image["derivation"])
        if image["derivation"].get("kind") == "registration":
            entry["registration"] = registration.inspect(image, document)
    if image.get("sourceRegion"):
        entry["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    for key in ("variantOf", "variantRootId", "variantCopiedAnalysis",
                "preferredSourceParameters", "preferredVolumeSelection", "readerOrigin", "sweepOrigin", "workflowBranch", "legacyOrigin"):
        if key in image:
            entry[key] = copy.deepcopy(image[key])
    if not analysis and image.get("volumeFrames"):
        entry["status"] = "volume-analyzed"
    if analysis:
        entry.update({"analysisRevision": analysis["analysisRevision"],
                      "measurementRevision": analysis["measurementRevision"],
                      "cellCount": len(analysis["cells"]), "parameters": analysis["parameters"],
                      "inputFingerprint": analysis["inputFingerprint"]})
    entry["temporalPropagations"] = temporal.describe_propagations(image)
    return entry


def _inspection(document, store=None, *, image_ids=None, include_history=True):
    if image_ids is None and len(document["images"]) > 1000:
        raise WorkbenchError("paged-read-required", "Use project.snapshot and image.list for this large library; project.inspect is a bounded compatibility operation.")
    review_flags = review.flags_by_image(document)
    selected = document["images"] if image_ids is None else [_image(document, identifier) for identifier in image_ids]
    images = [_image_inspection(document, image, review_flags) for image in selected]
    job_descriptors = workflows.inspect_jobs(document)
    return {"project": {"id": document["id"], "name": document["name"],
                        "revision": document["revision"], "createdAt": document["createdAt"],
                        "updatedAt": document["updatedAt"]},
            "images": images, **({"history": document["history"][-500:]} if include_history else {}),
            "jobs": job_descriptors,
            "sweeps": sweeps.inspect_sweeps(document, job_descriptors),
            "jobWorkers": batch_jobs.inspect_workers(store, document),
            "imageExports": [image_exports.describe(item) for item in document.get("imageExports", [])],
            "displayPresets": display_presets.inspect_presets(document),
            "distributions": distributed.inspect_groups(document),
            "distributedTask": distributed.describe_task(document, include_local_runtime=True),
            "refreshJobs": refresh.inspect_jobs(document),
            "migration": migration.describe(document),
            "collections": library.collections(document),
            "zarrSources": [zarr_sources.describe(source) for source in document.get("zarrSources", [])],
            "tiledAnalyses": [tiled.describe(analysis) for analysis in document.get("tiledAnalyses", [])],
            "statisticsDesigns": statistical.inspect_designs(document),
            "statisticsRuns": [statistical.describe_run(document, run) for run in document.get("statisticsRuns", [])],
            "workspaces": workspaces.inspect_workspaces(document),
            "workspaceOutputs": [workspaces.describe_output(document, output) for output in document.get("workspaceOutputs", [])],
            "labelImports": [label_imports.describe(item) for item in document.get("labelImports", [])],
            "workflows": workflows.inspect_workflows(document),
            "experimentalDesign": experiments.describe(document),
            **experiment_layouts.inspect_records(document),
            "plugins": [plugins.describe(plugin) for plugin in document.get("plugins", [])],
            "modelActivation": model_cards.activation(document),
            "adaptationDatasets": [adaptation.describe(document, dataset, detail=False)
                                   for dataset in document.get("adaptationDatasets", [])],
            "models": [models.describe(model) for model in document.get("models", [])],
            "trainingJobs": [models.describe_job(store, job) if store is not None else
                             {key: value for key, value in job.items() if key not in ("reportPath", "predictions")}
                             for job in document.get("trainingJobs", [])],
            "assayRuns": [assays.describe(document, run) for run in document.get("assayRuns", [])],
            "assaySeriesRuns": [assay_series.describe(document, run) for run in document.get("assaySeriesRuns", [])],
            "reviewSessions": [review.describe(document, session) for session in document.get("reviewSessions", [])],
            "largeSources": [sources.describe(source) for source in document.get("largeSources", [])],
            **({"restoredFrom": document["restoredFrom"], "restoredHistoryCount": len(document.get("restoredHistory", []))}
               if document.get("restoredFrom") else {})}


def _check_expected(document, expected):
    if expected is not None and expected != document["revision"]:
        raise WorkbenchError("revision-conflict", "Project revision differs from expectedRevision. Inspect and retry.",
                             {"expectedRevision": expected, "actualRevision": document["revision"]})


def _source(store, image, parameters):
    path = store.verify_artifact(image["sourcePath"], image["sourceHash"])
    plane, metadata = imaging.load_plane(path, parameters)
    if metadata["width"] != image["width"] or metadata["height"] != image["height"]:
        raise WorkbenchError("source-changed", "Source dimensions differ from the imported image.")
    return plane


def _labels(store, image, analysis=None):
    analysis = analysis or image.get("analysis")
    if analysis is None:
        raise WorkbenchError("analysis-required", "Run an analysis before editing or reading measurements.")
    path = store.verify_artifact(analysis["labelsPath"], analysis["labelsHash"])
    labels = imaging.read_labels(path, (image["height"], image["width"]))
    if support.descriptor(image):
        support.assert_labels(store, image, labels, analysis.get("parameters"))
    return labels


def _fingerprint(image, analysis):
    inputs = {"sourceHash": image["sourceHash"], "parameters": analysis["parameters"],
              "labelsHash": analysis["labelsHash"], "pxPerUm": image["pxPerUm"],
              "engineVersion": analysis["engineVersion"]}
    if "voxelSizeUm" in image:
        inputs["pixelSizeUm"] = {axis: image["voxelSizeUm"].get(axis) for axis in "xy"}
    if support.descriptor(image):
        inputs["validSupport"] = support.fingerprint(image)
    return hashlib.sha256(canonical(inputs).encode("utf-8")).hexdigest()


def _current_analysis(store, image, verify_files=True):
    analysis = image.get("analysis")
    if analysis is None:
        raise WorkbenchError("analysis-required", "Run an analysis before reading its measurements.")
    if analysis["inputFingerprint"] != _fingerprint(image, analysis):
        raise WorkbenchError("stale-analysis", "Saved measurements no longer match their inputs. Recompute the analysis.")
    if verify_files:
        store.verify_artifact(image["sourcePath"], image["sourceHash"])
        if support.descriptor(image):
            _labels(store, image, analysis)
        else:
            store.verify_artifact(analysis["labelsPath"], analysis["labelsHash"])
    return analysis


def _measurement_result(image, analysis=None):
    analysis = analysis or image["analysis"]
    return {"imageId": image["id"], "width": image["width"], "height": image["height"],
            "cells": analysis["cells"], "cellCount": len(analysis["cells"]),
            "pxPerUm": image["pxPerUm"], "voxelSizeUm": volume.calibration(image),
            "calibrated": volume.xy_calibrated(image),
            "parameters": analysis["parameters"], "imageStats": analysis["imageStats"],
            "analysisRevision": analysis["analysisRevision"],
            "measurementRevision": analysis["measurementRevision"],
            "inputFingerprint": analysis["inputFingerprint"],
            "validSupport": copy.deepcopy(analysis.get("validSupport", support.summary(image))),
            **({"model": copy.deepcopy(analysis["model"])} if analysis.get("model") else {}),
            **({"sourceRegion": copy.deepcopy(image["sourceRegion"])} if image.get("sourceRegion") else {}),
            "coordinateSpace": "pixel-edges",
            "intensityUnits": "processed-source" if image.get("derivation") else "raw-source"}


def _set_analysis(store, image, labels, plane, parameters, revision, stats=None, preserve_undo=True):
    labels, support_info = support.clip_labels(store, image, labels, parameters)
    previous = image.get("analysis")
    if preserve_undo and previous is not None:
        history = image.setdefault("undoStack", [])
        history.append({key: previous[key] for key in (
            "labelsPath", "labelsHash", "parameters", "analysisRevision", "engineVersion", "imageStats",
        )})
        if previous.get("model"):
            history[-1]["model"] = copy.deepcopy(previous["model"])
        # Bound retained correction snapshots; artifacts remain immutable for saved exports.
        del history[:-100]
    label_path, label_hash = store.put_bytes(imaging.encode_labels(labels), ".labels.npy")
    analysis = {
        "labelsPath": label_path, "labelsHash": label_hash, "parameters": copy.deepcopy(parameters),
        "cells": imaging.measure(labels, plane, image["pxPerUm"], volume.calibration(image)),
        "imageStats": {**(stats or {}), "foregroundPixels": int((labels > 0).sum()),
                       "validSupport": support_info},
        "validSupport": support_info,
        "analysisRevision": revision, "measurementRevision": revision,
        "engineVersion": ENGINE_VERSION, "createdAt": utc_now(),
    }
    analysis["inputFingerprint"] = _fingerprint(image, analysis)
    image["analysis"] = analysis
    return _measurement_result(image)


def _summary(document):
    entries = []
    for image in document["images"]:
        analysis = image.get("analysis")
        cells = analysis["cells"] if analysis else []
        calibrated = volume.xy_calibrated(image)
        entries.append({
            "imageId": image["id"], "name": image["name"],
            "status": "analyzed" if analysis else "imported",
            "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
            "cellCount": len(cells) if analysis else None,
            "calibrated": calibrated, "pxPerUm": image["pxPerUm"],
            "totalAreaPx": sum(cell["areaPx"] for cell in cells) if analysis else None,
            "totalAreaUm2": (sum(cell["areaUm2"] for cell in cells) if analysis and calibrated else None),
            "meanDiameterUm": (sum(cell["diameterUm"] for cell in cells) / len(cells)
                               if cells and calibrated else None),
            "meanCellIntensity": (sum(cell["meanIntensity"] for cell in cells) / len(cells)
                                  if cells else None),
            "analysisRevision": analysis["analysisRevision"] if analysis else None,
            "measurementRevision": analysis["measurementRevision"] if analysis else None,
            "validSupport": support.summary(image),
        })
    return {
        "projectId": document["id"], "sourceRevision": document["revision"],
        "imageCount": len(entries),
        "analyzedImageCount": sum(entry["status"] == "analyzed" for entry in entries),
        "cellCount": sum(entry["cellCount"] or 0 for entry in entries),
        "images": entries, "aggregation": "descriptive-per-image",
        "volumes": volume.summary(document),
    }


def _csv(document):
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    columns = ["image_id", "image_name", "label_id", "centroid_x_px", "centroid_y_px",
               "area_px", "area_um2", "diameter_um", "mean_intensity_raw", "px_per_um",
               "analysis_revision", "measurement_revision", "intensity_units"]
    writer.writerow(columns)
    for image in document["images"]:
        analysis = image.get("analysis")
        if analysis is None:
            continue
        name = image["name"]
        if name.lstrip().startswith(("=", "+", "-", "@", "\t", "\r")):
            name = "'" + name
        for cell in analysis["cells"]:
            writer.writerow([image["id"], name, cell["labelId"], cell["cx"], cell["cy"],
                             cell["areaPx"], cell["areaUm2"], cell["diameterUm"], cell["meanIntensity"],
                             image["pxPerUm"], analysis["analysisRevision"], analysis["measurementRevision"],
                             "processed-source" if image.get("derivation") else "raw-source"])
    return output.getvalue().encode("utf-8")


def _volume_csv(document):
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(["image_id", "time_index", "channel", "label_id", "centroid_x_vox",
                     "centroid_y_vox", "centroid_z_vox", "voxel_count", "volume_um3",
                     "equivalent_diameter_um", "mean_intensity_raw", "analysis_revision", "measurement_revision",
                     "intensity_units"])
    for image in document["images"]:
        for frame in image.get("volumeFrames", []):
            for cell in frame["cells"]:
                writer.writerow([image["id"], frame["timeIndex"], frame["channel"], cell["labelId"],
                                 cell["cx"], cell["cy"], cell["cz"], cell["voxelCount"], cell["volumeUm3"],
                                 cell["equivalentDiameterUm"], cell["meanIntensity"],
                                 frame["analysisRevision"], frame["measurementRevision"],
                                 "processed-source" if image.get("derivation") else "raw-source"])
    return output.getvalue().encode("utf-8")


def _prepare_export(store, document, request, *, preserve_worker_records=False):
    if document.get("storageFormat") == 2:
        return package2.prepare_export(store, document, request)
    destination = absolute_path(request["arguments"]["destination"], "destination")
    if destination.suffix.lower() != ".zip":
        raise WorkbenchError("invalid-path", "Export destination must have a .zip extension.")
    if not destination.parent.is_dir():
        raise WorkbenchError("invalid-path", "Export parent directory must exist.")
    if destination.exists():
        raise WorkbenchError("destination-exists", "Export never overwrites an existing destination.")
    for image in document["images"]:
        if image.get("analysis"):
            _current_analysis(store, image, verify_files=False)
        for frame in image.get("volumeFrames", []):
            volume.current_frame(store, image, frame["timeIndex"], frame["channel"], verify=False)
    references = packages.artifact_references(document, packages.store_json_reader(store))
    paths = {ref: store.artifact_path(ref) for ref in references}
    provenance = {
        "schemaVersion": 1, "engineVersion": ENGINE_VERSION,
        "projectId": document["id"], "sourceRevision": document["revision"],
        "requestId": request["requestId"], "exportedAt": utc_now(),
        "coordinateSpace": "pixel-edges", "intensityUnits": "raw-source",
        "calibrationUnit": "pixels-per-micrometre",
        "coordinateSystems": {
            "plane": {"coordinates": "pixel-edges", "centres": "index + 0.5",
                      "physicalScale": "voxelSizeUm.x and .y; pxPerUm only for isotropic XY"},
            "volume": {"coordinates": "voxel-edges", "centres": "index + 0.5",
                       "arrayOrder": "ZYX", "coordinateOrder": "XYZ",
                       "physicalScale": "voxelSizeUm: micrometres per voxel along each axis",
                       "timeScale": "timeStepSeconds: seconds per frame",
                       "unknownCalibration": None,
                       "displaySampling": "display previews are resampled; saved labels and measurements retain source resolution"},
        },
        "supportedAnalysis": "2D and per-time 3D classical threshold and watershed",
        "runtimeDependencies": packages.runtime_versions(),
        "plugins": [plugins.describe(plugin) for plugin in document.get("plugins", [])],
        "models": [models.describe(model) for model in document.get("models", [])],
    }
    packaged_document = ({**document, "jobWorkers": batch_jobs.inspect_workers(store, document)}
                         if document.get("jobWorkers") and not preserve_worker_records else document)
    generated = {
        "project.json": (canonical(packaged_document) + "\n").encode("utf-8"),
        "measurements.csv": _csv(document),
        "volume-measurements.csv": _volume_csv(document),
        "volume-summary.json": (canonical(volume.summary(document)) + "\n").encode("utf-8"),
        "tracks.json": (canonical({"tracks": [volume.describe_tracks(image, track["channel"])
                                              for image in document["images"]
                                              for track in image.get("volumeTracks", [])]}) + "\n").encode("utf-8"),
        "summary.json": (canonical(_summary(document)) + "\n").encode("utf-8"),
        "experiment-summary.json": (canonical(experiments.summarize(document)) + "\n").encode("utf-8"),
        "review-summary.json": (canonical(review.summary(document)) + "\n").encode("utf-8"),
        "review-records.json": (canonical({
            "schemaVersion": 1, "flags": document.get("reviewFlags", []),
            "sessions": document.get("reviewSessions", []),
            "identityAssurance": "declared-local-identities; no authentication",
            "blindingScope": "presentation-only; this package retains complete source identities and evidence",
        }) + "\n").encode("utf-8"),
        "large-sources.json": (canonical({"sources": [sources.describe(source)
                                                   for source in document.get("largeSources", [])]}) + "\n").encode("utf-8"),
        "lineages.json": (canonical(lineages.export(store, document)) + "\n").encode("utf-8"),
        "registrations.json": (canonical({"registrations": [
            registration.inspect(image, document) for image in document["images"]
            if image.get("derivation", {}).get("kind") == "registration"]}) + "\n").encode("utf-8"),
        "provenance.json": (canonical(provenance) + "\n").encode("utf-8"),
    }
    manifest = {"schemaVersion": 1, "files": {
        **references, **{name: hashlib.sha256(data).hexdigest() for name, data in generated.items()},
    }}
    generated["manifest.json"] = (canonical(manifest) + "\n").encode("utf-8")
    if len(paths) + len(generated) > packages.MAX_MEMBERS:
        raise WorkbenchError("package-too-large", "A re-executable package supports at most 10,000 retained files.")
    if sum(path.stat().st_size for path in paths.values()) + sum(map(len, generated.values())) > packages.MAX_EXPANDED_BYTES:
        raise WorkbenchError("package-too-large", "A re-executable package supports at most 4 GiB of expanded data. Split the project before export.")
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".cellcounter-export-", suffix=".zip",
                                         delete=False) as temporary:
            temp_path = Path(temporary.name)
        with zipfile.ZipFile(temp_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=4, allowZip64=True) as archive:
            for ref, path in sorted(paths.items()):
                # Hash the exact bytes entering the archive. This avoids a
                # verify-then-copy race and repeated reads of large TIFF files.
                checksum = hashlib.sha256()
                with path.open("rb") as source, archive.open(ref, "w", force_zip64=True) as target:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        checksum.update(block)
                        target.write(block)
                if checksum.hexdigest() != references[ref]:
                    raise WorkbenchError("artifact-changed", "A project artifact changed while the package was being exported.",
                                         {"artifact": ref})
            for name, data in generated.items():
                archive.writestr(name, data)
        with temp_path.open("rb") as stream:
            os.fsync(stream.fileno())
        if temp_path.stat().st_size > packages.MAX_ARCHIVE_BYTES:
            raise WorkbenchError("package-too-large", "A re-executable package supports at most 2 GiB compressed. Split the project before export.")
        digest = file_hash(temp_path)
        result = {"destination": str(destination), "sha256": digest,
                  "sourceRevision": document["revision"], "files": sorted([*references, *generated])}

        def cleanup_publication():
            try:
                if os.path.samefile(str(destination), str(temp_path)):
                    destination.unlink()
                    sync_directory(destination.parent)
            except FileNotFoundError:
                pass

        def publish():
            try:
                os.link(str(temp_path), str(destination))
            except FileExistsError:
                raise WorkbenchError("destination-exists", "Export never overwrites an existing destination.")
            try:
                sync_directory(destination.parent)
            except OSError:
                cleanup_publication()
                raise
            return cleanup_publication

        return result, publish, temp_path
    except Exception:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)
        raise


def _execute_scientific_step(store, document, step, selected, revision):
    """One scientific implementation shared by linear and DAG checkpoints."""
    image = _image(document, selected["imageId"])
    kind = step["type"]
    retained = {}
    measured = None
    if kind == "analysis":
        if image.get("analysis"):
            _current_analysis(store, image)
        parameters = step["parameters"]
        plane = _source(store, image, parameters)
        labels, stats = imaging.segment(plane, parameters, support.load(store, image, plane.shape, parameters))
        measured = _set_analysis(store, image, labels, plane, parameters, revision, stats)
    elif kind == "volume-analysis":
        measured = volume.execute(store, image, "volume.analysis.run", {**selected, "parameters": step["parameters"]}, revision)
    elif kind in ("plugin-segmentation", "plugin-measurement"):
        result = plugins.execute_step(store, document, step, selected, revision,
                                      {"image": _image, "source": _source, "labels": _labels,
                                       "current_analysis": _current_analysis, "set_analysis": _set_analysis})
        measured = result.get("analysis")
        run = result["run"]
        retained = {"pluginRunId": run["runId"], "outputHash": run["outputHash"], "packageHash": run["packageHash"]}
    elif kind == "model-segmentation":
        result = workflows.execute_model_step(store, document, step, selected, revision)
        measured = result["analysis"]
        retained = {"modelId": step["modelId"], "checkpointHash": step["checkpointHash"],
                    "pythonHash": step["pythonHash"],
                    **{key: step[key] for key in ("backend", "inferenceSchemaHash", "environmentHash") if key in step}}
    elif kind == "assay":
        result = workflows.execute_assay_step(store, document, step, selected, revision)
        run = result["run"]
        retained = {"assayRunId": run["runId"], "assay": run["assay"], "outputHash": run["outputHash"],
                    "inputFingerprint": run["inputFingerprint"]}
    else:
        raise WorkbenchError("unsupported-workflow-node", "The scientific checkpoint type is unsupported.")
    if measured is not None:
        retained.update({"cellCount": measured["cellCount"], "analysisRevision": measured["analysisRevision"]})
    return retained


def _advance_job(store, document, request, actor, *, job_id=None, result_builder=None):
    with batch_jobs.advance_guard(store):
        return _advance_job_unit(store, document, request, actor, job_id=job_id, result_builder=result_builder)


def _advance_job_unit(store, document, request, actor, *, job_id=None, result_builder=None):
    job_id = job_id or request["arguments"]["jobId"]
    job = workflows.get_job(document, job_id)
    if job["status"] not in ("pending", "running"):
        raise WorkbenchError("invalid-job-state", f"Cannot advance a {job['status']} job.")
    temporary = None
    publish = None
    publication = None
    # Failed computations must not preserve partial changes to an image or job.
    before = copy.deepcopy(document)
    try:
        distributed.guard_job(store, document, job)
        workflows.check_inputs(document, job)
        unit = workflows.next_unit(job)
        job["status"] = "running"
        if "stepIndex" in unit:
            checkpoint = next(item for item in job["checkpoints"] if item["imageId"] == unit["imageId"] and
                              all(item.get(key) == unit.get(key) for key in ("timeIndex", "channel")))
            execution_checkpoint = workflows.execution_checkpoint(checkpoint)
            image = _image(document, execution_checkpoint["imageId"])
            step = workflows.execution_step(workflows.execution_steps(job["workflow"])[unit["stepIndex"]], checkpoint)
        if unit["type"] == "graph-node":
            graphs.advance_node(store, document, job, unit, document["revision"] + 1)
        elif unit["type"] == "preprocessing":
            image, retained = workflows.execute_preprocessing_step(
                store, document, step, checkpoint, document["revision"] + 1,
                {"image": _image, "source": _source})
            workflows.complete_step(job, checkpoint, image, retained, document["revision"] + 1)
        elif unit["type"] in ("image", "volume", "plugin", "model", "assay"):
            retained = _execute_scientific_step(store, document, step, execution_checkpoint, document["revision"] + 1)
            checkpoint.update({key: retained[key] for key in ("cellCount", "analysisRevision") if key in retained})
            workflows.complete_step(job, checkpoint, image, retained, document["revision"] + 1)
        elif unit["type"] == "summary" and job.get("kind") == "dag":
            job["summary"] = graphs.summarize(store, document, job)
        elif unit["type"] == "summary":
            subset = {**document, "images": []}
            working = {}
            for checkpoint in job["checkpoints"]:
                selected = workflows.execution_checkpoint(checkpoint)
                working.setdefault(selected["imageId"], []).append(selected)
            if workflows.is_volume(job["workflow"]):
                for image_id, selected in working.items():
                    image = _image(document, image_id)
                    frames = [volume.current_frame(store, image, checkpoint["timeIndex"], checkpoint["channel"])
                              for checkpoint in selected]
                    subset["images"].append({**image, "volumeFrames": frames})
                job["summary"] = volume.summary(subset)
            else:
                for image_id in working:
                    image = _image(document, image_id)
                    _current_analysis(store, image)
                    subset["images"].append(image)
                job["summary"] = _summary(subset)
            job["summary"]["scopeImageIds"] = list(working)
            if workflows.has_preprocessing(job["workflow"]):
                job["summary"]["sourceImageIds"] = list(job["imageIds"])
                job["summary"]["processedInputs"] = [
                    {key: copy.deepcopy(checkpoint[key]) for key in
                     ("imageId", "sourceSelection", "workingImageId", "workingSelection")}
                    for checkpoint in job["checkpoints"]]
                job["summary"]["processingNotes"] = [
                    "Measurements describe processed acquisitions and their retained intensity transformation.",
                    "Original specimen, well and review assignments were not copied to processed acquisitions.",
                    "Volume frame outputs retain their original time selection in processedInputs; their local time index is 0.",
                ]
            plugin_run_ids = {result["pluginRunId"] for checkpoint in job["checkpoints"]
                              for result in checkpoint.get("stepResults", []) if "pluginRunId" in result}
            if plugin_run_ids:
                job["summary"]["pluginRuns"] = [
                    {key: run[key] for key in ("runId", "imageId", "pluginId", "kind", "target", "timeIndex",
                                               "channel", "measurementCount", "summary", "units") if key in run}
                    for run in document.get("pluginRuns", []) if run["runId"] in plugin_run_ids]
            assay_run_ids = {result["assayRunId"] for checkpoint in job["checkpoints"]
                             for result in checkpoint.get("stepResults", []) if "assayRunId" in result}
            if assay_run_ids:
                job["summary"]["assayRuns"] = [assays.describe(document, run)
                                               for run in document.get("assayRuns", []) if run["runId"] in assay_run_ids]
        elif unit["type"] == "export":
            step = next(step for step in job["workflow"]["steps"] if step["type"] == "export")
            export_request = {**request, "arguments": {"destination": step["destination"]}}
            # Export is explicitly the complete project; the job's own summary is target-scoped.
            result, publish, temporary = _prepare_export(store, document, export_request)
            publication = {key: result[key] for key in ("destination", "sha256")}
            job["export"] = {**result, "scope": "complete-project",
                             "projectInputFingerprint": workflows.project_fingerprint(document)}
        job["updatedAt"] = utc_now()
        if workflows.next_unit(job) is None:
            job["status"] = "completed"
            job["completedRevision"] = document["revision"] + 1
    except (WorkbenchError, OSError) as exc:
        document = before
        job = workflows.get_job(document, job_id)
        code = exc.code if isinstance(exc, WorkbenchError) else "storage-error"
        job["status"] = "blocked" if code in ("stale-job-input", "artifact-changed", "stale-analysis") else "failed"
        job["error"] = {"code": code, "message": str(exc)}
        if job.get("kind") == "dag" and "unit" in locals():
            job["error"]["unit"] = {key: unit[key] for key in ("nodeId", "nodeType", "imageId", "timeIndex", "checkpointIndex") if key in unit}
        if isinstance(exc, WorkbenchError) and exc.details is not None:
            job["error"]["details"] = exc.details
        job["updatedAt"] = utc_now()
    try:
        result = (result_builder(document, job) if result_builder is not None
                  else {"job": workflows.describe_job(job, document)})
        return store.commit(request, document, result, actor,
                            publish, publication)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _execute(request):
    entry, arguments, actor = validate_request(request)
    operation = request["operation"]
    if operation == "operations.discover":
        from _workbench_discovery import discover
        return _success(request, discover(arguments))
    if operation == "capabilities":
        deps = imaging.dependencies()
        return _success(request, {
            "engineVersion": ENGINE_VERSION, "operations": operation_catalog(),
            "dependencies": deps,
            "segmentation": {"available": all(deps.values()), "methods": ["otsu", "manual", "triangle", "li", "yen", "mean", "adaptive"],
                             "planeMethods": ["otsu", "manual", "triangle", "li", "yen", "mean", "adaptive"],
                             "volumeMethods": ["otsu", "manual"],
                             "device": "cpu", "dimensions": [2, 3]},
            "sourceFormats": ["TIFF", "PNG", "JPEG", "BMP"],
            "supportedAxes": list(imaging.SUPPORTED_AXES),
            "limits": {"planePixels": imaging.MAX_PIXELS, "sourceBytes": 512 * 1024 * 1024,
                       "decodeBytes": imaging.MAX_DECODE_BYTES, "channels": 32, "instances": imaging.MAX_CELLS,
                       "indexedProjectImages": 100000, "imagePage": 500, "measurementPage": 1000,
                       "packageBytes": package2.MAX_BYTES, "packageArtifacts": package2.MAX_REFS,
                       "volumeVoxels": volume.MAX_VOLUME_VOXELS, "displayVolumeDimension": 128,
                       "trackingObjectsPerFrame": volume.MAX_TRACK_OBJECTS},
            "multiTimeAnalysis": True, "twoDimensionalMultiTimeAnalysis": False,
            "executablePlugins": True, "learnedInference": True,
            "learnedBackends": [entry["id"] for entry in models.catalog()["backends"]], "modelInstallation": "explicit-local-environment-and-checkpoint",
            "pluginKinds": list(plugins.SUPPORTED_KINDS),
            "coordinateSpace": "pixel-edges", "intensityUnits": "raw-source",
        })
    if operation == "project.create":
        created = utc_now()
        document = {"schemaVersion": 1, "id": str(uuid.uuid4()), "name": arguments["name"],
                    "revision": 0, "createdAt": created, "updatedAt": created,
                    "images": [], "history": [{
                        "revision": 0, "operation": operation, "requestId": request["requestId"],
                        "actor": actor, "at": created, "arguments": arguments,
                    }]}
        response = _success(request, _inspection(document), 0)
        _, response = ProjectStore.create(request["projectPath"], document, request, response)
        return response
    if operation == "package.inspect":
        return _success(request, package2.inspect(arguments["path"]) if package2.is_package2(arguments["path"]) else packages.inspect(arguments["path"]))
    if operation.startswith("package.restore."):
        return package2.execute(request, actor)
    if operation in ("omero.runtime.configure", "omero.profile.save"):
        return _success(request, omero.configure_request(request))
    if operation.startswith("runtime."):
        return _success(request, runtimes.execute(request))
    if operation.startswith("omero.") and operation != "omero.import.run":
        return _success(request, omero.execute(None, None, operation, arguments, 0))
    if operation == "temporal.catalogue":
        return _success(request, temporal.catalogue())
    if operation == "experiment.layout.catalogue":
        return _success(request, experiment_layouts.catalogue())
    if operation == "statistics.catalogue":
        return _success(request, statistical.catalogue())
    if operation == "statistics.export.catalogue":
        return _success(request, statistics_exports.catalogue())
    if operation == "tiled.analysis.export.catalogue":
        return _success(request, {"formats": copy.deepcopy(tiled.EXPORT_FORMATS)})
    if operation == "tiled.analysis.catalogue":
        return _success(request, tiled.catalogue())
    if operation == "zarr.catalogue":
        return _success(request, zarr_sources.catalogue())
    if operation == "resource.report":
        return _success(request, sessions.resource_report())
    if operation == "workspace.catalogue":
        return _success(request, workspaces.catalogue())
    if operation == "migration.library.catalogue":
        return _success(request, migration.catalogue())
    if operation == "migration.library.capture":
        return _success(request, migration.capture(request))
    if operation == "migration.library.preview":
        return _success(request, migration.preview(arguments)[0])
    if operation == "migration.library.run":
        return migration.start(request, actor)
    if operation == "preprocessing.catalogue":
        return _success(request, preprocessing.catalogue())
    if operation == "package.restore":
        return package2.restore(request, actor) if package2.is_package2(arguments["path"]) else packages.restore(request, actor, _inspection)
    if operation == "assay.series.catalogue":
        return _success(request, assay_series.execute(None, None, "assay.series.catalogue", {}, 0))
    if operation == "assay.series.export.catalogue":
        return _success(request, {"formats": copy.deepcopy(assay_series.FORMATS)})
    if operation == "assay.catalog":
        return _success(request, {"assays": assays.catalog()})
    if operation == "model.catalog":
        return _success(request, models.catalog())
    if operation == "image.export.catalogue":
        return _success(request, image_exports.catalogue())
    if operation == "image.composite.catalogue":
        return _success(request, composite.catalogue())
    if operation == "image.composite.export.catalogue":
        return _success(request, composite_exports.catalogue())
    if operation == "display.preset.export.catalogue":
        return _success(request, display_preset_io.catalogue())
    if operation == "annotation.export.catalogue":
        return _success(request, image_exports.annotation_catalogue())
    if operation == "lineage.export.catalogue":
        return _success(request, image_exports.lineage_catalogue())
    if operation == "sweep.export.catalogue":
        return _success(request, sweep_reports.catalogue())
    if operation == "workflow.graph.catalogue":
        return _success(request, graphs.catalogue())
    if operation == "refresh.export.catalogue":
        return _success(request, refresh_reports.catalogue())
    store = ProjectStore(request["projectPath"])
    if operation.startswith("plugin.runtime."):
        document = store.read()
        _check_expected(document, request.get("expectedRevision"))
        plugin = plugins._record(document, arguments["pluginId"])
        plugins._verified(store, plugin)
        if operation.endswith(".bind"):
            return _success(request, runtimes.configure_request(request, plugin), document["revision"])
        if operation.endswith(".probe"):
            import _workbench_environment as environments
            binding = runtimes.resolve(package_hash=plugin["packageHash"])
            inventory = runtimes.capture(binding)
            try: dependencies = environments.check_constraints(inventory, plugin["manifest"]["dependencies"]) if "dependencies" in plugin["manifest"] else {"satisfied": True, "requirements": [], "scope": "no-dependencies-declared"}
            except ValueError as error: raise WorkbenchError("plugin-dependencies-unsatisfied", str(error))
            return _success(request, {"pluginId": plugin["pluginId"], "runtime": runtimes.identity(binding), "environment": inventory, "dependencies": dependencies, "notes": runtimes.notes()}, document["revision"])
        binding = runtimes.metadata_binding(package_hash=plugin["packageHash"])
        binding.pop("pythonPath", None)
        return _success(request, {"pluginId": plugin["pluginId"], "runtime": binding, "dependencies": plugin["manifest"].get("dependencies"), "notes": runtimes.notes()}, document["revision"])
    if operation == "project.changes":
        result = sessions.changes(store, arguments)
        return _success(request, result, result["projectRevision"])
    if operation.startswith("session."):
        return sessions.execute(store, request, actor)
    if entry["mutating"]:
        batch_jobs.check_control_request_id(store, request, actor)
        replay = store.replay(request)
        if replay is not None:
            if operation in ("adaptation.train.start", "adaptation.train.cancel"):
                models.after_commit(store, store.read(), operation, arguments, replay["result"])
            if operation in ("job.worker.start", "sweep.worker.start", "refresh.worker.start", "tiled.analysis.worker.start"):
                batch_jobs.after_commit(store, store.read(), replay["result"])
            return replay
    document = store.read(track_effects=entry["mutating"])
    _check_expected(document, request.get("expectedRevision"))
    input_revision = document["revision"]
    next_revision = input_revision + 1
    if operation.startswith("project.catalogue") or operation == "project.activity":
        result = (catalogues.activity(store, document) if operation == "project.activity" else
                  catalogues.get_many(store, document, arguments) if operation.endswith(".getMany") else
                  catalogues.get(store, document, arguments) if operation.endswith(".get") else
                  catalogues.page(store, document, arguments))
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if (operation.startswith("experiment.layout.") or operation.startswith("experiment.exclusion.")
            or operation.startswith("acquisition.session.")):
        result = experiment_layouts.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation in ("project.snapshot", "image.list", "image.get", "project.history", "measurements.page", "measurements.lookup", "mask.pick", "mask.overlay", "project.storage.inspect", "project.storage.upgrade.preview", "project.storage.upgrade.run"):
        result = pages.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "omero.import.run":
        result = omero.execute(store, document, operation, arguments, next_revision)
        return store.commit(request, document, result, actor)
    if operation.startswith("temporal."):
        result = temporal.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "statistics.export":
        result, publish, temporary, publication = statistics_exports.prepare_export(
            store, document, arguments, next_revision, request["requestId"], actor)
        try:
            return store.commit(request, document, result, actor, publish, publication)
        finally:
            temporary.unlink(missing_ok=True)
    if operation.startswith("statistics."):
        result = statistical.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "image.relink.run":
        result, publish, temporary, publication = library.prepare_relink(
            store, document, arguments, next_revision, request["requestId"], actor)
        try:
            return store.commit(request, document, result, actor, publish, publication)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    if (operation.startswith("library.") or operation.startswith("collection.") or
            operation.startswith("image.metadata.") or operation in ("image.archive", "image.relink.preview")):
        result = library.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "tiled.analysis.export":
        result, publish, temporary, publication = tiled.prepare_export(
            store, document, arguments, next_revision, request["requestId"], actor)
        try:
            return store.commit(request, document, result, actor, publish, publication)
        finally:
            temporary.unlink(missing_ok=True)
    if operation.startswith("tiled.analysis.") and operation != "tiled.analysis.worker.start":
        if operation == "tiled.analysis.advance":
            with batch_jobs.advance_guard(store):
                result = tiled.execute(store, document, operation, arguments, next_revision)
                return store.commit(request, document, result, actor)
        result = tiled.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("zarr."):
        result = zarr_sources.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation in ("workspace.export", "workspace.output.export"):
        result, publish, temporary, publication = workspaces.prepare_export(
            store, document, operation, arguments, next_revision, request["requestId"], actor)
        try:
            return store.commit(request, document, result, actor, publish, publication)
        finally:
            temporary.unlink(missing_ok=True)
    if operation.startswith("workspace.") or operation in ("semantic.render", "pointlineage.build", "animation.render"):
        result = workspaces.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("migration."):
        result = migration.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation in ("distribution.bundle.export", "distribution.result.export"):
        result, publish, temporary, publication = distributed.prepare_export(
            store, document, operation, arguments, next_revision, request["requestId"], actor)
        try:
            return store.commit(request, document, result, actor, publish, publication)
        finally:
            temporary.unlink(missing_ok=True)
    if operation.startswith("distribution."):
        result = distributed.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "refresh.results":
        result = refresh_reports.read(store, document, arguments)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation in ("annotation.export", "lineage.export", "sweep.export", "image.composite.export", "display.preset.export", "refresh.export"):
        prepare = {"annotation.export": image_exports.prepare_annotation_export,
                   "lineage.export": image_exports.prepare_lineage_export,
                   "sweep.export": sweep_reports.prepare_export,
                   "image.composite.export": composite_exports.prepare_export,
                   "display.preset.export": display_preset_io.prepare_export,
                   "refresh.export": refresh_reports.prepare_export}[operation]
        result, publish, temporary, publication = prepare(
            store, document, arguments, next_revision, request["requestId"], actor)
        try:
            return store.commit(request, document, result, actor, publish, publication)
        finally:
            temporary.unlink(missing_ok=True)
    if operation.startswith("display.preset.import."):
        result = display_preset_io.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("display.preset."):
        result = display_presets.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("annotation."):
        result = annotations.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("mask.import."):
        result = label_imports.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "image.export":
        result, publish, temporary, publication = image_exports.prepare_export(
            store, document, arguments, next_revision, request["requestId"], actor)
        try:
            return store.commit(request, document, result, actor, publish, publication)
        finally:
            temporary.unlink(missing_ok=True)
    if operation.startswith("job.worker.") or operation in ("sweep.worker.start", "refresh.worker.start", "tiled.analysis.worker.start"):
        if operation in ("job.worker.start", "sweep.worker.start", "refresh.worker.start", "tiled.analysis.worker.start"):
            with batch_jobs.start_guard(store):
                result = batch_jobs.prepare_start(store, document, request, actor)
                response = store.commit(request, document, result, actor)
            batch_jobs.after_commit(store, store.read(), response["result"])
            return response
        if operation == "job.worker.stop":
            result, revision = batch_jobs.request_stop(store, document, request, actor)
            return _success(request, result, revision)
        result = batch_jobs.read(store, document, operation, arguments)
        return _success(request, result, input_revision)
    if operation == "project.inspect":
        return _success(request, _inspection(document, store), input_revision)
    if operation.startswith("workflow.graph."):
        result = graphs.preview(document, arguments) if operation == "workflow.graph.preview" else graphs.save(document, arguments)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("job.graph.review.") or operation.startswith("job.graph.continue."):
        import _workbench_graph_controls as graph_controls
        if operation.startswith("job.graph.review."):
            result = graph_controls.execute_review(document, operation, arguments, next_revision, actor)
        elif operation == "job.graph.continue.preview":
            result = graph_controls.continuation_preview(store, document, arguments)
        else:
            result = graph_controls.continue_job(store, document, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "job.graph.node.preview":
        result = graphs.preview_node(store, document, arguments)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("refresh."):
        if operation == "refresh.advance":
            with batch_jobs.advance_guard(store):
                result = refresh.execute(store, document, operation, arguments, next_revision, actor)
                return store.commit(request, document, result, actor)
        result = refresh.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "sweep.results":
        result = sweep_reports.read(store, document, arguments)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("sweep."):
        if operation == "sweep.advance":
            group = sweeps.get(document, arguments["sweepId"])
            job = sweeps.check_advance(document, group)
            return _advance_job(store, document, request, actor, job_id=job["id"],
                                result_builder=lambda current, advanced: {
                                    "job": workflows.describe_job(advanced, current),
                                    "sweep": sweeps.describe(current, sweeps.get(current, group["id"]))})
        result = sweeps.execute(store, document, operation, arguments, next_revision,
                                {"image": _image, "current_analysis": _current_analysis})
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "mask.compare":
        result = comparison.execute(store, document, arguments)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "image.composite.preview":
        result = composite.preview(store, _image(document, arguments["imageId"]), arguments, document=document)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "image.composite.volume":
        result = composite.volume_display(store, _image(document, arguments["imageId"]), arguments, document=document)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("source."):
        result = sources.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("lineage."):
        result = lineages.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("registration."):
        result = registration.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("review."):
        result = review.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "image.duplicate":
        result = variants.execute(store, document, arguments, next_revision,
                                  {"image": _image, "current_analysis": _current_analysis})
        return store.commit(request, document, result, actor)
    if operation.startswith(("model.card.", "model.activation.")):
        result = model_cards.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith(("model.", "adaptation.train.")):
        result = models.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            response = store.commit(request, document, result, actor)
            models.after_commit(store, document, operation, arguments, response["result"])
            return response
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation in ("assay.metrics", "experiment.assay.summary"):
        result = assay_summary.execute(store, document, operation, arguments)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "assay.series.export":
        result, publish, temporary, publication = assay_series.prepare_export(store, document, arguments, next_revision, request["requestId"], actor)
        try: return store.commit(request, document, result, actor, publish, publication)
        finally: temporary.unlink(missing_ok=True)
    if operation.startswith("assay.series."):
        result = assay_series.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]: return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("assay."):
        result = assays.execute(store, document, operation, arguments, next_revision)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith("preprocessing."):
        result = preprocessing.execute(store, document, operation, arguments, next_revision,
                                       {"image": _image, "source": _source})
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith(("plugin.", "adaptation.")):
        if operation.startswith("plugin."):
            hooks = {
                "image": _image, "source": _source, "labels": _labels,
                "current_analysis": _current_analysis, "set_analysis": _set_analysis,
            }
            if operation == "plugin.export":
                result, publish, temporary, publication = plugins.prepare_export(
                    store, document, arguments, next_revision, hooks)
                try:
                    return store.commit(request, document, result, actor, publish, publication)
                finally:
                    temporary.unlink(missing_ok=True)
            result = plugins.execute(store, document, operation, arguments, next_revision, hooks)
        else:
            result = adaptation.execute(store, document, operation, arguments, next_revision, actor)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation.startswith(("volume.", "tracks.")):
        image = _image(document, arguments["imageId"])
        result = volume.execute(store, image, operation, arguments, next_revision)
        if operation == "volume.calibration.set" and image.get("analysis"):
            analysis = image["analysis"]
            analysis["cells"] = imaging.measure(_labels(store, image), _source(store, image, analysis["parameters"]),
                                                 image["pxPerUm"], volume.calibration(image))
            analysis["measurementRevision"] = next_revision
            analysis["inputFingerprint"] = _fingerprint(image, analysis)
            support.refresh_calibration(image, analysis)
        if entry["mutating"]:
            return store.commit(request, document, result, actor)
        _check_expected(store.read(), input_revision)
        return _success(request, result, input_revision)
    if operation == "experiment.get":
        return _success(request, experiments.describe(document), input_revision)
    if operation == "experiment.summary":
        for image in document["images"]:
            if image.get("analysis"):
                _current_analysis(store, image)
        _check_expected(store.read(), input_revision)
        return _success(request, experiments.summarize(document), input_revision)
    if operation in ("specimen.set", "plate.set", "image.assign", "image.unassign"):
        result = experiments.apply(document, operation, arguments)
        return store.commit(request, document, result, actor)
    if operation.startswith(("workflow.", "job.")):
        if not entry["mutating"]:
            return _success(request, workflows.read(document, operation, arguments), input_revision)
        if operation == "job.advance":
            return _advance_job(store, document, request, actor)
        result = workflows.apply(document, operation, arguments)
        return store.commit(request, document, result, actor)
    if operation == "summary.get":
        for image in document["images"]:
            if image.get("analysis"):
                _current_analysis(store, image)
            for frame in image.get("volumeFrames", []):
                volume.current_frame(store, image, frame["timeIndex"], frame["channel"])
        _check_expected(store.read(), input_revision)
        return _success(request, _summary(document), input_revision)
    if operation == "measurements.get":
        image = _image(document, arguments["imageId"])
        analysis = _current_analysis(store, image)
        _check_expected(store.read(), input_revision)
        return _success(request, _measurement_result(image, analysis), input_revision)
    if operation in ("image.preview", "analysis.preview", "analysis.run"):
        image = _image(document, arguments["imageId"])
        if operation == "image.preview" and "parameters" not in arguments and image.get("analysis"):
            parameters = image["analysis"]["parameters"]
        else:
            parameters = analysis_parameters({"parameters": {
                **image.get("preferredSourceParameters", {}), **arguments.get("parameters", {})}})
        plane = _source(store, image, parameters)
        if operation == "image.preview":
            result = {"imageId": image["id"], "parameters": parameters,
                      **imaging.preview_data(plane, max_size=arguments.get("maxSize", 768))}
            _check_expected(store.read(), input_revision)
            return _success(request, result, input_revision)
        valid = support.load(store, image, plane.shape, parameters)
        labels, stats = imaging.segment(plane, parameters, valid)
        if operation == "analysis.preview":
            cells = imaging.measure(labels, plane, image["pxPerUm"], volume.calibration(image))
            result = {"imageId": image["id"], "cells": cells, "cellCount": len(cells),
                      "pxPerUm": image["pxPerUm"], "calibrated": volume.xy_calibrated(image),
                      "parameters": parameters, "imageStats": stats,
                      "validSupport": support.summary(image, valid, plane.shape),
                      "coordinateSpace": "pixel-edges",
                      "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
                      **imaging.preview_data(plane, max_size=arguments.get("maxSize", 768))}
            result["overlayDataUrl"] = imaging.preview_data(plane, labels, max_size=arguments.get("maxSize", 768))["dataUrl"]
            _check_expected(store.read(), input_revision)
            return _success(request, result, input_revision)
        result = _set_analysis(store, image, labels, plane, parameters, next_revision, stats)
        return store.commit(request, document, result, actor)
    if operation == "image.import":
        from _workbench_indexed import image_capacity, RecordList
        if len(document["images"]) + len(arguments["paths"]) > image_capacity(document):
            raise WorkbenchError("project-too-large", "This import exceeds the project acquisition bound. Upgrade format1 storage or reduce the batch.")
        imported = []
        duplicates = []
        acquisitions = {} if isinstance(document["images"], RecordList) else {(image.get("importedFrom"), image["sourceHash"]): image
                        for image in document["images"] if image.get("importedFrom")}
        for path_string in arguments["paths"]:
            source = absolute_path(path_string, "paths")
            # Inspect before copying so unsupported images do not leave large unused artifacts.
            imaging.inspect_source(source)
            reference, checksum, size = store.import_file(str(source))
            acquisition = (str(source), checksum)
            existing = acquisitions.get(acquisition)
            if existing is None and isinstance(document["images"], RecordList):
                rows = document["images"]
                found = rows.view.query("SELECT r.entity_id FROM records r JOIN image_index i ON i.record_key=r.record_key WHERE r.collection='images' AND i.source_hash=? AND i.imported_from=? LIMIT 1", (checksum, str(source))).fetchone()
                if found: existing = rows.find(found[0])
            if existing is not None:
                duplicates.append(existing["id"])
                continue
            metadata = imaging.inspect_source(store.artifact_path(reference))
            scale = arguments.get("pxPerUm", metadata["metadataPxPerUm"])
            voxels = dict(metadata["voxelSizeUm"])
            if "pxPerUm" in arguments:
                voxels.update({"x": 1 / scale, "y": 1 / scale})
            image = {
                "id": str(uuid.uuid4()), "name": source.name, "sourcePath": reference,
                "sourceHash": checksum, "sourceBytes": size, "importedAt": utc_now(),
                "importedFrom": str(source),
                "pxPerUm": scale,
                "voxelSizeUm": voxels, "timeStepSeconds": metadata["timeStepSeconds"],
                "calibrationSource": "manual" if "pxPerUm" in arguments else "metadata" if scale else "unknown",
                "undoStack": [],
                **{key: metadata[key] for key in ("width", "height", "channels", "axes", "shape", "dtype", "zCount", "timeCount")},
            }
            document["images"].append(image)
            acquisitions[acquisition] = image
            imported.append(image["id"])
        result = {"importedImageIds": imported, "duplicateImageIds": duplicates,
                  "images": [_image_inspection(document, _image(document, identifier)) for identifier in dict.fromkeys([*imported, *duplicates])],
                  "imageCount": len(document["images"])}
        return store.commit(request, document, result, actor)
    if operation == "calibration.set":
        image = _image(document, arguments["imageId"])
        previous = image.get("analysis")
        volume.recalibrate(store, image, {"voxelSizeUm": {"x": 1 / arguments["pxPerUm"],
                                                         "y": 1 / arguments["pxPerUm"]}}, next_revision)
        image["calibrationSource"] = "manual"
        if previous is not None:
            labels = _labels(store, image)
            plane = _source(store, image, previous["parameters"])
            previous["cells"] = imaging.measure(labels, plane, image["pxPerUm"], volume.calibration(image))
            previous["measurementRevision"] = next_revision
            previous["inputFingerprint"] = _fingerprint(image, previous)
            support.refresh_calibration(image, previous)
            result = _measurement_result(image)
        else:
            result = {"imageId": image["id"], "pxPerUm": image["pxPerUm"], "calibrated": True}
        return store.commit(request, document, result, actor)
    if operation in ("mask.edit", "mask.undo"):
        image = _image(document, arguments["imageId"])
        analysis = _current_analysis(store, image)
        if operation == "mask.edit":
            labels = imaging.edit_labels(_labels(store, image), arguments)
            parameters = analysis["parameters"]
            plane = _source(store, image, parameters)
            result = _set_analysis(store, image, labels, plane, parameters, next_revision)
            if analysis.get("model"):
                image["analysis"]["model"] = {**copy.deepcopy(analysis["model"]), "manuallyCorrected": True}
                result["model"] = image["analysis"]["model"]
        else:
            history = image.get("undoStack", [])
            if not history:
                raise WorkbenchError("nothing-to-undo", "No previous mask state is available.")
            previous = history.pop()
            labels = _labels(store, image, previous)
            parameters = previous["parameters"]
            plane = _source(store, image, parameters)
            result = _set_analysis(store, image, labels, plane, parameters, next_revision,
                                   previous["imageStats"], preserve_undo=False)
            if previous.get("model"):
                image["analysis"]["model"] = copy.deepcopy(previous["model"])
                result["model"] = image["analysis"]["model"]
        return store.commit(request, document, result, actor)
    if operation == "project.export":
        result, publish, temporary = _prepare_export(store, document, request)
        try:
            return store.commit(request, document, result, actor, publish,
                                {key: result[key] for key in ("destination", "sha256")})
        finally:
            temporary.unlink(missing_ok=True)
    raise WorkbenchError("unknown-operation", "Operation is not supported.")


def dispatch(request: dict) -> dict:
    """Execute a single command, returning the same JSON envelope on every path."""
    from _workbench_indexed import close_views, begin_view_scope
    view_token = begin_view_scope()
    runtime_token = runtimes.begin_request()
    try:
        response = _execute(request)
        encoded = canonical(response)
        if len(encoded.encode()) > 24 * 1024 ** 2:
            raise WorkbenchError("result-too-large", "Use paged reads; this response exceeds24MiB.")
        return json.loads(encoded)
    except WorkbenchError as exc:
        error = {"code": exc.code, "message": exc.message}
        if exc.details is not None:
            error["details"] = exc.details
    except (OSError, sqlite3.DatabaseError) as exc:
        error = {"code": "storage-error", "message": f"Cannot complete the filesystem or project operation: {exc}"}
    except (ValueError, TypeError, KeyError, IndexError) as exc:
        error = {"code": "invalid-data", "message": f"Invalid operation data: {exc}"}
    except Exception as exc:
        error = {"code": "operation-failed", "message": f"Operation failed: {type(exc).__name__}: {exc}"}
    finally:
        close_views(view_token)
        runtimes.end_request(runtime_token)
    return {"schemaVersion": 1, "ok": False,
            "operation": request.get("operation") if isinstance(request, dict) else None,
            "requestId": request.get("requestId") if isinstance(request, dict) else None, "error": error}
