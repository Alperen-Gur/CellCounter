"""Publication tables/figures from retained inference; no recomputation on export."""
from __future__ import annotations

import copy
import csv
import io
import uuid

FORMATS = [
    {"id": "results-json", "name": "Complete inference report", "extension": "json", "mediaType": "application/json"},
    {"id": "inputs-csv", "name": "Biological specimen input table", "extension": "csv", "mediaType": "text/csv"},
    {"id": "results-csv", "name": "Effects and pointwise confidence intervals", "extension": "csv", "mediaType": "text/csv"},
    {"id": "effects-svg", "name": "Vector effect plot", "extension": "svg", "mediaType": "image/svg+xml", "requires": "matplotlib"},
]


def catalogue():
    return {"formats": copy.deepcopy(FORMATS), "notes": [
        "Exports use retained input/effect tables and report currentness; historical files are never silently replaced.",
        "SVG plots use Matplotlib. Pointwise intervals and declared multiplicity remain explicitly distinguished.",
    ]}


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    return [_op("statistics.export.catalogue", "Describe retained statistical table and vector figure exports.", _object(), project=False),
            _op("statistics.export", "Publish a retained replicate report or effect plot with exact inputs and assumptions.",
                _object({"runId": _ID, "format": {"type": "string", "enum": [row["id"] for row in FORMATS]},
                         "destination": _STRING}, ["runId", "format", "destination"]), True)]


def _csv(rows, columns):
    from _workbench_exports import _csv_safe
    from _workbench_store import canonical
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(columns)
    for row in rows:
        writer.writerow([_csv_safe(canonical(row.get(key)) if isinstance(row.get(key), (dict, list)) else row.get(key)) for key in columns])
    return output.getvalue().encode("utf-8")


def _svg(report):
    from _workbench_statistics import fail
    try:
        from matplotlib.figure import Figure
        from matplotlib.backends.backend_svg import FigureCanvasSVG
        from matplotlib import rc_context
    except ImportError as exc:
        fail("missing-dependency", "Install the pinned requirements-reporting.txt in the Workbench environment to export statistical SVG figures.",
             {"package": "matplotlib", "requirements": "requirements-reporting.txt"})
    rows = report["result"]["plotTable"]
    if not rows:
        fail("statistics-plot-empty", "The retained result has no estimable effect table to plot.")
    with rc_context({"svg.fonttype": "none", "svg.hashsalt": report["inputFingerprint"], "font.family": "sans-serif", "font.size": 10}):
        figure = Figure(figsize=(8, max(3, .35 * len(rows) + 1.8)), layout="constrained")
        FigureCanvasSVG(figure)
        ax = figure.subplots()
        for index, row in enumerate(rows):
            ax.plot(row["estimate"], index, "o", color="#175c80", markersize=5)
            interval = row.get("confidenceInterval")
            if interval is not None:
                ax.hlines(index, interval[0], interval[1], color="#175c80", linewidth=1.5)
        ax.axvline(0, color="#666666", linewidth=.8, linestyle="--")
        ax.set_yticks(range(len(rows)), [row["id"] for row in rows])
        ax.invert_yaxis()
        units = report["result"]["units"]
        ax.set_xlabel("Effect (comparison − reference)" + (f" [{units}]" if isinstance(units, str) else " [assay-declared units]"))
        confidence = report["result"]["analysis"]["confidenceLevel"]
        ax.set_title(report["name"] + f"\n{confidence * 100:g}% pointwise confidence intervals", loc="left")
        ax.spines[["top", "right"]].set_visible(False)
        figure.text(.02, .005, "Current inputs" if report["outputsCurrent"] else "Historical inputs — superseded or changed", fontsize=8)
        buffer = io.BytesIO()
        figure.savefig(buffer, format="svg", metadata={"Date": None, "Title": report["name"],
                       "Description": "Retained biological-replicate effects. " + " ".join(report["result"]["notes"])})
        return buffer.getvalue()


def prepare_export(store, document, arguments, revision, request_id, actor):
    from _workbench_statistics import get_run, _run, LIMITS, fail, ENGINE
    from _workbench_exports import _destination, _stage_publication, MAX_EXPORTS
    from _workbench_store import canonical, utc_now
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "This project retains at most 1,000 built-in exports.")
    definition = next(item for item in FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    record = _run(document, arguments["runId"])
    report = get_run(store, document, record["id"])
    references = {record["inputPath"]: record["inputHash"], record["resultPath"]: record["resultHash"]}
    references.update({row["path"]: row["hash"] for row in record["inputReferences"]})
    for path, checksum in references.items():
        store.verify_artifact(path, checksum)
    provenance = {"schemaVersion": 1, "engineVersion": ENGINE, "exportId": str(uuid.uuid4()), "projectId": document["id"],
                  "runId": record["id"], "designId": record["designId"], "designVersion": record["designVersion"],
                  "inputFingerprint": record["inputFingerprint"], "inputTableHash": record["inputHash"], "resultHash": record["resultHash"],
                  "sourceRevision": document["revision"], "exportRevision": revision, "createdAt": utc_now(),
                  "requestId": request_id, "actor": copy.deepcopy(actor), "outputsCurrent": report["outputsCurrent"],
                  "format": definition["id"], "notes": report["result"]["notes"]}
    if definition["id"] == "results-json":
        contents = (canonical({"schemaVersion": 1, "format": "cellcounter-statistical-report", "report": report, "provenance": provenance}) + "\n").encode()
    elif definition["id"] == "inputs-csv":
        rows = [{**row, "runId": record["id"], "inputFingerprint": record["inputFingerprint"], "outputsCurrent": report["outputsCurrent"],
                 "units": report["result"]["units"]} for row in report["inputTable"]["rows"]]
        contents = _csv(rows, ["runId", "inputFingerprint", "outputsCurrent", "specimenId", "name", "subjectId", "blockId", "included", "reason", "value", "units", "values", "imageIds"])
    elif definition["id"] == "results-csv":
        rows = [{**row, "runId": record["id"], "inputFingerprint": record["inputFingerprint"], "outputsCurrent": report["outputsCurrent"],
                 "units": report["result"]["units"], "resultJson": row} for row in report["result"]["results"]]
        contents = _csv(rows, ["runId", "inputFingerprint", "outputsCurrent", "id", "status", "estimate", "units", "standardError", "degreesOfFreedom",
                              "confidenceLevel", "confidenceInterval", "pValue", "adjustedPValue", "multiplicity", "familySize", "resultJson"])
    else:
        contents = _svg(report)
    if len(contents) > LIMITS["artifactBytes"]:
        fail("statistics-export-limit", "The report exceeds its 16 MiB publication bound.")
    provenance_path, provenance_hash = store.put_bytes((canonical(provenance) + "\n").encode(), ".statistics-provenance.json")
    path, checksum = store.put_bytes(contents, ".statistics-export." + definition["extension"])
    item = {"exportId": provenance["exportId"], "kind": "statistics", "runId": record["id"], "format": definition["id"],
            "createdAt": provenance["createdAt"], "revision": revision, "destination": str(destination),
            "filePath": path, "fileHash": checksum, "provenancePath": provenance_path, "provenanceHash": provenance_hash,
            "reportPath": record["resultPath"], "reportHash": record["resultHash"], "bytes": len(contents), "mediaType": definition["mediaType"],
            "inputReferences": [{"path": key, "hash": value} for key, value in sorted(references.items())]}
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {"exportId": item["exportId"], "runId": record["id"], "destination": str(destination), "sha256": checksum,
            "bytes": len(contents), "mediaType": item["mediaType"], "provenance": provenance}, publish, temporary, publication
