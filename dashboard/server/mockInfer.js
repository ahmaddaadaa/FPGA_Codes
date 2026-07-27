/**
 * Placeholder classifier until FPGA UDP / integer MLP is wired.
 * Shape features on 28×28 ink (0–127) for demos only — not trained weights.
 *
 * Real path (not used here): Vakili MNIST P16 host infer → 10 logits + cycles
 * https://github.com/ahmaddaadaa/FPGA_Codes/tree/main/Vakili_P16_FPGA
 */

function toGrid(pixels) {
  const g = Array.from({ length: 28 }, () => new Array(28).fill(0));
  for (let i = 0; i < 784; i++) {
    const n = Number(pixels[i]);
    const v = Number.isFinite(n) ? n : 0;
    g[Math.floor(i / 28)][i % 28] = Math.max(0, Math.min(127, Math.round(v)));
  }
  return g;
}

function inkAt(g, r, c) {
  if (r < 0 || c < 0 || r > 27 || c > 27) return 0;
  return g[r][c];
}

function bbox(g, thr = 18) {
  let r0 = 28;
  let r1 = -1;
  let c0 = 28;
  let c1 = -1;
  for (let r = 0; r < 28; r++) {
    for (let c = 0; c < 28; c++) {
      if (g[r][c] < thr) continue;
      if (r < r0) r0 = r;
      if (r > r1) r1 = r;
      if (c < c0) c0 = c;
      if (c > c1) c1 = c;
    }
  }
  if (r1 < 0) return null;
  return { r0, r1, c0, c1 };
}

function regionDensity(g, r0, r1, c0, c1, thr = 18) {
  let ink = 0;
  let n = 0;
  for (let r = r0; r <= r1; r++) {
    for (let c = c0; c <= c1; c++) {
      n += 1;
      if (g[r][c] >= thr) ink += 1;
    }
  }
  return n ? ink / n : 0;
}

function hTransitions(g, r, c0, c1, thr = 18) {
  let t = 0;
  let prev = false;
  for (let c = c0; c <= c1; c++) {
    const on = g[r][c] >= thr;
    if (on !== prev) {
      t += 1;
      prev = on;
    }
  }
  return t;
}

function vTransitions(g, c, r0, r1, thr = 18) {
  let t = 0;
  let prev = false;
  for (let r = r0; r <= r1; r++) {
    const on = g[r][c] >= thr;
    if (on !== prev) {
      t += 1;
      prev = on;
    }
  }
  return t;
}

// flood-fill background from borders; remaining dark holes ≈ loops in digit
function countHoles(g, thr = 18) {
  const seen = Array.from({ length: 28 }, () => new Array(28).fill(false));
  const q = [];

  function push(r, c) {
    if (r < 0 || c < 0 || r > 27 || c > 27) return;
    if (seen[r][c]) return;
    if (g[r][c] >= thr) return; // ink blocks
    seen[r][c] = true;
    q.push([r, c]);
  }

  for (let i = 0; i < 28; i++) {
    push(0, i);
    push(27, i);
    push(i, 0);
    push(i, 27);
  }

  while (q.length) {
    const [r, c] = q.pop();
    push(r - 1, c);
    push(r + 1, c);
    push(r, c - 1);
    push(r, c + 1);
  }

  let holes = 0;
  for (let r = 0; r < 28; r++) {
    for (let c = 0; c < 28; c++) {
      if (seen[r][c] || g[r][c] >= thr) continue;
      holes += 1;
      // fill this hole component
      const qq = [[r, c]];
      seen[r][c] = true;
      while (qq.length) {
        const [rr, cc] = qq.pop();
        for (const [dr, dc] of [
          [-1, 0],
          [1, 0],
          [0, -1],
          [0, 1],
        ]) {
          const nr = rr + dr;
          const nc = cc + dc;
          if (nr < 0 || nc < 0 || nr > 27 || nc > 27) continue;
          if (seen[nr][nc] || g[nr][nc] >= thr) continue;
          seen[nr][nc] = true;
          qq.push([nr, nc]);
        }
      }
    }
  }
  return holes;
}

function features(g) {
  const box = bbox(g);
  if (!box) {
    return null;
  }
  const { r0, r1, c0, c1 } = box;
  const h = r1 - r0 + 1;
  const w = c1 - c0 + 1;
  const aspect = h / Math.max(1, w);

  const midR = (r0 + r1) / 2;
  const midC = (c0 + c1) / 2;
  const thirdH = h / 3;
  const thirdW = w / 3;

  const top = regionDensity(g, r0, r0 + Math.floor(thirdH), c0, c1);
  const mid = regionDensity(
    g,
    r0 + Math.floor(thirdH),
    r0 + Math.floor(2 * thirdH),
    c0,
    c1
  );
  const bot = regionDensity(g, r0 + Math.floor(2 * thirdH), r1, c0, c1);

  const left = regionDensity(g, r0, r1, c0, c0 + Math.floor(thirdW));
  const right = regionDensity(g, r0, r1, c0 + Math.floor(2 * thirdW), c1);
  const center = regionDensity(
    g,
    r0 + Math.floor(thirdH),
    r0 + Math.floor(2 * thirdH),
    c0 + Math.floor(thirdW),
    c0 + Math.floor(2 * thirdW)
  );

  const rowMid = Math.round(midR);
  const colMid = Math.round(midC);
  const ht = hTransitions(g, rowMid, c0, c1);
  const vt = vTransitions(g, colMid, r0, r1);
  const holes = countHoles(g);

  let mass = 0;
  let mx = 0;
  let my = 0;
  for (let r = r0; r <= r1; r++) {
    for (let c = c0; c <= c1; c++) {
      const p = g[r][c];
      if (p < 18) continue;
      mass += p;
      mx += c * p;
      my += r * p;
    }
  }
  const comX = mass ? (mx / mass - c0) / Math.max(1, w) : 0.5;
  const comY = mass ? (my / mass - r0) / Math.max(1, h) : 0.5;

  // upper / lower loops proxy: empty-ish centers in top/bottom halves
  const topCenterEmpty =
    1 -
    regionDensity(
      g,
      r0 + Math.floor(h * 0.15),
      r0 + Math.floor(h * 0.45),
      c0 + Math.floor(w * 0.3),
      c0 + Math.floor(w * 0.7)
    );
  const botCenterEmpty =
    1 -
    regionDensity(
      g,
      r0 + Math.floor(h * 0.55),
      r0 + Math.floor(h * 0.85),
      c0 + Math.floor(w * 0.3),
      c0 + Math.floor(w * 0.7)
    );

  return {
    aspect,
    top,
    mid,
    bot,
    left,
    right,
    center,
    ht,
    vt,
    holes,
    comX,
    comY,
    topCenterEmpty,
    botCenterEmpty,
    density: regionDensity(g, r0, r1, c0, c1),
  };
}

function scoreDigits(f) {
  // higher is better; tuned for clear high-contrast digits
  const s = new Array(10).fill(0);

  // 0: round, one hole, similar top/bot, not too tall
  s[0] += f.holes === 1 ? 3.5 : f.holes === 0 ? 0.2 : -1;
  s[0] += f.aspect > 0.85 && f.aspect < 1.45 ? 1.2 : -0.5;
  s[0] += Math.abs(f.top - f.bot) < 0.15 ? 1 : 0;
  s[0] += f.center < 0.35 ? 1.5 : -0.8;
  s[0] += f.density > 0.25 && f.density < 0.55 ? 0.8 : 0;

  // 1: very tall, thin, left/center mass
  s[1] += f.aspect > 1.6 ? 2.5 : -1;
  s[1] += f.density < 0.35 ? 1.2 : -0.5;
  s[1] += f.ht <= 2 ? 1.2 : -0.8;
  s[1] += f.holes === 0 ? 1 : -2;
  s[1] += f.comX < 0.55 ? 0.6 : 0;

  // 2: bottom heavy, open top, no hole
  s[2] += f.holes === 0 ? 1.2 : -2;
  s[2] += f.bot > f.top + 0.05 ? 1.5 : 0;
  s[2] += f.mid > 0.15 ? 0.8 : 0;
  s[2] += f.ht >= 2 ? 0.8 : 0;
  s[2] += f.comY > 0.5 ? 0.6 : 0;

  // 3: right-heavy, two-ish horizontal lobes, no hole
  s[3] += f.holes === 0 ? 1 : -1.5;
  s[3] += f.right > f.left + 0.05 ? 1.8 : -0.5;
  s[3] += f.ht >= 3 ? 1.2 : 0.3;
  s[3] += Math.abs(f.top - f.bot) < 0.2 ? 0.6 : 0;
  s[3] += f.center > 0.1 ? 0.4 : 0;

  // 4: open top, crossbar mid, often no full hole (or small)
  s[4] += f.holes <= 1 ? 1 : -1;
  s[4] += f.top < f.mid ? 0.8 : 0;
  s[4] += f.vt >= 2 ? 1.2 : 0;
  s[4] += f.left > 0.15 && f.right > 0.1 ? 0.8 : 0;
  s[4] += f.comY < 0.55 ? 0.5 : 0;
  s[4] += f.botCenterEmpty > 0.4 ? 0.6 : 0;

  // 5: top bar, bottom bowl, no hole
  s[5] += f.holes === 0 ? 1.2 : -2;
  s[5] += f.top > f.mid ? 1 : 0;
  s[5] += f.bot > 0.2 ? 1 : 0;
  s[5] += f.left > f.right ? 0.5 : 0;
  s[5] += f.comY > 0.45 ? 0.4 : 0;

  // 6: bottom hole-ish, top open
  s[6] += f.holes === 1 ? 2.5 : f.holes === 0 ? 0.5 : -1;
  s[6] += f.bot > f.top ? 1.5 : -0.5;
  s[6] += f.botCenterEmpty < 0.55 ? 1.2 : 0;
  s[6] += f.topCenterEmpty > 0.35 ? 1 : 0;
  s[6] += f.comY > 0.5 ? 0.8 : 0;

  // 7: top heavy, sparse bottom, tall
  s[7] += f.holes === 0 ? 1.2 : -2;
  s[7] += f.top > f.bot + 0.1 ? 2 : -0.5;
  s[7] += f.density < 0.4 ? 0.8 : 0;
  s[7] += f.comY < 0.45 ? 1 : 0;
  s[7] += f.aspect > 1.1 ? 0.5 : 0;

  // 8: two holes or strong top+bottom loops
  s[8] += f.holes >= 2 ? 3.5 : f.holes === 1 ? 0.8 : -0.5;
  s[8] += f.topCenterEmpty < 0.5 && f.botCenterEmpty < 0.5 ? 1.5 : 0;
  s[8] += Math.abs(f.top - f.bot) < 0.12 ? 0.8 : 0;
  s[8] += f.center > 0.15 ? 0.6 : 0;
  s[8] += f.aspect > 0.9 && f.aspect < 1.5 ? 0.6 : 0;

  // 9: top loop, open bottom
  s[9] += f.holes === 1 ? 2.2 : f.holes === 0 ? 0.4 : -1;
  s[9] += f.top > f.bot ? 1.5 : -0.5;
  s[9] += f.topCenterEmpty < 0.55 ? 1.2 : 0;
  s[9] += f.botCenterEmpty > 0.35 ? 1 : 0;
  s[9] += f.comY < 0.5 ? 0.8 : 0;

  return s;
}

function toLogits(scores) {
  // look a bit like int32 network scores
  const maxS = Math.max(...scores);
  const exps = scores.map((x) => Math.exp((x - maxS) * 1.4));
  const sum = exps.reduce((a, b) => a + b, 0) || 1;
  return scores.map((x, i) => {
    const conf = exps[i] / sum;
    return Math.round(conf * 1400 - 180 + (scores[i] - maxS) * 90);
  });
}

function mockInfer(pixels) {
  if (!Array.isArray(pixels) || pixels.length !== 784) {
    throw new Error("pixels must be length 784 (28x28)");
  }

  const g = toGrid(pixels);
  const f = features(g);

  let scores;
  if (!f) {
    // empty image → weak uniform-ish scores, pick 0
    scores = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  } else {
    scores = scoreDigits(f);
  }

  const logits = toLogits(scores);
  let digit = 0;
  for (let i = 1; i < 10; i++) {
    if (logits[i] > logits[digit]) digit = i;
  }

  return {
    timestamp: new Date().toISOString(),
    digit,
    logits,
    cycles: 15420,
    source: "mock",
    note: "shape-based mock (not FPGA weights yet)",
  };
}

module.exports = { mockInfer };
