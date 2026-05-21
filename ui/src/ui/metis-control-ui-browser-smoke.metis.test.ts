import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, type Page } from "playwright";
import { describe, expect, it } from "vitest";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../../..");
const controlUiRoot = path.join(repoRoot, "assets/control-ui");
const sourcePublicRoot = path.join(repoRoot, "ui/public");
const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const healthzPayload = {
  ok: true,
  status: "live",
};

const degradedReadinessPayload = {
  ok: false,
  ready: false,
  status: "degraded",
  readiness: {
    ok: false,
    ready: false,
    status: "degraded",
    degraded: true,
    reason: "channel-runtime-degraded",
    failedCount: 1,
    startingCount: 0,
    backoffCount: 0,
    accounts: [
      {
        channelId: "telegram",
        accountId: "bot-main",
        lifecycleState: "failed",
        lastError: "poll timeout",
      },
    ],
  },
};

const degradedStatusPayload = {
  readiness: degradedReadinessPayload.readiness,
};

const degradedChannelsStatusPayload = {
  ts: 1,
  channelOrder: ["telegram"],
  channelLabels: { telegram: "Telegram" },
  channelDetailLabels: {},
  channelSystemImages: {},
  channelMeta: [
    {
      id: "telegram",
      label: "Telegram",
      detailLabel: "Bot status and channel configuration.",
    },
  ],
  channels: {
    telegram: {
      configured: true,
      tokenSource: "env",
      running: false,
      mode: "polling",
      lastError: "poll timeout",
      probe: {
        ok: false,
        error: "poll timeout",
      },
    },
  },
  channelAccounts: {
    telegram: [
      {
        accountId: "bot-main",
        name: "Telegram bot-main",
        enabled: true,
        configured: true,
        running: false,
        connected: false,
        lastError: "poll timeout",
      },
    ],
  },
  channelDefaultAccountId: { telegram: "bot-main" },
};

function walkFiles(root: string): string[] {
  if (!fs.existsSync(root)) {
    return [];
  }
  const out: string[] = [];
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

function contentType(file: string): string {
  if (file.endsWith(".html")) {
    return "text/html; charset=utf-8";
  }
  if (file.endsWith(".js")) {
    return "text/javascript; charset=utf-8";
  }
  if (file.endsWith(".css")) {
    return "text/css; charset=utf-8";
  }
  if (file.endsWith(".json") || file.endsWith(".map")) {
    return "application/json; charset=utf-8";
  }
  if (file.endsWith(".svg")) {
    return "image/svg+xml";
  }
  if (file.endsWith(".png")) {
    return "image/png";
  }
  return "application/octet-stream";
}

function isExternalRef(ref: string): boolean {
  return /^(?:[a-z][a-z0-9+.-]*:|#)/i.test(ref);
}

function indexResourceRefs(indexHtml: string): string[] {
  return Array.from(indexHtml.matchAll(/\b(?:src|href)=["']([^"']+)["']/g))
    .map((match) => match[1])
    .filter((ref): ref is string => Boolean(ref) && !isExternalRef(ref))
    .map((ref) => ref.split("#", 1)[0].split("?", 1)[0])
    .map((ref) => path.posix.normalize(ref.replace(/^\.?\//, "")))
    .filter((ref) => ref !== "." && !ref.startsWith("../") && ref !== "..");
}

function startServer(): Promise<{ url: string; close: () => Promise<void> }> {
  const server = http.createServer((req, res) => {
    const requestUrl = new URL(req.url ?? "/", "http://127.0.0.1");
    const replyJson = (payload: unknown) => {
      res.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-cache",
      });
      res.end(JSON.stringify(payload));
    };
    if (requestUrl.pathname === "/healthz") {
      replyJson(healthzPayload);
      return;
    }
    if (requestUrl.pathname === "/readyz") {
      replyJson(degradedReadinessPayload);
      return;
    }
    if (requestUrl.pathname === "/api/status") {
      replyJson(degradedStatusPayload);
      return;
    }
    if (requestUrl.pathname === "/__metis/control-ui-config.json") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ basePath: "/", wsUrl: "ws://127.0.0.1:18788/ws" }));
      return;
    }
    if (requestUrl.pathname === "/__metis/control-ui-auth.json") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ authToken: "smoke-token", authPassword: "" }));
      return;
    }
    const rel =
      requestUrl.pathname === "/" ||
      requestUrl.pathname === "/chat" ||
      requestUrl.pathname === "/channels" ||
      requestUrl.pathname === "/agent-teams"
        ? "index.html"
        : requestUrl.pathname.replace(/^\/+/, "");
    const full = path.resolve(controlUiRoot, rel);
    if (
      !full.startsWith(controlUiRoot) ||
      !fs.existsSync(full) ||
      fs.statSync(full).isDirectory()
    ) {
      res.writeHead(404);
      res.end("not found");
      return;
    }
    res.writeHead(200, { "content-type": contentType(full) });
    fs.createReadStream(full).pipe(res);
  });

  return new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("failed to bind test server"));
        return;
      }
      resolve({
        url: `http://127.0.0.1:${address.port}`,
        close: () => new Promise((done) => server.close(() => done())),
      });
    });
  });
}

async function installFakeGatewayWebSocket(page: Page) {
  await page.addInitScript((channelsStatus) => {
    const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
    class FakeGatewayWebSocket extends EventTarget {
      url: string;
      readyState = states.CONNECTING;
      binaryType = "blob";
      protocol = "";
      extensions = "";
      onopen: ((event: Event) => void) | null = null;
      onmessage: ((event: MessageEvent) => void) | null = null;
      onerror: ((event: Event) => void) | null = null;
      onclose: ((event: CloseEvent) => void) | null = null;

      constructor(url: string) {
        super();
        this.url = String(url);
        window.setTimeout(() => {
          if (this.readyState !== states.CONNECTING) {
            return;
          }
          this.readyState = states.OPEN;
          this.emit("open", new Event("open"));
        }, 0);
      }

      send(raw: string) {
        const parsed = JSON.parse(String(raw)) as {
          type?: string;
          id?: string;
          method?: string;
        };
        if (parsed.type !== "req" || !parsed.id) {
          return;
        }
        const payload = this.payloadFor(parsed.method ?? "");
        window.setTimeout(() => {
          this.emit(
            "message",
            new MessageEvent("message", {
              data: JSON.stringify({ type: "res", id: parsed.id, ok: true, payload }),
            }),
          );
        }, 0);
      }

      close(code = 1000, reason = "") {
        if (this.readyState === states.CLOSED) {
          return;
        }
        this.readyState = states.CLOSED;
        this.emit("close", new CloseEvent("close", { code, reason }));
      }

      private emit(type: "open", event: Event): void;
      private emit(type: "message", event: MessageEvent): void;
      private emit(type: "close", event: CloseEvent): void;
      private emit(type: string, event: Event): void {
        this.dispatchEvent(event);
        const handler = this[`on${type}` as keyof this];
        if (typeof handler === "function") {
          (handler as (event: Event) => void).call(this, event);
        }
      }

      private payloadFor(method: string) {
        if (method === "connect") {
          return {
            type: "hello-ok",
            protocol: 3,
            server: { version: "smoke" },
            features: { methods: ["channels.status", "health"], events: [] },
            snapshot: {
              health: {
                ok: false,
                ts: 1,
                durationMs: 0,
                heartbeatSeconds: 0,
                defaultAgentId: "main",
                agents: [],
                sessions: { path: "", count: 0, recent: [] },
              },
              sessionDefaults: {
                defaultAgentId: "main",
                mainKey: "main",
                mainSessionKey: "agent:main:main",
              },
            },
            auth: {
              role: "operator",
              scopes: ["operator.admin", "operator.read", "operator.write"],
            },
            policy: { tickIntervalMs: 1000 },
          };
        }
        if (method === "channels.status") {
          return channelsStatus;
        }
        if (method === "health") {
          return {
            ok: false,
            ts: 1,
            durationMs: 0,
            heartbeatSeconds: 0,
            defaultAgentId: "main",
            agents: [],
            sessions: { path: "", count: 0, recent: [] },
          };
        }
        if (method === "agents.list") {
          return { defaultId: "main", agents: [] };
        }
        if (method === "agent.identity.get") {
          return { agentId: "main", name: "Metis", avatar: null };
        }
        if (method === "device.pair.list") {
          return { pending: [], paired: [] };
        }
        if (method === "sessions.subscribe") {
          return {};
        }
        if (method === "sessions.list") {
          return { sessions: [], count: 0, total: 0 };
        }
        if (method === "config.schema") {
          return { version: "smoke", schema: { type: "object", properties: {} }, uiHints: {} };
        }
        if (method === "config.get") {
          return { raw: "{}", config: {}, valid: true, issues: [] };
        }
        if (method === "logs.tail") {
          return { cursor: 0, lines: [] };
        }
        if (method === "models.list") {
          return { models: [] };
        }
        return {};
      }
    }
    Object.assign(FakeGatewayWebSocket, states);
    Object.defineProperty(window, "WebSocket", {
      configurable: true,
      writable: true,
      value: FakeGatewayWebSocket,
    });
  }, degradedChannelsStatusPayload);
}

async function assertProbeAndApiRoutes(page: Page, baseUrl: string) {
  const probes = await page.evaluate(async (url) => {
    const out: Array<{
      path: string;
      status: number;
      contentType: string;
      body: Record<string, unknown>;
      textPrefix: string;
    }> = [];
    for (const path of ["/healthz", "/readyz", "/api/status"]) {
      const res = await fetch(`${url}${path}`);
      const text = await res.text();
      out.push({
        path,
        status: res.status,
        contentType: res.headers.get("content-type") ?? "",
        body: JSON.parse(text),
        textPrefix: text.slice(0, 15),
      });
    }
    return out;
  }, baseUrl);
  expect(probes.map((probe) => probe.status)).toEqual([200, 200, 200]);
  for (const probe of probes) {
    expect(probe.contentType, probe.path).toContain("application/json");
    expect(probe.textPrefix, probe.path).not.toMatch(/^<!doctype html/i);
  }
  expect(probes[0]?.body.status).toBe("live");
  expect(probes[1]?.body.status).toBe("degraded");
  expect((probes[2]?.body.readiness as { status?: string } | undefined)?.status).toBe("degraded");
}

describe("Metis control-ui browser smoke", () => {
  it("built assets contain browser-safe JavaScript and Metis-owned branding", () => {
    const indexPath = path.join(controlUiRoot, "index.html");
    const indexHtml = fs.readFileSync(indexPath, "utf8");
    expect(indexHtml).toMatch(/<metis-app(?:\s|>|\/)/);
    const missingIndexRefs = indexResourceRefs(indexHtml)
      .filter((ref) => !fs.existsSync(path.join(controlUiRoot, ref)))
      .map((ref) => `${path.relative(repoRoot, indexPath)} -> ${ref}`);
    expect(missingIndexRefs).toEqual([]);

    const jsFiles = walkFiles(path.join(controlUiRoot, "assets")).filter((file) =>
      file.endsWith(".js"),
    );
    expect(jsFiles.length).toBeGreaterThan(0);
    for (const file of jsFiles) {
      const rel = path.relative(controlUiRoot, file);
      const source = fs.readFileSync(file, "utf8");
      expect(source, rel).not.toMatch(/@customElement\s*\(/);
      expect(source, rel).not.toMatch(/@(property|state|query|eventOptions)\s*(\(|\n)/);
    }

    const markers = ["lobster-gradient", "Left Claw", "Right Claw", "pixel-lobster"];
    const markerFiles = [controlUiRoot, sourcePublicRoot]
      .flatMap((root) => walkFiles(root))
      .filter((file) => /(?:favicon|touch-icon|public|assets\/control-ui)/.test(file));
    expect(markerFiles.length).toBeGreaterThan(0);
    for (const full of markerFiles) {
      const rel = path.relative(repoRoot, full);
      const raw = fs.readFileSync(full).toString("utf8");
      for (const marker of markers) {
        expect(raw, rel).not.toContain(marker);
      }
    }
  });

  it.skipIf(!fs.existsSync(chromePath))("registers the metis app in a real browser", async () => {
    const server = await startServer();
    const browser = await chromium.launch({ headless: true, executablePath: chromePath });
    try {
      const page = await browser.newPage();
      await installFakeGatewayWebSocket(page);
      const errors: string[] = [];
      const failedJsCssRequests: string[] = [];
      page.on("pageerror", (err) => errors.push(err.message));
      page.on("requestfailed", (req) => errors.push(`${req.url()} ${req.failure()?.errorText}`));
      page.on("response", (res) => {
        const url = res.url();
        if ((url.endsWith(".js") || url.endsWith(".css")) && res.status() >= 400) {
          failedJsCssRequests.push(`${res.status()} ${url}`);
        }
      });
      const routes = [
        "/chat?session=agent%3Amain%3Aexplicit%3Acli%3Amain",
        "/channels",
        "/agent-teams",
      ];
      const appStates = [];
      for (const route of routes) {
        await page.goto(`${server.url}${route}`, {
          waitUntil: "domcontentloaded",
        });
        await page.waitForFunction(() => Boolean(customElements.get("metis-app")));
        appStates.push(await page.evaluate(() => ({
          defined: Boolean(customElements.get("metis-app")),
          renderedText: document.querySelector("metis-app")?.textContent?.trim().slice(0, 4096) ?? "",
          visible:
            document.querySelector("metis-app") instanceof HTMLElement &&
            document.querySelector("metis-app")!.getBoundingClientRect().height > 0,
          pathname: window.location.pathname,
          scopedSessionToken: sessionStorage.getItem("metis.control.token.v1:ws://127.0.0.1:18788/ws"),
          legacyLocalToken: localStorage.getItem("metis.control.token.v1"),
          scopedLocalToken: localStorage.getItem("metis.control.token.v1:ws://127.0.0.1:18788/ws"),
        })));
      }
      await assertProbeAndApiRoutes(page, server.url);
      expect(errors).toEqual([]);
      expect(failedJsCssRequests).toEqual([]);
      for (const appState of appStates) {
        expect(appState.defined).toBe(true);
        expect(appState.visible).toBe(true);
        expect(appState.renderedText).toContain("Metis");
        expect(appState.scopedSessionToken).toBe("smoke-token");
        expect(appState.legacyLocalToken).toBeNull();
        expect(appState.scopedLocalToken).toBeNull();
      }
      expect(appStates[1]?.renderedText).toContain("poll timeout");
      expect(appStates[2]?.pathname).toBe("/agent-teams");
    } finally {
      await browser.close();
      await server.close();
    }
  }, 20_000);
});
