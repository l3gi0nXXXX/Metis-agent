import { once } from "node:events";
import { pathToFileURL } from "node:url";

const encoder = new TextEncoder();

export function emitFrame(frame, output = process.stdout) {
  output.write(`${JSON.stringify(frame)}\n`);
}

export function emitMalformedBytes(output = process.stdout) {
  output.write(Buffer.from([0xc3, 0x28, 0x0a]));
}

export async function hangUntilKilled({ ignoreTerm = false } = {}) {
  await new Promise((resolve) => {
    process.once("SIGINT", resolve);
    process.once("SIGHUP", resolve);
    process.once("SIGTERM", () => {
      if (!ignoreTerm) {
        resolve();
      }
    });
  });
}

async function writeChunkedFrame(frame) {
  const bytes = encoder.encode(`${JSON.stringify(frame)}\n`);
  const splitAt = Math.max(1, bytes.length - 3);
  process.stdout.write(bytes.subarray(0, splitAt));
  await new Promise((resolve) => setTimeout(resolve, 5));
  process.stdout.write(bytes.subarray(splitAt));
}

export async function runFakeProtocolChild(options = {}) {
  const scenario = options.scenario ?? "sequence";
  if (scenario === "sequence") {
    emitFrame({ type: "ready", child: "fake" });
    emitFrame({ type: "frame", value: "ok" });
    return 0;
  }
  if (scenario === "utf8-boundary") {
    process.stdout.write("\n");
    await writeChunkedFrame({
      type: "frame",
      value: `${"中文🙂".repeat(4096)}末尾🚀`,
    });
    return 0;
  }
  if (scenario === "malformed-bytes") {
    emitMalformedBytes();
    return 0;
  }
  if (scenario === "responsive") {
    emitFrame({ type: "ready", child: "fake" });
    process.stdin.setEncoding("utf8");
    let pending = "";
    process.stdin.on("data", (chunk) => {
      pending += chunk;
      while (true) {
        const newline = pending.indexOf("\n");
        if (newline < 0) {
          break;
        }
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (line.length === 0) {
          continue;
        }
        const request = JSON.parse(line);
        emitFrame({ type: "pollResult", requestId: request.requestId });
      }
    });
    await once(process.stdin, "end");
    return 0;
  }
  if (scenario === "hang") {
    emitFrame({ type: "ready", child: "fake" });
    await hangUntilKilled({ ignoreTerm: options.ignoreTerm === true });
    return 0;
  }
  throw new Error(`unsupported fake child scenario: ${scenario}`);
}

function parseCliOptions(argv) {
  const options = {};
  for (const arg of argv) {
    if (arg.startsWith("--scenario=")) {
      options.scenario = arg.slice("--scenario=".length);
    } else if (arg === "--ignore-term") {
      options.ignoreTerm = true;
    }
  }
  return options;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  runFakeProtocolChild(parseCliOptions(process.argv.slice(2))).then(
    (exitCode) => {
      process.exitCode = exitCode;
    },
    (error) => {
      process.stderr.write(`fake_protocol_child failed: ${error.message}\n`);
      process.exitCode = 1;
    },
  );
}
