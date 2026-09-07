import contextlib
import importlib
import io
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _cellpose_common as cc


class DetectionStartupTests(unittest.TestCase):
    def test_both_desktop_workers_keep_their_protocol_and_reuse_one_model(self):
        import argparse
        import cellpose_detect
        import cellpose4_detect
        for module, model_name in ((cellpose_detect, 'cyto3'), (cellpose4_detect, 'cpsam')):
            self.assertTrue(callable(module.parse_args))
            self.assertTrue(callable(module.build_model))
            self.assertTrue(callable(module.run_detection_once))
            calls = []
            def run_once(model, name, args, channels):
                calls.append((args.segment_channel, args.z_project, name))
                return dict(width=8, height=6, cells=[], image_stats={})
            args = argparse.Namespace(model=model_name, segment_channel=None, z_project='max')
            requests = [dict(id=1, image='one.tif', segment_channel=2, z_project='sum'),
                        dict(id=2, image='two.tif', segment_channel=None, z_project='none')]
            package = types.ModuleType('cellpose')
            package.models = object()
            output = io.StringIO()
            with patch.dict(sys.modules, {'cellpose': package, 'torch': object()}), \
                 patch.object(module, 'build_model', return_value=(object(), None)) as build, \
                 patch.object(module, 'run_detection_once', side_effect=run_once), \
                 patch.object(sys, 'stdin', io.StringIO('\n'.join(map(json.dumps, requests)))), \
                 contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                module.serve(args, [0, 0])
            frames = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual([frame['type'] for frame in frames], ['ready', 'result', 'result'])
            self.assertEqual(build.call_count, 1)
            self.assertEqual(calls, [(2, 'sum', model_name), (None, 'none', model_name)])

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



if __name__ == '__main__':
    unittest.main()
