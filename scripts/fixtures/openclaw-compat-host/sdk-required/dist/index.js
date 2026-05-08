import { sdk } from "openclaw/plugin-sdk/core";

export default async function register(api) {
  api.registerTool({ name: "sdk.required.tool", sdk }, async () => ({ ok: true }));
}
