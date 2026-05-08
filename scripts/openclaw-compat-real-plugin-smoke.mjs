#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { preparePluginStage } from "./openclaw-compat-installer.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const hostScript = path.join(__dirname, "openclaw-compat-host.mjs");

function parseArgs(argv) {
  const args = {
    plugins: [],
    stageRoot: "",
    openclawPackageRoot: "",
    matrixIn: "",
    matrixOut: "",
    artifactRoot: "",
    runtimeVersion: "2026.3.23",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const value = argv[i + 1] ?? "";
    if (token === "--plugin") {
      const split = value.indexOf(":");
      const pluginId = split > 0 ? value.slice(0, split) : path.basename(value);
      const root = split > 0 ? value.slice(split + 1) : value;
      args.plugins.push({ pluginId, root: path.resolve(root) });
      i += 1;
    } else if (token === "--stage-root") {
      args.stageRoot = path.resolve(value);
      i += 1;
    } else if (token === "--openclaw-package-root") {
      args.openclawPackageRoot = path.resolve(value);
      i += 1;
    } else if (token === "--matrix-in") {
      args.matrixIn = path.resolve(value);
      i += 1;
    } else if (token === "--matrix-out") {
      args.matrixOut = path.resolve(value);
      i += 1;
    } else if (token === "--artifact-root") {
      args.artifactRoot = path.resolve(value);
      i += 1;
    } else if (token === "--runtime-version") {
      args.runtimeVersion = value;
      i += 1;
    }
  }
  return args;
}

function safeName(value) {
  return String(value || "plugin").replace(/[^a-zA-Z0-9._-]+/g, "_");
}

function readJsonFile(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function readJson(raw) {
  try {
    return JSON.parse(raw);
  } catch (error) {
    return { result: null, error: { code: "invalid_host_json", message: error.message, raw } };
  }
}

function runHostLoad(root, runtimeVersion) {
  const request = {
    jsonrpc: "2.0",
    id: 1,
    method: "plugin.load",
    params: {
      roots: [root],
      runtime: { version: runtimeVersion },
    },
  };
  const child = spawnSync(process.execPath, [hostScript, "--once"], {
    input: `${JSON.stringify(request)}\n`,
    encoding: "utf8",
  });
  if (child.status !== 0) {
    return {
      result: null,
      diagnostics: [{ code: "host_process_failed", message: child.stderr || child.stdout, exitCode: child.status }],
    };
  }
  const line = child.stdout.trim().split(/\n+/).find(Boolean) ?? "";
  const response = readJson(line);
  return {
    result: response?.result ?? null,
    diagnostics: response?.result?.diagnostics ?? [],
  };
}

function blockerFromDiagnostic(diagnostic) {
  if (diagnostic.code === "ts_entry_loader_unavailable") {
    return {
      code: "ts_entry_loader_unavailable",
      message: diagnostic.message,
      entry: diagnostic.entry,
    };
  }
  if (
    diagnostic.code === "plugin_load_error" &&
    /(?:Cannot find package 'openclaw'|openclaw\/plugin-sdk|package 'openclaw')/i.test(String(diagnostic.message ?? ""))
  ) {
    return {
      code: "openclaw_sdk_incompatible",
      message: "OpenClaw SDK could not be resolved from staged package; pass --openclaw-package-root for a real SDK link.",
      detail: diagnostic.message,
    };
  }
  if (diagnostic.code === "entry_not_found") {
    return {
      code: "entry_not_found",
      message: "No loadable OpenClaw plugin entry was discovered.",
      root: diagnostic.root,
    };
  }
  if (diagnostic.code === "plugin_load_error") {
    return {
      code: "plugin_load_error",
      message: diagnostic.message,
      entry: diagnostic.entry,
    };
  }
  return null;
}

function blockersFor(hostResult, plan) {
  const blockers = [];
  if (plan.install?.status === "failed") {
    blockers.push({
      code: "install_failed",
      message: "Package dependency install failed in the isolated stage.",
      packageManager: plan.packageManager,
      command: plan.install.command,
      exitCode: plan.install.exitCode,
      stderr: plan.install.stderr,
    });
  } else if (plan.install?.status === "blocked") {
    blockers.push({
      code: "install_required",
      message: "Package has dependencies that are not satisfied by workspace/OpenClaw SDK links in the isolated stage.",
      packageManager: plan.packageManager,
      command: plan.install.command,
    });
  }
  for (const diagnostic of hostResult.diagnostics ?? []) {
    const blocker = blockerFromDiagnostic(diagnostic);
    if (blocker) {
      blockers.push(blocker);
    }
  }
  if ((hostResult.result?.loadedPluginCount ?? 0) === 0 && blockers.length === 0) {
    blockers.push({
      code: "register_not_reached",
      message: "Host completed but no plugin reached register(api).",
    });
  }
  return blockers;
}

function smokeStatus(result, blockers) {
  if (blockers.some((blocker) => blocker.code === "install_failed" || blocker.code === "plugin_load_error")) {
    return "failed";
  }
  return result?.loadedPluginCount > 0 && blockers.length === 0 ? "passed" : "blocked";
}

function loaderFor(hostResult, plan) {
  const plugin = hostResult.result?.plugins?.[0];
  const entry = String(plugin?.entry ?? "");
  if (hostResult.diagnostics?.some((diagnostic) => diagnostic.code === "ts_entry_transpiled")) {
    return "ts-transpile";
  }
  if (entry.includes(`${path.sep}dist${path.sep}`) || entry.includes("/dist/")) {
    return "dist";
  }
  if (entry.endsWith(".ts") || plan.stagedPluginRoot.endsWith(".ts")) {
    return "blocked";
  }
  return entry ? "source" : "blocked";
}

function sourceWriteCheck(sourceRoot) {
  return {
    sourceNodeModulesCreated: fs.existsSync(path.join(sourceRoot, "node_modules")),
    sourceLifecycleMarkerCreated: fs.existsSync(path.join(sourceRoot, "lifecycle-ran.txt")),
    sourceStageCreated: fs.existsSync(path.join(sourceRoot, ".metis-openclaw-stage")),
  };
}

function artifactPathFor(artifactRoot, pluginId) {
  if (!artifactRoot) {
    return "";
  }
  fs.mkdirSync(artifactRoot, { recursive: true });
  return path.join(artifactRoot, `${safeName(pluginId)}-smoke.json`);
}

function updateMatrix(matrix, results) {
  if (!matrix) {
    return matrix;
  }
  const records = Array.isArray(matrix) ? matrix : Array.isArray(matrix.plugins) ? matrix.plugins : Array.isArray(matrix.records) ? matrix.records : [];
  for (const record of records) {
    const match = results.find((result) => {
      const ids = [record.plugin_id, record.pluginId, record.id, record.package_name, record.packageName].filter(Boolean);
      return ids.includes(result.pluginId) || record.source_root === result.sourceRoot || record.sourceRoot === result.sourceRoot;
    });
    if (!match) {
      continue;
    }
    record.real_plugin_smoke_status = match.real_plugin_smoke_status;
    record.real_plugin_smoke_diagnostic = {
      pluginId: match.pluginId,
      stagedPluginRoot: match.stagedPluginRoot,
      loadedPluginCount: match.loadedPluginCount,
      install: match.install,
      loader: match.loader,
      blockers: match.blockers,
    };
    if (match.artifact) {
      record.real_plugin_smoke_artifact = match.artifact;
    }
  }
  return matrix;
}

async function runSmoke(args) {
  const results = [];
  for (const plugin of args.plugins) {
    const stageRoot = path.join(args.stageRoot || path.join(plugin.root, ".metis-openclaw-stage"), safeName(plugin.pluginId));
    const plan = preparePluginStage(plugin.root, {
      stageRoot,
      openclawPackageRoot: args.openclawPackageRoot,
    });
    const hostResult = plan.install?.status === "failed"
      ? { result: null, diagnostics: [] }
      : runHostLoad(plan.stagedPluginRoot, args.runtimeVersion);
    const blockers = blockersFor(hostResult, plan);
    const realPluginSmokeStatus = smokeStatus(hostResult.result, blockers);
    const result = {
      pluginId: plugin.pluginId,
      sourceRoot: plugin.root,
      stageRoot: plan.stageRoot,
      stagedPluginRoot: plan.stagedPluginRoot,
      packageManager: plan.packageManager,
      installCommand: plan.installCommand,
      install: plan.install,
      loader: loaderFor(hostResult, plan),
      loadedPluginCount: hostResult.result?.loadedPluginCount ?? 0,
      real_plugin_smoke_status: realPluginSmokeStatus,
      capabilities: hostResult.result?.capabilities ?? {},
      diagnostics: hostResult.diagnostics ?? [],
      blockers,
      sourceWriteCheck: sourceWriteCheck(plugin.root),
      artifact: "",
    };
    result.artifact = artifactPathFor(args.artifactRoot, plugin.pluginId);
    if (result.artifact) {
      fs.writeFileSync(result.artifact, JSON.stringify(result, null, 2), "utf8");
    }
    results.push(result);
  }

  if (args.matrixIn && args.matrixOut) {
    const matrix = readJsonFile(args.matrixIn, null);
    const mapped = updateMatrix(matrix, results);
    fs.writeFileSync(args.matrixOut, JSON.stringify(mapped, null, 2), "utf8");
  }

  return {
    status: results.every((result) => result.real_plugin_smoke_status === "passed") ? "DONE" : "BLOCKED",
    results,
  };
}

const result = await runSmoke(parseArgs(process.argv.slice(2)));
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
