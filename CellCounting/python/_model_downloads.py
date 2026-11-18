"""
_model_downloads.py — verified, resumable model-weight downloads.

Cellpose 3.x and 4.x (and the `cellpose_omni` fork) fetch missing weights
through `utils.download_url_to_file(url, dst, progress=True)`. That helper:

  * turns off HTTPS certificate checks for the whole process
    (`ssl._create_default_https_context = ssl._create_unverified_context`),
    although the weights are torch files that are unpickled on load;
  * streams into a randomly named `tmpXXXXXXXX` file that only a Python
    `finally` removes, so a worker stopped with SIGTERM/SIGKILL leaves up to
    ~1.2 GB behind for good;
  * stops at the first empty read and moves the file into place without
    comparing it with Content-Length, so a dropped connection becomes a
    permanent, truncated `cpsam`/`cyto3` that Cellpose never downloads again.

`_cellpose_common.model_loading_progress` replaces it with
`download_url_to_file` below while a model is constructed. Guarantees:

  * TLS is always verified (system/OpenSSL defaults plus `certifi` when it is
    installed). There is no unverified fallback, an https→http redirect is
    refused, and a certificate failure is reported as such.
  * Bytes go to a deterministic `<dst>.cellcounter-part` (a suffix no other
    software uses, so housekeeping in a shared folder only ever touches
    CellCounter's own files), locked with `flock` so two workers never write
    the same file. A retry resumes with an HTTP Range request when the server
    answers 206 and restarts cleanly when it does not. When the first answer
    named the file version (ETag, else Last-Modified), it is kept in
    `<part>.validator` and sent as If-Range, so a file republished between two
    attempts is downloaded again instead of being spliced onto the old bytes.
  * The file is moved into place (fsync, then `os.replace`) only when its size
    equals the size the server declared — and, for the files listed in
    `PINNED_SIZES`, the size CellCounter expects. Otherwise the partial file
    stays for the next attempt and the error says that a retry resumes.

Housekeeping for the models folder: `cleanup_stale_files`,
`quarantine_mismatched_pinned_weights`, `quarantine` (keeps only the newest
moved-aside copy of a file), and `is_corrupt_checkpoint_error` (used by
`_cellpose_common` to recover from a damaged checkpoint).

Standard library only (`certifi` is used when importable).
"""

from __future__ import annotations

import errno
import fcntl
import ipaddress
import os
import pickle
import re
import shutil
import ssl
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from http import client as http_client


LOG_PREFIX = "[cellpose_detect] "

# Optional exact sizes of published files, in bytes. Empty on purpose: the
# server's Content-Length already proves a download complete, and damaged
# legacy files are caught when loading fails (`build_with_weight_recovery`).
# A pin would lock every user out the day upstream republishes a file.
# An entry here makes a server that offers a different size be refused, and a
# local file of another size be treated as damaged.
PINNED_SIZES: dict = {}

# CellCounter's partial downloads. Unique, so cleanup never deletes another
# program's `*.part` in a folder CELLPOSE_LOCAL_MODELS_PATH shares with it.
PART_SUFFIX = ".cellcounter-part"
# What older CellCounter versions used; such files are removed only for known
# Cellpose weight names (see `cleanup_stale_files`).
LEGACY_PART_SUFFIX = ".part"
# `<part>.validator`: the ETag/Last-Modified the partial file was downloaded at.
VALIDATOR_SUFFIX = ".validator"
CORRUPT_MARKER = ".corrupt-"
_CORRUPT_NAME = re.compile(r".+" + re.escape(CORRUPT_MARKER) + r"(\d{8}-\d{6})(?:-\d+)?")
# Python's `tempfile` names: "tmp" + 8 characters from this alphabet.
TEMP_NAME = re.compile(r"tmp[a-z0-9_]{8}")
TEMP_MIN_AGE_SECONDS = 10 * 60
PART_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
# Moved-aside copies are deleted this long after they were moved aside.
CORRUPT_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
# Weight files the sidecars have Cellpose download, besides the MODEL_NAMES of
# an already imported Cellpose: `<name>torch_<n>` (Cellpose 3 cyto/cyto2/
# nuclei, Omnipose) and the size models `size_<name>.npy`.
BUILTIN_WEIGHT_NAMES = frozenset({"cpsam", "cyto3", "nuclei", "cyto2", "cyto", "denoise_cyto3"})
_BUILTIN_WEIGHT_FILE = re.compile(r"[A-Za-z0-9_]+torch_\d+|size_[A-Za-z0-9_]+\.npy")
# A damaged file moved aside this recently is not downloaded yet again.
RECENT_QUARANTINE_SECONDS = 60 * 60

READ_TIMEOUT_SECONDS = 30
CHUNK_BYTES = 1024 * 1024
DISK_MARGIN_BYTES = 64 * 1024 * 1024
# macOS's own CA bundle, used only if the interpreter found no CA certificates.
SYSTEM_CA_BUNDLE = "/etc/ssl/cert.pem"

_MIB = 1024 * 1024


class ModelDownloadError(RuntimeError):
    """The weights are unavailable; image loading/inference is not the failure."""


class IncompleteDownloadError(ModelDownloadError):
    """The stream ended early. The partial file is kept and a retry resumes."""


class CertificateVerificationError(ModelDownloadError):
    """The server's HTTPS certificate could not be verified."""


class UnexpectedSizeError(ModelDownloadError):
    """The server or the file disagrees with the size CellCounter expects."""


def _log(message: str) -> None:
    print(LOG_PREFIX + message, file=sys.stderr, flush=True)


def _mb(size) -> str:
    return f"{size / _MIB:.1f} MB"


# ---------------------------------------------------------------------------
# Where Cellpose keeps its weights.
# ---------------------------------------------------------------------------

def models_dir(models_module=None) -> str:
    """The folder Cellpose reads weights from.

    The module's own `MODEL_DIR` is authoritative (Cellpose reads
    `CELLPOSE_LOCAL_MODELS_PATH` once, at import). Without it, apply the same
    rule Cellpose does.
    """
    configured = getattr(models_module, "MODEL_DIR", None) if models_module is not None else None
    if configured:
        return os.fspath(configured)
    override = os.environ.get("CELLPOSE_LOCAL_MODELS_PATH")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".cellpose", "models")


def is_download_artifact(name: str) -> bool:
    """A name this module or Cellpose's downloader creates besides weights."""
    return (name.endswith((PART_SUFFIX, PART_SUFFIX + VALIDATOR_SUFFIX, LEGACY_PART_SUFFIX))
            or CORRUPT_MARKER in name or TEMP_NAME.fullmatch(name) is not None)


# ---------------------------------------------------------------------------
# TLS.
# ---------------------------------------------------------------------------

def make_ssl_context() -> ssl.SSLContext:
    """A verifying client context. Never an unverified one.

    `create_default_context` honours SSL_CERT_FILE/SSL_CERT_DIR and the
    interpreter's OpenSSL paths; certifi's bundle is added when installed.
    """
    context = ssl.create_default_context()
    try:
        import certifi  # type: ignore
    except ImportError:
        certifi = None
    if certifi is not None:
        try:
            context.load_verify_locations(cafile=certifi.where())
        except (OSError, ssl.SSLError):
            pass
    if (not context.cert_store_stats().get("x509_ca")
            and os.path.isfile(SYSTEM_CA_BUNDLE)):
        # A capath directory loads lazily and counts 0 here; adding the system
        # bundle on top of it is harmless.
        try:
            context.load_verify_locations(cafile=SYSTEM_CA_BUNDLE)
        except (OSError, ssl.SSLError):
            pass
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def restore_default_https_context() -> bool:
    """Undo Cellpose's process-wide `ssl._create_unverified_context` switch."""
    unverified = getattr(ssl, "_create_unverified_context", None)
    if unverified is not None and getattr(ssl, "_create_default_https_context", None) is unverified:
        ssl._create_default_https_context = ssl.create_default_context
        return True
    return False


def _is_certificate_error(error) -> bool:
    if isinstance(error, ssl.SSLCertVerificationError):
        return True
    return isinstance(error, ssl.SSLError) and "CERTIFICATE_VERIFY_FAILED" in str(error)


class _NoDowngradeRedirect(urllib.request.HTTPRedirectHandler):
    """Follow redirects (Hugging Face → CDN) but never from https to http."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old = urllib.parse.urlsplit(req.full_url).scheme
        new = urllib.parse.urlsplit(newurl).scheme
        if old == "https" and new != "https":
            raise ModelDownloadError(
                f"The server redirected the download to an insecure address ({newurl}); "
                "CellCounter only downloads model weights over verified HTTPS.")
        # Range survives: only Content-Length/Content-Type are dropped.
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def build_opener(context: ssl.SSLContext | None = None, proxies=None):
    """An opener with a verifying HTTPS context and no https→http redirects.

    ``proxies`` None keeps the environment/system proxy settings.
    """
    handlers = [urllib.request.HTTPSHandler(context=context or make_ssl_context()),
                _NoDowngradeRedirect()]
    if proxies is not None:
        handlers.append(urllib.request.ProxyHandler(proxies))
    return urllib.request.build_opener(*handlers)


def _is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _secure_url(url: str, log) -> str:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https":
        return url
    if parts.scheme == "http":
        if _is_loopback(parts.hostname or ""):
            return url  # a local server (tests); nothing crosses the network
        upgraded = urllib.parse.urlunsplit(("https",) + tuple(parts[1:]))
        log(f"using HTTPS for {parts.hostname} instead of plain HTTP")
        return upgraded
    raise ModelDownloadError(f"Refusing to download model weights from {url!r}: only HTTPS is allowed.")


# ---------------------------------------------------------------------------
# The download.
# ---------------------------------------------------------------------------

class _Progress:
    """Newline progress lines in the format the native UI already shows.

    "downloading weights: 10.0 / 1176.4 MB (1%)" — one per 5 % step, or every
    2 s while bytes arrive, plus a final "downloaded weights: …" line.
    """

    def __init__(self, total, log, enabled=True):
        self.total = total
        self.log = log
        self.enabled = enabled
        self.last_bucket = -1
        self.last_time = 0.0
        self.last_done = 0

    def _amount(self, done):
        if self.total:
            percent = min(100, int(done * 100 / self.total))
            return f"{done / _MIB:.1f} / {self.total / _MIB:.1f} MB ({percent}%)"
        return f"{done / _MIB:.1f} MB"

    def update(self, done, force=False):
        if not self.enabled:
            return
        now = time.monotonic()
        bucket = int(done * 20 / self.total) if self.total else -1
        changed = bucket > self.last_bucket if self.total else done - self.last_done >= _MIB
        if not force and not changed and now - self.last_time < 2:
            return
        self.last_bucket, self.last_time, self.last_done = bucket, now, done
        self.log(f"downloading weights: {self._amount(done)}")

    def finish(self, done):
        if self.enabled:
            self.log(f"downloaded weights: {self._amount(done)}")


def _complete(path: str, pinned) -> bool:
    try:
        info = os.stat(path)
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and (pinned is None or info.st_size == pinned)


def _try_lock(fd: int) -> bool:
    """Exclusive, non-blocking. A filesystem without flock counts as locked by us."""
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False
    except OSError as exc:
        if exc.errno in (errno.EAGAIN, errno.EACCES):
            return False
        return True


def _open_locked_part(part: str, dst: str, pinned, name: str, log, progress: bool):
    """Open and lock `part`, waiting for another worker that holds it.

    Returns the descriptor, or None when the other worker completed `dst`
    meanwhile.
    """
    waiting_since = None
    reporter = None
    while True:
        if _complete(dst, pinned):
            return None
        fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            if not _try_lock(fd):
                if waiting_since is None:
                    waiting_since = time.monotonic()
                    log(f"another CellCounter worker is downloading {name}; waiting for it")
                    reporter = _Progress(pinned, log, enabled=progress)
                try:
                    reporter.update(os.path.getsize(part))
                except OSError:
                    pass
                os.close(fd)
                fd = -1
                time.sleep(0.5)
                continue
            # The holder may have renamed or removed the file we opened.
            try:
                current = os.stat(part)
                held = os.fstat(fd)
                same = (current.st_ino, current.st_dev) == (held.st_ino, held.st_dev)
            except FileNotFoundError:
                same = False
            if not same:
                os.close(fd)
                fd = -1
                continue
            return fd
        except BaseException:
            if fd >= 0:
                os.close(fd)
            raise


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def _fsync_directory(directory: str) -> None:
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _parse_content_range(value):
    """'bytes START-END/TOTAL' → (start, end, total|None); None when unusable."""
    match = re.fullmatch(r"\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*", value or "")
    if not match:
        return None
    total = None if match.group(3) == "*" else int(match.group(3))
    return int(match.group(1)), int(match.group(2)), total


def _unsatisfied_range_total(value):
    match = re.fullmatch(r"\s*bytes\s+\*/(\d+)\s*", value or "")
    return int(match.group(1)) if match else None


def _content_length(headers):
    value = headers.get("Content-Length")
    try:
        length = int(value)
    except (TypeError, ValueError):
        return None
    return length if length >= 0 else None


def _read_validator(part: str):
    try:
        with open(part + VALIDATOR_SUFFIX, "r", encoding="ascii") as handle:
            return handle.read(1024).strip() or None
    except (OSError, ValueError):
        return None


def _save_validator(part: str, headers) -> None:
    """Remember which version of the file the partial download holds.

    A strong ETag is preferred (a weak one is never honoured in If-Range),
    else Last-Modified. Without either, a stale validator is removed and a
    resume works as before, unchecked.
    """
    etag = (headers.get("ETag") or "").strip()
    value = etag if etag and not etag.startswith("W/") else (headers.get("Last-Modified") or "").strip()
    try:
        if value and len(value) <= 1024 and value.isascii() and value.isprintable():
            with open(part + VALIDATOR_SUFFIX, "w", encoding="ascii") as handle:
                handle.write(value)
        else:
            _remove_validator(part)
    except OSError:
        pass  # best effort: a resume without If-Range is today's behaviour


def _remove_validator(part: str) -> None:
    try:
        os.unlink(part + VALIDATOR_SUFFIX)
    except OSError:
        pass


def _connect(opener, url: str, offset: int, timeout: float, name: str, validator=None):
    """GET `url` from `offset`. Returns (response, None) or (None, http_error).

    With `validator`, the range is asked for only if the file is still that
    version (If-Range); otherwise the server answers 200 with the whole file.
    """
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    if offset:
        request.add_header("Range", f"bytes={offset}-")
        if validator:
            request.add_header("If-Range", validator)
    host = urllib.parse.urlsplit(url).hostname or url
    try:
        return opener.open(request, timeout=timeout), None
    except urllib.error.HTTPError as exc:
        return None, exc
    except urllib.error.URLError as exc:
        if _is_certificate_error(exc.reason):
            raise CertificateVerificationError(_certificate_message(host, exc.reason)) from exc
        raise ModelDownloadError(
            f"Could not reach {host} ({exc.reason}). Check your internet connection and retry.") from exc
    except ssl.SSLError as exc:
        if _is_certificate_error(exc):
            raise CertificateVerificationError(_certificate_message(host, exc)) from exc
        raise ModelDownloadError(
            f"The secure connection to {host} failed ({exc}). Check your internet connection and retry.") from exc
    except (OSError, http_client.HTTPException) as exc:
        raise ModelDownloadError(
            f"Could not reach {host} ({exc}). Check your internet connection and retry.") from exc


def _certificate_message(host, reason) -> str:
    detail = getattr(reason, "verify_message", None) or str(reason)
    return (f"The HTTPS certificate of {host} could not be verified ({detail}). "
            "CellCounter only downloads model weights over verified connections. "
            "If this network inspects HTTPS traffic, its certificate authority has to be "
            "trusted by the Python environment; otherwise try another network.")


def download_url_to_file(url, dst, progress=True, *, expected_size=None,
                         timeout=READ_TIMEOUT_SECONDS, opener=None, log=_log,
                         chunk_bytes=CHUNK_BYTES):
    """Download `url` to `dst`, verified and resumable. Same call shape as Cellpose's.

    Raises `ModelDownloadError` (or a subclass) with a message meant for the
    user. The partial `<dst>.cellcounter-part` file (and its `.validator`)
    survives every failure, SIGTERM and SIGKILL, so the next call resumes; it
    is removed only when it holds no bytes.
    """
    restore_default_https_context()
    dst = os.path.abspath(os.path.expanduser(os.fspath(dst)))
    name = os.path.basename(dst)
    directory = os.path.dirname(dst)
    os.makedirs(directory, exist_ok=True)
    pinned = expected_size if expected_size is not None else PINNED_SIZES.get(name)
    url = _secure_url(str(url), log)
    opener = opener or build_opener()
    part = dst + PART_SUFFIX

    fd = _open_locked_part(part, dst, pinned, name, log, progress)
    if fd is None:
        log(f"another worker finished downloading {name}")
        return
    try:
        if _complete(dst, pinned):
            # Finished by another worker between our check and the lock.
            log(f"another worker finished downloading {name}")
            return
        _download_locked(fd, url, part, dst, name, directory, pinned, progress,
                         timeout, opener, log, chunk_bytes)
    finally:
        _remove_if_empty(part, fd)
        os.close(fd)  # releases the lock


def _remove_if_empty(part: str, fd: int) -> None:
    """A partial file without bytes has nothing to resume; do not leave it behind."""
    try:
        held = os.fstat(fd)
        current = os.stat(part)
    except OSError:
        return
    if held.st_size == 0 and (held.st_ino, held.st_dev) == (current.st_ino, current.st_dev):
        try:
            os.unlink(part)
        except OSError:
            return
        _remove_validator(part)


def _finalize(fd: int, part: str, dst: str, directory: str) -> None:
    os.fsync(fd)
    os.replace(part, dst)
    _remove_validator(part)
    _fsync_directory(directory)


def _refusal(error, name) -> ModelDownloadError:
    code, reason = error.code, error.reason
    error.close()
    return ModelDownloadError(f"The server refused the {name} download (HTTP {code} {reason}). Retry later.")


def _download_locked(fd, url, part, dst, name, directory, pinned, progress,
                     timeout, opener, log, chunk_bytes):
    offset = os.fstat(fd).st_size
    if pinned is not None and offset > pinned:
        log(f"discarding {name}{PART_SUFFIX}: it is larger than the expected {pinned} bytes")
        os.ftruncate(fd, 0)
        offset = 0
    if pinned is not None and offset == pinned:
        # Complete already: the previous run stopped between writing and moving.
        _finalize(fd, part, dst, directory)
        return

    validator = _read_validator(part) if offset else None
    response = None
    try:
        # At most two requests: a resume, and one fresh start if the server
        # cannot continue the partial file (or it is now another version).
        for attempt in (1, 2):
            response, refused = _connect(opener, url, offset, timeout, name, validator)
            if refused is not None:
                if refused.code == 416 and offset:
                    total = _unsatisfied_range_total(refused.headers.get("Content-Range"))
                    refused.close()
                    if total == offset and (pinned is None or pinned == total):
                        _finalize(fd, part, dst, directory)  # the .part was complete
                        return
                    if attempt == 1:
                        log(f"the partial {name} download does not match the server's file; starting again")
                        os.ftruncate(fd, 0)
                        offset = 0
                        continue
                raise _refusal(refused, name)
            status = getattr(response, "status", None) or response.getcode()
            if status == 206:
                parsed = _parse_content_range(response.headers.get("Content-Range"))
                if parsed is None or parsed[0] != offset:
                    response.close()
                    response = None
                    if attempt == 1:
                        log(f"the server answered the {name} resume request with another range; starting again")
                        os.ftruncate(fd, 0)
                        offset = 0
                        continue
                    raise ModelDownloadError(
                        f"The server sent an unusable partial answer for {name}. Retry later.")
                total = parsed[2]
                if total is None:
                    length = _content_length(response.headers)
                    total = offset + length if length is not None else None
                break
            if status == 200:
                if offset:
                    log(f"the server cannot resume the {name} download; starting again")
                    os.ftruncate(fd, 0)
                    offset = 0
                _save_validator(part, response.headers)  # the version these bytes are of
                total = _content_length(response.headers)
                break
            response.close()
            response = None
            raise ModelDownloadError(f"The server answered the {name} download with HTTP {status}. Retry later.")

        encoding = (response.headers.get("Content-Encoding") or "identity").strip().lower()
        if encoding not in ("", "identity"):
            raise ModelDownloadError(
                f"The server sent the {name} weights encoded as {encoding!r}; CellCounter needs the raw file.")
        if pinned is not None and total is not None and total != pinned:
            raise UnexpectedSizeError(
                f"The server offers {total} bytes for {name}, but CellCounter expects "
                f"{pinned} bytes. The published file may have changed; update CellCounter.")
        expected = pinned if pinned is not None else total
        if expected is not None:
            free = shutil.disk_usage(directory).free
            if free < expected - offset + DISK_MARGIN_BYTES:
                raise ModelDownloadError(
                    f"Not enough free disk space for the {name} weights: "
                    f"{_mb(expected - offset)} are needed and {_mb(free)} are free.")

        if offset:
            log(f"resuming the {name} download at {_mb(offset)}")
        reporter = _Progress(expected, log, enabled=progress)
        reporter.update(offset, force=True)
        done = offset
        while True:
            try:
                chunk = response.read(chunk_bytes)
            except (OSError, http_client.HTTPException) as exc:
                # socket.timeout, a reset, or an IncompleteRead in a chunked body.
                raise IncompleteDownloadError(_incomplete_message(name, done, expected, exc)) from exc
            if not chunk:
                break
            if expected is not None and done + len(chunk) > expected:
                os.ftruncate(fd, 0)
                raise UnexpectedSizeError(
                    f"The server sent more than the {expected} bytes expected for {name}; "
                    "the partial file was discarded. Retry the download.")
            try:
                _write_all(fd, chunk)
            except OSError as exc:
                if exc.errno == errno.ENOSPC:
                    raise ModelDownloadError(
                        f"The disk filled up while downloading {name}. Free some space and retry; "
                        "the download resumes where it stopped.") from exc
                raise
            done += len(chunk)
            reporter.update(done)
    finally:
        if response is not None:
            response.close()

    os.fsync(fd)
    size = os.fstat(fd).st_size
    if expected is not None and size != expected:
        # Only fewer bytes can arrive here: more were refused above.
        raise IncompleteDownloadError(_incomplete_message(name, size, expected, None))
    if expected is None:
        log(f"the server did not report the size of {name}; its completeness could not be checked")
    reporter.finish(size)
    _finalize(fd, part, dst, directory)


def _incomplete_message(name, done, expected, cause) -> str:
    amount = f"{_mb(done)} of {_mb(expected)}" if expected else _mb(done)
    reason = f" ({cause})" if cause is not None else ""
    return (f"The {name} download stopped after {amount}{reason}. "
            "The partial file is kept; retry and the download resumes where it stopped.")


# ---------------------------------------------------------------------------
# Models-folder housekeeping.
# ---------------------------------------------------------------------------

def _unlink_unless_locked(path: str, companion: str | None = None) -> bool:
    """Delete `path` while holding its download lock; False when a worker holds it.

    The lock is held across the unlink, so no worker can lock and resume the
    file in between (it would append to a file that no longer has a name).
    A file replaced since it was opened is left alone. `companion` (the resume
    validator) is removed under the same lock. A failed unlink raises OSError.
    """
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EACCES):
                return False
            # No flock on this filesystem: workers cannot lock either.
        try:
            current = os.lstat(path)
        except OSError:
            return False
        held = os.fstat(fd)
        if (current.st_ino, current.st_dev) != (held.st_ino, held.st_dev):
            return False
        os.unlink(path)
        if companion is not None:
            try:
                os.unlink(companion)
            except OSError:
                pass
        return True
    finally:
        os.close(fd)  # releases the lock


def _cellpose_weight_names() -> set:
    """Built-in weight names plus MODEL_NAMES of the Cellpose modules already imported.

    Only `sys.modules` is read: importing Cellpose here would load PyTorch.
    """
    names = set(BUILTIN_WEIGHT_NAMES)
    for module_name in ("cellpose.models", "cellpose.denoise", "cellpose_omni.models"):
        try:
            names.update(str(item) for item in
                         getattr(sys.modules.get(module_name), "MODEL_NAMES", None) or ())
        except TypeError:
            pass
    return names


def _quarantined_at(name: str):
    """When `<name>.corrupt-<timestamp>` was moved aside (epoch seconds), or None."""
    match = _CORRUPT_NAME.fullmatch(name)
    if not match:
        return None
    try:
        return time.mktime(time.strptime(match.group(1), "%Y%m%d-%H%M%S"))
    except (ValueError, OverflowError):
        return None


def _leftover_kind(name: str):
    """Which download leftover `name` could be; None for every other name."""
    if TEMP_NAME.fullmatch(name):
        return "temporary download"
    for suffix, kind in ((PART_SUFFIX, "partial download"),
                         (PART_SUFFIX + VALIDATOR_SUFFIX, "resume validator"),
                         (LEGACY_PART_SUFFIX, "partial download of an older CellCounter")):
        if name.endswith(suffix) and len(name) > len(suffix):
            return kind
    if _CORRUPT_NAME.fullmatch(name):
        return "damaged copy"
    return None


def cleanup_stale_files(directory, *, now=None, log=_log) -> list:
    """Delete abandoned downloads in `directory`; return the removed names.

    The folder may be shared with other software, so only these regular
    files are ever removed:
      * Python `tempfile` names (`tmp` + 8 of [a-z0-9_]) — Cellpose's own
        downloader — not modified for 10 minutes, so a live download in
        another process is never touched;
      * CellCounter's `*.cellcounter-part` files not modified for 7 days and
        not locked by a worker, with their `.validator`; a `.validator` whose
        partial file is gone, after 10 minutes;
      * once, the `<name>.part` files older CellCounter versions left: only
        for a Cellpose weight name (built in, `*torch_<n>`, `size_*.npy`, or
        the MODEL_NAMES of an imported Cellpose) that gui_models.txt does not
        list as the user's own, not modified for 10 minutes, and not locked;
      * `<name>.corrupt-<timestamp>` copies moved aside more than 7 days ago
        (by the timestamp: a rename keeps the original modification time).
    Symlinks, folders and every other name are left alone.
    """
    removed = []
    directory = os.fspath(directory)
    try:
        entries = list(os.scandir(directory))
    except FileNotFoundError:
        return removed
    except OSError as exc:
        log(f"could not inspect {directory} for stale downloads: {exc}")
        return removed
    now = time.time() if now is None else now
    weight_names = user_models = None  # read only when a legacy partial file is found
    for entry in entries:
        name = entry.name
        kind = _leftover_kind(name)
        if kind is None:
            continue
        try:
            info = os.lstat(entry.path)
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode):
            continue
        age = now - info.st_mtime
        partial = kind in ("partial download", "partial download of an older CellCounter")
        if kind == "temporary download":
            stale = age >= TEMP_MIN_AGE_SECONDS
        elif kind == "partial download":
            stale = age >= PART_MAX_AGE_SECONDS
        elif kind == "resume validator":
            stale = (age >= TEMP_MIN_AGE_SECONDS
                     and not os.path.lexists(entry.path[:-len(VALIDATOR_SUFFIX)]))
        elif kind == "damaged copy":
            moved_at = _quarantined_at(name)
            age = now - moved_at if moved_at is not None else 0
            stale = age >= CORRUPT_MAX_AGE_SECONDS
        else:  # a partial file of an older CellCounter
            if weight_names is None:
                weight_names, user_models = _cellpose_weight_names(), user_registered_models(directory)
            weight = name[:-len(LEGACY_PART_SUFFIX)]
            stale = (age >= TEMP_MIN_AGE_SECONDS and weight not in user_models
                     and (weight in weight_names or _BUILTIN_WEIGHT_FILE.fullmatch(weight) is not None))
        if not stale:
            continue
        try:
            if partial:
                companion = entry.path + VALIDATOR_SUFFIX if kind == "partial download" else None
                if not _unlink_unless_locked(entry.path, companion):
                    continue  # a worker holds it (or it was just replaced)
            else:
                os.unlink(entry.path)
        except OSError as exc:
            log(f"could not remove the stale {kind} {name}: {exc}")
            continue
        detail = (f"moved aside {_age_text(age)} ago" if kind == "damaged copy"
                  else f"unchanged for {_age_text(age)}")
        log(f"removed stale {kind} {name} ({_mb(info.st_size)}, {detail}) from {directory}")
        removed.append(name)
    return removed


def _age_text(seconds: float) -> str:
    if seconds >= 2 * 24 * 3600:
        return f"{int(seconds // (24 * 3600))} days"
    if seconds >= 2 * 3600:
        return f"{int(seconds // 3600)} hours"
    return f"{int(seconds // 60)} minutes"


def quarantine(path, reason: str, log=_log) -> str:
    """Move a damaged weight file aside to `<name>.corrupt-<timestamp>`.

    Only this newest copy is kept: older `<name>.corrupt-*` copies (each up to
    ~1.2 GB) are deleted, so a file that keeps failing cannot fill the disk.
    """
    path = os.fspath(path)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    target = f"{path}{CORRUPT_MARKER}{stamp}"
    counter = 1
    while os.path.lexists(target):
        target = f"{path}{CORRUPT_MARKER}{stamp}-{counter}"
        counter += 1
    os.rename(path, target)
    log(f"moved the damaged {os.path.basename(path)} weights aside to "
        f"{os.path.basename(target)} ({reason}); they will be downloaded again")
    _remove_older_copies(path, target, log)
    return target


def _remove_older_copies(path: str, keep: str, log) -> None:
    directory, name = os.path.split(path)
    pattern = re.compile(re.escape(name + CORRUPT_MARKER) + r"\d{8}-\d{6}(?:-\d+)?")
    try:
        names = os.listdir(directory or ".")
    except OSError:
        return
    for candidate in names:
        if candidate == os.path.basename(keep) or not pattern.fullmatch(candidate):
            continue
        older = os.path.join(directory, candidate)
        try:
            info = os.lstat(older)
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode):
            continue
        try:
            os.unlink(older)
        except OSError as exc:
            log(f"could not remove the older damaged copy {candidate}: {exc}")
            continue
        log(f"removed the older damaged copy {candidate} ({_mb(info.st_size)}) from "
            f"{directory}; only the newest one, {os.path.basename(keep)}, is kept")


def recently_quarantined(path, *, now=None, window=RECENT_QUARANTINE_SECONDS):
    """Name of a copy of `path` moved aside within `window` seconds, or None."""
    path = os.fspath(path)
    directory, name = os.path.split(path)
    now = time.time() if now is None else now
    pattern = re.compile(re.escape(name + CORRUPT_MARKER) + r"(\d{8}-\d{6})(?:-\d+)?")
    try:
        names = os.listdir(directory)
    except OSError:
        return None
    for candidate in sorted(names, reverse=True):
        match = pattern.fullmatch(candidate)
        if not match:
            continue
        try:
            moved_at = time.mktime(time.strptime(match.group(1), "%Y%m%d-%H%M%S"))
        except (ValueError, OverflowError):
            continue
        if 0 <= now - moved_at < window:
            return candidate
    return None


def quarantine_mismatched_pinned_weights(directory, *, log=_log, pins=None) -> list:
    """Move aside pinned files whose size is wrong (e.g. an old truncated copy)."""
    moved = []
    for name, size in (PINNED_SIZES if pins is None else pins).items():
        path = os.path.join(os.fspath(directory), name)
        try:
            info = os.lstat(path)
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_size == size:
            continue  # symlinks are the user's own arrangement
        try:
            moved.append(quarantine(path, f"{info.st_size} bytes instead of {size}", log=log))
        except OSError as exc:
            log(f"could not move the incomplete {name} weights aside: {exc}")
    return moved


def user_registered_models(directory) -> set:
    """Names the Cellpose GUI registered as the user's own models (gui_models.txt)."""
    try:
        with open(os.path.join(os.fspath(directory), "gui_models.txt"), "r") as handle:
            return {line.strip() for line in handle if line.strip()}
    except OSError:
        return set()


_CORRUPT_TEXT = (
    "pytorchstreamreader",
    "failed finding central directory",
    "invalid header or archive is corrupted",
    "unexpected eof",
    "file might be corrupted",
    "ran out of input",
    "invalid load key",
    "not a zip file",
    "weights only load failed",
)


def is_corrupt_checkpoint_error(error) -> bool:
    """Whether `error` (or what caused it) is typical of a truncated/corrupt checkpoint."""
    seen = set()
    while error is not None and id(error) not in seen:
        seen.add(id(error))
        if isinstance(error, ModelDownloadError):
            return False
        if isinstance(error, (EOFError, pickle.UnpicklingError, zipfile.BadZipFile)):
            return True
        text = str(error).lower()
        if any(marker in text for marker in _CORRUPT_TEXT):
            return True
        error = error.__cause__ or error.__context__
    return False


__all__ = [
    "PINNED_SIZES", "ModelDownloadError", "IncompleteDownloadError",
    "CertificateVerificationError", "UnexpectedSizeError", "models_dir",
    "is_download_artifact", "make_ssl_context", "restore_default_https_context",
    "build_opener", "download_url_to_file", "cleanup_stale_files", "quarantine",
    "recently_quarantined", "quarantine_mismatched_pinned_weights",
    "user_registered_models", "is_corrupt_checkpoint_error",
]
