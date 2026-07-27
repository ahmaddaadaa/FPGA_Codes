// Render freehand strokes → 28×28 MNIST-style pixels (0–127, light on dark)

const MNIST = 28;
const DIGIT_BOX = 20;

function clamp(v, lo, hi) {
  return Math.min(hi, Math.max(lo, v));
}

/**
 * @param {{ points: { x: number, y: number }[] }[]} strokes  normalized 0..1
 * @param {number} brushSize  fraction of min(width,height)
 */
export function strokesToMnist(strokes, brushSize = 0.025) {
  if (!strokes?.length) {
    throw new Error("draw a digit first");
  }

  const size = 512;
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });

  // white background, black ink (same as drawing_webapp)
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

  // bbox of dark ink
  let r0 = size;
  let r1 = -1;
  let c0 = size;
  let c1 = -1;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      const gray = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
      if (gray > 200) continue;
      if (y < r0) r0 = y;
      if (y > r1) r1 = y;
      if (x < c0) c0 = x;
      if (x > c1) c1 = x;
    }
  }

  if (r1 < 0) throw new Error("draw a digit first");

  // pad bbox a little
  const pad = Math.round(lineWidth);
  r0 = Math.max(0, r0 - pad);
  c0 = Math.max(0, c0 - pad);
  r1 = Math.min(size - 1, r1 + pad);
  c1 = Math.min(size - 1, c1 + pad);

  const bw = c1 - c0 + 1;
  const bh = r1 - r0 + 1;
  const scale = DIGIT_BOX / Math.max(bw, bh);
  const tw = Math.max(1, Math.round(bw * scale));
  const th = Math.max(1, Math.round(bh * scale));
  const ox = Math.floor((MNIST - tw) / 2);
  const oy = Math.floor((MNIST - th) / 2);

  const out = document.createElement("canvas");
  out.width = MNIST;
  out.height = MNIST;
  const octx = out.getContext("2d", { willReadFrequently: true });
  octx.fillStyle = "#000";
  octx.fillRect(0, 0, MNIST, MNIST);
  octx.imageSmoothingEnabled = true;
  // crop black-on-white, draw into black canvas then invert via reading
  octx.drawImage(canvas, c0, r0, bw, bh, ox, oy, tw, th);

  const img = octx.getImageData(0, 0, MNIST, MNIST);
  const pixels = new Array(784);
  for (let i = 0; i < 784; i++) {
    const r = img.data[i * 4];
    const g = img.data[i * 4 + 1];
    const b = img.data[i * 4 + 2];
    const y = 0.299 * r + 0.587 * g + 0.114 * b;
    // invert: ink was dark on white crop → want bright on black
    const ink = 255 - y;
    pixels[i] = Math.max(0, Math.min(127, Math.round(ink * (127 / 255))));
  }

  // rebuild preview from pixels (light on black)
  for (let i = 0; i < 784; i++) {
    const v = Math.round((pixels[i] / 127) * 255);
    img.data[i * 4] = v;
    img.data[i * 4 + 1] = v;
    img.data[i * 4 + 2] = v;
    img.data[i * 4 + 3] = 255;
  }
  octx.putImageData(img, 0, 0);

  // display original drawing as data URL
  const originalDataUrl = canvas.toDataURL("image/png");

  return {
    pixels,
    previewDataUrl: out.toDataURL("image/png"),
    originalDataUrl,
  };
}

export { clamp };
