"""Release regressions for indexed state, portable snapshots and agent bindings."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _workbench_core import dispatch
from _workbench_store import ProjectStore, file_hash, canonical
from _workbench_schema import OPERATIONS
import _workbench_runtimes as runtimes
import _workbench_plugins as plugins
import _workbench_package2 as package2


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.project = self.root / 'Project'; self.revision = 0
        self.call('project.create', {'name': 'Release regression'})
        previous = runtimes._registry_path
        self.addCleanup(setattr, runtimes, '_registry_path', previous)
        runtimes._registry_path = None

    def request(self, op, args=None, **extra):
        value = {'schemaVersion': 1, 'operation': op, 'requestId': str(uuid.uuid4()),
                 'projectPath': str(self.project), 'arguments': args or {},
                 'actor': {'kind': 'test', 'name': 'Release regressions'}}
        descriptor = next(row for row in OPERATIONS if row['name'] == op)
        if descriptor['mutating'] and descriptor.get('requiresExpectedRevision', True) and op not in ('project.create', 'package.restore'):
            value['expectedRevision'] = self.revision
        return {**value, **extra}

    def call(self, op, args=None, **extra):
        response = dispatch(self.request(op, args, **extra)); self.assertTrue(response['ok'], response)
        self.revision = response.get('revision', self.revision)
        return response['result']

    def image(self):
        import numpy as np
        from PIL import Image
        pixels = np.zeros((24, 32), np.uint16); pixels[2:7, 3:9] = 100; pixels[12:18, 20:26] = 200
        path = self.root / (uuid.uuid4().hex + '.tif'); Image.fromarray(pixels).save(path)
        identifier = self.call('image.import', {'paths': [str(path)]})['importedImageIds'][0]
        return identifier

    def analyzed(self):
        identifier = self.image()
        result = self.call('analysis.run', {'imageId': identifier, 'parameters': {'method': 'manual', 'threshold': 50, 'minAreaPx': 1, 'minDistancePx': 99}, 'cellLimit': 1})
        self.assertEqual(result['cellCount'], 2); self.assertEqual(len(result['cells']), 1)
        return identifier

    def test_indexed_pages_snapshot_pins_pick_and_cursors(self):
        identifier = self.analyzed(); self.image()
        snapshot = self.call('project.snapshot', {'selectedImageIds': [identifier]})
        self.assertEqual(snapshot['imageCount'], 2); self.assertEqual(len(snapshot['images']), 1)
        self.assertEqual(snapshot['storage']['format'], 2)
        page = self.call('image.list', {'limit': 1}); self.assertEqual(page['total'], 2)
        self.assertTrue(page['nextCursor'])
        second = self.call('image.list', {'limit': 1, 'cursor': page['nextCursor']})
        self.assertNotEqual(page['images'][0]['id'], second['images'][0]['id'])
        measured = self.call('measurements.page', {'imageId': identifier, 'limit': 1})
        self.assertEqual(measured['total'], 2); self.assertEqual(len(measured['cells']), 1)
        picked = self.call('mask.pick', {'imageId': identifier, 'x': 4, 'y': 3})
        self.assertGreater(picked['labelId'], 0)
        found = self.call('measurements.lookup', {'imageId': identifier, 'labelIds': [picked['labelId'], 999]})
        self.assertEqual(found['missingLabelIds'], [999])
        self.call('image.metadata.set', {'imageId': identifier, 'tags': ['selected']})
        conflict = dispatch(self.request('image.list', {'limit': 1, 'cursor': page['nextCursor']}))
        self.assertEqual(conflict['error']['code'], 'snapshot-changed')

    def test_retained_views_survive_unrelated_dispatch_and_deepcopy_isolated(self):
        identifier = self.analyzed(); document = ProjectStore(str(self.project)).read()
        self.addCleanup(document.view.close)
        before = copy.deepcopy(document)
        self.call('project.snapshot', {'selectedImageIds': [identifier]})
        self.assertEqual(document, before)
        before['images'][0]['name'] = 'preview only'
        self.assertNotEqual(before['images'][0]['name'], document['images'][0]['name'])

    def test_package2_roundtrip_exact_cells_undo_and_integrity(self):
        identifier = self.analyzed()
        original = self.call('measurements.get', {'imageId': identifier})
        self.call('mask.edit', {'imageId': identifier, 'action': 'delete', 'labelIds': [original['cells'][0]['labelId']]})
        path = self.root / 'portable.zip'; self.call('project.export', {'destination': str(path)})
        info = self.call('package.inspect', {'path': str(path)})
        self.assertEqual(info['package']['format'], 2)
        self.assertTrue(info['verification']['snapshotVerified']); self.assertFalse(info['verification']['artifactBytesVerified'])
        target = self.root / 'Restored'
        request = self.request('package.restore', {'path': str(path)}, projectPath=str(target))
        restored = dispatch(request); self.assertTrue(restored['ok'], restored); self.assertEqual(dispatch(request), restored)
        measured = dispatch(self.request('measurements.get', {'imageId': identifier}, projectPath=str(target)))
        self.assertEqual(measured['result']['cellCount'], 1)
        undo = dispatch(self.request('mask.undo', {'imageId': identifier}, projectPath=str(target), expectedRevision=0))
        self.assertTrue(undo['ok'], undo); self.assertEqual(undo['result']['cells'], original['cells'])
        with zipfile.ZipFile(path) as source:
            entries = [(item.filename, source.read(item)) for item in source.infolist()]
        bad = self.root / 'changed.zip'
        with zipfile.ZipFile(bad, 'w') as output:
            for name, data in entries:
                output.writestr(name, bytes([data[0] ^ 1]) + data[1:] if name == 'snapshot.sqlite' else data)
        rejected = dispatch(self.request('package.restore', {'path': str(bad)}, projectPath=str(self.root / 'Rejected')))
        self.assertFalse(rejected['ok']); self.assertEqual(rejected['error']['code'], 'package-integrity')

    def test_package2_restartable_cancel_and_exact_restore_receipts(self):
        self.analyzed(); path = self.root / 'partial.zip'; self.call('project.export', {'destination': str(path)})
        target = self.root / 'Partial'
        initial = self.call('package.restore.start', {'path': str(path)}, projectPath=str(target))['restore']
        self.assertFalse((target / 'workbench.sqlite').exists())
        cancelled = self.call('package.restore.cancel', {'expectedRestoreRevision': initial['restoreRevision']}, projectPath=str(target))['restore']
        current = self.call('package.restore.resume', {'expectedRestoreRevision': cancelled['restoreRevision']}, projectPath=str(target))['restore']
        for _ in range(current['progress']['total'] + 2):
            request = self.request('package.restore.advance', {'expectedRestoreRevision': current['restoreRevision']}, projectPath=str(target))
            response = dispatch(request); self.assertTrue(response['ok'], response); self.assertEqual(dispatch(request), response)
            current = response['result']['restore']
            if current['status'] == 'completed': break
        self.assertEqual(current['status'], 'completed')
        self.assertTrue((target / 'workbench.sqlite').exists())

    def test_package2_rejects_executable_sql_schema(self):
        path = self.root / 'untrusted.sqlite'; connection = sqlite3.connect(path)
        for statement in package2._SCHEMA.values(): connection.execute(statement)
        connection.execute("INSERT INTO project VALUES(1,'{}')")
        connection.execute('CREATE VIEW unsafe AS SELECT 1')
        connection.commit(); connection.close()
        with self.assertRaises(Exception) as error: package2._connect(path)
        self.assertEqual(error.exception.code, 'invalid-package-snapshot')

    def test_package2_convenience_retry_finishes_journaled_database(self):
        self.analyzed(); path = self.root / 'recovery.zip'
        self.call('project.export', {'destination': str(path)})
        target = self.root / 'Interrupted'
        request = self.request('package.restore', {'path': str(path)}, projectPath=str(target))
        original_link = package2.os.link
        def interrupted_link(source, destination, *args, **kwargs):
            if Path(source).name == '.package2-local.sqlite':
                raise OSError('simulated failure after completion journal')
            return original_link(source, destination, *args, **kwargs)
        with patch.object(package2.os, 'link', side_effect=interrupted_link):
            interrupted = dispatch(request)
        self.assertFalse(interrupted['ok'])
        self.assertFalse((target / 'workbench.sqlite').exists())
        self.assertEqual(package2._journal(target)[1]['status'], 'completed')
        recovered = dispatch(request)
        self.assertTrue(recovered['ok'], recovered)
        self.assertTrue((target / 'workbench.sqlite').is_file())
        self.assertEqual(dispatch(request), recovered)

    def plugin(self):
        source = self.root / 'extension.py'
        source.write_text("import json,sys,pathlib,numpy as np\nr=json.load(open(sys.argv[1])); a=np.load(r['input']['pixelsPath']); np.save(pathlib.Path(r['outputDirectory'])/'labels.npy',(a>50).astype('uint32')); json.dump({'schemaVersion':1,'labelsPath':'labels.npy'},open(sys.argv[2],'w'))")
        manifest = self.root / 'plugin.json'
        manifest.write_text(json.dumps({'schemaVersion': 1, 'id': 'org.release.plugin', 'version': '1', 'name': 'Release', 'kind': 'segmentation', 'entryPoint': source.name, 'supportedDimensions': [2]}))
        return self.call('plugin.install', {'manifestPath': str(manifest)})['plugin']['pluginId']

    def test_runtime_registry_cas_replay_frozen_workflow_and_legacy_default(self):
        plugin_id = self.plugin(); runtimes.configure(str(self.root / 'runtimes.json'))
        candidate = runtimes.candidate(sys.executable)
        args = {'runtimeId': 'local', 'name': 'Local', 'pythonPath': sys.executable, 'pythonSha256': candidate['pythonSha256'], 'expectedConfigurationHash': 'missing'}
        request = self.request('runtime.interpreter.register', args)
        registered = dispatch(request); self.assertTrue(registered['ok'], registered); self.assertEqual(dispatch(request), registered)
        binding = self.call('plugin.runtime.bind', {'pluginId': plugin_id, 'runtimeId': 'local', 'expectedConfigurationHash': registered['result']['configurationHash']})
        self.assertFalse(binding['enabled'])
        steps = [{'type': 'plugin-segmentation', 'pluginId': plugin_id}, {'type': 'measurements'}, {'type': 'summary'}]
        saved = self.call('workflow.save', {'name': 'Plugin', 'steps': steps})['workflow']
        self.assertEqual(saved['steps'][0]['pluginRuntimeBinding']['kind'], 'registered-runtime')
        self.call('workflow.save', {'workflowId': saved['id'], 'name': 'Plugin again', 'steps': saved['steps']})
        document = ProjectStore(str(self.project)).read(); self.addCleanup(document.view.close)
        old = {key: value for key, value in saved['steps'][0].items() if key != 'pluginRuntimeBinding'}
        with patch.object(plugins, 'execute', return_value={}) as call:
            plugins.execute_step(None, document, old, {'imageId': 'fake'}, 1)
            self.assertTrue(call.call_args.kwargs['legacy_default_runtime'])
        current = runtimes.resolve(package_hash=plugins._record(document, plugin_id)['packageHash'])
        self.assertNotIn('pythonPath', runtimes.identity(current))
        self.assertEqual(runtimes.resolve(force_default=True)['kind'], 'current-runtime')
        stale = dispatch(self.request('runtime.interpreter.register', args))
        self.assertFalse(stale['ok']); self.assertEqual(stale['error']['code'], 'host-configuration-conflict')
        self.call('plugin.setEnabled', {'pluginId': plugin_id, 'enabled': True})
        identifier = self.image()
        inferred = self.call('plugin.run', {'pluginId': plugin_id, 'imageId': identifier})
        self.assertTrue(inferred)
        self.assertEqual(self.call('measurements.get', {'imageId': identifier})['cellCount'], 1)

    def test_model_card_routes_and_future_default_without_enabling(self):
        weight = self.root / 'model.bin'; weight.write_bytes(b'checkpoint fixture' * 100)
        model = self.call('model.register', {'name': 'Authored model', 'backend': 'cellpose3', 'pythonPath': sys.executable, 'checkpointPath': str(weight)})['model']
        card = self.call('model.card.save', {'modelId': model['id'], 'intendedUse': 'Fixture only', 'limitations': 'Never inferred'})['card']
        self.assertEqual(card['version'], 1)
        self.assertEqual(self.call('model.card.get', {'modelId': model['id']})['card']['hash'], card['hash'])
        self.call('model.configure', {'modelId': model['id'], 'enabled': False})
        refused = dispatch(self.request('model.activation.set', {'modelId': model['id'], 'reason': 'fixture'}))
        self.assertEqual(refused['error']['code'], 'model-disabled')
        snapshot = self.call('project.snapshot')
        self.assertIsNone(snapshot['modelActivation']['modelId'])
        self.call('model.activation.set', {'modelId': None, 'reason': 'No default'})

    def test_catalogue_selected_older_record_and_session_no_science_revision(self):
        first = None
        for index in range(4):
            value = self.call('specimen.set', {'name': str(index), 'experiment': 'E', 'condition': 'C', 'role': 'control'})
            first = first or value['id']
        snapshot = self.call('project.snapshot', {'catalogueLimit': 1, 'selectedCatalogueEntries': [{'catalogue': 'specimens', 'entryId': first}]})
        self.assertEqual(snapshot['cataloguePages']['specimens']['total'], 4)
        self.assertTrue(snapshot['cataloguePages']['specimens']['partial'])
        self.assertEqual(snapshot['selectedCatalogueEntries'][0]['entry']['id'], first)
        before = self.revision
        opened = self.call('session.open', {'name': 'SDK', 'clientKind': 'sdk'})
        self.assertEqual(self.revision, before)
        self.assertIsNotNone(opened)
        changes = self.call('project.changes', {'afterRevision': before})
        self.assertEqual(changes['events'], [])


if __name__ == '__main__': unittest.main()
