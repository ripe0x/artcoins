#!/usr/bin/env python3
"""
Build a self-contained HTML preview of `script-js/data/ll/sketch.js` so the
animation behavior can be eyeballed without going through the contract +
ScriptyBuilder pipeline.

Usage:
    python3 script-js/build-ll-preview.py

Output: tmp/ll-preview.html

Compose:
- The on-disk sketch.js verbatim
- Mona Lisa as a base64 data URI (window.LL_ASSETS)
- A synthetic LL_TOTAL/LL_BITS/LL_SEED that produces a good number of
  visible glyphs (no pool needed)

Open the resulting file in a browser. Click the canvas to test:
  - Page loads → final state (all positions composited)
  - Click → restarts animation from frame 0
  - Click during animation → pauses in place
  - Click while paused → resumes from paused frame
"""
import base64
import hashlib
import os
import random


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> None:
    sketch_path = os.path.join(ROOT, "script-js/data/ll/sketch.js")
    mona_path = os.path.join(ROOT, "script-js/data/ll/mona.jpeg")
    out_dir = os.path.join(ROOT, "tmp")
    out_path = os.path.join(out_dir, "ll-preview.html")

    with open(sketch_path, "rb") as f:
        sketch = f.read().decode("utf-8")
    with open(mona_path, "rb") as f:
        mona_b64 = base64.b64encode(f.read()).decode("ascii")

    # Synthesize ~600 trades (enough to be visually meaningful, not enough to
    # run for hours). LSB-first within each byte. Distribution: 60% buys
    # (1) / 40% sells (0) so the final composition has visible green and red.
    rng = random.Random(0xA11CE)
    total_bits = 600
    n_bytes = (total_bits + 7) // 8
    raw = bytearray(n_bytes)
    for i in range(total_bits):
        if rng.random() < 0.6:
            raw[i >> 3] |= 1 << (i & 7)
    bits_b64 = base64.b64encode(bytes(raw)).decode("ascii")

    # Token address used as motion seed — any 0x...20-byte hex works.
    seed = "0x" + hashlib.sha256(b"ll-preview-seed").hexdigest()[:40]

    html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>LL Preview</title>
  <style>
    body {{
      background: #1a1a1a;
      color: #ccc;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      align-items: center;
      min-height: 100vh;
    }}
    header {{
      padding: 16px 24px;
      width: 100%;
      box-sizing: border-box;
      border-bottom: 1px solid #333;
      font-size: 13px;
      line-height: 1.5;
    }}
    header strong {{ color: #fff; }}
    .legend {{ margin-top: 6px; color: #999; font-size: 12px; }}
    main {{
      padding: 24px;
      display: flex;
      justify-content: center;
      align-items: center;
      flex: 1;
    }}
    /* The sketch sizes its canvas to CONFIG.width / CONFIG.height. Add a
       drop shadow + border so it stands out against the dark background. */
    canvas {{
      box-shadow: 0 4px 24px rgba(0,0,0,0.6);
      border: 1px solid #333;
      max-width: 100%;
      height: auto;
    }}
  </style>
</head>
<body>
  <header>
    <strong>LiquidityLayer sketch preview</strong> — synthetic seed
    <code>{seed}</code>, {total_bits} trades.
    <div class="legend">
      Behavior: page load shows the final composed state.
      <b>Click canvas</b> → restart animation from frame 0.
      <b>Click during animation</b> → pause in place.
      <b>Click while paused</b> → resume from paused frame.
      A complete animation returns to the "stopped/final" state, so
      a click after completion restarts.
    </div>
  </header>
  <main>
    <!-- The sketch builds canvases internally; we just need the document
         body for it to attach to. -->
  </main>
  <script>
    window.LL_ASSETS = {{
      mona: "data:image/jpeg;base64,{mona_b64}"
    }};
    const LL_TOTAL = {total_bits};
    const LL_BITS = "{bits_b64}";
    const LL_SEED = "{seed}";
  </script>
  <script>
{sketch}
  </script>
</body>
</html>
"""

    os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w") as f:
        f.write(html)
    print(f"wrote {out_path} ({len(html):,} bytes)")
    print(f"  sketch.js:   {len(sketch):,} bytes")
    print(f"  mona base64: {len(mona_b64):,} chars")
    print(f"  bits:        {total_bits} trades")
    print()
    print("Open with:")
    print(f"  open {out_path}")


if __name__ == "__main__":
    main()
