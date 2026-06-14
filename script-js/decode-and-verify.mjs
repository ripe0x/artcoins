/**
 * Reads `tmp/contract-uri.txt` (the data:application/json;base64 URI written
 * by VerifyLLRenderer), decodes the JSON, extracts the animation_url HTML
 * data URI, base64-decodes that to plain HTML, writes it to `tmp/animation.html`,
 * then loads it in puppeteer and screenshots the canvas after a short delay.
 *
 * Usage: node script-js/decode-and-verify.mjs
 */

import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ROOT = path.resolve(import.meta.dirname, "..");
const URI_FILE = path.resolve(ROOT, "tmp/contract-uri.txt");
const ANIM_HTML = path.resolve(ROOT, "tmp/animation.html");
const OUT_PNG = path.resolve(ROOT, "tmp/animation-50.png");

function decodeJsonUri(uri) {
  const prefix = "data:application/json;base64,";
  if (!uri.startsWith(prefix)) throw new Error("not a data:application/json;base64 URI");
  return JSON.parse(Buffer.from(uri.slice(prefix.length), "base64").toString("utf8"));
}

function decodeHtmlUri(uri) {
  const prefix = "data:text/html;base64,";
  if (!uri.startsWith(prefix)) throw new Error("animation_url is not a data:text/html;base64 URI");
  return Buffer.from(uri.slice(prefix.length), "base64").toString("utf8");
}

async function main() {
  const raw = fs.readFileSync(URI_FILE, "utf8").trim();
  console.log(`contractURI: ${raw.length} chars`);

  const meta = decodeJsonUri(raw);
  console.log(`metadata fields: ${Object.keys(meta).join(", ")}`);
  console.log(`name=${meta.name}  symbol=${meta.symbol}`);
  console.log(`description=${meta.description}`);
  console.log(`image: ${meta.image.slice(0, 50)}…  (${meta.image.length} chars)`);
  console.log(`animation_url: ${meta.animation_url.slice(0, 50)}…  (${meta.animation_url.length} chars)`);

  const html = decodeHtmlUri(meta.animation_url);
  fs.writeFileSync(ANIM_HTML, html);
  console.log(`wrote ${path.relative(ROOT, ANIM_HTML)}: ${html.length} bytes`);

  // Sanity: the animation should be self-contained — no fetch(), no script src
  // pointing anywhere except an inline data: URI.
  const externalScripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)]
    .map((m) => m[1])
    .filter((src) => !src.startsWith("data:"));
  if (externalScripts.length > 0) {
    console.error("found non-data: script srcs:", externalScripts);
    process.exit(2);
  }
  if (/\bfetch\s*\(/.test(html)) console.warn("warning: html contains fetch( — review for self-containment");

  // Render in puppeteer and screenshot the canvas.
  const browser = await puppeteer.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1100, height: 1100, deviceScaleFactor: 1 });
    const errors = [];
    page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
    page.on("console", (m) => { if (m.type() === "error") errors.push(`console.error: ${m.text()}`); });
    await page.goto(`file://${ANIM_HTML}`, { waitUntil: "networkidle0" });
    await page.waitForFunction("!!document.querySelector('canvas')", { timeout: 15000 });
    // Let the auto-play loop draw for ~3s. With 100 total trades at 600/sec
    // that completes well within a single pass.
    await new Promise((r) => setTimeout(r, 3000));
    const canvas = await page.$("canvas");
    await canvas.screenshot({ path: OUT_PNG });
    console.log(`screenshot -> ${path.relative(ROOT, OUT_PNG)}`);
    if (errors.length) {
      console.error("page errors:", errors);
      process.exit(2);
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
