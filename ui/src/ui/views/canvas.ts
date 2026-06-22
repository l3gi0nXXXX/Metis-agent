import { html, nothing } from "lit";
import type { CanvasRuntimeSnapshot } from "../controllers/canvas.ts";
import { canvasStatusLabel, isCanvasReady } from "../controllers/canvas.ts";
import { formatRelativeTimestamp } from "../format.ts";
import { icons } from "../icons.ts";
import { openExternalUrlSafe } from "../open-external-url.ts";

export type CanvasProps = {
  loading: boolean;
  runtime: CanvasRuntimeSnapshot | null;
  error: string | null;
  lastReloadAt: number | null;
  actionBusy: boolean;
  actionMessage: string | null;
  actionError: string | null;
  onRefresh: () => void;
  onScreenshot: () => void;
};

function renderStatusChip(label: string) {
  const tone =
    label === "ready" || label === "serving"
      ? "success"
      : label === "disabled" || label === "unknown"
        ? ""
        : "warn";
  return html`<span class="pill ${tone}">${label}</span>`;
}

function valueOrNA(value: string | number | null | undefined) {
  if (value === null || value === undefined || value === "") {
    return "n/a";
  }
  return String(value);
}

function renderMetric(label: string, value: string | number | null | undefined) {
  return html`
    <div class="list-item">
      <div class="list-main">
        <div class="list-title">${label}</div>
      </div>
      <div class="list-meta mono">${valueOrNA(value)}</div>
    </div>
  `;
}

function openCanvas(runtime: CanvasRuntimeSnapshot | null) {
  const url = runtime?.httpUrl?.trim() ?? "";
  if (!url) {
    return;
  }
  openExternalUrlSafe(url);
}

export function renderCanvasStatus(props: CanvasProps) {
  const status = canvasStatusLabel(props.runtime, props.error, props.loading);
  const runtime = props.runtime;
  const ready = isCanvasReady(runtime);
  return html`
    <section class="card">
      <div class="row" style="justify-content: space-between; align-items: flex-start;">
        <div>
          <div class="card-title">Canvas Runtime</div>
          <div class="card-sub">Host, root, capability route, and live reload status.</div>
        </div>
        <div class="row" style="gap: 8px; justify-content: flex-end;">
          ${renderStatusChip(status)}
          <button class="btn" ?disabled=${props.loading} @click=${props.onRefresh}>
            <span class="btn-icon" aria-hidden="true">${icons.loader}</span>
            ${props.loading ? "Refreshing" : "Refresh"}
          </button>
          <button class="btn primary" ?disabled=${!ready} @click=${() => openCanvas(runtime)}>
            <span class="btn-icon" aria-hidden="true">${icons.monitor}</span>
            Open
          </button>
          <button class="btn" ?disabled=${props.actionBusy} @click=${props.onScreenshot}>
            <span class="btn-icon" aria-hidden="true">${icons.image}</span>
            ${props.actionBusy ? "Capturing" : "Screenshot"}
          </button>
        </div>
      </div>
      ${props.error
        ? html`<div class="callout danger" style="margin-top: 12px;">${props.error}</div>`
        : nothing}
      ${props.actionError
        ? html`<div class="callout danger" style="margin-top: 12px;">${props.actionError}</div>`
        : nothing}
      ${props.actionMessage
        ? html`<div class="callout success" style="margin-top: 12px;">${props.actionMessage}</div>`
        : nothing}
      <div class="list" style="margin-top: 16px;">
        ${renderMetric("Enabled", runtime?.enabled ? "yes" : "no")}
        ${renderMetric("Host", runtime?.hostStarted ? "started" : "stopped")}
        ${renderMetric("Health", runtime?.healthy ? "healthy" : "not healthy")}
        ${renderMetric("Root", runtime?.root)}
        ${renderMetric("Root readable", runtime?.rootReadable ? "yes" : "no")}
        ${renderMetric("Asset state", runtime?.assetState)}
        ${renderMetric("URL", runtime?.httpUrl)}
        ${renderMetric("Routes", runtime?.routeCount ?? 0)}
        ${renderMetric("Live reload", runtime?.watchState || (runtime?.liveReload ? "watching" : "static"))}
        ${renderMetric("Reload events", runtime?.liveReloadEventCount ?? 0)}
        ${renderMetric(
          "Last pushed reload",
          props.lastReloadAt ? formatRelativeTimestamp(props.lastReloadAt) : null,
        )}
      </div>
    </section>
  `;
}

export function renderCanvasView(props: CanvasProps) {
  return html`
    <section class="grid">
      ${renderCanvasStatus(props)}
      <section class="card">
        <div class="card-title">Canvas Checks</div>
        <div class="card-sub">Runtime constraints reported by the gateway.</div>
        <div class="list" style="margin-top: 16px;">
          ${renderMetric("Phase", props.runtime?.phase)}
          ${renderMetric("Error", props.runtime?.errorKind)}
          ${renderMetric("Port", props.runtime?.port)}
          ${renderMetric("Live reload enabled", props.runtime?.liveReload ? "yes" : "no")}
          ${renderMetric("Last host reload event", props.runtime?.liveReloadLastEventAtMs || null)}
        </div>
      </section>
    </section>
  `;
}
