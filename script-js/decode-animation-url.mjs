#!/usr/bin/env node
// Decode a contractURI(token) data URI dumped by PreviewLLAnimation.s.sol.
// Writes the metadata JSON and the animation_url HTML to disk so the page
// can be opened in a browser.
//
// Usage:
//   node script-js/decode-animation-url.mjs <input.uri.txt> <output.html>

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname, basename, join } from "node:path";

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error("usage: decode-animation-url.mjs <input.uri.txt> <output.html>");
  process.exit(1);
}

const uri = readFileSync(resolve(inPath), "utf8").trim();
const JSON_PREFIX = "data:application/json;base64,";
if (!uri.startsWith(JSON_PREFIX)) {
  console.error("input is not a data:application/json;base64 URI:", uri.slice(0, 40));
  process.exit(2);
}

const json = JSON.parse(Buffer.from(uri.slice(JSON_PREFIX.length), "base64").toString("utf8"));

const metaPath = join(dirname(resolve(outPath)), basename(outPath, ".html") + ".meta.json");
writeFileSync(metaPath, JSON.stringify(json, null, 2));

const anim = json.animation_url ?? "";
const HTML_PREFIX = "data:text/html;base64,";
if (!anim.startsWith(HTML_PREFIX)) {
  console.error("animation_url is not a data:text/html;base64 URI:", anim.slice(0, 40));
  process.exit(3);
}

const html = Buffer.from(anim.slice(HTML_PREFIX.length), "base64").toString("utf8");
writeFileSync(resolve(outPath), html);

console.log("wrote html  :", outPath, "(", html.length, "bytes )");
console.log("wrote meta  :", metaPath);
console.log("name        :", json.name);
console.log("symbol      :", json.symbol);
console.log("description :", json.description);
