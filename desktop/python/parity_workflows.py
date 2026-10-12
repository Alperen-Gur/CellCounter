"""Bounded local source inspection, adaptive prompts, and reviewed snapshots.
No model is inferred or substituted by this helper. The host resolves sources.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
import re
import shutil
import sys
import uuid
from pathlib import Path

MAX_PIXELS = 16_000_000
MAX_PREVIEW_PIXELS = 1_000_000


def verify_source(request):
    expected = request.get('sourceHash')
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-fA-F]{64}', expected):
        raise ValueError('Preserved source identity is unavailable; reimport before source workflows.')
    path = Path(request['sourcePath'])
    before = path.stat()
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino) or digest.hexdigest() != expected.lower():
        raise ValueError('Preserved source bytes changed after import; reimport and review again.')
    return path, after


def load_source(request):
    import numpy as np
    import _imageio
    # Reader shape budgets are checked before materialization where the reader
    # exposes a header. Also preflight source dimensions supplied by the DB.
    source_path, source_stat = verify_source(request)
    width, height = int(request.get('sourceWidth', 0)), int(request.get('sourceHeight', 0))
    if width * height > MAX_PIXELS: raise ValueError('Source inspection is limited to 16 megapixels.')
    _imageio.MAX_RAW_SOURCE_BYTES = 256 * 1024 * 1024
    _imageio.MAX_PROJECTED_FLOAT_BYTES = 64 * 1024 * 1024
    stack, meta = _imageio.load_planes(request['sourcePath'], z_project=request.get('projection', 'max'), channel=None,
                                     t_index=request.get('timeIndex', 0), z_index=request.get('zIndex'), require_lossless_f32=True)
    after_decode = source_path.stat()
    if (source_stat.st_size, source_stat.st_mtime_ns, source_stat.st_ino) != (after_decode.st_size, after_decode.st_mtime_ns, after_decode.st_ino):
        raise ValueError('Source changed while reading; retry from a stable imported source.')
    if stack.shape[0] * stack.shape[1] > MAX_PIXELS:
        raise ValueError('Source inspection is limited to 16 megapixels. Open a lower-resolution workspace level or crop the source.')
    if not np.isfinite(stack).all():
        raise ValueError('Source contains non-finite intensity values.')
    channel = request.get('channel')
    pair = request.get('detectionChannels')
    scalar_policy = request.get('sourcePolicy')
    rgb_mean = False
    if pair is not None:
        if len(pair) != 2 or any(not isinstance(value, int) or value not in range(4) for value in pair):
            raise ValueError('Captured Cellpose channel mapping is invalid')
        if scalar_policy == 'legacyRgbMean' and pair != [0,0]:
            selected = 0 if channel is None else channel
            if not isinstance(selected,int) or selected<0 or selected>=stack.shape[2]:
                raise ValueError('Captured segmentation channel is unavailable')
            order = [selected]+[c for c in range(stack.shape[2]) if c!=selected]
            # Legacy RGB input pads missing slots with zero. Its scalar view
            # is explicitly the mean of those three input slots, not an
            # acquired primary channel inferred from Cellpose's channel pair.
            plane = stack[...,order[:3]].sum(axis=2,dtype=np.float64)/3
            rgb_mean = True
        elif pair[0] == 0 and pair[1] != 0:
            raise ValueError('A gray-plus-nuclear legacy mapping has no unambiguous acquired primary plane; rerun with explicit channels before quantitative source workflows.')
        elif pair[0] != 0:
            selected = 0 if channel is None else channel
            if not isinstance(selected, int) or selected < 0 or selected >= stack.shape[2]:
                raise ValueError('Captured segmentation channel is unavailable')
            order = [selected] + [c for c in range(stack.shape[2]) if c != selected]
            slot = pair[0] - 1
            if slot >= min(3, len(order)):
                raise ValueError('Captured primary Cellpose channel maps to zero padding; no acquired source plane exists')
            channel = order[slot]
    if rgb_mean:
        plane = plane.astype(np.float32)
    elif channel is None:
        plane = stack[...,:3].mean(axis=2,dtype=np.float64).astype(np.float32) if scalar_policy=='rgbMeanIfAutomatic' and meta.get('is_rgb') and stack.shape[2]>=3 else _imageio.rgb_luminance(stack) if meta.get('is_rgb') and stack.shape[2] >= 3 else stack[..., 0]
    else:
        if not isinstance(channel, int) or channel < 0 or channel >= stack.shape[2]:
            raise ValueError(f'Source channel {channel} is unavailable; source has {stack.shape[2]} channels.')
        plane = stack[..., channel]
    return stack, plane, meta


def source(request):
    import numpy as np
    from PIL import Image
    stack, plane, meta = load_source(request)
    h, w = plane.shape
    if request.get('workspaceExact') and w*h > 4_000_000: raise ValueError('Exact workspace planes support up to four megapixels; choose a lower-resolution OME-Zarr level.')
    stride = 1 if request.get('workspaceExact') or request.get('exportFull') else max(1, math.ceil(math.sqrt(w * h / MAX_PREVIEW_PIXELS)))
    values = plane[::stride, ::stride]
    lo, hi = np.percentile(values, (1, 99))
    display = np.clip((values - lo) / max(float(hi - lo), 1e-12) * 255, 0, 255).astype(np.uint8)
    image = Image.fromarray(display)
    # The display may be downsampled; geometry and calibration remain source-pixel.
    output = request['previewPath']
    image.save(output, format='PNG')
    return {'path': output, 'width': w, 'height': h, 'previewWidth': int(values.shape[1]), 'previewHeight': int(values.shape[0]),
            'imageId':request['imageId'],'sourceHash':request.get('sourceHash'),'sourcePolicy':request.get('sourcePolicy','acquiredChannelOrRgbLuminance'),'pxPerUm':request['pxPerUm'],'calibrationSource':request.get('calibrationSource','default'),'stride': stride, 'channelCount': int(stack.shape[2]), 'channelNames': meta.get('channel_names') or [],
            'min': float(lo), 'max': float(hi), 'tCount':meta.get('t_count',1), 'zCount':meta.get('z_count',1), 'values': values.ravel().tolist() if request.get('includeValues') else None}


def prompt(request):
    import numpy as np
    stack, plane, _ = load_source(request)
    del stack
    px_per_um = float(request['pxPerUm'])
    if not math.isfinite(px_per_um) or px_per_um <= 0:
        raise ValueError('Calibration must be positive.')
    coords = request['prompt']
    if len(coords) not in (2, 4) or not all(math.isfinite(float(x)) for x in coords):
        raise ValueError('A prompt needs finite point or box coordinates.')
    h, w = plane.shape
    if len(coords) == 4:
        xa, ya, xb, yb = map(float, coords)
        if abs(xb - xa) < 1 or abs(yb - ya) < 1:
            raise ValueError('Draw a box with positive area.')
        cx, cy = (xa + xb) / 2, (ya + yb) / 2
        x0, y0, x1, y1 = min(xa, xb), min(ya, yb), max(xa, xb), max(ya, yb)
    else:
        cx, cy = map(float, coords)
        side = min(1024, max(96, float(request.get('diameterPx', 32)) * 4))
        x0, y0, x1, y1 = cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2
    if not (0 <= cx < w and 0 <= cy < h):
        raise ValueError('Prompt must lie inside the source image.')
    x0, y0, x1, y1 = max(0, int(x0)), max(0, int(y0)), min(w, math.ceil(x1)), min(h, math.ceil(y1))
    crop = plane[y0:y1, x0:x1]
    if crop.size > 1_000_000:
        raise ValueError('Prompt crop exceeds one megapixel; draw a smaller box.')
    lo, hi = float(crop.min()), float(crop.max())
    if hi <= lo:
        raise ValueError('Prompt did not isolate an object in a uniform region.')
    hist, edges = np.histogram(crop, bins=256, range=(lo, hi))
    probabilities = hist.astype(np.float64) / hist.sum()
    weights = np.cumsum(probabilities)
    means = np.cumsum(probabilities * edges[:-1])
    scores = (means[-1] * weights - means) ** 2 / np.maximum(weights * (1 - weights), 1e-12)
    threshold = edges[int(scores.argmax())]
    sx, sy = int(cx) - x0, int(cy) - y0
    seed_mean = float(crop[max(0, sy-3):sy+4, max(0, sx-3):sx+4].mean())
    mask = crop <= threshold if seed_mean < float(crop.mean()) else crop > threshold
    if not mask[sy, sx]:
        yy, xx = np.nonzero(mask[max(0, sy-12):sy+13, max(0, sx-12):sx+13])
        if not len(xx):
            raise ValueError('Prompt contains no foreground.')
        xx += max(0, sx-12); yy += max(0, sy-12)
        i = int(np.argmin((xx-sx)**2 + (yy-sy)**2)); sx, sy = int(xx[i]), int(yy[i])
    visited = np.zeros(mask.shape, dtype=np.bool_)
    queue = np.empty((crop.size,2),dtype=np.int32);queue[0]=(sx,sy);count=1;cursor=0;visited[sy,sx]=True
    while cursor<count:
        x,y=map(int,queue[cursor]);cursor+=1
        for xx, yy in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
            if 0 <= xx < mask.shape[1] and 0 <= yy < mask.shape[0] and mask[yy,xx] and not visited[yy,xx]:
                visited[yy,xx] = True;queue[count]=(xx,yy);count+=1
    if count < 9 or count > crop.size * .95:
        raise ValueError('Prompt did not isolate a usable object; draw a tighter box.')
    ys, xs = np.nonzero(visited); xs = xs + x0; ys = ys + y0
    cx, cy = float(xs.mean()), float(ys.mean())
    # Radial envelope matches the native adaptive fallback, explicitly marked.
    angles = np.arctan2(ys-cy, xs-cx); radii = (xs-cx)**2 + (ys-cy)**2
    contour = []
    for index in range(96):
        sector = np.where((angles >= -math.pi + index*2*math.pi/96) & (angles < -math.pi + (index+1)*2*math.pi/96))[0]
        if len(sector):
            i = sector[np.argmax(radii[sector])]; contour.append([float(xs[i]),float(ys[i])])
    if len(contour) < 3:
        raise ValueError('Prompt contour is degenerate.')
    contour.append(contour[0])
    diameter = 2*math.sqrt(count/math.pi)
    return {'backend': 'adaptive connected-component contour', 'cell': {'id': request.get('replacingId') or str(uuid.uuid4()), 'cx':cx,'cy':cy,
            'diameterUm':diameter/px_per_um,'diameterPx':diameter,'areaUm2':count/px_per_um**2,
            'confidence':1,'isManual':True,'contourPx':contour}}


def channels(request):
    import numpy as np
    from PIL import Image, ImageDraw
    stack, _, meta = load_source(request)
    h,w,n = stack.shape
    output=[]
    work=0;vertices=0;prepared=[]
    if len(request.get('cells', [])) > 50_000: raise ValueError('Channel inspection is limited to 50,000 cells; select a smaller field.')
    for cell in request.get('cells', []):
        if not all(math.isfinite(float(cell[k])) for k in ('cx','cy','diameterPx')) or cell['diameterPx']<=0: raise ValueError('Invalid channel-inspection mask geometry')
        radius = max(1, float(cell['diameterPx'])/2)
        polygon=cell.get('contourPx')
        points = polygon if polygon and len(polygon) >= 3 else None
        if points and (len(points)>10000 or any(len(p)!=2 or not all(math.isfinite(float(v)) for v in p) for p in points)): raise ValueError('Invalid channel-inspection contour')
        if points:
            x0,y0 = max(0, int(min(p[0] for p in points))), max(0,int(min(p[1] for p in points)))
            x1,y1 = min(w, math.ceil(max(p[0] for p in points))+1), min(h, math.ceil(max(p[1] for p in points))+1)
        else:
            x0,y0=max(0,int(cell['cx']-radius)),max(0,int(cell['cy']-radius))
            x1,y1=min(w,math.ceil(cell['cx']+radius)+1),min(h,math.ceil(cell['cy']+radius)+1)
        if x1 <= x0 or y1 <= y0: continue
        work += (x1-x0)*(y1-y0)*n; vertices += len(points) if points else 0
        if work>100_000_000 or vertices>500_000: raise ValueError('Channel inspection exceeds its aggregate sample/contour budget; select fewer or smaller masks')
        prepared.append((cell,radius,points,x0,y0,x1,y1))
    for cell,radius,points,x0,y0,x1,y1 in prepared:
        mask=Image.new('1',(x1-x0,y1-y0)); draw=ImageDraw.Draw(mask)
        if points: draw.polygon([(x-x0,y-y0) for x,y in points],fill=1)
        else: draw.ellipse((cell['cx']-radius-x0,cell['cy']-radius-y0,cell['cx']+radius-x0,cell['cy']+radius-y0),fill=1)
        selected=stack[y0:y1,x0:x1][np.array(mask,dtype=bool)]
        output.append({'id':cell['id'],'means':selected.mean(axis=0,dtype=np.float64).tolist() if len(selected) else [None]*n})
    return {'channelCount':n,'channelNames':meta.get('channel_names') or [],'cells':output,'geometry':'source contour or explicit circle approximation'}


def dataset(request):
    import numpy as np
    from PIL import Image, ImageDraw
    samples=request.get('samples',[])
    if not samples: raise ValueError('Select reviewed images with nonempty masks.')
    groups={s['group'] for s in samples}
    if len(groups)<3: raise ValueError('A training snapshot needs at least three independent specimen groups.')
    target=Path(request['outDir'])/('reviewed-'+str(uuid.UUID(request['snapshotId'])))
    temporary=target.with_name('.'+target.name+'.partial')
    temporary.mkdir(parents=True, exist_ok=False)
    manifest={'schemaVersion':1,'id':str(uuid.uuid4()),'createdAt':request['createdAt'],'samples':[],'geometry':'complete reviewed source contours; overlapping/out-of-bounds masks rejected'}
    assignments={}; hashes=set(); source_hashes=set()
    raster_work=0;total_pixels=0
    try:
        for sample in samples:
            try: uuid.UUID(sample['imageId'])
            except (ValueError, KeyError): raise ValueError('Invalid image identity in training snapshot')
            calibration=float(sample['pxPerUm'])
            if not math.isfinite(calibration) or calibration <= 0: raise ValueError('Training calibration must be positive')
            raw_hash=sample.get('sourceHash')
            if raw_hash in source_hashes: raise ValueError('Duplicate source images cannot cross specimen splits')
            source_hashes.add(raw_hash)
            _,plane,meta=load_source(sample)
            h,w=plane.shape; total_pixels+=h*w
            if total_pixels>128_000_000: raise ValueError('Training source planes exceed 128 megapixels in aggregate; export fewer fields')
            labels=np.zeros((h,w),dtype=np.uint16)
            cells=sample['cells']
            if len(cells)>65535: raise ValueError('16-bit masks support at most 65,535 instances.')
            for index,cell in enumerate(cells,1):
                if not all(math.isfinite(float(cell[field])) for field in ('cx','cy','diameterPx','diameterUm','confidence')) or cell['diameterPx'] <= 0:
                    raise ValueError('Invalid reviewed geometry')
                pts=cell.get('contourPx')
                if pts and any(len(p)!=2 or not all(math.isfinite(float(v)) for v in p) for p in pts): raise ValueError('Invalid source contour')
                if pts and len(pts)>10000: raise ValueError('Reviewed contour exceeds the vertex budget')
                if not pts or len(pts)<3: raise ValueError('Training requires complete reviewed contours; circle approximations cannot become ground truth')
                if any(x<0 or y<0 or x>w or y>h for x,y in pts): raise ValueError('Reviewed contour lies outside the source bounds')
                x0,y0=max(0,int(min(x for x,y in pts))),max(0,int(min(y for x,y in pts)))
                x1,y1=min(w,math.ceil(max(x for x,y in pts))+1),min(h,math.ceil(max(y for x,y in pts))+1)
                if x1<=x0 or y1<=y0: raise ValueError('Reviewed contour has no in-bounds pixels')
                raster_work += (x1-x0)*(y1-y0)
                if raster_work>256_000_000: raise ValueError('Training mask rasterization exceeds its bounded work budget; choose fewer or smaller fields')
                mask=Image.new('1',(x1-x0,y1-y0)); draw=ImageDraw.Draw(mask)
                draw.polygon([(x-x0,y-y0) for x,y in pts],fill=1)
                pixels=np.asarray(mask,dtype=bool); region=labels[y0:y1,x0:x1]
                if not pixels.any(): raise ValueError('Each reviewed instance needs in-bounds pixels')
                if np.any(region[pixels] != 0): raise ValueError('Reviewed masks overlap; resolve overlapping instances before immutable training export')
                region[pixels]=index
            stem=sample['imageId']; image_name=stem+'.tif'; mask_name=stem+'_masks.tif'
            Image.fromarray(plane.astype(np.float32)).save(temporary/image_name,format='TIFF')
            Image.fromarray(np.asarray(labels,dtype=np.uint16)).save(temporary/mask_name,format='TIFF')
            digest=hashlib.sha256((temporary/image_name).read_bytes()).hexdigest()
            if digest in hashes: raise ValueError('Duplicate image content cannot cross specimen splits.')
            hashes.add(digest); assignments[image_name]=sample['group']
            manifest['samples'].append({'imageId':stem,'sourceHash':sample.get('sourceHash'),'imageSha256':digest,'maskSha256':hashlib.sha256((temporary/mask_name).read_bytes()).hexdigest(),
                'group':sample['group'],'pxPerUm':sample['pxPerUm'],'detectorId':sample['detectorId'],'reviewConfidence':sample.get('reviewConfidence'),
                'instanceIds':[c['id'] for c in cells],'fileName':image_name,'maskFile':mask_name,'run':sample.get('run')})
        manifest['specimenGroups']=sorted(groups)
        manifest['splitPolicy']='Group-isolated split is chosen and recorded by the training runner; images from one specimen must stay together.'
        (temporary/'groups.json').write_text(json.dumps(assignments,indent=2),encoding='utf-8')
        (temporary/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
        # Publication belongs to the host, after it observes successful completion.
    except BaseException:
        shutil.rmtree(temporary,ignore_errors=True); raise
    return {'path':str(target),'stagingPath':str(temporary),'samples':len(samples),'groups':len(groups)}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--request',required=True);args=parser.parse_args()
    try:
        request=json.loads(Path(args.request).read_text(encoding='utf-8'))
        functions={'source':source,'prompt':prompt,'channels':channels,'dataset':dataset}
        fn=functions.get(request.get('operation'))
        if fn is None: raise ValueError('Unknown local workflow.')
        print(json.dumps(fn(request),allow_nan=False))
    except Exception as exc:
        print(json.dumps({'error':'local-workflow-failed','hint':str(exc)}));sys.exit(3)

if __name__=='__main__': main()
