/**
 * components/Icon.tsx — the app's line-icon set.
 *
 * Inline SVG (no CDN, CSP-safe, offline) in a consistent 24×24 stroke style
 * (Lucide-leaning) so the whole UI shares one crisp, monochrome icon language
 * instead of emoji. Icons inherit `currentColor` and scale via the `size` prop.
 */

import type { CSSProperties, ReactElement } from "react";

export type IconName =
  | "menu"
  | "search"
  | "home"
  | "queue"
  | "image"
  | "batches"
  | "models"
  | "finetune"
  | "trash"
  | "support"
  | "settings"
  | "calibrate"
  | "folder"
  | "images"
  | "compare"
  | "review"
  | "results"
  | "chevronDown"
  | "chevronRight"
  | "scope"
  | "windowMin"
  | "windowMax"
  | "windowClose";

interface IconProps {
  name: IconName;
  size?: number;
  strokeWidth?: number;
  className?: string;
  style?: CSSProperties;
}

// Each entry is the inner markup of a 24×24 viewBox, drawn with the shared
// stroke attributes below.
const PATHS: Record<IconName, ReactElement> = {
  menu: (
    <>
      <line x1="3" y1="6" x2="21" y2="6" />
      <line x1="3" y1="12" x2="21" y2="12" />
      <line x1="3" y1="18" x2="21" y2="18" />
    </>
  ),
  search: (
    <>
      <circle cx="11" cy="11" r="7" />
      <line x1="21" y1="21" x2="16.65" y2="16.65" />
    </>
  ),
  home: (
    <>
      <path d="M3 10.5 12 3l9 7.5" />
      <path d="M5 9.5V20a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V9.5" />
    </>
  ),
  queue: (
    <>
      <line x1="4" y1="7" x2="20" y2="7" />
      <line x1="4" y1="12" x2="20" y2="12" />
      <line x1="4" y1="17" x2="14" y2="17" />
    </>
  ),
  image: (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2.5" />
      <circle cx="8.5" cy="9.5" r="1.75" />
      <path d="m4 18 5-5 4 4 3-3 4 4" />
    </>
  ),
  batches: (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2.5" />
      <line x1="3" y1="9" x2="21" y2="9" />
      <line x1="9" y1="9" x2="9" y2="20" />
    </>
  ),
  models: (
    <>
      <rect x="6" y="6" width="12" height="12" rx="2" />
      <path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3" />
      <rect x="10" y="10" width="4" height="4" rx="0.6" />
    </>
  ),
  finetune: (
    <>
      <path d="M12 3v3M12 18v3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M3 12h3M18 12h3M4.9 19.1l2.1-2.1M17 7l2.1-2.1" />
      <circle cx="12" cy="12" r="3" />
    </>
  ),
  trash: (
    <>
      <path d="M4 7h16" />
      <path d="M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" />
      <path d="M6 7l1 13a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-13" />
      <line x1="10" y1="11" x2="10" y2="17" />
      <line x1="14" y1="11" x2="14" y2="17" />
    </>
  ),
  support: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M9.2 9.2a2.8 2.8 0 1 1 4.2 2.6c-.9.6-1.4 1-1.4 2" />
      <line x1="12" y1="17" x2="12" y2="17" />
    </>
  ),
  settings: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1Z" />
    </>
  ),
  calibrate: (
    <>
      <path d="M3.5 8.5 8.5 3.5a1.5 1.5 0 0 1 2.1 0l9.9 9.9a1.5 1.5 0 0 1 0 2.1l-5 5a1.5 1.5 0 0 1-2.1 0L3.5 10.6a1.5 1.5 0 0 1 0-2.1Z" />
      <path d="M7 9l1.5 1.5M10 6l1.5 1.5M13 9l1.5 1.5M9 13l1.5 1.5" />
    </>
  ),
  folder: (
    <>
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
    </>
  ),
  images: (
    <>
      <rect x="7" y="3" width="14" height="14" rx="2.5" />
      <circle cx="11" cy="8" r="1.5" />
      <path d="m8 15 3.5-3.5 3 3 2-2 4 4" />
      <path d="M17 21H5a2 2 0 0 1-2-2V8" />
    </>
  ),
  compare: (
    <>
      <line x1="5" y1="20" x2="5" y2="10" />
      <line x1="12" y1="20" x2="12" y2="4" />
      <line x1="19" y1="20" x2="19" y2="13" />
    </>
  ),
  review: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="m8.5 12 2.5 2.5 4.5-4.5" />
    </>
  ),
  results: (
    <>
      <circle cx="11" cy="11" r="6" />
      <line x1="20" y1="20" x2="15.5" y2="15.5" />
      <circle cx="11" cy="11" r="2" />
    </>
  ),
  chevronDown: <path d="m6 9 6 6 6-6" />,
  chevronRight: <path d="m9 6 6 6-6 6" />,
  scope: (
    <>
      <circle cx="12" cy="12" r="9" />
      <circle cx="12" cy="12" r="3.5" />
      <circle cx="12" cy="12" r="0.5" fill="currentColor" />
    </>
  ),
  windowMin: <line x1="5" y1="12" x2="19" y2="12" />,
  windowMax: <rect x="6" y="6" width="12" height="12" rx="1.5" />,
  windowClose: (
    <>
      <line x1="6" y1="6" x2="18" y2="18" />
      <line x1="18" y1="6" x2="6" y2="18" />
    </>
  ),
};

export function Icon({
  name,
  size = 18,
  strokeWidth = 1.75,
  className,
  style,
}: IconProps) {
  return (
    <svg
      className={"cc-icon" + (className ? " " + className : "")}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      style={style}
    >
      {PATHS[name]}
    </svg>
  );
}

export default Icon;
