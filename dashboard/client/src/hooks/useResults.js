import { useEffect, useRef, useState } from "react";

function defaultApiUrl() {
  if (import.meta.env.VITE_API_URL) return import.meta.env.VITE_API_URL;
  return `${window.location.origin}/api`;
}

function defaultWsUrl() {
  if (import.meta.env.VITE_WS_URL) return import.meta.env.VITE_WS_URL;
  const proto = window.location.protocol === "https:" ? "wss" : "ws";
  return `${proto}://${window.location.host}/ws`;
}

const API_URL = defaultApiUrl();
const WS_URL = defaultWsUrl();

export function useResults() {
  const [results, setResults] = useState(null);
  const [inference, setInference] = useState(null);
  const [original, setOriginal] = useState(null);
  const [scaled, setScaled] = useState(null);
  const [status, setStatus] = useState("connecting");
  const [photoTick, setPhotoTick] = useState(0);
  const reconnectDelayRef = useRef(1000);
  const wsRef = useRef(null);

  useEffect(() => {
    let cancelled = false;
    let reconnectTimer = null;

    fetch(`${API_URL}/results`)
      .then((r) => r.json())
      .then((data) => {
        if (!cancelled) setResults(data);
      })
      .catch(() => {});

    fetch(`${API_URL}/photo`)
      .then((r) => r.json())
      .then((data) => {
        if (cancelled || !data?.inference) return;
        if (data.originalDataUrl) setOriginal(data.originalDataUrl);
        if (data.previewDataUrl) setScaled(data.previewDataUrl);
        setInference(data.inference);
      })
      .catch(() => {});

    function onMessage(raw) {
      const msg = JSON.parse(raw);
      if (msg?.type === "photo") {
        const d = msg.data || {};
        if (d.originalDataUrl) setOriginal(d.originalDataUrl);
        if (d.previewDataUrl) setScaled(d.previewDataUrl);
        if (d.inference) setInference(d.inference);
        setPhotoTick((n) => n + 1);
        return;
      }
      if (msg?.type === "inference") {
        setInference(msg.data);
        return;
      }
      if (msg?.type === "eval") {
        setResults(msg.data);
        return;
      }
      if (msg?.accuracy) setResults(msg);
    }

    function connect() {
      if (cancelled) return;
      setStatus("connecting");
      const ws = new WebSocket(WS_URL);
      wsRef.current = ws;

      ws.onopen = () => {
        if (cancelled) return;
        reconnectDelayRef.current = 1000;
        setStatus("live");
      };

      ws.onmessage = (event) => {
        if (cancelled) return;
        try {
          onMessage(event.data);
          setStatus("live");
        } catch (err) {
          console.error("ws message error", err);
        }
      };

      ws.onclose = () => {
        if (cancelled) return;
        setStatus("disconnected");
        const delay = reconnectDelayRef.current;
        reconnectTimer = setTimeout(connect, delay);
        reconnectDelayRef.current = Math.min(delay * 1.5, 10000);
      };

      ws.onerror = () => ws.close();
    }

    connect();

    return () => {
      cancelled = true;
      clearTimeout(reconnectTimer);
      if (wsRef.current) {
        wsRef.current.onclose = null;
        wsRef.current.close();
      }
    };
  }, []);

  return {
    results,
    inference,
    setInference,
    original,
    setOriginal,
    scaled,
    setScaled,
    status,
    photoTick,
    apiUrl: API_URL,
  };
}
