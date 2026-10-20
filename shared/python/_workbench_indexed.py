"""Revision-bound compatibility views over normalized project records.

Only touched rows enter a commit delta. Numerical engines continue to receive
mapping/sequence interfaces; image measurements are immutable indexed artifacts.
"""
from __future__ import annotations

from collections import OrderedDict
from collections.abc import MutableSequence, Mapping, Sequence
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import uuid
import weakref
import threading
import contextvars

FORMAT = 2
MAX_IMAGES = 100000
MAX_RECORD_BYTES = 32 * 1024 ** 2
MAX_DELTA_BYTES = 64 * 1024 ** 2
MAX_COLLECTION_RECORDS = 1000000
CACHE_RECORDS = 64
NESTED_COLLECTIONS = {"experimentalDesign": {"specimens": "experimentSpecimens", "plates": "experimentPlates", "assignments": "experimentAssignments"}}
_OPEN = weakref.WeakSet()
_VIEW_SCOPE = contextvars.ContextVar("workbench_read_scope", default=None)


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False, default=json_default)


def json_default(value):
    if isinstance(value, CellRows):
        return list(value)
    if isinstance(value, (RecordList, CombinedRows)):
        if len(value) > 1000:
            fail("paged-read-required", "Use project.snapshot and paged collection operations for this indexed project.")
        return list(value)
    raise TypeError("Unsupported JSON value: " + type(value).__name__)


def begin_view_scope():
    return _VIEW_SCOPE.set(object())


def close_views(token=None):
    scope = _VIEW_SCOPE.get()
    for view in list(_OPEN):
        if view.owner_thread == threading.get_ident() and (token is None or view.scope is scope):
            view.close()
    if token is not None: _VIEW_SCOPE.reset(token)


class ReadView:
    def __init__(self, store, connection):
        self.store, self.connection = store, connection
        self.closed = False
        self.owner_thread = threading.get_ident()
        self.scope = _VIEW_SCOPE.get()
        _OPEN.add(self)

    def close(self):
        if not self.closed:
            self.connection.close(); self.closed = True
            cleanup = getattr(self, "cleanup", None)
            if cleanup is not None: cleanup()

    def __del__(self):
        try: self.close()
        except Exception: pass

    def query(self, sql, args=()):
        if self.closed:
            fail("snapshot-closed", "The request snapshot has closed; issue a new canonical read.")
        return self.connection.execute(sql, args)


def _tracked(value, changed):
    if isinstance(value, CellRows): return value
    if isinstance(value, dict): return TrackedDict(value, changed)
    if isinstance(value, list): return TrackedList(value, changed)
    return value


class TrackedDict(dict):
    def __init__(self, value, changed):
        self._changed = changed
        dict.__init__(self, ((key, _tracked(item, changed)) for key, item in value.items()))

    def __setitem__(self, key, value):
        dict.__setitem__(self, key, _tracked(value, self._changed)); self._changed()

    def __delitem__(self, key):
        dict.__delitem__(self, key); self._changed()

    def pop(self, key, *default):
        if key in self: self._changed()
        return dict.pop(self, key, *default)

    def popitem(self):
        result = dict.popitem(self); self._changed(); return result

    def clear(self):
        dict.clear(self); self._changed()

    def update(self, *args, **kwargs):
        for key, value in dict(*args, **kwargs).items(): self[key] = value

    def setdefault(self, key, default=None):
        if key not in self: self[key] = default
        return self[key]

    def __deepcopy__(self, memo):
        return {key: copy.deepcopy(value, memo) for key, value in self.items()}


class TrackedList(list):
    def __init__(self, value, changed):
        self._changed = changed
        list.__init__(self, (_tracked(item, changed) for item in value))

    def __setitem__(self, key, value):
        list.__setitem__(self, key, [_tracked(item, self._changed) for item in value] if isinstance(key, slice) else _tracked(value, self._changed)); self._changed()

    def __delitem__(self, key): list.__delitem__(self, key); self._changed()
    def append(self, value): list.append(self, _tracked(value, self._changed)); self._changed()
    def extend(self, values):
        for value in values: self.append(value)
    def insert(self, index, value): list.insert(self, index, _tracked(value, self._changed)); self._changed()
    def pop(self, index=-1):
        value = list.pop(self, index); self._changed(); return value
    def clear(self): list.clear(self); self._changed()
    def remove(self, value): list.remove(self, value); self._changed()
    def reverse(self): list.reverse(self); self._changed()
    def sort(self, *args, **kwargs): list.sort(self, *args, **kwargs); self._changed()
    def __iadd__(self, values): self.extend(values); return self
    def __imul__(self, count): list.__imul__(self, count); self._changed(); return self
    def __deepcopy__(self, memo): return [copy.deepcopy(item, memo) for item in self]


class CellRows(Sequence):
    """Immutable per-analysis rows; len and pages do not hydrate every object."""
    def __init__(self, store, reference):
        self.store, self.reference = store, copy.deepcopy(reference)

    def __eq__(self, other):
        if isinstance(other, CellRows) and self.reference == other.reference: return True
        return isinstance(other, Sequence) and len(self) == len(other) and all(left == right for left, right in zip(self, other))

    def __len__(self): return self.reference["count"]
    def __deepcopy__(self, memo): return self

    def _connection(self):
        path = self.store.artifact_path(self.reference["path"])
        connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
        connection.execute("PRAGMA trusted_schema=OFF")
        connection.execute("PRAGMA query_only=ON")
        validate_measurement_schema(connection)
        return connection

    def page(self, offset, limit, include_contours=True):
        connection = self._connection()
        try:
            rows = connection.execute("SELECT value FROM cells WHERE ordinal>=? ORDER BY ordinal LIMIT ?", (offset, limit))
            result = []
            for row in rows:
                value = json.loads(row[0])
                if not include_contours:
                    for key in ("contourPx", "contoursPx", "surface", "mesh"): value.pop(key, None)
                result.append(value)
            return result
        finally: connection.close()

    def __getitem__(self, index):
        if isinstance(index, slice):
            start, stop, step = index.indices(len(self))
            if step == 1: return self.page(start, max(0, stop - start))
            return [self[item] for item in range(start, stop, step)]
        if index < 0: index += len(self)
        if not 0 <= index < len(self): raise IndexError(index)
        values = self.page(index, 1)
        if not values: fail("measurement-table-corrupt", "A retained object row is missing.")
        return values[0]

    def __iter__(self):
        connection = self._connection()
        try:
            for row in connection.execute("SELECT value FROM cells ORDER BY ordinal"):
                yield json.loads(row[0])
        finally: connection.close()


def validate_measurement_schema(connection):
    schema = connection.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").fetchall()
    expected = {"cells", "sqlite_autoindex_cells_1"}
    if any(row[0] not in ("table", "index") or row[1] not in expected or row[2] != "cells" for row in schema):
        fail("invalid-measurement-table", "A measurement artifact contains unsupported SQL objects.")
    columns = connection.execute("PRAGMA table_info(cells)").fetchall()
    if [(row[1], row[2]) for row in columns] != [("ordinal", "INTEGER"), ("label_id", "INTEGER"), ("value", "TEXT")]:
        fail("invalid-measurement-table", "A measurement artifact has an unsupported column layout.")
    table_sql = next((row[3] for row in schema if row[0] == "table"), "")
    if "VIRTUAL" in table_sql.upper() or "GENERATED" in table_sql.upper():
        fail("invalid-measurement-table", "Virtual/generated measurement tables are not accepted.")


def retain_cells(store, cells):
    if isinstance(cells, CellRows): return copy.deepcopy(cells.reference)
    from _workbench_store import file_hash
    if len(cells) > 20000: fail("measurement-limit", "One image/frame supports at most20,000 object measurements.")
    with tempfile.TemporaryDirectory(prefix="cellcounter-measurements-") as directory:
        path = Path(directory) / "measurements.sqlite"
        connection = sqlite3.connect(str(path))
        try:
            connection.execute("CREATE TABLE cells (ordinal INTEGER PRIMARY KEY, label_id INTEGER NOT NULL UNIQUE, value TEXT NOT NULL)")
            with connection:
                connection.executemany("INSERT INTO cells VALUES(?,?,?)", ((index, cell["labelId"], _json(cell)) for index, cell in enumerate(cells)))
        finally: connection.close()
        checksum = file_hash(path); reference = "artifacts/" + checksum + ".measurements.sqlite"
        store.retain_verified_file(path, reference, checksum, maximum_bytes=128 * 1024 ** 2)
        return {"path": reference, "hash": checksum, "count": len(cells), "schemaVersion": 1}


def expand(store, value):
    if isinstance(value, dict):
        result = {key: expand(store, item) for key, item in value.items()}
        if "measurementTable" in result and "cells" not in result:
            result["cells"] = CellRows(store, result["measurementTable"])
        return result
    if isinstance(value, list): return [expand(store, item) for item in value]
    return value


def pack(store, value):
    if isinstance(value, dict):
        result = {key: pack(store, item) for key, item in value.items() if key != "cells" or "labelsHash" not in value}
        if "labelsHash" in value and "cells" in value:
            result["measurementTable"] = retain_cells(store, value["cells"])
        return result
    if isinstance(value, (list, tuple)): return [pack(store, item) for item in value]
    if isinstance(value, CellRows): return list(value)
    return value


class CombinedRows(Sequence):
    def __init__(self, left, right): self.left, self.right = left, right
    def __len__(self): return len(self.left) + len(self.right)
    def __iter__(self):
        yield from self.left
        yield from self.right
    def __getitem__(self, index):
        if isinstance(index, slice): return [self[item] for item in range(*index.indices(len(self)))]
        if index < 0: index += len(self)
        return self.left[index] if index < len(self.left) else self.right[index-len(self.left)]
    def __add__(self, right): return CombinedRows(self, right)
    def __radd__(self, left): return CombinedRows(left, self)
    def __deepcopy__(self, memo): return CombinedRows(copy.deepcopy(self.left, memo), copy.deepcopy(self.right, memo))


class RecordList(MutableSequence):
    def __init__(self, view, collection, *, reset=False):
        self.view, self.collection, self.reset = view, collection, reset
        self.dirty, self.deleted, self.added = {}, set(), OrderedDict()
        self.cache = OrderedDict()
        self.base_count = 0 if reset else view.query("SELECT COUNT(*) FROM records WHERE collection=?", (collection,)).fetchone()[0]
        self.maximum_ordinal = -1 if reset else view.query("SELECT COALESCE(MAX(ordinal),-1) FROM records WHERE collection=?", (collection,)).fetchone()[0]

    def __eq__(self, other):
        if not isinstance(other, Sequence) or len(self) != len(other): return False
        if isinstance(other, RecordList) and self.view is other.view and self.collection == other.collection:
            if self.reset == other.reset and self.deleted == other.deleted and self.added == other.added and self.dirty == other.dirty:
                return True
        return all(left == right for left, right in zip(self, other))

    def __len__(self): return self.base_count - len(self.deleted) + len(self.added)
    def __add__(self, right): return CombinedRows(self, right)
    def __radd__(self, left): return CombinedRows(left, self)

    def _loaded(self, key, ordinal, raw):
        if key in self.dirty: return self.dirty[key][1]
        if key in self.added: return self.added[key][1]
        if key in self.cache:
            self.cache.move_to_end(key); return self.cache[key][1]
        holder = []
        def changed():
            self.dirty[key] = (ordinal, holder[0])
        value = _tracked(expand(self.view.store, json.loads(raw)), changed)
        holder.append(value)
        self.cache[key] = (ordinal, value)
        while len(self.cache) > CACHE_RECORDS:
            self.cache.popitem(last=False)
        return value

    def __iter__(self):
        if not self.reset:
            for key, ordinal, raw in self.view.query("SELECT record_key,ordinal,payload FROM records WHERE collection=? ORDER BY ordinal", (self.collection,)):
                if key not in self.deleted: yield self._loaded(key, ordinal, raw)
        for _, value in list(self.added.values()): yield value

    def _entry(self, index):
        if index < 0: index += len(self)
        if not 0 <= index < len(self): raise IndexError(index)
        if self.deleted:
            for number, value in enumerate(self):
                if number == index:
                    key = next(key for key, (_, item) in list(self.dirty.items()) + list(self.cache.items()) + list(self.added.items()) if item is value)
                    return key, value
        if index >= self.base_count:
            key = list(self.added)[index - self.base_count]
            return key, self.added[key][1]
        row = self.view.query("SELECT record_key,ordinal,payload FROM records WHERE collection=? ORDER BY ordinal LIMIT 1 OFFSET ?", (self.collection, index)).fetchone()
        return row[0], self._loaded(*row)

    def __getitem__(self, index):
        if isinstance(index, slice):
            start, stop, step = index.indices(len(self))
            if self.deleted or step != 1: return [self[item] for item in range(start, stop, step)]
            result = []
            if not self.reset and start < self.base_count:
                for row in self.view.query("SELECT record_key,ordinal,payload FROM records WHERE collection=? ORDER BY ordinal LIMIT ? OFFSET ?", (self.collection, min(stop, self.base_count) - start, start)):
                    result.append(self._loaded(*row))
            if stop > self.base_count: result.extend(value for _, value in list(self.added.values())[max(0, start-self.base_count):stop-self.base_count])
            return result
        return self._entry(index)[1]

    def __delitem__(self, index):
        if isinstance(index, slice):
            for item in reversed(range(*index.indices(len(self)))): del self[item]
            return
        key, _ = self._entry(index)
        if key in self.added: del self.added[key]
        else: self.deleted.add(key)
        self.dirty.pop(key, None); self.cache.pop(key, None)

    def __setitem__(self, index, value):
        if isinstance(index, slice):
            values = list(self); values[index] = value
            self.replace(values); return
        key, _ = self._entry(index)
        ordinal = (self.added.get(key) or self.dirty.get(key) or self.cache.get(key))[0]
        holder = []
        def changed():
            target = self.added if key in self.added else self.dirty
            target[key] = (ordinal, holder[0])
        wrapped = _tracked(value, changed); holder.append(wrapped)
        if key in self.added: self.added[key] = (ordinal, wrapped)
        else: self.dirty[key] = (ordinal, wrapped)

    def append(self, value):
        if len(self) >= (MAX_IMAGES if self.collection == "images" else MAX_COLLECTION_RECORDS):
            fail("indexed-collection-limit", "This indexed collection has reached its supported record bound.")
        key = str(uuid.uuid4()); self.maximum_ordinal += 1
        ordinal = self.maximum_ordinal; holder = []
        def changed(): self.added[key] = (ordinal, holder[0])
        wrapped = _tracked(value, changed); holder.append(wrapped)
        self.added[key] = (ordinal, wrapped)

    def insert(self, index, value):
        if index >= len(self): self.append(value); return
        values = list(self); values.insert(index, value); self.replace(values)

    def replace(self, values):
        if len(values) > 1000:
            fail("bounded-record-write-required", "Replace at most1,000 records per operation; use bounded append/update operations for larger collections.")
        self.reset = True; self.base_count = 0; self.maximum_ordinal = -1
        self.dirty.clear(); self.deleted.clear(); self.added.clear(); self.cache.clear()
        for value in values: self.append(value)

    def find(self, identifier):
        for _, value in [*self.added.values(), *self.dirty.values()]:
            if record_identity(value) == identifier: return value
        if self.reset: return None
        rows = self.view.query("SELECT record_key,ordinal,payload FROM records WHERE collection=? AND entity_id=? ORDER BY ordinal DESC", (self.collection, identifier))
        for row in rows:
            if row[0] not in self.deleted:
                value = self._loaded(*row)
                if record_identity(value) == identifier: return value
        # Older format2 writers indexed only the generic id field. Read their
        # null-indexed identities with trusted JSON selectors until touched.
        selectors = ",".join("json_extract(payload,'$." + key + "')" for key in ("id", "runId", "pluginId", "exportId", "importId", "workerId", "imageId"))
        for row in self.view.query("SELECT record_key,ordinal,payload FROM records WHERE collection=? AND entity_id IS NULL AND COALESCE(" + selectors + ")=? ORDER BY ordinal DESC", (self.collection, identifier)):
            if row[0] not in self.deleted:
                value = self._loaded(*row)
                if record_identity(value) == identifier: return value
        return None

    def remove_identity(self, identifier):
        """Delete a unique entity without locating its position in the list."""
        value = self.find(identifier)
        if value is None: return False
        for source in (self.added, self.dirty, self.cache):
            key = next((key for key, (_, item) in source.items() if item is value), None)
            if key is None: continue
            if key in self.added: del self.added[key]
            else: self.deleted.add(key)
            self.dirty.pop(key, None); self.cache.pop(key, None)
            return True
        fail("indexed-record-unavailable", "The selected record could not be resolved within this revision snapshot.")

    def __deepcopy__(self, memo):
        clone = RecordList.__new__(RecordList)
        clone.view, clone.collection, clone.reset = self.view, self.collection, self.reset
        clone.base_count, clone.maximum_ordinal = self.base_count, self.maximum_ordinal
        clone.dirty, clone.deleted, clone.added, clone.cache = {}, set(self.deleted), OrderedDict(), OrderedDict()
        # Copy only operation deltas. Unchanged retained rows remain immutable
        # in the same SQLite read snapshot and are loaded independently later.
        for source, target in ((self.dirty, clone.dirty), (self.added, clone.added)):
            for key, (ordinal, value) in source.items():
                holder = []
                def changed(key=key, ordinal=ordinal, holder=holder, target=target): target[key] = (ordinal, holder[0])
                wrapped = _tracked(copy.deepcopy(value, memo), changed); holder.append(wrapped)
                target[key] = (ordinal, wrapped)
        return clone


class IndexedDocument(dict):
    def __init__(self, store, connection, header):
        self.view = ReadView(store, connection)
        collections = header.get("_recordCollections", [])
        nested = header.get("_nestedRecords", {})
        dict.__init__(self, {key: value for key, value in header.items() if key not in ("_recordCollections", "_nestedRecords")})
        hidden = {name for mapping in nested.values() for name in mapping.values()}
        for name in collections:
            if name not in hidden: dict.__setitem__(self, name, RecordList(self.view, name))
        for parent, mapping in nested.items():
            design = self.setdefault(parent, {})
            for field, name in mapping.items(): design[field] = RecordList(self.view, name)

    def __deepcopy__(self, memo):
        result = IndexedDocument.__new__(IndexedDocument); result.view = self.view
        dict.__init__(result, {key: copy.deepcopy(value, memo) for key, value in self.items()})
        return result

    def setdefault(self, key, default=None):
        if key not in self:
            if isinstance(default, list):
                record = RecordList(self.view, key, reset=True)
                for value in default: record.append(value)
                dict.__setitem__(self, key, record)
            else: dict.__setitem__(self, key, default)
        return self[key]


class OverlayImageIndex(Mapping):
    def __init__(self, rows):
        self.left = ImageIndex(rows.left) if isinstance(rows.left, RecordList) else OverlayImageIndex(rows.left) if isinstance(rows.left, CombinedRows) else {row['id']: row for row in rows.left}
        self.right = {row['id']: row for row in rows.right}
    def __len__(self): return len(self.left) + sum(key not in self.left for key in self.right)
    def __iter__(self):
        yield from self.left
        yield from (key for key in self.right if key not in self.left)
    def __getitem__(self, key): return self.right[key] if key in self.right else self.left[key]


class ImageIndex(Mapping):
    def __init__(self, rows): self.rows = rows
    def __len__(self): return len(self.rows)
    def __iter__(self):
        if not self.rows.reset:
            for key, identifier in self.rows.view.query("SELECT record_key,entity_id FROM records WHERE collection='images' ORDER BY ordinal"):
                if key not in self.rows.deleted: yield identifier
        for _, value in self.rows.added.values(): yield value["id"]
    def __getitem__(self, identifier):
        value = self.rows.find(identifier)
        if value is None: raise KeyError(identifier)
        return value
    def values(self): return iter(self.rows)
    def items(self): return ((value["id"], value) for value in self.rows)


def image_index(document):
    rows = document["images"]
    return ImageIndex(rows) if isinstance(rows, RecordList) else OverlayImageIndex(rows) if isinstance(rows, CombinedRows) else {row["id"]: row for row in rows}


class RecordIndex(Mapping):
    """Exact identity lookups for unique run/job catalogues without row scans."""
    def __init__(self, rows): self.rows = rows
    def __len__(self): return len(self.rows)
    def __iter__(self):
        for row in self.rows: yield record_identity(row)
    def __getitem__(self, identifier):
        value = self.rows.find(identifier)
        if value is None: raise KeyError(identifier)
        return value


def collection_index(document, collection):
    rows = document.get(collection, [])
    return RecordIndex(rows) if isinstance(rows, RecordList) else {record_identity(row): row for row in rows}


def image_capacity(document): return MAX_IMAGES if document.get("storageFormat") == FORMAT else 1000


def create_tables(connection):
    connection.execute("CREATE TABLE IF NOT EXISTS records (collection TEXT NOT NULL, record_key TEXT NOT NULL, ordinal INTEGER NOT NULL, entity_id TEXT, payload TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY(collection,record_key))")
    connection.execute("CREATE UNIQUE INDEX IF NOT EXISTS records_order ON records(collection,ordinal)")
    connection.execute("CREATE INDEX IF NOT EXISTS records_identity ON records(collection,entity_id)")
    connection.execute("CREATE TABLE IF NOT EXISTS image_index (image_id TEXT PRIMARY KEY, record_key TEXT NOT NULL UNIQUE, ordinal INTEGER NOT NULL, name TEXT NOT NULL, search_text TEXT NOT NULL, source_hash TEXT NOT NULL, archived INTEGER NOT NULL, status TEXT NOT NULL, imported_from TEXT, has_plane INTEGER NOT NULL, has_volume INTEGER NOT NULL, reference_current INTEGER NOT NULL)")
    connection.execute("CREATE INDEX IF NOT EXISTS image_index_scope ON image_index(archived,ordinal)")
    connection.execute("CREATE INDEX IF NOT EXISTS image_index_hash ON image_index(source_hash,imported_from)")
    connection.execute("CREATE TABLE IF NOT EXISTS image_tags (image_id TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY(image_id,tag))")
    connection.execute("CREATE INDEX IF NOT EXISTS image_tags_value ON image_tags(tag,image_id)")
    connection.execute("CREATE TABLE IF NOT EXISTS collection_images (collection_id TEXT NOT NULL,image_id TEXT NOT NULL,PRIMARY KEY(collection_id,image_id))")


def _record(collection, key, ordinal, value, store):
    body = pack(store, value); raw = _json(body); size = len(raw.encode())
    if size > MAX_RECORD_BYTES: fail("indexed-record-limit", "A single retained record exceeds32MiB; use bounded jobs/datasets.")
    return {"collection": collection, "key": key, "ordinal": ordinal, "entityId": record_identity(body), "payload": raw, "bytes": size}


def record_identity(value):
    if not isinstance(value, dict): return None
    return next((value[key] for key in ("id", "runId", "pluginId", "exportId", "importId", "workerId", "imageId") if isinstance(value.get(key), str)), None)


def scientific_collections(document):
    for key, value in document.items():
        if isinstance(value, (list, RecordList)): yield key, value
    for parent, mapping in NESTED_COLLECTIONS.items():
        for field, name in mapping.items():
            value = document.get(parent, {}).get(field)
            if isinstance(value, (list, RecordList)): yield name, value


def scientific_header(document):
    header = {key: value for key, value in document.items() if not isinstance(value, (list, RecordList))}
    nested = {}
    for parent, mapping in NESTED_COLLECTIONS.items():
        if parent not in header: continue
        value = dict(header[parent])
        selected = {field: name for field, name in mapping.items() if isinstance(value.get(field), (list, RecordList))}
        for field in selected: value.pop(field)
        header[parent] = value
        if selected: nested[parent] = selected
    header.update({"storageFormat": FORMAT, "_recordCollections": [name for name, _ in scientific_collections(document)], "_nestedRecords": nested})
    return header


def delta(store, document):
    header, updates, deletes, resets, names = scientific_header(document), [], [], [], []
    for key, value in scientific_collections(document):
        if isinstance(value, RecordList):
            names.append(key)
            if value.reset: resets.append(key)
            deletes.extend({"collection": key, "key": identifier} for identifier in sorted(value.deleted))
            updates.extend(_record(key, identifier, ordinal, row, store) for identifier, (ordinal, row) in [*value.dirty.items(), *value.added.items()])
        elif isinstance(value, list):
            names.append(key); resets.append(key)
            if len(value) > MAX_COLLECTION_RECORDS: fail("indexed-collection-limit", "A retained collection exceeds its row bound.")
            updates.extend(_record(key, str(uuid.uuid4()), index, row, store) for index, row in enumerate(value))
    header.update({"storageFormat": FORMAT, "_recordCollections": names})
    result = {"schemaVersion": 1, "storageFormat": FORMAT, "header": header, "updates": updates, "deletes": deletes, "resets": resets}
    if len(_json(result).encode()) > MAX_DELTA_BYTES:
        fail("indexed-write-limit", "One operation exceeds the64MiB normalized commit budget; use bounded checkpoints.")
    return result


def apply_delta(connection, value):
    create_tables(connection)
    for collection in value["resets"]:
        connection.execute("DELETE FROM records WHERE collection=?", (collection,))
        if collection == "images":
            connection.execute("DELETE FROM image_index"); connection.execute("DELETE FROM image_tags")
        if collection == "collections": connection.execute("DELETE FROM collection_images")
    for record in value["deletes"]:
        if record["collection"] == "images":
            found = connection.execute("SELECT entity_id FROM records WHERE collection='images' AND record_key=?", (record["key"],)).fetchone()
            if found:
                connection.execute("DELETE FROM image_index WHERE image_id=?", found); connection.execute("DELETE FROM image_tags WHERE image_id=?", found)
        connection.execute("DELETE FROM records WHERE collection=? AND record_key=?", (record["collection"], record["key"]))
    for record in value["updates"]:
        connection.execute("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?,?)", (record["collection"], record["key"], record["ordinal"], record["entityId"], record["payload"], record["bytes"]))
        body = json.loads(record["payload"])
        if record["collection"] == "images":
            from _workbench_adaptation import _reference_current
            words = [body["name"], body.get("notes", ""), *body.get("tags", []), *body.get("channelNames", [])]
            status = "analyzed" if body.get("analysis") else "volume-analyzed" if body.get("volumeFrames") else "imported"
            connection.execute("INSERT OR REPLACE INTO image_index VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (body["id"], record["key"], record["ordinal"], body["name"], "\n".join(words).casefold(), body["sourceHash"], int(body.get("archived", False)), status, body.get("importedFrom"), int(bool(body.get("analysis"))), int(bool(body.get("volumeFrames"))), int(_reference_current(body))))
            connection.execute("DELETE FROM image_tags WHERE image_id=?", (body["id"],))
            connection.executemany("INSERT OR IGNORE INTO image_tags VALUES(?,?)", ((body["id"], tag.strip().casefold()) for tag in body.get("tags", [])))
        if record["collection"] == "collections":
            connection.execute("DELETE FROM collection_images WHERE collection_id=?", (body["id"],))
            connection.executemany("INSERT OR IGNORE INTO collection_images VALUES(?,?)", ((body["id"], image_id) for image_id in body.get("imageIds", [])))
    connection.execute("UPDATE state SET revision=?,document=? WHERE id=1", (value["header"]["revision"], _json(value["header"])))


def touched_effects(connection, change, request, actor):
    from _workbench_sessions import effect_basis, event_for
    old_images, new_images = [], []
    image_rows = [row for row in change["updates"] if row["collection"] == "images"]
    identifiers = {row["key"] for row in image_rows} | {row["key"] for row in change["deletes"] if row["collection"] == "images"}
    if "images" in change["resets"]:
        old_images = [json.loads(row[0]) for row in connection.execute("SELECT payload FROM records WHERE collection='images'")]
    else:
        for identifier in identifiers:
            row = connection.execute("SELECT payload FROM records WHERE collection='images' AND record_key=?", (identifier,)).fetchone()
            if row: old_images.append(json.loads(row[0]))
    new_images = [json.loads(row["payload"]) for row in image_rows]
    before = effect_basis({"revision": request["expectedRevision"], "images": old_images})
    return event_for(before, {**change["header"], "images": new_images}, request, actor)


def artifact_references(document):
    refs = {}
    def visit(value):
        if isinstance(value, CellRows): refs[value.reference["path"]] = value.reference["hash"]
        elif isinstance(value, dict):
            reference = value.get("measurementTable")
            if reference: refs[reference["path"]] = reference["hash"]
            for key, child in value.items():
                if key != "measurementTable": visit(child)
        elif isinstance(value, (list, tuple)):
            for child in value: visit(child)
    for image in document["images"]:
        # Undo/correction histories retain previous exact measurements as well
        # as current analyses. Never hydrate their cell rows to collect refs.
        visit(image)
    migration = document.get("storageMigration")
    if migration and migration.get("snapshotPath"): refs[migration["snapshotPath"]] = migration["snapshotHash"]
    return refs


def base_metadata_bytes(document):
    """Format2 budgets apply to this command's delta, not total retained state."""
    if document.get('storageFormat') == FORMAT: return 0
    from _workbench_store import canonical
    return len(canonical(document).encode())


def bound_cell_response(value, request):
    """Copy response containers, paging cell rows without modifying scientific state.

    This runs before response receipts are retained. An exact retry therefore
    returns the same explicitly bounded result, including after a reopen.
    """
    limit = request.get("arguments", {}).get("cellLimit")
    if limit is None:
        return value

    def visit(item):
        if isinstance(item, dict):
            output = {key: visit(child) for key, child in item.items() if key != "cells"}
            if "cells" in item:
                cells = item["cells"]
                if isinstance(cells, (list, tuple, CellRows)):
                    total = max(len(cells), item.get("cellCount", len(cells)))
                    output["cells"] = [visit(cell) for cell in cells[:limit]]
                    output.setdefault("cellCount", total)
                    output["returnedCellCount"] = len(output["cells"])
                    output["cellsTruncated"] = total > limit
                else:
                    output["cells"] = visit(cells)
            return output
        if isinstance(item, (list, tuple)):
            return [visit(child) for child in item]
        return item

    return visit(value)
