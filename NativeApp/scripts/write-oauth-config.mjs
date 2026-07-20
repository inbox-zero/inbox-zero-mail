#!/usr/bin/env node

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const nativeAppDirectory = resolve(scriptDirectory, "..");
const outputPath = resolve(nativeAppDirectory, "assets/oauth.json");

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function readXcconfig(path) {
  if (!path) return {};
  const result = {};
  for (const line of readFileSync(resolve(process.cwd(), path), "utf8").split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match && !match[2].startsWith("//")) result[match[1]] = match[2];
  }
  return result;
}

const xcconfig = readXcconfig(argumentValue("--from-xcconfig"));
const value = (name) => (process.env[name] || xcconfig[name] || "").trim();
const config = {
  gmail_client_id: value("INBOX_ZERO_GMAIL_CLIENT_ID"),
  gmail_client_secret: value("INBOX_ZERO_GMAIL_CLIENT_SECRET"),
  outlook_client_id: value("INBOX_ZERO_OUTLOOK_CLIENT_ID"),
};

if (process.argv.includes("--require-gmail")) {
  if (!config.gmail_client_id) throw new Error("INBOX_ZERO_GMAIL_CLIENT_ID is required");
  if (!config.gmail_client_secret) throw new Error("INBOX_ZERO_GMAIL_CLIENT_SECRET is required for this release");
}

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
console.log(`Wrote ${outputPath} (Gmail ${config.gmail_client_id ? "enabled" : "disabled"}, Outlook ${config.outlook_client_id ? "enabled" : "disabled"}).`);
