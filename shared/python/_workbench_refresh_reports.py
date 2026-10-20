"""Retained reports of downstream recomputation, including skipped blockers."""
from __future__ import annotations

import copy
import csv
import io
import uuid

ENGINE_VERSION = "refresh-reports-1"
MAX_REPORT_BYTES = 16 * 1024 ** 2
FORMATS = [
    {"id": "results-json", "name": "Result refresh report (JSON)", "extension": "json",
     "mediaType": "application/json",
     "description": "Complete checkpoint history, previous/replacement results, frozen dependencies and skipped blockers."},
    {"id": "results-csv", "name": "Result refresh checkpoints (CSV)", "extension": "csv",
     "mediaType": "text/csv",
     "description": "One row per checkpoint or skipped blocker, with explicit completion and currentness."},
]


def catalogue():
    return {"formats": copy.deepcopy(FORMATS)}


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    return [
        _op("refresh.results", "Read a complete downstream refresh report without recalculating scientific results.",
            _object({"refreshId": _ID}, ["refreshId"])),
        _op("refresh.export.catalogue", "Describe saved result-refresh report formats.", _object(), project=False),
        _op("refresh.export", "Retain and publish a complete refresh report including skipped, incomplete and stale outputs.",
            _object({"refreshId": _ID, "format": {"type": "string", "enum": [item["id"] for item in FORMATS]},
                     "destination": _STRING}, ["refreshId", "format", "destination"]), True),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def build(store, document, refresh_id):
    from _workbench_refresh import build_report
    from _workbench_store import canonical
    report, references = build_report(store, document, refresh_id)
    report = copy.deepcopy(report)
    report["reportEngineVersion"] = ENGINE_VERSION
    report["executionComplete"] = report["complete"] is True
    report["coverageComplete"] = (report["executionComplete"] and report["outputsCurrent"] is True and
                                  not report["refresh"].get("skipped"))
    report["notes"] = list(report.get("notes", [])) + [
        "Execution completion describes the selected executable checkpoints; skipped blockers remain explicitly unresolved.",
        "Coverage is complete only when execution is complete, its outputs remain current and no selected blockers were skipped.",
        "Previous results remain historical; replacement links identify newly computed results without rewriting old outputs.",
        "This report does not modify saved masks, rerun segmentation or update previously exported files.",
    ]
    if len(canonical(report).encode("utf-8")) + 1 > MAX_REPORT_BYTES:
        fail("refresh-report-limit", "The complete result-refresh report exceeds its 16 MiB budget.")
    return report, references


def read(store, document, arguments):
    return build(store, document, arguments["refreshId"])[0]


def _csv(report, provenance_hash):
    from _workbench_exports import _csv_safe
    from _workbench_store import canonical
    refresh = report["refresh"]
    columns = [
        "row_type", "refresh_id", "refresh_name", "source_revision", "refresh_status", "definition_sha256",
        "execution_complete", "outputs_current", "coverage_complete", "provenance_sha256",
        "unit_id", "kind", "previous_run_id", "replacement_run_id", "image_id", "target", "time_index", "channel",
        "checkpoint_status", "checkpoint_outputs_current", "result_output_sha256", "completed_revision", "logical_key", "input_fingerprint",
        "entry_json", "refresh_runtime_json", "refresh_error_json",
    ]
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(columns)
    rows = [("checkpoint", unit) for unit in refresh.get("units", [])]
    rows.extend(("skipped", item) for item in refresh.get("skipped", []))
    if not rows:
        rows = [("summary", {})]
    for kind, entry in rows:
        # Skipped blocker structures can carry different selections; entry_json
        # preserves them exactly rather than filling in invented checkpoint data.
        values = [
            kind, refresh["id"], refresh["name"], report["sourceRevision"], refresh["status"], refresh["definitionHash"],
            report["executionComplete"], report["outputsCurrent"], report["coverageComplete"], provenance_hash,
            entry.get("id"), entry.get("kind"), entry.get("runId"), entry.get("resultRunId"),
            entry.get("imageId"), entry.get("target"), entry.get("timeIndex"), entry.get("channel"),
            entry.get("status"), entry.get("outputsCurrent"), entry.get("resultOutputHash"), entry.get("completedRevision"),
            entry.get("logicalKey"), entry.get("inputFingerprint"),
            canonical(entry), canonical(refresh.get("runtime")), canonical(refresh.get("error")),
        ]
        writer.writerow([_csv_safe(value) for value in values])
    return output.getvalue().encode("utf-8")


def prepare_export(store, document, arguments, revision, request_id, actor):
    from _workbench_exports import _destination, _stage_publication, MAX_EXPORTS
    from _workbench_store import canonical, utc_now
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "A project retains at most 1,000 built-in scientific exports.")
    definition = next(item for item in FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    report, references = build(store, document, arguments["refreshId"])
    refresh = report["refresh"]
    report_path, report_hash = store.put_bytes((canonical(report) + "\n").encode("utf-8"), ".refresh-report.json")
    provenance = {
        "schemaVersion": 1, "engineVersion": ENGINE_VERSION, "exportId": str(uuid.uuid4()),
        "projectId": document["id"], "sourceRevision": document["revision"], "exportRevision": revision,
        "refreshId": refresh["id"], "definitionHash": refresh["definitionHash"], "format": definition["id"],
        "createdAt": utc_now(), "requestId": request_id, "actor": copy.deepcopy(actor),
        "reportSha256": report_hash, "checkpointCount": len(refresh.get("units", [])),
        "skippedCount": len(refresh.get("skipped", [])),
        "executionComplete": report["executionComplete"], "outputsCurrent": report["outputsCurrent"],
        "coverageComplete": report["coverageComplete"],
        "notes": report["notes"] + [
            "Exports include all selected checkpoints and skipped blockers, independent of desktop pagination.",
            "JSON columns in CSV preserve exact dependency, method and runtime records; missing scalar values remain empty.",
            "CSV text that could be interpreted as a spreadsheet formula is prefixed with an apostrophe.",
        ],
    }
    provenance_path, provenance_hash = store.put_bytes((canonical(provenance) + "\n").encode("utf-8"),
                                                     ".refresh-report-provenance.json")
    contents = ((canonical({"schemaVersion": 1, "format": "cellcounter-refresh-results", "report": report,
                            "provenance": provenance, "provenanceSha256": provenance_hash}) + "\n").encode("utf-8")
                if definition["id"] == "results-json" else _csv(report, provenance_hash))
    if len(contents) > MAX_REPORT_BYTES:
        fail("refresh-report-limit", "The complete result-refresh export exceeds its 16 MiB budget.")
    file_path, checksum = store.put_bytes(contents, ".refresh-export." + definition["extension"])
    item = {"exportId": provenance["exportId"], "kind": "refresh", "refreshId": refresh["id"], "format": definition["id"],
            "createdAt": provenance["createdAt"], "revision": revision, "destination": str(destination),
            "filePath": file_path, "fileHash": checksum, "provenancePath": provenance_path, "provenanceHash": provenance_hash,
            "reportPath": report_path, "reportHash": report_hash, "bytes": len(contents), "mediaType": definition["mediaType"],
            "inputReferences": [{"path": path, "hash": checksum} for path, checksum in sorted(references.items())]}
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {"exportId": item["exportId"], "destination": str(destination), "sha256": checksum,
            "format": definition["id"], "mediaType": definition["mediaType"], "bytes": len(contents),
            "refreshId": refresh["id"], "provenance": provenance, "provenanceSha256": provenance_hash}, publish, temporary, publication
