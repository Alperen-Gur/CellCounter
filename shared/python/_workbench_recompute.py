"""Dependency-ordered refresh using the existing canonical scientific engines.

Historical inputs stay immutable. Future inputs are typed predecessor references;
only outputs committed by this plan may update its expected scientific state.
"""
from __future__ import annotations

from _workbench_indexed import image_capacity

from _workbench_indexed import image_index
import copy
import hashlib
import json
import uuid

MODE = "transitive-1"
KINDS = ("derived-image", "tracks", "lineage", "assay", "assay-series", "plugin-measurement", "statistics")
MAX_UNITS = 256
MAX_COMPARE_VOXELS = 64_000_000


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def notes():
    return ["Refresh follows explicit processing, tracking, lineage, measurement and statistical dependencies; every checkpoint uses the canonical engine.",
            "Registration reapplies its saved transform. It does not claim a newly estimated alignment.",
            "Derived acquisitions retain new identities. Existing specimen assignments move to the replacement representation with retained transfer history; old and new alternatives do not add biological n.",
            "Saved masks transfer only across identical acquisition-coordinate ancestry with exact retained label bytes and compatible valid support; dimensions or object IDs alone never establish identity.",
            "Manual temporal corrections transfer only where affected objects have identical voxel geometry and source-grid identity. Ambiguous corrections block that checkpoint.",
            "Historical exports remain unchanged. Report/plot tables are refreshed through retained statistical results; publish new files explicitly."]


def _image(document, identifier):
    from _workbench_core import _image as lookup
    return lookup(document, identifier)


def _parents(image):
    derivation = image.get("derivation", {})
    if derivation.get("kind") == "workspace":
        from _workbench_workspace import materialized_dependencies
        return list(dict.fromkeys(row["imageId"] for row in materialized_dependencies(image) if row.get("imageId")))
    if derivation.get("kind") == "registration":
        registration = derivation["registration"]
        return list(dict.fromkeys([registration["fixedImageId"], registration["movingImageId"]]))
    return [derivation["sourceImageId"]] if derivation.get("sourceImageId") else []


def _replacement_maps(document):
    """Retained replacements survive a cancelled coordinator, without merging data."""
    images, runs = {}, {}
    def add(mapping, key, value):
        if key == value:
            return  # Same-acquisition tracker revisions keep their stable logical ID.
        if key in mapping and mapping[key] != value:
            fail("ambiguous-refresh-replacement", "A retained result has multiple replacement branches; choose their provenance explicitly before refresh.")
        mapping[key] = value
    for image in document["images"]:
        if image.get("replacesImageId"):
            add(images, image["replacesImageId"], image["id"])
    for kind, collection in (("assay", "assayRuns"), ("plugin-measurement", "pluginRuns"), ("statistics", "statisticsRuns"), ("assay-series", "assaySeriesRuns")):
        for run in document.get(collection, []):
            previous = run.get("replacesRunId") if kind not in ("statistics", "assay-series") else run.get("predecessorRunId")
            identifier = run.get("runId", run.get("id"))
            if previous:
                add(runs, (kind, previous), (kind, identifier))
    for job in document.get("refreshJobs", []):
        completed = {unit["id"] for unit in job.get("units", []) if unit.get("status") == "completed"}
        for row in job.get("runReplacements", []):
            if row.get("unitId") in completed:
                add(runs, (row["kind"], row["previousRunId"]), (row["kind"], row["runId"]))
    for mapping in (images, runs):
        for identifier in mapping:
            _follow(mapping, identifier)
    return images, runs


def _follow(mapping, identifier):
    seen = set()
    while identifier in mapping:
        if identifier in seen:
            fail("refresh-integrity", "Retained replacement identities contain a cycle.")
        seen.add(identifier)
        identifier = mapping[identifier]
    return identifier


def grid_identity(image, images, visited=None):
    """Exact coordinate ancestry, excluding intensity operations and calibration."""
    visited = set() if visited is None else set(visited)
    if image["id"] in visited or len(visited) > 32:
        fail("invalid-processing-lineage", "The acquisition coordinate ancestry is cyclic or too deep.")
    visited.add(image["id"])
    derivation = image.get("derivation")
    if derivation:
        if derivation.get("kind") == "workspace":
            return {"kind": "workspace-grid", "coordinateIdentity": derivation.get("coordinateIdentity"), "shape": image["shape"], "axes": image["axes"]}
        if derivation.get("kind") == "registration":
            registration = derivation["registration"]
            parent = images[registration["fixedImageId"]]
            return {"kind": "fixed-registration-grid", "parent": grid_identity(parent, images, visited),
                    "selection": registration["fixedSelection"], "width": image["width"], "height": image["height"]}
        parent = images[derivation["sourceImageId"]]
        return {"kind": "selected-grid", "parent": grid_identity(parent, images, visited),
                "selection": derivation["selection"], "shape": image["shape"], "axes": image["axes"]}
    if image.get("variantOf") and image["variantOf"] in images:
        return grid_identity(images[image["variantOf"]], images, visited)
    return {"kind": "acquisition-grid", "imageId": image.get("variantRootId", image["id"]),
            "sourceHash": image["sourceHash"], "shape": image["shape"], "axes": image["axes"],
            "sourceRegion": copy.deepcopy(image.get("sourceRegion"))}


def _image_state(image, include_dependents=True):
    from _workbench_support import fingerprint
    def analysis(item):
        return {key: item.get(key) for key in ("timeIndex", "channel", "labelsHash", "parameters", "inputFingerprint", "analysisRevision", "measurementRevision")}
    return {"id": image["id"], "sourceHash": image["sourceHash"], "shape": image["shape"], "axes": image["axes"],
            "pxPerUm": image["pxPerUm"], "voxelSizeUm": image.get("voxelSizeUm"), "timeStepSeconds": image.get("timeStepSeconds"),
            "support": fingerprint(image), "derivation": image.get("derivation"), "replacesImageId": image.get("replacesImageId"),
            "analysis": analysis(image["analysis"]) if image.get("analysis") else None,
            "frames": [analysis(frame) for frame in image.get("volumeFrames", [])],
            "tracks": image.get("volumeTracks", []) if include_dependents else [],
            "lineages": [{"channel": record["channel"], "snapshot": record["currentSnapshotId"]} for record in image.get("volumeLineages", [])] if include_dependents else []}


def state(document, job):
    identifiers = set(job["definition"]["imageIds"])
    identifiers.update(row["imageId"] for row in job.get("imageReplacements", []))
    units = job["definition"]["units"]
    statistics_ids = {unit["runId"] for unit in units if unit["kind"] == "statistics"}
    statistics_ids.update(row["runId"] for row in job.get("runReplacements", []) if row["kind"] == "statistics")
    image_mapping, run_mapping = _replacement_maps(document)
    relevant_runs = {(unit["kind"], unit["runId"]) for unit in units}
    relevant_runs.update((row["kind"], row["runId"]) for row in job.get("runReplacements", []))
    return digest({"replacementEdges": {"images": sorted((left, right) for left, right in image_mapping.items() if left in identifiers or right in identifiers),
                                       "runs": sorted((left, right) for left, right in run_mapping.items() if left in relevant_runs or right in relevant_runs)},
                   "images": [_image_state(image) for image in document["images"] if image["id"] in identifiers],
                   "experimentalDesign": document.get("experimentalDesign", {}),
                   "experimentExclusions": document.get("experimentExclusions", []),
                   "runs": [{key: row.get(key) for key in ("runId", "imageId", "outputHash", "currentFingerprint", "dependencies")}
                            for row in document.get("assayRuns", []) + document.get("pluginRuns", []) if row["imageId"] in identifiers],
                   "series": [{key: row.get(key) for key in ("runId", "outputHash", "inputFingerprint", "dependencies", "predecessorRunId")}
                              for row in document.get("assaySeriesRuns", []) if any(dep["imageId"] in identifiers for dep in row["dependencies"])],
                   "statistics": [{"id": row["id"], "inputHash": row["inputHash"], "resultHash": row["resultHash"], "replacementRunId": row.get("replacementRunId")}
                                  for row in document.get("statisticsRuns", []) if row["id"] in statistics_ids],
                   "plugins": [{key: row.get(key) for key in ("pluginId", "enabled", "packageHash", "manifestHash", "sourceHash")}
                               for row in document.get("plugins", []) if row["pluginId"] in {unit.get("arguments", {}).get("pluginId") for unit in units}]})


def _records(document):
    import _workbench_volume as volume
    import _workbench_lineages as lineage
    import _workbench_preprocessing as preprocessing
    import _workbench_refresh as refresh
    import _workbench_statistics as statistics
    records = []
    images = image_index(document)
    image_mapping, run_mapping = _replacement_maps(document)
    superseded_images = set(image_mapping)
    for image in document["images"]:
        if image.get("derivation") and image["id"] not in superseded_images:
            try:
                current = preprocessing.inspect(image, document)["parentInputsCurrent"]
            except (KeyError, ValueError):
                current = False
            records.append({"kind": "derived-image", "runId": "derived:" + image["id"], "imageId": image["id"], "label": image["name"],
                            "current": current, "parents": _parents(image), "record": image["derivation"]})
        for tracks in image.get("volumeTracks", []):
            if ("tracks", "tracks:" + image["id"] + ":" + str(tracks["channel"])) in run_mapping:
                continue
            records.append({"kind": "tracks", "runId": "tracks:" + image["id"] + ":" + str(tracks["channel"]), "imageId": image["id"],
                            "label": "Object tracks", "channel": tracks["channel"], "current": tracks["inputFingerprint"] == volume.tracks_fingerprint(image, tracks),
                            "parents": [image["id"]], "record": tracks})
        for record in image.get("volumeLineages", []):
            snapshot = lineage.snapshot_for(record)
            if ("lineage", snapshot["id"]) in run_mapping:
                continue
            records.append({"kind": "lineage", "runId": snapshot["id"], "imageId": image["id"], "label": "Lineage graph", "channel": record["channel"],
                            "current": lineage.snapshot_current(image, snapshot), "parents": [image["id"]], "record": snapshot})
    context = refresh.Context(None, document)
    replaced = {(kind, run.get("replacesRunId")) for kind, run in context.records if run.get("replacesRunId")}
    for kind, run in context.records:
        if (kind, run["runId"]) in replaced or (kind, run["runId"]) in run_mapping or context.latest[context.logical_keys[(kind, run["runId"])]] != (kind, run["runId"]):
            continue
        descriptor = refresh._inspect_output(context, kind, run, True)[0]
        records.append({"kind": kind, "runId": run["runId"], "imageId": run["imageId"], "label": descriptor["label"],
                        "current": descriptor["freshness"] == "current", "parents": [dep["imageId"] for dep in run.get("dependencies", [])] or [run["imageId"]],
                        "record": run})
    import _workbench_assay_series as series
    latest_series = {}
    for run in document.get("assaySeriesRuns", []):
        if ("assay-series", run["runId"]) not in run_mapping:
            latest_series[digest({key: value for key, value in run["arguments"].items() if key != "name"})] = run
    for run in latest_series.values():
        parents = list(dict.fromkeys(dep["imageId"] for dep in run["dependencies"]))
        records.append({"kind": "assay-series", "runId": run["runId"], "imageId": parents[0], "label": run["name"],
                        "current": series.current(document, run), "parents": parents, "record": run})
    for run in document.get("statisticsRuns", []):
        if run.get("replacementRunId") or ("statistics", run["id"]) in run_mapping:
            continue
        parents = list(dict.fromkeys(dep["imageId"] for dep in run["dependencies"]))
        records.append({"kind": "statistics", "runId": run["id"], "imageId": parents[0] if parents else "", "label": run["name"],
                        "current": statistics.current(document, run), "parents": parents, "record": run})
    # Source-only currentness is transitive; a current derived hash can still
    # represent an obsolete ancestor. Propagate staleness without pixel reads.
    stale_images = superseded_images | {item["imageId"] for item in records if item["kind"] == "derived-image" and not item["current"]}
    changed = True
    while changed:
        changed = False
        for item in records:
            if item["kind"] == "derived-image" and item["imageId"] not in stale_images and set(item["parents"]) & stale_images:
                stale_images.add(item["imageId"]); changed = True
    for item in records:
        if set(item["parents"]) & stale_images or item["imageId"] in stale_images:
            item["current"] = False
    return records


def _descriptor(item, document):
    image = image_index(document).get(item["imageId"])
    return {"kind": item["kind"], "runId": item["runId"], "imageId": item["imageId"], "imageName": image["name"] if image else "Experimental design",
            "label": item["label"], "target": "volume" if item["kind"] in ("tracks", "lineage") else item["record"].get("target", "plane"),
            **({"channel": item["channel"]} if "channel" in item else {}), "logicalKey": digest([item["kind"], item["runId"]]),
            "latest": True, "status": "current" if item["current"] else "stale", "freshness": "current" if item["current"] else "stale",
            "recomputable": True, "reasons": [] if item["current"] else [{"code": "changed-dependencies", "message": "A scientific input or upstream result changed."}], "blockers": []}


def _affected_scope(document, scope):
    if scope is None:
        return None
    result = set(scope)
    changed = True
    while changed:
        changed = False
        for image in document["images"]:
            identities = {image["id"], image.get("replacesImageId")} - {None}
            if identities & result and not identities <= result:
                result.update(identities); changed = True
            if image["id"] not in result and set(_parents(image)) & result:
                result.add(image["id"]); changed = True
    return result


def inspect(store, document, args):
    import _workbench_refresh as refresh
    scope = _affected_scope(document, refresh._scope(document, args))
    rows = [_descriptor(item, document) for item in _records(document) if scope is None or item["imageId"] in scope or scope & set(item["parents"])]
    if args.get("includeHistory"):
        old = refresh.inspect(store, document, {**args, "dependencyMode": "measurements"})["outputs"]
        seen = {(row["kind"], row["runId"]) for row in rows}
        rows.extend(row for row in old if (row["kind"], row["runId"]) not in seen)
    return {"sourceRevision": document["revision"], "dependencyMode": "transitive", "outputs": rows,
            "counts": {**{status: sum(row["status"] == status for row in rows) for status in ("current", "stale", "blocked")}, "total": len(rows)},
            "unhandled": [{"kind": "historical-exports", "status": "historical", "message": "Exported files remain immutable snapshots; publish refreshed reports to a new path."}],
            "limits": refresh.limits(), "notes": notes()}


def _refs(document, image_ids):
    import _workbench_support as support
    refs = {}
    for image in document["images"]:
        if image["id"] not in image_ids:
            continue
        refs[image["sourcePath"]] = image["sourceHash"]
        for analysis in ([image["analysis"]] if image.get("analysis") else []) + image.get("volumeFrames", []):
            refs[analysis["labelsPath"]] = analysis["labelsHash"]
        refs.update(support.artifact_references({"images": [image]}))
    return refs


def _arguments(item):
    import _workbench_refresh as refresh
    record = item["record"]
    if item["kind"] == "assay-series":
        return copy.deepcopy(record["arguments"])
    if item["kind"] in ("assay", "plugin-measurement"):
        return refresh._arguments(item["kind"], record)
    if item["kind"] == "derived-image":
        if record.get("kind") == "workspace":
            return {"imageId": item["imageId"], "operation": "workspace-materialize"}
        if record.get("kind") == "registration":
            source = record["registration"]
            return {key: copy.deepcopy(source[key]) for key in ("fixedImageId", "movingImageId", "fixedSelection", "movingSelection", "shiftPx", "interpolation", "fillValue")}
        return {"imageId": record["sourceImageId"], "recipe": copy.deepcopy(record["recipe"]), **copy.deepcopy(record["selection"])}
    if item["kind"] == "tracks":
        return {"imageId": item["imageId"], "channel": record["channel"], "timeIndices": list(record["timeIndices"]), **copy.deepcopy(record["parameters"])}
    return {"imageId": item["imageId"], "channel": item.get("channel")} if item["kind"] == "lineage" else {"runId": item["runId"]}


def _selected_records(document, args):
    import _workbench_refresh as refresh
    records = _records(document)
    image_mapping, run_mapping = _replacement_maps(document)
    scope = _affected_scope(document, refresh._scope(document, args))
    chosen = {(row["kind"], row["runId"]) for row in args.get("runRefs", [])}
    if chosen and not chosen.issubset({(row["kind"], row["runId"]) for row in records}):
        fail("refresh-result-not-found", "Select current logical results or their latest replacements from refresh.inspect.")
    selected = [row for row in records if (not chosen or (row["kind"], row["runId"]) in chosen) and
                (scope is None or row["imageId"] in scope or scope & set(row["parents"])) and
                (not row["current"] or args.get("includeCurrent"))]
    if chosen and len(selected) != len(chosen):
        fail("current-refresh-result", "Every explicit result must intersect the scope and be stale, or includeCurrent must be true.")
    derived = {row["imageId"]: row for row in records if row["kind"] == "derived-image"}
    selected_keys = {(row["kind"], row["runId"]) for row in selected}
    def add_parents(item, visited=None):
        visited = set() if visited is None else set(visited)
        if item["imageId"] in visited and item["kind"] == "derived-image":
            fail("invalid-processing-lineage", "Derived acquisition dependencies contain a cycle.")
        visited.add(item["imageId"])
        for identifier in item["parents"]:
            parent = derived.get(_follow(image_mapping, identifier))
            if parent and parent is not item and not parent["current"]:
                add_parents(parent, visited)
                key = (parent["kind"], parent["runId"])
                if key not in selected_keys:
                    selected.append(parent); selected_keys.add(key)
        if item["kind"] == "lineage" and item["record"].get("bindingKind") != "temporal":
            track = next((row for row in records if row["kind"] == "tracks" and _follow(image_mapping, row["imageId"]) == _follow(image_mapping, item["imageId"]) and row["channel"] == item["channel"]), None)
            if track and not track["current"] and (track["kind"], track["runId"]) not in selected_keys:
                selected.append(track); selected_keys.add((track["kind"], track["runId"]))
    for item in list(selected):
        add_parents(item)
    # Deterministic parent-first topological order, then temporal and outputs.
    ordered, active, done = [], set(), set()
    def order(item):
        key = (item["kind"], item["runId"])
        if key in done: return
        if key in active: fail("refresh-dependency-cycle", "The requested refresh graph contains a cycle.")
        active.add(key)
        for identifier in item["parents"]:
            parent = derived.get(_follow(image_mapping, identifier))
            if parent and parent is not item and (parent["kind"], parent["runId"]) in selected_keys: order(parent)
        active.remove(key); done.add(key); ordered.append(item)
    for item in sorted(selected, key=lambda row: (KINDS.index(row["kind"]), row["imageId"], row["runId"])): order(item)
    if len(ordered) > MAX_UNITS or len(document["images"]) + sum(row["kind"] == "derived-image" for row in ordered) > image_capacity(document):
        fail("refresh-too-large", "The plan exceeds 256 checkpoints or the 1,000-acquisition project capacity. Select a smaller scope.")
    return ordered, image_mapping, run_mapping


def external_source_paths(document, args, *, refresh_id=None):
    """Authorize only selected/frozen replay dependencies before external reads.

    Selection shares the metadata-only planner. Retained workspace provenance
    includes generated parents and exact source bindings; no NGFF bytes or
    executable environments are opened by this inspection.
    """
    if refresh_id is None:
        if args.get("dependencyMode", "transitive") == "measurements": return []
        units, _, _ = _selected_records(document, args)
    else:
        job = next((item for item in document.get("refreshJobs", []) if item["id"] == refresh_id), None)
        if job is None: fail("refresh-not-found", "The selected refresh plan is unavailable.")
        if job.get("definition", {}).get("dependencyMode") != MODE: return []
        units = [unit for unit in job["units"] if unit.get("status") != "completed"]
    source_ids = set()
    for unit in units:
        if unit["kind"] != "derived-image": continue
        image = _image(document, unit["imageId"])
        origin = image.get("derivation", {})
        if origin.get("kind") != "workspace": continue
        pending, visited = [origin], set()
        while pending:
            provenance = pending.pop()
            for binding in provenance.get("resolvedInputs", []) + provenance.get("sourceBindings", []):
                if binding.get("sourceKind") == "zarr": source_ids.add(binding["sourceId"])
            for plane in provenance.get("parentPlanes", []):
                identity = (plane.get("path"), plane.get("hash"))
                if identity in visited: continue
                visited.add(identity)
                if len(visited) > 256: fail("workspace-provenance-limit", "The frozen workspace has more than 256 generated parent planes.")
                pending.append(plane.get("provenance", {}))
    import _workbench_zarr as zarr
    return sorted({zarr.source(document, source_id)["path"] for source_id in source_ids})


def preview(store, document, args):
    import _workbench_refresh as refresh
    import _workbench_plugins as plugins
    import _workbench_lineages as lineage
    from _workbench_schema import WorkbenchError
    ordered, image_mapping, run_mapping = _selected_records(document, args)
    runtime, inventory = refresh._runtime()
    inventories, plugin_environments, units = [inventory], {}, []
    producers, unit_by_key = {}, {}
    image_ids = set()
    for item in ordered:
        descriptor = _descriptor(item, document)
        arguments = _arguments(item)
        identifier = "u-" + digest([item["kind"], item["runId"]])[:24]
        requires = [producers[_follow(image_mapping, parent_id)] for parent_id in item["parents"] if _follow(image_mapping, parent_id) in producers]
        binding = {"runtime": runtime}
        blockers = []
        try:
            if item["kind"] == "tracks":
                if "maxDistance" not in arguments:
                    fail("manual-track-policy-required", "This manually constructed tracker has no saved automatic matching method. Review and recreate its baseline explicitly.")
                if "correctionHistory" not in item["record"]:
                    fail("legacy-track-evidence-required", "This historical tracker did not retain exact edit/label evidence. Rebuild its baseline explicitly once before automatic correction-preserving refresh.")
            elif item["kind"] == "lineage":
                snapshot = item["record"]
                graph = lineage.load_graph(store, snapshot)
                binding.update({"graphPath": snapshot["graphPath"], "graphHash": snapshot["graphHash"]})
                if graph.get("temporalInference"):
                    binding["reexecution"] = copy.deepcopy(graph["temporalInference"]["reexecution"])
                baseline = next((row for row in reversed(lineage.record_for(_image(document, item["imageId"]), item["channel"])["snapshots"])
                                 if row["revision"] <= snapshot["revision"] and row["operation"] in ("lineage.initialize", "temporal.track.run")), None)
                if baseline is None:
                    fail("lineage-baseline-required", "A retained initialization/inference snapshot is required to distinguish manual corrections.")
                binding["baselineGraphPath"], binding["baselineGraphHash"] = baseline["graphPath"], baseline["graphHash"]
                related_ids = {related_id for related_id in image_ids | {item["imageId"], _follow(image_mapping, item["imageId"])}
                               if _follow(image_mapping, related_id) == _follow(image_mapping, item["imageId"])}
                track_ids = {"tracks:" + related_id + ":" + str(item["channel"]) for related_id in related_ids}
                track_key = next((key for key in unit_by_key if key[0] == "tracks" and key[1] in track_ids), None)
                if track_key and snapshot.get("bindingKind") != "temporal": requires.append(unit_by_key[track_key])
            elif item["kind"] == "assay":
                from _workbench_workflows import _freeze_assay
                definition = _freeze_assay({"type": "assay", "assay": item["record"]["assay"], "assayParameters": arguments["parameters"]}, 3 if arguments["target"] == "volume" else 2)
                binding["assayDefinitionHash"] = definition["assayDefinitionHash"]
            elif item["kind"] == "assay-series":
                import _workbench_assay_series as series
                binding["seriesEngineVersion"] = series.ENGINE_VERSION
                binding["seriesDefinitionHash"] = digest(series.definition_schema())
            elif item["kind"] == "plugin-measurement":
                plugin = plugins._record(document, arguments["pluginId"])
                if not plugin.get("enabled") or plugin["packageHash"] != item["record"]["packageHash"]:
                    fail("plugin-disabled-or-changed", "Enable the exact retained measurement plugin before preparing this refresh.")
                import _workbench_runtimes as runtimes
                runtime_binding = runtimes.identity(runtimes.resolve(package_hash=plugin["packageHash"]))
                key = runtime_binding["bindingHash"]
                if key not in plugin_environments:
                    observed = plugins.capture_environment(package_hash=plugin["packageHash"]); inventories.append(observed)
                    plugin_environments[key] = refresh._inventory_reference(observed)
                binding.update({"pluginId": plugin["pluginId"], "packageHash": plugin["packageHash"], "environment": plugin_environments[key],
                                "pluginRuntimeBinding": runtime_binding,
                                "manifestPath": plugin["manifestPath"], "manifestHash": plugin["manifestHash"],
                                "pluginSourcePath": plugin["sourcePath"], "pluginSourceHash": plugin["sourceHash"]})
            elif item["kind"] == "statistics":
                requires.extend(unit["id"] for unit in units if unit["kind"] in ("assay", "assay-series", "plugin-measurement") and _follow(image_mapping, unit["imageId"]) in {_follow(image_mapping, parent) for parent in item["parents"]})
            if item["kind"] in ("assay", "plugin-measurement"):
                import _workbench_core as core
                import _workbench_volume as volume
                for parent_id in item["parents"]:
                    mapped_parent = _follow(image_mapping, parent_id)
                    if mapped_parent in producers:
                        continue
                    parent = _image(document, mapped_parent)
                    if arguments.get("target") == "volume":
                        volume.current_frame(store, parent, arguments["timeIndex"], arguments["channel"], verify=False)
                    elif not (item["kind"] == "assay" and any(dep.get("rawSourceOnly") and dep["imageId"] == parent_id for dep in item["record"].get("dependencies", []))):
                        core._current_analysis(store, parent, verify_files=False)
        except (WorkbenchError, OSError, KeyError) as exc:
            blockers.append({"code": getattr(exc, "code", "missing-reexecution-evidence"), "message": str(exc)})
        if any(unit["status"] == "blocked" and unit["id"] in requires for unit in units):
            blockers.append({"code": "blocked-predecessor", "message": "A required predecessor cannot be safely refreshed."})
        frozen = {"arguments": arguments, "binding": binding, "predecessorHash": digest(item["record"]), "dependsOn": sorted(set(requires))}
        unit = {**descriptor, **frozen, "id": identifier, "inputFingerprint": digest(frozen), "dependencies": [],
                "blockers": blockers, "recomputable": not blockers, "status": "blocked" if blockers else "ready"}
        if item["kind"] == "tracks": unit["predecessorRecord"] = copy.deepcopy(item["record"])
        if item["kind"] == "statistics":
            unit["binding"]["definition"] = copy.deepcopy(item["record"]["definition"])
            unit["binding"]["analysis"] = copy.deepcopy(item["record"]["analysis"])
        unit["inputFingerprint"] = digest({key: unit[key] for key in ("arguments", "binding", "predecessorHash", "dependsOn")})
        units.append(unit); unit_by_key[(item["kind"], item["runId"])] = identifier
        if item["kind"] == "derived-image": producers[item["imageId"]] = identifier
        image_ids.update(item["parents"]); image_ids.add(item["imageId"])
    # Include all roots, even roots outside an explicit downstream selection.
    queue = list(image_ids)
    while queue:
        current_id = queue.pop()
        mapped_id = image_mapping.get(current_id, current_id)
        if mapped_id not in image_ids:
            image_ids.add(mapped_id); queue.append(mapped_id)
        for parent in _parents(_image(document, current_id)):
            if parent not in image_ids: image_ids.add(parent); queue.append(parent)
    references = _refs(document, image_ids)
    for path, checksum in references.items(): store.verify_artifact(path, checksum)
    assignment_transfers = [{"imageId": row["imageId"], "specimenId": row["specimenId"], "producerUnitId": producers[row["imageId"]]}
                           for row in document.get("experimentalDesign", {}).get("assignments", []) if row["imageId"] in producers]
    plan = {"dependencyMode": "transitive", "sourceRevision": document["revision"], "units": units,
            "readyCount": sum(row["status"] == "ready" for row in units), "blockedCount": sum(row["status"] == "blocked" for row in units),
            "usesExecutableCode": any(row["kind"] == "plugin-measurement" and row["status"] == "ready" for row in units),
            "imageIds": sorted(image_ids), "assignmentTransfers": assignment_transfers, "runtime": runtime, "notes": notes(),
            "existingImageReplacements": [{"previousImageId": left, "imageId": right} for left, right in sorted(image_mapping.items()) if left in image_ids or right in image_ids],
            "existingRunReplacements": [{"kind": left[0], "previousRunId": left[1], "runId": _follow(run_mapping, left)[1]} for left in sorted(run_mapping)
                                        if any(unit["runId"] == left[1] or unit.get("binding", {}).get("definition", {}).get("outcome", {}).get("runId") == left[1] for unit in units)],
            "inputReferences": [{"path": path, "hash": checksum} for path, checksum in sorted(references.items())]}
    return {"plan": plan, "previewFingerprint": digest({"projectId": document["id"], "plan": plan})}, inventories


def create(store, document, args, revision, actor):
    import _workbench_refresh as refresh
    import _workbench_environment as environment
    from _workbench_store import utc_now
    if len(document.get("refreshJobs", [])) >= refresh.MAX_JOBS: fail("refresh-limit", "A project retains at most 100 refresh jobs.")
    response, inventories = preview(store, document, args)
    plan = response["plan"]
    if args["previewFingerprint"] != response["previewFingerprint"]: fail("stale-refresh-preview", "Inputs, methods or the runtime changed; preview this dependency plan again.")
    if plan["blockedCount"] and not args.get("skipBlocked"): fail("refresh-blocked", "Resolve blockers or explicitly save only ready dependency units.")
    ready = [{key: copy.deepcopy(value) for key, value in row.items() if key != "status"} for row in plan["units"] if row["status"] == "ready"]
    if not ready: fail("nothing-to-refresh", "No executable selected dependencies need refreshing.")
    for inventory in inventories: environment.retain(store, inventory)
    definition = {"dependencyMode": MODE, "units": ready, "skipped": [row for row in plan["units"] if row["status"] == "blocked"],
                  "runtime": plan["runtime"], "imageIds": plan["imageIds"], "inputReferences": plan["inputReferences"],
                  "assignmentTransfers": plan["assignmentTransfers"], "previewFingerprint": response["previewFingerprint"],
                  "existingImageReplacements": plan["existingImageReplacements"], "existingRunReplacements": plan["existingRunReplacements"]}
    job = {"id": str(uuid.uuid4()), "name": args.get("name", "Refresh dependent analyses"), "createdAt": utc_now(), "createdRevision": revision,
           "actor": copy.deepcopy(actor), "status": "pending", "definition": definition, "definitionHash": digest(definition),
           "usesExecutableCode": plan["usesExecutableCode"], "units": [{**copy.deepcopy(row), "status": "pending"} for row in ready],
           "imageReplacements": [], "runReplacements": [], "assignmentTransfers": []}
    job["expectedStateHash"] = state(document, job)
    document.setdefault("refreshJobs", []).append(job)
    return {"refresh": describe(document, job)}


def check_inputs(document, job):
    if state(document, job) != job["expectedStateHash"]:
        fail("stale-refresh-input", "An external scientific input, assignment or completed dependency changed. Prepare a new plan; completed historical checkpoints remain retained.")


def _mapped(job, identifier):
    rows = job["definition"].get("existingImageReplacements", []) + job.get("imageReplacements", [])
    return _follow({row["previousImageId"]: row["imageId"] for row in rows}, identifier)


def _mapped_run(job, kind, identifier):
    rows = job["definition"].get("existingRunReplacements", []) + job.get("runReplacements", [])
    mapping = {(row["kind"], row["previousRunId"]): (row["kind"], row["runId"]) for row in rows if row["previousRunId"] != row["runId"]}
    return _follow(mapping, (kind, identifier))[1]


def _mapped_args(job, args):
    args = copy.deepcopy(args)
    for key in ("imageId", "fixedImageId", "movingImageId"):
        if key in args: args[key] = _mapped(job, args[key])
    for key in ("nuclearImageId", "somaImageId"):
        if key in args.get("parameters", {}):
            args["parameters"][key] = _mapped(job, args["parameters"][key])
    for frame in args.get("frames", []):
        if "imageId" in frame: frame["imageId"] = _mapped(job, frame["imageId"])
    return args


def _transfer_masks(store, document, old, new, revision):
    import _workbench_core as core
    import _workbench_volume as volume
    import _workbench_support as support
    images = image_index(document)
    if digest(grid_identity(old, images)) != digest(grid_identity(new, images)):
        fail("ambiguous-mask-grid-transfer", "The replacement does not preserve the same exact acquisition-coordinate ancestry. Review/rebind masks explicitly.")
    transfers = []
    if old.get("analysis"):
        analysis = old["analysis"]
        labels = core._labels(store, old, analysis)
        support.assert_labels(store, new, labels, analysis["parameters"])
        plane = core._source(store, new, analysis["parameters"])
        core._set_analysis(store, new, labels, plane, analysis["parameters"], revision,
                           {**copy.deepcopy(analysis.get("imageStats", {})), "refreshMaskTransfer": {"imageId": old["id"], "labelsHash": analysis["labelsHash"]}})
        if new["analysis"]["labelsHash"] != analysis["labelsHash"]:
            fail("mask-transfer-changed", "Exact mask transfer unexpectedly changed raster labels.")
        transfers.append({"target": "plane", "labelsHash": analysis["labelsHash"]})
    for frame in old.get("volumeFrames", []):
        labels = volume.read_labels(store, old, frame)
        support.assert_labels(store, new, labels)
        raw = volume.load_source(store, new, frame["timeIndex"], frame["channel"])
        saved = volume.save_frame(store, new, raw, labels, frame["parameters"], frame["timeIndex"], frame["channel"], revision,
                                  {**copy.deepcopy(frame.get("imageStats", {})), "refreshMaskTransfer": {"imageId": old["id"], "labelsHash": frame["labelsHash"]}}, undo=False)
        if saved["labelsHash"] != frame["labelsHash"]: fail("mask-transfer-changed", "Exact volumetric mask transfer changed labels unexpectedly.")
        transfers.append({"target": "volume", "timeIndex": frame["timeIndex"], "channel": frame["channel"], "labelsHash": frame["labelsHash"]})
    return transfers


def _derived(store, document, job, unit, revision, actor):
    import _workbench_core as core
    import _workbench_registration as registration
    import _workbench_preprocessing as preprocessing
    old = _image(document, unit["imageId"])
    args = _mapped_args(job, unit["arguments"])
    args["name"] = old["name"][:170] + " · refreshed"
    if old["derivation"].get("kind") == "workspace":
        import _workbench_workspace as workspaces
        workspaces.verify_materialized_inputs(store, document, old)
        replacements = {row["previousImageId"]: _mapped(job, row["previousImageId"]) for row in job["definition"].get("existingImageReplacements", []) + job.get("imageReplacements", [])}
        response = workspaces.reexecute(store, document, old, revision, replacements)
    elif old["derivation"].get("kind") == "registration":
        response = registration.execute(store, document, "registration.apply", args, revision)
    else:
        response = preprocessing.execute(store, document, "preprocessing.run", args, revision, {"image": core._image, "source": core._source})
    new = _image(document, response["derivedImageId"])
    transferred = _transfer_masks(store, document, old, new, revision)
    new["replacesImageId"] = old["id"]
    new["refreshOrigin"] = {"refreshId": job["id"], "unitId": unit["id"], "predecessorImageId": old["id"], "maskTransfers": transferred,
                            "coordinateIdentity": digest(grid_identity(new, image_index(document)))}
    for assignment in document.get("experimentalDesign", {}).get("assignments", []):
        if assignment["imageId"] == old["id"]:
            job["assignmentTransfers"].append({"unitId": unit["id"], "previous": copy.deepcopy(assignment), "imageId": new["id"], "revision": revision})
            assignment["imageId"] = new["id"]
    import _workbench_experiment_layouts as experiment_layouts
    excluded = experiment_layouts.effective_exclusions(document)["image"].get(old["id"])
    if excluded:
        transferred_exclusion = experiment_layouts.execute(store, document, "experiment.exclusion.set",
            {"target": "image", "targetId": new["id"], "excluded": True, "reason": excluded["reason"]}, revision, actor)["exclusion"]
        document["experimentExclusions"][-1]["transferredFrom"] = {"exclusionId": excluded["id"], "imageId": old["id"], "refreshId": job["id"]}
        new["refreshOrigin"]["transferredExclusionId"] = transferred_exclusion["id"]
    job["imageReplacements"].append({"previousImageId": old["id"], "imageId": new["id"], "unitId": unit["id"]})
    return {"resultImageId": new["id"], "resultRunId": new["id"], "resultOutputHash": new["sourceHash"], "outputBinding": _image_state(new, include_dependents=False), "maskTransfers": transferred}


def _exact_objects(store, image, frame_references, observations):
    import numpy as np
    import _workbench_volume as volume
    compared = 0
    by_time = {}
    for time, label in observations: by_time.setdefault(time, set()).add(label)
    references = {row["timeIndex"]: row for row in frame_references}
    for time, labels in by_time.items():
        previous = references.get(time)
        if previous is None: fail("correction-evidence-missing", "A manual correction has no retained source mask for exact identity comparison.")
        current = volume.current_frame(store, image, time, previous["channel"])
        current_ids = {cell["labelId"] for cell in current["cells"]}
        if not labels <= current_ids: fail("ambiguous-correction-transfer", "A manually referenced object no longer exists. Review its correspondence explicitly.")
        if previous["labelsHash"] == current["labelsHash"]: continue
        left = volume.read_labels(store, image, previous); right = volume.read_labels(store, image, current)
        compared += int(left.size)
        if compared > MAX_COMPARE_VOXELS: fail("correction-comparison-limit", "Exact manual correction comparison exceeds 64 million voxels; review a smaller temporal scope.")
        if left.shape != right.shape: fail("ambiguous-correction-transfer", "The manual correction grid changed.")
        # Both ownership and identity must match at every affected object's voxel.
        mask = np.isin(left, list(labels)) | np.isin(right, list(labels))
        if not np.array_equal(left[mask], right[mask]):
            fail("ambiguous-correction-transfer", "A manually referenced object's exact voxel geometry changed. Numeric IDs/counts do not establish a safe correspondence.")


def _tracks(store, document, job, unit, revision):
    import _workbench_volume as volume
    old = unit["predecessorRecord"]
    image = _image(document, _mapped(job, unit["imageId"]))
    images = image_index(document)
    if digest(grid_identity(_image(document, unit["imageId"]), images)) != digest(grid_identity(image, images)):
        fail("ambiguous-correction-grid", "Tracking corrections cannot cross a changed acquisition-coordinate identity.")
    corrections = old.get("correctionHistory", [])
    observations = {(entry["arguments"][prefix + "TimeIndex"], entry["arguments"][prefix + "LabelId"])
                    for entry in corrections for prefix in ("source", "target")}
    if observations:
        _exact_objects(store, image, old.get("frameReferences", []), observations)
    response = volume.run_tracks(store, image, _mapped_args(job, unit["arguments"]), revision)
    for correction in corrections:
        args = {**correction["arguments"], "imageId": image["id"], "channel": unit["channel"]}
        record = volume.get_tracks(image, unit["channel"])
        keys = ("sourceTimeIndex", "sourceLabelId", "targetTimeIndex", "targetLabelId")
        match = next((edge for edge in record["edges"] if all(edge[key] == args[key] for key in keys)), None)
        if correction["operation"] == "tracks.unlink" and match is None: continue
        if correction["operation"] == "tracks.link" and match is not None: continue
        if correction["operation"] == "tracks.link":
            conflicts = [edge for edge in record["edges"] if (edge["sourceTimeIndex"], edge["sourceLabelId"]) == (args["sourceTimeIndex"], args["sourceLabelId"]) or (edge["targetTimeIndex"], edge["targetLabelId"]) == (args["targetTimeIndex"], args["targetLabelId"])]
            if any(edge.get("origin") != "automatic" for edge in conflicts):
                fail("ambiguous-track-refresh", "Preserved manual correspondences conflict with one another; review the tracker explicitly.")
            record["edges"] = [edge for edge in record["edges"] if edge not in conflicts]
        volume.edit_track(store, image, correction["operation"], args, revision)
    record = volume.get_tracks(image, unit["channel"])
    record["correctionHistory"] = copy.deepcopy(corrections)
    record["refreshOrigin"] = {"refreshId": job["id"], "unitId": unit["id"], "predecessorHash": unit["predecessorHash"]}
    return {"resultImageId": image["id"], "resultRunId": "tracks:" + image["id"] + ":" + str(unit["channel"]),
            "resultOutputHash": digest(record), "retainedRecord": copy.deepcopy(record), "outputBinding": {"kind": "tracks", "imageId": image["id"], "channel": unit["channel"], "hash": digest(record)}}


def _edge_key(edge): return edge["sourceNodeId"], edge["targetNodeId"], edge["kind"]
def _division_key(row): return row["parent"]["timeIndex"], row["parent"]["labelId"], tuple(sorted((child["timeIndex"], child["labelId"]) for child in row["daughters"]))


def _lineage(store, document, job, unit, revision, actor):
    import _workbench_lineages as lineage
    import _workbench_temporal as temporal
    old = lineage.load_graph(store, {"graphPath": unit["binding"]["graphPath"], "graphHash": unit["binding"]["graphHash"]})
    base = lineage.load_graph(store, {"graphPath": unit["binding"]["baselineGraphPath"], "graphHash": unit["binding"]["baselineGraphHash"]})
    image = _image(document, _mapped(job, unit["imageId"]))
    images = image_index(document)
    if digest(grid_identity(_image(document, unit["imageId"]), images)) != digest(grid_identity(image, images)):
        fail("ambiguous-correction-grid", "Lineage corrections cannot cross a changed acquisition-coordinate identity.")
    old_edges, base_edges = ({_edge_key(edge): edge for edge in graph["edges"]} for graph in (old, base))
    added = [edge for key, edge in old_edges.items() if key not in base_edges or digest(edge) != digest(base_edges[key])]
    removed = set(base_edges) - set(old_edges)
    old_div, base_div = ({_division_key(row): row for row in graph["divisions"]} for graph in (old, base))
    added_div = [row for key, row in old_div.items() if key not in base_div or digest(row) != digest(base_div[key])]
    removed_div = set(base_div) - set(old_div)
    touched = {node for edge in added for node in (edge["sourceNodeId"], edge["targetNodeId"])}
    touched.update(node for key in removed for node in key[:2])
    for division in added_div:
        touched.add(lineage.node_id(division["parent"]["timeIndex"], division["parent"]["labelId"]))
        touched.update(lineage.node_id(child["timeIndex"], child["labelId"]) for child in division["daughters"])
    for parent_time, parent_label, children in removed_div:
        touched.add(lineage.node_id(parent_time, parent_label))
        touched.update(lineage.node_id(time, label) for time, label in children)
    observations = {(node["timeIndex"], node["labelId"]) for node in old["nodes"] if node["id"] in touched}
    if observations: _exact_objects(store, image, old["frameReferences"], observations)
    if old.get("temporalInference"):
        args = _mapped_args(job, unit["binding"]["reexecution"]["arguments"])
        args.update({"replaceGraph": True, "reason": "Dependency refresh of saved temporal inference; exact portable manual corrections are retained."})
        preview = temporal.track_preview(store, image, args)[0]
        temporal.track_run(store, image, {**args, "previewFingerprint": preview["previewFingerprint"]}, revision, actor)
    else:
        lineage.initialize(store, image, {"channel": unit["channel"], "reason": "Dependency refresh from current matching baseline."}, revision, actor)
    record = lineage.record_for(image, unit["channel"])
    graph = lineage.load_graph(store, lineage.snapshot_for(record))
    graph["edges"] = [edge for edge in graph["edges"] if _edge_key(edge) not in removed]
    remove_divisions = {row["id"] for row in graph["divisions"] if _division_key(row) in removed_div or _division_key(row) in {_division_key(value) for value in added_div}}
    graph["divisions"] = [row for row in graph["divisions"] if row["id"] not in remove_divisions]
    graph["edges"] = [edge for edge in graph["edges"] if edge.get("divisionId") not in remove_divisions]
    # Manual edges can replace automatic continuations only; inferred division
    # conflicts require review instead of silently removing one daughter.
    for edge in added:
        conflicts = [candidate for candidate in graph["edges"] if candidate["sourceNodeId"] == edge["sourceNodeId"] or candidate["targetNodeId"] == edge["targetNodeId"]]
        if any(candidate["kind"] == "division" and candidate.get("divisionId") != edge.get("divisionId") for candidate in conflicts):
            fail("ambiguous-lineage-refresh", "A preserved manual correction conflicts with a newly inferred division. Review the new inference explicitly.")
        graph["edges"] = [candidate for candidate in graph["edges"] if candidate not in conflicts or
                          (candidate["kind"] == "division" and candidate.get("divisionId") == edge.get("divisionId") and candidate["targetNodeId"] != edge["targetNodeId"])]
        graph["edges"].append(copy.deepcopy(edge))
    graph["divisions"].extend(copy.deepcopy(added_div))
    lineage.validate_graph(graph)
    graph["refreshOrigin"] = {"refreshId": job["id"], "unitId": unit["id"], "predecessorSnapshotId": unit["runId"],
                              "predecessorGraphHash": unit["binding"]["graphHash"], "transferredManualEdges": len(added), "removedBaselineEdges": len(removed)}
    lineage.save(store, image, record, graph, revision, "refresh.lineage", actor, "Refreshed canonical inference and transferred only exact object-bound manual corrections.")
    snapshot = lineage.snapshot_for(record)
    return {"resultImageId": image["id"], "resultRunId": snapshot["id"], "resultOutputHash": snapshot["graphHash"],
            "outputBinding": {"kind": "lineage", "imageId": image["id"], "channel": unit["channel"], "snapshotId": snapshot["id"]}}


def _execute_unit(store, document, job, unit, revision, actor):
    import _workbench_refresh as refresh
    import _workbench_assays as assays
    import _workbench_plugins as plugins
    import _workbench_statistics as statistics
    kind = unit["kind"]
    if kind == "derived-image": return _derived(store, document, job, unit, revision, actor)
    if kind == "tracks": return _tracks(store, document, job, unit, revision)
    if kind == "lineage": return _lineage(store, document, job, unit, revision, actor)
    if kind == "statistics":
        old = statistics._run(document, unit["runId"])
        definition = copy.deepcopy(unit["binding"]["definition"])
        if definition["outcome"]["kind"] in ("assay", "assay-series"):
            definition["outcome"]["runId"] = _mapped_run(job, definition["outcome"]["kind"], definition["outcome"]["runId"])
        table = statistics.resolve(store, document, definition)
        result = statistics.calculate(document, table, unit["binding"]["analysis"], old["designId"], old["designVersion"])
        design = statistics._design(document, old["designId"], old["designVersion"])
        saved = statistics._retain_run(store, document, design, table, result, revision, actor, old)
        return {"resultRunId": saved["id"], "resultOutputHash": saved["resultHash"], "outputBinding": {"kind": kind, "runId": saved["id"]}}
    args = _mapped_args(job, unit["arguments"])
    if kind == "assay-series":
        import _workbench_assay_series as series
        if series.ENGINE_VERSION != unit["binding"]["seriesEngineVersion"] or digest(series.definition_schema()) != unit["binding"]["seriesDefinitionHash"]:
            fail("refresh-method-changed", "The saved time-series method changed; create a new refresh plan.")
        value, output = series.calculate(store, document, args)
        response = series.execute(store, document, "assay.series.run", {**value, "previewFingerprint": output["previewFingerprint"]}, revision, actor,
                                  calculated=(value, output))
        saved = series._find(document, response["run"]["runId"])
        saved.update({"predecessorRunId": unit["runId"], "refreshId": job["id"], "refreshUnitId": unit["id"]})
        return {"resultRunId": saved["runId"], "resultOutputHash": saved["outputHash"],
                "outputBinding": {"kind": kind, "runId": saved["runId"]}}
    if kind == "assay":
        from _workbench_workflows import _assay_definition
        if digest(_assay_definition(args["assay"])) != unit["binding"]["assayDefinitionHash"]:
            fail("refresh-method-changed", "The saved assay definition changed; create a new refresh plan.")
        response = assays.execute(store, document, "assay.run", args, revision)
    else:
        plugin = plugins._record(document, args["pluginId"])
        if plugin["packageHash"] != unit["binding"]["packageHash"]: fail("refresh-method-changed", "The frozen measurement plugin changed.")
        response = plugins.execute(store, document, "plugin.run", args, revision, expected_environment_hash=unit["binding"]["environment"]["hash"],
                                   expected_runtime_binding=unit["binding"].get("pluginRuntimeBinding"),
                                   legacy_default_runtime="pluginRuntimeBinding" not in unit["binding"])
    saved = refresh._run(document, kind, response["run"]["runId"])
    saved.update({"replacesRunId": unit["runId"], "refreshId": job["id"], "refreshUnitId": unit["id"]})
    return {"resultImageId": args["imageId"], "resultRunId": saved["runId"], "resultOutputHash": saved["outputHash"],
            "outputBinding": {"kind": kind, "runId": saved["runId"], "imageId": args["imageId"]}}


def advance(store, document, args, revision, actor):
    import _workbench_refresh as refresh
    from _workbench_schema import WorkbenchError
    job = refresh.get(document, args["refreshId"])
    if job["status"] not in ("pending", "running"): fail("invalid-refresh-state", "Resume or retry this refresh before advancing.")
    before = copy.deepcopy(document)
    try:
        check_inputs(document, job)
        if refresh._runtime()[0] != job["definition"]["runtime"]: fail("refresh-runtime-changed", "The frozen scientific runtime changed; preview a new plan.")
        unit = next(row for row in job["units"] if row["status"] != "completed")
        if any(row["status"] != "completed" for row in job["units"] if row["id"] in unit["dependsOn"]):
            fail("refresh-predecessor-pending", "Complete the selected checkpoint's predecessors first.")
        result = _execute_unit(store, document, job, unit, revision, actor)
        from _workbench_store import canonical
        checkpoint_path, checkpoint_hash = store.put_bytes((canonical({"unitId": unit["id"], "result": result, "revision": revision}) + "\n").encode(), ".refresh-checkpoint.json")
        result.pop("retainedRecord", None)
        unit.update({**result, "checkpointPath": checkpoint_path, "checkpointHash": checkpoint_hash, "status": "completed", "completedRevision": revision})
        if unit["kind"] != "derived-image":
            job["runReplacements"].append({"kind": unit["kind"], "previousRunId": unit["runId"], "runId": unit["resultRunId"], "unitId": unit["id"]})
        job["status"] = "completed" if all(row["status"] == "completed" for row in job["units"]) else "running"
        if job["status"] == "completed": job["completedRevision"] = revision
        job["expectedStateHash"] = state(document, job)
        job.pop("error", None)
    except (WorkbenchError, OSError, KeyError) as exc:
        document.clear(); document.update(before)
        job = refresh.get(document, args["refreshId"])
        job["status"] = "blocked"
        job["error"] = {"code": getattr(exc, "code", "refresh-input-unavailable"), "message": str(exc),
                        **({"details": exc.details} if isinstance(exc, WorkbenchError) and exc.details else {})}
    return {"refresh": describe(document, job)}


def _output_current(document, unit):
    if unit["status"] != "completed": return True
    binding = unit["outputBinding"]
    try:
        if unit["kind"] == "derived-image": return digest(_image_state(_image(document, unit["resultImageId"]), include_dependents=False)) == digest(binding)
        if unit["kind"] == "tracks":
            import _workbench_volume as volume
            image = _image(document, binding["imageId"])
            record = volume.get_tracks(image, binding["channel"])
            return digest(record) == binding["hash"] and record["inputFingerprint"] == volume.tracks_fingerprint(image, record)
        if unit["kind"] == "lineage":
            import _workbench_lineages as lineage
            image = _image(document, binding["imageId"])
            record = lineage.record_for(image, binding["channel"])
            return record["currentSnapshotId"] == binding["snapshotId"] and lineage.snapshot_current(image, lineage.snapshot_for(record))
        if unit["kind"] == "assay-series":
            import _workbench_assay_series as series
            return series.current(document, series._find(document, binding["runId"]))
        if unit["kind"] == "statistics":
            import _workbench_statistics as statistics
            return statistics.current(document, statistics._run(document, binding["runId"]))
        import _workbench_refresh as refresh
        import _workbench_assays as assays
        import _workbench_plugins as plugins
        record = refresh._run(document, unit["kind"], binding["runId"])
        return assays._current(document, record) if unit["kind"] == "assay" else plugins._state_fingerprint(_image(document, binding["imageId"]), record.get("target", "plane"), record.get("timeIndex"), record.get("channel")) == record["currentFingerprint"]
    except Exception: return False


def describe(document, job, compact=False):
    import _workbench_refresh as refresh
    inputs_current = state(document, job) == job["expectedStateHash"]
    stale = [unit["id"] for unit in job["units"] if not _output_current(document, unit)]
    result = {key: copy.deepcopy(job[key]) for key in ("id", "name", "status", "createdAt", "createdRevision", "definitionHash", "usesExecutableCode")}
    result.update({"dependencyMode": "transitive", "progress": {"completed": sum(unit["status"] == "completed" for unit in job["units"]), "total": len(job["units"])},
                   "inputsCurrent": inputs_current, "outputsCurrent": inputs_current and not stale, "staleUnitIds": stale,
                   "nextUnit": refresh.next_unit(job), "skippedCount": len(job["definition"]["skipped"]),
                   "imageReplacements": copy.deepcopy(job["imageReplacements"]), "runReplacements": copy.deepcopy(job["runReplacements"]),
                   **({"error": copy.deepcopy(job["error"])} if job.get("error") else {})})
    if not compact:
        result.update({"units": [{**copy.deepcopy(unit), "outputsCurrent": inputs_current and unit["id"] not in stale} for unit in job["units"]],
                       "skipped": copy.deepcopy(job["definition"]["skipped"]), "runtime": copy.deepcopy(job["definition"]["runtime"]),
                       "assignmentTransfers": copy.deepcopy(job["assignmentTransfers"]), "replacements": copy.deepcopy(job["runReplacements"]),
                       "existingImageReplacements": copy.deepcopy(job["definition"].get("existingImageReplacements", [])),
                       "existingRunReplacements": copy.deepcopy(job["definition"].get("existingRunReplacements", [])), "notes": notes()})
    return result


def artifact_references(document):
    refs = {}
    for job in document.get("refreshJobs", []):
        if job["definition"].get("dependencyMode") != MODE: continue
        for row in job["definition"]["inputReferences"]: refs[row["path"]] = row["hash"]
        for completed in job["units"]:
            if completed.get("checkpointPath"):
                refs[completed["checkpointPath"]] = completed["checkpointHash"]
        for unit in job["definition"]["units"]:
            binding = unit["binding"]
            for prefix in ("graph", "baselineGraph"):
                if binding.get(prefix + "Path"): refs[binding[prefix + "Path"]] = binding[prefix + "Hash"]
            for frame in unit.get("predecessorRecord", {}).get("frameReferences", []): refs[frame["labelsPath"]] = frame["labelsHash"]
    return refs


def report_references(document, job):
    import _workbench_refresh as refresh
    import _workbench_statistics as statistics
    import _workbench_lineages as lineage
    refs = artifact_references({"refreshJobs": [job]})
    refs.update(refresh._references(job["definition"]["units"]))
    for unit in job["units"]:
        if unit["kind"] in ("assay", "plugin-measurement"):
            for identifier in (unit["runId"], unit.get("resultRunId")):
                if identifier:
                    run = refresh._run(document, unit["kind"], identifier); refs[run["outputPath"]] = run["outputHash"]
        elif unit["kind"] == "assay-series":
            import _workbench_assay_series as series
            for identifier in (unit["runId"], unit.get("resultRunId")):
                if identifier: refs.update(series.artifact_references({"assaySeriesRuns": [series._find(document, identifier)]}))
        elif unit["kind"] == "statistics":
            for identifier in (unit["runId"], unit.get("resultRunId")):
                if identifier: refs.update(statistics.artifact_references({"statisticsRuns": [statistics._run(document, identifier)]}))
        elif unit["status"] == "completed" and unit["kind"] == "lineage":
            record = lineage.record_for(_image(document, unit["resultImageId"]), unit["channel"])
            snapshot = lineage.snapshot_for(record, unit["resultRunId"]); refs[snapshot["graphPath"]] = snapshot["graphHash"]
        elif unit["status"] == "completed" and unit["kind"] == "derived-image": refs.update(_refs(document, {unit["resultImageId"]}))
    return refs


def validate_job(document, job):
    completed = set()
    known = set()
    for unit in job["units"]:
        if unit["kind"] not in KINDS or unit["status"] not in ("pending", "completed") or set(unit["dependsOn"]) - known:
            fail("invalid-package", "Transitive refresh nodes must be supported, ordered and checkpointed.")
        known.add(unit["id"])
        if unit["status"] == "completed":
            if set(unit["dependsOn"]) - completed or not isinstance(unit.get("outputBinding"), dict):
                fail("invalid-package", "A completed refresh node lacks its completed predecessor bindings.")
            completed.add(unit["id"])
    if len(job["definition"].get("imageIds", [])) > 1000 or len(job.get("imageReplacements", [])) > MAX_UNITS or len(job.get("runReplacements", [])) > MAX_UNITS:
        fail("invalid-package", "Transitive refresh identities exceed their bounded plan.")
    if len(job.get("assignmentTransfers", [])) > 1000:
        fail("invalid-package", "Transitive assignment history exceeds the acquisition bound.")

    if len(job["definition"].get("existingImageReplacements", [])) > 1000 or len(job["definition"].get("existingRunReplacements", [])) > MAX_UNITS * 2:
        fail("invalid-package", "Frozen prior replacement bindings exceed the plan bounds.")
    image_ids = {image["id"] for image in document["images"]}
    for row in job["definition"].get("existingImageReplacements", []) + job.get("imageReplacements", []):
        if row.get("previousImageId") not in image_ids or row.get("imageId") not in image_ids:
            fail("invalid-package", "A refresh replacement references a missing acquisition.")
        _mapped(job, row["previousImageId"])
