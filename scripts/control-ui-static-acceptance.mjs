#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");
const builtRoot = path.join(repoRoot, "assets", "control-ui");
const sourcePublicRoot = path.join(repoRoot, "ui", "public");

const errors = [];

function report(message) {
  errors.push(message);
}

function readUtf8(file) {
  return fs.readFileSync(file, "utf8");
}

function walkFiles(root) {
  if (!fs.existsSync(root)) {
    return [];
  }
  const out = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkFiles(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

function relative(file) {
  return path.relative(repoRoot, file);
}

function isExternalRef(ref) {
  return /^(?:[a-z][a-z0-9+.-]*:|#)/i.test(ref);
}

function normalizeIndexRef(ref) {
  if (!ref || isExternalRef(ref)) {
    return null;
  }
  const withoutFragment = ref.split("#", 1)[0].split("?", 1)[0];
  const normalized = path.posix.normalize(withoutFragment.replace(/^\.?\//, ""));
  if (!normalized || normalized === "." || normalized.startsWith("../") || normalized === "..") {
    return null;
  }
  return normalized;
}

function indexResourceRefs(indexHtml) {
  return Array.from(indexHtml.matchAll(/\b(?:src|href)=["']([^"']+)["']/g))
    .map((match) => match[1])
    .map(normalizeIndexRef)
    .filter((ref) => ref !== null);
}

function checkIndexAndResourceRefs() {
  const indexPath = path.join(builtRoot, "index.html");
  if (!fs.existsSync(indexPath)) {
    report(`${relative(indexPath)} is missing`);
    return { refs: [] };
  }

  const index = readUtf8(indexPath);
  if (!/<metis-app(?:\s|>|\/)/.test(index)) {
    report(`${relative(indexPath)} does not mount <metis-app>`);
  }

  const refs = indexResourceRefs(index);
  if (refs.length === 0) {
    report(`${relative(indexPath)} has no static src/href resource references`);
  }
  for (const ref of refs) {
    const target = path.resolve(builtRoot, ref);
    if (!target.startsWith(path.resolve(builtRoot) + path.sep)) {
      report(`${relative(indexPath)} resource escapes built root: ${ref}`);
      continue;
    }
    if (!fs.existsSync(target) || fs.statSync(target).isDirectory()) {
      report(`${relative(indexPath)} references missing resource: ${ref}`);
    }
  }
  return { refs };
}

function checkBuiltJavaScriptDecorators() {
  const jsFiles = walkFiles(path.join(builtRoot, "assets")).filter((file) => file.endsWith(".js"));
  if (jsFiles.length === 0) {
    report(`${relative(path.join(builtRoot, "assets"))} has no built JavaScript files`);
    return { jsFiles };
  }

  const rawDecoratorPattern = /(^|[\s;({])@(customElement|property|state|query|eventOptions)\s*(?:\(|[\r\n])/m;
  for (const file of jsFiles) {
    const source = readUtf8(file);
    if (rawDecoratorPattern.test(source)) {
      report(`${relative(file)} contains raw TypeScript decorator syntax`);
    }
  }
  return { jsFiles };
}

function checkIconBrandMarkers() {
  const markers = ["lobster-gradient", "Left Claw", "Right Claw", "pixel-lobster"];
  const roots = [builtRoot, sourcePublicRoot];
  const iconFiles = roots
    .flatMap((root) => walkFiles(root))
    .filter((file) => /(?:favicon|touch-icon)/.test(path.basename(file)));

  if (iconFiles.length === 0) {
    report("No Control UI favicon or touch-icon assets found");
    return { iconFiles };
  }

  for (const file of iconFiles) {
    const raw = fs.readFileSync(file);
    for (const marker of markers) {
      if (raw.includes(Buffer.from(marker, "utf8"))) {
        report(`${relative(file)} contains forbidden icon marker ${JSON.stringify(marker)}`);
      }
    }
  }
  return { iconFiles };
}

function sourceSlice(source, startNeedle, endNeedle) {
  const start = source.indexOf(startNeedle);
  if (start < 0) {
    return "";
  }
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  return end < 0 ? source.slice(start) : source.slice(start, end);
}

function checkGatewayProbeRoutesStayOutsideSpaRoutes() {
  const httpSurfacePath = path.join(repoRoot, "src", "gateway", "runtime", "gateway_http_surface.cj");
  const controlRoutesPath = path.join(repoRoot, "src", "gateway", "runtime", "gateway_control_ui_routes.cj");
  const controlRuntimePath = path.join(repoRoot, "src", "gateway", "runtime", "gateway_control_ui_runtime.cj");
  const httpSurface = readUtf8(httpSurfacePath);
  const controlRoutes = readUtf8(controlRoutesPath);
  const controlRuntime = readUtf8(controlRuntimePath);

  for (const route of ["/healthz", "/readyz"]) {
    const probeIndex = httpSurface.indexOf(`s.distributor.register("${route}"`);
    const controlUiIndex = httpSurface.indexOf("gatewayRegisterControlUiRoutes(s, cfg)");
    if (probeIndex < 0) {
      report(`${relative(httpSurfacePath)} does not register ${route}`);
    } else if (controlUiIndex >= 0 && probeIndex > controlUiIndex) {
      report(`${relative(httpSurfacePath)} registers ${route} after Control UI routes`);
    }
  }

  if (!controlRoutes.includes('GatewayControlUiRuntime.registerRoute(server, cfg, "/api/status"')) {
    report(`${relative(controlRoutesPath)} does not register /api/status as an API route`);
  }

  const spaRoutes = sourceSlice(
    controlRuntime,
    "public func gatewayControlUiSpaRoutes",
    "public func gatewayControlUiSnapshotJson",
  );
  if (!spaRoutes) {
    report(`${relative(controlRuntimePath)} does not expose gatewayControlUiSpaRoutes for static inspection`);
    return;
  }
  for (const reservedRoute of ["/healthz", "/readyz", "/api/status"]) {
    if (spaRoutes.includes(`"${reservedRoute}"`)) {
      report(`${relative(controlRuntimePath)} includes reserved API/probe route ${reservedRoute} in SPA routes`);
    }
  }
}

const { refs } = checkIndexAndResourceRefs();
const { jsFiles } = checkBuiltJavaScriptDecorators();
const { iconFiles } = checkIconBrandMarkers();
checkGatewayProbeRoutesStayOutsideSpaRoutes();

if (errors.length > 0) {
  for (const error of errors) {
    console.error(`control-ui-static-acceptance: ${error}`);
  }
  process.exit(1);
}

console.log(
  `control-ui-static-acceptance: passed (${refs.length} index refs, ${jsFiles.length} JS files, ${iconFiles.length} icon assets)`,
);
