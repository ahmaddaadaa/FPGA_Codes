/**
 * Core 28×28 prep aligned with drawing_webapp/preprocessing.py:
 * DIGIT_BOX=20, 28×28 canvas, mass-center, quantize to 0–127.
 */

export const MNIST_SIZE = 28;
export const DIGIT_BOX_SIZE = 20;
export const INPUT_SCALE = 127;
const STROKE_MARGIN = 2;
const EDGE_MARGIN = 1;

function restoreContrast(buf, n) {
  let peak = 0;
  for (let i = 0; i < n; i++) if (buf[i] > peak) peak = buf[i];
  if (peak <= 0) return buf;
  for (let i = 0; i < n; i++) {
    const t = buf[i] / peak;
    buf[i] = Math.max(0, Math.min(255, Math.round(255 * Math.sqrt(t))));
  }
  return buf;
}

function boundingRect(mask, w, h, thr = 1) {
  let x0 = w;
  let y0 = h;
  let x1 = -1;
  let y1 = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (mask[y * w + x] < thr) continue;
      if (x < x0) x0 = x;
      if (y < y0) y0 = y;
      if (x > x1) x1 = x;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) return null;
  return { x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1 };
}

function binaryMask(src, thr = 31) {
  const out = new Uint8Array(src.length);
  for (let i = 0; i < src.length; i++) out[i] = src[i] > thr ? 255 : 0;
  return out;
}

function boxBlur(src, w, h, radius) {
  const r = Math.max(1, radius | 0);
  const tmp = new Float64Array(w * h);
  const out = new Float64Array(w * h);
  const inv = 1 / (2 * r + 1);

  // horizontal
  for (let y = 0; y < h; y++) {
    let sum = 0;
    for (let x = -r; x <= r; x++) {
      sum += src[y * w + Math.min(w - 1, Math.max(0, x))];
    }
    for (let x = 0; x < w; x++) {
      tmp[y * w + x] = sum * inv;
      const leave = src[y * w + Math.min(w - 1, Math.max(0, x - r))];
      const enter = src[y * w + Math.min(w - 1, Math.max(0, x + r + 1))];
      sum += enter - leave;
    }
  }
  // vertical
  for (let x = 0; x < w; x++) {
    let sum = 0;
    for (let y = -r; y <= r; y++) {
      sum += tmp[Math.min(h - 1, Math.max(0, y)) * w + x];
    }
    for (let y = 0; y < h; y++) {
      out[y * w + x] = sum * inv;
      const leave = tmp[Math.min(h - 1, Math.max(0, y - r)) * w + x];
      const enter = tmp[Math.min(h - 1, Math.max(0, y + r + 1)) * w + x];
      sum += enter - leave;
    }
  }
  return out;
}

function otsuThreshold(gray, n) {
  const hist = new Array(256).fill(0);
  for (let i = 0; i < n; i++) hist[Math.max(0, Math.min(255, gray[i] | 0))]++;
  let sum = 0;
  for (let i = 0; i < 256; i++) sum += i * hist[i];
  let sumB = 0;
  let wB = 0;
  let maxVar = 0;
  let thr = 128;
  for (let t = 0; t < 256; t++) {
    wB += hist[t];
    if (!wB) continue;
    const wF = n - wB;
    if (!wF) break;
    sumB += t * hist[t];
    const mB = sumB / wB;
    const mF = (sum - sumB) / wF;
    const v = wB * wF * (mB - mF) * (mB - mF);
    if (v > maxVar) {
      maxVar = v;
      thr = t;
    }
  }
  return thr;
}

/**
 * Segment black digit on light paper → binary mask 255=ink (like segment_black_digit).
 * For clean drawings (pure white bg), falls back to simple threshold.
 */
export function segmentBlackDigit(gray, w, h) {
  const n = w * h;
  const g = new Float64Array(n);
  for (let i = 0; i < n; i++) g[i] = gray[i];

  // illumination flatten: gray / blurred_bg
  const radius = Math.max(8, Math.round(Math.min(w, h) * 0.08));
  const bg = boxBlur(g, w, h, radius);
  const flat = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    const b = Math.max(1, bg[i]);
    flat[i] = Math.max(0, Math.min(255, Math.round((g[i] / b) * 255)));
  }

  // light blur
  const flatF = new Float64Array(n);
  for (let i = 0; i < n; i++) flatF[i] = flat[i];
  const soft = boxBlur(flatF, w, h, 1);
  for (let i = 0; i < n; i++) {
    flat[i] = Math.max(0, Math.min(255, Math.round(soft[i])));
  }

  // Otsu inverted (dark ink → white mask)
  const thr = otsuThreshold(flat, n);
  const mask = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    // THRESH_BINARY_INV: below thr = ink
    mask[i] = flat[i] < thr + 8 ? 255 : 0;
  }

  // simple open (erode then dilate) 2x2 then close 3x3 to clean noise
  morphOpen(mask, w, h, 1);
  morphClose(mask, w, h, 1);

  // keep largest connected component (approx: keep dense bbox region)
  return keepLargestBlob(mask, w, h);
}

function morphOpen(mask, w, h, r) {
  const er = erode(mask, w, h, r);
  const di = dilate(er, w, h, r);
  mask.set(di);
}

function morphClose(mask, w, h, r) {
  const di = dilate(mask, w, h, r);
  const er = erode(di, w, h, r);
  mask.set(er);
}

function erode(src, w, h, r) {
  const out = new Uint8Array(src.length);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let ok = 255;
      for (let dy = -r; dy <= r && ok; dy++) {
        for (let dx = -r; dx <= r; dx++) {
          const ny = y + dy;
          const nx = x + dx;
          if (ny < 0 || nx < 0 || ny >= h || nx >= w || !src[ny * w + nx]) {
            ok = 0;
            break;
          }
        }
      }
      out[y * w + x] = ok;
    }
  }
  return out;
}

function dilate(src, w, h, r) {
  const out = new Uint8Array(src.length);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let ok = 0;
      for (let dy = -r; dy <= r && !ok; dy++) {
        for (let dx = -r; dx <= r; dx++) {
          const ny = y + dy;
          const nx = x + dx;
          if (ny >= 0 && nx >= 0 && ny < h && nx < w && src[ny * w + nx]) {
            ok = 255;
            break;
          }
        }
      }
      out[y * w + x] = ok;
    }
  }
  return out;
}

function keepLargestBlob(mask, w, h) {
  const seen = new Uint8Array(mask.length);
  let best = null;
  let bestArea = 0;

  for (let i = 0; i < mask.length; i++) {
    if (!mask[i] || seen[i]) continue;
    const stack = [i];
    seen[i] = 1;
    const cells = [];
    while (stack.length) {
      const p = stack.pop();
      cells.push(p);
      const x = p % w;
      const y = (p / w) | 0;
      for (const [dx, dy] of [
        [1, 0],
        [-1, 0],
        [0, 1],
        [0, -1],
      ]) {
        const nx = x + dx;
        const ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const ni = ny * w + nx;
        if (seen[ni] || !mask[ni]) continue;
        seen[ni] = 1;
        stack.push(ni);
      }
    }
    if (cells.length > bestArea) {
      bestArea = cells.length;
      best = cells;
    }
  }

  const out = new Uint8Array(mask.length);
  if (best) {
    for (const p of best) out[p] = 255;
  }
  return out;
}

/**
 * Fit bright-ink (or binary 255) component into 28×28.
 */
export function fitAndCenterDigit(component, w, h, bounds) {
  const { x, y, width, height } = bounds;
  const crop = new Uint8Array(width * height);
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      crop[row * width + col] = component[(y + row) * w + (x + col)];
    }
  }

  const scale = DIGIT_BOX_SIZE / Math.max(width, height);
  const rw = Math.max(1, Math.round(width * scale));
  const rh = Math.max(1, Math.round(height * scale));

  const c1 = document.createElement("canvas");
  c1.width = width;
  c1.height = height;
  const ctx1 = c1.getContext("2d");
  const img1 = ctx1.createImageData(width, height);
  for (let i = 0; i < width * height; i++) {
    const v = crop[i];
    img1.data[i * 4] = v;
    img1.data[i * 4 + 1] = v;
    img1.data[i * 4 + 2] = v;
    img1.data[i * 4 + 3] = 255;
  }
  ctx1.putImageData(img1, 0, 0);

  const c2 = document.createElement("canvas");
  c2.width = rw;
  c2.height = rh;
  const ctx2 = c2.getContext("2d", { willReadFrequently: true });
  ctx2.imageSmoothingEnabled = true;
  ctx2.imageSmoothingQuality = "high";
  ctx2.fillStyle = "#000";
  ctx2.fillRect(0, 0, rw, rh);
  ctx2.drawImage(c1, 0, 0, rw, rh);
  const resizedData = ctx2.getImageData(0, 0, rw, rh).data;
  let resized = new Uint8Array(rw * rh);
  for (let i = 0; i < rw * rh; i++) resized[i] = resizedData[i * 4];
  restoreContrast(resized, rw * rh);

  const mw = rw + STROKE_MARGIN * 2;
  const mh = rh + STROKE_MARGIN * 2;
  const padded = new Uint8Array(mw * mh);
  for (let row = 0; row < rh; row++) {
    for (let col = 0; col < rw; col++) {
      padded[(row + STROKE_MARGIN) * mw + (col + STROKE_MARGIN)] =
        resized[row * rw + col];
    }
  }

  let canvas = new Uint8Array(MNIST_SIZE * MNIST_SIZE);
  const startX = Math.floor((MNIST_SIZE - mw) / 2);
  const startY = Math.floor((MNIST_SIZE - mh) / 2);
  for (let row = 0; row < mh; row++) {
    for (let col = 0; col < mw; col++) {
      const tx = startX + col;
      const ty = startY + row;
      if (tx < 0 || ty < 0 || tx >= MNIST_SIZE || ty >= MNIST_SIZE) continue;
      canvas[ty * MNIST_SIZE + tx] = padded[row * mw + col];
    }
  }

  let m00 = 0;
  let m10 = 0;
  let m01 = 0;
  for (let row = 0; row < MNIST_SIZE; row++) {
    for (let col = 0; col < MNIST_SIZE; col++) {
      const v = canvas[row * MNIST_SIZE + col];
      if (v <= 0) continue;
      m00 += v;
      m10 += col * v;
      m01 += row * v;
    }
  }
  if (m00 <= 0) throw new Error("detected digit has zero intensity");

  const cx = m10 / m00;
  const cy = m01 / m00;
  const target = (MNIST_SIZE - 1) / 2;
  let shiftX = target - cx;
  let shiftY = target - cy;

  const bin = binaryMask(canvas, 0);
  const bb = boundingRect(bin, MNIST_SIZE, MNIST_SIZE, 1);
  if (bb) {
    const minX = EDGE_MARGIN - bb.x;
    const maxX = MNIST_SIZE - EDGE_MARGIN - (bb.x + bb.width);
    const minY = EDGE_MARGIN - bb.y;
    const maxY = MNIST_SIZE - EDGE_MARGIN - (bb.y + bb.height);
    shiftX = Math.min(maxX, Math.max(minX, shiftX));
    shiftY = Math.min(maxY, Math.max(minY, shiftY));
  }

  const sx = Math.round(shiftX);
  const sy = Math.round(shiftY);
  if (sx !== 0 || sy !== 0) {
    const shifted = new Uint8Array(MNIST_SIZE * MNIST_SIZE);
    for (let row = 0; row < MNIST_SIZE; row++) {
      for (let col = 0; col < MNIST_SIZE; col++) {
        const v = canvas[row * MNIST_SIZE + col];
        if (!v) continue;
        const nr = row + sy;
        const nc = col + sx;
        if (nr < 0 || nc < 0 || nr >= MNIST_SIZE || nc >= MNIST_SIZE) continue;
        shifted[nr * MNIST_SIZE + nc] = Math.max(
          shifted[nr * MNIST_SIZE + nc],
          v
        );
      }
    }
    canvas = shifted;
  }
  restoreContrast(canvas, MNIST_SIZE * MNIST_SIZE);

  const pixels = new Array(MNIST_SIZE * MNIST_SIZE);
  for (let i = 0; i < pixels.length; i++) {
    pixels[i] = Math.max(
      0,
      Math.min(127, Math.round(canvas[i] * (INPUT_SCALE / 255)))
    );
  }

  return { normalized: canvas, pixels };
}

/** Upscaled pixel preview (like drawing_webapp scale=10) so 28×28 is easy to see */
export function previewFromPixels(pixels, scale = 10) {
  const s = MNIST_SIZE;
  const canvas = document.createElement("canvas");
  canvas.width = s * scale;
  canvas.height = s * scale;
  const ctx = canvas.getContext("2d");
  ctx.imageSmoothingEnabled = false;
  const img = ctx.createImageData(s, s);
  for (let i = 0; i < 784; i++) {
    const v = Math.round((pixels[i] / 127) * 255);
    img.data[i * 4] = v;
    img.data[i * 4 + 1] = v;
    img.data[i * 4 + 2] = v;
    img.data[i * 4 + 3] = 255;
  }
  // draw 28×28 then scale up nearest-neighbor
  const tiny = document.createElement("canvas");
  tiny.width = s;
  tiny.height = s;
  tiny.getContext("2d").putImageData(img, 0, 0);
  ctx.drawImage(tiny, 0, 0, s * scale, s * scale);
  return canvas.toDataURL("image/png");
}

/**
 * Clean drawing (black ink on white): simple threshold → same fit/center.
 */
export function drawingGrayToMnist(gray, w, h) {
  const component = new Uint8Array(w * h);
  for (let i = 0; i < gray.length; i++) {
    // black ink on white
    component[i] = gray[i] < 200 ? 255 : 0;
  }
  const bounds = boundingRect(component, w, h, 1);
  if (!bounds) throw new Error("draw a digit first");
  if (Math.max(bounds.width, bounds.height) < 8) {
    throw new Error("digit is too small — draw larger");
  }
  return fitAndCenterDigit(component, w, h, bounds);
}

/**
 * Phone photo: segment black digit (webapp-style) → same fit/center as drawings.
 */
export function photoGrayToMnist(gray, w, h) {
  const mask = segmentBlackDigit(gray, w, h);
  const bounds = boundingRect(mask, w, h, 1);
  if (!bounds) throw new Error("no digit found — use dark ink on light paper");

  const minSpan = Math.max(8, Math.round(Math.min(w, h) * 0.03));
  if (Math.max(bounds.width, bounds.height) < minSpan) {
    throw new Error("digit too small — fill more of the frame");
  }

  const area = mask.reduce((a, v) => a + (v ? 1 : 0), 0);
  if (area < 40) throw new Error("digit too small — fill more of the frame");

  // mask is binary 255 ink → fitAndCenter (same as drawing)
  return fitAndCenterDigit(mask, w, h, bounds);
}
