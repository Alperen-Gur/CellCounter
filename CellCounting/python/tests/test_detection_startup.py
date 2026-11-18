import contextlib
import importlib
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _cellpose_common as cc


class DetectionStartupTests(unittest.TestCase):
    def setUp(self):
        # Model loading cleans the Cellpose models folder; keep it off the
        # real ~/.cellpose. No test here reaches the network.
        models = tempfile.TemporaryDirectory()
        self.addCleanup(models.cleanup)
        self.models_dir = models.name
        patcher = patch.dict(os.environ, {'CELLPOSE_LOCAL_MODELS_PATH': models.name,
                                          # Keep weight checksums out of the real caches folder.
                                          'CELLCOUNTER_WEIGHTS_HASH_CACHE': os.path.join(models.name, 'weights-sha256.json'),
                                          'no_proxy': '*', 'NO_PROXY': '*'})
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_utils(self):
        utils = types.ModuleType('cellpose.utils')
        def download(url, destination, progress=True):
            raise AssertionError("Cellpose's own downloader must not run")
        utils.download_url_to_file = download
        return utils

    def test_cellcounter_downloader_replaces_cellposes_and_hooks_restore(self):
        utils = self.fake_utils()
        original_download = utils.download_url_to_file
        package = types.ModuleType('cellpose')
        package.utils = utils
        with patch.dict(sys.modules, {'cellpose': package}), contextlib.redirect_stderr(io.StringIO()):
            with cc.model_loading_progress() as directory:
                self.assertIsNot(utils.download_url_to_file, original_download)
                self.assertEqual(directory, self.models_dir)
        self.assertIs(utils.download_url_to_file, original_download)

    def test_download_failure_stays_distinct_and_never_claims_ready(self):
        utils = self.fake_utils()
        original_download = utils.download_url_to_file
        package = types.ModuleType('cellpose')
        package.utils = utils
        with socket.socket() as probe:  # a local port nobody listens on
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        logs = io.StringIO()
        with patch.dict(sys.modules, {'cellpose': package}), contextlib.redirect_stderr(logs):
            with self.assertRaisesRegex(cc.ModelDownloadError, 'internet connection and retry'):
                with cc.model_loading_progress():
                    utils.download_url_to_file(f'http://127.0.0.1:{port}/cyto3',
                                               os.path.join(self.models_dir, 'cyto3'))
        self.assertIn('one-time model setup', logs.getvalue())
        self.assertNotIn('weights ready', logs.getvalue())
        self.assertIs(utils.download_url_to_file, original_download)
        self.assertEqual(os.listdir(self.models_dir), [])

    def test_byte_progress_is_idempotent_and_partial_close_is_not_success(self):
        class Bar:
            def __init__(self, total=None, unit='B', unit_scale=True):
                self.total, self.unit, self.unit_scale, self.n = total, unit, unit_scale, 0
            def update(self, n=1):
                self.n += n
            def close(self):
                pass
        module = types.ModuleType('tqdm')
        module.tqdm = Bar
        with patch.dict(sys.modules, {'tqdm': module}):
            cc.install_tqdm_progress_bridge()
            first_update = Bar.update
            cc.install_tqdm_progress_bridge()
            self.assertIs(first_update, Bar.update)
            logs = io.StringIO()
            with contextlib.redirect_stderr(logs):
                partial = Bar(total=100)
                partial.update(25)
                partial.close()
                partial.close()
            self.assertIn('(25%)', logs.getvalue())
            self.assertNotIn('downloaded weights', logs.getvalue())
            self.assertNotIn('weights ready', logs.getvalue())
            complete = io.StringIO()
            with contextlib.redirect_stderr(complete):
                full = Bar(total=100)
                full.update(100)
                full.close()
                unknown = Bar()
                unknown.update(2 * 1024 * 1024)
                unknown.close()
                non_download = Bar(total=5, unit='cells')
                non_download.update(5)
                non_download.close()
            self.assertEqual(complete.getvalue().count('downloaded weights:'), 1)
            self.assertIn('downloading weights: 2.0 MB', complete.getvalue())
            self.assertNotIn('cells', complete.getvalue())

    def test_warm_requests_preserve_pixels_arguments_and_single_model(self):
        import numpy as np
        import cellpose_detect
        constructions, evaluations = [], []
        source = np.arange(120, dtype=np.uint8).reshape(10, 12)
        class Model:
            device = 'cpu'
            def __init__(self, **kwargs):
                constructions.append(kwargs)
            def eval(self, image, **kwargs):
                evaluations.append((image, kwargs))
                return (np.zeros(image.shape, dtype=np.int32), None)
        package = types.ModuleType('cellpose')
        package.models = types.SimpleNamespace(CellposeModel=Model)
        package.utils = self.fake_utils()
        torch = types.SimpleNamespace(__version__='fixture',
            backends=types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: False)),
            cuda=types.SimpleNamespace(is_available=lambda: False))
        requests = [dict(request_id=str(i), args=['--image', 'fixture.png', '--pxPerUm', '4.24921083813378',
                                                '--conf', '0.6639127831010453']) for i in range(2)]
        cellpose_detect._MODEL_CACHE.clear()
        output = io.StringIO()
        with patch.dict(sys.modules, {'cellpose': package, 'torch': torch}), \
             patch.object(cc, 'open_image_for_detection', return_value=source), \
             patch.object(cc, 'compute_qc_metrics', return_value={}), \
             patch.object(cc, 'compute_colony_stats', return_value={}), \
             patch.object(cc, 'measure_cells', return_value=[]), \
             patch.object(sys, 'stdin', io.StringIO('\n'.join(map(json.dumps, requests)))), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            cc.serve_ndjson(cellpose_detect.main)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([r['exit_code'] for r in responses], [0, 0])
        self.assertEqual(len(constructions), 1)
        self.assertEqual(len(evaluations), 2)
        for image, arguments in evaluations:
            self.assertIs(image, source)
            self.assertEqual(arguments['channels'], [0, 0])
            self.assertAlmostEqual(arguments['diameter'], 25 * 4.24921083813378)
        cellpose_detect._MODEL_CACHE.clear()


if __name__ == '__main__':
    unittest.main()
