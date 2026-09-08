import { useCallback, useEffect, useRef, useState, type MouseEvent } from "react";
import { ArrowDown, ArrowLeft, ArrowRight, Microscope, Pause, Play, RotateCcw } from "lucide-react";
import type { ParticleField } from "../visuals/particleField";
import "../styles/welcome.css";

const chapters = [
  { id: "see", label: "See" },
  { id: "separate", label: "Separate" },
  { id: "measure", label: "Measure" },
  { id: "work", label: "Work" },
] as const;

/** Actual section positions remain the anchors when type wraps or the viewport changes. */
function progressAtScroll(container: HTMLElement, sections: readonly (HTMLElement | null)[]): number {
  const origin = container.getBoundingClientRect().top;
  const positions = sections.map((section) => section ? section.getBoundingClientRect().top - origin + container.scrollTop : 0);
  for (let index = 0; index < positions.length - 1; index++) {
    if (container.scrollTop < positions[index + 1]) {
      return index + Math.max(0, Math.min(1, (container.scrollTop - positions[index]) / Math.max(1, positions[index + 1] - positions[index])));
    }
  }
  return chapters.length - 1;
}

export default function WelcomeScene({ onOpen }: { onOpen(): void }) {
  const scroller = useRef<HTMLElement>(null);
  const sections = useRef<Array<HTMLElement | null>>([]);
  const host = useRef<HTMLDivElement>(null);
  const field = useRef<ParticleField | undefined>(undefined);
  const scrollFrame = useRef<number | undefined>(undefined);
  const selectedShape = useRef(0);
  const currentChapter = useRef(0);
  const renderedChapter = useRef(0);
  const [chapter, setChapter] = useState(0);
  const [illustratedChapter, setIllustratedChapter] = useState(0);
  const [paused, setPaused] = useState(false);
  const [reduced, setReduced] = useState(() => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches);
  const [unavailable, setUnavailable] = useState(false);
  const [ready, setReady] = useState(false);
  const moving = !paused && !reduced;
  const currentMotion = useRef(moving);
  currentMotion.current = moving;

  const readScroll = useCallback(() => {
    if (!scroller.current || sections.current.length !== chapters.length) return;
    const progress = progressAtScroll(scroller.current, sections.current);
    const nearest = Math.round(progress);
    if (nearest !== currentChapter.current) { currentChapter.current = nearest; setChapter(nearest); }
    if (!currentMotion.current) return;
    selectedShape.current = progress;
    field.current?.setShape(progress);
    if (nearest !== renderedChapter.current) { renderedChapter.current = nearest; setIllustratedChapter(nearest); }
  }, []);

  const scheduleScroll = useCallback(() => {
    if (scrollFrame.current !== undefined) return;
    scrollFrame.current = requestAnimationFrame(() => { scrollFrame.current = undefined; readScroll(); });
  }, [readScroll]);

  useEffect(() => {
    const preference = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : undefined;
    const update = () => setReduced(preference?.matches ?? false);
    preference?.addEventListener("change", update);
    window.addEventListener("resize", scheduleScroll, { passive: true });
    let cancelled = false;
    void import("../visuals/particleField").then(({ createParticleField }) => {
      if (cancelled || !host.current) return;
      field.current = createParticleField(host.current, () => { if (!cancelled) setUnavailable(true); });
      field.current.setMotion(currentMotion.current);
      field.current.setShape(selectedShape.current, true);
      setReady(true);
    }).catch(() => { if (!cancelled) setUnavailable(true); });
    return () => {
      cancelled = true;
      preference?.removeEventListener("change", update);
      window.removeEventListener("resize", scheduleScroll);
      if (scrollFrame.current !== undefined) cancelAnimationFrame(scrollFrame.current);
      scrollFrame.current = undefined;
      field.current?.dispose(); field.current = undefined;
    };
  }, [scheduleScroll]);

  useEffect(() => {
    field.current?.setMotion(moving);
    if (moving) readScroll();
  }, [moving, readScroll]);

  const goToChapter = (event: MouseEvent<HTMLAnchorElement>, index: number) => {
    event.preventDefault();
    const container = scroller.current, section = sections.current[index];
    if (!container || !section) return;
    selectedShape.current = index;
    renderedChapter.current = index;
    setIllustratedChapter(index);
    field.current?.setShape(index, !currentMotion.current);
    const top = section.getBoundingClientRect().top - container.getBoundingClientRect().top + container.scrollTop;
    container.scrollTo({ top, behavior: "instant" });
    currentChapter.current = index; setChapter(index);
    section.focus({ preventScroll: true });
  };

  const motionStatus = unavailable ? "Illustration unavailable · workspace ready" : !ready ? "Preparing illustration…" : reduced ? "Static illustration · reduced motion" : paused ? `Illustration paused · ${chapters[illustratedChapter].label}` : "Illustration · drag or scroll";

  return <main className={`welcome ${unavailable ? "welcome-no-renderer" : ""}`} ref={scroller} onScroll={scheduleScroll}>
    <div className="welcome-particle-host" ref={host} role="img" aria-label="An illustrative point cloud changes from a cell-like form to separated cells, object boundaries, and an ordered field. This is an illustration, not microscopy data or analysis output. Use the stage links and rotation controls as alternatives to scrolling and dragging." />

    <header className="welcome-header">
      <a className="welcome-brand" href="#welcome-see" onClick={(event) => goToChapter(event, 0)}><Microscope size={23} strokeWidth={1.6} aria-hidden="true" /><span>CellCounter</span></a>
      <span className="welcome-header-note">Microscopy, made measurable.</span>
      <button className="welcome-open" onClick={onOpen}>Open workspace <ArrowRight size={17} aria-hidden="true" /></button>
    </header>

    <div className="welcome-chapters">
      <section className="welcome-section welcome-see" id="welcome-see" ref={(element) => { sections.current[0] = element; }} aria-labelledby="welcome-title" tabIndex={-1}>
        <div className="welcome-copy">
          <p className="welcome-kicker"><span>01</span> See</p>
          <h1 id="welcome-title">Look closely.<br />Count with<br /><em>confidence.</em></h1>
          <p className="welcome-description">Bring microscopy images into focus. Inspect the source, choose your channel, and set the scale.</p>
          <a className="welcome-next" href="#welcome-separate" onClick={(event) => goToChapter(event, 1)}>Follow the image <ArrowDown size={17} aria-hidden="true" /></a>
        </div>
        <p className="welcome-field-caption">A study in form.<br /><span>An illustration, not analysis output.</span></p>
      </section>

      <section className="welcome-section welcome-separate" id="welcome-separate" ref={(element) => { sections.current[1] = element; }} aria-labelledby="welcome-separate-title" tabIndex={-1}>
        <div className="welcome-copy">
          <p className="welcome-kicker"><span>02</span> Separate</p>
          <h2 id="welcome-separate-title">Every cell deserves<br /><em>a closer look.</em></h2>
          <p className="welcome-description">Preview a representative field before processing the study. Keep the settings and progress with every saved result.</p>
          <p className="welcome-detail">Pause a batch. Return to it later.<br />Pick up where the saved work ends.</p>
          <a className="welcome-next" href="#welcome-measure" onClick={(event) => goToChapter(event, 2)}>Look beyond the count <ArrowDown size={17} aria-hidden="true" /></a>
        </div>
      </section>

      <section className="welcome-section welcome-measure" id="welcome-measure" ref={(element) => { sections.current[2] = element; }} aria-labelledby="welcome-measure-title" tabIndex={-1}>
        <div className="welcome-copy">
          <p className="welcome-kicker"><span>03</span> Measure</p>
          <h2 id="welcome-measure-title">Connect the count<br /><em>to the evidence.</em></h2>
          <p className="welcome-description">Select an object and follow it to its measurements. Review the masks, make corrections, and export the result with its context.</p>
          <p className="welcome-detail">One image. Each object.<br />A record of how you got there.</p>
          <a className="welcome-next" href="#welcome-work" onClick={(event) => goToChapter(event, 3)}>Make it your work <ArrowDown size={17} aria-hidden="true" /></a>
        </div>
      </section>

      <section className="welcome-section welcome-work" id="welcome-work" ref={(element) => { sections.current[3] = element; }} aria-labelledby="welcome-work-title" tabIndex={-1}>
        <div className="welcome-copy">
          <p className="welcome-kicker"><span>04</span> Work</p>
          <h2 id="welcome-work-title">Your images.<br /><em>Your judgment.</em></h2>
          <p className="welcome-description">A private workbench for the decisions that matter. Your images and analysis stay in this browser, on this device.</p>
          <button className="welcome-primary" onClick={onOpen}>Open workspace <ArrowRight size={18} aria-hidden="true" /></button>
          <p className="welcome-capability">Classical segmentation is ready in the browser.<br />{" "}Learned-model weights are not bundled in this version.</p>
          <p className="welcome-version">CellCounter Web · 0.2.1</p>
        </div>
      </section>
    </div>

    <div className="welcome-utilities">
      <nav className="welcome-stage-links" aria-label="Introduction stages">{chapters.map(({ id, label }, index) => <a key={id} href={`#welcome-${id}`} aria-current={chapter === index ? "location" : undefined} onClick={(event) => goToChapter(event, index)}><span aria-hidden="true">0{index + 1}</span>{label}</a>)}</nav>
      <div className="welcome-motion">
        <p className="welcome-motion-status" role="status">{motionStatus}</p>
        <div className="welcome-camera" role="group" aria-label="Illustration controls">
          <button onClick={() => field.current?.rotate(1)} aria-label="Rotate illustration left" title="Rotate left" disabled={unavailable || !ready}><ArrowLeft size={17} /></button>
          <button onClick={() => field.current?.rotate(-1)} aria-label="Rotate illustration right" title="Rotate right" disabled={unavailable || !ready}><ArrowRight size={17} /></button>
          <button onClick={() => field.current?.reset()} aria-label="Reset illustration view" title="Reset view" disabled={unavailable || !ready}><RotateCcw size={17} /></button>
          <button className="welcome-pause" onClick={() => setPaused((value) => !value)} aria-label={moving ? "Pause illustration" : "Resume illustration"} disabled={unavailable || reduced || !ready}>{moving ? <Pause size={16} /> : <Play size={16} />}<span>{reduced ? "Motion off" : moving ? "Pause" : "Resume"}</span></button>
        </div>
      </div>
    </div>
  </main>;
}
