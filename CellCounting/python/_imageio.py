"""
_imageio.py — vendor microscope format reader + Z-stack / multi-channel handling.

This is the single entry point every CellCounter sidecar uses to turn a file on
disk into pixel data. It replaces the old "PIL only, RGB only, one plane only"
assumption in `_cellpose_common.open_image_for_detection()`.

FROZEN PUBLIC API — other modules code against this verbatim:

    load_planes(path, *, z_project="max", channel=None) -> (array, meta)

      array : numpy.ndarray, dtype float32, shape (H, W, C).
              C == 1 for grayscale sources; C == 3 for RGB; C == n for
              n-channel fluorescence. Values are RAW detector counts in the
              source file's own units — deliberately NOT rescaled to 0–255,
              because per-channel quantification (e.g. "GFP mean intensity")
              is meaningless after a per-image min/max renormalisation.

      meta  : dict with (at minimum) these keys:
                "channel_names"  list[str]   — one entry per channel in `array`
                "pixel_size_um"  float|None  — physical size of one pixel, µm
                "z_count"        int         — Z planes in the source (>= 1)
                "t_count"        int         — time points in the source (>= 1)
                "source_format"  str         — "czi" | "nd2" | "lif" | "oif" |
                                               "oib" | "oir" | "tiff" | "pil"
              Additive extras (safe to ignore, never removed):
                "is_rgb"             bool      — source is an RGB(A) photo, so
                                                 channel 0/1/2 are R/G/B
                "dtype"              str       — source numpy dtype name
                "z_project"          str       — projection actually applied
                "all_channel_names"  list[str] — names for every channel in the
                                                 file, even when `channel=` was
                                                 used to extract just one
                "reader"             str       — python package that read it
                "axes"               str       — canonical axes of the source

      z_project : "max" | "sum" | "mean" | "none". Applied across Z.
                  "none" means *no projection* — the single central Z plane
                  (index z_count // 2) is returned, because plane 0 of a stack
                  is usually the out-of-focus end.
                  Anything else raises ImageIOError("z-project-invalid"); it is
                  NOT substituted with a default, because two projections of the
                  same stack are two different images.

      channel   : None extracts every channel; an int extracts just that one
                  (clamped to range) and the result has C == 1.

Vendor formats are read by OPTIONAL, pure-Python, BSD-3-Clause packages. If the
package for a given extension is not installed we fall back to PIL and, when
that also fails (it always will for .czi/.nd2/.lif/.oir), raise a
`MissingReaderError` whose message is literally "install czifile to open .czi"
so the host can show something actionable instead of a traceback.

DELIBERATELY EXCLUDED (all GPL / AGPL — this app is MIT):
  bioformats, python-bioformats, bioio-czi, readlif, aicspylibczi, pyometiff,
  czitools. Do not add them.

The `czifile`, `liffile` and `oirfile` APIs are documented upstream as unstable,
so every attribute access on them is defensive (getattr / try) and the install
lists pin them.
"""

from __future__ import annotations

import os
import sys
from typing import Any


# ---------------------------------------------------------------------------
# Logging — same "[cellpose_detect]" prefix the UI's stage parser already knows.
# ---------------------------------------------------------------------------

def _log(*args: Any) -> None:
    print("[cellpose_detect]", *args, file=sys.stderr)


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

class ImageIOError(Exception):
    """Structured load failure. `code` maps onto the sidecar's error JSON."""

    def __init__(self, message: str, hint: str = "",
                 code: str = "image-open-failed"):
        super().__init__(message)
        self.message = message
        self.hint = hint
        self.code = code


class MissingReaderError(ImageIOError):
    """A vendor reader package is not installed for this file extension."""

    def __init__(self, package: str, ext: str, detail: str = ""):
        msg = "install {} to open {}".format(package, ext)
        hint = "Run: pip install {}".format(package)
        if detail:
            hint = "{} ({})".format(hint, detail)
        super().__init__(msg, hint=hint, code="image-reader-missing")
        self.package = package
        self.ext = ext


class ImageTooLargeError(ImageIOError):
    def __init__(self, detail: str):
        super().__init__("image-too-large", hint=detail, code="image-too-large")


# ---------------------------------------------------------------------------
# Extension → reader registry
# ---------------------------------------------------------------------------

#: extension -> (pip package name, source_format tag)
VENDOR_PACKAGES = {
    ".czi": ("czifile", "czi"),
    ".nd2": ("nd2", "nd2"),
    ".lif": ("liffile", "lif"),
    ".oif": ("oiffile", "oif"),
    ".oib": ("oiffile", "oib"),
    ".oir": ("oirfile", "oir"),
}

#: handled by tifffile when present, PIL otherwise
TIFF_EXTENSIONS = (".tif", ".tiff", ".ome.tif", ".ome.tiff", ".lsm", ".stk",
                   ".qptiff", ".svs")

Z_PROJECT_MODES = ("max", "sum", "mean", "none")

#: PIL's DecompressionBomb guard defaults to ~178 MP. Whole-slide and
#: large-sensor microscopy scans legitimately exceed that; 2 GP is a sane
#: sanity cap that still rejects an absurd header. Matches the value the
#: previous PIL-only loader used.
_PIL_MAX_PIXELS = 2_000_000_000


def _ext_of(path: str) -> str:
    low = os.path.basename(path).lower()
    if low.endswith(".ome.tif"):
        return ".ome.tif"
    if low.endswith(".ome.tiff"):
        return ".ome.tiff"
    return os.path.splitext(low)[1]


def supported_extensions() -> list:
    """Every extension this module can open (vendor + tiff + common PIL)."""
    return sorted(set(list(VENDOR_PACKAGES.keys()) + list(TIFF_EXTENSIONS) + [
        ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp",
    ]))


# ---------------------------------------------------------------------------
# Axis normalisation
#
# Every reader hands back (array, axes_string, extras). `axes_string` uses one
# character per array dimension. We canonicalise to (Y, X, C) here so the rest
# of the app never has to think about vendor axis orders again.
#
# Recognised characters after canonicalisation:
#   Y, X  spatial (required)
#   Z     focal planes            → projected per `z_project`
#   C     channels                → kept, moved last
#   S     samples/components      → promoted to C when there is no C axis
#   T     time                    → counted, then index 0 taken
#   any other character           → index 0 taken (scene, tile, block, view…)
# ---------------------------------------------------------------------------

def _infer_axes(shape) -> str:
    """Best-effort axes string when the reader gave us nothing usable."""
    n = len(shape)
    if n == 2:
        return "YX"
    if n == 3:
        if shape[-1] <= 4:
            return "YXS"          # channels-last RGB(A)
        if shape[0] <= 8:
            return "CYX"          # a handful of leading channels
        return "ZYX"
    if n == 4:
        if shape[-1] <= 4:
            return "ZYXS"
        return "CZYX" if shape[0] <= 8 else "ZCYX"
    # Deeper: pad the front with placeholders that get index-0'd away.
    return "?" * (n - 3) + ("YXS" if shape[-1] <= 4 else "ZYX")


def _to_hwc(arr, axes: str, z_project: str):
    """(array, axes) → ((H, W, C) float32 array, z_count, t_count, canon_axes).

    Never raises for merely-odd axis strings; it degrades to inference.
    """
    import numpy as np

    a = np.asarray(arr)
    axes = (axes or "").upper()
    if len(axes) != a.ndim or not axes:
        inferred = _infer_axes(a.shape)
        if axes:
            _log("axes {!r} does not match ndim={}; inferring {!r}"
                 .format(axes, a.ndim, inferred))
        axes = inferred

    z_count = 1
    t_count = 1
    for ch, size in zip(axes, a.shape):
        if ch == "Z":
            z_count = int(size)
        elif ch == "T":
            t_count = int(size)

    # 1. Collapse every axis we do not model down to its first element.
    keep = set("ZCYXS")
    idx = []
    kept_axes = []
    for ch, size in zip(axes, a.shape):
        if ch in keep:
            idx.append(slice(None))
            kept_axes.append(ch)
        else:
            idx.append(0)
    a = a[tuple(idx)]
    axes = "".join(kept_axes)

    # 2. Reconcile a sample axis (RGB components) with a channel axis.
    if "S" in axes:
        s_size = a.shape[axes.index("S")]
        if "C" not in axes:
            axes = axes.replace("S", "C")
        else:
            c_size = a.shape[axes.index("C")]
            if s_size > 1 and c_size == 1:
                a = a[tuple(0 if ch == "C" else slice(None) for ch in axes)]
                axes = axes.replace("C", "").replace("S", "C")
            else:
                a = a[tuple(0 if ch == "S" else slice(None) for ch in axes)]
                axes = axes.replace("S", "")

    # 3. Y and X must exist; if the reader lied, take the last two dims.
    if "Y" not in axes or "X" not in axes:
        _log("axes {!r} has no Y/X after reduction; assuming last two dims"
             .format(axes))
        lead = a.ndim - 2
        axes = ("C" if lead == 1 else "?" * lead) + "YX"
        if lead > 1:
            a = a[tuple([0] * lead + [slice(None), slice(None)])]
            axes = "YX"

    # 4. Transpose to (Z?, C?, Y, X).
    target = [ch for ch in "ZC" if ch in axes] + ["Y", "X"]
    a = np.transpose(a, [axes.index(ch) for ch in target])
    axes = "".join(target)

    a = a.astype(np.float32, copy=False)

    # 5. Project across Z.
    if "Z" in axes:
        zi = axes.index("Z")
        mode = z_project if z_project in Z_PROJECT_MODES else "max"
        if mode == "max":
            a = a.max(axis=zi)
        elif mode == "sum":
            a = a.sum(axis=zi, dtype=np.float32)
        elif mode == "mean":
            a = a.mean(axis=zi, dtype=np.float32)
        else:  # "none" — keep a single, central plane
            mid = a.shape[zi] // 2
            a = np.take(a, mid, axis=zi)
        axes = axes.replace("Z", "")

    # 6. Channel last.
    if "C" in axes:
        a = np.moveaxis(a, axes.index("C"), -1)
    else:
        a = a[..., np.newaxis]

    return np.ascontiguousarray(a, dtype=np.float32), z_count, t_count, axes


# ---------------------------------------------------------------------------
# Small metadata helpers
# ---------------------------------------------------------------------------

def _xml_root(text):
    if not text:
        return None
    try:
        import xml.etree.ElementTree as ET
        if isinstance(text, bytes):
            text = text.decode("utf-8", "replace")
        return ET.fromstring(text)
    except Exception:  # noqa: BLE001
        return None


def _localname(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def _float_or_none(value):
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    if f != f or f <= 0:  # NaN or non-positive
        return None
    return f


def _default_names(count: int, prefix: str = "Ch") -> list:
    return ["{}{}".format(prefix, i) for i in range(count)]


def _fit_names(names, count: int) -> list:
    """Force `names` to exactly `count` entries, filling gaps with Ch<i>."""
    out = []
    names = list(names or [])
    for i in range(count):
        raw = names[i] if i < len(names) else None
        text = str(raw).strip() if raw is not None else ""
        out.append(text if text else "Ch{}".format(i))
    return out


# ---------------------------------------------------------------------------
# Readers. Each returns (array, axes_string, extras dict).
# Extras may carry: channel_names, pixel_size_um, is_rgb.
# ---------------------------------------------------------------------------

def _read_czi(path: str):
    """Zeiss .czi via `czifile` (BSD-3, Gohlke). API is documented unstable."""
    import czifile

    meta_xml = None
    czi = czifile.CziFile(path)
    try:
        arr = czi.asarray()
        axes = str(getattr(czi, "axes", "") or "")
        try:
            meta_xml = czi.metadata()
        except Exception:  # noqa: BLE001
            meta_xml = None
    finally:
        try:
            czi.close()
        except Exception:  # noqa: BLE001
            pass

    # czifile uses '0'/'1' for the sample (component) axis and 'S' for SCENE —
    # the opposite of tifffile/nd2. Remap before the shared normaliser runs.
    remapped = []
    for ch in axes:
        if ch == "S":
            remapped.append("E")      # scene → dropped by _to_hwc
        elif ch in ("0", "1"):
            remapped.append("S")      # component → sample
        else:
            remapped.append(ch)
    axes = "".join(remapped)

    return arr, axes, {
        "channel_names": _czi_channel_names(meta_xml),
        "pixel_size_um": _czi_pixel_size_um(meta_xml),
        "is_rgb": False,
    }


def _czi_channel_names(meta_xml):
    root = _xml_root(meta_xml)
    if root is None:
        return []
    names = []
    for el in root.iter():
        if _localname(el.tag) != "Channel":
            continue
        name = el.get("Name")
        if not name:
            for child in el:
                if _localname(child.tag) in ("Name", "ShortName", "Fluor"):
                    name = (child.text or "").strip()
                    if name:
                        break
        if name and name not in names:
            names.append(name)
    return names


def _czi_pixel_size_um(meta_xml):
    root = _xml_root(meta_xml)
    if root is None:
        return None
    for el in root.iter():
        if _localname(el.tag) != "Distance" or el.get("Id") != "X":
            continue
        for child in el:
            if _localname(child.tag) == "Value":
                metres = _float_or_none(child.text)
                if metres:
                    return metres * 1e6  # CZI stores metres
    return None


def _read_nd2(path: str):
    """Nikon .nd2 via `nd2` (BSD-3)."""
    import nd2

    with nd2.ND2File(path) as f:
        arr = f.asarray()
        try:
            axes = "".join(str(k) for k in f.sizes.keys())
        except Exception:  # noqa: BLE001
            axes = ""
        names = []
        try:
            for c in f.metadata.channels:
                names.append(str(c.channel.name))
        except Exception:  # noqa: BLE001
            names = []
        px = None
        try:
            px = _float_or_none(f.voxel_size().x)
        except Exception:  # noqa: BLE001
            px = None
        is_rgb = bool(getattr(f, "is_rgb", False))

    return arr, axes, {
        "channel_names": names,
        "pixel_size_um": px,
        "is_rgb": is_rgb,
    }


def _read_lif(path: str):
    """Leica .lif via `liffile` (BSD-3, Gohlke). API is documented unstable."""
    import liffile

    lif = liffile.LifFile(path)
    try:
        images = list(getattr(lif, "images", []) or [])
        if not images:
            raise ImageIOError(
                "lif-no-images",
                hint="{} contains no readable image series".format(
                    os.path.basename(path)))
        # A .lif holds several series; the first is often a low-res overview.
        # Pick the largest by pixel count so we open the real acquisition.
        def _pixels(im):
            try:
                shape = tuple(im.shape)
                out = 1
                for s in shape:
                    out *= int(s)
                return out
            except Exception:  # noqa: BLE001
                return 0

        image = max(images, key=_pixels)
        if len(images) > 1:
            _log("lif: {} series present; using largest ({!r})"
                 .format(len(images), getattr(image, "name", "?")))
        arr = image.asarray()
        axes = ""
        dims = getattr(image, "dims", None)
        if dims:
            try:
                axes = "".join(str(d)[0].upper() for d in dims)
            except Exception:  # noqa: BLE001
                axes = ""
        px = _lif_pixel_size_um(image)
        names = _lif_channel_names(image)
    finally:
        try:
            lif.close()
        except Exception:  # noqa: BLE001
            pass

    return arr, axes, {
        "channel_names": names,
        "pixel_size_um": px,
        "is_rgb": False,
    }


def _lif_pixel_size_um(image):
    """Derive µm/pixel from the X coordinate vector, when liffile exposes it."""
    try:
        coords = getattr(image, "coords", None)
        if not coords:
            return None
        xs = coords.get("X") if hasattr(coords, "get") else None
        if xs is None or len(xs) < 2:
            return None
        step = abs(float(xs[1]) - float(xs[0]))
        # liffile reports coordinates in metres.
        return _float_or_none(step * 1e6)
    except Exception:  # noqa: BLE001
        return None


def _lif_channel_names(image):
    for attr in ("channel_names", "channels"):
        try:
            value = getattr(image, attr, None)
            if value:
                return [str(v) for v in value]
        except Exception:  # noqa: BLE001
            continue
    return []


def _read_oif(path: str):
    """Olympus .oif / .oib via `oiffile` (BSD-3, Gohlke)."""
    import oiffile

    oif = oiffile.OifFile(path)
    try:
        arr = oif.asarray()
        axes = str(getattr(oif, "axes", "") or "")
        if not axes:
            tiffs = getattr(oif, "tiffs", None)
            axes = str(getattr(tiffs, "axes", "") or "")
        mainfile = getattr(oif, "mainfile", None)
        px = _oif_pixel_size_um(mainfile)
        names = _oif_channel_names(mainfile)
    finally:
        try:
            oif.close()
        except Exception:  # noqa: BLE001
            pass

    return arr, axes, {
        "channel_names": names,
        "pixel_size_um": px,
        "is_rgb": False,
    }


def _oif_pixel_size_um(mainfile):
    """Olympus stores axis extents; µm/px = (end - start) / maxsize."""
    if not mainfile:
        return None
    try:
        for key in mainfile.keys():
            if not str(key).startswith("Axis 0 Parameters"):
                continue
            section = mainfile[key]
            start = _float_or_none(section.get("StartPosition"))
            end = _float_or_none(section.get("EndPosition"))
            size = _float_or_none(section.get("MaxSize"))
            if start is None:
                start = 0.0
            if end is None or not size:
                return None
            span = abs(end - start)
            unit = str(section.get("PixUnit", "um")).lower()
            if unit in ("nm",):
                span /= 1000.0
            elif unit in ("mm",):
                span *= 1000.0
            return _float_or_none(span / size)
    except Exception:  # noqa: BLE001
        return None
    return None


def _oif_channel_names(mainfile):
    if not mainfile:
        return []
    names = []
    try:
        for key in mainfile.keys():
            text = str(key)
            if not text.startswith("Channel "):
                continue
            section = mainfile[key]
            name = section.get("DyeName") or section.get("ChannelName")
            if name:
                names.append(str(name))
    except Exception:  # noqa: BLE001
        return []
    return names


def _read_oir(path: str):
    """Olympus .oir via `oirfile` (BSD-3, Gohlke). API is documented unstable."""
    import oirfile

    oir = oirfile.OirFile(path)
    try:
        arr = oir.asarray()
        axes = str(getattr(oir, "axes", "") or "")
    finally:
        try:
            oir.close()
        except Exception:  # noqa: BLE001
            pass
    return arr, axes, {"channel_names": [], "pixel_size_um": None,
                       "is_rgb": False}


def _read_tiff(path: str):
    """TIFF family via `tifffile` (BSD-3). Handles OME-TIFF / ImageJ / LSM."""
    import tifffile

    with tifffile.TiffFile(path) as tf:
        series = tf.series[0] if tf.series else None
        if series is not None:
            arr = series.asarray()
            axes = str(getattr(series, "axes", "") or "")
        else:
            arr = tf.asarray()
            axes = ""

        is_rgb = False
        try:
            photometric = tf.pages[0].photometric
            is_rgb = int(photometric) in (2, 6)  # RGB, YCbCr
        except Exception:  # noqa: BLE001
            is_rgb = False

        px = _tiff_pixel_size_um(tf)
        names = _tiff_channel_names(tf)

    return arr, axes, {
        "channel_names": names,
        "pixel_size_um": px,
        "is_rgb": is_rgb,
    }


def _tiff_pixel_size_um(tf):
    # 1. OME-XML PhysicalSizeX (already µm unless PhysicalSizeXUnit says else).
    root = _xml_root(getattr(tf, "ome_metadata", None))
    if root is not None:
        for el in root.iter():
            if _localname(el.tag) != "Pixels":
                continue
            value = _float_or_none(el.get("PhysicalSizeX"))
            if value is None:
                continue
            unit = (el.get("PhysicalSizeXUnit") or "µm").strip().lower()
            if unit in ("nm",):
                value /= 1000.0
            elif unit in ("mm",):
                value *= 1000.0
            return value

    # 2. ImageJ metadata: XResolution is px per `unit`.
    try:
        ij = getattr(tf, "imagej_metadata", None) or {}
        unit = str(ij.get("unit", "")).lower()
        page = tf.pages[0]
        xres = page.tags.get("XResolution")
        if xres is not None and unit in ("um", "µm", "micron", "microns"):
            num, den = xres.value
            px_per_unit = float(num) / float(den) if den else 0.0
            if px_per_unit > 0:
                return 1.0 / px_per_unit
    except Exception:  # noqa: BLE001
        pass

    # 3. Plain TIFF resolution tags (inch / centimetre).
    try:
        page = tf.pages[0]
        xres = page.tags.get("XResolution")
        runit = page.tags.get("ResolutionUnit")
        if xres is not None:
            num, den = xres.value
            px_per_unit = float(num) / float(den) if den else 0.0
            code = int(runit.value) if runit is not None else 2
            if px_per_unit > 0 and code in (2, 3):
                unit_um = 25400.0 if code == 2 else 10000.0
                return unit_um / px_per_unit
    except Exception:  # noqa: BLE001
        pass
    return None


def _tiff_channel_names(tf):
    root = _xml_root(getattr(tf, "ome_metadata", None))
    if root is not None:
        names = []
        for el in root.iter():
            if _localname(el.tag) == "Channel":
                name = el.get("Name") or el.get("Fluor") or el.get("ID")
                if name:
                    names.append(str(name))
        if names:
            return names
    try:
        ij = getattr(tf, "imagej_metadata", None) or {}
        labels = ij.get("Labels")
        if labels:
            return [str(x) for x in labels]
    except Exception:  # noqa: BLE001
        pass
    return []


def _read_pil(path: str):
    """Fallback for png/jpg/bmp/gif and TIFFs when tifffile is absent."""
    import numpy as np
    from PIL import Image

    Image.MAX_IMAGE_PIXELS = _PIL_MAX_PIXELS

    try:
        pil = Image.open(path)
        pil.load()
    except Image.DecompressionBombError as exc:  # noqa: BLE001
        raise ImageTooLargeError(str(exc))

    mode = pil.mode
    if mode in ("L", "I", "F", "I;16", "I;16B", "I;16L"):
        arr = np.array(pil)
        if arr.ndim == 2:
            arr = arr[..., np.newaxis]
        return arr, "YXS", {"channel_names": [], "pixel_size_um": None,
                            "is_rgb": False}

    if mode == "LA":
        arr = np.array(pil)[..., :1]
        return arr, "YXS", {"channel_names": [], "pixel_size_um": None,
                            "is_rgb": False}

    rgb = pil.convert("RGB")
    arr = np.array(rgb)
    return arr, "YXS", {"channel_names": ["R", "G", "B"],
                        "pixel_size_um": None, "is_rgb": True}


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def _dispatch(path: str):
    """Pick a reader for `path`. Returns (array, axes, extras, format, reader).

    Vendor readers are optional: a missing package falls back to PIL, and only
    if PIL also fails do we surface "install <pkg> to open <ext>".
    """
    ext = _ext_of(path)

    if ext in VENDOR_PACKAGES:
        package, fmt = VENDOR_PACKAGES[ext]
        try:
            if ext == ".czi":
                arr, axes, extras = _read_czi(path)
            elif ext == ".nd2":
                arr, axes, extras = _read_nd2(path)
            elif ext == ".lif":
                arr, axes, extras = _read_lif(path)
            elif ext == ".oir":
                arr, axes, extras = _read_oir(path)
            else:
                arr, axes, extras = _read_oif(path)
            return arr, axes, extras, fmt, package
        except ImportError as exc:
            _log("{} reader unavailable ({!r}); trying PIL".format(package, exc))
            try:
                arr, axes, extras = _read_pil(path)
                _log("PIL opened {} unexpectedly — using it".format(ext))
                return arr, axes, extras, fmt, "PIL"
            except Exception:  # noqa: BLE001
                raise MissingReaderError(package, ext, detail=str(exc))
        except ImageIOError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise ImageIOError("image-open-failed",
                               hint="{}: {!r}".format(package, exc))

    if ext in TIFF_EXTENSIONS:
        try:
            arr, axes, extras = _read_tiff(path)
            return arr, axes, extras, "tiff", "tifffile"
        except ImportError:
            _log("tifffile not installed; falling back to PIL for {}".format(ext))
        except ImageIOError:
            raise
        except Exception as exc:  # noqa: BLE001
            _log("tifffile failed on {} ({!r}); falling back to PIL"
                 .format(os.path.basename(path), exc))

    try:
        arr, axes, extras = _read_pil(path)
    except ImageIOError:
        raise
    except Exception as exc:  # noqa: BLE001
        raise ImageIOError("image-open-failed", hint=repr(exc))
    return arr, axes, extras, "pil", "PIL"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def load_planes(path, *, z_project="max", channel=None):
    """Load `path` as an (H, W, C) float32 array plus a metadata dict.

    See the module docstring for the full, frozen contract. Raises
    `ImageIOError` (or its `MissingReaderError` / `ImageTooLargeError`
    subclasses) on failure; never returns None.
    """
    import numpy as np

    if not os.path.exists(path):
        raise ImageIOError("image-open-failed",
                           hint="no such file: {}".format(path))

    # An unrecognised mode used to fall back to "max" with a stderr line and a
    # clean exit — but on a real Z-stack the projections are not
    # interchangeable (min- and max-projection are near-opposite images), so
    # quietly substituting one for another produces a result that looks fine
    # and answers a different question. Refuse.
    mode = z_project
    if mode not in Z_PROJECT_MODES:
        raise ImageIOError(
            "unknown z-projection {!r}".format(z_project),
            hint="--z-project must be one of: {}. (Projections are not "
                 "interchangeable on a real Z-stack, so this is not "
                 "substituted with a default.)".format(", ".join(Z_PROJECT_MODES)),
            code="z-project-invalid")

    arr, axes, extras, fmt, reader = _dispatch(path)
    source_dtype = str(np.asarray(arr).dtype)

    stack, z_count, t_count, canon_axes = _to_hwc(arr, axes, mode)
    channel_count = int(stack.shape[2])

    all_names = _fit_names(extras.get("channel_names"), channel_count)
    if extras.get("is_rgb") and channel_count == 3:
        all_names = ["R", "G", "B"]

    selected_names = all_names
    if channel is not None:
        idx = int(channel)
        clamped = max(0, min(channel_count - 1, idx))
        if clamped != idx:
            _log("--segment-channel {} out of range (C={}); using {}"
                 .format(idx, channel_count, clamped))
        stack = stack[:, :, clamped:clamped + 1]
        selected_names = [all_names[clamped]]

    stack = np.ascontiguousarray(stack, dtype=np.float32)

    meta = {
        "channel_names": selected_names,
        "pixel_size_um": _float_or_none(extras.get("pixel_size_um")),
        "z_count": int(z_count),
        "t_count": int(t_count),
        "source_format": fmt,
        # Additive extras.
        "is_rgb": bool(extras.get("is_rgb", False)),
        "dtype": source_dtype,
        "z_project": mode,
        "all_channel_names": all_names,
        "reader": reader,
        "axes": canon_axes,
    }

    _log("loaded {} via {}: {}x{} C={} z_count={} t_count={} "
         "z_project={} dtype={} px_um={}".format(
             os.path.basename(path), reader, stack.shape[1], stack.shape[0],
             stack.shape[2], z_count, t_count, mode, source_dtype,
             meta["pixel_size_um"]))
    return stack, meta


def to_uint8(arr, meta=None):
    """Scale a float32 plane/stack to the uint8 range detectors expect.

    8-bit sources pass through untouched (bit-identical to the old PIL path);
    everything else is min/max stretched, which is what the previous loader
    did for PIL's "I"/"F" modes and is the only sane choice for 16-bit
    microscopy. The RAW values stay available on the array returned by
    `load_planes` for quantification.
    """
    import numpy as np

    a = np.asarray(arr, dtype=np.float32)
    dtype = str((meta or {}).get("dtype", ""))
    if dtype == "uint8":
        return np.clip(a, 0, 255).astype(np.uint8)

    lo = float(a.min()) if a.size else 0.0
    hi = float(a.max()) if a.size else 0.0
    if hi > lo:
        a = (a - lo) / (hi - lo) * 255.0
    else:
        a = np.zeros_like(a)
    return np.clip(a, 0, 255).astype(np.uint8)


def rgb_luminance(stack):
    """ITU-R 601-2 luma, bit-identical to `PIL.Image.convert("L")`.

    Pillow's `rgb2l` uses fixed-point weights, not the decimal 299/587/114
    ones — `(R*19595 + G*38470 + B*7471 + 0x8000) >> 16`. Reproducing that
    exactly keeps the RGB grayscale path byte-for-byte identical to the loader
    this module replaced (verified against Pillow 11 over random RGB data).
    """
    import numpy as np

    a = np.asarray(stack, dtype=np.float64)
    luma = (a[..., 0] * 19595.0
            + a[..., 1] * 38470.0
            + a[..., 2] * 7471.0
            + 32768.0) / 65536.0
    return np.floor(luma).astype(np.float32)
