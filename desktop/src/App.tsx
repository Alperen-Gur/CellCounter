import { Suspense, useEffect, useState } from "react";
import { LocalTimingIndicator } from "./pages/system/LocalDiagnosticsPanel";
import { TitleBar } from "./components/TitleBar";
import { Sidebar } from "./components/Sidebar";
import { Icon } from "./components/Icon";
import { KeyboardShortcutsSheet } from "./components/KeyboardShortcutsSheet";
import { AppearancePreferencesProvider } from "./components/AppearancePreferences";
import { useHashRoute } from "./components/useHashRoute";
import { useKeymap } from "./components/useKeymap";
import { initAppData } from "./components/appInit";
import { isExistingLibraryRoute, WORKBENCH_ROUTE } from "./components/routes";
import { openWorkbench } from "./components/workbenchNavigation";
import { WorkbenchVisibility } from "./components/WorkbenchVisibility";
import { OnboardingRoot } from "./pages/onboarding/OnboardingRoot";
import "./styles/theme.css";
import "./styles/shell.css";

const Workbench = WORKBENCH_ROUTE.component;

function App() {
  const { route, navigate } = useHashRoute();
  const [shortcutsOpen, setShortcutsOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  // The active project and its drafts survive visits to preferences or older records.
  const [workbenchOpened, setWorkbenchOpened] = useState(route.id === "workbench");
  useEffect(() => { if (route.id === "workbench") setWorkbenchOpened(true); }, [route.id]);
  useEffect(() => { if ("__TAURI_INTERNALS__" in window) void initAppData(); }, []);

  useKeymap("global", { showShortcuts: () => setShortcutsOpen(true) }, { allowInInputs: true });
  useKeymap("application", {
    newProject: () => openWorkbench({ kind: "new-project" }),
    openProject: () => openWorkbench({ kind: "open-project" }),
    openImages: () => openWorkbench({ kind: "import" }),
    settings: () => navigate("settings"),
    preparation: () => openWorkbench({ kind: "task", task: "preparation" }),
    segmentation: () => openWorkbench({ kind: "task", task: "segmentation" }),
    measurements: () => openWorkbench({ kind: "task", task: "measurements" }),
    review: () => openWorkbench({ kind: "task", task: "review" }),
    workflows: () => openWorkbench({ kind: "task", task: "workflows" }),
    export: () => openWorkbench({ kind: "task", task: "export" }),
  }, { allowInInputs: true });

  const PageComponent = route.component;
  const existingLibrary = isExistingLibraryRoute(route.id);
  return <AppearancePreferencesProvider>
    <div className="cc-app">
      <TitleBar />
      <div className="cc-body">
        <Sidebar activeId={route.id} collapsed={collapsed} onNavigate={navigate} />
        <div className="cc-main">
          <header className="cc-topbar">
            <button type="button" className="cc-iconbtn" onClick={() => setCollapsed(value => !value)}
              aria-label={collapsed ? "Expand application navigation" : "Collapse application navigation"}
              aria-expanded={!collapsed} title="Toggle application navigation"><Icon name="menu" size={18} /></button>
            <nav className="cc-breadcrumb" aria-label="Breadcrumb">
              <span className="cc-breadcrumb__root">CellCounter</span>
              <Icon name="chevronRight" size={15} className="cc-breadcrumb__sep" />
              {existingLibrary && route.id !== "existing-library" ? <>
                <button type="button" className="cc-breadcrumb__link" onClick={() => navigate("existing-library")}>Existing library</button>
                <Icon name="chevronRight" size={15} className="cc-breadcrumb__sep" />
              </> : null}
              <span className="cc-breadcrumb__here">{route.label}</span>
            </nav>
            <span className="cc-topbar__spacer" />
            <button type="button" className="cc-iconbtn" onClick={() => setShortcutsOpen(true)}
              aria-label="Keyboard shortcuts" title="Keyboard shortcuts"><Icon name="info" size={18} /></button>
          </header>
          <main className="cc-content">
            {existingLibrary && route.id !== "existing-library" ? <aside className="cc-library-context" aria-label="Existing library context">
              <span>These are original library records. Workbench projects have their own images, settings and history.</span>
              <button type="button" className="cc-btn" onClick={() => openWorkbench({ kind: "library-import" })}>Import into Workbench…</button>
            </aside> : null}
            {workbenchOpened || route.id === "workbench" ? <div hidden={route.id !== "workbench"} className="cc-route-pane">
              <WorkbenchVisibility.Provider value={route.id === "workbench"}>
                <Suspense fallback={<div className="cc-loading" role="status">Opening Workbench…</div>}><Workbench /></Suspense>
              </WorkbenchVisibility.Provider>
            </div> : null}
            {route.id !== "workbench" ? <Suspense fallback={<div className="cc-loading" role="status">Opening {route.label}…</div>}><PageComponent /></Suspense> : null}
          </main>
        </div>
      </div>
      <KeyboardShortcutsSheet open={shortcutsOpen} onClose={() => setShortcutsOpen(false)} />
      <LocalTimingIndicator />
      <OnboardingRoot />
    </div>
  </AppearancePreferencesProvider>;
}
export default App;
