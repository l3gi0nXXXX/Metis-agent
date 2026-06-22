import { describe, expect, it, vi } from "vitest";
import {
  canvasStatusLabel,
  captureCanvasSnapshot,
  isCanvasReady,
  loadCanvasRuntime,
  normalizeCanvasRuntimeSnapshot,
  type CanvasState,
} from "./canvas.ts";

function createState(request: ReturnType<typeof vi.fn>): CanvasState {
  return {
    client: { request } as unknown as CanvasState["client"],
    connected: true,
    canvasLoading: false,
    canvasRuntime: null,
    canvasError: null,
    canvasLastReloadAt: null,
    canvasActionBusy: false,
    canvasActionMessage: null,
    canvasActionError: null,
  };
}

describe("canvas controller", () => {
  it("normalizes a ready canvas runtime snapshot", () => {
    const runtime = normalizeCanvasRuntimeSnapshot({
      enabled: true,
      root: "/tmp/metis-canvas",
      port: 18793,
      liveReload: true,
      hostStarted: true,
      httpUrl: "http://127.0.0.1:18793/__metis__/canvas/",
      healthy: true,
      rootPresent: true,
      rootReadable: true,
      assetState: "mounted",
      watchState: "watching",
      phase: "ready",
      routeCount: 3,
      liveReloadEventCount: 2,
    });

    expect(runtime?.watchState).toBe("watching");
    expect(runtime?.routeCount).toBe(3);
    expect(isCanvasReady(runtime)).toBe(true);
    expect(canvasStatusLabel(runtime, null, false)).toBe("ready");
  });

  it("classifies missing and disabled runtime states without throwing", () => {
    expect(normalizeCanvasRuntimeSnapshot(null)).toBeNull();
    const disabled = normalizeCanvasRuntimeSnapshot({ enabled: false, phase: "disabled" });
    expect(isCanvasReady(disabled)).toBe(false);
    expect(canvasStatusLabel(disabled, null, false)).toBe("disabled");
    expect(canvasStatusLabel(null, "boom", false)).toBe("error");
  });

  it("loads canvas.runtime through the gateway client", async () => {
    const request = vi.fn(async () => ({
      canvas: {
        enabled: true,
        hostStarted: true,
        healthy: true,
        rootPresent: true,
        rootReadable: true,
        httpUrl: "http://127.0.0.1:18793/__metis__/canvas/",
      },
    }));
    const state = createState(request);

    await loadCanvasRuntime(state);

    expect(request).toHaveBeenCalledWith("canvas.runtime", {});
    expect(state.canvasError).toBeNull();
    expect(isCanvasReady(state.canvasRuntime)).toBe(true);
  });

  it("records load failures without clearing the previous runtime", async () => {
    const request = vi.fn(async () => {
      throw new Error("canvas offline");
    });
    const state = createState(request);
    state.canvasRuntime = normalizeCanvasRuntimeSnapshot({ enabled: true });

    await loadCanvasRuntime(state);

    expect(state.canvasRuntime?.enabled).toBe(true);
    expect(state.canvasError).toContain("canvas offline");
  });

  it("requests a node canvas snapshot through node.invoke", async () => {
    const request = vi.fn(async () => ({ ok: true }));
    const state = createState(request);

    await captureCanvasSnapshot(state);

    expect(request).toHaveBeenCalledWith("node.invoke", {
      command: "canvas.snapshot",
      payload: { format: "png" },
    });
    expect(state.canvasActionMessage).toBe("Snapshot requested.");
    expect(state.canvasActionError).toBeNull();
  });
});
