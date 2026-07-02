/**
 * components/Sidebar.tsx — the shell's left navigation rail.
 *
 * Renders the grouped nav from `NAV_SECTIONS` and highlights the active route.
 * Reads a few derived counts from the FROZEN store's LibrarySlice
 * (libraryImageCount / libraryBatchCount / reviewQueueCount) to show live
 * badges — this is read-only consumption of the kernel store, never a mutation
 * of its shape. Purely presentational otherwise; it owns no feature logic.
 */

import { NAV_SECTIONS, ROUTES, type RouteId } from "./routes";
import { useAppStore } from "../kernel/store/store";

interface SidebarProps {
  activeId: RouteId;
  onNavigate: (id: RouteId) => void;
}

export function Sidebar({ activeId, onNavigate }: SidebarProps) {
  const reviewQueueCount = useAppStore((s) => s.reviewQueueCount);
  const libraryImageCount = useAppStore((s) => s.libraryImageCount);
  const libraryBatchCount = useAppStore((s) => s.libraryBatchCount);

  const badgeFor = (id: RouteId): number | undefined => {
    switch (id) {
      case "review":
        return reviewQueueCount || undefined;
      case "library":
        return libraryImageCount || undefined;
      case "batch":
        return libraryBatchCount || undefined;
      default:
        return undefined;
    }
  };

  return (
    <nav className="cc-sidebar" aria-label="Primary">
      <div className="cc-sidebar__brand">
        <span className="cc-sidebar__logo" aria-hidden="true">
          🧫
        </span>
        <span className="cc-sidebar__brand-name">CellCounter</span>
      </div>

      <div className="cc-sidebar__scroll">
        {NAV_SECTIONS.map((section) => (
          <div key={section.title} className="cc-sidebar__section">
            <div className="cc-sidebar__section-title">{section.title}</div>
            {section.routeIds.map((id) => {
              const route = ROUTES.find((r) => r.id === id);
              if (!route) return null;
              const badge = badgeFor(id);
              const isActive = id === activeId;
              return (
                <button
                  key={id}
                  type="button"
                  className={
                    "cc-navitem" + (isActive ? " cc-navitem--active" : "")
                  }
                  aria-current={isActive ? "page" : undefined}
                  onClick={() => onNavigate(id)}
                >
                  <span className="cc-navitem__icon" aria-hidden="true">
                    {route.icon}
                  </span>
                  <span className="cc-navitem__label">{route.label}</span>
                  {badge !== undefined && (
                    <span className="cc-navitem__badge">{badge}</span>
                  )}
                </button>
              );
            })}
          </div>
        ))}
      </div>

      <div className="cc-sidebar__footer">
        <span className="cc-sidebar__version">v0.1 · cyto3</span>
      </div>
    </nav>
  );
}
