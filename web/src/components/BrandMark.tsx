export function BrandMark({ compact = false }: { compact?: boolean }) {
  return (
    <div className="brand-mark" aria-label="CellCounter">
      <span className="brand-orbit"><i /><b /></span>
      {!compact && <span className="brand-word">CellCounter <sup>WEB</sup></span>}
    </div>
  );
}
