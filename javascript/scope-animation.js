// scope-animation.js
//
// The animated oscilloscope on the Halcyon Instruments product page: two
// slowly detuned oscillators drawn as a Lissajous figure with phosphor
// persistence, the way a real analogue scope would show them.
//
// Usage:
//   <canvas id="scope" aria-label="Animated oscilloscope trace"></canvas>
//   <script src="scope-animation.js" defer></script>
//
// Nothing here depends on a framework. The animation pauses when the canvas
// is off screen or the tab is hidden, and draws a single still frame when the
// reader prefers reduced motion.

(() => {
  "use strict";

  const canvas = document.getElementById("scope");
  if (!(canvas instanceof HTMLCanvasElement)) return;
  const ctx = canvas.getContext("2d", { alpha: false });

  const config = {
    ratioX: 3,              // frequency ratio of the two oscillators
    ratioY: 2,
    detuneHz: 0.07,         // how fast the figure rotates
    points: 900,            // samples per frame
    persistence: 0.14,      // 0 = instant fade, 1 = never fades
    hue: 152,               // P31 phosphor green
    gridDivisions: 8,
  };

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  let width = 0;
  let height = 0;
  let dpr = 1;
  let frameId = 0;
  let visible = true;
  let startTime = performance.now();

  // --- sizing --------------------------------------------------------------

  /** Match the backing store to the CSS size and the display's pixel ratio. */
  function resize() {
    const rect = canvas.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = Math.max(1, Math.round(rect.width));
    height = Math.max(1, Math.round(rect.height));
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    paintBackground(1);
    if (reducedMotion.matches) drawFrame(startTime + 2400);
  }

  // --- drawing -------------------------------------------------------------

  function paintBackground(alpha) {
    ctx.globalCompositeOperation = "source-over";
    ctx.fillStyle = `rgba(6, 12, 10, ${alpha})`;
    ctx.fillRect(0, 0, width, height);
  }

  function drawGrid() {
    const n = config.gridDivisions;
    ctx.save();
    ctx.strokeStyle = "rgba(120, 160, 140, 0.12)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 1; i < n; i++) {
      const x = Math.round((width * i) / n) + 0.5;
      const y = Math.round((height * i) / n) + 0.5;
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
    }
    ctx.stroke();

    // Minor ticks along the centre axes, five per division.
    ctx.strokeStyle = "rgba(120, 160, 140, 0.22)";
    ctx.beginPath();
    const cx = Math.round(width / 2) + 0.5;
    const cy = Math.round(height / 2) + 0.5;
    for (let i = 0; i <= n * 5; i++) {
      const x = (width * i) / (n * 5);
      const y = (height * i) / (n * 5);
      ctx.moveTo(x, cy - 3);
      ctx.lineTo(x, cy + 3);
      ctx.moveTo(cx - 3, y);
      ctx.lineTo(cx + 3, y);
    }
    ctx.stroke();
    ctx.restore();
  }

  /**
   * One frame of the trace. The beam is drawn twice: a wide, faint pass for
   * the glow and a thin, bright pass for the core, both with additive
   * blending so crossings bloom the way phosphor does.
   */
  function drawFrame(now) {
    const t = (now - startTime) / 1000;
    const phase = 2 * Math.PI * config.detuneHz * t;
    const ampX = width * 0.4;
    const ampY = height * 0.4;
    const cx = width / 2;
    const cy = height / 2;

    paintBackground(1 - config.persistence);
    drawGrid();

    ctx.globalCompositeOperation = "lighter";
    ctx.lineJoin = "round";
    ctx.lineCap = "round";

    const path = new Path2D();
    for (let i = 0; i <= config.points; i++) {
      const u = (i / config.points) * 2 * Math.PI;
      // A touch of second harmonic on X makes the figure feel analogue.
      const x = Math.sin(config.ratioX * u + phase) + 0.06 * Math.sin(2 * config.ratioX * u);
      const y = Math.sin(config.ratioY * u);
      const px = cx + x * ampX;
      const py = cy - y * ampY;
      if (i === 0) path.moveTo(px, py);
      else path.lineTo(px, py);
    }

    ctx.strokeStyle = `hsla(${config.hue}, 90%, 55%, 0.18)`;
    ctx.lineWidth = 6;
    ctx.stroke(path);

    ctx.strokeStyle = `hsla(${config.hue}, 100%, 78%, 0.85)`;
    ctx.lineWidth = 1.25;
    ctx.stroke(path);

    ctx.globalCompositeOperation = "source-over";
  }

  // --- the loop ------------------------------------------------------------

  function loop(now) {
    drawFrame(now);
    frameId = requestAnimationFrame(loop);
  }

  function start() {
    if (frameId || reducedMotion.matches || !visible || document.hidden) return;
    frameId = requestAnimationFrame(loop);
  }

  function stop() {
    cancelAnimationFrame(frameId);
    frameId = 0;
  }

  // --- wiring --------------------------------------------------------------

  new ResizeObserver(resize).observe(canvas);

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    visible ? start() : stop();
  }).observe(canvas);

  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));

  reducedMotion.addEventListener("change", () => {
    stop();
    if (reducedMotion.matches) drawFrame(startTime + 2400);
    else start();
  });

  // Click to step through a few classic ratios.
  const ratios = [[3, 2], [5, 4], [1, 1], [2, 1], [5, 3], [7, 4]];
  let ratioIndex = 0;
  canvas.addEventListener("click", () => {
    ratioIndex = (ratioIndex + 1) % ratios.length;
    [config.ratioX, config.ratioY] = ratios[ratioIndex];
    canvas.setAttribute("aria-label", `Oscilloscope trace, ratio ${config.ratioX}:${config.ratioY}`);
    if (reducedMotion.matches) drawFrame(startTime + 2400);
  });

  resize();
  start();
})();
