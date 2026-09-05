import contextlib
import importlib
import io
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _cellpose_common as cc


class DetectionStartupTests(unittest.TestCase):
    def fake_utils(self, fail=False):
        opened = []
        utils = types.ModuleType('cellpose.utils')
        def open_url(*args, **kwargs):
            opened.append(kwargs.get('timeout'))
            if fail:
                raise TimeoutError('socket stopped responding')
            return object()
        def download(url, destination, progress=True):
            utils.urlopen(url)
            return 'saved'
        utils.urlopen = open_url
        utils.download_url_to_file = download
        return utils, opened

    def test_download_timeout_progress_and_hooks_restore_without_network(self):
        utils, opened = self.fake_utils()
        original_download, original_open = utils.download_url_to_file, utils.urlopen
        logs = io.StringIO()
        package = types.ModuleType('cellpose')
        package.utils = utils
        with patch.dict(sys.modules, {'cellpose': package}), contextlib.redirect_stderr(logs):
            with cc.model_loading_progress():
                result = utils.download_url_to_file('https://unused.invalid/cyto3', '/tmp/cyto3')
        self.assertEqual(result, 'saved')
        self.assertEqual(opened, [30])
        self.assertIs(utils.download_url_to_file, original_download)
        self.assertIs(utils.urlopen, original_open)
        self.assertIn('one-time model setup', logs.getvalue())
        self.assertIn('weights ready: cyto3', logs.getvalue())

    def test_download_failure_stays_distinct_and_never_claims_ready(self):
        utils, opened = self.fake_utils(fail=True)
        original_download, original_open = utils.download_url_to_file, utils.urlopen
        package = types.ModuleType('cellpose')
        package.utils = utils
        logs = io.StringIO()
        with patch.dict(sys.modules, {'cellpose': package}), contextlib.redirect_stderr(logs):
            with self.assertRaisesRegex(cc.ModelDownloadError, 'internet connection and retry'):
                with cc.model_loading_progress():
                    utils.download_url_to_file('https://unused.invalid/cyto3', '/tmp/cyto3')
        self.assertEqual(opened, [30])
        self.assertNotIn('weights ready', logs.getvalue())
        self.assertIs(utils.download_url_to_file, original_download)
        self.assertIs(utils.urlopen, original_open)

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
        package.utils, _ = self.fake_utils()
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
