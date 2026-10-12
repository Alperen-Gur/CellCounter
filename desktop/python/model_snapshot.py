"""Install-time exact checkpoint capture and read-only readiness probing."""
from __future__ import annotations
import argparse, hashlib, importlib.metadata, json, os, sys
from pathlib import Path


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def packages(kind):
    names={'cellpose':['cellpose','torch','numpy'],'cellpose4':['cellpose','torch','numpy'],'stardist':['stardist','csbdeep','tensorflow','numpy'],'omnipose':['omnipose','torch','numpy'],'classical':['scikit-image','scipy','numpy']}[kind]
    return {name:importlib.metadata.version(name) for name in names}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--model-id',required=True);parser.add_argument('--runtime-name',required=True);parser.add_argument('--kind',required=True);parser.add_argument('--ready-path',required=True);parser.add_argument('--probe',action='store_true');args=parser.parse_args()
    ready=Path(args.ready_path);versions=packages(args.kind)
    if args.kind == 'omnipose':
        from omnipose_detect import configure_model_cache
        configure_model_cache(args.runtime_name)
    if args.probe:
        record=json.loads(ready.read_text(encoding='utf-8'))
        if record.get('schemaVersion')!=1 or record.get('modelId')!=args.model_id or record.get('runtimeName')!=args.runtime_name or record.get('packages')!=versions:raise ValueError('Exact runtime has changed; reinstall this model')
        for checkpoint in record.get('checkpoints',[]):
            path=Path(checkpoint['path'])
            if not path.is_file() or path.stat().st_size!=checkpoint['bytes'] or digest(path)!=checkpoint['sha256']:raise ValueError('Exact checkpoint is missing or changed; reinstall this model')
        return
    paths=[];name=args.runtime_name
    if args.kind in ('cellpose','cellpose4'):
        from cellpose import models
        if name not in getattr(models,'MODEL_NAMES',()) and name!='cpsam':raise ValueError(f'Exact checkpoint {name} is unavailable in this installed Cellpose runtime')
        if args.model_id=='cp-cyto3-r':
            from cellpose import denoise
            model=denoise.CellposeDenoiseModel(gpu=False,model_type=name,restore_type='denoise_cyto3')
            for part,expected in [(model.cp,name),(model.dn,'denoise_cyto3')]:
                path=Path(str(part.pretrained_model))
                if expected not in path.name:raise ValueError('Restoration runtime substituted a different checkpoint')
                paths.append(path)
        else:
            model=models.CellposeModel(gpu=False,**({'pretrained_model':name} if args.kind=='cellpose4' else {'model_type':name}))
            path=Path(str(model.pretrained_model))
            if (args.kind=='cellpose4' and path.name!=name) or (args.kind=='cellpose' and name not in path.name):raise ValueError('Runtime substituted a different checkpoint')
            paths.append(path)
    elif args.kind=='stardist':
        from stardist.models import StarDist2D
        model=StarDist2D.from_pretrained(name)
        directory=Path(model.basedir)/model.name
        paths=[directory/'config.json']+[directory/member for member in ('weights_best.h5','weights_now.h5','thresholds.json') if (directory/member).is_file()]
        if len(paths)<2:raise ValueError('StarDist exact checkpoint weights are missing')
    elif args.kind=='omnipose':
        from cellpose_omni import models
        if name not in models.MODEL_NAMES:raise ValueError('Exact Omnipose model is unavailable')
        model=models.CellposeModel(gpu=False,model_type=name,omni=True,nchan=2,nclasses=3,dim=2)
        raw=model.pretrained_model;paths=[Path(value) for value in raw] if isinstance(raw,(list,tuple)) else [Path(raw)]
        if not paths or any(name not in p.name for p in paths):raise ValueError('Omnipose runtime substituted checkpoint')
    elif args.kind=='classical':
        import numpy, scipy, skimage, PIL  # noqa: F401
    else:raise ValueError('Unsupported snapshot kind')
    checkpoints=[]
    for path in paths:
        path=path.resolve(strict=True)
        if not path.is_file() or path.stat().st_size>2*1024*1024*1024:raise ValueError('Checkpoint file is invalid or exceeds 2 GiB')
        checkpoints.append({'path':str(path),'sha256':digest(path),'bytes':path.stat().st_size})
    record={'schemaVersion':1,'modelId':args.model_id,'runtimeName':name,'packages':versions,'checkpoints':checkpoints,'python':sys.version.split()[0]}
    ready.parent.mkdir(parents=True,exist_ok=True);temporary=ready.with_suffix('.partial')
    try:
        with temporary.open('w',encoding='utf-8') as stream:json.dump(record,stream,indent=2);stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,ready)
    finally:
        temporary.unlink(missing_ok=True)

if __name__=='__main__':
    try:main()
    except Exception as exc:print(str(exc),file=sys.stderr);sys.exit(2)
