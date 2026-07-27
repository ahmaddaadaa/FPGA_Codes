import { useState } from "react";
import { preprocessMnistImage } from "./lib/preprocessMnist";
import "./PhoneCapture.css";

const API_URL =
  import.meta.env.VITE_API_URL || `${window.location.origin}/api`;

export default function PhoneCapture() {
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("Take or pick a photo of a digit");
  const [preview, setPreview] = useState(null);
  const [error, setError] = useState(null);
  const [done, setDone] = useState(false);

  async function onFile(file, inputEl) {
    if (!file) return;
    setError(null);
    setDone(false);
    setBusy(true);
    setStatus("Scaling to 28×28…");

    try {
      const { pixels, previewDataUrl, originalDataUrl } =
        await preprocessMnistImage(file);
      setPreview(previewDataUrl);
      setStatus("Sending…");

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

      setDone(true);
      setStatus(`Sent · prediction ${data.digit}`);
    } catch (err) {
      const msg = String(err.message || err);
      if (msg === "Failed to fetch" || msg.includes("NetworkError")) {
        setError("Can't reach the server. Use the dashboard HTTPS link.");
      } else if (/not allowed|permission|secure|https/i.test(msg)) {
        setError("Camera blocked. Allow camera on the HTTPS site.");
      } else {
        setError(msg);
      }
      setStatus("Failed — try again");
    } finally {
      setBusy(false);
      if (inputEl) inputEl.value = "";
    }
  }

  return (
    <div className="phone-page">
      <header className="phone-header">
        <h1>Send photo</h1>
        <p>It shows up on the dashboard after you shoot</p>
      </header>

      <div className="phone-actions">
        <label className={`phone-btn primary ${busy ? "disabled" : ""}`}>
          {busy ? "Working…" : "Take photo"}
          <input
            type="file"
            accept="image/*"
            capture="environment"
            disabled={busy}
            onChange={(e) => onFile(e.target.files?.[0], e.target)}
          />
        </label>

        <label className={`phone-btn ${busy ? "disabled" : ""}`}>
          {busy ? "Working…" : "Choose from gallery"}
          <input
            type="file"
            accept="image/*"
            disabled={busy}
            onChange={(e) => onFile(e.target.files?.[0], e.target)}
          />
        </label>
      </div>

      <p className={`phone-status ${done ? "ok" : ""}`}>{status}</p>
      {error && <p className="phone-error">{error}</p>}

      {preview && (
        <div className="phone-preview-wrap">
          <p>28×28 input</p>
          <img src={preview} alt="Scaled" className="phone-preview" />
        </div>
      )}
    </div>
  );
}
