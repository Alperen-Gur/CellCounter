/**
 * pages/system/ComingSoon.tsx — shared placeholder for rail destinations that
 * are designed but not yet built (Fine-tune, Recently deleted, Support). Reads
 * the active route so one component serves all three with tailored copy.
 */

import { useHashRoute } from "../../components/useHashRoute";
import { Icon, type IconName } from "../../components/Icon";
import "./coming-soon.css";

const COPY: Record<string, { icon: IconName; blurb: string; tag: string }> = {
  finetune: {
    icon: "finetune",
    tag: "Planned",
    blurb:
      "Fine-tune Cellpose on your own corrected cells — turn the masks you fix by hand into a model that fits your images. Landing in a future release.",
  },
  trash: {
    icon: "trash",
    tag: "Coming soon",
    blurb:
      "Images and batches you delete will rest here so you can restore them before they're gone for good.",
  },
  support: {
    icon: "support",
    tag: "Coming soon",
    blurb:
      "Documentation, keyboard shortcuts, and how to reach a human when something goes wrong.",
  },
};

export default function ComingSoon() {
  const { route } = useHashRoute();
  const copy = COPY[route.id] ?? {
    icon: route.icon,
    tag: "Coming soon",
    blurb: "This section isn't ready yet.",
  };

  return (
    <div className="cs-wrap">
      <div className="cs-card">
        <span className="cs-glyph" aria-hidden="true">
          <Icon name={copy.icon} size={30} strokeWidth={1.6} />
        </span>
        <span className="cs-tag">{copy.tag}</span>
        <h1 className="cs-title">{route.label}</h1>
        <p className="cs-blurb">{copy.blurb}</p>
      </div>
    </div>
  );
}
