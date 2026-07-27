// Phone/camera image → 28x28 MNIST-style pixels (0–127)

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

  const side = Math.min(img.width, img.height);
  const sx = Math.floor((img.width - side) / 2);
  const sy = Math.floor((img.height - side) / 2);

  const canvas = document.createElement("canvas");
  canvas.width = 28;
  canvas.height = 28;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });

  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, 28, 28);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(img, sx, sy, side, side, 0, 0, 28, 28);

  const { data } = ctx.getImageData(0, 0, 28, 28);
  const gray = new Array(784);
  let sum = 0;
  for (let i = 0; i < 784; i++) {
    const r = data[i * 4];
    const g = data[i * 4 + 1];
    const b = data[i * 4 + 2];
    const y = 0.299 * r + 0.587 * g + 0.114 * b;
    gray[i] = y;
    sum += y;
  }

  // paper photos are dark-on-light; MNIST is light-on-dark
  const invert = sum / 784 > 127;
  const pixels = gray.map((y) => {
    const v = invert ? 255 - y : y;
    return Math.max(0, Math.min(127, Math.round(v * (127 / 255))));
  });

  const preview = ctx.createImageData(28, 28);
  for (let i = 0; i < 784; i++) {
    const v = Math.round((pixels[i] / 127) * 255);
    preview.data[i * 4] = v;
    preview.data[i * 4 + 1] = v;
    preview.data[i * 4 + 2] = v;
    preview.data[i * 4 + 3] = 255;
  }
  ctx.putImageData(preview, 0, 0);

  return {
    pixels,
    previewDataUrl: canvas.toDataURL("image/png"),
    originalDataUrl,
  };
}
