import { describe, expect, it, vi } from "vitest";
import { loadOverview } from "./app-settings.ts";
import type { MetisApp } from "./app.ts";

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

function createOverviewHost(request: ReturnType<typeof vi.fn>): MetisApp {
  return {
    client: { request },
    connected: true,
    settings: { gatewayUrl: "ws://127.0.0.1:18789" },
    overviewLogLines: [],
    overviewLogCursor: 0,
    attentionItems: [],
    lastError: null,
    hello: { auth: { role: "operator", scopes: ["operator.read"] } },
    channelsLoading: false,
    channelsSnapshot: null,
    channelsError: null,
    channelsLastSuccess: null,
    presenceLoading: false,
    presenceEntries: [],
    presenceError: null,
    presenceStatus: null,
    sessionsLoading: false,
    sessionsResult: null,
    sessionsError: null,
    sessionsFilterActive: "",
    sessionsFilterLimit: "50",
    sessionsIncludeGlobal: true,
    sessionsIncludeUnknown: false,
    cronStatus: null,
    cronError: null,
    cronLoading: false,
    cronJobsLoadingMore: false,
    cronJobs: [],
    cronJobsTotal: 0,
    cronJobsHasMore: false,
    cronJobsNextOffset: null,
    cronJobsLimit: 50,
    cronJobsQuery: "",
    cronJobsEnabledFilter: "all",
    cronJobsScheduleKindFilter: "all",
    cronJobsLastStatusFilter: "all",
    cronJobsSortBy: "nextRunAtMs",
    cronJobsSortDir: "asc",
    debugLoading: false,
    debugStatus: null,
    debugHealth: null,
    debugModels: [],
    debugHeartbeat: null,
    debugCallMethod: "",
    debugCallParams: "{}",
    debugCallResult: null,
    debugCallError: null,
    skillsLoading: false,
    skillsReport: null,
    skillsError: null,
    skillMessages: {},
    usageLoading: false,
    usageResult: null,
    usageCostSummary: null,
    usageError: null,
    usageStartDate: "2026-05-27",
    usageEndDate: "2026-05-27",
    usageSelectedSessions: [],
    usageSelectedDays: [],
    usageTimeSeries: null,
    usageTimeSeriesLoading: false,
    usageTimeSeriesCursorStart: null,
    usageTimeSeriesCursorEnd: null,
    usageSessionLogs: null,
    usageSessionLogsLoading: false,
    usageTimeZone: "utc",
  } as unknown as MetisApp;
}

function payloadFor(method: string): unknown {
  if (method === "channels.status") {
    return { channelOrder: ["telegram"], channels: { telegram: { running: true } } };
  }
  if (method === "system-presence") {
    return [{ id: "gateway-main" }];
  }
  if (method === "sessions.list") {
    return { sessions: [{ key: "main" }], count: 1, total: 1 };
  }
  if (method === "cron.status") {
    return { enabled: true, jobs: 0, nextWakeAtMs: null };
  }
  if (method === "cron.list") {
    return { jobs: [], total: 0, limit: 50, offset: 0, hasMore: false };
  }
  if (method === "status") {
    return { ok: true };
  }
  if (method === "health") {
    return { ok: true };
  }
  if (method === "models.list") {
    return { models: [{ id: "test-model" }] };
  }
  if (method === "last-heartbeat") {
    return { ts: 1 };
  }
  if (method === "skills.status") {
    return { skills: [] };
  }
  if (method === "sessions.usage") {
    return { sessions: [{ key: "main" }] };
  }
  if (method === "usage.cost") {
    return { totalCost: 0, currency: "USD" };
  }
  return {};
}

describe("loadOverview logs", () => {
  it("does not block the other overview requests when logs.tail fails", async () => {
    const request = vi.fn(async (method: string) => {
      if (method === "logs.tail") {
        throw new Error("log read failed");
      }
      return payloadFor(method);
    });
    const host = createOverviewHost(request);

    await loadOverview(host as unknown as Parameters<typeof loadOverview>[0]);

    expect(host.connected).toBe(true);
    expect(host.channelsSnapshot).toEqual(payloadFor("channels.status"));
    expect(host.presenceEntries).toEqual([{ id: "gateway-main" }]);
    expect(host.sessionsResult).toEqual({ sessions: [{ key: "main" }], count: 1, total: 1 });
    expect(host.cronStatus).toEqual({ enabled: true, jobs: 0, nextWakeAtMs: null });
    expect(host.debugStatus).toEqual({ ok: true });
    expect(host.skillsReport).toEqual({ skills: [] });
    expect(host.usageResult).toEqual({ sessions: [{ key: "main" }] });
    expect(host.overviewLogLines).toEqual([]);
  });

  it("coalesces concurrent overview log refreshes", async () => {
    const tail = createDeferred<{ cursor: number; lines: string[] }>();
    const request = vi.fn(async (method: string) => {
      if (method === "logs.tail") {
        return await tail.promise;
      }
      return payloadFor(method);
    });
    const host = createOverviewHost(request);

    const first = loadOverview(host as unknown as Parameters<typeof loadOverview>[0]);
    const second = loadOverview(host as unknown as Parameters<typeof loadOverview>[0]);

    expect(request.mock.calls.filter(([method]) => method === "logs.tail")).toHaveLength(1);

    tail.resolve({ cursor: 42, lines: ["line one"] });
    await Promise.all([first, second]);

    expect(host.overviewLogCursor).toBe(42);
    expect(host.overviewLogLines).toEqual(["line one"]);
  });
});
