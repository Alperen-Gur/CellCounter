/**
 * components/Sidebar.tsx — the shell's left navigation rail.
 *
 * Search field + grouped nav (from NAV_SECTIONS) + bottom-pinned footer
 * (NAV_FOOTER). Renders line icons and live counts read read-only from the
 * FROZEN store's LibrarySlice. Typing in search filters the rail to matching
 * destinations. Purely presentational; owns no feature logic.
 */

import { useMemo, useState } from "react";
import {
  NAV_SECTIONS,
  NAV_FOOTER,
  ROUTES,
  type RouteId,
  type RouteDef,
} from "./routes";
import { Icon } from "./Icon";
import { useAppStore } from "../kernel/store/store";

interface SidebarProps {
  activeId: RouteId;
  collapsed: boolean;
  onNavigate: (id: RouteId) => void;
}

export function Sidebar({ activeId, collapsed, onNavigate }: SidebarProps) {
  const reviewQueueCount = useAppStore((s) => s.reviewQueueCount);
  const libraryImageCount = useAppStore((s) => s.libraryImageCount);
  const libraryBatchCount = useAppStore((s) => s.libraryBatchCount);
  const [query, setQuery] = useState("");

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

  const routeById = useMemo(() => {
    const m = new Map<RouteId, RouteDef>();
    for (const r of ROUTES) m.set(r.id, r);
    return m;
  }, []);

  const q = query.trim().toLowerCase();
  const filtered = (id: RouteId) =>
    !q || (routeById.get(id)?.label.toLowerCase().includes(q) ?? false);

  const renderItem = (id: RouteId) => {
    const route = routeById.get(id);
    if (!route || !filtered(id)) return null;
    const badge = badgeFor(id);
    const isActive = id === activeId;
    return (
      <button
        key={id}
        type="button"
        className={"cc-navitem" + (isActive ? " cc-navitem--active" : "")}
        aria-current={isActive ? "page" : undefined}
        onClick={() => onNavigate(id)}
        title={collapsed ? route.label : undefined}
      >
        <span className="cc-navitem__icon">
          <Icon name={route.icon} size={18} />
        </span>
        <span className="cc-navitem__label">{route.label}</span>
        {badge !== undefined && (
          <span className="cc-navitem__badge">{badge}</span>
        )}
      </button>
    );
  };

  return (
    <nav
      className={"cc-sidebar" + (collapsed ? " cc-sidebar--collapsed" : "")}
      aria-label="Primary"
    >
      <div className="cc-sidebar__search">
        <span className="cc-sidebar__search-icon" aria-hidden="true">
          <Icon name="search" size={16} />
        </span>
        <input
          className="cc-sidebar__search-input"
          type="text"
          placeholder="Search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search"
          spellCheck={false}
        />
      </div>

      <div className="cc-sidebar__scroll">
        {NAV_SECTIONS.map((section, i) => {
          const items = section.routeIds.map(renderItem).filter(Boolean);
          if (items.length === 0) return null;
          return (
            <div key={section.title || `sec-${i}`} className="cc-sidebar__section">
              {section.title && (
                <div className="cc-sidebar__section-title">{section.title}</div>
              )}
              {items}
            </div>
          );
        })}
      </div>

      <div className="cc-sidebar__footer">
        {NAV_FOOTER.map(renderItem)}
      </div>
    </nav>
  );
}
