"use strict";

const canvas = document.querySelector("#drawing");
const context = canvas.getContext("2d", { alpha: false });
const hint = document.querySelector("#hint");
const clearButton = document.querySelector("#clear");
const fullscreenButton = document.querySelector("#fullscreen");
const connection = document.querySelector("#connection");
const prediction = document.querySelector("#prediction");
const normalizedImage = document.querySelector("#normalized");
const message = document.querySelector("#message");
const timing = document.querySelector("#timing");
const scoreList = document.querySelector("#score-list");

const BRUSH_SIZE = 0.025;
const RECOGNITION_DELAY_MS = 550;
const MINIMUM_POINT_DISTANCE = 0.001;

let strokes = [];
let currentStroke = null;
let recognitionTimer = null;
let inferenceRequest = null;
let drawingRevision = 0;

function createScoreRow(digit) {
  const row = document.createElement("div");
  const digitLabel = document.createElement("span");
  const track = document.createElement("div");
  const bar = document.createElement("div");
  const value = document.createElement("span");

  row.className = "score-row";
  digitLabel.textContent = String(digit);
  track.className = "track";
  bar.className = "bar";
  value.className = "value";
  value.textContent = "—";

  track.appendChild(bar);
  row.append(digitLabel, track, value);
  scoreList.appendChild(row);

  return { row, bar, value };
}

const scoreRows = Array.from({ length: 10 }, (_, digit) => createScoreRow(digit));

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function showMessage(text, isError = false) {
  message.textContent = text;
  message.classList.toggle("error", isError);
}

function redrawCanvas() {
  context.fillStyle = "#fff";
  context.fillRect(0, 0, canvas.width, canvas.height);

  for (const stroke of strokes) {
    drawStroke(stroke);
  }

  hint.hidden = strokes.length > 0;
}

function resizeCanvas() {
  const bounds = canvas.getBoundingClientRect();
  const pixelRatio = Math.min(window.devicePixelRatio || 1, 3);
  const width = Math.max(1, Math.round(bounds.width * pixelRatio));
  const height = Math.max(1, Math.round(bounds.height * pixelRatio));

  if (canvas.width === width && canvas.height === height) {
    return;
  }

  canvas.width = width;
  canvas.height = height;
  redrawCanvas();
}

function drawStroke(stroke) {
  if (stroke.points.length === 0) {
    return;
  }

  const lineWidth = BRUSH_SIZE * Math.min(canvas.width, canvas.height);
  context.strokeStyle = "#050505";
  context.fillStyle = "#050505";
  context.lineCap = "round";
  context.lineJoin = "round";
  context.lineWidth = lineWidth;

  const firstPoint = stroke.points[0];
  const firstX = firstPoint.x * canvas.width;
  const firstY = firstPoint.y * canvas.height;

  if (stroke.points.length === 1) {
    context.beginPath();
    context.arc(firstX, firstY, lineWidth / 2, 0, Math.PI * 2);
    context.fill();
    return;
  }

  context.beginPath();
  context.moveTo(firstX, firstY);

  for (let index = 1; index < stroke.points.length; index += 1) {
    const point = stroke.points[index];
    context.lineTo(point.x * canvas.width, point.y * canvas.height);
  }

  context.stroke();
}

function pointFromEvent(event) {
  const bounds = canvas.getBoundingClientRect();
  return {
    x: clamp((event.clientX - bounds.left) / bounds.width, 0, 1),
    y: clamp((event.clientY - bounds.top) / bounds.height, 0, 1),
    pressure: event.pressure > 0 ? event.pressure : 0.5,
  };
}

function appendPoint(event) {
  if (!currentStroke) {
    return;
  }

  const point = pointFromEvent(event);
  const previousPoint = currentStroke.points[currentStroke.points.length - 1];

  if (previousPoint) {
    const distance = Math.hypot(
      point.x - previousPoint.x,
      point.y - previousPoint.y,
    );
    if (distance < MINIMUM_POINT_DISTANCE) {
      return;
    }
  }

  currentStroke.points.push(point);
}

function cancelRecognitionTimer() {
  if (recognitionTimer !== null) {
    window.clearTimeout(recognitionTimer);
    recognitionTimer = null;
  }
}

function cancelInferenceRequest() {
  if (inferenceRequest) {
    inferenceRequest.abort();
    inferenceRequest = null;
  }
}

function startStroke(event) {
  if (event.pointerType === "mouse" && event.button !== 0) {
    return;
  }

  event.preventDefault();
  cancelRecognitionTimer();
  cancelInferenceRequest();

  currentStroke = { points: [] };
  strokes.push(currentStroke);
  canvas.setPointerCapture(event.pointerId);
  appendPoint(event);
  redrawCanvas();
}

function moveStroke(event) {
  if (!currentStroke) {
    return;
  }

  event.preventDefault();
  const pointerEvents = event.getCoalescedEvents
    ? event.getCoalescedEvents()
    : [event];

  for (const pointerEvent of pointerEvents) {
    appendPoint(pointerEvent);
  }

  redrawCanvas();
}

function finishStroke(event) {
  if (!currentStroke) {
    return;
  }

  event.preventDefault();
  appendPoint(event);
  currentStroke = null;

  if (canvas.hasPointerCapture(event.pointerId)) {
    canvas.releasePointerCapture(event.pointerId);
  }

  redrawCanvas();
  recognitionTimer = window.setTimeout(recognizeDrawing, RECOGNITION_DELAY_MS);
}

function clearScores() {
  for (const score of scoreRows) {
    score.row.classList.remove("winner");
    score.bar.style.width = "0%";
    score.value.textContent = "—";
  }
}

function clearDrawing() {
  drawingRevision += 1;
  cancelRecognitionTimer();
  cancelInferenceRequest();

  strokes = [];
  currentStroke = null;
  prediction.textContent = "—";
  normalizedImage.hidden = true;
  normalizedImage.removeAttribute("src");
  timing.textContent = "";

  clearScores();
  showMessage("");
  redrawCanvas();
}

function setBusy(isBusy) {
  connection.classList.toggle("busy", isBusy);
}

function currentFullscreenElement() {
  return document.fullscreenElement || document.webkitFullscreenElement;
}

async function enterFullscreen() {
  const page = document.documentElement;

  try {
    if (page.requestFullscreen) {
      await page.requestFullscreen({ navigationUI: "hide" });
    } else if (page.webkitRequestFullscreen) {
      await Promise.resolve(page.webkitRequestFullscreen());
    } else {
      throw new Error("Fullscreen is not supported by this browser.");
    }

    if (screen.orientation?.lock) {
      try {
        await screen.orientation.lock("landscape");
      } catch (_error) {
        // Some browsers allow fullscreen but do not allow orientation locking.
      }
    }
  } catch (error) {
    showMessage(`Could not enter fullscreen: ${error.message}`, true);
  }
}

function updateFullscreenState() {
  const isFullscreen = Boolean(currentFullscreenElement());
  fullscreenButton.hidden = isFullscreen;
  document.body.classList.toggle("fullscreen", isFullscreen);
  window.setTimeout(resizeCanvas, 50);
}

function updatePrediction(result) {
  prediction.textContent = result.prediction == null
    ? "—"
    : String(result.prediction);

  normalizedImage.src = result.normalized_png;
  normalizedImage.hidden = false;

  const probabilities =
    result.probability_percentages || result.confidence_percentages;

  if (!Array.isArray(probabilities)) {
    clearScores();
    return;
  }

  for (let digit = 0; digit < scoreRows.length; digit += 1) {
    const score = scoreRows[digit];
    const rawValue = Number(probabilities[digit]);
    const value = Number.isFinite(rawValue) ? rawValue : 0;

    score.row.classList.toggle("winner", digit === result.prediction);
    score.bar.style.width = `${clamp(value, 0, 100)}%`;
    score.value.textContent = `${value.toFixed(2)}%`;
  }
}

function updateTiming(result) {
  timing.replaceChildren();

  const preprocessing = document.createElement("span");
  const udp = document.createElement("span");
  preprocessing.textContent = `Preprocess ${Number(result.preprocessing_ms).toFixed(2)} ms`;
  udp.textContent = `UDP ${Number(result.udp_round_trip_ms).toFixed(2)} ms`;

  timing.append(preprocessing, udp);
}

async function readJsonResponse(response) {
  try {
    return await response.json();
  } catch (_error) {
    throw new Error(`Request failed (${response.status})`);
  }
}

async function recognizeDrawing() {
  cancelRecognitionTimer();
  if (strokes.length === 0 || currentStroke) {
    return;
  }

  const requestRevision = ++drawingRevision;
  cancelInferenceRequest();
  inferenceRequest = new AbortController();

  setBusy(true);
  showMessage("Normalizing and sending to the FPGA…");

  const bounds = canvas.getBoundingClientRect();
  const payload = {
    width: bounds.width,
    height: bounds.height,
    brush_size: BRUSH_SIZE,
    strokes,
  };

  try {
    const response = await fetch("/api/infer", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: inferenceRequest.signal,
    });
    const result = await readJsonResponse(response);

    if (!response.ok) {
      throw new Error(result.error || `Request failed (${response.status})`);
    }
    if (requestRevision !== drawingRevision) {
      return;
    }

    updatePrediction(result);
    updateTiming(result);
    showMessage(`Connected to ${result.endpoint}`);
  } catch (error) {
    if (error.name !== "AbortError" && requestRevision === drawingRevision) {
      showMessage(error.message, true);
    }
  } finally {
    if (requestRevision === drawingRevision) {
      inferenceRequest = null;
      setBusy(false);
    }
  }
}

function setConnectionStatus(className, label, endpoint = "") {
  connection.className = `status ${className}`;
  connection.replaceChildren();

  const indicator = document.createElement("span");
  connection.append(indicator, document.createTextNode(label));
  connection.title = endpoint;
}

async function updateConnectionStatus() {
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) {
      throw new Error("offline");
    }

    const status = await response.json();
    setConnectionStatus("online", status.transport, status.endpoint);
  } catch (_error) {
    setConnectionStatus("error", "PC offline");
  }
}

canvas.addEventListener("pointerdown", startStroke);
canvas.addEventListener("pointermove", moveStroke);
canvas.addEventListener("pointerup", finishStroke);
canvas.addEventListener("pointercancel", finishStroke);
clearButton.addEventListener("click", clearDrawing);
fullscreenButton.addEventListener("click", enterFullscreen);
document.addEventListener("fullscreenchange", updateFullscreenState);
document.addEventListener("webkitfullscreenchange", updateFullscreenState);
window.addEventListener("resize", resizeCanvas);

resizeCanvas();
clearDrawing();
updateConnectionStatus();
updateFullscreenState();
window.setInterval(updateConnectionStatus, 5000);
