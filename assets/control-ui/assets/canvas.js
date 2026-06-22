import{f as e,u as t}from"./i18n.js";import{l as n}from"./format.js";import{A as r,E as i,F as a,P as o}from"./index.js";function s(t){return e`<span class="pill ${t===`ready`||t===`serving`?`success`:t===`disabled`||t===`unknown`?``:`warn`}">${t}</span>`}function c(e){return e==null||e===``?`n/a`:String(e)}function l(t,n){return e`
    <div class="list-item">
      <div class="list-main">
        <div class="list-title">${t}</div>
      </div>
      <div class="list-meta mono">${c(n)}</div>
    </div>
  `}function u(e){let t=e?.httpUrl?.trim()??``;t&&i(t)}function d(i){let c=o(i.runtime,i.error,i.loading),d=i.runtime,f=a(d);return e`
    <section class="card">
      <div class="row" style="justify-content: space-between; align-items: flex-start;">
        <div>
          <div class="card-title">Canvas Runtime</div>
          <div class="card-sub">Host, root, capability route, and live reload status.</div>
        </div>
        <div class="row" style="gap: 8px; justify-content: flex-end;">
          ${s(c)}
          <button class="btn" ?disabled=${i.loading} @click=${i.onRefresh}>
            <span class="btn-icon" aria-hidden="true">${r.loader}</span>
            ${i.loading?`Refreshing`:`Refresh`}
          </button>
          <button class="btn primary" ?disabled=${!f} @click=${()=>u(d)}>
            <span class="btn-icon" aria-hidden="true">${r.monitor}</span>
            Open
          </button>
          <button class="btn" ?disabled=${i.actionBusy} @click=${i.onScreenshot}>
            <span class="btn-icon" aria-hidden="true">${r.image}</span>
            ${i.actionBusy?`Capturing`:`Screenshot`}
          </button>
        </div>
      </div>
      ${i.error?e`<div class="callout danger" style="margin-top: 12px;">${i.error}</div>`:t}
      ${i.actionError?e`<div class="callout danger" style="margin-top: 12px;">${i.actionError}</div>`:t}
      ${i.actionMessage?e`<div class="callout success" style="margin-top: 12px;">${i.actionMessage}</div>`:t}
      <div class="list" style="margin-top: 16px;">
        ${l(`Enabled`,d?.enabled?`yes`:`no`)}
        ${l(`Host`,d?.hostStarted?`started`:`stopped`)}
        ${l(`Health`,d?.healthy?`healthy`:`not healthy`)}
        ${l(`Root`,d?.root)}
        ${l(`Root readable`,d?.rootReadable?`yes`:`no`)}
        ${l(`Asset state`,d?.assetState)}
        ${l(`URL`,d?.httpUrl)}
        ${l(`Routes`,d?.routeCount??0)}
        ${l(`Live reload`,d?.watchState||(d?.liveReload?`watching`:`static`))}
        ${l(`Reload events`,d?.liveReloadEventCount??0)}
        ${l(`Last pushed reload`,i.lastReloadAt?n(i.lastReloadAt):null)}
      </div>
    </section>
  `}function f(t){return e`
    <section class="grid">
      ${d(t)}
      <section class="card">
        <div class="card-title">Canvas Checks</div>
        <div class="card-sub">Runtime constraints reported by the gateway.</div>
        <div class="list" style="margin-top: 16px;">
          ${l(`Phase`,t.runtime?.phase)}
          ${l(`Error`,t.runtime?.errorKind)}
          ${l(`Port`,t.runtime?.port)}
          ${l(`Live reload enabled`,t.runtime?.liveReload?`yes`:`no`)}
          ${l(`Last host reload event`,t.runtime?.liveReloadLastEventAtMs||null)}
        </div>
      </section>
    </section>
  `}export{d as renderCanvasStatus,f as renderCanvasView};
//# sourceMappingURL=canvas.js.map