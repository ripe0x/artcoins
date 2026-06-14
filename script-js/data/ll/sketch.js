// Liquidity Layer on-chain animation sketch.
//
// Loaded from ScriptyStorage by the LiquidityLayerOnchainRenderer via
// `<script src="data:text/javascript;base64,...">`. Expects the renderer
// to have already injected:
//   const LL_TOTAL    = <uint>;            // count of recorded trades
//   const LL_BITS     = "<base64>";        // packed bit-stream (LSB-first within bytes)
//   const LL_SEED     = "0x<hex>";         // token address, used to seed glyph positions
//   const LL_ASSETS   = { mona: "data:image/...;base64,..." };
//
// Auto-plays once: draws the Mona Lisa, then progressively covers her with
// green plus signs (buys) and red minus signs (sells) in chronological order.
// Clicking the canvas while it runs pauses/resumes the animation. When the
// final layer lands, the finished image holds; clicking then restarts the
// layering from the beginning.

(function () {
  "use strict";

  const CONFIG = {
    width: 1000,
    height: 1000,
    symbolSize: 40,
    symbolStrokeWidth: 6,
    bgWidth: 508,
    bgHeight: 758,
    plusColor: "#0DFF00",
    minusColor: "#FF0000",
  };
  CONFIG.bgX = (CONFIG.width - CONFIG.bgWidth) / 2;
  CONFIG.bgY = (CONFIG.height - CONFIG.bgHeight) / 2;
  CONFIG.overflowAllowance = CONFIG.symbolSize / 6;

  // ─── deterministic placement ─────────────────────────────────────────

  // Ported verbatim from the off-chain svgGenerator; same hashing, same
  // jitter, same minus y-offset, same collision retry.
  function hashToNumber(hash, offset, attempt) {
    if (!hash || hash.length < 10) return offset * 1000007 + attempt;
    const len = hash.length;
    const eff = (offset + attempt * 7) % (len - 10);
    const start = eff + 2;
    const end = Math.min(start + 8, len);
    const truncated = hash.slice(start, end);
    const padded = truncated.padEnd(8, offset.toString());
    const n = parseInt(padded, 16);
    if (Number.isNaN(n)) return offset * 1000007 + attempt;
    return n + offset + attempt;
  }

  function seededRandom(seed) {
    return ((48271 * seed) % 2147483647) / 2147483647;
  }

  function synthHash(seed, i) {
    let s = ((parseInt(seed.slice(2, 10), 16) >>> 0) ^ (i >>> 0)) >>> 0;
    if (s === 0) s = 0x9E3779B9;
    let out = "0x";
    for (let n = 0; n < 8; n++) {
      s ^= s << 13; s >>>= 0;
      s ^= s >>> 17;
      s ^= s << 5; s >>>= 0;
      out += s.toString(16).padStart(8, "0");
    }
    return out;
  }

  function computePositions(txs) {
    const { bgX, bgY, bgWidth, bgHeight, overflowAllowance, symbolSize } = CONFIG;
    const used = new Set();
    const out = new Array(txs.length);

    for (let i = 0; i < txs.length; i++) {
      const tx = txs[i];
      const isMinus = !tx.isBuy;
      const hash = tx.hash;

      let placed = null;
      for (let attempt = 0; attempt < 10; attempt++) {
        const sx = hashToNumber(hash, i, attempt);
        const sy = hashToNumber(hash, i + 1000, attempt + 1000);
        let x = Math.floor(bgX - overflowAllowance + seededRandom(sx) * (bgWidth + 2 * overflowAllowance));
        let y = Math.floor(bgY - overflowAllowance + seededRandom(sy) * (bgHeight + 2 * overflowAllowance));
        if (isMinus) {
          y = Math.floor(
            bgY - symbolSize / 3 - overflowAllowance +
              seededRandom(sy) * (bgHeight + 2 * overflowAllowance + symbolSize * 0.6)
          );
        }
        const jx = hashToNumber(hash, i + 2000, attempt + 2000);
        const jy = hashToNumber(hash, i + 3000, attempt + 3000);
        x += Math.floor(seededRandom(jx) * 5) - 2;
        y += Math.floor(seededRandom(jy) * 5) - 2;
        const key = x + "," + y;
        if (!used.has(key)) { used.add(key); placed = { x, y, isMinus }; break; }
      }
      if (!placed) {
        const x = Math.floor(bgX + (i % Math.floor(bgWidth)));
        const y = Math.floor(bgY + ((i * 17) % Math.floor(bgHeight)));
        used.add(x + "," + y);
        placed = { x, y, isMinus };
      }
      out[i] = placed;
    }
    return out;
  }

  // ─── unpack on-chain bit-stream ──────────────────────────────────────

  // Renderer serializes counter chunks as little-endian bytes; trade i lives
  // at byte (i >> 3), bit (i & 7), LSB-first within the byte.
  function unpackTxs(b64, total, seed) {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const out = new Array(total);
    for (let i = 0; i < total; i++) {
      const isBuy = ((bytes[i >> 3] >> (i & 7)) & 1) === 1;
      out[i] = { isBuy, hash: synthHash(seed, i) };
    }
    return out;
  }

  // ─── DOM scaffolding ─────────────────────────────────────────────────

  const styleEl = document.createElement("style");
  styleEl.textContent =
    "html,body{margin:0;padding:0;background:#000;height:100%}" +
    "body{display:flex;justify-content:center;align-items:center;min-height:100vh}" +
    "canvas{max-width:100vmin;max-height:100vmin;width:100vmin;height:100vmin}";
  document.head.appendChild(styleEl);

  // Visible canvas: gets composited each frame (settled bitmap + active pop-ins).
  const canvas = document.createElement("canvas");
  document.body.appendChild(canvas);
  const ctx = canvas.getContext("2d");
  const dpr = window.devicePixelRatio || 1;

  // Settled canvas: holds the base image plus every shape whose pop-in
  // animation has completed. We blit this onto the visible canvas each
  // frame, then draw still-animating shapes on top.
  const settledCanvas = document.createElement("canvas");
  const settledCtx = settledCanvas.getContext("2d");

  // Match each canvas's backing store to its actual displayed physical-pixel
  // size, so the browser never has to upscale. Without this, the canvas paints
  // into a fixed CONFIG.width×CONFIG.height×dpr buffer that gets stretched to
  // fit the layout, which softens the image (and the mona) on large viewports.
  function sizeCanvases() {
    const rect = canvas.getBoundingClientRect();
    const targetW = Math.max(1, Math.round(rect.width * dpr));
    const targetH = Math.max(1, Math.round(rect.height * dpr));
    if (canvas.width === targetW && canvas.height === targetH) return false;
    canvas.width = targetW;
    canvas.height = targetH;
    settledCanvas.width = targetW;
    settledCanvas.height = targetH;
    const sx = targetW / CONFIG.width;
    const sy = targetH / CONFIG.height;
    ctx.setTransform(sx, 0, 0, sy, 0, 0);
    settledCtx.setTransform(sx, 0, 0, sy, 0, 0);
    return true;
  }

  // Repaint the settled bitmap from `positions[]` for the shapes that have
  // already completed their drop. Used on init, restart, and resize.
  function repaintSettled() {
    paintBase(settledCtx);
    settledCtx.save();
    settledCtx.globalCompositeOperation = "multiply";
    const settledCount = drawnUpTo - (active.length - activeHead);
    for (let i = 0; i < settledCount; i++) {
      const pos = positions[i];
      drawShape(settledCtx, pos, pos.x, pos.y, 1, 1, 0);
    }
    settledCtx.restore();
  }

  // Coalesce ResizeObserver bursts via rAF so window-drag doesn't thrash.
  let resizeFrame = 0;
  function onResize() {
    if (resizeFrame) return;
    resizeFrame = requestAnimationFrame(() => {
      resizeFrame = 0;
      if (sizeCanvases() && monaImg) repaintSettled();
    });
  }
  new ResizeObserver(onResize).observe(canvas);

  // ─── animation loop ──────────────────────────────────────────────────

  let monaImg = null;
  let positions = [];
  let drawnUpTo = 0;
  let lastFrameT = 0;
  const SPEED_MULTIPLIER = 1.25;
  const START_SHAPES_PER_SEC = 180 * SPEED_MULTIPLIER;
  const END_SHAPES_PER_SEC = 2400 * SPEED_MULTIPLIER;
  const DROP_DURATION_MS = 180 / SPEED_MULTIPLIER; // each shape's fall/settle animation length
  const RAMP_ACCELERATION = 2.4;
  const BLUR_FADE_START_ACTIVE = 140;
  const BLUR_FADE_END_ACTIVE = 340;
  let rafId = 0;
  let stopped = false;
  let paused = false;
  let pausedAt = 0;
  let motionSeed = "0x0000000000000000000000000000000000000000";
  let active = []; // queue of shapes still falling into place
  let activeHead = 0;

  function clamp01(x) {
    return Math.max(0, Math.min(1, x));
  }

  function paintBase(targetCtx) {
    targetCtx.globalCompositeOperation = "source-over";
    targetCtx.fillStyle = "#FFFFFF";
    targetCtx.fillRect(0, 0, CONFIG.width, CONFIG.height);
    if (monaImg) targetCtx.drawImage(monaImg, CONFIG.bgX, CONFIG.bgY, CONFIG.bgWidth, CONFIG.bgHeight);
  }

  function paintFinished() {
    repaintSettled();
    ctx.globalCompositeOperation = "source-over";
    ctx.drawImage(settledCanvas, 0, 0, CONFIG.width, CONFIG.height);
  }

  function easeOutCubic(u) {
    return 1 - Math.pow(1 - clamp01(u), 3);
  }

  function perimeterPoint(unit, margin) {
    const edge = Math.floor(unit * 4);
    const local = unit * 4 - edge;
    if (edge === 0) return { x: local * CONFIG.width, y: -margin };
    if (edge === 1) return { x: CONFIG.width + margin, y: local * CONFIG.height };
    if (edge === 2) return { x: (1 - local) * CONFIG.width, y: CONFIG.height + margin };
    return { x: -margin, y: (1 - local) * CONFIG.height };
  }

  function motionUnit(idx, salt) {
    return seededRandom(hashToNumber(motionSeed, idx + salt * 997, salt * 101));
  }

  function layerRate() {
    if (positions.length === 0) return END_SHAPES_PER_SEC;
    const progress = Math.min(1, drawnUpTo / positions.length);
    const eased = 1 - Math.pow(1 - progress, RAMP_ACCELERATION);
    return START_SHAPES_PER_SEC + (END_SHAPES_PER_SEC - START_SHAPES_PER_SEC) * eased;
  }

  function makeDrop(idx, startT) {
    const pos = positions[idx];
    const unit = (idx * 0.61803398875 + motionUnit(idx, 1) * 0.13) % 1;
    const margin = CONFIG.symbolSize * (2.4 + motionUnit(idx, 2) * 5.5);
    const start = perimeterPoint(unit, margin);
    const dx = pos.x - start.x;
    const dy = pos.y - start.y;
    const len = Math.max(1, Math.sqrt(dx * dx + dy * dy));
    const curve = (motionUnit(idx, 3) - 0.5) * CONFIG.symbolSize * 5.2;
    return {
      idx,
      startT,
      startX: start.x,
      startY: start.y,
      travelX: dx / len,
      travelY: dy / len,
      curveX: (-dy / len) * curve,
      curveY: (dx / len) * curve,
      nearScale: 0.45 + motionUnit(idx, 4) * 0.55,
      blur: 1 + motionUnit(idx, 5) * 2.75
    };
  }

  function dropFrame(drop, t) {
    const pos = positions[drop.idx];
    const u = clamp01((t - drop.startT) / DROP_DURATION_MS);
    const fall = easeOutCubic(u);
    const landing = u < 0.78 ? 0 : (u - 0.78) / 0.22;
    const arc = Math.sin(u * Math.PI);
    const settle = Math.sin(landing * Math.PI) * CONFIG.symbolSize * 0.11;
    const depth = Math.pow(arc, 1.35);
    return {
      x: drop.startX + (pos.x - drop.startX) * fall + arc * drop.curveX + drop.travelX * settle,
      y: drop.startY + (pos.y - drop.startY) * fall + arc * drop.curveY + drop.travelY * settle,
      scale: 1 + depth * drop.nearScale,
      alpha: clamp01(u / 0.18),
      blur: depth * drop.blur
    };
  }

  function displayBlur(rawBlur, activeCount) {
    if (rawBlur < 0.75) return 0;
    const fade = 1 - clamp01(
      (activeCount - BLUR_FADE_START_ACTIVE) /
      (BLUR_FADE_END_ACTIVE - BLUR_FADE_START_ACTIVE)
    );
    const blur = Math.min(3, rawBlur * fade);
    return blur < 0.25 ? 0 : blur;
  }

  // Draws a shape (+ for buy, − for sell). multiply blend mode is set by the caller.
  function drawShape(targetCtx, pos, x, y, scale, alpha, blur) {
    const half = Math.floor(CONFIG.symbolSize / 2);
    targetCtx.save();
    targetCtx.globalAlpha = alpha;
    if (blur > 0.1) targetCtx.filter = "blur(" + blur.toFixed(2) + "px)";
    targetCtx.translate(x, y);
    if (scale !== 1) targetCtx.scale(scale, scale);
    targetCtx.beginPath();
    targetCtx.lineWidth = CONFIG.symbolStrokeWidth;
    targetCtx.lineCap = "butt";
    targetCtx.strokeStyle = pos.isMinus ? CONFIG.minusColor : CONFIG.plusColor;
    targetCtx.moveTo(-half, 0); targetCtx.lineTo(half, 0);
    if (!pos.isMinus) {
      targetCtx.moveTo(0, -half); targetCtx.lineTo(0, half);
    }
    targetCtx.stroke();
    targetCtx.restore();
  }

  function tick(t) {
    if (stopped) return;
    const dt = lastFrameT ? (t - lastFrameT) : 16;
    lastFrameT = t;

    // Promote any shapes whose pop-in finished this frame: paint them onto
    // the settled bitmap at full scale + opacity, with multiply blend so
    // they integrate with the Mona Lisa underneath.
    settledCtx.save();
    settledCtx.globalCompositeOperation = "multiply";
    while (activeHead < active.length && t - active[activeHead].startT >= DROP_DURATION_MS) {
      const s = active[activeHead++];
      const pos = positions[s.idx];
      drawShape(settledCtx, pos, pos.x, pos.y, 1, 1, 0);
    }
    settledCtx.restore();
    if (activeHead > 512 && activeHead > active.length / 2) {
      active = active.slice(activeHead);
      activeHead = 0;
    }

    // Push new shapes into the active queue based on the per-second rate.
    // Stagger their startT across the frame so they appear smoothly even
    // when many shapes land in a single rAF.
    const add = Math.max(1, Math.round((dt / 1000) * layerRate()));
    const next = Math.min(positions.length, drawnUpTo + add);
    if (next > drawnUpTo) {
      const stagger = dt / Math.max(1, next - drawnUpTo);
      for (let i = drawnUpTo; i < next; i++) {
        active.push(makeDrop(i, t + (i - drawnUpTo) * stagger - dt));
      }
      drawnUpTo = next;
    }

    // Composite frame: settled bitmap, then animating shapes on top.
    ctx.globalCompositeOperation = "source-over";
    ctx.drawImage(settledCanvas, 0, 0, CONFIG.width, CONFIG.height);
    ctx.save();
    ctx.globalCompositeOperation = "multiply";
    const activeCount = active.length - activeHead;
    for (let i = activeHead; i < active.length; i++) {
      const s = active[i];
      const frame = dropFrame(s, t);
      drawShape(ctx, positions[s.idx], frame.x, frame.y, frame.scale, frame.alpha, displayBlur(frame.blur, activeCount));
    }
    ctx.restore();

    if (drawnUpTo >= positions.length && activeHead >= active.length) {
      stopped = true;
      rafId = 0;
      return;
    }
    rafId = requestAnimationFrame(tick);
  }

  function pause() {
    // Freeze in place: keep settledCanvas + active queue + drawnUpTo as-is.
    // tick() bails on its `if (stopped) return;` guard while paused.
    if (stopped || paused) return;
    paused = true;
    pausedAt = performance.now();
    if (rafId) cancelAnimationFrame(rafId);
    rafId = 0;
  }

  function resume() {
    // Continue from where pause() froze. Shift `lastFrameT` and every in-
    // flight shape's `startT` forward by the pause duration so the next
    // tick computes the same `dt` it would have if we'd never paused.
    if (!paused) return;
    const pauseDuration = performance.now() - pausedAt;
    paused = false;
    pausedAt = 0;
    if (lastFrameT) lastFrameT += pauseDuration;
    for (let i = activeHead; i < active.length; i++) {
      active[i].startT += pauseDuration;
    }
    if (rafId) cancelAnimationFrame(rafId);
    rafId = requestAnimationFrame(tick);
  }

  function restart() {
    // Re-run the animation from drawnUpTo=0. Used when the canvas is in
    // its "final state" (post-init or post-completion).
    if (!stopped) return;
    stopped = false;
    paused = false;
    pausedAt = 0;
    paintBase(settledCtx);
    drawnUpTo = 0;
    lastFrameT = 0;
    active = [];
    activeHead = 0;
    if (rafId) cancelAnimationFrame(rafId);
    rafId = requestAnimationFrame(tick);
  }

  // Three-state click handler:
  //   stopped (final state) → restart from 0
  //   playing               → pause in place
  //   paused                → resume from paused frame
  function handleCanvasClick() {
    if (stopped) { restart(); return; }
    if (paused) resume();
    else pause();
  }

  function loadImage(src) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = reject;
      img.src = src;
    });
  }

  async function init() {
    const monaSrc = (window.LL_ASSETS && window.LL_ASSETS.mona) || "monalisa.png";
    monaImg = await loadImage(monaSrc);
    const seed = (typeof LL_SEED !== "undefined" ? LL_SEED : "0x0000000000000000000000000000000000000000");
    const total = (typeof LL_TOTAL !== "undefined" ? LL_TOTAL : 0);
    const bits = (typeof LL_BITS !== "undefined" ? LL_BITS : "");
    motionSeed = seed;
    const txs = unpackTxs(bits, total, seed);
    positions = computePositions(txs);
    canvas.style.cursor = "pointer";
    canvas.addEventListener("click", handleCanvasClick);
    drawnUpTo = positions.length;
    active = [];
    activeHead = 0;
    stopped = true;
    sizeCanvases();
    paintFinished();
  }

  init();
})();
