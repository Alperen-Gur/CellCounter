"""Revision-bound bounded catalogue pages, exact pins and compact snapshots.

The records table remains the single scientific store. These adapters select
rows before invoking domain serializers; paging never changes their identity.
"""
from __future__ import annotations

import copy

CATALOGUES = (
    "jobs", "sweeps", "jobWorkers", "imageExports", "displayPresets", "distributions",
    "refreshJobs", "collections", "zarrSources", "tiledAnalyses", "statisticsDesigns",
    "statisticsRuns", "workspaces", "workspaceOutputs", "labelImports", "workflows",
    "experimentLayouts", "experimentApplications", "acquisitionSessions", "experimentExclusions",
    "plugins", "adaptationDatasets", "models", "trainingJobs", "assayRuns", "assaySeriesRuns",
    "reviewSessions", "largeSources", "specimens", "plates", "assignments",
)
VERSIONED_ROWS = frozenset(("workflows", "statisticsDesigns", "experimentLayouts", "acquisitionSessions"))
VERSIONED_EMBEDDED = frozenset(("displayPresets", "workspaces"))
PAGE_BYTES = 2 * 1024 ** 2
SNAPSHOT_PAGE_BYTES = 128 * 1024
PIN_BYTES = 4 * 1024 ** 2


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def selection_schema():
    from _workbench_schema import _object, _ID
    return _object({"catalogue": {"type": "string", "enum": list(CATALOGUES)}, "entryId": _ID,
                    "version": {"type": "integer", "minimum": 1}}, ["catalogue", "entryId"])


def operations():
    from _workbench_schema import _object, _op, _ID
    return [
        _op("project.catalogue", "Page one scientific catalogue at a fixed revision; versioned identities return their latest descriptor.",
            _object({"catalogue": {"type": "string", "enum": list(CATALOGUES)},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 25},
                     "cursor": {"type": "string", "minLength": 1, "maxLength": 4096}}, ["catalogue"])),
        _op("project.catalogue.get", "Read an exact catalogue identity, including an older selected version without paging other records.", selection_schema()),
        _op("project.catalogue.getMany", "Read an explicit bounded set of current catalogue identities at one scientific revision; missing identities remain explicit.",
            _object({"catalogue": {"type": "string", "enum": list(CATALOGUES)}, "entryIds": {"type": "array", "items": _ID, "minItems": 1, "maxItems": 200}}, ["catalogue", "entryIds"])),
        {**_op("project.activity", "Read complete bounded live activity without adopting catalogue/scientific drafts or calculating scientific previews.", _object()), "affectsProjectRevision": False},
    ]


def _rows(document, name):
    if name not in CATALOGUES: fail("unknown-catalogue", "Select a supported scientific catalogue.")
    if name in ("specimens", "plates", "assignments"):
        return document.get("experimentalDesign", {}).get(name, [])
    return document.get(name, [])


def entry_id(name, value):
    if name == "experimentExclusions": return value["target"] + ":" + value["targetId"]
    from _workbench_indexed import record_identity
    return record_identity(value)


def _identity_sql(name, alias="r"):
    if name == "experimentExclusions":
        return "json_extract(" + alias + ".payload,'$.target')||':'||json_extract(" + alias + ".payload,'$.targetId')"
    # JSON fallback reads earlier format2 records whose entity_id predates the
    # generalized identity index. New commits always populate entity_id.
    return "COALESCE(" + alias + ".entity_id," + ",".join("json_extract(" + alias + ".payload,'$." + key + "')" for key in ("id", "runId", "pluginId", "exportId", "importId", "workerId", "imageId")) + ")"


def _where(name, collection, *, identifier=None, version=None, active=False):
    predicates, values = ["r.collection=?"], [collection]
    identity = _identity_sql(name)
    if identifier is not None:
        predicates.append(identity + "=?"); values.append(identifier)
    if version is not None and name in VERSIONED_ROWS:
        predicates.append("json_extract(r.payload,'$.version')=?"); values.append(version)
    elif name in VERSIONED_ROWS or name == "experimentExclusions":
        newer = "(COALESCE(json_extract(n.payload,'$.version'),0)>COALESCE(json_extract(r.payload,'$.version'),0) OR (COALESCE(json_extract(n.payload,'$.version'),0)=COALESCE(json_extract(r.payload,'$.version'),0) AND n.ordinal>r.ordinal))" if name in VERSIONED_ROWS else "n.ordinal>r.ordinal"
        predicates.append("NOT EXISTS(SELECT 1 FROM records n WHERE n.collection=r.collection AND " + _identity_sql(name, "n") + "=" + identity + " AND " + newer + ")")
    if active:
        statuses = ("queued", "starting", "running", "stopping") if name == "jobWorkers" else ("queued", "starting", "running", "cancelling")
        predicates.append("json_extract(r.payload,'$.status') IN (" + ",".join("?" for _ in statuses) + ")"); values.extend(statuses)
    return " AND ".join(predicates), values


def _select(document, name, offset=0, limit=25, *, identifier=None, version=None, active=False):
    from _workbench_indexed import RecordList
    rows = _rows(document, name)
    if isinstance(rows, RecordList) and not (rows.dirty or rows.added or rows.deleted or rows.reset):
        where, values = _where(name, rows.collection, identifier=identifier, version=version, active=active)
        total = rows.view.query("SELECT COUNT(*) FROM records r WHERE " + where, values).fetchone()[0]
        selected = rows.view.query("SELECT r.record_key,r.ordinal,r.payload FROM records r WHERE " + where + " ORDER BY r.ordinal DESC LIMIT ? OFFSET ?", [*values, limit, offset])
        return [rows._loaded(*row) for row in selected], total
    candidates = []
    latest = {}
    for ordinal, row in enumerate(rows):
        if identifier is not None and entry_id(name, row) != identifier: continue
        if version is not None and name in VERSIONED_ROWS and row.get("version") != version: continue
        if active and row.get("status") not in (("queued", "starting", "running", "stopping") if name == "jobWorkers" else ("queued", "starting", "running", "cancelling")): continue
        if version is None and (name in VERSIONED_ROWS or name == "experimentExclusions"):
            key = entry_id(name, row); previous = latest.get(key)
            if previous is None or (row.get("version", 0), ordinal) > (previous[1].get("version", 0), previous[0]): latest[key] = (ordinal, row)
        else: candidates.append((ordinal, row))
    candidates.extend(latest.values()); candidates.sort(key=lambda pair: pair[0], reverse=True)
    return [row for _, row in candidates[offset:offset + limit]], len(candidates)


def _describe(store, document, name, row, version=None):
    import _workbench_core as core
    if name == "jobs": return core.workflows.describe_job(row, document, compact=True)
    if name == "sweeps": return core.sweeps.describe(document, row, compact=True)
    if name == "jobWorkers": return core.batch_jobs.describe(store, document, row)
    if name == "imageExports": return core.image_exports.describe(row)
    if name == "displayPresets":
        # The existing descriptor intentionally omits full channel settings;
        # display.preset.get is the selected scientific definition reader.
        local = dict(document); local[name] = [row]
        value = core.display_presets.get(local, row["id"], version, include_import=False)
        channels = value.pop("channels"); value.pop("actor", None)
        return {**value, "channelCount": len(channels), "hasFixedWindows": any("lower" in item for item in channels)}
    if name == "distributions": return core.distributed.describe_group(document, row, compact=True)
    if name == "refreshJobs": return core.refresh.describe(document, row, compact=True)
    if name == "zarrSources": return core.zarr_sources.describe(row)
    if name == "tiledAnalyses": return core.tiled.describe(row)
    if name == "statisticsDesigns":
        local = dict(document); latest, _ = _select(document, name, identifier=row["id"], limit=1)
        local[name] = [row, *latest]
        return core.statistical.describe_design(local, row)
    if name == "statisticsRuns": return core.statistical.describe_run(document, row)
    if name == "workspaces":
        selected = None
        if version is not None:
            selected = next((item for item in row["versions"] if item["version"] == version), None)
            if selected is None: fail("catalogue-entry-not-found", "The requested workspace version is not retained.")
        return core.workspaces.describe(document, row, selected)
    if name == "workspaceOutputs": return core.workspaces.describe_output(document, row)
    if name == "labelImports": return core.label_imports.describe(row)
    if name in ("experimentLayouts", "experimentApplications", "acquisitionSessions"):
        local = dict(document); latest, _ = _select(document, name, identifier=row["id"], limit=1)
        local[name] = [row, *latest]
        return core.experiment_layouts._compact(local, name, row)
    if name == "plugins": return core.plugins.describe(row)
    if name == "adaptationDatasets": return core.adaptation.describe(document, row, detail=False)
    if name == "models": return core.models.describe(row)
    if name == "trainingJobs": return core.models.describe_job(store, row)
    if name == "assayRuns": return core.assays.describe(document, row)
    if name == "assaySeriesRuns": return core.assay_series.describe(document, row)
    if name == "reviewSessions": return core.review.describe(document, row)
    if name == "largeSources": return core.sources.describe(row)
    return copy.deepcopy(row)


def _size(value):
    from _workbench_store import canonical
    return len(canonical(value).encode("utf-8"))


def page(store, document, args, *, byte_limit=PAGE_BYTES, allow_empty=False):
    from _workbench_pages import _page_state, _cursor
    name = args["catalogue"]; identity, offset = _page_state(document, "project.catalogue", args)
    selected, total = _select(document, name, offset, args.get("limit", 25))
    entries, used = [], 0
    for row in selected:
        value = _describe(store, document, name, row); size = _size(value)
        if used + size > byte_limit:
            if not entries and not allow_empty:
                fail("catalogue-entry-too-large", "This descriptor exceeds the page budget. Read the exact identity with project.catalogue.get.", {"catalogue": name, "entryId": entry_id(name, row), "descriptorBytes": size})
            break
        entries.append(value); used += size
    return {"catalogue": name, "entries": entries, "total": total, "returned": len(entries),
            "nextCursor": _cursor(identity, offset + len(entries), total), "partial": len(entries) < total,
            "sourceRevision": document["revision"]}


def get(store, document, args):
    name = args["catalogue"]; version = args.get("version")
    if version is not None and name not in VERSIONED_ROWS | VERSIONED_EMBEDDED:
        fail("catalogue-not-versioned", "This catalogue does not accept a version selector.", {"catalogue": name})
    rows, _ = _select(document, name, identifier=args["entryId"], version=version, limit=1)
    if not rows: fail("catalogue-entry-not-found", "The selected catalogue identity/version is not retained.", args)
    return {"catalogue": name, "entry": _describe(store, document, name, rows[0], version), "sourceRevision": document["revision"]}


def get_many(store, document, args):
    from _workbench_schema import WorkbenchError
    identifiers = args["entryIds"]
    if len(identifiers) != len(set(identifiers)): fail("invalid-selection", "Catalogue identities must be distinct.")
    entries, missing, size = [], [], 0
    for identifier in identifiers:
        try: value = get(store, document, {"catalogue": args["catalogue"], "entryId": identifier})["entry"]
        except WorkbenchError as error:
            if error.code != "catalogue-entry-not-found": raise
            missing.append(identifier); continue
        size += _size(value)
        if size > PAGE_BYTES: fail("catalogue-batch-too-large", "This explicit selection exceeds2MiB; split the requested identities into smaller batches.")
        entries.append(value)
    return {"catalogue": args["catalogue"], "entries": entries, "missingIds": missing, "sourceRevision": document["revision"]}


def _activity(store, document, name):
    # Persisted launch records may still say queued after their worker finishes.
    # Read every potential live control record, but never hydrate unrelated
    # historical payloads. The existing lifecycle bounds these to1000/100.
    bound = 1000 if name == "jobWorkers" else 100
    rows, total = _select(document, name, limit=bound, active=True)
    if total > bound: fail("activity-record-limit", "Active-worker candidates exceed the supported lifecycle bound; activity cannot safely be inferred.")
    states = ("queued", "starting", "running", "stopping") if name == "jobWorkers" else ("queued", "starting", "running", "cancelling")
    result = []
    for row in rows:
        value = _describe(store, document, name, row)
        if value.get("status") in states: result.append(value)
    if _size(result) > PAGE_BYTES: fail("activity-response-limit", "Live activity exceeds the bounded snapshot budget; no inactive state has been inferred.")
    return result


def activity(store, document):
    workers = _activity(store, document, "jobWorkers")
    training = _activity(store, document, "trainingJobs")
    return {"activeJobWorkers": workers, "activeTrainingJobs": training,
            "activeWorkerCount": len(workers), "activeTrainingJobCount": len(training), "projectRevision": document["revision"]}


def snapshot(store, document, args):
    import _workbench_core as core
    from _workbench_pages import storage
    selected = args.get("selectedImageIds", [])
    if len(selected) != len(set(selected)): fail("invalid-selection", "Selected image IDs must be distinct.")
    # Restrict flag history to selected acquisitions before deriving currentness.
    from _workbench_indexed import RecordList
    flags = document.get("reviewFlags", [])
    if not selected: flags = []
    elif isinstance(flags, RecordList):
        query = "SELECT record_key,ordinal,payload FROM records WHERE collection=? AND json_extract(payload,'$.imageId') IN (" + ",".join("?" for _ in selected) + ") ORDER BY ordinal"
        flags = [flags._loaded(*row) for row in flags.view.query(query, [flags.collection, *selected])]
    else: flags = [row for row in flags if row["imageId"] in selected]
    local = dict(document); local["reviewFlags"] = flags
    by_image = core.review.flags_by_image(local)
    result = {"project": {key: document[key] for key in ("id", "name", "revision", "createdAt", "updatedAt")},
              "images": [core._image_inspection(document, core._image(document, identity), by_image) for identity in selected],
              "imageCount": len(document["images"]), "imagePageRequired": True, "storage": storage(document),
              "cataloguePages": {}, "experimentalDesign": {},
              "migration": core.migration.describe(document),
              "modelActivation": core.model_cards.activation(document),
              "distributedTask": core.distributed.describe_task(document, include_local_runtime=True)}
    for name in CATALOGUES:
        values = page(store, document, {"catalogue": name, "limit": args.get("catalogueLimit", 25)}, byte_limit=SNAPSHOT_PAGE_BYTES, allow_empty=True)
        result["cataloguePages"][name] = {key: values[key] for key in ("total", "returned", "nextCursor", "partial")}
        if name in ("specimens", "plates", "assignments"): result["experimentalDesign"][name] = values["entries"]
        elif name == "experimentExclusions":
            result[name] = {target: {row["targetId"]: row for row in values["entries"] if row["target"] == target and row["excluded"]} for target in ("image", "specimen")}
        else: result[name] = values["entries"]
    pins, seen, used = [], set(), 0
    for selection in args.get("selectedCatalogueEntries", []):
        key = (selection["catalogue"], selection["entryId"], selection.get("version"))
        if key in seen: fail("invalid-selection", "Selected catalogue identities/versions must be distinct.")
        seen.add(key)
        try: entry = get(store, document, selection)["entry"]
        except core.WorkbenchError as error:
            if error.code != "catalogue-entry-not-found": raise
            pins.append({**selection, "missing": True}); continue
        used += _size(entry)
        if used > PIN_BYTES:
            fail("selected-catalogue-limit", "Pinned descriptors exceed4MiB; retain fewer pins and load the selected detail only when opened.")
        pins.append({**selection, "entry": entry, "missing": False})
    result["selectedCatalogueEntries"] = pins
    result.update(activity(store, document))
    if document.get("restoredFrom"):
        result.update({"restoredFrom": document["restoredFrom"], "restoredHistoryCount": len(document.get("restoredHistory", []))})
    return result
