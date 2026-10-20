"""Frozen downstream measurement refreshes; saved segmentation masks never change."""
from __future__ import annotations

from _workbench_indexed import RecordList

from _workbench_indexed import image_index

import copy
import hashlib
import uuid

MAX_JOBS = 100
MAX_UNITS = 256


def operations():
    from _workbench_schema import _object, _op, _ID
    image_ids = {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000}
    selection = {"dependencyMode": {"type": "string", "enum": ["transitive", "measurements"], "default": "transitive"}, "imageIds": image_ids,
                 "runRefs": {"type": "array", "minItems": 1, "maxItems": MAX_UNITS,
                             "items": _object({"kind": {"type": "string", "enum": ["derived-image", "tracks", "lineage", "assay", "assay-series", "plugin-measurement", "statistics"]},
                                               "runId": _ID}, ["kind", "runId"])},
                 "includeCurrent": {"type": "boolean", "default": False}}
    entries = [
        _op("refresh.inspect", "List current, stale and blocked downstream results, using latest logical analyses by default.",
            _object({"dependencyMode": selection["dependencyMode"], "imageIds": image_ids, "includeHistory": {"type": "boolean", "default": False}})),
        _op("refresh.preview", "Freeze a proposed downstream refresh from current saved masks without executing assays or plugins.", _object(selection)),
        _op("refresh.create", "Save an immutable refresh plan with exact masks, references, method and runtime bindings.",
            _object({**selection, "name": {"type": "string", "maxLength": 200},
                     "previewFingerprint": {"type": "string", "minLength": 64, "maxLength": 64},
                     "skipBlocked": {"type": "boolean", "default": False}}, ["previewFingerprint"]), True),
        _op("refresh.list", "List durable downstream refresh jobs and live input currentness.", _object()),
        _op("refresh.get", "Read a refresh's frozen units, replacement links and remaining work.",
            _object({"refreshId": _ID}, ["refreshId"])),
    ]
    for name, description in (
        ("advance", "Recompute one downstream result from exact saved masks and retain its predecessor link."),
        ("pause", "Pause a refresh before its next bounded measurement unit."),
        ("resume", "Resume a paused refresh if its frozen inputs are unchanged."),
        ("retry", "Retry a failed or blocked unit against the same frozen inputs and methods."),
        ("cancel", "Cancel remaining refresh units while preserving completed replacement results."),
    ):
        fields = {"refreshId": _ID}
        if name == "pause":
            fields.update({"reason": {"type": "string", "maxLength": 500}, "controlRequestId": _ID})
        entries.append(_op("refresh." + name, description, _object(fields, ["refreshId"]), True))
    return entries


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def limits():
    return {"jobs": MAX_JOBS, "unitsPerJob": MAX_UNITS, "outputs": 2000}


def notes():
    return ["Refresh executes saved assay and measurement-plugin settings on the current saved masks; it never runs segmentation or edits a mask.",
            "Previous results and exported files remain historical. Replacement results receive new identities and explicit predecessor links.",
            "Default selection uses the latest run for each image, method, parameter set and time/channel selection. Image scope also includes dependent reference images.",
            "Stale registration, base measurements, tracking and lineage require separate explicit repair; this is not an automatic whole-project graph rebuild.",
            "A completed selected plan can still have skipped blockers or other stale project results. Observed runtime inventories are metadata records, not binary lockfiles."]


def _records(document):
    return [("assay", run) for run in document.get("assayRuns", [])] + [
        ("plugin-measurement", run) for run in document.get("pluginRuns", []) if run.get("kind") == "measurement"]


def _run(document, kind, run_id):
    for candidate_kind, record in _records(document):
        if kind == candidate_kind and record["runId"] == run_id:
            return record
    fail("refresh-result-not-found", "The selected assay or measurement-plugin result is not retained.", {"kind": kind, "runId": run_id})


def _arguments(kind, run):
    if kind == "assay":
        return {**copy.deepcopy(run["arguments"]), "target": run.get("target", "plane"),
                "parameters": copy.deepcopy(run["parameters"])}
    result = {"imageId": run["imageId"], "pluginId": run["pluginId"], "parameters": copy.deepcopy(run["parameters"]),
              "target": run.get("target", "plane")}
    if result["target"] == "volume":
        result.update({key: run[key] for key in ("timeIndex", "channel")})
    return result


def _logical(kind, run):
    def numbers(value):
        if type(value) in (float, int):
            return float(value)
        if isinstance(value, dict):
            return {key: numbers(item) for key, item in value.items()}
        if isinstance(value, (list, RecordList)):
            return [numbers(item) for item in value]
        return value
    return digest({"kind": kind, **numbers(_arguments(kind, run))})


def _reason(code, message, image_id=None):
    return {"code": code, "message": message, **({"imageId": image_id} if image_id else {})}


class Context:
    def __init__(self, store, document):
        self.store, self.document = store, document
        self.images = image_index(document)
        self.dependencies = {}
        self.verified = set()
        self.records = _records(document)
        self.runs = {(kind, run["runId"]): run for kind, run in self.records}
        self.logical_keys = {(kind, run["runId"]): _logical(kind, run) for kind, run in self.records}
        self.latest = {self.logical_keys[(kind, run["runId"])]: (kind, run["runId"])
                       for kind, run in self.records}
        self.replacements = {(kind, run["replacesRunId"]): run["runId"]
                             for kind, run in self.records if run.get("replacesRunId")}
        self.processing_checked = set()

    def check_processing(self, image):
        import _workbench_preprocessing as preprocessing
        import _workbench_workspace as workspaces
        visiting = set()
        def visit(current):
            if current['id'] in self.processing_checked: return
            if current['id'] in visiting or len(visiting) >= 32: fail('invalid-processing-lineage', 'Processing ancestry is cyclic or too deep.')
            visiting.add(current['id']); derivation = current.get('derivation')
            if derivation:
                status = preprocessing.inspect(current, self.document)
                if status.get('parentInputsCurrent') is False: fail('stale-registration', 'A generating parent changed; refresh its derived acquisition before dependent measurements.', {'imageId': current['id']})
                if derivation.get('kind') == 'workspace':
                    if self.store is not None: workspaces.verify_materialized_inputs(self.store, self.document, current)
                    parent_ids = [row['imageId'] for row in workspaces.materialized_dependencies(current) if row.get('imageId')]
                elif derivation.get('kind') == 'registration':
                    parent_ids = [derivation['registration']['fixedImageId'], derivation['registration']['movingImageId']]
                else: parent_ids = [derivation['sourceImageId']]
                for identifier in parent_ids:
                    parent = self.images.get(identifier)
                    if parent is None: fail('missing-processing-lineage', 'A retained generating parent is missing.', {'imageId': identifier})
                    visit(parent)
            visiting.remove(current['id']); self.processing_checked.add(current['id'])
        visit(image)

    def dependency(self, image_id, target="plane", time_index=None, channel=None, raw_selection=None):
        import _workbench_core as core
        import _workbench_volume as volume
        import _workbench_assays as assays
        import _workbench_support as support
        key = image_id, target, time_index, channel, digest(raw_selection) if raw_selection is not None else None
        if key in self.dependencies:
            return copy.deepcopy(self.dependencies[key])
        image = self.images.get(image_id)
        if image is None:
            fail("image-not-found", "A source or paired reference is missing.", {"imageId": image_id})
        self.check_processing(image)
        selection = {"target": target}
        if raw_selection is not None:
            selection.update({"rawSourceOnly": True, "sourceParameters": copy.deepcopy(raw_selection)})
            analysis = {"parameters": raw_selection}
        elif target == "volume":
            selection.update({"timeIndex": time_index, "channel": channel})
            analysis = volume.current_frame(self.store, image, time_index, channel, verify=False)
        else:
            analysis = core._current_analysis(self.store, image, verify_files=False)
        dependency = {"imageId": image_id, **selection, "fingerprint": assays._fingerprint(image, selection),
                      "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
                      **({"labelsPath": analysis["labelsPath"], "labelsHash": analysis["labelsHash"]} if raw_selection is None else {}),
                      "sourceProvenance": assays.source_provenance(self.document, image, analysis, selection)}
        if support.descriptor(image):
            dependency.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
        self.dependencies[key] = dependency
        return copy.deepcopy(dependency)

    def verify(self, reference, checksum):
        if (reference, checksum) not in self.verified:
            self.store.verify_artifact(reference, checksum)
            self.verified.add((reference, checksum))


def _inspect_output(context, kind, run, latest):
    import _workbench_assays as assays
    import _workbench_plugins as plugins
    import _workbench_workflows as workflows
    from _workbench_schema import WorkbenchError
    args = _arguments(kind, run)
    image = context.images.get(run["imageId"])
    target = args.get("target", "plane")
    try:
        current = assays._current(context.document, run) if kind == "assay" else (
            image is not None and plugins._state_fingerprint(image, target, args.get("timeIndex"), args.get("channel")) == run["currentFingerprint"])
    except (WorkbenchError, KeyError, TypeError):
        current = False
    label = next((item["name"] for item in assays.catalog() if item["id"] == run.get("assay")), run.get("assay")) if kind == "assay" else run["pluginId"]
    blockers, dependencies, method = [], [], {}
    try:
        raw_selection = args.get("sourceParameters") if kind == "assay" and any(item.get("rawSourceOnly") for item in run.get("dependencies", [])) else None
        dependencies.append(context.dependency(run["imageId"], target, args.get("timeIndex"), args.get("channel"), raw_selection))
        if kind == "assay":
            frozen = workflows._freeze_assay({"type": "assay", "assay": run["assay"], "assayParameters": args["parameters"]}, 3 if target == "volume" else 2)
            args["parameters"] = frozen["assayParameters"]
            method = {"assayDefinitionHash": frozen["assayDefinitionHash"]}
            for argument in workflows._assay_definition(run["assay"]).get("imageReferenceArguments", []):
                reference = context.dependency(args["parameters"][argument])
                main = dependencies[0]
                if reference["sourceHash"] != main["sourceHash"] or reference["sourceProvenance"]["selection"]["zProjection"] != main["sourceProvenance"]["selection"]["zProjection"]:
                    fail("source-mismatch", "Nuclear and cell masks must use the same source bytes and projection before refreshing N:C measurements.")
                dependencies.append(reference)
            if run["assay"] == "puncta" and image.get("pxPerUm") is None:
                fail("calibration-required", "Spot detection needs known isotropic XY calibration before refresh.")
            channel_keys = [key for key in args["parameters"] if key == "channel" or key.endswith("_channel") or key.startswith("channel_")]
            if any(args["parameters"][key] >= image["channels"] for key in channel_keys):
                fail("channel-unavailable", "A saved measurement channel does not exist in this acquisition.")
        else:
            plugin = plugins._record(context.document, run["pluginId"])
            if plugin["manifest"]["kind"] != "measurement" or plugin["packageHash"] != run["packageHash"]:
                fail("plugin-changed", "Restore the exact retained measurement plugin version before refreshing this result.")
            if not plugin.get("enabled"):
                fail("plugin-disabled", "Explicitly enable the trusted measurement plugin before preparing a refresh.")
            if (3 if target == "volume" else 2) not in plugin["manifest"]["supportedDimensions"]:
                fail("unsupported-plugin-dimension", "This plugin does not support the saved result's dimensions.")
            import _workbench_support as support
            supported = support.descriptor(image)
            if supported and support.summary(image)["invalidPixelCount"] and not plugin["manifest"].get("supportsValidSupport", False):
                fail("unsupported-plugin-support", "This measurement plugin must declare supportsValidSupport and exclude filled samples before it can refresh a supported derived acquisition.")
            args["parameters"] = plugins.validate_parameters(plugin["manifest"], args["parameters"])
            method = {"pluginId": plugin["pluginId"], "packageHash": plugin["packageHash"],
                      "manifestPath": plugin["manifestPath"], "manifestHash": plugin["manifestHash"],
                      "pluginSourcePath": plugin["sourcePath"], "pluginSourceHash": plugin["sourceHash"]}
    except WorkbenchError as exc:
        blockers.append(_reason(exc.code, str(exc), (exc.details or {}).get("imageId") if isinstance(exc.details, dict) else run["imageId"]))
        if exc.code in ("stale-registration", "stale-analysis", "stale-volume-analysis", "analysis-required",
                        "volume-analysis-required", "image-not-found", "missing-processing-lineage", "invalid-processing-lineage"):
            current = False
    reasons = [] if current else [_reason("changed-inputs", "Saved source pixels, masks, selection, calibration or a paired reference differ from this result.", run["imageId"])]
    replacement = context.replacements.get((kind, run["runId"]))
    result = {"kind": kind, "runId": run["runId"], "imageId": run["imageId"],
              "imageName": image["name"] if image else "Missing image", "label": label,
              "target": target, **{key: args[key] for key in ("timeIndex", "channel") if key in args},
              "logicalKey": context.logical_keys[(kind, run["runId"])], "latest": latest,
              "createdAt": run.get("createdAt"), "revision": run.get("revision"),
              "status": "current" if current else "blocked" if blockers else "stale",
              "freshness": "current" if current else "stale", "recomputable": not blockers,
              "reasons": reasons, "blockers": blockers,
              **({"replacementRunId": replacement} if replacement else {})}
    return result, args, dependencies, method


def _scope(document, arguments):
    identifiers = arguments.get("imageIds")
    if identifiers is None:
        return None
    if len(set(identifiers)) != len(identifiers) or set(identifiers) - {image["id"] for image in document["images"]}:
        fail("invalid-image-scope", "Select distinct acquisitions that belong to this project.")
    return set(identifiers)


def _in_scope(kind, run, scope):
    return scope is None or run["imageId"] in scope or (kind == "assay" and any(item["imageId"] in scope for item in run["dependencies"]))


def _unhandled(context, scope):
    import _workbench_core as core
    import _workbench_volume as volume
    import _workbench_lineages as lineages
    from _workbench_schema import WorkbenchError
    document = context.document
    output = []
    for image in document["images"]:
        if scope is not None and image["id"] not in scope:
            continue
        try:
            context.check_processing(image)
        except WorkbenchError as exc:
            output.append({"kind": "registration", "imageId": image["id"], "status": "blocked",
                           "message": str(exc), "action": "Repair the retained processing lineage explicitly; refresh will not change a transform or derived source."})
        if image.get("analysis"):
            try:
                core._current_analysis(None, image, verify_files=False)
            except WorkbenchError as exc:
                output.append({"kind": "base-analysis", "imageId": image["id"], "target": "plane", "status": "blocked",
                               "message": str(exc), "action": "Review and repair the base mask/calibration explicitly before refreshing its dependent measurements."})
        for frame in image.get("volumeFrames", []):
            try:
                volume.current_frame(None, image, frame["timeIndex"], frame["channel"], verify=False)
            except WorkbenchError as exc:
                output.append({"kind": "base-analysis", "imageId": image["id"], "target": "volume", "status": "blocked",
                               "timeIndex": frame["timeIndex"], "channel": frame["channel"], "message": str(exc),
                               "action": "Review and repair this exact saved volume frame before refreshing its dependent measurements."})
        for track in image.get("volumeTracks", []):
            if track["inputFingerprint"] != volume.tracks_fingerprint(image, track):
                output.append({"kind": "tracks", "imageId": image["id"], "status": "blocked", "channel": track["channel"],
                               "message": "Saved tracking inputs changed.", "action": "Recompute or correct tracks explicitly before rebuilding dependent lineage analyses."})
        for lineage in image.get("volumeLineages", []):
            if lineages.describe(image, lineage)["status"] == "stale":
                output.append({"kind": "lineage", "imageId": image["id"], "status": "blocked", "channel": lineage["channel"],
                               "message": "Lineage masks or baseline tracks changed.", "action": "Reinitialize or correct the lineage explicitly; division decisions are not recreated by measurement refresh."})
    if document.get("imageExports"):
        output.append({"kind": "historical-exports", "status": "historical",
                       "message": "Published files remain snapshots of their original revisions.",
                       "action": "Review refreshed current results, then export a new file with a fresh destination."})
    return output[:2000]


def inspect(store, document, arguments):
    if arguments.get("dependencyMode", "transitive") == "transitive":
        from _workbench_recompute import inspect as inspect_graph
        return inspect_graph(store, document, arguments)
    context, scope = Context(store, document), _scope(document, arguments)
    outputs = []
    for kind, run in context.records:
        is_latest = context.latest[context.logical_keys[(kind, run["runId"])]] == (kind, run["runId"])
        if _in_scope(kind, run, scope) and (is_latest or arguments.get("includeHistory", False)):
            outputs.append(_inspect_output(context, kind, run, is_latest)[0])
    return {"sourceRevision": document["revision"], "outputs": outputs,
            "unhandled": _unhandled(context, scope),
            "counts": {**{status: sum(item["status"] == status for item in outputs) for status in ("current", "stale", "blocked")},
                       "total": len(outputs)}, "limits": limits(), "notes": notes()}


def _inventory_reference(inventory):
    from _workbench_store import canonical
    import _workbench_environment as environments
    encoded = (canonical(inventory) + "\n").encode()
    checksum = hashlib.sha256(encoded).hexdigest()
    return {"hash": inventory["hash"], "inventoryPath": f"artifacts/{checksum}.python-environment.json",
            "inventoryHash": checksum, "summary": environments.summary(inventory)}


def _runtime():
    import _workbench_environment as environments
    import _workbench_distributed as distributed
    inventory = environments.capture()
    signature = distributed.runtime_signature(inventory=inventory)
    return {"codeHash": signature["codeHash"], "environment": _inventory_reference(inventory)}, inventory


def preview(store, document, arguments):
    if arguments.get("dependencyMode", "transitive") == "transitive":
        from _workbench_recompute import preview as preview_graph
        return preview_graph(store, document, arguments)
    import _workbench_plugins as plugins
    from _workbench_schema import WorkbenchError
    context, scope = Context(store, document), _scope(document, arguments)
    if "runRefs" in arguments:
        refs = [(item["kind"], item["runId"]) for item in arguments["runRefs"]]
        if len(refs) != len(set(refs)):
            fail("duplicate-refresh-result", "Select each retained result once.")
        selected = [(kind, _run(document, kind, identifier)) for kind, identifier in refs]
        if any(not _in_scope(kind, run, scope) for kind, run in selected):
            fail("invalid-refresh-scope", "Explicit results must intersect the selected source or reference image scope.")
    else:
        selected = [(kind, run) for kind, run in context.records if _in_scope(kind, run, scope) and
                    context.latest[context.logical_keys[(kind, run["runId"])]] == (kind, run["runId"])]
    runtime, inventory = _runtime()
    inventories = [inventory]
    plugin_environments = {}
    units = []
    for kind, run in selected:
        descriptor, args, dependencies, method = _inspect_output(context, kind, run,
            context.latest[context.logical_keys[(kind, run["runId"])]] == (kind, run["runId"]))
        if descriptor["freshness"] == "current" and not arguments.get("includeCurrent", False):
            if "runRefs" in arguments:
                fail("current-refresh-result", "An explicitly selected result is current. Set includeCurrent to recompute it deliberately.", {"runId": run["runId"]})
            continue
        if not descriptor["blockers"]:
            try:
                for dependency in dependencies:
                    for prefix in ("source", "labels", "support"):
                        if prefix + "Path" in dependency:
                            context.verify(dependency[prefix + "Path"], dependency[prefix + "Hash"])
                if kind == "plugin-measurement":
                    context.verify(method["manifestPath"], method["manifestHash"])
                    context.verify(method["pluginSourcePath"], method["pluginSourceHash"])
                    import _workbench_runtimes as runtimes
                    runtime_binding = runtimes.identity(runtimes.resolve(package_hash=method["packageHash"]))
                    key = runtime_binding["bindingHash"]
                    if key not in plugin_environments:
                        observed = plugins.capture_environment(package_hash=method["packageHash"])
                        inventories.append(observed)
                        plugin_environments[key] = _inventory_reference(observed)
                    method["environment"] = plugin_environments[key]
                    method["pluginRuntimeBinding"] = runtime_binding
            except (WorkbenchError, OSError) as exc:
                descriptor["blockers"].append(_reason(exc.code if isinstance(exc, WorkbenchError) else "artifact-unavailable", str(exc), run["imageId"]))
                descriptor["recomputable"] = False
        frozen = {"arguments": args, "dependencies": dependencies, "binding": {**method, "runtime": runtime},
                  "predecessorHash": digest(run)}
        units.append({**descriptor, **frozen, "inputFingerprint": digest(frozen),
                      "status": "blocked" if descriptor["blockers"] else "ready"})
        if len(units) > MAX_UNITS:
            fail("refresh-too-large", "A refresh supports at most 256 downstream results. Select fewer imageIds or runRefs.")
    plan = {"sourceRevision": document["revision"], "units": units,
            "readyCount": sum(item["status"] == "ready" for item in units),
            "blockedCount": sum(item["status"] == "blocked" for item in units),
            "usesExecutableCode": any(item["kind"] == "plugin-measurement" and item["status"] == "ready" for item in units),
            "runtime": runtime, "notes": notes()}
    return {"plan": plan, "previewFingerprint": digest({"projectId": document["id"], "plan": plan})}, inventories


def get(document, refresh_id):
    value = next((item for item in document.get("refreshJobs", []) if item["id"] == refresh_id), None)
    if value is None:
        fail("refresh-not-found", "This project does not contain the requested refresh job.")
    if value["definitionHash"] != digest(value["definition"]):
        fail("refresh-integrity", "The immutable downstream refresh definition changed.")
    frozen = value["definition"]["units"]
    if len(frozen) != len(value["units"]):
        fail("refresh-integrity", "The refresh checkpoint count changed.")
    for original, unit in zip(frozen, value["units"]):
        if any(unit.get(key) != item for key, item in original.items()):
            fail("refresh-integrity", "A refresh unit's frozen arguments or inputs changed.")
    return value


def _unit_current(context, unit):
    try:
        if digest(context.runs[(unit["kind"], unit["runId"])]) != unit["predecessorHash"]:
            return False
        for dependency in unit["dependencies"]:
            if context.dependency(dependency["imageId"], dependency["target"], dependency.get("timeIndex"), dependency.get("channel"), dependency.get("sourceParameters") if dependency.get("rawSourceOnly") else None) != dependency:
                return False
        if unit["status"] == "completed":
            result = context.runs[(unit["kind"], unit["resultRunId"])]
            if result["outputHash"] != unit["resultOutputHash"] or result.get("replacesRunId") != unit["runId"]:
                return False
        return True
    except Exception:
        return False


def next_unit(job):
    if job["status"] in ("completed", "cancelled"):
        return None
    unit = next((item for item in job["units"] if item["status"] != "completed"), None)
    return {"unitId": unit["id"], **{key: unit[key] for key in ("kind", "runId", "imageId")}} if unit else None


def describe(document, job, compact=False, context=None):
    if job["definition"].get("dependencyMode") == "transitive-1":
        from _workbench_recompute import describe as describe_graph
        return describe_graph(document, job, compact)
    context = context or Context(None, document)
    stale = [unit["id"] for unit in job["units"] if not _unit_current(context, unit)]
    result = {key: copy.deepcopy(job[key]) for key in ("id", "name", "status", "createdAt", "createdRevision", "definitionHash", "usesExecutableCode")}
    result.update({"progress": {"completed": sum(unit["status"] == "completed" for unit in job["units"]), "total": len(job["units"])},
                   "outputsCurrent": not stale, "staleUnitIds": stale, "nextUnit": next_unit(job),
                   "skippedCount": len(job["definition"]["skipped"]),
                   **({"error": copy.deepcopy(job["error"])} if job.get("error") else {})})
    if not compact:
        result.update({"units": [{**copy.deepcopy(unit), "outputsCurrent": unit["id"] not in stale} for unit in job["units"]],
                       "skipped": copy.deepcopy(job["definition"]["skipped"]),
                       "replacements": [{"kind": unit["kind"], "previousRunId": unit["runId"], "runId": unit["resultRunId"],
                                         "imageId": unit["imageId"]} for unit in job["units"] if unit["status"] == "completed"],
                       "runtime": copy.deepcopy(job["definition"]["runtime"]), "notes": notes()})
    return result


def inspect_jobs(document):
    context = Context(None, document)
    return [describe(document, get(document, item["id"]), compact=True, context=context) for item in document.get("refreshJobs", [])]


def check_inputs(document, job):
    if job["definition"].get("dependencyMode") == "transitive-1":
        from _workbench_recompute import check_inputs as check_graph
        return check_graph(document, job)
    context = Context(None, document)
    stale = [unit["id"] for unit in job["units"] if not _unit_current(context, unit)]
    if stale:
        fail("stale-refresh-input", "A frozen source, label mask, calibration, reference or completed replacement changed. Create a new refresh plan to use the new inputs.", {"unitIds": stale})


def create(store, document, arguments, revision, actor):
    if arguments.get("dependencyMode", "transitive") == "transitive":
        from _workbench_recompute import create as create_graph
        return create_graph(store, document, arguments, revision, actor)
    from _workbench_store import utc_now
    import _workbench_environment as environments
    if len(document.get("refreshJobs", [])) >= MAX_JOBS:
        fail("refresh-limit", "A project retains at most 100 downstream refresh jobs.")
    selection = {key: value for key, value in arguments.items() if key in ("imageIds", "runRefs", "includeCurrent", "dependencyMode")}
    response, inventories = preview(store, document, selection)
    if response["previewFingerprint"] != arguments["previewFingerprint"]:
        fail("stale-refresh-preview", "The project, executable binding or observed runtime changed. Preview the refresh again before saving it.")
    plan = response["plan"]
    if plan["blockedCount"] and not arguments.get("skipBlocked", False):
        fail("refresh-blocked", "Resolve the previewed blockers or explicitly set skipBlocked to save only ready units.", {"blockedCount": plan["blockedCount"]})
    ready = [unit for unit in plan["units"] if unit["status"] == "ready"]
    if not ready:
        fail("nothing-to-refresh", "No ready selected downstream results need recomputation.")
    if len(document.get("assayRuns", [])) + sum(item["kind"] == "assay" for item in ready) > 1000 or len(document.get("pluginRuns", [])) + sum(item["kind"] == "plugin-measurement" for item in ready) > 1000:
        fail("refresh-result-limit", "The planned replacement results exceed the project assay/plugin history limit. Export and use a new project before refreshing this many outputs.")
    for inventory in inventories:
        environments.retain(store, inventory)
    frozen = [{**{key: copy.deepcopy(value) for key, value in unit.items() if key != "status"}, "id": str(uuid.uuid4())} for unit in ready]
    definition = {"units": frozen, "skipped": [copy.deepcopy(unit) for unit in plan["units"] if unit["status"] == "blocked"],
                  "runtime": plan["runtime"], "previewFingerprint": response["previewFingerprint"]}
    job = {"id": str(uuid.uuid4()), "name": arguments.get("name", "Refresh downstream results"),
           "createdAt": utc_now(), "createdRevision": revision, "actor": copy.deepcopy(actor),
           "status": "pending", "definition": definition, "definitionHash": digest(definition),
           "usesExecutableCode": plan["usesExecutableCode"], "units": [{**copy.deepcopy(unit), "status": "pending"} for unit in frozen]}
    document.setdefault("refreshJobs", []).append(job)
    return {"refresh": describe(document, job)}


def advance(store, document, arguments, revision, actor):
    if get(document, arguments["refreshId"])["definition"].get("dependencyMode") == "transitive-1":
        from _workbench_recompute import advance as advance_graph
        return advance_graph(store, document, arguments, revision, actor)
    import _workbench_assays as assays
    import _workbench_plugins as plugins
    from _workbench_schema import WorkbenchError
    job = get(document, arguments["refreshId"])
    if job["status"] not in ("pending", "running"):
        fail("invalid-refresh-state", "Explicitly resume or retry this refresh before advancing another unit.")
    before = copy.deepcopy(document)
    try:
        check_inputs(document, job)
        runtime, _ = _runtime()
        if runtime != job["definition"]["runtime"]:
            fail("refresh-runtime-changed", "The shared runtime changed after this plan was saved. Restore its recorded environment or preview a new refresh.")
        unit = next(item for item in job["units"] if item["status"] != "completed")
        old = _run(document, unit["kind"], unit["runId"])
        if unit["arguments"] != _arguments(unit["kind"], old):
            fail("refresh-integrity", "A refresh must repeat its retained predecessor's exact measurement arguments.")
        binding = unit["binding"]
        if unit["kind"] == "assay":
            from _workbench_workflows import _assay_definition
            if digest(_assay_definition(old["assay"])) != binding["assayDefinitionHash"]:
                fail("refresh-method-changed", "The saved assay definition changed. Preview a new refresh using the current declared method.")
            result = assays.execute(store, document, "assay.run", unit["arguments"], revision)
        else:
            record = plugins._record(document, binding["pluginId"])
            if record["manifest"]["kind"] != "measurement":
                fail("refresh-method-changed", "Refresh executes measurement plugins only; segmentation cannot run through this operation.")
            if any(record[key] != binding[field] for key, field in (("packageHash", "packageHash"), ("manifestHash", "manifestHash"), ("sourceHash", "pluginSourceHash"))):
                fail("refresh-method-changed", "The frozen measurement plugin bytes changed.")
            result = plugins.execute(store, document, "plugin.run", unit["arguments"], revision,
                                     expected_environment_hash=binding["environment"]["hash"],
                                     expected_runtime_binding=binding.get("pluginRuntimeBinding"),
                                     legacy_default_runtime="pluginRuntimeBinding" not in binding)
        saved = _run(document, unit["kind"], result["run"]["runId"])
        saved.update({"replacesRunId": unit["runId"], "refreshId": job["id"], "refreshUnitId": unit["id"]})
        unit.update({"status": "completed", "resultRunId": saved["runId"], "resultOutputHash": saved["outputHash"],
                     "completedRevision": revision})
        job["status"] = "completed" if all(item["status"] == "completed" for item in job["units"]) else "running"
        if job["status"] == "completed":
            job["completedRevision"] = revision
        job.pop("error", None)
    except (WorkbenchError, OSError) as exc:
        document.clear()
        document.update(before)
        job = get(document, arguments["refreshId"])
        code = exc.code if isinstance(exc, WorkbenchError) else "storage-error"
        job["status"] = "blocked" if code in ("stale-refresh-input", "refresh-runtime-changed", "refresh-method-changed", "plugin-environment-changed", "plugin-disabled", "artifact-changed", "stale-analysis", "stale-volume-analysis") else "failed"
        job["error"] = {"code": code, "message": str(exc), **({"details": exc.details} if isinstance(exc, WorkbenchError) and exc.details is not None else {})}
    return {"refresh": describe(document, job)}


def execute(store, document, operation, arguments, revision, actor):
    if operation == "refresh.inspect":
        return inspect(store, document, arguments)
    if operation == "refresh.preview":
        return preview(store, document, arguments)[0]
    if operation == "refresh.create":
        return create(store, document, arguments, revision, actor)
    if operation == "refresh.list":
        return {"refreshes": inspect_jobs(document), "limits": limits()}
    if operation == "refresh.get":
        return {"refresh": describe(document, get(document, arguments["refreshId"]))}
    if operation == "refresh.advance":
        return advance(store, document, arguments, revision, actor)
    job = get(document, arguments["refreshId"])
    action = operation.split(".")[1]
    allowed = {"pause": ("pending", "running"), "resume": ("paused",), "retry": ("failed", "blocked"),
               "cancel": ("pending", "running", "paused", "failed", "blocked")}
    if action not in allowed or job["status"] not in allowed[action]:
        fail("invalid-refresh-state", f"Cannot {action} a {job['status']} refresh.")
    if action in ("resume", "retry"):
        check_inputs(document, job)
        job["status"] = "running"
        job.pop("error", None)
    else:
        job["status"] = "paused" if action == "pause" else "cancelled"
        if arguments.get("reason"):
            job["pauseReason"] = arguments["reason"]
    return {"refresh": describe(document, job)}


def _references(units):
    references = {}
    for unit in units:
        for dependency in unit.get("dependencies", []):
            for prefix in ("source", "labels", "support"):
                if dependency.get(prefix + "Path"):
                    references[dependency[prefix + "Path"]] = dependency[prefix + "Hash"]
        binding = unit.get("binding", {})
        for prefix in ("manifest", "pluginSource"):
            if binding.get(prefix + "Path"):
                references[binding[prefix + "Path"]] = binding[prefix + "Hash"]
        for environment in (binding.get("environment"), binding.get("runtime", {}).get("environment")):
            if environment:
                references[environment["inventoryPath"]] = environment["inventoryHash"]
    return references


def artifact_references(document):
    result = {}
    for job in document.get("refreshJobs", []):
        result.update(_references(job["definition"]["units"]))
        # Blocked candidates remain descriptive only; their potentially missing
        # inputs are deliberately not promoted into required artifact retention.
    from _workbench_recompute import artifact_references as graph_references
    result.update(graph_references(document))
    return result


def environment_bindings(document):
    result = []
    for job in document.get("refreshJobs", []):
        for unit in job["definition"]["units"]:
            for record in (unit["binding"].get("environment"), unit["binding"]["runtime"]["environment"]):
                if record:
                    result.append({key: copy.deepcopy(record[key]) for key in ("inventoryPath", "hash", "summary")})
    return result


def validate_document(document):
    records = document.get("refreshJobs", [])
    if not isinstance(records, (list, RecordList)) or len(records) > MAX_JOBS:
        fail("invalid-package", "Refresh job history exceeds its 100-job bound.")
    if len({item["id"] for item in records}) != len(records):
        fail("invalid-package", "Refresh identities must be unique.")
    for item in records:
        job = get(document, item["id"])
        if not 1 <= len(job["units"]) <= MAX_UNITS or len({unit["id"] for unit in job["units"]}) != len(job["units"]):
            fail("invalid-package", "Refresh checkpoints must be distinct and bounded.")
        if job["status"] not in ("pending", "running", "paused", "blocked", "failed", "cancelled", "completed"):
            fail("invalid-package", "Unsupported retained refresh state.")
        if job["definition"].get("dependencyMode") == "transitive-1":
            from _workbench_recompute import validate_job
            validate_job(document, job)
            continue
        for unit in job["units"]:
            if unit["kind"] not in ("assay", "plugin-measurement") or unit["status"] not in ("pending", "completed"):
                fail("invalid-package", "Unsupported retained downstream refresh unit.")
            _run(document, unit["kind"], unit["runId"])
            if unit["status"] == "completed":
                _run(document, unit["kind"], unit["resultRunId"])


def build_report(store, document, refresh_id):
    job = get(document, refresh_id)
    descriptor = describe(document, job)
    report = {"schemaVersion": 1, "refresh": descriptor, "sourceRevision": document["revision"],
              "complete": job["status"] == "completed", "outputsCurrent": descriptor["outputsCurrent"], "notes": notes()}
    if job["definition"].get("dependencyMode") == "transitive-1":
        from _workbench_recompute import report_references
        references = report_references(document, job)
        report["notes"] = descriptor["notes"]
        for path, checksum in references.items():
            store.verify_artifact(path, checksum)
        return report, references
    references = _references(job["definition"]["units"])
    for unit in job["units"]:
        for identifier in (unit["runId"], unit.get("resultRunId")):
            if identifier:
                run = _run(document, unit["kind"], identifier)
                references[run["outputPath"]] = run["outputHash"]
                if run.get("environment"):
                    references[run["environment"]["inventoryPath"]] = run["environment"]["inventoryHash"]
    for path, checksum in references.items():
        store.verify_artifact(path, checksum)
    return report, references
