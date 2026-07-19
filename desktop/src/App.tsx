/**
 * App.tsx — the CellCounter application shell.
 *
 * Draws the custom Windows-native chrome (TitleBar) + left Sidebar + a content
 * top bar (breadcrumb · model selector · Calibrate · settings) around a
 * hash-routed content pane that renders exactly one feature page. Routing is the
 * dependency-free `useHashRoute` + `ROUTES` registry, so route state lives in
 * the URL hash, never in the FROZEN kernel store.
 *
 * Shell-owned: feature engineers fill their `pages/<name>/` directory and never
 * edit App.tsx, the router, the Sidebar, the TitleBar, or the theme.
 */

import { Suspense, useEffect, useState } from "react";

import { TitleBar } from "./components/TitleBar";
import { Sidebar } from "./components/Sidebar";
import { Icon } from "./components/Icon";
import { KeyboardShortcutsSheet } from "./components/KeyboardShortcutsSheet";
import { useHashRoute } from "./components/useHashRoute";
import { initAppData } from "./components/appInit";
import { OnboardingRoot } from "./pages/onboarding/OnboardingRoot";
import { modelLabel } from "./pages/models/catalog";
import { useAppStore } from "./kernel/store/store";

import "./styles/theme.css";
import "./styles/shell.css";

function App() {
  const { route, navigate } = useHashRoute();
  const [shortcutsOpen, setShortcutsOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const activeModelId = useAppStore((s) => s.activeModelId);

  useEffect(() => {
    void initAppData();
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing =
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable);
      if (!typing && e.key === "?") {
        e.preventDefault();
        setShortcutsOpen((v) => !v);
      }
      if (e.key === "Escape") setShortcutsOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const PageComponent = route.component;

  return (
    <div className="cc-app">
      <TitleBar />

      <div className="cc-body">
        <Sidebar activeId={route.id} collapsed={collapsed} onNavigate={navigate} />

        <div className="cc-main">
          <header className="cc-topbar">
            <button
              type="button"
              className="cc-iconbtn"
              onClick={() => setCollapsed((v) => !v)}
              aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
              title="Toggle sidebar"
            >
              <Icon name="menu" size={18} />
            </button>

            <nav className="cc-breadcrumb" aria-label="Breadcrumb">
              <span className="cc-breadcrumb__root">CellCounter</span>
              <Icon name="chevronRight" size={15} className="cc-breadcrumb__sep" />
              <span className="cc-breadcrumb__here">{route.label}</span>
            </nav>

            <span className="cc-topbar__spacer" />

            <button
              type="button"
              className="cc-model"
              onClick={() => navigate("models")}
              title="Choose detection model"
            >
              <span className="cc-model__label">MODEL</span>
              <span className="cc-model__value">{modelLabel(activeModelId)}</span>
              <Icon name="chevronDown" size={15} className="cc-model__chev" />
            </button>

            <button
              type="button"
              className="cc-btn"
              onClick={() => navigate("onboarding")}
              title="Set the pixel scale"
            >
              <Icon name="calibrate" size={16} />
              Calibrate
            </button>

            <button
              type="button"
              className="cc-iconbtn"
              onClick={() => navigate("settings")}
              aria-label="Settings"
              title="Settings"
            >
              <Icon name="settings" size={18} />
            </button>
          </header>

          <main className="cc-content">
            <Suspense fallback={<div className="cc-loading">Loading…</div>}>
              <PageComponent />
            </Suspense>
          </main>
        </div>
      </div>

      <KeyboardShortcutsSheet
        open={shortcutsOpen}
        onClose={() => setShortcutsOpen(false)}
      />

      {/* Modal host for calibration/onboarding (reached via Calibrate or first
          run). Auto-launch is off until the tour UI is restyled to match. */}
      <OnboardingRoot />
    </div>
  );
}

export default App;
