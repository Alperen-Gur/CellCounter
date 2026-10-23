import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

type Theme = "system" | "light" | "dark";
const AppearanceContext = createContext<{ theme: Theme; setTheme: (value: Theme) => void } | null>(null);

export function AppearancePreferencesProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<Theme>(() => {
    const saved = localStorage.getItem("cc-theme");
    return saved === "light" || saved === "dark" ? saved : "system";
  });
  useEffect(() => {
    localStorage.setItem("cc-theme", theme);
    const media = matchMedia("(prefers-color-scheme: dark)");
    const apply = () => { document.documentElement.dataset.theme = theme === "system" ? media.matches ? "dark" : "light" : theme; };
    apply();
    media.addEventListener("change", apply);
    return () => media.removeEventListener("change", apply);
  }, [theme]);
  return <AppearanceContext.Provider value={{ theme, setTheme }}>{children}</AppearanceContext.Provider>;
}

export function AppearancePreference() {
  const appearance = useContext(AppearanceContext);
  if (!appearance) return null;
  return <label className="cc-appearance-preference">Appearance
    <select value={appearance.theme} onChange={event => appearance.setTheme(event.target.value as Theme)}>
      <option value="system">Follow system</option><option value="light">Light</option><option value="dark">Dark</option>
    </select>
  </label>;
}
