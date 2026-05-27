/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import { startLogsPolling, stopLogsPolling } from "./app-polling.ts";

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
};

function createDeferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

function createPollingHost(request: ReturnType<typeof vi.fn>) {
  return {
    tab: "logs",
    nodesPollInterval: null,
    logsPollInterval: null,
    debugPollInterval: null,
    client: { request },
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

describe("logs polling", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("does not start another logs.tail request while a poll is still in flight", async () => {
    vi.useFakeTimers();
    const tail = createDeferred<{ cursor: number; lines: string[] }>();
    const request = vi.fn(async (method: string) => {
      expect(method).toBe("logs.tail");
      return await tail.promise;
    });
    const host = createPollingHost(request);

    startLogsPolling(host);
    await vi.advanceTimersByTimeAsync(6_000);

    expect(request).toHaveBeenCalledTimes(1);

    tail.resolve({ cursor: 1, lines: [] });
    await vi.advanceTimersByTimeAsync(0);
    stopLogsPolling(host);
  });
});
