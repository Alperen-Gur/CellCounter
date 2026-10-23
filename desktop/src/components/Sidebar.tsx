import { NAV_SECTIONS, NAV_FOOTER, ROUTES, isExistingLibraryRoute, type RouteId } from "./routes";
import { Icon } from "./Icon";

interface SidebarProps {
  activeId: RouteId;
  collapsed: boolean;
  onNavigate: (id: RouteId) => void;
}
const routeById = new Map(ROUTES.map(route => [route.id, route]));

/** Application destinations only; the active project owns its task navigation. */
export function Sidebar({ activeId, collapsed, onNavigate }: SidebarProps) {
  const renderItem = (id: RouteId) => {
    const route = routeById.get(id);
    if (!route) return null;
    const active = id === activeId || id === "existing-library" && isExistingLibraryRoute(activeId);
    return <button key={id} type="button" className={`cc-navitem${active ? " cc-navitem--active" : ""}`}
      aria-current={active ? "page" : undefined} aria-label={route.label}
      onClick={() => onNavigate(id)} title={collapsed ? route.label : undefined}>
      <span className="cc-navitem__icon" aria-hidden="true"><Icon name={route.icon} size={18} /></span>
      <span className="cc-navitem__label">{route.label}</span>
    </button>;
  };
  return <nav className={`cc-sidebar${collapsed ? " cc-sidebar--collapsed" : ""}`} aria-label="Application">
    <div className="cc-sidebar__scroll">
      {NAV_SECTIONS.map((section, index) => <div key={section.title || index} className="cc-sidebar__section">
        {section.title ? <div className="cc-sidebar__section-title">{section.title}</div> : null}
        {section.routeIds.map(renderItem)}
      </div>)}
    </div>
    <div className="cc-sidebar__footer">{NAV_FOOTER.map(renderItem)}</div>
  </nav>;
}
