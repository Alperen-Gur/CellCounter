"""Streamed scientific snapshots and restartable bounded artifact-shard restore.

Portable SQLite is data only: its exact ordinary-table schema is checked before
trusted SELECT statements copy rows into a newly initialized local store.
"""
from __future__ import annotations

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tarfile
import tempfile
import uuid
import zipfile

FORMAT = 'cellcounter-analysis-package'
MAX_BYTES = 32 * 1024 ** 3
MAX_SNAPSHOT_BYTES = 2 * 1024 ** 3
MAX_REFS = 500000
MAX_ROWS = 2000000
SHARD_BYTES = 256 * 1024 ** 2
MAX_MEMBER_BYTES = 2 * 1024 ** 3
MAX_MANIFEST_BYTES = 2 * 1024 ** 2
_ARTIFACT = re.compile(r'^artifacts/([0-9a-f]{64})\.[A-Za-z0-9._-]{1,32}$')
_SCHEMA = {
 'project': 'CREATE TABLE project (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL)',
 'records': 'CREATE TABLE records (collection TEXT NOT NULL, record_key TEXT NOT NULL, ordinal INTEGER NOT NULL, entity_id TEXT, payload TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY(collection,record_key))',
 'artifacts': 'CREATE TABLE artifacts (path TEXT PRIMARY KEY, sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, shard INTEGER NOT NULL)',
}


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _json(value):
    from _workbench_store import canonical
    return canonical(value)


def _load(data, name):
    from _workbench_packages import _json as strict_json
    return strict_json(data, name)


def _atomic(path, value):
    from _workbench_store import sync_directory
    temporary = path.with_name('.' + path.name + '-' + uuid.uuid4().hex)
    try:
        with temporary.open('xb') as stream:
            stream.write(_json(value).encode()); stream.flush(); os.fsync(stream.fileno())
        os.replace(str(temporary), str(path)); sync_directory(path.parent)
    finally: temporary.unlink(missing_ok=True)


def _schema(connection):
    connection.execute('PRAGMA trusted_schema=OFF'); connection.execute('PRAGMA query_only=ON')
    objects = connection.execute('SELECT type,name,tbl_name,sql FROM sqlite_master').fetchall()
    tables = {name: sql for kind, name, _, sql in objects if kind == 'table'}
    if tables != _SCHEMA:
        fail('invalid-package-snapshot', 'The portable snapshot must contain exactly the supported ordinary data tables.')
    for kind, name, owner, sql in objects:
        if kind == 'table': continue
        if kind != 'index' or owner not in ('records', 'artifacts') or sql is not None or not name.startswith('sqlite_autoindex_'):
            fail('invalid-package-snapshot', 'Views, triggers, virtual tables and extra SQL schema are not accepted in portable snapshots.')
    if connection.execute('SELECT COUNT(*) FROM project').fetchone()[0] != 1:
        fail('invalid-package-snapshot', 'The portable snapshot requires one scientific project header.')


def _connect(path):
    connection = sqlite3.connect(path.as_uri() + '?mode=ro&immutable=1', uri=True)
    try: _schema(connection)
    except Exception:
        connection.close()
        raise
    return connection


def _paths(value):
    if isinstance(value, str):
        if _ARTIFACT.fullmatch(value): yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from _paths(key)
            yield from _paths(item)
    elif isinstance(value, (list, tuple)):
        for item in value: yield from _paths(item)


def _put_reference(connection, store, reference):
    digest = _ARTIFACT.fullmatch(reference).group(1)
    path = store.artifact_path(reference)
    if path.is_symlink() or not path.is_file(): fail('artifact-missing', 'A retained artifact is missing or linked.', {'artifact': reference})
    size = path.stat().st_size
    if size > MAX_MEMBER_BYTES: fail('package-artifact-limit', 'A retained artifact exceeds the 2 GiB member limit.', {'artifact': reference})
    connection.execute('INSERT OR IGNORE INTO artifacts VALUES(?,?,?,-1)', (reference, digest, size))


def _portable_header(document):
    from _workbench_indexed import scientific_header
    header = copy.deepcopy(scientific_header(document))
    header.pop('storageMigration', None)
    return header


def _record_rows(store, document):
    from _workbench_indexed import scientific_collections, pack, record_identity
    for name, values in scientific_collections(document):
        for ordinal, value in enumerate(values):
            body = pack(store, value)
            # Process ownership and runtime sessions are never portable launch authority.
            if name == 'jobWorkers':
                body = {key: item for key, item in body.items() if key not in ('pid', 'token', 'runToken', 'processStartedAt')}
                body['status'] = 'interrupted'; body['stopReason'] = 'portable-snapshot'
            raw = _json(body); size = len(raw.encode())
            if size > 32 * 1024 ** 2: fail('package-record-limit', 'One scientific record exceeds its 32 MiB portable bound.')
            yield name, str(uuid.uuid4()), ordinal, record_identity(body), raw, size


def _snapshot(store, document, path):
    connection = sqlite3.connect(str(path))
    try:
        for statement in _SCHEMA.values(): connection.execute(statement)
        header = _portable_header(document)
        connection.execute('INSERT INTO project VALUES(1,?)', (_json(header),))
        count = 0
        for record in _record_rows(store, document):
            count += 1
            if count > MAX_ROWS: fail('package-record-limit', 'The portable snapshot exceeds two million scientific records.')
            connection.execute('INSERT INTO records VALUES(?,?,?,?,?,?)', record)
            for reference in _paths(_load(record[4], 'scientific record')): _put_reference(connection, store, reference)
            if count % 1000 == 0:
                connection.commit()
                if path.stat().st_size > MAX_SNAPSHOT_BYTES: fail('package-snapshot-limit', 'Scientific snapshot exceeds 2 GiB.')
        for reference in _paths(header): _put_reference(connection, store, reference)
        # Retained radix/checkpoint/report nodes carry further immutable references.
        # A SQL frontier bounds memory independently of the number of artifacts.
        last = 0
        while True:
            row = connection.execute('SELECT rowid,path,bytes FROM artifacts WHERE rowid>? ORDER BY rowid LIMIT 1', (last,)).fetchone()
            if row is None: break
            last, name, size = row
            if last > MAX_REFS: fail('package-reference-limit', 'A package supports at most 500,000 retained artifacts.')
            if name.endswith('.json'):
                if size > 32 * 1024 ** 2: fail('package-metadata-limit', 'A retained JSON dependency exceeds 32 MiB.')
                source = store.verify_artifact(name, _ARTIFACT.fullmatch(name).group(1))
                for reference in _paths(_load(source.read_bytes(), name)): _put_reference(connection, store, reference)
        shard, shard_size, total = 0, 0, 0
        for rowid, size in connection.execute('SELECT rowid,bytes FROM artifacts ORDER BY path'):
            entry_size = ((size + 511) // 512 + 1) * 512
            if shard_size and shard_size + entry_size > SHARD_BYTES: shard += 1; shard_size = 0
            connection.execute('UPDATE artifacts SET shard=? WHERE rowid=?', (shard, rowid))
            shard_size += entry_size; total += entry_size
            if total > MAX_BYTES: fail('package-too-large', 'The portable scientific payload exceeds 32 GiB.')
        connection.commit()
        if path.stat().st_size > MAX_SNAPSHOT_BYTES: fail('package-snapshot-limit', 'Scientific snapshot exceeds 2 GiB.')
        return {'recordCount': count, 'artifactCount': connection.execute('SELECT COUNT(*) FROM artifacts').fetchone()[0],
                'artifactBytes': connection.execute('SELECT COALESCE(SUM(bytes),0) FROM artifacts').fetchone()[0],
                'imageCount': len(document['images']), 'shardCount': connection.execute('SELECT COALESCE(MAX(shard)+1,0) FROM artifacts').fetchone()[0]}
    finally: connection.close()


class _HashReader:
    def __init__(self, stream): self.stream, self.digest, self.bytes = stream, hashlib.sha256(), 0
    def read(self, size=-1):
        value = self.stream.read(size); self.digest.update(value); self.bytes += len(value); return value


def prepare_export(store, document, request):
    from _workbench_schema import absolute_path
    from _workbench_store import file_hash, sync_directory, utc_now
    from _workbench_packages import runtime_versions
    destination = absolute_path(request['arguments']['destination'], 'destination')
    if destination.suffix.lower() != '.zip' or not destination.parent.is_dir(): fail('invalid-path', 'Choose a new .zip file in an existing directory.')
    if destination.exists(): fail('destination-exists', 'Package export never overwrites an existing file.')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.package2-', suffix='.zip', delete=False) as stream: temporary = Path(stream.name)
        with tempfile.TemporaryDirectory(prefix='cellcounter-package2-') as working:
            from _workbench_distributed import runtime_signature
            from _workbench_models import active_environment_hash
            runtime = runtime_signature(store, {model['id']: active_environment_hash(model) for model in document.get('models', [])})
            export_document = {**document, 'packageRuntimeEvidence': runtime}
            snapshot = Path(working) / 'snapshot.sqlite'; counts = _snapshot(store, export_document, snapshot)
            manifest = {'schemaVersion': 2, 'format': FORMAT, 'projectId': document['id'], 'name': document['name'],
                        'sourceRevision': document['revision'], 'exportedAt': utc_now(), 'runtimeDependencies': runtime_versions(), 'runtimeEvidence': runtime,
                        'snapshot': {'path': 'snapshot.sqlite', 'sha256': file_hash(snapshot), 'bytes': snapshot.stat().st_size},
                        **counts, 'shards': [], 'notes': ['Scientific data only; client sessions, local configuration and request receipts are omitted.',
                        'Original artifact references and exact measurements are retained. External source roots still require explicit relocation/authorization.']}
            connection = _connect(snapshot)
            try:
                with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
                    archive.write(snapshot, 'snapshot.sqlite')
                    for index in range(counts['shardCount']):
                        shard_path = Path(working) / 'shard.tar'
                        with tarfile.open(shard_path, 'w', format=tarfile.USTAR_FORMAT) as tar:
                            for name, expected, size in connection.execute('SELECT path,sha256,bytes FROM artifacts WHERE shard=? ORDER BY path', (index,)):
                                info = tarfile.TarInfo(name); info.size = size; info.mode = 0o600; info.mtime = 0
                                with store.artifact_path(name).open('rb') as source:
                                    reader = _HashReader(source); tar.addfile(info, reader)
                                    if reader.bytes != size or reader.digest.hexdigest() != expected:
                                        fail('artifact-changed', 'A retained artifact changed during streamed export.', {'artifact': name})
                        name = 'shards/' + str(index).zfill(6) + '.tar'
                        manifest['shards'].append({'path': name, 'sha256': file_hash(shard_path), 'bytes': shard_path.stat().st_size})
                        archive.write(shard_path, name); shard_path.unlink()
                    archive.writestr('manifest.json', _json(manifest))
            finally: connection.close()
        if temporary.stat().st_size > MAX_BYTES: fail('package-too-large', 'The streamed archive exceeds 32 GiB.')
        with temporary.open('rb') as stream: os.fsync(stream.fileno())
        digest = file_hash(temporary)
        result = {'destination': str(destination), 'sha256': digest, 'sourceRevision': document['revision'],
                  'packageFormat': 2, **counts, 'files': ['manifest.json', 'snapshot.sqlite'], 'artifactManifest': 'snapshot.sqlite:artifacts'}
        def cleanup():
            try:
                if os.path.samefile(str(destination), str(temporary)): destination.unlink(); sync_directory(destination.parent)
            except FileNotFoundError: pass
        def publish():
            try: os.link(str(temporary), str(destination))
            except FileExistsError: fail('destination-exists', 'Package export never overwrites an existing file.')
            sync_directory(destination.parent); return cleanup
        return result, publish, temporary
    except Exception:
        if temporary is not None: temporary.unlink(missing_ok=True)
        raise


def is_package2(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file(): return False
    # Read only the bounded directory; package2 has at most 130 small entries.
    if path.stat().st_size > MAX_BYTES: fail('package-too-large', 'The package exceeds 32 GiB.')
    with path.open('rb') as stream:
        stream.seek(max(0, path.stat().st_size - 65557)); tail = stream.read()
    marker = tail.rfind(b'PK\x05\x06')
    if marker < 0: return False
    import struct
    if marker + 22 > len(tail): return False
    _, disk, start, disk_count, count, size, offset, comment = struct.unpack('<4s4H2LH', tail[marker:marker+22])
    if disk or start or count > 1024 or size > 2 * 1024 ** 2:
        return False
    with zipfile.ZipFile(path) as archive:
        try: info = archive.getinfo('manifest.json')
        except KeyError: return False
        if info.file_size > MAX_MANIFEST_BYTES: return False
        return _load(archive.read(info), 'manifest.json').get('schemaVersion') == 2


def _manifest(path):
    if not is_package2(path): fail('invalid-package', 'This is not a supported streamed package2 archive.')
    archive = zipfile.ZipFile(path)
    try:
        infos = archive.infolist(); names = [info.filename for info in infos]
        manifest = _load(archive.read('manifest.json'), 'manifest.json')
        if manifest.get('format') != FORMAT or not isinstance(manifest.get('shards'), list) or len(manifest['shards']) > 512:
            fail('invalid-package', 'The package2 manifest has an unsupported format or shard count.')
        refs = [manifest.get('snapshot', {}), *manifest['shards']]
        if manifest.get('snapshot', {}).get('path') != 'snapshot.sqlite' or [row.get('path') for row in manifest['shards'] if isinstance(row, dict)] != ['shards/' + str(i).zfill(6) + '.tar' for i in range(len(manifest['shards']))]:
            fail('invalid-package', 'Snapshot and shard names must follow their exact indexed sequence.')
        expected_names = {'manifest.json', 'snapshot.sqlite'} | {'shards/' + str(i).zfill(6) + '.tar' for i in range(len(manifest['shards']))}
        if len(names) != len(set(names)) or set(names) != expected_names: fail('invalid-package', 'Package2 entries must exactly match the bounded manifest.')
        for ref in refs:
            if not isinstance(ref, dict) or ref.get('path') not in expected_names or not re.fullmatch('[0-9a-f]{64}', str(ref.get('sha256', ''))): fail('invalid-package', 'A streamed entry has invalid identity metadata.')
            info = archive.getinfo(ref['path']); bound = MAX_SNAPSHOT_BYTES if ref['path'] == 'snapshot.sqlite' else MAX_MEMBER_BYTES + 10240
            if type(ref.get('bytes')) is not int or not 0 <= ref['bytes'] <= bound or info.file_size != ref['bytes']:
                fail('invalid-package', 'A streamed entry exceeds its declared size or supported bound.')
            if info.flag_bits & 1 or info.is_dir() or info.compress_type != zipfile.ZIP_STORED:
                fail('invalid-package', 'Streamed package2 entries must be unencrypted ordinary stored files.')
        if sum(info.file_size for info in infos) > MAX_BYTES: fail('package-too-large', 'Expanded package exceeds 32 GiB.')
        return archive, manifest
    except Exception: archive.close(); raise


def _copy_entry(archive, ref, destination):
    digest = hashlib.sha256(); size = 0
    with archive.open(ref['path']) as source, destination.open('wb') as target:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            size += len(block)
            if size > ref['bytes']: fail('package-integrity', 'A package entry exceeded its declared length.')
            digest.update(block); target.write(block)
        target.flush(); os.fsync(target.fileno())
    if size != ref['bytes'] or digest.hexdigest() != ref['sha256']: fail('package-integrity', 'A package entry failed its immutable hash binding.', {'entry': ref['path']})


def _validate_snapshot(connection, manifest):
    header = _load(connection.execute('SELECT value FROM project WHERE id=1').fetchone()[0], 'snapshot header')
    if not isinstance(header, dict) or header.get('schemaVersion') != 1 or header.get('id') != manifest.get('projectId') or header.get('revision') != manifest.get('sourceRevision'):
        fail('invalid-package-snapshot', 'The scientific snapshot and package identity differ.')
    names = header.get('_recordCollections')
    if not isinstance(names, list) or len(names) > 256 or any(not isinstance(name, str) or not re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,80}', name) for name in names) or len(names) != len(set(names)):
        fail('invalid-package-snapshot', 'The snapshot has invalid scientific collection names.')
    if any(name in names for name in ('sessions', 'requests', 'session_requests', 'events')): fail('invalid-package-snapshot', 'Portable snapshots may not carry transport authority.')
    from _workbench_indexed import NESTED_COLLECTIONS
    nested = header.get('_nestedRecords', {})
    if not isinstance(nested, dict) or any(parent not in NESTED_COLLECTIONS or not isinstance(mapping, dict)
            or not isinstance(header.get(parent), dict)
            or any(field not in NESTED_COLLECTIONS[parent] or name != NESTED_COLLECTIONS[parent][field]
                   or name not in names or field in header[parent] for field, name in mapping.items())
            for parent, mapping in nested.items()):
        fail('invalid-package-snapshot', 'The snapshot has an invalid nested scientific collection mapping.')
    reserved = {name for mapping in NESTED_COLLECTIONS.values() for name in mapping.values()}
    mapped = {name for mapping in nested.values() for name in mapping.values()}
    if set(names).intersection(reserved) != mapped:
        fail('invalid-package-snapshot', 'Reserved nested collections must have their exact declared scientific parent.')
    actual = {row[0] for row in connection.execute('SELECT DISTINCT collection FROM records')}
    if not actual.issubset(set(names)): fail('invalid-package-snapshot', 'Snapshot records name an undeclared collection.')
    counts = dict(connection.execute('SELECT collection,COUNT(*) FROM records GROUP BY collection'))
    if sum(counts.values()) > MAX_ROWS or counts.get('images', 0) > 100000: fail('package-record-limit', 'The indexed snapshot exceeds supported record counts.')
    if counts.get('images', 0) != manifest.get('imageCount'): fail('package-integrity', 'The snapshot image count differs from the manifest.')
    artifact_count = 0
    for name, digest, size, shard in connection.execute('SELECT path,sha256,bytes,shard FROM artifacts'):
        match = _ARTIFACT.fullmatch(name)
        if not match or match.group(1) != digest or type(size) is not int or not 0 <= size <= MAX_MEMBER_BYTES or type(shard) is not int or not 0 <= shard < len(manifest['shards']):
            fail('invalid-package-snapshot', 'The artifact index contains an invalid path, hash, size or shard.')
        artifact_count += 1
        if artifact_count > MAX_REFS: fail('package-reference-limit', 'The package artifact count exceeds 500,000.')
    if artifact_count != manifest.get('artifactCount'): fail('package-integrity', 'The artifact count differs from the manifest.')
    if connection.execute('SELECT 1 FROM records GROUP BY collection,ordinal HAVING COUNT(*)>1 LIMIT 1').fetchone():
        fail('invalid-package-snapshot', 'Scientific record ordinals must be unique within a collection.')
    if connection.execute("SELECT 1 FROM records WHERE collection='images' GROUP BY entity_id HAVING COUNT(*)>1 LIMIT 1").fetchone():
        fail('invalid-package-snapshot', 'Acquisition identities must be distinct.')
    large_models = set()
    model_records = []
    for row in connection.execute("SELECT payload FROM records WHERE collection='models'"):
        model = _load(row[0], 'model record'); model_records.append(model)
        if len(model_records) > 1000: fail('invalid-package-snapshot', 'Model catalogue exceeds its supported bound.')
        if model.get('backend') == 'cellpose4' and str(model.get('checkpointPath', '')).endswith('.cp4'): large_models.add(model['checkpointPath'])
        if model.get('backend') == 'micro-sam' and str(model.get('checkpointPath', '')).endswith('.microsam'): large_models.add(model['checkpointPath'])
    from _workbench_models import validate_model_artifacts, validate_environment_records
    validate_model_artifacts({'models': model_records})
    validate_environment_records({'models': model_records})
    for name, in connection.execute('SELECT path FROM artifacts WHERE bytes>?', (512 * 1024 ** 2,)):
        if name not in large_models: fail('package-member-limit', 'Only an exactly referenced Cellpose4 or micro-SAM checkpoint may exceed 512 MiB.')
    # Records remain streamed and are never executed. Each bounded JSON row is
    # validated before being copied into a newly created trusted SQL schema.
    for collection, key, ordinal, entity_id, raw, size in connection.execute('SELECT collection,record_key,ordinal,entity_id,payload,bytes FROM records'):
        if type(ordinal) is not int or ordinal < 0 or len(raw.encode()) != size or size > 32 * 1024 ** 2: fail('invalid-package-snapshot', 'A scientific row has invalid size or ordering.')
        body = _load(raw, 'scientific row')
        if collection == 'images':
            required = ('id','name','sourcePath','sourceHash','width','height','channels','pxPerUm','axes','shape','dtype','zCount','timeCount','importedAt')
            if not isinstance(body, dict) or any(key not in body for key in required) or body.get('id') != entity_id: fail('invalid-package-snapshot', 'An acquisition row has invalid identity.')
            if any(type(body[key]) is not int or body[key] < 1 for key in ('width','height','channels','zCount','timeCount')) or body['channels'] > 32: fail('invalid-package-snapshot', 'Acquisition dimensions exceed their supported bounds.')
            if not _ARTIFACT.fullmatch(body['sourcePath']) or _ARTIFACT.fullmatch(body['sourcePath']).group(1) != body['sourceHash']: fail('package-integrity', 'An acquisition source path and hash differ.')
        for reference in _paths(body):
            if connection.execute('SELECT 1 FROM artifacts WHERE path=?', (reference,)).fetchone() is None: fail('package-integrity', 'A scientific row references an absent retained artifact.', {'artifact': reference})
    return header, counts


def inspect(path):
    from _workbench_schema import absolute_path
    from _workbench_store import file_hash
    from _workbench_packages import dependency_report
    path = absolute_path(path, 'path'); archive, manifest = _manifest(path)
    try:
        with tempfile.TemporaryDirectory(prefix='cellcounter-package2-inspect-') as working:
            snapshot = Path(working) / 'snapshot.sqlite'; _copy_entry(archive, manifest['snapshot'], snapshot)
            connection = _connect(snapshot)
            try:
                header, counts = _validate_snapshot(connection, manifest)
                dependencies = {'plugins': [], 'models': []}
                for name in dependencies:
                    dependencies[name] = [_load(row[0], name) for row in connection.execute('SELECT payload FROM records WHERE collection=? ORDER BY ordinal', (name,))]
                report = dependency_report(manifest, dependencies)
            finally: connection.close()
        return {'package': {'format': 2, 'path': str(path), 'sha256': file_hash(path), 'projectId': header['id'], 'name': header['name'],
                            'sourceRevision': header['revision'], 'imageCount': counts.get('images', 0), 'artifactCount': manifest['artifactCount'],
                            'bytes': path.stat().st_size, 'shardCount': len(manifest['shards'])}, 'dependencies': report,
                'verification': {'snapshotVerified': True, 'artifactBytesVerified': False, 'artifactVerification': 'Each exact shard/artifact is verified during bounded restore.'}}
    finally: archive.close()


def operations():
    from _workbench_schema import _op, _object, _STRING
    result = [
        _op('package.restore.start', 'Begin an indexed package restore in a new directory without executing retained code.', _object({'path': _STRING, 'name': {'type': 'string', 'maxLength': 200}}, ['path']), True),
        _op('package.restore.get', 'Read a retained restore checkpoint without opening a partial project.', _object()),
        _op('package.restore.advance', 'Verify and restore one bounded artifact shard, or finish the trusted scientific database.', _object({'expectedRestoreRevision': {'type': 'integer', 'minimum': 0}}, ['expectedRestoreRevision']), True),
        _op('package.restore.cancel', 'Stop a partial restore while preserving verified bytes and its recovery journal.', _object({'expectedRestoreRevision': {'type': 'integer', 'minimum': 0}}, ['expectedRestoreRevision']), True),
        _op('package.restore.resume', 'Resume an explicitly cancelled restore of the same bound package.', _object({'expectedRestoreRevision': {'type': 'integer', 'minimum': 0}}, ['expectedRestoreRevision']), True),
    ]
    for item in result:
        item['requiresExpectedRevision'] = False
        item['affectsProjectRevision'] = False
    return result


def _journal(root):
    path = root / '.package2-restore.json'
    if root.is_symlink() or path.is_symlink() or not path.is_file() or path.stat().st_size > 8 * 1024 ** 2:
        fail('restore-not-found', 'Select a directory with a retained package2 restore checkpoint.')
    value = _load(path.read_bytes(), 'restore checkpoint')
    if not isinstance(value, dict) or value.get('schemaVersion') != 1 or not isinstance(value.get('manifest'), dict):
        fail('restore-corrupt', 'The retained restore checkpoint is invalid.')
    return path, value


def _description(value):
    return {key: copy.deepcopy(value[key]) for key in ('id', 'status', 'restoreRevision', 'packagePath', 'packageHash', 'sourceProjectId', 'sourceRevision', 'name', 'nextShard', 'createdAt')}


def _result(value):
    count = len(value['manifest']['shards'])
    result = {'restore': {**_description(value), 'progress': {'completed': value['nextShard'] + int(value['status'] == 'completed'), 'total': count + 1},
                         'imageCount': value['manifest']['imageCount'], 'artifactCount': value['manifest']['artifactCount'],
                         'nextUnit': None if value['status'] in ('completed', 'cancelled') else {'type': 'restore-shard' if value['nextShard'] < count else 'restore-metadata', 'shardIndex': value['nextShard'] if value['nextShard'] < count else None},
                         'notes': ['A partial destination is not an open project. Verified bytes and checkpoints are retained after cancellation.', 'No model, plugin or background job starts automatically.']}}
    if value.get('project'): result.update(value['project'])
    return result


def _envelope(request, result):
    value = {'schemaVersion': 1, 'ok': True, 'operation': request['operation'], 'requestId': request['requestId'], 'result': result}
    if result.get('project'): value['revision'] = result['project']['revision']
    return value


def _receipt(value, request, response):
    from _workbench_store import request_hash
    value.setdefault('receipts', {})[request['requestId']] = {'hash': request_hash(request), 'response': response}
    if len(value['receipts']) > 2048: fail('restore-receipt-limit', 'This restore reached its bounded command-history limit.')


def _replay(value, request):
    from _workbench_store import request_hash
    receipt = value.get('receipts', {}).get(request['requestId'])
    if receipt:
        if receipt['hash'] != request_hash(request): fail('request-conflict', 'requestId already identifies another restore command.')
        return receipt['response']
    return None


def _stat_identity(path):
    value = path.stat()
    return {key: getattr(value, key) for key in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns')}


def _start(request, actor):
    from _workbench_schema import absolute_path
    from _workbench_store import file_hash, sync_directory, utc_now
    root = absolute_path(request['projectPath'], 'projectPath')
    if root.exists():
        _, value = _journal(root)
        replay = _replay(value, request)
        if replay: return replay
        fail('project-exists', 'Start restore in a new directory; continue an existing checkpoint with package.restore.advance.')
    if not root.parent.is_dir(): fail('invalid-path', 'The destination parent must exist.')
    source = absolute_path(request['arguments']['path'], 'path')
    archive, manifest = _manifest(source)
    temporary = Path(tempfile.mkdtemp(dir=root.parent, prefix='.package2-start-'))
    try:
        snapshot = temporary / 'snapshot.sqlite'; _copy_entry(archive, manifest['snapshot'], snapshot)
        connection = _connect(snapshot)
        try: header, _ = _validate_snapshot(connection, manifest)
        finally: connection.close()
        value = {'schemaVersion': 1, 'id': str(uuid.uuid4()), 'status': 'pending', 'restoreRevision': 0, 'nextShard': 0,
                 'packagePath': str(source), 'packageHash': file_hash(source), 'packageStat': _stat_identity(source), 'manifest': manifest,
                 'sourceProjectId': header['id'], 'sourceRevision': header['revision'], 'name': request['arguments'].get('name', header['name']),
                 'createdAt': utc_now(), 'actor': copy.deepcopy(actor), 'receipts': {}}
        response = _envelope(request, _result(value)); _receipt(value, request, response)
        (temporary / 'artifacts').mkdir(); _atomic(temporary / '.package2-restore.json', value)
        try: root.mkdir()
        except FileExistsError: fail('project-exists', 'Another operation created the restore destination.')
        os.rename(snapshot, root / '.package2-snapshot.sqlite')
        os.rename(temporary / 'artifacts', root / 'artifacts')
        os.rename(temporary / '.package2-restore.json', root / '.package2-restore.json')
        sync_directory(root); sync_directory(root.parent)
        return response
    finally: archive.close(); shutil.rmtree(temporary)


def _extract_shard(root, connection, archive, reference, index):
    from _workbench_store import file_hash, sync_directory
    expected_count = connection.execute('SELECT COUNT(*) FROM artifacts WHERE shard=?', (index,)).fetchone()[0]
    count = 0
    with tempfile.TemporaryDirectory(dir=root, prefix='.shard-') as working:
        shard = Path(working) / 'shard.tar'; _copy_entry(archive, reference, shard)
        with tarfile.open(shard, 'r|') as stream:
            # No generic extract: each safe regular member is copied into its
            # exact content-addressed destination after byte and hash checks.
            seen = set()
            for member in stream:
                if not member.isreg() or not _ARTIFACT.fullmatch(member.name) or member.name in seen or member.pax_headers:
                    fail('invalid-package-shard', 'A shard contains an unsafe, repeated or unsupported TAR entry.')
                row = connection.execute('SELECT sha256,bytes FROM artifacts WHERE path=? AND shard=?', (member.name, index)).fetchone()
                if row is None or member.size != row[1]: fail('package-integrity', 'A TAR member differs from its indexed shard binding.')
                seen.add(member.name); count += 1
                if count > expected_count: fail('package-integrity', 'A shard contains extra artifacts.')
                source = stream.extractfile(member)
                temporary = Path(working) / 'artifact'; digest = hashlib.sha256(); size = 0
                with temporary.open('wb') as target:
                    for block in iter(lambda: source.read(1024 * 1024), b''):
                        size += len(block)
                        if size > member.size: fail('package-integrity', 'An artifact exceeded its declared length.')
                        digest.update(block); target.write(block)
                    target.flush(); os.fsync(target.fileno())
                if size != member.size or digest.hexdigest() != row[0]: fail('package-integrity', 'An artifact failed its exact SHA-256 binding.')
                if member.name.endswith('.measurements.sqlite'):
                    from _workbench_indexed import validate_measurement_schema
                    measured = sqlite3.connect(temporary.as_uri() + '?mode=ro&immutable=1', uri=True)
                    try:
                        measured.execute('PRAGMA trusted_schema=OFF'); measured.execute('PRAGMA query_only=ON'); validate_measurement_schema(measured)
                    finally: measured.close()
                destination = root / member.name
                try: os.link(str(temporary), str(destination))
                except FileExistsError:
                    if destination.is_symlink() or file_hash(destination) != row[0]: fail('restore-artifact-conflict', 'Existing restore bytes differ from this package; nothing was overwritten.')
                temporary.unlink()
        if count != expected_count: fail('package-integrity', 'A shard is missing indexed artifacts.')
        sync_directory(root / 'artifacts')


def _restored_record(collection, body):
    if collection in ('models', 'plugins'):
        body['enabledBeforeRestore'] = bool(body.get('enabled')); body['enabled'] = False
    if collection == 'trainingJobs' and body.get('status') != 'collected':
        body['status'] = 'interrupted'; body['error'] = {'code': 'restored-training-job', 'message': 'Training requires a new explicit local process.'}
    if collection in ('jobs', 'refreshJobs', 'tiledAnalyses') and body.get('status') in ('pending', 'running'):
        body['status'] = 'paused'; body['pauseReason'] = 'Explicit resume and runtime/source authorization are required after restore.'
    if collection == 'jobWorkers':
        for key in ('pid', 'token', 'runToken', 'processStartedAt'): body.pop(key, None)
        body['status'] = 'interrupted'; body['stopReason'] = 'restored-package'
    return body


def _finish(root, source, value, request, actor):
    _validate_retained(root, root / ".package2-snapshot.sqlite")
    from _workbench_store import DB_NAME, utc_now, request_hash, sync_directory
    from _workbench_indexed import apply_delta, create_tables
    header, counts = _validate_snapshot(source, value['manifest'])
    now = utc_now(); original_id = header['id']; new_id = value.get('projectId') or str(uuid.uuid4()); value['projectId'] = new_id
    restored = {'path': value['packagePath'], 'sha256': value['packageHash'], 'projectId': original_id, 'name': header['name'], 'sourceRevision': header['revision'], 'packageFormat': 2}
    header.update({'id': new_id, 'name': value['name'], 'revision': 0, 'createdAt': now, 'updatedAt': now, 'restoredFrom': restored})
    header.pop('storageMigration', None)
    if header.get('legacyMigration', {}).get('status') in ('pending', 'running'):
        header['legacyMigration']['status'] = 'paused'; header['legacyMigration']['pauseReason'] = 'Explicit source authorization and resume are required.'
    names = list(header['_recordCollections'])
    for name in ('history', 'restoredHistory'):
        if name not in names: names.append(name)
    header['_recordCollections'] = names
    result = {'project': {key: header[key] for key in ('id', 'name', 'revision', 'createdAt', 'updatedAt')}, 'images': [],
              'imageCount': counts.get('images', 0), 'imagePageRequired': True, 'storage': {'format': 2}, 'restoredFrom': restored}
    value['project'] = result; value['status'] = 'completed'
    response = _envelope(request, _result(value))
    target = root / '.package2-local.sqlite'
    target.unlink(missing_ok=True)
    connection = sqlite3.connect(str(target))
    try:
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute('PRAGMA synchronous=FULL')
        connection.execute('CREATE TABLE state (id INTEGER PRIMARY KEY CHECK (id=1), revision INTEGER NOT NULL, document TEXT NOT NULL)')
        connection.execute('CREATE TABLE requests (request_id TEXT PRIMARY KEY, digest TEXT NOT NULL, response TEXT NOT NULL)')
        create_tables(connection); connection.execute('INSERT INTO state VALUES(1,0,?)', (_json(header),))
        old_history = counts.get('restoredHistory', 0); batch = []
        for collection, key, ordinal, entity, raw, size in source.execute('SELECT collection,record_key,ordinal,entity_id,payload,bytes FROM records ORDER BY collection,ordinal'):
            body = _restored_record(collection, _load(raw, 'scientific row'))
            if collection == 'history': collection = 'restoredHistory'; ordinal += old_history; body['projectId'] = original_id
            raw = _json(body)
            batch.append({'collection': collection, 'key': key, 'ordinal': ordinal, 'entityId': entity, 'payload': raw, 'bytes': len(raw.encode())})
            if len(batch) >= 64:
                apply_delta(connection, {'header': header, 'updates': batch, 'deletes': [], 'resets': []}); connection.commit(); batch = []
        entry = {'revision': 0, 'operation': 'package.restore', 'requestId': request['requestId'], 'actor': actor, 'at': now, 'arguments': {'packageHash': value['packageHash']}}
        batch.append({'collection': 'history', 'key': str(uuid.uuid4()), 'ordinal': 0, 'entityId': None, 'payload': _json(entry), 'bytes': len(_json(entry).encode())})
        apply_delta(connection, {'header': header, 'updates': batch, 'deletes': [], 'resets': []})
        connection.execute('INSERT INTO requests VALUES(?,?,?)', (request['requestId'], request_hash(request), _json(response)))
        connection.commit()
        connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    finally: connection.close()
    # Journal is durable before the trusted local DB becomes visible. A retry
    # can recover the final receipt without executing or replacing a project.
    from _workbench_store import file_hash
    value['localDatabaseHash'] = file_hash(target)
    _receipt(value, request, response); _atomic(root / '.package2-restore.json', value)
    if (root / DB_NAME).exists(): fail('project-exists', 'A project appeared during restore finalization.')
    os.link(str(target), str(root / DB_NAME)); sync_directory(root); target.unlink()
    return response


def _execute_locked(request, actor):
    from _workbench_schema import absolute_path
    from _workbench_store import file_hash, DB_NAME
    operation = request['operation']
    if operation == 'package.restore.start': return _start(request, actor)
    root = absolute_path(request['projectPath'], 'projectPath'); journal_path, value = _journal(root)
    pending_db = root / '.package2-local.sqlite'
    if value['status'] == 'completed' and not (root / DB_NAME).exists():
        if pending_db.is_symlink() or not pending_db.is_file() or file_hash(pending_db) != value.get('localDatabaseHash'): fail('restore-finalization-incomplete', 'The completed restore journal has no matching trusted local database.')
        os.link(str(pending_db), str(root / DB_NAME)); pending_db.unlink()
    if operation == 'package.restore.get': return _envelope(request, _result(value))
    replay = _replay(value, request)
    if replay:
        pending_db = root / '.package2-local.sqlite'
        if value['status'] == 'completed' and not (root / DB_NAME).exists() and pending_db.is_file():
            os.link(str(pending_db), str(root / DB_NAME)); pending_db.unlink()
        return replay
    if request['arguments']['expectedRestoreRevision'] != value['restoreRevision']:
        fail('restore-revision-conflict', 'The restore checkpoint changed. Read it before another command.', {'actualRestoreRevision': value['restoreRevision']})
    if value['status'] == 'completed': fail('restore-completed', 'The restored project is already complete.')
    if operation == 'package.restore.cancel': value['status'] = 'cancelled'
    elif operation == 'package.restore.resume':
        if value['status'] != 'cancelled': fail('restore-not-cancelled', 'Only an explicitly cancelled restore needs resume.')
        value['status'] = 'pending'
    elif operation == 'package.restore.advance':
        if value['status'] == 'cancelled': fail('restore-cancelled', 'Resume this restore explicitly before advancing it.')
        package = Path(value['packagePath'])
        if package.is_symlink() or _stat_identity(package) != value['packageStat']:
            fail('package-changed', 'The bound package file changed. Its partial restore is preserved; select the exact original package.')
        archive, manifest = _manifest(package)
        try:
            if _json(manifest) != _json(value['manifest']): fail('package-changed', 'The bound package manifest changed.')
            snapshot = root / '.package2-snapshot.sqlite'
            if snapshot.is_symlink() or file_hash(snapshot) != manifest['snapshot']['sha256']: fail('restore-snapshot-changed', 'The retained scientific snapshot changed.')
            connection = _connect(snapshot)
            try:
                index = value['nextShard']
                if index < len(manifest['shards']):
                    _extract_shard(root, connection, archive, manifest['shards'][index], index)
                    value['nextShard'] += 1; value['status'] = 'running'
                else:
                    value['restoreRevision'] += 1
                    return _finish(root, connection, value, request, actor)
            finally: connection.close()
        finally: archive.close()
    else: fail('unknown-operation', 'Unsupported package restore operation.')
    value['restoreRevision'] += 1
    response = _envelope(request, _result(value)); _receipt(value, request, response); _atomic(journal_path, value)
    return response


def restore(request, actor):
    """Compatible single-command convenience; every shard remains restartable."""
    from _workbench_schema import absolute_path
    from _workbench_store import request_hash
    root = absolute_path(request['projectPath'], 'projectPath')
    start = {**request, 'operation': 'package.restore.start', 'requestId': request['requestId'] + ':start'}
    if root.exists():
        _, value = _journal(root)
        if value.get('compatibilityRequestHash') != request_hash(request):
            if _replay(value, start) and 'compatibilityRequestHash' not in value:
                value['compatibilityRequestHash'] = request_hash(request); _atomic(root / '.package2-restore.json', value)
            else: fail('request-conflict', 'This restore directory belongs to another request.')
    else:
        execute(start, actor)
        path, value = _journal(root); value['compatibilityRequestHash'] = request_hash(request); _atomic(path, value)
    while True:
        _, value = _journal(root)
        if value['status'] == 'completed':
            # Completion is journaled before publishing the database. Re-enter
            # the locked finalization path when an exact convenience retry
            # follows a crash between those two durable steps.
            recovered = execute({**request, 'operation': 'package.restore.get', 'arguments': {}}, actor)
            return {'schemaVersion': 1, 'ok': True, 'operation': request['operation'], 'requestId': request['requestId'], 'revision': 0,
                    'result': recovered['result']}
        if value['status'] == 'cancelled': fail('restore-cancelled', 'Resume the retained checkpoint explicitly before continuing this restore.')
        advance = {**request, 'operation': 'package.restore.advance', 'requestId': request['requestId'] + ':shard:' + str(value['restoreRevision']),
                   'arguments': {'expectedRestoreRevision': value['restoreRevision']}}
        execute(advance, actor)


def execute(request, actor):
    from _workbench_schema import absolute_path
    from _workbench_jobs import ProjectLock
    from types import SimpleNamespace
    if request['operation'] == 'package.restore.start':
        return _start(request, actor)
    root = absolute_path(request['projectPath'], 'projectPath')
    if not root.is_dir(): fail('restore-not-found', 'The restore directory does not exist.')
    lock = ProjectLock(SimpleNamespace(root=root))
    if not lock.acquire(): fail('restore-busy', 'Another process is advancing this restore checkpoint.')
    try: return _execute_locked(request, actor)
    finally: lock.close()


def verify_document(path, artifact_destination=None):
    """Compatibility seam for isolated task collection; full bytes verified.

    The temporary artifact/snapshot lifetime is attached to the read view and
    ends at the canonical dispatch boundary, after callers retain needed bytes.
    """
    from _workbench_schema import absolute_path
    from _workbench_store import ProjectStore, file_hash
    from _workbench_indexed import IndexedDocument
    from _workbench_packages import dependency_report
    source = absolute_path(path, 'path'); archive, manifest = _manifest(source)
    temporary = tempfile.TemporaryDirectory(prefix='cellcounter-package2-read-')
    working = Path(temporary.name)
    root = Path(artifact_destination) if artifact_destination is not None else working
    (root / 'artifacts').mkdir(parents=True, exist_ok=True)
    snapshot = working / 'snapshot.sqlite'
    connection = None
    try:
        _copy_entry(archive, manifest['snapshot'], snapshot); connection = _connect(snapshot)
        header, counts = _validate_snapshot(connection, manifest)
        for index, shard in enumerate(manifest['shards']): _extract_shard(root, connection, archive, shard, index)
        _validate_retained(root, snapshot)
        store = ProjectStore.__new__(ProjectStore); store.root = root; store.db_path = snapshot
        document = IndexedDocument(store, connection, header)
        document.view.cleanup = temporary.cleanup
        report = {'package': {'format': 2, 'path': str(source), 'sha256': file_hash(source), 'projectId': header['id'], 'name': header['name'],
                              'sourceRevision': header['revision'], 'imageCount': counts.get('images', 0), 'artifactCount': manifest['artifactCount'],
                              'bytes': source.stat().st_size, 'shardCount': len(manifest['shards'])},
                  'dependencies': dependency_report(manifest, document), 'verification': {'snapshotVerified': True, 'artifactBytesVerified': True}}
        return report, document
    except Exception:
        if connection is not None: connection.close()
        temporary.cleanup(); raise
    finally: archive.close()


class _ArtifactIndex:
    """Manifest mapping backed by fixed trusted SQL; no 500k-entry JSON map."""
    def __init__(self, connection): self.connection = connection
    def __iter__(self):
        for row in self.connection.execute('SELECT path FROM artifacts ORDER BY path'): yield row[0]
    def get(self, name, default=None):
        row = self.connection.execute('SELECT sha256 FROM artifacts WHERE path=?', (name,)).fetchone()
        return row[0] if row else default
    def __getitem__(self, name):
        row = self.connection.execute('SELECT sha256 FROM artifacts WHERE path=?', (name,)).fetchone()
        if row is None: raise KeyError(name)
        return row[0]
    def items(self):
        yield from self.connection.execute('SELECT path,sha256 FROM artifacts ORDER BY path')


def _validate_retained(root, snapshot):
    """Reuse canonical scientific validators after exact bytes are restored."""
    from _workbench_store import ProjectStore
    from _workbench_indexed import IndexedDocument
    from _workbench_packages import _validate_document, directory_json_reader
    connection = _connect(snapshot)
    header = _load(connection.execute('SELECT value FROM project WHERE id=1').fetchone()[0], 'snapshot header')
    store = ProjectStore.__new__(ProjectStore); store.root = root; store.db_path = snapshot
    document = IndexedDocument(store, connection, header)
    reader = directory_json_reader(root); manifest = _ArtifactIndex(connection)
    try:
        _validate_document(document, manifest, reader)
        import _workbench_models as models
        import _workbench_distributed as distributed
        import _workbench_refresh as refresh
        import _workbench_environment as environment
        bindings = [*models.environment_bindings(document), *distributed.environment_bindings(document), *refresh.environment_bindings(document)]
        runtime = document.get('packageRuntimeEvidence')
        if runtime:
            inventory = environment.validate(reader(runtime['environmentPath'], runtime['environmentHash'], 2 * 1024 ** 2))
            if environment.summary(inventory) != runtime['environment']: fail('package-integrity', 'Package runtime inventory differs from its observed summary.')
        for name, (task, is_result) in distributed.snapshot_references(document).items():
            path = root / name
            if path.stat().st_size > 64 * 1024 ** 2: fail('package-metadata-limit', 'An isolated task snapshot exceeds 64 MiB.')
            raw = path.read_bytes()
            bindings.extend(distributed.validate_snapshot(document, name, raw, manifest, read_json=reader))
        for binding in bindings:
            checksum = manifest.get(binding['inventoryPath'])
            if checksum is None: fail('package-integrity', 'Observed environment bytes are missing.')
            inventory = environment.validate(reader(binding['inventoryPath'], checksum, 2 * 1024 ** 2))
            if {'hash': inventory['hash'], 'summary': environment.summary(inventory)} != {key: binding[key] for key in ('hash', 'summary')}:
                fail('package-integrity', 'Retained environment bytes differ from their bound observed summary.')
        for model in document.get('models', []):
            for item in model.get('modelArtifacts', []):
                row = connection.execute('SELECT bytes FROM artifacts WHERE path=?', (item['path'],)).fetchone()
                if row is None or row[0] != item['bytes']: fail('package-integrity', 'A model artifact byte count differs from its immutable role binding.')
                if item['role'] in ('config', 'thresholds'):
                    config = reader(item['path'], item['hash'], 1024 ** 2)
                    if not isinstance(config, dict): fail('invalid-package', 'A model configuration must contain a JSON object.')
                    if item['role'] == 'config' and (config.get('n_dim', 2) != 2 or config.get('axes', 'YXC') != 'YXC' or config.get('n_classes') not in (None, 0) or config.get('n_channel_in') != model['registrationConfig'].get('inputChannels')):
                        fail('package-integrity', 'StarDist configuration bytes differ from their registered channel/dimension identity.')
                    if item['role'] == 'thresholds' and (set(config) != {'prob', 'nms'} or any(type(value) not in (int, float) or not 0 < value < 1 for value in config.values())):
                        fail('invalid-package', 'StarDist thresholds must be probabilities strictly between zero and one.')
    finally: document.view.close()
