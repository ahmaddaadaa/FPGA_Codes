// Phone photo → same 28×28 calculation as drawing_webapp
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

/**
 * Photo path (matches drawing_webapp intent):
 * 1) resize
 * 2) segment black digit on light paper (like segment_black_digit)
 * 3) bbox → scale to 20px → center in 28×28 → quantize 0–127
 *    (same fitAndCenterDigit as strokes)
 */
export async function preprocessMnistImage(file) {
  const img = await loadImageFromFile(file);
  const originalDataUrl = makeDisplayDataUrl(img);

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
    // upscaled pixel look (same style as drawing preview)
    previewDataUrl: previewFromPixels(pixels, 10),
    originalDataUrl,
  };
}
