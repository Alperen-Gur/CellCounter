"""Canonical library metadata and identity-preserving source repair."""
from __future__ import annotations

from _workbench_indexed import image_index

import copy
import hashlib
import os
from pathlib import Path
import tempfile
import uuid

MAX_COLLECTIONS = 200
MAX_REPAIRS = 1000


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    name = {"type": "string", "minLength": 1, "maxLength": 200}
    tags = {"type": "array", "maxItems": 64, "items": {"type": "string", "minLength": 1, "maxLength": 80}}
    images = {"type": "array", "minItems": 1, "maxItems": 1000, "items": _ID}
    return [
        _op("image.metadata.get", "Read acquisition names, indexed channel names, notes, tags and reversible archive state.", _object({"imageId": _ID}, ["imageId"])),
        _op("image.metadata.set", "Update descriptive metadata without changing pixels, masks, calibration or experimental assignments.",
            _object({"imageId": _ID, "name": name, "notes": {"type": "string", "minLength": 0, "maxLength": 10000}, "tags": tags,
                     "channelNames": {"type": "array", "minItems": 1, "maxItems": 32, "items": name}}, ["imageId"]), True),
        _op("library.search", "Search acquisition metadata and collections with explicit archive scope and bounded paging.",
            _object({"query": {"type": "string", "minLength": 0, "maxLength": 1000}, "tags": tags, "collectionId": _ID,
                     "archiveScope": {"type": "string", "enum": ["active", "all", "archived"], "default": "active"},
                     "offset": {"type": "integer", "minimum": 0, "default": 0},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 100}})),
        _op("library.duplicates", "Find exact retained source-byte duplicates without merging acquisitions or biological replicates.",
            _object({"includeArchived": {"type": "boolean", "default": False}})),
        _op("collection.save", "Create or edit a named acquisition collection; membership does not imply biological replication.",
            _object({"collectionId": _ID, "name": name, "description": {"type": "string", "minLength": 0, "maxLength": 2000},
                     "imageIds": {**images, "minItems": 0}}, ["name"]), True),
        _op("collection.list", "Read collection membership, optionally including archived collections.", _object({"includeArchived": {"type": "boolean", "default": False}})),
        _op("collection.archive", "Archive or restore a collection without removing its images or scientific assignments.",
            _object({"collectionId": _ID, "archived": {"type": "boolean"}}, ["collectionId", "archived"]), True),
        _op("image.archive", "Archive or restore acquisition visibility; preserve source bytes, masks, assignments and all history.",
            _object({"imageIds": images, "archived": {"type": "boolean"}}, ["imageIds", "archived"]), True),
        _op("image.relink.preview", "Compare a candidate file with the exact retained source identity and inspect missing or corrupt bytes.",
            _object({"imageId": _ID, "path": _STRING}, ["imageId", "path"])),
        _op("image.relink.run", "Restore only the original source bytes from a previewed file, retaining displaced corrupt evidence.",
            _object({"imageId": _ID, "path": _STRING, "previewFingerprint": _ID}, ["imageId", "path", "previewFingerprint"]), True),
    ]


def metadata(image):
    return {**{key: image[key] for key in ("id", "name", "sourceHash", "width", "height", "channels")},
            "notes": image.get("notes", ""), "tags": copy.deepcopy(image.get("tags", [])),
            "channelNames": copy.deepcopy(image.get("channelNames", [f"Channel {index + 1}" for index in range(image["channels"])])),
            "archived": image.get("archived", False), "metadataRevision": image.get("metadataRevision", 0)}


def collections(document, include_archived=True):
    return [copy.deepcopy(item) for item in document.get("collections", []) if include_archived or not item["archived"]]


def _collection(document, identity):
    value = next((item for item in document.get("collections", []) if item["id"] == identity), None)
    if value is None:
        fail("collection-not-found", "The selected collection is unavailable.")
    return value


def _images(document, ids):
    if len(ids) != len(set(ids)):
        fail("duplicate-image-selection", "Select each acquisition identity once.")
    mapping = image_index(document)
    if any(identity not in mapping for identity in ids):
        fail("image-not-found", "A selected acquisition is unavailable.")
    return [mapping[identity] for identity in ids]


def execute(store, document, operation, args, revision):
    from _workbench_store import utc_now
    if operation == "library.search":
        from _workbench_pages import _images_page
        images, total, _ = _images_page(document, args, offset_override=args.get("offset", 0))
        offset, limit = args.get("offset", 0), args.get("limit", 100)
        return {"images": [metadata(image) for image in images], "total": total, "offset": offset,
                "nextOffset": offset + limit if offset + limit < total else None, "archiveScope": args.get("archiveScope", "active")}
    if operation == "library.duplicates":
        groups = {}
        for image in document["images"]:
            if image.get("archived", False) and not args.get("includeArchived", False):
                continue
            groups.setdefault(image["sourceHash"], []).append(image)
        return {"groups": [{"sourceHash": checksum, "imageIds": [image["id"] for image in images],
                            "names": [image["name"] for image in images], "bytes": images[0]["sourceBytes"]}
                           for checksum, images in groups.items() if len(images) > 1],
                "notes": ["Groups compare exact retained file bytes, not decoded-pixel similarity or biological equivalence.",
                          "Distinct acquisitions, blank controls and analysis variants retain independent identities and assignments; nothing is merged."]}
    if operation == "collection.list":
        return {"collections": collections(document, args.get("includeArchived", False))}
    if operation.startswith("collection."):
        if "collectionId" in args:
            value = _collection(document, args["collectionId"])
        else:
            if len(document.get("collections", [])) >= MAX_COLLECTIONS:
                fail("collection-limit", "The project supports at most 200 collections, including archived collections.")
            value = {"id": str(uuid.uuid4()), "name": args["name"], "description": "", "imageIds": [], "archived": False}
            document.setdefault("collections", []).append(value)
        if operation == "collection.archive":
            value["archived"] = args["archived"]
        else:
            if "imageIds" in args:
                _images(document, args["imageIds"])
            value.update({key: copy.deepcopy(args[key]) for key in ("name", "description", "imageIds") if key in args})
        value.update({"updatedAt": utc_now(), "updatedRevision": revision})
        return {"collection": copy.deepcopy(value)}
    if operation == "image.archive":
        images = _images(document, args["imageIds"])
        for image in images:
            image.update({"archived": args["archived"], "metadataRevision": revision})
        return {"images": [metadata(image) for image in images]}
    image = _images(document, [args["imageId"]])[0]
    if operation == "image.relink.preview":
        return {"preview": preview_relink(store, document, image, args["path"])}
    if operation == "image.metadata.set":
        if len(args) == 1:
            fail("metadata-empty", "Provide at least one descriptive metadata field to update.")
        if "channelNames" in args and len(args["channelNames"]) != image["channels"]:
            fail("channel-name-count", "Provide one explicit name for each indexed source channel.", {"channels": image["channels"]})
        if "tags" in args:
            tags = [tag.strip() for tag in args["tags"]]
            if len(set(tag.casefold() for tag in tags)) != len(tags):
                fail("duplicate-tags", "Tags must be distinct when compared without case.")
            image["tags"] = tags
        image.update({key: copy.deepcopy(args[key]) for key in ("name", "notes", "channelNames") if key in args})
        image["metadataRevision"] = revision
    return {"image": metadata(image)}


def _source_file(path):
    from _workbench_schema import absolute_path
    from _workbench_store import MAX_SOURCE_BYTES
    source = absolute_path(path, "path")
    if not source.is_file() or source.stat().st_size > MAX_SOURCE_BYTES:
        fail("invalid-relink-source", "Choose a regular original source file of at most 512 MiB.")
    return source


def _destination(store, image):
    from _workbench_store import MAX_SOURCE_BYTES
    relative = image["sourcePath"]
    if not relative.startswith("artifacts/" + image["sourceHash"] + ".") or "/" in relative[len("artifacts/"):]:
        fail("invalid-artifact", "The saved source path is not an immutable hash-named artifact.")
    directory = store.root / "artifacts"
    path = store.root / relative
    if directory.is_symlink() or directory.resolve().parent != store.root or path.is_symlink():
        fail("invalid-artifact", "Restore source files only inside the project's real artifact directory.")
    if path.exists() and (not path.is_file() or path.stat().st_size > MAX_SOURCE_BYTES):
        fail("repair-evidence-limit", "The displaced source must be a regular file no larger than 512 MiB so all evidence can be preserved.")
    return path


def preview_relink(store, document, image, path):
    from _workbench_store import canonical, file_hash
    source = _source_file(path)
    candidate = file_hash(source)
    target = _destination(store, image)
    current_hash = file_hash(target) if target.exists() else None
    status = "missing" if current_hash is None else "intact" if current_hash == image["sourceHash"] else "corrupt"
    body = {"imageId": image["id"], "sourceHash": image["sourceHash"], "candidateHash": candidate,
            "identityMatches": candidate == image["sourceHash"], "currentArtifactStatus": status,
            "bytes": source.stat().st_size, "sourceRevision": document["revision"], "candidatePath": str(source),
            **({"displacedHash": current_hash} if status == "corrupt" else {})}
    return {**body, "previewFingerprint": hashlib.sha256(canonical(body).encode()).hexdigest(),
            "notes": ["Only the original retained source bytes may repair this acquisition. Different bytes require a new acquisition identity.",
                      "Calibration, labels, assignments and historical outputs remain tied to the same source hash.",
                      "Corrupt displaced bytes are retained as evidence; archive visibility never deletes source data."]}


def prepare_relink(store, document, args, revision, request_id, actor):
    from _workbench_store import file_hash, utc_now, sync_directory, MAX_SOURCE_BYTES
    image = _images(document, [args["imageId"]])[0]
    report = preview_relink(store, document, image, args["path"])
    if report["previewFingerprint"] != args["previewFingerprint"]:
        fail("relink-preview-changed", "The project, candidate or retained source changed. Preview this repair again.")
    if not report["identityMatches"]:
        fail("source-identity-mismatch", "These bytes are not the original source. Import them as a new acquisition; saved masks cannot be silently transferred.")
    if len(document.get("sourceRepairs", [])) >= MAX_REPAIRS or len(image.get("sourceLocations", [])) >= 100:
        fail("repair-history-limit", "The project source-repair or location history is full; preserve a package before reorganizing.")
    source = _source_file(args["path"])
    destination = _destination(store, image)
    record = {"id": str(uuid.uuid4()), "imageId": image["id"], "sourceHash": image["sourceHash"],
              "candidatePath": str(source), "createdAt": utc_now(), "createdRevision": revision,
              "actor": copy.deepcopy(actor), "requestId": request_id,
              "status": "already-intact" if report["currentArtifactStatus"] == "intact" else "restored"}
    if report.get("displacedHash"):
        reference = "artifacts/" + report["displacedHash"] + ".repair-evidence.bin"
        store.retain_verified_file(destination, reference, report["displacedHash"])
        record.update({"displacedHash": report["displacedHash"], "displacedPath": reference})
    image.setdefault("sourceLocations", []).append({"path": str(source), "sourceHash": image["sourceHash"], "recordedAt": record["createdAt"], "revision": revision})
    image["sourceArtifactGeneration"] = image.get("sourceArtifactGeneration", 0) + (record["status"] == "restored")
    document.setdefault("sourceRepairs", []).append(record)
    result = {"image": metadata(image), "repair": {key: record[key] for key in ("id", "status", "sourceHash", "displacedHash") if key in record}}
    if record["status"] == "already-intact":
        return result, None, None, None
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".source-repair-", delete=False) as output:
            temporary = Path(output.name)
            checksum, size = hashlib.sha256(), 0
            with source.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    size += len(block)
                    if size > MAX_SOURCE_BYTES:
                        fail("invalid-relink-source", "The candidate grew beyond its source bound during repair preparation.")
                    checksum.update(block)
                    output.write(block)
            output.flush()
            os.fsync(output.fileno())
        if checksum.hexdigest() != image["sourceHash"]:
            fail("source-identity-mismatch", "The candidate changed during repair preparation. No source bytes were replaced.")
        expected_current = report.get("displacedHash")
        def publish():
            target = _destination(store, image)
            observed = file_hash(target) if target.exists() else None
            if observed != expected_current:
                fail("repair-target-changed", "The source artifact changed before repair publication. Preview it again.")
            os.replace(temporary, target)
            sync_directory(target.parent)
            return None
        publication = {"kind": "artifact-repair", "destination": str(destination), "sha256": image["sourceHash"], "previousHash": expected_current}
        return result, publish, temporary, publication
    except Exception:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise


def artifact_references(document):
    return {record["displacedPath"]: record["displacedHash"] for record in document.get("sourceRepairs", []) if record.get("displacedPath")}


def validate_document(document):
    from _workbench_schema import validate_value
    schema = {entry["name"]: entry["inputSchema"] for entry in operations()}
    image_ids = {image["id"] for image in document["images"]}
    for image in document["images"]:
        supplied = {"imageId": image["id"], **{key: image[key] for key in ("notes", "tags", "channelNames") if key in image}}
        validate_value(supplied, schema["image.metadata.set"])
        if "channelNames" in image and len(image["channelNames"]) != image["channels"]:
            fail("invalid-package", "Retained channel names do not match the source channel count.")
        if type(image.get("archived", False)) is not bool:
            fail("invalid-package", "Image archive state must be a boolean.")
    if len(document.get("collections", [])) > MAX_COLLECTIONS or len(document.get("sourceRepairs", [])) > MAX_REPAIRS:
        fail("invalid-package", "Retained library metadata exceeds its project bounds.")
    identities = set()
    for collection in document.get("collections", []):
        if collection["id"] in identities or any(identity not in image_ids for identity in collection["imageIds"]):
            fail("invalid-package", "Collection identity or acquisition membership is invalid.")
        identities.add(collection["id"])
        validate_value({key: collection[key] for key in ("name", "description", "imageIds")}, schema["collection.save"])
        if type(collection["archived"]) is not bool:
            fail("invalid-package", "Collection archive state must be a boolean.")
