import type { GatewayBrowserClient } from "../gateway.ts";

export type CanvasRuntimeSnapshot = {
  enabled: boolean;
  root: string;
  port: number | null;
  liveReload: boolean;
  hostStarted: boolean;
  httpUrl: string;
  healthy: boolean;
  rootPresent: boolean;
  rootReadable: boolean;
  assetState: string;
  watchState: string;
  phase: string;
  errorKind: string;
  routeCount: number;
  liveReloadEventCount: number;
  liveReloadLastEventAtMs: number;
};

export type CanvasState = {
  client: GatewayBrowserClient | null;
  connected: boolean;
  canvasLoading: boolean;
  canvasRuntime: CanvasRuntimeSnapshot | null;
  canvasError: string | null;
  canvasLastReloadAt: number | null;
  canvasActionBusy: boolean;
  canvasActionMessage: string | null;
  canvasActionError: string | null;
};

function readBool(source: Record<string, unknown>, key: string): boolean {
  return source[key] === true;
}

function readString(source: Record<string, unknown>, key: string): string {
  const value = source[key];
  return typeof value === "string" ? value : "";
}

function readNumber(source: Record<string, unknown>, key: string): number | null {
  const value = source[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function normalizeCanvasRuntimeSnapshot(value: unknown): CanvasRuntimeSnapshot | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const source = value as Record<string, unknown>;
  return {
    enabled: readBool(source, "enabled"),
    root: readString(source, "root"),
    port: readNumber(source, "port"),
    liveReload: readBool(source, "liveReload"),
    hostStarted: readBool(source, "hostStarted"),
    httpUrl: readString(source, "httpUrl"),
    healthy: readBool(source, "healthy"),
    rootPresent: readBool(source, "rootPresent"),
    rootReadable: readBool(source, "rootReadable"),
    assetState: readString(source, "assetState"),
    watchState: readString(source, "watchState"),
    phase: readString(source, "phase"),
    errorKind: readString(source, "errorKind"),
    routeCount: readNumber(source, "routeCount") ?? 0,
    liveReloadEventCount: readNumber(source, "liveReloadEventCount") ?? 0,
    liveReloadLastEventAtMs: readNumber(source, "liveReloadLastEventAtMs") ?? 0,
  };
}

export function isCanvasReady(runtime: CanvasRuntimeSnapshot | null): boolean {
  return Boolean(
    runtime?.enabled &&
      runtime.hostStarted &&
      runtime.healthy &&
      runtime.httpUrl.trim() &&
      runtime.rootPresent &&
      runtime.rootReadable,
  );
}

export function canvasStatusLabel(
  runtime: CanvasRuntimeSnapshot | null,
  error: string | null,
  loading: boolean,
): string {
  if (loading && !runtime) {
    return "loading";
  }
  if (error) {
    return "error";
  }
  if (!runtime) {
    return "unknown";
  }
  if (!runtime.enabled) {
    return "disabled";
  }
  if (!runtime.rootPresent || !runtime.rootReadable) {
    return "misconfigured";
  }
  if (!runtime.hostStarted) {
    return "host-not-started";
  }
  if (!runtime.healthy) {
    return "degraded";
  }
  return runtime.liveReload ? "ready" : "serving";
}

export async function loadCanvasRuntime(state: CanvasState, opts?: { quiet?: boolean }) {
  if (!state.client || !state.connected) {
    return;
  }
  if (state.canvasLoading) {
    return;
  }
  state.canvasLoading = true;
  if (!opts?.quiet) {
    state.canvasError = null;
  }
  try {
    const result = await state.client.request<{ canvas?: unknown }>("canvas.runtime", {});
    state.canvasRuntime = normalizeCanvasRuntimeSnapshot(result.canvas);
    state.canvasError = null;
  } catch (err) {
    if (!opts?.quiet) {
      state.canvasError = String(err);
    }
  } finally {
    state.canvasLoading = false;
  }
}

export function handleCanvasReloadEvent(state: CanvasState) {
  state.canvasLastReloadAt = Date.now();
  void loadCanvasRuntime(state, { quiet: true });
}

export async function captureCanvasSnapshot(state: CanvasState) {
  if (!state.client || !state.connected || state.canvasActionBusy) {
    return;
  }
  state.canvasActionBusy = true;
  state.canvasActionMessage = null;
  state.canvasActionError = null;
  try {
    await state.client.request("node.invoke", {
      command: "canvas.snapshot",
      payload: { format: "png" },
    });
    state.canvasActionMessage = "Snapshot requested.";
  } catch (err) {
    state.canvasActionError = String(err);
  } finally {
    state.canvasActionBusy = false;
  }
}
