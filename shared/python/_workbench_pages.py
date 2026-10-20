"""Coherent bounded project/library/measurement reads and explicit store upgrade."""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def operations():
    from _workbench_schema import _object, _op, _ID
    from _workbench_catalogues import selection_schema
    cursor = {"type": "string", "minLength": 1, "maxLength": 4096}
    page = {"limit": {"type": "integer", "minimum": 1, "maximum": 500, "default": 100}, "cursor": cursor}
    return [
        _op("project.snapshot", "Read compact project catalogues and explicitly selected images at one revision; no full library/history hydration.",
            _object({"selectedImageIds": {"type": "array", "items": _ID, "maxItems": 32},
                     "catalogueLimit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 25},
                     "selectedCatalogueEntries": {"type": "array", "items": selection_schema(), "maxItems": 64}})),
        _op("image.list", "Page indexed image descriptors with explicit archive, tag and collection scope.",
            _object({**page, "query": {"type": "string", "minLength": 0, "maxLength": 1000},
                     "tags": {"type": "array", "items": _ID, "maxItems": 100}, "collectionId": _ID,
                     "archiveScope": {"type": "string", "enum": ["active", "archived", "all"], "default": "active"},
                     "sourceHash": _ID, "analysisTarget": {"type": "string", "enum": ["plane", "volume"]}, "referenceCurrent": {"type": "boolean"}})),
        _op("image.get", "Read one selected acquisition descriptor without loading other images.", _object({"imageId": _ID}, ["imageId"])),
        _op("project.history", "Page append-only scientific history at an exact project revision.", _object(page)),
        _op("measurements.page", "Read bounded exact object measurements; contours are optional display payloads.",
            _object({"imageId": _ID, "target": {"type": "string", "enum": ["plane", "volume"], "default": "plane"},
                     "timeIndex": {"type": "integer", "minimum": 0}, "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 200},
                     "cursor": cursor, "includeContours": {"type": "boolean", "default": False}}, ["imageId"])),
        _op("measurements.lookup", "Read exact saved objects by label identity, independently of table pagination.",
            _object({"imageId": _ID, "target": {"type": "string", "enum": ["plane", "volume"], "default": "plane"},
                     "timeIndex": {"type": "integer", "minimum": 0}, "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                     "labelIds": {"type": "array", "minItems": 1, "maxItems": 1000, "items": {"type": "integer", "minimum": 1, "maximum": 4294967295}},
                     "includeContours": {"type": "boolean", "default": True}}, ["imageId", "labelIds"])),
        _op("mask.pick", "Pick the authoritative label at a source pixel/voxel edge coordinate; never infer it from contours.",
            _object({"imageId": _ID, "target": {"type": "string", "enum": ["plane", "volume"], "default": "plane"},
                     "timeIndex": {"type": "integer", "minimum": 0}, "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                     "x": {"type": "number", "minimum": 0}, "y": {"type": "number", "minimum": 0}, "z": {"type": "number", "minimum": 0}}, ["imageId", "x", "y"])),
        _op("mask.overlay", "Render the complete exact saved label raster as a transparent bounded overlay, independently of paged tables.",
            _object({"imageId": _ID, "target": {"type": "string", "enum": ["plane", "volume"], "default": "plane"},
                     "timeIndex": {"type": "integer", "minimum": 0}, "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                     "plane": {"type": "string", "enum": ["xy", "xz", "yz"], "default": "xy"}, "index": {"type": "integer", "minimum": 0},
                     "maxSize": {"type": "integer", "minimum": 16, "maximum": 2048, "default": 768}}, ["imageId"])),
        _op("project.storage.inspect", "Read storage format, record counts and supported paging limits.", _object()),
        _op("project.storage.upgrade.preview", "Describe a format1 to indexed-format2 migration without changing data.", _object()),
        _op("project.storage.upgrade.run", "Upgrade the exact preview, preserving a local copy of the original SQLite store and all scientific records.",
            _object({"previewFingerprint": _ID}, ["previewFingerprint"]), True),
    ]


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def _page_state(document, operation, args):
    filters = {key: value for key, value in args.items() if key not in ("cursor", "limit")}
    identity = _digest({"projectId": document["id"], "revision": document["revision"], "operation": operation, "filters": filters})
    offset = 0
    if args.get("cursor"):
        try:
            value = json.loads(base64.urlsafe_b64decode(args["cursor"].encode()).decode())
        except (ValueError, UnicodeError):
            fail("invalid-cursor", "The page cursor is malformed.")
        if not isinstance(value, dict) or value.get("identity") != identity:
            fail("snapshot-changed", "The project revision or page filters changed. Refresh the snapshot and begin this page sequence again.", {"sourceRevision": document["revision"]})
        offset = value.get("offset")
        if type(offset) is not int or offset < 0: fail("invalid-cursor", "The page cursor has an invalid offset.")
    return identity, offset


def _cursor(identity, offset, total):
    if offset >= total: return None
    return base64.urlsafe_b64encode(json.dumps({"identity": identity, "offset": offset}, separators=(",", ":")).encode()).decode()


def storage(document):
    from _workbench_indexed import IndexedDocument, MAX_IMAGES
    result = {"format": document.get("storageFormat", 1), "imageCount": len(document["images"]), "historyCount": len(document["history"]),
              "limits": {"images": MAX_IMAGES if isinstance(document, IndexedDocument) else 1000, "imagePage": 500,
                         "measurementPage": 1000, "selectedSnapshotImages": 32, "responseBytes": 24 * 1024 ** 2},
              "upgradeAvailable": document.get("storageFormat", 1) == 1}
    if isinstance(document, IndexedDocument):
        row = document.view.query("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM records").fetchone()
        result.update({"recordCount": row[0], "recordBytes": row[1]})
    if document.get("storageMigration"):
        result["migration"] = copy.deepcopy(document["storageMigration"])
    return result


def _images_page(document, args, *, offset_override=None):
    from _workbench_indexed import RecordList
    from _workbench_library import metadata, _collection
    identity, offset = _page_state(document, "image.list", args)
    if offset_override is not None: offset = offset_override
    limit, scope = args.get("limit", 100), args.get("archiveScope", "active")
    rows = document["images"]
    if isinstance(rows, RecordList):
        predicates, values = [], []
        if scope != "all": predicates.append("i.archived=?"); values.append(int(scope == "archived"))
        if args.get("sourceHash"):
            predicates.append("i.source_hash=?"); values.append(args["sourceHash"])
        if args.get("analysisTarget"):
            predicates.append("i.has_plane=1" if args["analysisTarget"] == "plane" else "i.has_volume=1")
        if "referenceCurrent" in args:
            predicates.append("i.reference_current=?"); values.append(int(args["referenceCurrent"]))
        if args.get("query", "").strip():
            predicates.append("instr(i.search_text,?)>0"); values.append(args["query"].strip().casefold())
        for tag in sorted({tag.strip().casefold() for tag in args.get("tags", [])}):
            predicates.append("EXISTS(SELECT 1 FROM image_tags t WHERE t.image_id=i.image_id AND t.tag=?)"); values.append(tag)
        if "collectionId" in args:
            _collection(document, args["collectionId"])
            predicates.append("EXISTS(SELECT 1 FROM collection_images c WHERE c.image_id=i.image_id AND c.collection_id=?)"); values.append(args["collectionId"])
        where = " WHERE " + " AND ".join(predicates) if predicates else ""
        total = rows.view.query("SELECT COUNT(*) FROM image_index i" + where, values).fetchone()[0]
        selected = [rows.find(row[0]) for row in rows.view.query("SELECT i.image_id FROM image_index i" + where + " ORDER BY i.ordinal LIMIT ? OFFSET ?", [*values, limit, offset])]
    else:
        required = {tag.strip().casefold() for tag in args.get("tags", [])}
        allowed = set(_collection(document, args["collectionId"])["imageIds"]) if "collectionId" in args else None
        selected, total = [], 0
        for image in rows:
            value = metadata(image)
            if args.get("sourceHash") and image["sourceHash"] != args["sourceHash"]: continue
            if args.get("analysisTarget") == "plane" and not image.get("analysis"): continue
            if args.get("analysisTarget") == "volume" and not image.get("volumeFrames"): continue
            if "referenceCurrent" in args:
                from _workbench_adaptation import _reference_current
                if bool(_reference_current(image)) != args["referenceCurrent"]: continue
            if scope != "all" and value["archived"] != (scope == "archived"): continue
            if allowed is not None and image["id"] not in allowed: continue
            if not required.issubset({tag.casefold() for tag in value["tags"]}): continue
            if args.get("query", "").strip().casefold() not in "\n".join([value["name"], value["notes"], *value["tags"], *value["channelNames"]]).casefold(): continue
            if offset <= total < offset + limit: selected.append(image)
            total += 1
    return selected, total, _cursor(identity, offset + len(selected), total)


def _upgrade_preview(document):
    from _workbench_store import canonical
    if document.get("storageFormat", 1) != 1:
        fail("storage-already-indexed", "This project already uses indexed storage.")
    source_hash = hashlib.sha256(canonical(document).encode()).hexdigest()
    cells = sum(len(analysis.get("cells", [])) for image in document["images"]
                for analysis in ([image["analysis"]] if image.get("analysis") else []) + image.get("volumeFrames", []))
    plan = {"fromFormat": 1, "toFormat": 2, "imageCount": len(document["images"]), "historyCount": len(document["history"]),
            "measurementRows": cells, "sourceStateHash": source_hash, "sourceRevision": document["revision"],
            "notes": ["The original SQLite store is copied into a local recovery directory before the atomic metadata migration.",
                      "Exact sources, labels, histories and request receipts remain available. No scientific measurements are recalculated.",
                      "The local recovery database may contain session/request metadata and is not included in portable scientific packages."]}
    return {"plan": plan, "previewFingerprint": _digest(plan)}


def execute(store, document, operation, args, revision, actor):
    from _workbench_core import _inspection, _image, _image_inspection, _current_analysis
    from _workbench_indexed import CellRows
    if operation == "project.snapshot":
        from _workbench_catalogues import snapshot
        return snapshot(store, document, args)
    if operation == "project.storage.inspect": return {"storage": storage(document)}
    if operation.startswith("project.storage.upgrade."):
        preview = _upgrade_preview(document)
        if operation.endswith("preview"): return preview
        if args["previewFingerprint"] != preview["previewFingerprint"]:
            fail("storage-upgrade-preview-changed", "The project changed. Preview the upgrade again.")
        from _workbench_store import file_hash, sync_directory, utc_now
        directory = store.root / ".storage-recovery"
        if directory.is_symlink(): fail("unsafe-recovery-path", "The storage recovery directory must not be a symbolic link.")
        directory.mkdir(exist_ok=True)
        destination = directory / ("format1-r" + str(document["revision"]) + ".sqlite")
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, prefix=".backup-", delete=False) as stream: temporary = Path(stream.name)
            source = store.connection(); target = sqlite3.connect(str(temporary))
            try:
                source.execute("BEGIN")
                actual = source.execute("SELECT revision FROM state WHERE id=1").fetchone()[0]
                if actual != document["revision"]: fail("revision-conflict", "Project changed before its recovery snapshot was frozen.")
                source.backup(target)
            finally: target.close(); source.close()
            checksum = file_hash(temporary)
            try: os.link(str(temporary), str(destination))
            except FileExistsError:
                if destination.is_symlink() or file_hash(destination) != checksum:
                    fail("storage-recovery-exists", "A different original-store recovery file exists. Preserve or move it before retrying this upgrade.")
            sync_directory(directory)
        finally:
            if temporary is not None: temporary.unlink(missing_ok=True)
        document["storageFormat"] = 2
        document["storageMigration"] = {"fromFormat": 1, "sourceRevision": document["revision"], "sourceStateHash": preview["plan"]["sourceStateHash"],
                                        "recoveryRelativePath": str(destination.relative_to(store.root)), "recoverySha256": checksum,
                                        "recoveryScope": "host-local-original-store", "at": utc_now(), "actor": copy.deepcopy(actor)}
        return {"storage": {"format": 2, "imageCount": len(document["images"]), "historyCount": len(document["history"]) + 1},
                "migration": copy.deepcopy(document["storageMigration"]), "recoveryPath": str(destination)}
    if operation == "image.get": return {"image": _image_inspection(document, _image(document, args["imageId"]))}
    if operation == "image.list":
        images, total, cursor = _images_page(document, args)
        return {"images": [_image_inspection(document, image) for image in images], "total": total,
                "nextCursor": cursor, "sourceRevision": document["revision"]}
    if operation == "project.history":
        identity, offset = _page_state(document, operation, args); limit = args.get("limit", 100)
        total = len(document["history"]); rows = document["history"][offset:offset+limit]
        return {"history": rows, "total": total, "nextCursor": _cursor(identity, offset+len(rows), total), "sourceRevision": document["revision"]}
    if operation in ("mask.pick", "mask.overlay"):
        return _mask_read(store, document, operation, args)
    if operation in ("measurements.page", "measurements.lookup"):
        image = _image(document, args["imageId"]); target = args.get("target", "plane")
        if target == "plane":
            if "timeIndex" in args or "channel" in args: fail("invalid-selection", "Plane measurements use their saved channel/projection; omit timeIndex/channel.")
            analysis = _current_analysis(store, image, verify_files=False)
            selection = {"target": "plane", **{key: analysis["parameters"][key] for key in ("channel", "zProjection")}}
        else:
            import _workbench_volume as volume
            selection = {"target": "volume", "timeIndex": args.get("timeIndex", 0), "channel": args.get("channel", 0)}
            analysis = volume.current_frame(store, image, selection["timeIndex"], selection["channel"], verify=False)
        if operation == "measurements.lookup":
            ids = args["labelIds"]
            if len(ids) != len(set(ids)): fail("invalid-selection", "Label IDs must be distinct.")
            rows = _lookup(store, analysis, ids, args.get("includeContours", True))
            found = {row["labelId"] for row in rows}
            return {"imageId": image["id"], "target": target, "selection": selection, "total": len(analysis["cells"]), "cells": rows,
                    "requestedLabelIds": ids, "missingLabelIds": [identifier for identifier in ids if identifier not in found],
                    "analysisRevision": analysis["analysisRevision"], "measurementRevision": analysis["measurementRevision"],
                    "sourceRevision": document["revision"], "coordinateSpace": "voxel-edges" if target == "volume" else "pixel-edges",
                    "intensityUnits": "processed-source" if image.get("derivation") else "raw-source"}
        identity, offset = _page_state(document, operation, args); limit = args.get("limit", 200)
        cells = analysis["cells"]; total = len(cells)
        if isinstance(cells, CellRows):
            store.verify_artifact(cells.reference["path"], cells.reference["hash"])
            rows = cells.page(offset, limit, args.get("includeContours", False))
        else:
            rows = copy.deepcopy(cells[offset:offset+limit])
            if not args.get("includeContours", False):
                for row in rows:
                    for key in ("contourPx", "contoursPx", "surface", "mesh"): row.pop(key, None)
        return {"imageId": image["id"], "target": target, "selection": selection, "total": total, "cells": rows,
                "nextCursor": _cursor(identity, offset+len(rows), total), "analysisRevision": analysis["analysisRevision"],
                "measurementRevision": analysis["measurementRevision"], "sourceRevision": document["revision"],
                "coordinateSpace": "voxel-edges" if target == "volume" else "pixel-edges",
                "intensityUnits": "processed-source" if image.get("derivation") else "raw-source"}
    fail("unknown-operation", "Unknown paged project operation.")


def _lookup(store, analysis, ids, contours=True):
    from _workbench_indexed import CellRows
    cells = analysis['cells']
    if isinstance(cells, CellRows):
        store.verify_artifact(cells.reference['path'], cells.reference['hash'])
        connection = cells._connection()
        try:
            found = {}
            for start in range(0, len(ids), 400):
                selected = ids[start:start+400]
                for label, raw in connection.execute('SELECT label_id,value FROM cells WHERE label_id IN (' + ','.join('?' for _ in selected) + ')', selected):
                    found[label] = json.loads(raw)
        finally: connection.close()
    else:
        selected = set(ids); found = {cell['labelId']: copy.deepcopy(cell) for cell in cells if cell['labelId'] in selected}
    result = [found[identifier] for identifier in ids if identifier in found]
    if not contours:
        for row in result:
            for key in ('contourPx', 'contoursPx', 'surface', 'mesh'): row.pop(key, None)
    return result


def _mask_read(store, document, operation, args):
    from _workbench_core import _image, _current_analysis, _labels
    import _workbench_volume as volume
    import math
    image = _image(document, args['imageId']); target = args.get('target', 'plane')
    if target == 'plane':
        if any(key in args for key in ('timeIndex', 'channel', 'z')): fail('invalid-selection', 'Plane masks use their saved channel/projection; omit volume coordinates.')
        analysis = _current_analysis(store, image, verify_files=False); labels = _labels(store, image, analysis)
        selection = {'target': target, **{key: analysis['parameters'][key] for key in ('channel', 'zProjection')}}
    else:
        selection = {'target': target, 'timeIndex': args.get('timeIndex', 0), 'channel': args.get('channel', 0)}
        analysis = volume.current_frame(store, image, selection['timeIndex'], selection['channel'], verify=False)
        labels = volume.read_labels(store, image, analysis)
    common = {'imageId': image['id'], 'target': target, 'selection': selection, 'analysisRevision': analysis['analysisRevision'],
              'sourceRevision': document['revision'], 'labelsHash': analysis['labelsHash']}
    if operation == 'mask.pick':
        x, y = math.floor(args['x']), math.floor(args['y']); z = math.floor(args.get('z', 0))
        if x >= labels.shape[-1] or y >= labels.shape[-2] or target == 'volume' and z >= labels.shape[0]:
            fail('coordinate-out-of-bounds', 'The pick lies outside the exact saved source grid.')
        label = int(labels[z, y, x] if target == 'volume' else labels[y, x])
        cells = _lookup(store, analysis, [label], True) if label else []
        return {**common, 'labelId': label, 'cell': cells[0] if cells else None,
                'position': {'x': x, 'y': y, **({'z': z} if target == 'volume' else {})}}
    if target == 'volume':
        plane = args.get('plane', 'xy'); axis = {'xy': 0, 'xz': 1, 'yz': 2}[plane]
        index = args.get('index', labels.shape[axis] // 2)
        if index >= labels.shape[axis]: fail('coordinate-out-of-bounds', 'The saved-mask slice index is outside its source grid.')
        selection.update({'plane': plane, 'index': index})
        common.update({'plane': plane, 'index': index, 'sliceCount': labels.shape[axis]})
        labels = labels[index] if plane == 'xy' else labels[:, index, :] if plane == 'xz' else labels[:, :, index]
    import numpy as np
    from PIL import Image
    import base64, io
    height, width = labels.shape
    maximum = args.get('maxSize', 768); scale = min(1.0, maximum / max(width, height))
    out_width, out_height = max(1, round(width*scale)), max(1, round(height*scale))
    # Nearest source-label sampling preserves label categories for display.
    # Exact click ownership always comes from mask.pick at source coordinates.
    xs = np.minimum(width-1, np.floor((np.arange(out_width)+0.5)*width/out_width).astype(int))
    ys = np.minimum(height-1, np.floor((np.arange(out_height)+0.5)*height/out_height).astype(int))
    sampled = labels[np.ix_(ys, xs)]
    rgba = np.zeros((out_height, out_width, 4), dtype=np.uint8)
    rgba[sampled > 0] = (63, 220, 190, 88)
    boundary = sampled > 0
    interior = np.zeros(sampled.shape, dtype=bool)
    interior[1:-1,1:-1] = (sampled[1:-1,1:-1] == sampled[:-2,1:-1]) & (sampled[1:-1,1:-1] == sampled[2:,1:-1]) & (sampled[1:-1,1:-1] == sampled[1:-1,:-2]) & (sampled[1:-1,1:-1] == sampled[1:-1,2:])
    rgba[boundary & ~interior] = (63, 220, 190, 230)
    stream = io.BytesIO(); Image.fromarray(rgba, 'RGBA').save(stream, format='PNG')
    return {**common, 'maskDataUrl': 'data:image/png;base64,' + base64.b64encode(stream.getvalue()).decode(),
            'width': width, 'height': height, 'previewWidth': out_width, 'previewHeight': out_height,
            'coordinateSpace': 'source-pixel-edges', 'resampling': 'nearest-display-only', 'completeMask': True}
