import { useState } from "react";
import DigitCanvas from "./DigitCanvas";
import { preprocessMnistImage } from "./lib/preprocessMnist";
import "./PhoneCapture.css";

const API_URL =
  import.meta.env.VITE_API_URL || `${window.location.origin}/api`;

export default function PhoneCapture() {
  const [mode, setMode] = useState("draw"); // draw | photo
  const [prediction, setPrediction] = useState(null);
  const [preview, setPreview] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  function onDrawResult(data, images) {
    setPrediction(data.digit);
    setPreview(images?.previewDataUrl || null);
    setError(null);
  }

  async function onPhoto(file, inputEl) {
    if (!file) return;
    setError(null);
    setBusy(true);
    try {
      const { pixels, previewDataUrl, originalDataUrl } =
        await preprocessMnistImage(file);
      setPreview(previewDataUrl);

      const res = await fetch(`${API_URL}/infer`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          pixels,
          originalDataUrl,
          previewDataUrl,
          from: "phone",
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `Error ${res.status}`);
      setPrediction(data.digit);
    } catch (err) {
      setError(err.message || "Failed");
    } finally {
      setBusy(false);
      if (inputEl) inputEl.value = "";
    }
  }

  return (
    <div className="phone-page">
      <header className="phone-header">
        <h1>FPGA digit demo</h1>
        <p>Draw a digit (best) or take a photo</p>
      </header>

      <div className="phone-mode">
        <button
          type="button"
          className={mode === "draw" ? "active" : ""}
          onClick={() => setMode("draw")}
        >
          Draw
        </button>
        <button
          type="button"
          className={mode === "photo" ? "active" : ""}
          onClick={() => setMode("photo")}
        >
          Photo
        </button>
      </div>

      {mode === "draw" ? (
        <div className="phone-draw">
          <DigitCanvas apiUrl={API_URL} onResult={onDrawResult} />
        </div>
      ) : (
        <div className="phone-actions">
          <label className={`phone-btn primary ${busy ? "disabled" : ""}`}>
            {busy ? "Working…" : "Take photo"}
            <input
              type="file"
              accept="image/*"
              capture="environment"
              disabled={busy}
              onChange={(e) => onPhoto(e.target.files?.[0], e.target)}
            />
          </label>
          <label className={`phone-btn ${busy ? "disabled" : ""}`}>
            {busy ? "Working…" : "Gallery"}
            <input
              type="file"
              accept="image/*"
              disabled={busy}
              onChange={(e) => onPhoto(e.target.files?.[0], e.target)}
            />
          </label>
        </div>
      )}

      <div className="phone-result">
        <div className="phone-digit">
          {prediction != null ? prediction : "—"}
        </div>
        {preview && (
          <img src={preview} alt="28x28" className="phone-preview" />
        )}
      </div>
      {error && <p className="phone-error">{error}</p>}
    </div>
  );
}
