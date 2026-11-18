"""Model-weight downloads: verified TLS, resumable `.cellcounter-part` files
(If-Range checked), size checks, stale-file cleanup, clean SIGTERM handling and
corrupt-checkpoint recovery.

Every download comes from an `http.server` on 127.0.0.1 started by the test.
Nothing touches the network or the real ~/.cellpose: HOME and
CELLPOSE_LOCAL_MODELS_PATH point at temporary folders, also for the
subprocesses. The tests at the end that use a real Cellpose/PyTorch run only
when those are installed (not in CI) and stay on the CPU.
"""

from __future__ import annotations

import contextlib
import fcntl
import http.server
import importlib.util
import io
import json
import os
import pickle
import random
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve()
PYTHON_DIR = HERE.parents[1]
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import _cellpose_common as cc  # noqa: E402
import _model_downloads as md  # noqa: E402

MIB = 1024 * 1024
PART = ".cellcounter-part"  # CellCounter's partial-download suffix
VALIDATOR = PART + ".validator"
DAY = 24 * 3600


# ---------------------------------------------------------------------------
# A local weights server: Range/If-Range support and early closes on demand.
# ---------------------------------------------------------------------------

class _WeightsHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep test output clean
        pass

    def do_GET(self):
        server = self.server
        with server.lock:
            server.requests.append({"path": self.path, "range": self.headers.get("Range"),
                                    "if_range": self.headers.get("If-Range")})
            cut = server.cuts.pop(0) if server.cuts else None
        payload = server.payload
        start, status = 0, 200
        requested = self.headers.get("Range")
        if_range = self.headers.get("If-Range")
        # If-Range: a range only of the same version, otherwise the whole file.
        same_version = if_range is None or if_range == server.etag
        if requested and server.ranges and same_version:
            first = int(requested.split("=", 1)[1].split("-", 1)[0])
            if first >= len(payload):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(payload)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                server.sent.append(0)
                return
            start, status = first, 206
        body = payload[start:]
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        if server.declare_length:
            self.send_header("Content-Length", str(len(body)))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{len(payload) - 1}/{len(payload)}")
        if server.etag is not None:
            self.send_header("ETag", server.etag)
        self.end_headers()
        limit = len(body) if cut is None else min(cut, len(body))
        sent = 0
        try:
            while sent < limit:
                piece = body[sent:min(limit, sent + server.chunk)]
                self.wfile.write(piece)
                sent += len(piece)
                if server.delay:
                    time.sleep(server.delay)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            server.sent.append(sent)
        if cut is not None:
            # An early close: fewer bytes than Content-Length announced.
            self.close_connection = True
            with contextlib.suppress(OSError):
                self.connection.shutdown(socket.SHUT_RDWR)


def _installed(name):
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def _openssl():
    return shutil.which("openssl") or ("/usr/bin/openssl" if os.path.exists("/usr/bin/openssl") else None)


class DownloadTestCase(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="cc-download-test-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.models = self.root / "models"
        self.models.mkdir()
        (self.root / "home").mkdir()
        self.env = {"CELLPOSE_LOCAL_MODELS_PATH": str(self.models), "HOME": str(self.root / "home"),
                    "no_proxy": "*", "NO_PROXY": "*", "PYTHONDONTWRITEBYTECODE": "1"}
        patcher = mock.patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.logs = []

    def log(self, message):
        self.logs.append(message)

    @staticmethod
    def payload(size, seed=1):
        return random.Random(seed).randbytes(size)

    def start_server(self, payload, *, ranges=True, cuts=(), delay=0.0, chunk=64 * 1024,
                     declare_length=True, tls=None, etag=None):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _WeightsHandler)
        server.daemon_threads = True
        server.payload, server.ranges, server.cuts, server.etag = payload, ranges, list(cuts), etag
        server.delay, server.chunk, server.declare_length = delay, chunk, declare_length
        server.requests, server.sent, server.lock = [], [], threading.Lock()
        if tls is not None:
            server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        scheme = "https" if tls is not None else "http"
        return server, f"{scheme}://127.0.0.1:{server.server_address[1]}"

    def download(self, base, name, **kwargs):
        kwargs.setdefault("log", self.log)
        return md.download_url_to_file(f"{base}/{name}", self.models / name, **kwargs)

    def listing(self):
        return sorted(path.name for path in self.models.iterdir())

    def write_script(self, name, source):
        path = self.root / name
        path.write_text(f"import sys\nsys.path.insert(0, {str(PYTHON_DIR)!r})\n" + source)
        return path

    def spawn(self, script, **kwargs):
        stderr_path = self.root / (script.stem + ".stderr")
        stderr = open(stderr_path, "w")
        self.addCleanup(stderr.close)
        process = subprocess.Popen([sys.executable, "-I", "-B", str(script)], env=dict(os.environ),
                                   stderr=stderr, **kwargs)

        def stop():
            if process.poll() is None:
                process.kill()
                process.wait(10)
            for pipe in (process.stdin, process.stdout):
                if pipe is not None:
                    with contextlib.suppress(OSError):
                        pipe.close()

        self.addCleanup(stop)
        return process, stderr_path

    @staticmethod
    def wait_for(condition, timeout=20.0, message="condition"):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        raise AssertionError(f"timed out waiting for {message}")


# ---------------------------------------------------------------------------
# The download itself.
# ---------------------------------------------------------------------------

class VerifiedDownloadTests(DownloadTestCase):
    def test_a_full_download_is_verified_and_moved_into_place(self):
        data = self.payload(3 * MIB + 17)
        server, base = self.start_server(data)
        self.download(base, "cyto2torch_0")
        self.assertEqual((self.models / "cyto2torch_0").read_bytes(), data)
        self.assertEqual(self.listing(), ["cyto2torch_0"])  # no partial file, no tmp file
        self.assertIsNone(server.requests[0]["range"])
        self.assertIn("downloaded weights: 3.0 / 3.0 MB (100%)", self.logs)

    def test_a_truncated_stream_keeps_the_part_file_and_no_final_file(self):
        data = self.payload(2 * MIB)
        server, base = self.start_server(data, cuts=[700_000])
        with self.assertRaisesRegex(md.IncompleteDownloadError, "resumes where it stopped"):
            self.download(base, "nucleitorch_0")
        self.assertEqual(self.listing(), ["nucleitorch_0" + PART])  # no ETag: no validator
        kept = (self.models / ("nucleitorch_0" + PART)).read_bytes()
        self.assertTrue(0 < len(kept) < len(data))
        self.assertEqual(kept, data[:len(kept)])

    def test_a_retry_resumes_with_a_range_request_and_completes(self):
        data = self.payload(2 * MIB + 5)
        server, base = self.start_server(data, cuts=[900_000])
        with self.assertRaises(md.IncompleteDownloadError):
            self.download(base, "cyto2torch_0")
        kept = (self.models / ("cyto2torch_0" + PART)).stat().st_size
        self.download(base, "cyto2torch_0")
        self.assertEqual((self.models / "cyto2torch_0").read_bytes(), data)
        self.assertEqual(self.listing(), ["cyto2torch_0"])
        self.assertEqual(server.requests[1]["range"], f"bytes={kept}-")
        self.assertIsNone(server.requests[1]["if_range"])  # the server named no version
        self.assertEqual(server.sent[1], len(data) - kept)  # only the remainder was sent
        self.assertTrue(any(line.startswith("resuming the cyto2torch_0 download at") for line in self.logs))

    def test_a_server_without_range_support_restarts_cleanly(self):
        data = self.payload(2 * MIB)
        server, base = self.start_server(data, ranges=False, cuts=[600_000])
        with self.assertRaises(md.IncompleteDownloadError):
            self.download(base, "cyto2torch_0")
        kept = (self.models / ("cyto2torch_0" + PART)).stat().st_size
        self.download(base, "cyto2torch_0")
        self.assertEqual((self.models / "cyto2torch_0").read_bytes(), data)
        self.assertEqual(server.requests[1]["range"], f"bytes={kept}-")
        self.assertEqual(server.sent[1], len(data))  # a 200: the whole file again
        self.assertIn("the server cannot resume the cyto2torch_0 download; starting again", self.logs)

    def test_a_complete_part_file_is_moved_into_place_without_a_request(self):
        data = self.payload(50_000)
        server, base = self.start_server(data)
        (self.models / ("cyto2torch_0" + PART)).write_bytes(data)
        self.download(base, "cyto2torch_0", expected_size=len(data))
        self.assertEqual((self.models / "cyto2torch_0").read_bytes(), data)
        self.assertEqual(server.requests, [])

    def test_a_size_other_than_the_pinned_size_is_refused(self):
        data = self.payload(MIB)
        server, base = self.start_server(data)
        with mock.patch.dict(md.PINNED_SIZES, {"cpsam": len(data) + 1}):
            with self.assertRaisesRegex(md.UnexpectedSizeError, f"expects {len(data) + 1} bytes"):
                self.download(base, "cpsam")
        self.assertEqual(self.listing(), [])  # refused on the headers: nothing written or kept

    def test_the_pinned_size_decides_when_the_server_declares_none(self):
        data = self.payload(400_000)
        server, base = self.start_server(data, declare_length=False)
        with mock.patch.dict(md.PINNED_SIZES, {"cpsam": len(data) + 10}):
            with self.assertRaisesRegex(md.IncompleteDownloadError, "resumes"):
                self.download(base, "cpsam")
        self.assertEqual(self.listing(), ["cpsam" + PART])
        (self.models / ("cpsam" + PART)).unlink()
        with mock.patch.dict(md.PINNED_SIZES, {"cpsam": len(data)}):
            self.download(base, "cpsam")
        self.assertEqual((self.models / "cpsam").read_bytes(), data)

    def test_a_stalled_server_is_bounded_by_the_read_timeout(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.addCleanup(listener.close)
        port = listener.getsockname()[1]
        started = time.monotonic()
        with self.assertRaisesRegex(md.ModelDownloadError, "internet connection"):
            md.download_url_to_file(f"http://127.0.0.1:{port}/cyto2torch_0", self.models / "cyto2torch_0",
                                    timeout=0.5, log=self.log)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(self.listing(), [])

    def test_the_default_read_timeout_is_thirty_seconds(self):
        seen = []

        class Opener:
            def open(self, request, timeout=None):
                seen.append(timeout)
                raise urllib.error.URLError("offline")

        with self.assertRaises(md.ModelDownloadError):
            md.download_url_to_file("https://weights.invalid/cyto2torch_0", self.models / "cyto2torch_0",
                                    opener=Opener(), log=self.log)
        self.assertEqual(seen, [30])

    def test_a_second_worker_waits_and_reuses_the_first_download(self):
        data = self.payload(MIB)
        server, base = self.start_server(data, delay=0.02, chunk=32 * 1024)
        errors = []

        def first():
            try:
                self.download(base, "cyto2torch_0", chunk_bytes=32 * 1024)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)

        thread = threading.Thread(target=first)
        thread.start()
        self.wait_for(lambda: (self.models / ("cyto2torch_0" + PART)).exists()
                      and (self.models / ("cyto2torch_0" + PART)).stat().st_size > 0, message="first download")
        self.download(base, "cyto2torch_0")  # blocks on the lock, then finds the file
        thread.join(10)
        self.assertEqual(errors, [])
        self.assertEqual(len(server.requests), 1)
        self.assertEqual((self.models / "cyto2torch_0").read_bytes(), data)
        self.assertIn("another CellCounter worker is downloading cyto2torch_0; waiting for it", self.logs)

    def test_a_resume_asks_for_the_same_file_version_with_if_range(self):
        data = self.payload(2 * MIB)
        server, base = self.start_server(data, cuts=[700_000], etag='"v1"')
        with self.assertRaises(md.IncompleteDownloadError):
            self.download(base, "cyto3")
        self.assertEqual(self.listing(), ["cyto3" + PART, "cyto3" + VALIDATOR])
        self.assertEqual((self.models / ("cyto3" + VALIDATOR)).read_text(), '"v1"')
        kept = (self.models / ("cyto3" + PART)).stat().st_size
        self.download(base, "cyto3")
        self.assertEqual(server.requests[1]["range"], f"bytes={kept}-")
        self.assertEqual(server.requests[1]["if_range"], '"v1"')
        self.assertEqual(server.sent[1], len(data) - kept)  # a 206: only the remainder
        self.assertEqual((self.models / "cyto3").read_bytes(), data)
        self.assertEqual(self.listing(), ["cyto3"])  # the validator goes with the partial file

    def test_a_file_republished_between_attempts_is_downloaded_again_not_spliced(self):
        old, new = self.payload(2 * MIB, seed=1), self.payload(2 * MIB + 100, seed=2)
        server, base = self.start_server(old, cuts=[700_000], etag='"v1"')
        with self.assertRaises(md.IncompleteDownloadError):
            self.download(base, "cyto3")
        server.payload, server.etag = new, '"v2"'
        self.download(base, "cyto3")
        self.assertEqual(server.requests[1]["if_range"], '"v1"')
        self.assertEqual(server.sent[1], len(new))  # a 200: the whole new version
        self.assertEqual((self.models / "cyto3").read_bytes(), new)
        self.assertEqual(self.listing(), ["cyto3"])
        self.assertIn("the server cannot resume the cyto3 download; starting again", self.logs)

    def test_plain_http_is_upgraded_except_on_this_machine(self):
        self.assertEqual(md._secure_url("http://127.0.0.1:9/x", self.log), "http://127.0.0.1:9/x")
        self.assertEqual(md._secure_url("http://www.cellpose.org/models/cyto3", self.log),
                         "https://www.cellpose.org/models/cyto3")
        with self.assertRaises(md.ModelDownloadError):
            md._secure_url("ftp://example.org/cyto3", self.log)


# ---------------------------------------------------------------------------
# TLS.
# ---------------------------------------------------------------------------

class CertificateTests(DownloadTestCase):
    def server_tls(self):
        openssl = _openssl()
        if openssl is None:
            self.skipTest("openssl is not available to create a self-signed certificate")
        key, cert = self.root / "key.pem", self.root / "cert.pem"
        subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(cert)],
                       check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(cert), str(key))
        return context

    def test_a_self_signed_certificate_fails_with_a_clear_error(self):
        server, base = self.start_server(b"w" * 10_000, tls=self.server_tls())
        with self.assertRaisesRegex(md.CertificateVerificationError,
                                    "HTTPS certificate of 127.0.0.1 could not be verified"):
            self.download(base, "cyto2torch_0")
        self.assertEqual(server.requests, [])  # refused during the handshake
        self.assertEqual(self.listing(), [])

    def test_the_certificate_failure_reaches_the_sidecar_message(self):
        server, base = self.start_server(b"w" * 10_000, tls=self.server_tls())
        utils = types.ModuleType("cellpose.utils")
        utils.download_url_to_file = lambda *args, **kwargs: None
        package = types.ModuleType("cellpose")
        package.utils = utils
        with mock.patch.dict(sys.modules, {"cellpose": package}), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(cc.ModelDownloadError,
                                        r"^Could not download the cpsam model weights\. The HTTPS certificate"):
                with cc.model_loading_progress():
                    utils.download_url_to_file(f"{base}/cpsam", str(self.models / "cpsam"))

    def test_client_contexts_always_verify(self):
        context = md.make_ssl_context()
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_cellposes_unverified_default_is_restored(self):
        utils = types.ModuleType("cellpose.utils")
        utils.download_url_to_file = lambda *args, **kwargs: None
        package = types.ModuleType("cellpose")
        package.utils = utils
        with mock.patch.object(ssl, "_create_default_https_context", ssl._create_unverified_context), \
                mock.patch.dict(sys.modules, {"cellpose": package}), contextlib.redirect_stderr(io.StringIO()):
            with cc.model_loading_progress():
                self.assertIs(ssl._create_default_https_context, ssl.create_default_context)

    def test_an_https_to_http_redirect_is_refused(self):
        handler = md._NoDowngradeRedirect()
        request = urllib.request.Request("https://huggingface.co/mouseland/cellpose-sam/resolve/main/cpsam")
        with self.assertRaisesRegex(md.ModelDownloadError, "insecure address"):
            handler.redirect_request(request, None, 302, "Found", {}, "http://cdn.example/cpsam")
        allowed = handler.redirect_request(request, None, 302, "Found", {}, "https://cdn.example/cpsam")
        self.assertEqual(allowed.full_url, "https://cdn.example/cpsam")


# ---------------------------------------------------------------------------
# Stale files.
# ---------------------------------------------------------------------------

class CleanupTests(DownloadTestCase):
    def make(self, name, age_seconds, data=b"x"):
        path = self.models / name
        path.write_bytes(data)
        moment = time.time() - age_seconds
        os.utime(path, (moment, moment))
        return path

    def hold_lock(self, path):
        holder = os.open(path, os.O_WRONLY)
        self.addCleanup(os.close, holder)
        fcntl.flock(holder, fcntl.LOCK_EX)

    def test_only_old_temp_files_and_cellcounters_own_stale_downloads_are_removed(self):
        old = 11 * 60
        moved_recently = "cyto3.corrupt-" + time.strftime("%Y%m%d-%H%M%S", time.localtime(time.time() - 6 * DAY))
        self.make("tmpab_12xyz", old, b"z" * 5000)          # Cellpose's tempfile, abandoned
        self.make("tmp0a1b2c3d", 9 * 60)                    # possibly a live download
        for keep in ("tmpABCDEFGH", "tmpabc1234", "tmpabc123456", "tmpabcd1234.npy", "xtmpabcd1234",
                     "cyto3", "gui_models.txt", "notes.txt", "cyto3.corrupt-backup",
                     moved_recently,                         # moved aside 6 days ago (the name says so)
                     "other-app.part", "video.mp4.part"):    # other software in a shared folder
            self.make(keep, 30 * DAY)
        self.make("cyto3.corrupt-20200101-000000", 0)       # moved aside long ago; mtime is irrelevant
        self.make("cpsam" + PART, 8 * DAY)                  # abandoned partial download
        self.make("cpsam" + VALIDATOR, 8 * DAY, b'"etag"')  # ... and its validator
        self.make("nucleitorch_0" + PART, 6 * DAY)          # recent enough to resume
        self.make("nucleitorch_0" + VALIDATOR, 6 * DAY)
        self.make("cyto2_cp3" + VALIDATOR, old)             # its partial file is gone
        locked = self.make("cyto2torch_0" + PART, 8 * DAY)  # a worker holds its lock
        self.hold_lock(locked)
        folder = self.models / "tmpdir_0000"
        folder.mkdir()
        os.utime(folder, (time.time() - old,) * 2)
        target = self.root / "elsewhere"
        target.write_bytes(b"y")
        os.symlink(target, self.models / "tmplink0000")
        os.utime(self.models / "tmplink0000", (time.time() - old,) * 2, follow_symlinks=False)

        removed = md.cleanup_stale_files(self.models, log=self.log)

        self.assertEqual(sorted(removed), sorted(["cpsam" + PART, "tmpab_12xyz", "cyto3.corrupt-20200101-000000",
                                                  "cyto2_cp3" + VALIDATOR]))
        self.assertEqual(self.listing(), sorted([
            "tmp0a1b2c3d", "tmpABCDEFGH", "tmpabc1234", "tmpabc123456", "tmpabcd1234.npy", "xtmpabcd1234",
            "cyto3", "gui_models.txt", "notes.txt", "cyto3.corrupt-backup", moved_recently,
            "other-app.part", "video.mp4.part", "nucleitorch_0" + PART, "nucleitorch_0" + VALIDATOR,
            "cyto2torch_0" + PART, "tmpdir_0000", "tmplink0000"]))
        self.assertTrue(target.exists())
        self.assertTrue(any("removed stale temporary download tmpab_12xyz" in line for line in self.logs))
        self.assertTrue(any(f"removed stale partial download cpsam{PART} " in line for line in self.logs))
        self.assertTrue(any("removed stale damaged copy cyto3.corrupt-20200101-000000" in line
                            for line in self.logs))

    def test_partial_files_of_older_versions_are_removed_only_for_cellpose_weights(self):
        (self.models / "gui_models.txt").write_text("labtorch_0\n")
        for name in ("cyto3", "nucleitorch_0", "size_cyto3.npy", "tissuenet_cp3"):
            self.make(name + ".part", DAY)
        self.make("labtorch_0.part", 30 * DAY)              # the user's own model (gui_models.txt)
        self.make("firmware.part", 30 * DAY)                # another program's download
        self.make("cpsam.part", 60)                         # changed a minute ago
        self.hold_lock(self.make("cyto2torch_0.part", DAY))  # a worker holds its lock
        imported = types.SimpleNamespace(MODEL_NAMES=["cyto3", "tissuenet_cp3"])
        with mock.patch.dict(sys.modules, {"cellpose.models": imported}):
            removed = md.cleanup_stale_files(self.models, log=self.log)
        self.assertEqual(sorted(removed), ["cyto3.part", "nucleitorch_0.part", "size_cyto3.npy.part",
                                           "tissuenet_cp3.part"])
        self.assertEqual(self.listing(), ["cpsam.part", "cyto2torch_0.part", "firmware.part",
                                          "gui_models.txt", "labtorch_0.part"])
        self.assertTrue(any("removed stale partial download of an older CellCounter cyto3.part" in line
                            for line in self.logs))

    def test_a_stale_part_is_unlinked_while_its_lock_is_held(self):
        part = self.make("cpsam" + PART, 8 * DAY)
        self.make("cpsam" + VALIDATOR, 8 * DAY)
        seen = []
        real_unlink = os.unlink

        def probing_unlink(path, *args, **kwargs):
            if os.fspath(path) == str(part):
                probe = os.open(path, os.O_RDONLY)
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    seen.append("unlocked")  # a worker could have locked and resumed it now
                except BlockingIOError:
                    seen.append("locked")
                finally:
                    os.close(probe)
            return real_unlink(path, *args, **kwargs)

        with mock.patch.object(os, "unlink", probing_unlink):
            removed = md.cleanup_stale_files(self.models, log=self.log)
        self.assertEqual(removed, ["cpsam" + PART])
        self.assertEqual(seen, ["locked"])
        self.assertEqual(self.listing(), [])  # the validator went with it

    def test_a_part_replaced_while_cleanup_probes_it_is_left_alone(self):
        part = self.make("cpsam" + PART, 8 * DAY)
        fresh = self.root / "fresh"
        fresh.write_bytes(b"a new download")
        real_flock = fcntl.flock

        def replacing_flock(fd, operation):
            if fresh.exists():
                os.replace(fresh, part)  # a worker started again under the same name
            return real_flock(fd, operation)

        with mock.patch.object(fcntl, "flock", replacing_flock):
            removed = md.cleanup_stale_files(self.models, log=self.log)
        self.assertEqual(removed, [])
        self.assertEqual(part.read_bytes(), b"a new download")

    def test_only_the_newest_damaged_copy_is_kept(self):
        weights = self.models / "cyto3"
        self.make("cyto3.corrupt-20240101-000000", 0, b"a" * 100)
        self.make("nucleitorch_0.corrupt-20240101-000000", 0)  # another file's copy
        weights.write_bytes(b"b" * 100)
        first = md.quarantine(weights, "test", log=self.log)
        weights.write_bytes(b"c" * 100)
        second = md.quarantine(weights, "test", log=self.log)
        self.assertNotEqual(first, second)
        self.assertEqual(self.listing(), sorted([os.path.basename(second), "nucleitorch_0.corrupt-20240101-000000"]))
        self.assertEqual(Path(second).read_bytes(), b"c" * 100)
        for gone in ("cyto3.corrupt-20240101-000000", os.path.basename(first)):
            self.assertTrue(any(f"removed the older damaged copy {gone} " in line for line in self.logs), gone)

    def test_a_missing_folder_is_left_missing(self):
        absent = self.root / "absent"
        self.assertEqual(md.cleanup_stale_files(absent, log=self.log), [])
        self.assertFalse(absent.exists())

    def test_model_loading_cleans_the_folder_cellpose_uses(self):
        other = self.root / "configured"
        other.mkdir()
        stale = other / "tmpq1w2e3r4"
        stale.write_bytes(b"x")
        os.utime(stale, (time.time() - 3600,) * 2)
        package = types.ModuleType("cellpose")
        package.utils = types.SimpleNamespace(download_url_to_file=lambda *a, **k: None)
        package.models = types.SimpleNamespace(MODEL_DIR=other)  # wins over the environment
        with mock.patch.dict(sys.modules, {"cellpose": package}), contextlib.redirect_stderr(io.StringIO()):
            with cc.model_loading_progress() as directory:
                self.assertEqual(directory, os.fspath(other))
        self.assertFalse(stale.exists())

    def test_pinned_files_of_the_wrong_size_are_moved_aside_before_construction(self):
        (self.models / "cyto3").write_bytes(b"x" * 1000)
        (self.models / "cpsam").write_bytes(b"y" * 4000)
        os.symlink(self.root / "home", self.models / "linked")
        pins = {"cyto3": 5000, "cpsam": 4000, "linked": 1}
        moved = md.quarantine_mismatched_pinned_weights(self.models, log=self.log, pins=pins)
        self.assertEqual(len(moved), 1)
        self.assertTrue(os.path.basename(moved[0]).startswith("cyto3.corrupt-"))
        self.assertEqual(Path(moved[0]).read_bytes(), b"x" * 1000)
        self.assertEqual((self.models / "cpsam").read_bytes(), b"y" * 4000)
        self.assertTrue((self.models / "linked").is_symlink())


# ---------------------------------------------------------------------------
# SIGTERM.
# ---------------------------------------------------------------------------

class TerminationTests(DownloadTestCase):
    def test_sigterm_during_a_download_leaves_only_the_part_file(self):
        data = self.payload(4 * MIB)
        server, base = self.start_server(data, delay=0.05, chunk=32 * 1024)
        script = self.write_script("download_child.py", f"""
import _cellpose_common as cc
import _model_downloads as md
cc.run_sidecar(lambda: md.download_url_to_file({base + '/cyto2torch_0'!r},
                                               {str(self.models / 'cyto2torch_0')!r},
                                               chunk_bytes=32 * 1024))
""")
        child, _ = self.spawn(script)
        part = self.models / ("cyto2torch_0" + PART)
        self.wait_for(lambda: part.exists() and part.stat().st_size >= 64 * 1024, message="download start")
        sent = time.monotonic()
        child.send_signal(signal.SIGTERM)
        child.wait(timeout=10)
        self.assertLess(time.monotonic() - sent, 2.0)
        self.assertEqual(child.returncode, -signal.SIGTERM)  # the status the host already handles
        self.assertEqual(self.listing(), ["cyto2torch_0" + PART])
        kept = part.stat().st_size
        self.assertEqual(part.read_bytes(), data[:kept])

        server.delay = 0
        self.download(base, "cyto2torch_0")
        self.assertEqual((self.models / "cyto2torch_0").read_bytes(), data)
        self.assertEqual(server.requests[-1]["range"], f"bytes={kept}-")

    SERVE_CHILD = """
import time
import _cellpose_common as cc

def run_once(argv):
    print("[test] request started", file=sys.stderr, flush=True)
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            time.sleep(0.01)
    finally:
        print("[test] cleanup ran", file=sys.stderr, flush=True)
    print("{}")

print("[test] ready", file=sys.stderr, flush=True)
cc.run_sidecar(lambda: cc.serve_ndjson(run_once))
"""

    def test_a_busy_served_worker_stops_without_answering(self):
        script = self.write_script("serve_child.py", self.SERVE_CHILD)
        child, stderr = self.spawn(script, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        child.stdin.write(json.dumps({"request_id": "r1", "args": []}).encode() + b"\n")
        child.stdin.flush()
        self.wait_for(lambda: "request started" in stderr.read_text(), message="request start")
        sent = time.monotonic()
        child.send_signal(signal.SIGTERM)
        output = child.stdout.read()
        child.wait(timeout=10)
        self.assertLess(time.monotonic() - sent, 2.0)
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertEqual(output, b"")  # no response: the loop did not swallow the stop
        self.assertIn("cleanup ran", stderr.read_text())

    def test_an_idle_served_worker_stops_promptly(self):
        script = self.write_script("idle_child.py", self.SERVE_CHILD)
        child, stderr = self.spawn(script, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.wait_for(lambda: "ready" in stderr.read_text(), message="worker start")
        time.sleep(0.2)  # now blocked reading stdin
        sent = time.monotonic()
        child.send_signal(signal.SIGTERM)
        child.wait(timeout=10)
        self.assertLess(time.monotonic() - sent, 2.0)
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertEqual(child.stdout.read(), b"")

    def test_a_swallowed_stop_still_ends_the_process(self):
        script = self.write_script("swallow_child.py", """
import time
import _cellpose_common as cc

def stubborn():
    print("[test] ready", file=sys.stderr, flush=True)
    while True:  # a library that catches everything, SystemExit included
        try:
            time.sleep(0.05)
        except BaseException:
            pass

cc.run_sidecar(stubborn)
""")
        child, stderr = self.spawn(script)
        self.wait_for(lambda: "ready" in stderr.read_text(), message="worker start")
        sent = time.monotonic()
        child.send_signal(signal.SIGTERM)
        child.wait(timeout=15)
        elapsed = time.monotonic() - sent
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertLess(elapsed, cc.TERMINATION_GRACE_SECONDS + 2)

    def test_ordinary_exit_codes_pass_through(self):
        script = self.write_script("exit_child.py", """
import _cellpose_common as cc
cc.run_sidecar(lambda: sys.exit(4))
""")
        child, _ = self.spawn(script)
        self.assertEqual(child.wait(timeout=20), 4)


# ---------------------------------------------------------------------------
# Corrupt checkpoints.
# ---------------------------------------------------------------------------

CORRUPT = "PytorchStreamReader failed reading zip archive: failed finding central directory"


class RecoveryTests(DownloadTestCase):
    def fake_cellpose(self, base, good):
        """A stand-in that downloads like Cellpose (`utils.download_url_to_file`) and loads like torch."""
        package = types.ModuleType("cellpose")
        utils = types.ModuleType("cellpose.utils")
        models = types.ModuleType("cellpose.models")

        def cellposes_own(*args, **kwargs):
            raise AssertionError("Cellpose's own downloader must not run")

        utils.download_url_to_file = cellposes_own
        models.MODEL_DIR = self.models
        models.MODEL_NAMES = ["cyto3", "nuclei", "cyto2"]
        package.utils, package.models = utils, models
        loads = []

        def load(name):
            path = self.models / name
            if not path.exists():
                utils.download_url_to_file(f"{base}/{name}", str(path), progress=True)
            data = path.read_bytes()
            loads.append(data)
            if data != good:
                raise RuntimeError(CORRUPT)
            return "model"

        return package, cellposes_own, load, loads

    @contextlib.contextmanager
    def cellpose(self, package):
        with mock.patch.dict(sys.modules, {"cellpose": package, "cellpose.utils": package.utils,
                                           "cellpose.models": package.models}), \
                contextlib.redirect_stderr(io.StringIO()) as logs:
            yield logs

    def managed(self, package, name):
        return cc.managed_cellpose_weights(package.models, name, default="cyto3",
                                           torch_suffixed=("cyto", "cyto2", "nuclei"))

    def test_corrupt_weights_are_moved_aside_and_downloaded_once(self):
        good = self.payload(300_000)
        server, base = self.start_server(good)
        (self.models / "nucleitorch_0").write_bytes(b"\0" * 1000)
        package, original, load, loads = self.fake_cellpose(base, good)
        with self.cellpose(package) as logs:
            with cc.model_loading_progress() as directory:
                result = cc.build_with_weight_recovery(
                    lambda: load("nucleitorch_0"), self.managed(package, "nuclei"), directory)
        self.assertEqual(result, "model")
        self.assertIs(package.utils.download_url_to_file, original)
        self.assertEqual(len(server.requests), 1)
        self.assertEqual((self.models / "nucleitorch_0").read_bytes(), good)
        aside = [name for name in self.listing() if name.startswith("nucleitorch_0.corrupt-")]
        self.assertEqual(len(aside), 1)
        self.assertEqual((self.models / aside[0]).read_bytes(), b"\0" * 1000)
        self.assertIn("moved the damaged nucleitorch_0 weights aside", logs.getvalue())
        self.assertIn("weights ready: nucleitorch_0", logs.getvalue())

    def test_a_second_failure_is_reported_after_exactly_one_download(self):
        bad = b"\1" * 2000
        server, base = self.start_server(bad)
        (self.models / "nucleitorch_0").write_bytes(b"\0" * 1000)
        package, _, load, loads = self.fake_cellpose(base, good=b"never")
        with self.cellpose(package):
            with self.assertRaisesRegex(cc.WeightsUnusableError, "downloaded the nucleitorch_0 model weights again"):
                with cc.model_loading_progress() as directory:
                    cc.build_with_weight_recovery(lambda: load("nucleitorch_0"),
                                                  self.managed(package, "nuclei"), directory)
            self.assertEqual(len(server.requests), 1)
            # Retrying soon after does not download the same file yet again.
            with self.assertRaisesRegex(cc.WeightsUnusableError, "less than an hour ago"):
                with cc.model_loading_progress() as directory:
                    cc.build_with_weight_recovery(lambda: load("nucleitorch_0"),
                                                  self.managed(package, "nuclei"), directory)
        self.assertEqual(len(server.requests), 1)
        self.assertEqual((self.models / "nucleitorch_0").read_bytes(), bad)

    def test_a_users_own_model_is_never_moved_aside(self):
        server, base = self.start_server(b"unused")
        package, _, load, _ = self.fake_cellpose(base, good=b"never")
        (self.models / "gui_models.txt").write_text("my_model\n")
        (self.models / "my_model").write_bytes(b"\0" * 100)
        custom = self.root / "lab_checkpoint"
        custom.write_bytes(b"\0" * 100)
        self.assertEqual(self.managed(package, "my_model"), [])
        self.assertEqual(self.managed(package, str(custom)), [])
        with self.cellpose(package):
            with self.assertRaisesRegex(RuntimeError, "PytorchStreamReader"):
                with cc.model_loading_progress() as directory:
                    cc.build_with_weight_recovery(lambda: load("my_model"),
                                                  self.managed(package, "my_model"), directory)
        self.assertEqual(sorted(self.listing()), ["gui_models.txt", "my_model"])
        self.assertEqual(server.requests, [])

    def test_errors_that_are_not_corruption_leave_the_weights_alone(self):
        (self.models / "cyto3").write_bytes(b"\0" * 10)

        def build():
            raise RuntimeError("Error(s) in loading state_dict for CPnet: size mismatch for output.2.weight")

        with mock.patch.dict(md.PINNED_SIZES, clear=True), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "size mismatch"):
                cc.build_with_weight_recovery(build, ["cyto3"], str(self.models))
        self.assertEqual(self.listing(), ["cyto3"])

    def test_unknown_names_fall_back_like_cellpose(self):
        package, _, _, _ = self.fake_cellpose("http://127.0.0.1:9", b"")
        self.assertEqual(self.managed(package, "cyto3"), ["cyto3"])
        self.assertEqual(self.managed(package, "cyto2"), ["cyto2torch_0"])
        self.assertEqual(self.managed(package, "not-a-model"), ["cyto3"])
        self.assertEqual(cc.managed_cellpose_weights(types.SimpleNamespace(MODEL_NAMES=["cpsam"]),
                                                     "cpdino", default="cpsam"), ["cpsam"])

    def test_typical_checkpoint_errors_are_recognised(self):
        for error in (EOFError("Ran out of input"), pickle.UnpicklingError("invalid load key, '\\x00'."),
                      zipfile.BadZipFile("File is not a zip file"), RuntimeError(CORRUPT),
                      RuntimeError("PytorchStreamReader failed reading file data/0: invalid header "
                                   "or archive is corrupted")):
            with self.subTest(error=error):
                self.assertTrue(md.is_corrupt_checkpoint_error(error))
        try:
            try:
                raise EOFError("Ran out of input")
            except EOFError as cause:
                raise ValueError("while loading the model") from cause
        except ValueError as wrapped:
            self.assertTrue(md.is_corrupt_checkpoint_error(wrapped))
        for error in (RuntimeError("MPS backend out of memory"), FileNotFoundError("model file not recognized"),
                      md.ModelDownloadError("Ran out of input")):
            with self.subTest(error=error):
                self.assertFalse(md.is_corrupt_checkpoint_error(error))

    @unittest.skipUnless(_installed("numpy"), "NumPy is not installed")
    def test_training_ignores_partial_and_damaged_copies(self):
        import cellpose_train
        self.assertIs(cellpose_train.is_download_artifact, md.is_download_artifact)
        for name in ("cyto3" + PART, "cyto3" + VALIDATOR, "cyto3.part", "cyto3.corrupt-20240101-000000",
                     "tmpabcd1234"):
            self.assertTrue(md.is_download_artifact(name))
        for name in ("cyto3", "nucleitorch_0", "size_cyto3.npy"):
            self.assertFalse(md.is_download_artifact(name))


# ---------------------------------------------------------------------------
# The sidecar end to end (stand-in framework, real sidecar code).
# ---------------------------------------------------------------------------

@unittest.skipUnless(_installed("numpy"), "NumPy is not installed")
class SidecarTests(DownloadTestCase):
    def test_cellpose4_reports_an_interrupted_download_and_resumes_on_retry(self):
        import numpy as np  # noqa: F401  (the sidecar needs it; CI installs it)
        import cellpose4_detect
        data = self.payload(MIB)
        server, base = self.start_server(data, cuts=[300_000])
        builds = []

        class Model:
            device = "cpu"
            net = None

            def __init__(self, gpu=False, pretrained_model=None, **kwargs):
                path = self.models_dir / "cpsam"
                if not path.exists():
                    sys.modules["cellpose.utils"].download_url_to_file(f"{base}/cpsam", str(path), progress=True)
                if path.read_bytes() != data:
                    raise RuntimeError(CORRUPT)
                builds.append(pretrained_model)

            def eval(self, image, **kwargs):
                return np.zeros(image.shape, dtype=np.int32), None, None

        Model.models_dir = self.models
        package = types.ModuleType("cellpose")
        package.version = "4.1.1"
        package.utils = types.ModuleType("cellpose.utils")
        package.utils.download_url_to_file = lambda *a, **k: None
        package.models = types.SimpleNamespace(CellposeModel=Model, MODEL_DIR=self.models, MODEL_NAMES=["cpsam"])
        torch = types.SimpleNamespace(__version__="fixture",
                                      backends=types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: False)),
                                      cuda=types.SimpleNamespace(is_available=lambda: False))
        argv = ["--image", "fixture.png", "--model", "cpsam", "--pxPerUm", "1"]
        source = np.zeros((8, 8), dtype=np.uint8)

        def run():
            output = io.StringIO()
            code = 0
            with mock.patch.dict(sys.modules, {"cellpose": package, "cellpose.utils": package.utils,
                                               "cellpose.models": package.models, "torch": torch}), \
                    mock.patch.dict(md.PINNED_SIZES, {"cpsam": len(data)}), \
                    mock.patch.object(cc, "open_image_for_detection", return_value=source), \
                    mock.patch.object(cc, "compute_qc_metrics", return_value={}), \
                    mock.patch.object(cc, "compute_colony_stats", return_value={}), \
                    mock.patch.object(cc, "measure_cells", return_value=[]), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                try:
                    cellpose4_detect.main(argv)
                except SystemExit as exc:
                    code = exc.code
            return code, output.getvalue()

        cellpose4_detect._MODEL_CACHE.clear()
        self.addCleanup(cellpose4_detect._MODEL_CACHE.clear)
        code, stdout = run()
        self.assertEqual(code, 4)
        error = json.loads(stdout)
        self.assertEqual(error["error"], "model-download-failed")
        self.assertRegex(error["hint"], r"^Could not download the cpsam model weights\. The cpsam download "
                                        r"stopped after .* retry and the download resumes")
        self.assertEqual(self.listing(), ["cpsam" + PART])

        code, stdout = run()
        self.assertEqual(code, 0, stdout)
        self.assertIn('"cells"', stdout)
        self.assertEqual(builds, ["cpsam"])
        self.assertEqual(server.requests[1]["range"], f"bytes={300_000}-")
        self.assertEqual(self.listing(), ["cpsam"])


# ---------------------------------------------------------------------------
# The installed Cellpose and PyTorch (skipped where they are absent, as in CI).
# ---------------------------------------------------------------------------

def _cellpose_major():
    if not _installed("cellpose"):
        return None
    try:
        import importlib.metadata as metadata
        return int(metadata.version("cellpose").split(".")[0])
    except Exception:  # noqa: BLE001
        return None


@unittest.skipUnless(_installed("torch"), "PyTorch is not installed")
class InstalledFrameworkTests(DownloadTestCase):
    def run_child(self, name, source, timeout=300):
        script = self.write_script(name, source)
        result = subprocess.run([sys.executable, "-I", "-B", str(script)], env=dict(os.environ),
                                capture_output=True, text=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        return result

    def test_real_torch_errors_for_a_truncated_checkpoint_are_recognised(self):
        checkpoint = self.root / "checkpoint.pt"
        result = self.run_child("torch_child.py", f"""
import json, os
import torch
import _model_downloads as md
path = {str(checkpoint)!r}
torch.save({{"weight": torch.zeros(256, 256)}}, path)
with open(path, "rb+") as handle:
    handle.truncate(os.path.getsize(path) // 2)
try:
    torch.load(path, map_location="cpu", weights_only=True)
except Exception as exc:
    print(json.dumps({{"recognised": md.is_corrupt_checkpoint_error(exc), "error": repr(exc)}}))
""")
        outcome = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertTrue(outcome["recognised"], outcome["error"])

    @unittest.skipUnless(_cellpose_major() in (3, 4), "Cellpose 3 or 4 is not installed")
    def test_cellposes_own_download_path_uses_the_verified_downloader(self):
        major = _cellpose_major()
        name = "cyto3" if major == 3 else "cpsam"
        data = self.payload(2 * MIB + 3)
        server, base = self.start_server(data)
        url_line = (f"models._MODEL_URL = {base!r}" if major == 3
                    else f"models._CPSAM_MODEL_URL = {base + '/cpsam'!r}")
        fetch = "models.cache_model_path('cyto3')" if major == 3 else "models.cache_CPSAM_model_path()"
        result = self.run_child("cellpose_child.py", f"""
import json, ssl
import _cellpose_common as cc
import _model_downloads as md
md.PINNED_SIZES.clear()  # the stand-in file is small
from cellpose import models, utils
original = utils.download_url_to_file
{url_line}
with cc.model_loading_progress() as directory:
    assert utils.download_url_to_file is not original
    path = {fetch}
assert utils.download_url_to_file is original
assert ssl._create_default_https_context is ssl.create_default_context
print(json.dumps({{"path": path, "directory": directory}}))
""")
        outcome = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(outcome["directory"], str(self.models))
        self.assertEqual(Path(outcome["path"]), self.models / name)
        self.assertEqual((self.models / name).read_bytes(), data)
        self.assertEqual(self.listing(), [name])
        self.assertIn(f"weights ready: {name}", result.stderr)
        self.assertEqual(len(server.requests), 1)

    @unittest.skipUnless(_cellpose_major() == 3, "Cellpose 3 is not installed")
    def test_cellpose3_recovers_from_a_truncated_cyto3_on_the_cpu(self):
        good_path = self.root / "cyto3-random-weights"
        # A valid Cellpose 3 checkpoint (random weights, cyto3's architecture).
        self.run_child("make_checkpoint.py", f"""
from cellpose import resnet_torch
net = resnet_torch.CPnet([2, 32, 64, 128, 256], 3, sz=3, mkldnn=False, max_pool=True, diam_mean=30.0)
net.save_model({str(good_path)!r})
""")
        good = good_path.read_bytes()
        server, base = self.start_server(good)
        (self.models / "cyto3").write_bytes(good[:len(good) // 3])  # an old truncated download
        result = self.run_child("recover_child.py", f"""
import json, os
import _cellpose_common as cc
import _model_downloads as md
md.PINNED_SIZES.clear()  # so the truncated file reaches torch instead of the size check
from cellpose import models
models._MODEL_URL = {base!r}
with cc.model_loading_progress() as directory:
    managed = cc.managed_cellpose_weights(models, "cyto3", default="cyto3",
                                          torch_suffixed=("cyto", "cyto2", "nuclei"))
    model = cc.build_with_weight_recovery(
        lambda: models.CellposeModel(gpu=False, model_type="cyto3"), managed, directory)
print(json.dumps({{"loaded": os.path.basename(str(model.pretrained_model)), "managed": managed}}))
""")
        outcome = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(outcome, {"loaded": "cyto3", "managed": ["cyto3"]})
        self.assertEqual((self.models / "cyto3").read_bytes(), good)
        aside = [name for name in self.listing() if name.startswith("cyto3.corrupt-")]
        self.assertEqual(len(aside), 1)
        self.assertEqual(len(server.requests), 1)
        self.assertIn("moved the damaged cyto3 weights aside", result.stderr)


if __name__ == "__main__":
    unittest.main()
