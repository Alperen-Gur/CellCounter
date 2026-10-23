"""Public task navigation over canonical operations, independent of project state."""
from __future__ import annotations

import copy

TASKS = (
    {"id": "preparation", "label": "Images", "description": "Import, organize and prepare images and sources."},
    {"id": "segmentation", "label": "Segmentation", "description": "Segment objects and correct exact labels with classical or learned methods."},
    {"id": "measurements", "label": "Measurements", "description": "Measure objects and assays, track lineages and compare experimental results."},
    {"id": "review", "label": "Review", "description": "Inspect disagreements and record review decisions."},
    {"id": "workflows", "label": "Workflows", "description": "Organize experiments, reusable workflows and resumable jobs."},
    {"id": "export", "label": "Results & export", "description": "Inspect summaries and export images, tables and portable analysis packages."},
)
TASK_IDS = tuple(task["id"] for task in TASKS)
DEFAULT_TASK = "preparation"

# Exact names deliberately avoid classifying new operations from a familiar
# prefix. Dynamic operations (for example plugin.run) may serve several tasks.
_TASK_OPERATIONS = {
    "preparation": """
        image.import image.preview image.duplicate image.metadata.get image.metadata.set image.archive
        image.relink.preview image.relink.run image.list image.get
        collection.save collection.list collection.archive library.search library.duplicates
        source.import source.list source.inspect source.overview source.extract
        zarr.catalogue zarr.import zarr.list zarr.get zarr.rebind zarr.overview zarr.extract
        omero.catalogue omero.runtime.inspect omero.runtime.candidate omero.runtime.probe
        omero.profile.list omero.connection.inspect omero.group.list omero.object.list omero.image.inspect
        omero.import.preview omero.import.run omero.runtime.configure omero.profile.save
        preprocessing.catalogue preprocessing.preview preprocessing.run preprocessing.inspect
        registration.estimate registration.preview registration.apply registration.inspect
        calibration.set volume.calibration.set
        display.preset.save display.preset.list display.preset.get display.preset.archive display.preset.resolve
        display.preset.import.preview display.preset.import.run
        workspace.zarr.add workspace.zarr.bind workspace.catalogue workspace.create workspace.list workspace.get
        workspace.import.preview workspace.import.run workspace.layer.update workspace.source.bind
        workspace.layer.add workspace.document.set workspace.document.update workspace.operation.run
        workspace.layer.samples workspace.materialize.preview workspace.materialize.run workspace.undo
        workspace.preview workspace.layer.preview workspace.replay workspace.output.list
        migration.library.catalogue migration.library.capture migration.library.preview migration.library.run
        migration.library.get migration.records.get migration.evidence.list migration.geometry.get
        migration.library.advance migration.library.pause migration.library.resume migration.library.cancel
    """,
    "segmentation": """
        analysis.preview analysis.run mask.edit mask.undo mask.import.preview mask.import.run
        mask.pick mask.overlay
        model.catalog model.register model.configure model.list model.probe model.environment.capture
        model.environment.get model.run model.card.save model.card.get model.card.list model.activation.set model.activation.get
        adaptation.reference.set adaptation.suggest adaptation.dataset.create adaptation.dataset.list
        adaptation.dataset.get adaptation.evaluate.preview adaptation.evaluate adaptation.train.start
        adaptation.train.list adaptation.train.status adaptation.train.cancel adaptation.train.collect
        image.composite.catalogue image.composite.preview image.composite.volume
        volume.inspect volume.slice volume.display volume.analysis.preview volume.analysis.run
        volume.mask.edit volume.mask.undo
        temporal.propagate.preview temporal.propagate.run temporal.propagate.list temporal.propagate.get temporal.propagate.undo
        tiled.analysis.worker.start tiled.analysis.catalogue tiled.analysis.preview tiled.analysis.create
        tiled.analysis.list tiled.analysis.get tiled.analysis.advance tiled.analysis.pause tiled.analysis.resume
        tiled.analysis.cancel
    """,
    "measurements": """
        measurements.get measurements.page measurements.lookup volume.measurements.get
        tiled.analysis.objects tiled.analysis.tiles
        temporal.catalogue temporal.track.preview temporal.track.run tracks.run tracks.get tracks.link tracks.unlink pointlineage.build
        lineage.initialize lineage.get lineage.division.set lineage.division.remove lineage.link lineage.unlink
        lineage.undo lineage.summary lineage.suggest
        assay.catalog assay.preview assay.run assay.results assay.recompute assay.metrics
        assay.series.catalogue assay.series.preview assay.series.run assay.series.results
        assay.series.recompute.preview assay.series.recompute.run
        annotation.save annotation.list annotation.get annotation.measure annotation.delete annotation.undo
        annotation.import.preview annotation.import.run
        statistics.catalogue statistics.design.preview statistics.design.save statistics.design.get statistics.design.list
        statistics.preview statistics.run statistics.get statistics.list statistics.recompute.preview statistics.recompute.run
    """,
    "review": """
        mask.compare review.flag review.session.create review.session.list review.session.get review.item.preview
        review.decision review.adjudicate review.reveal review.summary
    """,
    "workflows": """
        workflow.save workflow.get workflow.list workflow.graph.catalogue workflow.graph.preview workflow.graph.save
        job.create job.get job.list job.advance job.pause job.resume job.retry job.cancel
        job.worker.start job.worker.status job.worker.stop job.worker.list
        job.graph.review.get job.graph.review.recommend job.graph.review.decide
        job.graph.continue.preview job.graph.continue.run job.graph.node.preview
        sweep.parameters sweep.preview sweep.create sweep.get sweep.list sweep.advance sweep.pause
        sweep.resume sweep.retry sweep.cancel sweep.results sweep.worker.start
        distribution.preview distribution.create distribution.list distribution.get
        distribution.task.get distribution.task.prepare distribution.result.preview distribution.result.collect
        refresh.worker.start refresh.inspect refresh.preview refresh.create refresh.list refresh.get
        refresh.advance refresh.pause refresh.resume refresh.retry refresh.cancel refresh.results
        acquisition.session.save acquisition.session.list acquisition.session.get
        specimen.set plate.set image.assign image.unassign experiment.get experiment.summary
        experiment.layout.catalogue experiment.layout.save experiment.layout.list experiment.layout.get
        experiment.layout.apply.preview experiment.layout.apply.run experiment.layout.application.list
        experiment.layout.application.get experiment.layout.application.statistics experiment.exclusion.set
        experiment.exclusion.list experiment.assay.summary
    """,
    "export": """
        summary.get project.export
        package.inspect package.restore package.restore.start package.restore.get package.restore.advance
        package.restore.cancel package.restore.resume project.storage.inspect project.storage.upgrade.preview project.storage.upgrade.run
        image.export.catalogue image.export image.composite.export.catalogue image.composite.export
        display.preset.export.catalogue display.preset.export
        annotation.export.catalogue annotation.export lineage.export.catalogue lineage.export
        sweep.export.catalogue sweep.export distribution.bundle.export distribution.result.export
        refresh.export.catalogue refresh.export workspace.export workspace.output.export
        tiled.analysis.labels.region tiled.analysis.export.catalogue tiled.analysis.export statistics.export.catalogue statistics.export
        assay.series.export.catalogue assay.series.export animation.render semantic.render plugin.export
    """,
}
_OPERATION_TASKS = {name: task for task, names in _TASK_OPERATIONS.items() for name in names.split()}


def task_for_operation(name):
    return _OPERATION_TASKS.get(name)


def operations():
    from _workbench_schema import _object, _op
    return [_op("navigation.catalog", "Read shared workbench tasks and their canonical operation references without opening a project.",
                _object(), project=False)]


def summary():
    return {"catalogOperation": "navigation.catalog", "defaultTask": DEFAULT_TASK,
            "tasks": copy.deepcopy(list(TASKS))}


def catalogue(catalog=None):
    if catalog is None:
        from _workbench_schema import OPERATIONS
        catalog = OPERATIONS
    tasks = [{**copy.deepcopy(task), "operationNames": []} for task in TASKS]
    by_task = {task["id"]: task for task in tasks}
    entries, unassigned = [], []
    for descriptor in catalog:
        # Preserve canonical capability and revision flags; schemas remain
        # available through bounded operations.discover rather than duplicated.
        entry = {key: copy.deepcopy(value) for key, value in descriptor.items()
                 if key not in ("inputSchema", "outputSchema")}
        task = task_for_operation(entry["name"])
        if task is None:
            entry.pop("navigationTask", None)
            unassigned.append(entry["name"])
        else:
            entry["navigationTask"] = task
            by_task[task]["operationNames"].append(entry["name"])
        entries.append(entry)
    return {"schemaVersion": 1, "defaultTask": DEFAULT_TASK, "tasks": tasks,
            "operations": entries, "unassignedOperationNames": unassigned,
            "notes": [
                "Tasks organize canonical operations; navigation never runs an analysis or changes scientific project revision.",
                "Operation references describe declared capabilities. Inspect or probe optional dependencies before execution.",
                "Schemas and current transport permissions remain authoritative; navigation does not grant access or executable trust.",
                "Operations without an explicit task assignment remain discoverable through operations.discover.",
            ]}
