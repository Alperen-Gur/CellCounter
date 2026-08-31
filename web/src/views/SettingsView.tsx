import { CloudOff, Keyboard, MonitorCog, Moon, ShieldCheck, Sun } from "lucide-react";
import type { ThemeMode } from "../hooks/useTheme";

export function SettingsView({ theme, onTheme, onHelp }: { theme: ThemeMode; onTheme: () => void; onHelp: () => void }) {
  return (
    <main className="page-view settings-view">
      <header className="page-heading"><div><span className="eyebrow">This browser</span><h1>Preferences</h1><p>Settings are local to this browser profile.</p></div></header>
      <div className="settings-groups">
        <section><div className="settings-title"><MonitorCog size={19} /><div><h2>Appearance</h2><p>Match your viewing environment.</p></div></div><button className="preference-row" onClick={onTheme}><span>{theme === "light" ? <Sun size={17} /> : <Moon size={17} />} Color theme</span><strong>{theme === "light" ? "Light" : "Dark"}</strong></button><button className="preference-row" onClick={onHelp}><span><Keyboard size={17} /> Keyboard shortcuts</span><strong>View</strong></button></section>
        <section><div className="settings-title"><ShieldCheck size={19} /><div><h2>Privacy boundary</h2><p>Enforced by the application security policy.</p></div></div><div className="privacy-contract"><CloudOff size={22} /><div><strong>No image uploads</strong><p>Imported pixels, model inference, edits, persistence, and exports stay on this device. CellCounter Web has no analytics or telemetry endpoint.</p></div></div></section>
      </div>
    </main>
  );
}
