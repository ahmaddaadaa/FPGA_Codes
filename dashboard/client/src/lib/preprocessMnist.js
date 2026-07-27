/**
 * Phone/camera image → same 28×28 pipeline as drawings.
 *
 * Uses mnistNormalize.photoGrayToMnist (segment + fit/center/quantize),
 * matching drawing_webapp/preprocessing.py concepts.
 *
 * Source: https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/drawing_webapp
 * FPGA input format: 784×int8 (0–127), see Vakili MNIST host tooling.
 */
import { photoGrayToMnist, previewFromPixels } from "./mnistNormalize";

function loadImageFromFile(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Could not load image (use JPEG/PNG)"));
    };
    img.src = url;
  });
}

function makeDisplayDataUrl(img, maxSide = 360) {
  const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
  const w = Math.max(1, Math.round(img.width * scale));
  const h = Math.max(1, Math.round(img.height * scale));
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  canvas.getContext("2d").drawImage(img, 0, 0, w, h);
  return canvas.toDataURL("image/jpeg", 0.72);
}

export async function preprocessMnistImage(file) {
  const img = await loadImageFromFile(file);
  const originalDataUrl = makeDisplayDataUrl(img);

  // preprocessing.MAX_PROCESSING_DIMENSION ≈ 800
  const maxDim = 800;
  const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
  const w = Math.max(1, Math.round(img.width * scale));
  const h = Math.max(1, Math.round(img.height * scale));

  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(img, 0, 0, w, h);
  const { data } = ctx.getImageData(0, 0, w, h);

  const gray = new Float64Array(w * h);
  for (let i = 0; i < w * h; i++) {
    const r = data[i * 4];
    const g = data[i * 4 + 1];
    const b = data[i * 4 + 2];
    gray[i] = 0.299 * r + 0.587 * g + 0.114 * b;
  }

  const { pixels } = photoGrayToMnist(gray, w, h);

  return {
    pixels,
    previewDataUrl: previewFromPixels(pixels, 10),
    originalDataUrl,
  };
}
