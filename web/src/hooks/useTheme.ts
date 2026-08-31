import { useEffect, useState } from "react";

export type ThemeMode = "light" | "dark";

function preferredTheme(): ThemeMode {
  const saved = localStorage.getItem("cellcounter-theme");
  if (saved === "light" || saved === "dark") return saved;
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function useTheme() {
  const [theme, setTheme] = useState<ThemeMode>(preferredTheme);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("cellcounter-theme", theme);
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", theme === "dark" ? "#101817" : "#f4f3ee");
  }, [theme]);

  return { theme, toggleTheme: () => setTheme((current) => (current === "light" ? "dark" : "light")) };
}
