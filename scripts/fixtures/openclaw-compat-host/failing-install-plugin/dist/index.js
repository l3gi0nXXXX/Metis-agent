export default async function register(api) {
  api.registerTool({ name: "failing.install.tool" }, async () => ({ ok: true }));
}
