/**
 * components/StubPage.tsx — shared placeholder for not-yet-built feature pages.
 *
 * Every `pages/<name>/*Page.tsx` stub renders this so the app is fully
 * navigable before any feature lands. A stub imports ONLY this component (never
 * a sibling page), which keeps the 14 page directories physically disjoint —
 * the whole point of the shell. When a feature engineer fills their directory,
 * they replace their stub's body and this component is simply no longer used
 * there.
 */

interface StubPageProps {
  /** Human-readable screen name, e.g. "Results". */
  name: string;
  /** The feature task id that owns this page (docs/tasks.json). */
  owner: string;
  /** Optional glyph; defaults to a generic marker. */
  glyph?: string;
}

export function StubPage({ name, owner, glyph = "🧩" }: StubPageProps) {
  return (
    <section className="cc-stub" aria-label={`${name} placeholder`}>
      <div className="cc-stub__glyph" aria-hidden="true">
        {glyph}
      </div>
      <div className="cc-stub__title">{name} — coming in feature pass</div>
      <p className="cc-stub__msg">
        This screen's shell mount point is ready. Its interactions and layout
        arrive when the owning feature task is implemented.
      </p>
      <span className="cc-stub__owner">owner: {owner}</span>
    </section>
  );
}
