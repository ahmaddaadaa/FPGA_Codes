/**
 * MNIST FPGA dashboard API + WebSocket.
 *
 * Serves React UI in production; /api/infer accepts 784 int8 pixels (0–127)
 * prepared by the client (drawing_webapp-style 28×28 prep).
 *
 * Related:
 * - drawing_webapp: https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/drawing_webapp
 * - FPGA host/model: https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/Vakili_P16_FPGA
 * - See REFERENCES.md in this package
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const express = require("express");
const cors = require("cors");
const { WebSocketServer } = require("ws");
const { mockInfer } = require("./mockInfer");

const app = express();
const PORT = process.env.PORT || 3000;
const FRONTEND_PORT = process.env.FRONTEND_PORT || 5173;
const MOCK_PATH = path.join(__dirname, "mock-data.json");
const IS_PROD = process.env.NODE_ENV === "production";

app.set("trust proxy", 1);

const PUBLIC_DIR = [
  path.join(__dirname, "public"),
  path.join(__dirname, "..", "client", "dist"),
].find((dir) => fs.existsSync(path.join(dir, "index.html")));

app.use(cors({ origin: true }));
app.use(express.json({ limit: "12mb" }));

app.get("/health", (_req, res) => {
  res.status(200).send("ok");
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws" });

let lastInference = null;
let lastPhoto = null;

function loadMockData() {
  return JSON.parse(fs.readFileSync(MOCK_PATH, "utf8"));
}

function broadcast(data) {
  const msg = JSON.stringify(data);
  for (const client of wss.clients) {
    if (client.readyState === 1) client.send(msg);
  }
}

function lanIpv4Addresses() {
  const out = [];
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name] || []) {
      const v4 = net.family === "IPv4" || net.family === 4;
      if (v4 && !net.internal) out.push(net.address);
    }
  }
  return out;
}

function publicBaseFromRequest(req) {
  const fromEnv = (process.env.PUBLIC_BASE_URL || "").replace(/\/$/, "");
  if (fromEnv) return fromEnv;

  const host = req.get("x-forwarded-host") || req.get("host");
  if (!host) return null;

  let proto = req.get("x-forwarded-proto");
  if (!proto) {
    proto = (req.secure || IS_PROD) ? "https" : "http";
  }
  if (
    !req.get("x-forwarded-proto") &&
    /\.(onrender\.com|fly\.dev|railway\.app)$/i.test(host)
  ) {
    proto = "https";
  }

  return `${proto}://${host}`.replace(/\/$/, "");
}

const api = express.Router();

api.get("/", (_req, res) => {
  res.json({
    message: "MNIST FPGA API",
    endpoints: {
      results: "GET /api/results",
      infer: "POST /api/infer",
      hostInfo: "GET /api/host-info",
      ws: "WS /ws",
    },
  });
});

api.get("/host-info", (req, res) => {
  const ips = lanIpv4Addresses();
  const phoneUrls = ips.map(
    (ip) => `http://${ip}:${FRONTEND_PORT}/?phone=1`
  );
  const publicBase = publicBaseFromRequest(req);

  res.json({
    lanIps: ips,
    phoneUrls,
    publicBaseUrl: publicBase,
    publicPhoneUrl: publicBase ? `${publicBase}/?phone=1` : null,
    trustedPhoneUrl: publicBase ? `${publicBase}/?phone=1` : null,
    frontendPort: Number(FRONTEND_PORT),
    apiPort: Number(PORT),
    mode: IS_PROD ? "production" : "development",
  });
});

api.get("/results", (_req, res) => {
  try {
    res.json(loadMockData());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.get("/inference", (_req, res) => {
  res.json(lastInference || { digit: null, note: "no inference yet" });
});

api.get("/photo", (_req, res) => {
  res.json(lastPhoto || { note: "no photo yet" });
});

api.post("/infer", (req, res) => {
  try {
    const { pixels, originalDataUrl, previewDataUrl, from } = req.body || {};
    const result = mockInfer(pixels);
    result.from = from || "client";
    lastInference = result;

    lastPhoto = {
      originalDataUrl: originalDataUrl || null,
      previewDataUrl: previewDataUrl || null,
      inference: result,
    };

    broadcast({ type: "photo", data: lastPhoto });
    broadcast({ type: "inference", data: result });

    const n = [...wss.clients].filter((c) => c.readyState === 1).length;
    console.log(`infer (${result.from}): digit=${result.digit}, clients=${n}`);

    res.json(result);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.use("/api", api);

wss.on("connection", (ws) => {
  console.log("ws client connected");
  try {
    ws.send(JSON.stringify({ type: "eval", data: loadMockData() }));
    if (lastInference) {
      ws.send(JSON.stringify({ type: "inference", data: lastInference }));
    }
    if (lastPhoto) {
      ws.send(JSON.stringify({ type: "photo", data: lastPhoto }));
    }
  } catch (err) {
    console.error(err.message);
  }

  ws.on("close", () => console.log("ws client disconnected"));
  ws.on("error", (err) => console.error("ws error:", err.message));
});

fs.watchFile(MOCK_PATH, { interval: 500 }, () => {
  try {
    broadcast({ type: "eval", data: loadMockData() });
  } catch (err) {
    console.error(err.message);
  }
});

if (PUBLIC_DIR) {
  app.use(express.static(PUBLIC_DIR, { index: false }));
  app.get("*", (req, res, next) => {
    if (req.path.startsWith("/api") || req.path === "/ws") return next();
    res.sendFile(path.join(PUBLIC_DIR, "index.html"));
  });
  console.log("static ui:", PUBLIC_DIR);
}

server.listen(PORT, "0.0.0.0", () => {
  console.log(`server http://localhost:${PORT}`);
  if (!IS_PROD) {
    console.log(`dev ui  http://localhost:${FRONTEND_PORT}`);
    for (const ip of lanIpv4Addresses()) {
      console.log(`phone   http://${ip}:${FRONTEND_PORT}/?phone=1`);
    }
  }
});
