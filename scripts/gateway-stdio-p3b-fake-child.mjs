#!/usr/bin/env node

import process from "node:process";
import readline from "node:readline";
import fs from "node:fs";
import { spawn } from "node:child_process";

const mode = process.argv[2] ?? "compat";

async function writeStream(stream, bytes) {
  await new Promise((resolve, reject) => {
    stream.write(bytes, (error) => (error ? reject(error) : resolve()));
  });
}

if (mode === "managed-success" || mode === "managed-success-remove-worktree") {
  const unicodeOutput = Buffer.from("仓颉输出🙂\nsecond-line-without-tail");
  const emojiStart = Buffer.from("仓颉输出").length;
  await writeStream(process.stdout, unicodeOutput.subarray(0, emojiStart + 2));
  await new Promise((resolve) => setTimeout(resolve, 10));
  await writeStream(process.stdout, unicodeOutput.subarray(emojiStart + 2));
  await writeStream(process.stderr, "diagnostic 中文🙂\n");
  if (mode === "managed-success-remove-worktree") { fs.rmSync(process.cwd(), { recursive: true, force: true }); }
  process.exit(0);
}

if (mode === "managed-secret") {
  await writeStream(process.stdout, "safe-output");
  await writeStream(process.stderr, "Authorization: Bearer test-secret-token-value");
  process.exit(0);
}

if (mode === "managed-private-path") {
  await writeStream(process.stdout, "safe-output");
  await writeStream(process.stderr, "failed at /Users/example/private-workspace/config.json");
  process.exit(0);
}

if (mode === "managed-stderr-burst") {
  await writeStream(process.stdout, "burst-complete");
  await writeStream(process.stderr, Buffer.alloc(60_000, 0x64));
  process.exit(0);
}

if (mode === "managed-empty") {
  process.exit(0);
}

if (mode === "managed-invalid-utf8") {
  await writeStream(process.stdout, Buffer.from([0xc3, 0x28]));
  process.exit(0);
}

if (mode === "managed-overflow") {
  await writeStream(process.stdout, Buffer.alloc(65_537, 0x61));
  process.exit(0);
}

if (mode === "managed-below-limit") {
  await writeStream(process.stdout, Buffer.alloc(65_535, 0x61));
  process.exit(0);
}

if (mode === "managed-exact-limit") {
  await writeStream(process.stdout, Buffer.alloc(65_536, 0x61));
  process.exit(0);
}

if (mode === "managed-hang") {
  const descendant = spawn(process.execPath, ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], {
    stdio: "ignore",
  });
  if (process.argv[3]) {
    fs.writeFileSync(process.argv[3], `${process.pid}\n${descendant.pid}\n`);
  }
  process.on("SIGTERM", () => {});
  setInterval(() => {}, 1_000);
} else {
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  input.on("line", (line) => {
    let frame;
    try {
      frame = JSON.parse(line);
    } catch {
      process.stdout.write("not-json\n");
      return;
    }
    if (frame.method === "test.timeout") {
      process.on("SIGTERM", () => {});
      const marker = frame.params?.lateWriteMarker;
      setTimeout(() => {
        if (typeof marker === "string" && marker.length > 0) fs.writeFileSync(marker, "late-write-attempted\n");
        process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: frame.id, result: { text: "late-response", ok: true } })}\n`);
      }, 120);
      return;
    }
    if (frame.method === "test.exit") {
      process.exit(7);
    }
    if (frame.method === "test.invalid") {
      process.stdout.write("{invalid-json\n");
      return;
    }
    if (frame.method === "test.invalid-utf8") {
      process.stdout.write(Buffer.from([0xc3, 0x28, 0x0a]));
      return;
    }
    if (frame.method === "test.stderr-burst") {
      for (let index = 0; index < 100; index += 1) {
        process.stderr.write(`diagnostic-${index}-${"d".repeat(256)}\n`);
      }
    }
    process.stderr.write("compat diagnostic Authorization: Bearer test-secret-token-value\n");
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: frame.id, result: { text: "仓颉🙂", ok: true } })}\n`);
  });
}
