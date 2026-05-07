const CHAT_TAB_RENDER_IGNORED_KEYS = new Set([
  "nodes",
  "nodesLoading",
]);

export function shouldMetisAppRenderForChangedKeys(tab: string, keys: readonly string[]): boolean {
  if (tab !== "chat") {
    return true;
  }
  for (const key of keys) {
    if (!CHAT_TAB_RENDER_IGNORED_KEYS.has(key)) {
      return true;
    }
  }
  return false;
}
