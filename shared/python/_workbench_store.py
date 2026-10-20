"""Transactional project metadata and immutable artifacts for the workbench."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from datetime import datetime, timezone

from _workbench_schema import WorkbenchError, absolute_path

DB_NAME = "workbench.sqlite"
MAX_SOURCE_BYTES = 512 * 1024 * 1024
MAX_PROJECT_JSON_BYTES = 64 * 1024 * 1024
MAX_RESPONSE_BYTES = 24 * 1024 * 1024


def utc_now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def canonical(value):
    from _workbench_indexed import json_default
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False, default=json_default)


def request_hash(request):
    return hashlib.sha256(canonical(request).encode("utf-8")).hexdigest()


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sync_directory(path):
    """Persist directory entries where the platform provides directory fsync."""
    if os.name != "posix":
        return
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class ProjectStore:
    def __init__(self, project_path):
        self.root = absolute_path(project_path, "projectPath")
        self.db_path = self.root / DB_NAME
        if not self.root.is_dir() or not self.db_path.is_file() or self.db_path.is_symlink():
            raise WorkbenchError("project-not-found", "The selected directory is not a workbench project.")

    @classmethod
    def create(cls, project_path, document, request, response):
        if len(canonical(document).encode("utf-8")) > MAX_PROJECT_JSON_BYTES:
            raise WorkbenchError("project-too-large", "Project metadata exceeds the 64 MiB working-set budget.")
        if len(canonical(response).encode("utf-8")) > MAX_RESPONSE_BYTES:
            raise WorkbenchError("result-too-large", "Result exceeds the 24 MiB client response budget.")
        root = absolute_path(project_path, "projectPath")
        if root.exists():
            if (root / DB_NAME).is_file():
                store = cls(str(root))
                replay = store.replay(request)
                if replay is not None:
                    return store, replay
            raise WorkbenchError("project-exists", "Project creation requires a new directory.")
        if not root.parent.is_dir():
            raise WorkbenchError("invalid-path", "The project parent directory must already exist.")
        try:
            root.mkdir()
        except FileExistsError:
            raise WorkbenchError("project-exists", "Another operation created this directory.")
        try:
            (root / "artifacts").mkdir()
            connection = sqlite3.connect(str(root / DB_NAME), timeout=30)
            try:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute("PRAGMA synchronous=FULL")
                connection.executescript("""
                    CREATE TABLE state (id INTEGER PRIMARY KEY CHECK (id=1),
                                        revision INTEGER NOT NULL, document TEXT NOT NULL);
                    CREATE TABLE requests (request_id TEXT PRIMARY KEY, digest TEXT NOT NULL,
                                           response TEXT NOT NULL);
                """)
                with connection:
                    from _workbench_indexed import delta, apply_delta
                    document["storageFormat"] = 2
                    connection.execute("INSERT INTO state VALUES(1,?,?)", (document["revision"], "{}"))
                    apply_delta(connection, delta(cls(str(root)), document))
                    connection.execute("INSERT INTO requests VALUES(?,?,?)",
                                       (request["requestId"], request_hash(request), canonical(response)))
            finally:
                connection.close()
        except Exception:
            # Preserve partially created state for diagnosis; never remove user data.
            raise
        return cls(str(root)), response

    def connection(self):
        try:
            connection = sqlite3.connect(str(self.db_path), timeout=30)
            connection.execute("PRAGMA busy_timeout=30000")
            connection.execute("PRAGMA synchronous=FULL")
            return connection
        except sqlite3.DatabaseError as exc:
            raise WorkbenchError("project-corrupt", "Cannot open project metadata.", {"reason": str(exc)})

    @staticmethod
    def _replay(connection, request):
        row = connection.execute("SELECT digest,response FROM requests WHERE request_id=?",
                                 (request["requestId"],)).fetchone()
        if row is None:
            sessions = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_requests'").fetchone()
            if sessions and connection.execute("SELECT 1 FROM session_requests WHERE request_id=?", (request["requestId"],)).fetchone():
                raise WorkbenchError("request-conflict", "requestId was already used for a client session command.")
            return None
        if row[0] != request_hash(request):
            raise WorkbenchError("request-conflict", "requestId was already used for a different command.")
        return json.loads(row[1])

    def replay(self, request):
        connection = self.connection()
        try:
            # Take the writer lock before looking for an interrupted publication:
            # an active exporter must finish before another process reconciles it.
            connection.execute("BEGIN IMMEDIATE")
            self._reconcile_publication(connection)
            response = self._replay(connection, request)
            connection.commit()
            self._clear_committed_publication(connection)
            return response
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _publication_path(self):
        return self.root / ".pending-publication.json"

    def _write_publication(self, record):
        path = self._publication_path()
        record = {**record, "integrityHash": hashlib.sha256(canonical(record).encode("utf-8")).hexdigest()}
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=self.root, prefix=".publication-", delete=False) as output:
                temporary = Path(output.name)
                output.write(canonical(record).encode("utf-8"))
                output.flush()
                os.fsync(output.fileno())
            os.link(str(temporary), str(path))
            sync_directory(self.root)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def _read_publication(self):
        path = self._publication_path()
        if not path.exists():
            return None
        if path.is_symlink() or path.stat().st_size > MAX_PROJECT_JSON_BYTES + MAX_RESPONSE_BYTES + 2 * 1024 * 1024:
            raise WorkbenchError("project-corrupt", "Invalid pending publication record.")
        record = json.loads(path.read_text(encoding="utf-8"))
        integrity = {key: value for key, value in record.items() if key != "integrityHash"}
        if record.get("integrityHash") != hashlib.sha256(canonical(integrity).encode("utf-8")).hexdigest():
            raise WorkbenchError("project-corrupt", "The pending publication record failed its integrity check.")
        request, response = record["request"], record["response"]
        document = record["delta"]["header"] if record.get("storageFormat") == 2 else record["document"]
        if (record.get("schemaVersion") != 1 or record["requestHash"] != request_hash(request)
                or response.get("schemaVersion") != 1 or response.get("ok") is not True
                or response.get("operation") != request["operation"]
                or response.get("requestId") != request["requestId"]
                or response.get("revision") != request["expectedRevision"] + 1
                or document.get("revision") != response["revision"]):
            raise WorkbenchError("project-corrupt", "Inconsistent pending publication record.")
        return record

    def _reconcile_publication(self, connection):
        record = self._read_publication()
        if record is None:
            return
        request = record["request"]
        if self._replay(connection, request) is not None:
            # The original result is already durable. Clear under the current
            # writer lock so a new export can create its own intent immediately.
            self._publication_path().unlink(missing_ok=True)
            sync_directory(self.root)
            return
        recorded_destination = Path(record["publication"]["destination"])
        destination = absolute_path(record["publication"]["destination"], "destination")
        if recorded_destination.is_symlink() or recorded_destination != destination:
            raise WorkbenchError("publication-conflict", "The interrupted export destination has been replaced by a link.")
        if not destination.exists():
            # The process stopped before exposing any external file. Recompute
            # normally; neither the project nor the output needs recovery.
            self._publication_path().unlink()
            return
        if record["publication"].get("kind") == "artifact-repair" and destination.is_file():
            observed = file_hash(destination)
            if observed != record["publication"]["sha256"] and observed == record["publication"].get("previousHash"):
                # Intent was durable but atomic replacement had not happened.
                # The original corrupt evidence was retained during preparation.
                self._publication_path().unlink(missing_ok=True)
                sync_directory(self.root)
                return
        if destination.is_symlink() or not destination.is_file() or file_hash(destination) != record["publication"]["sha256"]:
            raise WorkbenchError("publication-conflict",
                                 "An interrupted export destination no longer matches its recorded package. Preserve or move that file before retrying.")
        row = connection.execute("SELECT revision,document FROM state WHERE id=1").fetchone()
        document = record["delta"]["header"] if record.get("storageFormat") == 2 else record["document"]
        if row is None or row[0] != request["expectedRevision"] or json.loads(row[1])["id"] != document["id"]:
            raise WorkbenchError("publication-conflict", "Project changed before its interrupted export could be recovered.")
        from _workbench_sessions import effect_basis, event_for, save_event
        event = record.get("event")
        if event is None:
            event = event_for(effect_basis(json.loads(row[1])), document, request, document["history"][-1]["actor"])
        save_event(connection, event)
        if record.get("storageFormat") == 2:
            from _workbench_indexed import apply_delta
            apply_delta(connection, record["delta"])
        else:
            connection.execute("UPDATE state SET revision=?,document=? WHERE id=1", (document["revision"], canonical(document)))
        connection.execute("INSERT INTO requests VALUES(?,?,?)",
                           (request["requestId"], record["requestHash"], canonical(record["response"])))

    def _clear_committed_publication(self, connection):
        connection.execute("BEGIN IMMEDIATE")
        try:
            record = self._read_publication()
            if record is not None and self._replay(connection, record["request"]) is not None:
                self._publication_path().unlink(missing_ok=True)
                sync_directory(self.root)
            connection.commit()
        except Exception:
            connection.rollback()
            raise

    def read(self, *, track_effects=False):
        connection = self.connection()
        retained = False
        try:
            if self._publication_path().exists():
                connection.execute("BEGIN IMMEDIATE")
                self._reconcile_publication(connection)
                connection.commit()
                self._clear_committed_publication(connection)
            connection.execute("BEGIN")
            row = connection.execute("SELECT revision,document FROM state WHERE id=1").fetchone()
            if not row:
                raise WorkbenchError("project-corrupt", "Project metadata is missing.")
            if len(row[1]) > MAX_PROJECT_JSON_BYTES:
                raise WorkbenchError("project-too-large", "Project header exceeds its64MiB budget.")
            document = json.loads(row[1])
            if document.get("schemaVersion") != 1 or document.get("revision") != row[0]:
                raise WorkbenchError("project-corrupt", "Project schema or revision is inconsistent.")
            if document.get("storageFormat") == 2:
                from _workbench_indexed import IndexedDocument
                value = IndexedDocument(self, connection, document)
                retained = True
                return value
            if track_effects:
                from _workbench_sessions import effect_basis
                self._effect_basis = effect_basis(document)
            return document
        finally:
            if not retained: connection.close()

    def _commit_indexed(self, request, document, result, actor, publish=None, publication=None):
        from _workbench_indexed import delta, apply_delta, touched_effects
        from _workbench_sessions import save_event
        expected = request["expectedRevision"]
        if document["revision"] != expected:
            raise WorkbenchError("revision-conflict", "The operation no longer owns its original read revision.")
        document["revision"] = expected + 1
        document["updatedAt"] = utc_now()
        document["history"].append({"revision": expected + 1, "operation": request["operation"],
                                    "requestId": request["requestId"], "actor": actor,
                                    "at": document["updatedAt"], "arguments": request.get("arguments", {})})
        # Measurement retention and normalized serialization occur before the
        # writer lock. A conflict discards the delta, never another actor's rows.
        change = delta(self, document)
        response = {"schemaVersion": 1, "ok": True, "operation": request["operation"],
                    "requestId": request["requestId"], "revision": expected + 1, "result": result}
        saved_response = canonical(response)
        response = json.loads(saved_response)
        if len(saved_response.encode()) > MAX_RESPONSE_BYTES:
            raise WorkbenchError("result-too-large", "Result exceeds the24MiB client response budget.")
        connection = self.connection(); cleanup = None; published = False; committed = False
        try:
            connection.execute("BEGIN IMMEDIATE")
            self._reconcile_publication(connection)
            replay = self._replay(connection, request)
            if replay is not None:
                connection.commit(); self._clear_committed_publication(connection); return replay
            row = connection.execute("SELECT revision,document FROM state WHERE id=1").fetchone()
            if row is None or row[0] != expected:
                raise WorkbenchError("revision-conflict", "Project changed while this operation ran. Inspect and retry.",
                                     {"expectedRevision": expected, "actualRevision": row[0] if row else None})
            if json.loads(row[1]).get("storageFormat") == 2:
                event = touched_effects(connection, change, request, actor)
            else:
                # Explicit upgrade preserves all pixels; only storage/domain metadata changes.
                event = {"revision": expected + 1, "operation": request["operation"], "requestId": request["requestId"],
                         "actor": actor, "at": document["updatedAt"], "imageEffects": [], "domains": ["project"]}
            if publish is not None:
                if publication is None: raise WorkbenchError("invalid-publication", "A publication requires a recovery record.")
                self._write_publication({"schemaVersion": 1, "storageFormat": 2, "request": request,
                                         "requestHash": request_hash(request), "delta": change, "response": response,
                                         "publication": publication, "event": event})
                cleanup = publish(); published = True
            apply_delta(connection, change)
            save_event(connection, event)
            connection.execute("INSERT INTO requests VALUES(?,?,?)", (request["requestId"], request_hash(request), saved_response))
            connection.commit(); committed = True
            self._clear_committed_publication(connection)
            return response
        except Exception:
            connection.rollback()
            if cleanup is not None and not committed: cleanup()
            preserve = published and publication is not None and publication.get("kind") == "artifact-repair"
            if not committed and not preserve and publish is not None and self._publication_path().exists():
                pending = self._read_publication()
                if pending is not None and pending["requestHash"] == request_hash(request): self._publication_path().unlink(missing_ok=True)
            raise
        finally: connection.close()

    def commit(self, request, document, result, actor, publish=None, publication=None):
        """Commit a computation only against the revision it read.

        ``publish`` may perform a single atomic rename/link of an already prepared
        export. Image processing and ZIP compression must happen before this call.
        """
        from _workbench_indexed import bound_cell_response
        result = bound_cell_response(result, request)
        if document.get("storageFormat") == 2:
            return self._commit_indexed(request, document, result, actor, publish, publication)
        connection = self.connection()
        published_cleanup = None
        published = False
        committed = False
        try:
            connection.execute("BEGIN IMMEDIATE")
            self._reconcile_publication(connection)
            replay = self._replay(connection, request)
            if replay is not None:
                connection.commit()
                self._clear_committed_publication(connection)
                return replay
            row = connection.execute("SELECT revision FROM state WHERE id=1").fetchone()
            actual = row[0] if row else None
            expected = request["expectedRevision"]
            if actual != expected or document["revision"] != expected:
                raise WorkbenchError("revision-conflict", "Project changed while this operation ran. Inspect and retry.",
                                     {"expectedRevision": expected, "actualRevision": actual})
            from _workbench_sessions import effect_basis, event_for, save_event
            before = getattr(self, "_effect_basis", None)
            if before is None or before["revision"] != expected:
                old = connection.execute("SELECT document FROM state WHERE id=1").fetchone()
                before = effect_basis(json.loads(old[0]))
            revision = expected + 1
            document["revision"] = revision
            document["updatedAt"] = utc_now()
            document["history"].append({
                "revision": revision, "operation": request["operation"],
                "requestId": request["requestId"], "actor": actor,
                "at": document["updatedAt"],
                "arguments": request.get("arguments", {}),
            })
            response = {"schemaVersion": 1, "ok": True, "operation": request["operation"],
                        "requestId": request["requestId"], "revision": revision, "result": result}
            event = event_for(before, document, request, actor)
            saved_document, saved_response = canonical(document), canonical(response)
            response = json.loads(saved_response)
            if len(saved_document.encode("utf-8")) > MAX_PROJECT_JSON_BYTES:
                raise WorkbenchError("project-too-large", "Project metadata exceeds 64 MiB. Split the experiment into smaller projects.")
            if len(saved_response.encode("utf-8")) > MAX_RESPONSE_BYTES:
                raise WorkbenchError("result-too-large", "Result exceeds the 24 MiB client response budget.")
            if publish is not None:
                if publication is None:
                    raise WorkbenchError("invalid-publication", "An external publication requires a recovery record.")
                self._write_publication({
                    "schemaVersion": 1, "request": request, "requestHash": request_hash(request),
                    "document": document, "response": response, "publication": publication, "event": event,
                })
                published_cleanup = publish()
                published = True
            save_event(connection, event)
            connection.execute("UPDATE state SET revision=?,document=? WHERE id=1",
                               (revision, saved_document))
            connection.execute("INSERT INTO requests VALUES(?,?,?)",
                               (request["requestId"], request_hash(request), saved_response))
            connection.commit()
            committed = True
            self._clear_committed_publication(connection)
            return response
        except Exception:
            connection.rollback()
            if published_cleanup is not None and not committed:
                published_cleanup()
            # Normal failures clean their own intent. Abrupt process termination
            # bypasses this branch, preserving the record for the next request.
            preserve_repair = published and publication is not None and publication.get("kind") == "artifact-repair"
            if not committed and not preserve_repair and publish is not None and self._publication_path().exists():
                pending = self._read_publication()
                if pending is not None and pending["requestHash"] == request_hash(request):
                    self._publication_path().unlink(missing_ok=True)
            raise
        finally:
            connection.close()

    def artifact_path(self, relative):
        if not isinstance(relative, str) or not relative.startswith("artifacts/"):
            raise WorkbenchError("project-corrupt", "Invalid artifact reference.")
        path = self.root / relative
        resolved = path.resolve()
        if path.is_symlink() or self.root not in resolved.parents or not resolved.is_file():
            raise WorkbenchError("missing-artifact", "A project artifact is missing or outside the project.",
                                 {"artifact": relative})
        return resolved

    def verify_artifact(self, reference, digest):
        path = self.artifact_path(reference)
        if file_hash(path) != digest:
            raise WorkbenchError("artifact-changed", "A project artifact no longer matches its recorded hash.",
                                 {"artifact": reference})
        return path

    def put_bytes(self, content, suffix):
        digest = hashlib.sha256(content).hexdigest()
        directory = self.root / "artifacts"
        if directory.is_symlink() or directory.resolve().parent != self.root:
            raise WorkbenchError("project-corrupt", "Artifact directory is outside the project.")
        relative = f"artifacts/{digest}{suffix}"
        path = self.root / relative
        temp = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, prefix=".artifact-", delete=False) as stream:
                temp = Path(stream.name)
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            try:
                os.link(str(temp), str(path))
            except FileExistsError:
                if path.is_symlink() or file_hash(path) != digest:
                    raise WorkbenchError("artifact-changed", "An immutable artifact has been modified.")
        finally:
            if temp is not None:
                temp.unlink(missing_ok=True)
        return relative, digest

    def import_file(self, source, artifact_suffix=None):
        path = absolute_path(source, "paths")
        if artifact_suffix is not None and artifact_suffix not in (".cp3", ".cp4", ".stardist.h5", ".stardist.weights.h5", ".omnipose", ".microsam"):
            raise WorkbenchError("invalid-artifact-type", "Unsupported retained binary artifact type.")
        maximum = 2 * 1024 ** 3 if artifact_suffix in (".cp4", ".microsam") else MAX_SOURCE_BYTES
        size_error = "artifact-too-large" if artifact_suffix is not None else "image-too-large"
        if not path.is_file():
            raise WorkbenchError("source-not-found", "An import source is not a regular file.", {"path": str(path)})
        if path.stat().st_size > maximum:
            raise WorkbenchError(size_error, "The import exceeds its retained artifact size limit.",
                                 {"maximumBytes": maximum})
        directory = self.root / "artifacts"
        if directory.is_symlink() or directory.resolve().parent != self.root:
            raise WorkbenchError("project-corrupt", "Artifact directory is outside the project.")
        temp = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, prefix=".import-", delete=False) as output:
                temp = Path(output.name)
                digest = hashlib.sha256()
                size = 0
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        size += len(block)
                        if size > maximum:
                            raise WorkbenchError(size_error, "The import exceeds its retained artifact size limit.",
                                                 {"maximumBytes": maximum})
                        digest.update(block)
                        output.write(block)
                output.flush()
                os.fsync(output.fileno())
            suffix = artifact_suffix or path.suffix.lower()
            if artifact_suffix is None and suffix not in (".tif", ".tiff", ".png", ".jpg", ".jpeg", ".bmp"):
                raise WorkbenchError("unsupported-format", "Supported imports are TIFF, PNG, JPEG and BMP.")
            checksum = digest.hexdigest()
            relative = f"artifacts/{checksum}{suffix}"
            destination = self.root / relative
            try:
                os.link(str(temp), str(destination))
            except FileExistsError:
                if destination.is_symlink() or file_hash(destination) != checksum:
                    raise WorkbenchError("artifact-changed", "An immutable source artifact has been modified.")
            return relative, checksum, size
        finally:
            if temp is not None:
                temp.unlink(missing_ok=True)

    def retain_verified_file(self, source, reference, checksum, *, maximum_bytes=MAX_SOURCE_BYTES):
        """Stream a package-verified artifact into immutable storage without decoding it."""
        import re
        match = re.fullmatch(r"artifacts/([0-9a-f]{64})(\.[A-Za-z0-9._-]+)", reference)
        if match is None or match.group(1) != checksum:
            raise WorkbenchError("invalid-artifact", "The retained artifact name must match its SHA-256 digest.")
        source = Path(source)
        if source.is_symlink() or not source.is_file() or source.stat().st_size > maximum_bytes:
            raise WorkbenchError("invalid-artifact", "The verified artifact must be a bounded regular file.")
        directory = self.root / "artifacts"
        if directory.is_symlink() or directory.resolve().parent != self.root:
            raise WorkbenchError("project-corrupt", "Artifact directory is outside the project.")
        destination = self.root / reference
        if destination.exists():
            self.verify_artifact(reference, checksum)
            return
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, prefix=".retained-", delete=False) as output:
                temporary = Path(output.name)
                digest = hashlib.sha256()
                size = 0
                with source.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        size += len(block)
                        if size > maximum_bytes:
                            raise WorkbenchError("artifact-too-large", "The retained artifact exceeds its size bound.")
                        digest.update(block)
                        output.write(block)
                if digest.hexdigest() != checksum:
                    raise WorkbenchError("artifact-changed", "The verified artifact changed before it could be retained.")
                output.flush()
                os.fsync(output.fileno())
            try:
                os.link(str(temporary), str(destination))
            except FileExistsError:
                self.verify_artifact(reference, checksum)
            sync_directory(directory)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
