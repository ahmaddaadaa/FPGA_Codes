/**
 * Same core 28×28 prep as drawing_webapp/preprocessing.py:
 * - DIGIT_BOX_SIZE = 20
 * - place in 28×28
 * - center by intensity mass
 * - quantize to int8 0..127 with scale 127
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

/**
 * Fit foreground intensity image (ink bright, bg 0) into 28×28 MNIST layout.
 * @param {Uint8Array|Float64Array} component  w*h, bright = ink
 * @param {{x,y,width,height}} bounds
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

  // resize crop → rw x rh via canvas
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
  ctx2.clearRect(0, 0, rw, rh);
  ctx2.drawImage(c1, 0, 0, rw, rh);
  const resizedData = ctx2.getImageData(0, 0, rw, rh).data;
  let resized = new Uint8Array(rw * rh);
  for (let i = 0; i < rw * rh; i++) resized[i] = resizedData[i * 4];
  restoreContrast(resized, rw * rh);

  // margin like STROKE_OPERATION_MARGIN
  const mw = rw + STROKE_MARGIN * 2;
  const mh = rh + STROKE_MARGIN * 2;
  const padded = new Uint8Array(mw * mh);
  for (let row = 0; row < rh; row++) {
    for (let col = 0; col < rw; col++) {
      padded[(row + STROKE_MARGIN) * mw + (col + STROKE_MARGIN)] =
        resized[row * rw + col];
    }
  }
  resized = padded;
  const resizedW = mw;
  const resizedH = mh;

  // place on 28×28
  let canvas = new Uint8Array(MNIST_SIZE * MNIST_SIZE);
  const startX = Math.floor((MNIST_SIZE - resizedW) / 2);
  const startY = Math.floor((MNIST_SIZE - resizedH) / 2);
  for (let row = 0; row < resizedH; row++) {
    for (let col = 0; col < resizedW; col++) {
      const tx = startX + col;
      const ty = startY + row;
      if (tx < 0 || ty < 0 || tx >= MNIST_SIZE || ty >= MNIST_SIZE) continue;
      canvas[ty * MNIST_SIZE + tx] = resized[row * resizedW + col];
    }
  }

  // mass center (same as cv2.moments)
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

  // bounded shift like _bounded_centering_shift
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

  // apply integer shift (good enough vs warpAffine for demo)
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

  // quantize_normalized_image
  const pixels = new Array(MNIST_SIZE * MNIST_SIZE);
  for (let i = 0; i < pixels.length; i++) {
    pixels[i] = Math.max(
      0,
      Math.min(127, Math.round(canvas[i] * (INPUT_SCALE / 255)))
    );
  }

  return { normalized: canvas, pixels };
}

export function previewFromPixels(pixels) {
  const canvas = document.createElement("canvas");
  canvas.width = MNIST_SIZE;
  canvas.height = MNIST_SIZE;
  const ctx = canvas.getContext("2d");
  const img = ctx.createImageData(MNIST_SIZE, MNIST_SIZE);
  for (let i = 0; i < 784; i++) {
    const v = Math.round((pixels[i] / 127) * 255);
    img.data[i * 4] = v;
    img.data[i * 4 + 1] = v;
    img.data[i * 4 + 2] = v;
    img.data[i * 4 + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
  return canvas.toDataURL("image/png");
}

/**
 * Convert a 2D grayscale buffer where dark = ink (photo/drawing style)
 * into MNIST pixels using the webapp fit/center pipeline.
 */
export function darkInkToMnist(gray, w, h) {
  // gray: Float or Uint8 0..255, lower = darker
  let sum = 0;
  for (let i = 0; i < gray.length; i++) sum += gray[i];
  const mean = sum / gray.length;

  // Build bright-ink image on black bg (webapp mask is 255 on ink after BINARY of foreground)
  const component = new Uint8Array(w * h);
  // if background is bright (paper), ink is dark → invert
  const darkIsInk = mean > 100;
  for (let i = 0; i < gray.length; i++) {
    const g = gray[i];
    if (darkIsInk) {
      // black digit on white: ink when dark
      component[i] = g < 200 ? Math.min(255, Math.round(255 - g)) : 0;
    } else {
      // already light-ish digit on dark
      component[i] = g > 40 ? Math.min(255, Math.round(g)) : 0;
    }
  }

  // threshold cleanup
  for (let i = 0; i < component.length; i++) {
    if (component[i] < 40) component[i] = 0;
  }

  const bounds = boundingRect(component, w, h, 1);
  if (!bounds) throw new Error("draw or capture a clearer digit");

  const minSpan = Math.max(4, Math.round(Math.min(w, h) * 0.025));
  if (Math.max(bounds.width, bounds.height) < minSpan) {
    throw new Error("digit is too small — draw larger");
  }

  const area = component.reduce((a, v) => a + (v > 0 ? 1 : 0), 0);
  const minArea = Math.max(12, Math.round(w * h * 0.00005));
  if (area < minArea) throw new Error("digit is too small — draw larger");

  return fitAndCenterDigit(component, w, h, bounds);
}
