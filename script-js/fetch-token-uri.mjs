// Read contractURI() from a deployed ArtCoinsToken on Sepolia, decode, and
// dump both the JSON metadata + the inlined animation_url HTML to disk.
//
// Usage: node script-js/fetch-token-uri.mjs <token-address>

import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const RPC = process.env.RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com";
const TOKEN = process.argv[2];
if (!TOKEN) { console.error("usage: node fetch-token-uri.mjs <token-address>"); process.exit(2); }

const SELECTOR = "0xe8a3d485"; // contractURI()

async function ethCall(to, data) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "eth_call",
      params: [{ to, data }, "latest"],
    }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`rpc error: ${JSON.stringify(j.error)}`);
  return j.result;
}

function decodeAbiString(hex) {
  // ABI-encoded `string`: offset (32B) + length (32B) + data (padded).
  const data = Buffer.from(hex.slice(2), "hex");
  const offset = Number(BigInt("0x" + data.subarray(0, 32).toString("hex")));
  const length = Number(BigInt("0x" + data.subarray(offset, offset + 32).toString("hex")));
  return data.subarray(offset + 32, offset + 32 + length).toString("utf8");
}

const result = await ethCall(TOKEN, SELECTOR);
const uri = decodeAbiString(result);

console.log(`contractURI: ${uri.length} chars`);
fs.mkdirSync(path.join(ROOT, "tmp"), { recursive: true });
fs.writeFileSync(path.join(ROOT, "tmp", "token-uri.txt"), uri);

const jsonPrefix = "data:application/json;base64,";
if (!uri.startsWith(jsonPrefix)) throw new Error("not a json data URI");
const meta = JSON.parse(Buffer.from(uri.slice(jsonPrefix.length), "base64").toString("utf8"));
console.log(`meta: name=${meta.name}, symbol=${meta.symbol}`);
console.log(`description: ${meta.description}`);
console.log(`image: ${meta.image.slice(0, 50)}...  (${meta.image.length} chars)`);
console.log(`animation_url: ${meta.animation_url.slice(0, 50)}...  (${meta.animation_url.length} chars)`);
fs.writeFileSync(path.join(ROOT, "tmp", "token-meta.json"), JSON.stringify(meta, null, 2));

const htmlPrefix = "data:text/html;base64,";
const html = Buffer.from(meta.animation_url.slice(htmlPrefix.length), "base64").toString("utf8");
fs.writeFileSync(path.join(ROOT, "tmp", "token-animation.html"), html);
console.log(`html: ${html.length} bytes -> tmp/token-animation.html`);

// Self-containment check.
const externalScripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)]
  .map(m => m[1])
  .filter(src => !src.startsWith("data:"));
if (externalScripts.length > 0) {
  console.error("⚠ non-data: script srcs:", externalScripts);
  process.exit(2);
}
console.log("✓ self-contained (only data: script srcs)");
