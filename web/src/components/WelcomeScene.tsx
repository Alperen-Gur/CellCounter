import { useEffect, useRef, useState } from "react";
import { ArrowDown, ArrowLeft, ArrowRight, Microscope, Pause, Play, RotateCcw } from "lucide-react";
import type { ParticleField } from "../visuals/particleField";
import "../styles/welcome.css";

const shapes = ["Membrane", "Division", "Orbits"];

export default function WelcomeScene({ onOpen }: { onOpen(): void }) {
  const scroller = useRef<HTMLElement>(null);
  const host = useRef<HTMLDivElement>(null);
  const field = useRef<ParticleField | undefined>(undefined);
  const [shape, setShape] = useState(0);
  const selectedShape = useRef(0);
  const [paused, setPaused] = useState(false);
  const [reduced, setReduced] = useState(() => matchMedia("(prefers-reduced-motion: reduce)").matches);
  const [unavailable, setUnavailable] = useState(false);
  const [ready, setReady] = useState(false);
  const moving = !paused && !reduced;
  const currentMotion = useRef(moving);
  currentMotion.current = moving;

  useEffect(() => {
    const preference = matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReduced(preference.matches);
    preference.addEventListener("change", update);
    let cancelled = false;
    void import("../visuals/particleField").then(({ createParticleField }) => {
      if (cancelled || !host.current) return;
      field.current = createParticleField(host.current, () => setUnavailable(true));
      field.current.setMotion(currentMotion.current);
      field.current.setShape(selectedShape.current, true);
      setReady(true);
    }).catch(() => { if (!cancelled) setUnavailable(true); });
    return () => { cancelled = true; preference.removeEventListener("change", update); field.current?.dispose(); field.current = undefined; };
  }, []);
  useEffect(() => { field.current?.setMotion(moving); }, [moving]);
  const chooseShape = (index: number) => { selectedShape.current = index; setShape(index); field.current?.setShape(index, !moving); };

  return <main className="welcome" ref={scroller} onScroll={() => {
    if (!moving || !scroller.current) return;
    const element = scroller.current;
    const progress = Math.min(2, element.scrollTop / Math.max(1, element.clientHeight * 0.65) * 2);
    selectedShape.current = progress;
    field.current?.setShape(progress);
    const nearest = Math.round(progress);
    if (nearest !== shape) setShape(nearest);
  }}>
    <header className="welcome-header">
      <a className="welcome-brand" href="#" onClick={(event) => { event.preventDefault(); scroller.current?.scrollTo({ top: 0, behavior: "instant" }); }}><Microscope size={23} strokeWidth={1.6} aria-hidden="true" />CellCounter<span>WEB</span></a>
      <div><span className="welcome-local">On your device. In your control.</span><button className="welcome-open" onClick={onOpen}>Open workspace <ArrowRight size={17} aria-hidden="true" /></button></div>
    </header>
    <section className="welcome-hero" aria-labelledby="welcome-title">
      <div className="welcome-copy">
        <p className="welcome-kicker">A closer look. A clearer count.</p>
        <h1 id="welcome-title">From cells<br />to <em>evidence.</em></h1>
        <p className="welcome-description">Turn microscopy images into measurements you can inspect, correct and trace back to the source.</p>
        <button className="welcome-primary" onClick={onOpen}>Start an analysis <ArrowRight size={18} aria-hidden="true" /></button>
        <p className="welcome-assurance">No account. No image uploads.<br />Your work stays in this browser.</p>
        <a className="welcome-scroll" href="#welcome-method" onClick={(event) => { event.preventDefault(); scroller.current?.scrollTo({ top: scroller.current.clientHeight * 0.8, behavior: moving ? "smooth" : "instant" }); }}>Explore the workflow <ArrowDown size={15} aria-hidden="true" /></a>
      </div>
      <div className="welcome-art">
        <div className="welcome-art-caption"><span>01—03 / A study in form</span><span>Interactive illustration</span></div>
        <div className="welcome-particle-host" ref={host} role="img" aria-label="An illustrative three-dimensional point cloud. Use the controls below to rotate it or change its shape." />
        {!ready && !unavailable && <p className="welcome-render-state">Preparing the illustration…</p>}
        {unavailable && <p className="welcome-render-state">The illustration is unavailable on this device.<br />The analysis workspace is still available.</p>}
        <div className="welcome-art-controls">
          <div className="welcome-shapes" role="group" aria-label="Illustration shape">{shapes.map((name, index) => <button key={name} aria-pressed={shape === index} onClick={() => chooseShape(index)} disabled={unavailable}>{name}</button>)}</div>
          <div className="welcome-camera" role="group" aria-label="Illustration controls">
            <button onClick={() => field.current?.rotate(1)} aria-label="Rotate illustration left" disabled={unavailable}><ArrowLeft size={16} /></button>
            <button onClick={() => field.current?.rotate(-1)} aria-label="Rotate illustration right" disabled={unavailable}><ArrowRight size={16} /></button>
            <button onClick={() => field.current?.reset()} aria-label="Reset illustration view" disabled={unavailable}><RotateCcw size={15} /></button>
            <button onClick={() => setPaused((value) => !value)} aria-label={moving ? "Pause illustration" : "Resume illustration"} disabled={unavailable || reduced}>{moving ? <Pause size={15} /> : <Play size={15} />}</button>
          </div>
        </div>
        <p className="welcome-art-hint">{reduced ? "Reduced motion is on. Choose a shape or rotate using the controls." : paused ? "Motion paused. Shape and rotation controls remain available." : "Drag to rotate · Scroll to transform · Or use the controls"}</p>
      </div>
    </section>
    <section className="welcome-method" id="welcome-method" aria-labelledby="welcome-method-title">
      <div className="welcome-method-heading"><p className="welcome-kicker">Made for the work between images and insight</p><h2 id="welcome-method-title">Keep the image.<br />Understand the result.</h2></div>
      <ol className="welcome-steps">
        <li><span>01</span><div><h3>Inspect & prepare</h3><p>Import your images. Choose the source channel and scale before making a measurement.</p></div></li>
        <li><span>02</span><div><h3>Preview & process</h3><p>Try a representative field, then process the study with saved settings and progress.</p></div></li>
        <li><span>03</span><div><h3>Review & export</h3><p>Connect each cell with its measurements. Correct the masks and export results with context.</p></div></li>
      </ol>
    </section>
    <footer className="welcome-footer"><p>Classical segmentation runs here without model downloads.<br />Cellpose and StarDist are available in the native apps; browser model weights are still being prepared.</p><button onClick={onOpen}>Open workspace <ArrowRight size={17} aria-hidden="true" /></button><span>CellCounter Web · 0.2.0</span></footer>
  </main>;
}
