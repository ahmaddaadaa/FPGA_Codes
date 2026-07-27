/**
 * Rasterize freehand strokes then run the shared MNIST normalizer.
 *
 * Stroke rendering follows drawing_webapp/run.py → render_strokes
 * (white background, black ink, round brush).
 * Normalization: drawing_webapp/preprocessing.py (via mnistNormalize.js).
 *
 * Source: https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/drawing_webapp
 */
import { drawingGrayToMnist, previewFromPixels } from "./mnistNormalize";

/**
 * @param {{ points: { x: number, y: number }[] }[]} strokes  normalized 0..1
 * @param {number} brushSize  fraction of min side (phone_canvas BRUSH_SIZE)
 */
export function strokesToMnist(strokes, brushSize = 0.025) {
  if (!strokes?.length) throw new Error("draw a digit first");

  const size = 512;
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });

  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, size, size);
  ctx.strokeStyle = "#050505";
  ctx.fillStyle = "#050505";
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  const lineWidth = Math.max(2, brushSize * size);
  ctx.lineWidth = lineWidth;

  for (const stroke of strokes) {
    const pts = stroke.points || [];
    if (!pts.length) continue;
    const x0 = pts[0].x * size;
    const y0 = pts[0].y * size;
    if (pts.length === 1) {
      ctx.beginPath();
      ctx.arc(x0, y0, lineWidth / 2, 0, Math.PI * 2);
      ctx.fill();
      continue;
    }
    ctx.beginPath();
    ctx.moveTo(x0, y0);
    for (let i = 1; i < pts.length; i++) {
      ctx.lineTo(pts[i].x * size, pts[i].y * size);
    }
    ctx.stroke();
  }

  const { data } = ctx.getImageData(0, 0, size, size);
  const gray = new Float64Array(size * size);
  for (let i = 0; i < size * size; i++) {
    const r = data[i * 4];
    const g = data[i * 4 + 1];
    const b = data[i * 4 + 2];
    gray[i] = 0.299 * r + 0.587 * g + 0.114 * b;
  }

  const { pixels } = drawingGrayToMnist(gray, size, size);

  return {
    pixels,
    previewDataUrl: previewFromPixels(pixels, 10),
    originalDataUrl: canvas.toDataURL("image/png"),
  };
}
