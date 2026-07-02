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

import { Icon } from "./Icon";

interface StubPageProps {
  /** Human-readable screen name, e.g. "Results". */
  name: string;
  /** The feature task id that owns this page (docs/tasks.json). */
  owner: string;
  /** Optional glyph; defaults to a generic marker. */
  glyph?: string;
}

export function StubPage({ name, owner, glyph }: StubPageProps) {
  return (
    <section className="cc-stub" aria-label={`${name} placeholder`}>
      <style>{STUB_STYLES}</style>
      <div className="cc-stub__card">
        <div className="cc-stub__glyph" aria-hidden="true">
          {glyph ? glyph : <Icon name="layers" size={22} />}
        </div>
        <div className="cc-stub__title">{name}</div>
        <div className="cc-stub__badge">Coming in feature pass</div>
        <p className="cc-stub__msg">
          This screen's shell mount point is ready. Its interactions and layout
          arrive when the owning feature task is implemented.
        </p>
        <span className="cc-stub__owner">
          <Icon name="info" size={13} />
          owner: {owner}
        </span>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Scoped styles (design tokens from styles/theme.css; self-contained)
// ---------------------------------------------------------------------------

const STUB_STYLES = `
.cc-stub {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100%;
  padding: var(--cc-space-8) var(--cc-space-6);
}
.cc-stub__card {
  display: flex;
  flex-direction: column;
  align-items: center;
  text-align: center;
  gap: var(--cc-space-2);
  width: min(440px, 100%);
  padding: var(--cc-space-8) var(--cc-space-6);
  border: 1px solid var(--cc-border);
  border-radius: var(--cc-radius-xl);
  background: var(--cc-bg-subtle);
}
.cc-stub__glyph {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 52px;
  height: 52px;
  margin-bottom: var(--cc-space-2);
  border-radius: var(--cc-radius-lg);
  background: var(--cc-bg-elevated);
  border: 1px solid var(--cc-border);
  color: var(--cc-text-secondary);
  font-size: 22px;
  line-height: 1;
}
.cc-stub__title {
  font-family: var(--cc-font-display);
  font-size: var(--cc-text-xl);
  font-weight: 650;
  letter-spacing: -0.01em;
  color: var(--cc-text);
}
.cc-stub__badge {
  display: inline-flex;
  align-items: center;
  padding: 2px 10px;
  border-radius: 999px;
  background: var(--cc-bg-active);
  color: var(--cc-text-secondary);
  font-size: var(--cc-text-xs);
  font-weight: 600;
  letter-spacing: 0.02em;
  text-transform: uppercase;
}
.cc-stub__msg {
  margin: var(--cc-space-2) 0 var(--cc-space-3);
  max-width: 340px;
  color: var(--cc-text-secondary);
  font-size: var(--cc-text-md);
  line-height: 1.55;
}
.cc-stub__owner {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-family: var(--cc-font-mono);
  font-size: var(--cc-text-xs);
  color: var(--cc-text-tertiary);
}
`;
