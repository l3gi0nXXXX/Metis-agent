(function () {
  "use strict";

  const state = {
    messages: []
  };

  function text(value) {
    if (value === null || value === undefined) {
      return "";
    }
    if (typeof value === "string") {
      return value;
    }
    try {
      return JSON.stringify(value, null, 2);
    } catch (_err) {
      return String(value);
    }
  }

  function status(value) {
    const el = document.getElementById("metis-a2ui-status");
    if (el) {
      el.textContent = value;
    }
  }

  function render() {
    const root = document.getElementById("metis-a2ui-root");
    if (!root) {
      return;
    }
    root.innerHTML = "";
    for (const message of state.messages) {
      const row = document.createElement("section");
      row.className = "metis-a2ui-message";
      row.textContent = text(message);
      root.appendChild(row);
    }
    status(state.messages.length ? "Rendered " + state.messages.length + " message(s)" : "Ready");
  }

  function applyMessages(messages) {
    if (Array.isArray(messages)) {
      state.messages = messages.slice();
    } else {
      state.messages = [messages];
    }
    render();
  }

  function reset() {
    state.messages = [];
    render();
  }

  function pushJSONL(jsonl) {
    const rows = [];
    for (const line of String(jsonl || "").split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed) {
        continue;
      }
      rows.push(JSON.parse(trimmed));
    }
    applyMessages(rows);
  }

  async function sendUserAction(action) {
    const endpoint = window.__METIS_A2UI_ACTION_ENDPOINT__;
    const session = window.__METIS_A2UI_SESSION__ || new URLSearchParams(window.location.search).get("session") || "";
    if (!endpoint) {
      return { ok: false, error: "Metis A2UI action endpoint is not configured." };
    }
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ session, action: action || {} })
    });
    return response.json();
  }

  window.metisA2UI = {
    applyMessages,
    reset,
    pushJSONL
  };
  window.Metis = window.Metis || {};
  window.Metis.sendUserAction = sendUserAction;

  render();
})();
