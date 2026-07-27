import { useCallback, useEffect, useRef, useState } from "react";
import { strokesToMnist } from "./lib/strokesToMnist";
import "./DigitCanvas.css";

const BRUSH_SIZE = 0.025;
const RECOGNITION_DELAY_MS = 550;
const MIN_POINT_DIST = 0.001;

/**
 * Drawing pad — full white board is drawable (phone + desktop).
 */
export default function DigitCanvas({ apiUrl, onResult, compact = false }) {
  const canvasRef = useRef(null);
  const cardRef = useRef(null);
  const strokesRef = useRef([]);
  const currentRef = useRef(null);
  const timerRef = useRef(null);
  const abortRef = useRef(null);
  const revRef = useRef(0);

  const [hint, setHint] = useState(true);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState(false);

  const redraw = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    const lineWidth = BRUSH_SIZE * Math.min(canvas.width, canvas.height);
    ctx.strokeStyle = "#050505";
    ctx.fillStyle = "#050505";
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.lineWidth = lineWidth;

    for (const stroke of strokesRef.current) {
      const pts = stroke.points;
      if (!pts.length) continue;
      const x0 = pts[0].x * canvas.width;
      const y0 = pts[0].y * canvas.height;
      if (pts.length === 1) {
        ctx.beginPath();
        ctx.arc(x0, y0, lineWidth / 2, 0, Math.PI * 2);
        ctx.fill();
        continue;
      }
      ctx.beginPath();
      ctx.moveTo(x0, y0);
      for (let i = 1; i < pts.length; i++) {
        ctx.lineTo(pts[i].x * canvas.width, pts[i].y * canvas.height);
      }
      ctx.stroke();
    }

    setHint(strokesRef.current.length === 0);
  }, []);

  const resize = useCallback(() => {
    const canvas = canvasRef.current;
    const card = cardRef.current;
    if (!canvas || !card) return;

    const bounds = card.getBoundingClientRect();
    const cssW = Math.max(1, bounds.width);
    const cssH = Math.max(1, bounds.height);
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    const w = Math.max(1, Math.round(cssW * dpr));
    const h = Math.max(1, Math.round(cssH * dpr));

    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    // keep CSS size locked to the white board
    canvas.style.width = `${cssW}px`;
    canvas.style.height = `${cssH}px`;
    redraw();
  }, [redraw]);

  useEffect(() => {
    resize();
    const card = cardRef.current;
    const ro =
      typeof ResizeObserver !== "undefined" && card
        ? new ResizeObserver(() => resize())
        : null;
    if (ro && card) ro.observe(card);
    window.addEventListener("resize", resize);
    window.addEventListener("orientationchange", resize);
    // second pass after layout (iOS address bar / flex)
    const t1 = setTimeout(resize, 50);
    const t2 = setTimeout(resize, 300);
    return () => {
      ro?.disconnect();
      window.removeEventListener("resize", resize);
      window.removeEventListener("orientationchange", resize);
      clearTimeout(t1);
      clearTimeout(t2);
    };
  }, [resize]);

  function pointFromEvent(event) {
    const canvas = canvasRef.current;
    const bounds = canvas.getBoundingClientRect();
    const w = bounds.width || 1;
    const h = bounds.height || 1;
    return {
      x: Math.min(1, Math.max(0, (event.clientX - bounds.left) / w)),
      y: Math.min(1, Math.max(0, (event.clientY - bounds.top) / h)),
    };
  }

  function cancelTimer() {
    if (timerRef.current != null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }

  function cancelInfer() {
    if (abortRef.current) {
      abortRef.current.abort();
      abortRef.current = null;
    }
  }

  async function recognize() {
    cancelTimer();
    if (!strokesRef.current.length || currentRef.current) return;

    const rev = ++revRef.current;
    cancelInfer();
    const ac = new AbortController();
    abortRef.current = ac;

    setBusy(true);
    setError(false);
    setMessage("Recognizing…");

    try {
      const { pixels, previewDataUrl, originalDataUrl } = strokesToMnist(
        strokesRef.current,
        BRUSH_SIZE
      );

      const res = await fetch(`${apiUrl}/infer`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          pixels,
          originalDataUrl,
          previewDataUrl,
          from: "draw",
        }),
        signal: ac.signal,
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `Error ${res.status}`);
      if (rev !== revRef.current) return;

      setMessage(`digit ${data.digit}`);
      onResult?.(data, { previewDataUrl, originalDataUrl });
    } catch (err) {
      if (err.name === "AbortError" || rev !== revRef.current) return;
      setError(true);
      setMessage(err.message || "Failed");
    } finally {
      if (rev === revRef.current) {
        abortRef.current = null;
        setBusy(false);
      }
    }
  }

  function clearAll() {
    revRef.current += 1;
    cancelTimer();
    cancelInfer();
    strokesRef.current = [];
    currentRef.current = null;
    setMessage("");
    setError(false);
    setBusy(false);
    redraw();
  }

  // native listeners with passive:false so iOS doesn't steal the gesture
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    function onPointerDown(event) {
      if (event.pointerType === "mouse" && event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();
      cancelTimer();
      cancelInfer();
      currentRef.current = { points: [pointFromEvent(event)] };
      strokesRef.current = [...strokesRef.current, currentRef.current];
      try {
        canvas.setPointerCapture(event.pointerId);
      } catch {
        // ignore
      }
      redraw();
    }

    function onPointerMove(event) {
      if (!currentRef.current) return;
      event.preventDefault();
      const events = event.getCoalescedEvents?.() || [event];
      for (const e of events) {
        const p = pointFromEvent(e);
        const pts = currentRef.current.points;
        const prev = pts[pts.length - 1];
        if (
          prev &&
          Math.hypot(p.x - prev.x, p.y - prev.y) < MIN_POINT_DIST
        ) {
          continue;
        }
        pts.push(p);
      }
      redraw();
    }

    function onPointerUp(event) {
      if (!currentRef.current) return;
      event.preventDefault();
      currentRef.current.points.push(pointFromEvent(event));
      currentRef.current = null;
      try {
        if (canvas.hasPointerCapture(event.pointerId)) {
          canvas.releasePointerCapture(event.pointerId);
        }
      } catch {
        // ignore
      }
      redraw();
      timerRef.current = setTimeout(recognize, RECOGNITION_DELAY_MS);
    }

    const opts = { passive: false };
    canvas.addEventListener("pointerdown", onPointerDown, opts);
    canvas.addEventListener("pointermove", onPointerMove, opts);
    canvas.addEventListener("pointerup", onPointerUp, opts);
    canvas.addEventListener("pointercancel", onPointerUp, opts);
    // iOS fallbacks
    canvas.addEventListener("touchstart", (e) => e.preventDefault(), opts);
    canvas.addEventListener("touchmove", (e) => e.preventDefault(), opts);

    return () => {
      canvas.removeEventListener("pointerdown", onPointerDown);
      canvas.removeEventListener("pointermove", onPointerMove);
      canvas.removeEventListener("pointerup", onPointerUp);
      canvas.removeEventListener("pointercancel", onPointerUp);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [redraw, apiUrl, onResult]);

  return (
    <div className={`digit-canvas-wrap ${compact ? "compact" : "phone-full"}`}>
      <div className="digit-toolbar">
        <button type="button" className="digit-clear-btn" onClick={clearAll}>
          Clear
        </button>
        <span className={`digit-msg ${error ? "err" : ""} ${busy ? "busy" : ""}`}>
          {message || (busy ? "Working…" : "Draw anywhere on the board")}
        </span>
      </div>

      <div ref={cardRef} className="digit-canvas-card">
        <canvas
          ref={canvasRef}
          className="digit-canvas"
          aria-label="Draw a digit"
        />
        {hint && <p className="digit-hint">Draw a single digit</p>}
      </div>
    </div>
  );
}
