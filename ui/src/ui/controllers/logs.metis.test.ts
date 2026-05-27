import { describe, expect, it, vi } from "vitest";
import { GatewayRequestError } from "../gateway.ts";
import { loadLogs, type LogsState } from "./logs.ts";

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason?: unknown) => void;
};

function createDeferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function createState(request: ReturnType<typeof vi.fn>): LogsState {
  return {
    client: { request } as unknown as LogsState["client"],
    connected: true,
    logsLoading: false,
    logsError: null,
    logsCursor: null,
    logsFile: null,
    logsEntries: [],
    logsTruncated: false,
    logsLastFetchAt: null,
    logsLimit: 500,
    logsMaxBytes: 250_000,
  };
}

describe("loadLogs", () => {
  it("coalesces repeated quiet polling while logs.tail is in flight", async () => {
    const tail = createDeferred<{ cursor: number; lines: string[] }>();
    const request = vi.fn(async (method: string) => {
      expect(method).toBe("logs.tail");
      return await tail.promise;
    });
    const state = createState(request);

    const first = loadLogs(state, { quiet: true });
    const second = loadLogs(state, { quiet: true });
    const third = loadLogs(state, { quiet: true });

    expect(request).toHaveBeenCalledTimes(1);

    tail.resolve({ cursor: 12, lines: [JSON.stringify({ level: "info", message: "ready" })] });
    await Promise.all([first, second, third]);

    expect(state.logsCursor).toBe(12);
    expect(state.logsEntries).toHaveLength(1);
  });

  it("keeps the gateway connection state when logs.tail rejects", async () => {
    const request = vi.fn(async () => {
      throw new GatewayRequestError({
        code: "UNAVAILABLE",
        message: "log tail unavailable",
      });
    });
    const state = createState(request);

    await loadLogs(state, { reset: true });

    expect(state.connected).toBe(true);
    expect(state.logsLoading).toBe(false);
    expect(state.logsError).toBe("log tail unavailable");
    expect(state.logsError).not.toContain("{");
  });
});
