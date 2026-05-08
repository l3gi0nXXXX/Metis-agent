import { value } from "fixture-local-dep";

export default async function register(api) {
  api.registerTool({ name: "installable.fixture.tool", value }, async () => ({ ok: true, value }));
}
