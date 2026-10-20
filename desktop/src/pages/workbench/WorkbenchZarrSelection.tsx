import type { StorageRegion, StorageSelection, ZarrSource } from '../../../../shared/workbench/storageProtocol';
export function zarrDimensions(source: ZarrSource | undefined, path: string): Record<string, number> {
  const array = source?.arrays.find(item => item.path === path);
  return Object.fromEntries(array?.axes.map((axis, index) => [axis.name, array.shape[index]]) ?? []);
}
export default function WorkbenchZarrSelection({ sources, value, onChange, disabled }: {
  sources: ZarrSource[]; value: StorageSelection; onChange: (value: StorageSelection) => void; disabled?: boolean;
}) {
  const source = sources.find(item => item.id === value.sourceId);
  const array = source?.arrays.find(item => item.path === value.arrayPath);
  const dimensions = zarrDimensions(source, value.arrayPath);
  return <fieldset disabled={disabled}><legend>NGFF source and acquisition selection</legend>
    <label>Registered source<select value={value.sourceId} onChange={event => {
      const next = sources.find(item => item.id === event.target.value);
      onChange({ sourceId: event.target.value, arrayPath: next?.arrays[0]?.path ?? '', timeIndex: 0, channel: 0, zIndex: 0 });
    }}><option value="">Choose a registered source</option>{sources.map(item => <option key={item.id} value={item.id}>{item.name} · NGFF {item.ngffVersion} / Zarr {item.zarrFormat}{item.available ? '' : ' · directory missing'}</option>)}</select></label>
    {source ? <><p className="workbench-project-path">{source.path}</p><p>Directory {source.available ? 'present' : 'unavailable'}. External ranges are verified when used; directory presence alone is not verification.</p>
      <label>Resolution level<select value={value.arrayPath} onChange={event => onChange({ ...value, arrayPath: event.target.value, timeIndex: 0, channel: 0, zIndex: 0 })}>{source.arrays.map(item => <option key={item.path} value={item.path}>{item.name || 'Image'} · level {item.level} · {item.path} · {item.shape.join(' × ')}</option>)}</select></label>
      {array ? <><p>{array.axes.map(item => `${item.name}${item.unit ? ` (${item.unit})` : ''}`).join(' × ')} · {array.dtype} · chunks {array.chunks.join(' × ')}</p>
        <p>Selected-level pixel size: X {array.voxelSizeUm.x ?? 'unknown'} µm; Y {array.voxelSizeUm.y ?? 'unknown'} µm. Unknown spacing is not replaced with a default.</p></> : null}
      <div className="workbench-editor-grid">{([['timeIndex', 'Time point', dimensions.t ?? 1], ['channel', 'Channel', dimensions.c ?? 1], ['zIndex', 'Z plane', dimensions.z ?? 1]] as const).map(([key, label, maximum]) => <label key={key}>{label} (starting at 1)<input type="number" min={1} max={maximum} value={value[key] + 1} onChange={event => onChange({ ...value, [key]: Number(event.target.value) - 1 })} /></label>)}</div>
    </> : null}
  </fieldset>;
}
export function WorkbenchZarrRegion({ value, onChange, disabled, maxPixels }: {
  value: StorageRegion; onChange: (value: StorageRegion) => void; disabled?: boolean; maxPixels?: number;
}) {
  return <fieldset disabled={disabled}><legend>Exact region on the selected resolution level</legend>
    <div className="workbench-editor-grid">{(['x', 'y', 'width', 'height'] as const).map(key => <label key={key}>{key === 'x' || key === 'y' ? `${key.toUpperCase()} origin (starting at 0)` : `${key} (source pixels)`}<input type="number" min={key === 'x' || key === 'y' ? 0 : 1} value={value[key]} onChange={event => onChange({ ...value, [key]: Number(event.target.value) })} /></label>)}</div>
    <p>{(value.width * value.height).toLocaleString()} exact selected-level pixels{maxPixels ? ` · limit ${maxPixels.toLocaleString()}` : ''}. Overview sampling does not change this source grid.</p>
  </fieldset>;
}
