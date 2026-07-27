import { useEffect, useState } from "react";
import { useResults } from "./hooks/useResults";
import PhoneCapture from "./PhoneCapture";
import DigitCanvas from "./DigitCanvas";
import "./App.css";

function statusLabel(status) {
  if (status === "live") return "Connected";
  if (status === "connecting") return "Connecting…";
  return "Disconnected";
}

function Stat({ label, value, unit }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className="stat-value">
        {value ?? "—"}
        {unit ? <span className="stat-unit">{unit}</span> : null}
      </span>
    </div>
  );
}

function ConfusionMatrix({ matrixData }) {
  if (!matrixData?.matrix?.length) return null;

  const { labels, matrix } = matrixData;
  const maxVal = Math.max(...matrix.flat(), 1);

  return (
    <table className="matrix">
      <thead>
        <tr>
          <th className="corner">T\\P</th>
          {labels.map((label) => (
            <th key={label}>{label}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {matrix.map((row, i) => (
          <tr key={labels[i]}>
            <th>{labels[i]}</th>
            {row.map((value, j) => {
              const intensity = value / maxVal;
              const isDiag = i === j;
              return (
                <td
                  key={`${i}-${j}`}
                  style={{
                    background: isDiag
                      ? `rgba(61, 220, 151, ${0.15 + intensity * 0.75})`
                      : value > 0
                        ? `rgba(255, 107, 107, ${0.12 + intensity * 0.65})`
                        : "transparent",
                  }}
                  title={`true ${labels[i]} → pred ${labels[j]}: ${value}`}
                >
                  {value}
                </td>
              );
            })}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function qrImageUrl(text) {
  return `https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=${encodeURIComponent(
    text
  )}`;
}

function Dashboard() {
  const {
    results,
    inference,
    original,
    scaled,
    status,
    photoTick,
    apiUrl,
    setInference,
    setOriginal,
    setScaled,
  } = useResults();

  const [showQr, setShowQr] = useState(false);
  const [phoneUrl, setPhoneUrl] = useState(null);

  const acc = results?.accuracy;
  const eff = results?.efficiency;

  useEffect(() => {
    let cancelled = false;
    async function loadHostInfo() {
      try {
        const res = await fetch(`${apiUrl}/host-info`);
        const data = await res.json();
        if (cancelled) return;
        const url =
          data.trustedPhoneUrl ||
          data.publicPhoneUrl ||
          `${window.location.origin}/?phone=1`;
        setPhoneUrl(url);
      } catch {
        if (!cancelled) setPhoneUrl(`${window.location.origin}/?phone=1`);
      }
    }
    loadHostInfo();
    const id = setInterval(loadHostInfo, 8000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [apiUrl]);

  useEffect(() => {
    if (photoTick > 0) setShowQr(false);
  }, [photoTick]);

  function onDrawResult(data, images) {
    setInference(data);
    if (images?.originalDataUrl) setOriginal(images.originalDataUrl);
    if (images?.previewDataUrl) setScaled(images.previewDataUrl);
  }

  return (
    <main className="page">
      <header className="header">
        <div className="title-block">
          <h1>MNIST FPGA</h1>
          <p className="meta">
            {results
              ? `${results.dataset} · ${results.sample_count} · ${results.source}`
              : "Loading…"}
            {" · draw a digit or use phone"}
          </p>
        </div>
        <div className={`status ${status}`}>
          <span className="dot" />
          <span>{statusLabel(status)}</span>
        </div>
      </header>

      <section className="stats">
        <Stat
          label="FPGA vs label"
          value={acc?.fpga_vs_label?.percent}
          unit="%"
        />
        <Stat
          label="vs integer ref"
          value={acc?.fpga_vs_integer_reference?.percent}
          unit="%"
        />
        <Stat
          label="Logit match"
          value={acc?.exact_logit_matches?.percent}
          unit="%"
        />
        <Stat
          label="Throughput"
          value={eff?.images_per_second}
          unit="img/s"
        />
        <Stat label="Time" value={eff?.elapsed_seconds} unit="s" />
        <Stat label="Cycles" value={eff?.core_cycles} />
      </section>

      <div className="main">
        <section className="live-panel draw-layout">
          <div className="draw-top">
            <button
              type="button"
              className="capture-btn"
              onClick={() => setShowQr((v) => !v)}
            >
              {showQr ? "Hide phone QR" : "Open on phone"}
            </button>
          </div>

          {showQr && phoneUrl && (
            <div className="phone-link-panel">
              <p className="phone-link-title">
                Scan to draw or take a photo on your phone
              </p>
              <img className="qr" src={qrImageUrl(phoneUrl)} alt="QR" />
              <p className="phone-url-alt">{phoneUrl}</p>
            </div>
          )}

          <div className="draw-row">
            <DigitCanvas apiUrl={apiUrl} onResult={onDrawResult} compact />

            <div className="draw-side">
              <div className="live-col">
                <p className="panel-label">Input / drawing</p>
                {original ? (
                  <img
                    className="photo-original"
                    src={original}
                    alt="Drawing"
                  />
                ) : (
                  <div className="mnist-placeholder">—</div>
                )}
              </div>
              <div className="live-col">
                <p className="panel-label">28×28</p>
                {scaled ? (
                  <img className="mnist-preview" src={scaled} alt="Scaled" />
                ) : (
                  <div className="mnist-placeholder">—</div>
                )}
              </div>
              <div className="live-col pred">
                <p className="panel-label">Result</p>
                <div className="digit-big">
                  {inference?.digit != null ? inference.digit : "—"}
                </div>
                <p className="live-meta">
                  {inference?.from === "draw"
                    ? "from drawing"
                    : inference?.from === "phone"
                      ? "from phone"
                      : inference?.source || "draw to predict"}
                </p>
              </div>
            </div>
          </div>

          {inference?.logits?.length === 10 && (
            <div className="logit-row">
              {inference.logits.map((v, i) => (
                <div
                  key={i}
                  className={`logit ${inference.digit === i ? "best" : ""}`}
                >
                  <span>{i}</span>
                  <span>{v}</span>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="matrix-panel">
          <div className="matrix-head">
            <h2>Confusion matrix</h2>
            <span className="matrix-hint">rows = true · cols = FPGA</span>
          </div>
          <div className="matrix-body">
            {results?.confusion_matrix ? (
              <ConfusionMatrix matrixData={results.confusion_matrix} />
            ) : (
              <p className="empty">No eval data yet</p>
            )}
          </div>
        </section>
      </div>
    </main>
  );
}

export default function App() {
  const isPhone =
    new URLSearchParams(window.location.search).get("phone") === "1";
  return isPhone ? <PhoneCapture /> : <Dashboard />;
}
