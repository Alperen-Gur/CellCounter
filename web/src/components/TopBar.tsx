import { CircleHelp, CloudOff, Moon, Sun } from "lucide-react";
import { BrandMark } from "./BrandMark";
import type { ThemeMode } from "../hooks/useTheme";

interface TopBarProps {
  theme: ThemeMode;
  toggleTheme: () => void;
  onHelp: () => void;
  projectName: string;
}

export function TopBar({ theme, toggleTheme, onHelp, projectName }: TopBarProps) {
  return (
    <header className="topbar">
      <BrandMark />
      <div className="project-title" title={projectName}>
        <span>{projectName}</span>
        <em>Saved in this browser</em>
      </div>
      <div className="top-actions">
        <span className="privacy-pill"><CloudOff size={14} /> No image uploads</span>
        <button className="icon-button" onClick={toggleTheme} aria-label={`Switch to ${theme === "light" ? "dark" : "light"} theme`}>
          {theme === "light" ? <Moon size={18} /> : <Sun size={18} />}
        </button>
        <button className="icon-button" onClick={onHelp} aria-label="Help and about"><CircleHelp size={18} /></button>
      </div>
    </header>
  );
}
