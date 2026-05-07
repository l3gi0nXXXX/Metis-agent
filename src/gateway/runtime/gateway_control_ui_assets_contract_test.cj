package metis.gateway.runtime

import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists}
import std.unittest.testmacro.*

private func controlUiAssetsRoot(): Path {
    Path(".").join("assets").join("control-ui")
}

private func controlUiSourceRoot(): Path {
    Path(".").join("ui")
}

private func readUtf8(path: Path): String {
    String.fromUtf8(File.readFrom(path))
}

private func isControlUiTextAsset(path: String): Bool {
    let lowered = path.toAsciiLower()
    lowered.endsWith(".html") ||
    lowered.endsWith(".js") ||
    lowered.endsWith(".mjs") ||
    lowered.endsWith(".css") ||
    lowered.endsWith(".json") ||
    lowered.endsWith(".svg") ||
    lowered.endsWith(".txt") ||
    lowered.endsWith(".map")
}

private func collectControlUiTextAssets(dir: Path, out: ArrayList<Path>): Unit {
    if (!exists(dir)) {
        return
    }
    for (entry in Directory.readFrom(dir)) {
        if (entry.path.toString().contains("/node_modules/") || entry.path.toString().contains("\\node_modules\\")) {
            continue
        }
        if (entry.isDirectory()) {
            collectControlUiTextAssets(entry.path, out)
            continue
        }
        if (isControlUiTextAsset(entry.path.toString())) {
            out.add(entry.path)
        }
    }
}

private func controlUiTextAssetPaths(): ArrayList<Path> {
    let paths = ArrayList<Path>()
    collectControlUiTextAssets(controlUiAssetsRoot(), paths)
    paths
}

private func controlUiTextSourcePaths(): ArrayList<Path> {
    let paths = ArrayList<Path>()
    collectControlUiTextAssets(controlUiSourceRoot(), paths)
    paths
}

private func addForbiddenBrandOffenders(path: Path, text: String, offenders: ArrayList<String>): Unit {
    if (text.contains("OpenClaw")) {
        offenders.add(path.toString() + ": OpenClaw")
    }
    if (text.contains("OPENCLAW")) {
        offenders.add(path.toString() + ": OPENCLAW")
    }
    if (text.contains("openclaw")) {
        offenders.add(path.toString() + ": openclaw")
    }
    if (text.contains("lobster-gradient")) {
        offenders.add(path.toString() + ": OpenClaw lobster icon marker")
    }
    if (text.contains("Left Claw") || text.contains("Right Claw")) {
        offenders.add(path.toString() + ": OpenClaw claw icon marker")
    }
    if (text.contains("pixel-lobster")) {
        offenders.add(path.toString() + ": OpenClaw lobster asset marker")
    }
}

private func joinedControlUiAssetJavaScript(): String {
    let parts = ArrayList<String>()
    let assetsDir = controlUiAssetsRoot().join("assets")
    if (!exists(assetsDir)) {
        return ""
    }
    for (entry in Directory.readFrom(assetsDir)) {
        if (!entry.isDirectory() && entry.path.toString().endsWith(".js")) {
            parts.add(readUtf8(entry.path))
        }
    }
    String.join(parts.toArray(), delimiter: "\n")
}

@Test
public class GatewayControlUiAssetsContractTest {
    @TestCase
    public func controlUiSourceAndAssetsDoNotExposeOpenClawBranding(): Unit {
        let offenders = ArrayList<String>()
        for (path in controlUiTextAssetPaths()) {
            addForbiddenBrandOffenders(path, readUtf8(path), offenders)
        }
        for (path in controlUiTextSourcePaths()) {
            addForbiddenBrandOffenders(path, readUtf8(path), offenders)
        }

        @Expect(String.join(offenders.toArray(), delimiter: "\n"), "")
    }

    @TestCase
    public func controlUiSourceOwnsMetisBuildChain(): Unit {
        let packageJson = readUtf8(controlUiSourceRoot().join("package.json"))
        let viteConfig = readUtf8(controlUiSourceRoot().join("vite.config.ts"))
        let tsConfig = readUtf8(controlUiSourceRoot().join("tsconfig.json"))
        let appSource = readUtf8(controlUiSourceRoot().join("src").join("ui").join("app.ts"))
        let storageSource = readUtf8(controlUiSourceRoot().join("src").join("ui").join("storage.ts"))

        @Expect(packageJson.contains("\"name\": \"metis-control-ui\""), true)
        @Expect(viteConfig.contains("METIS_CONTROL_UI_BASE_PATH"), true)
        @Expect(viteConfig.contains("../assets/control-ui"), true)
        @Expect(viteConfig.contains("entryFileNames: \"assets/[name].js\""), true)
        @Expect(viteConfig.contains("chunkFileNames: \"assets/[name].js\""), true)
        @Expect(viteConfig.contains("assetFileNames: \"assets/[name][extname]\""), true)
        @Expect(tsConfig.contains("\"experimentalDecorators\": true"), true)
        @Expect(tsConfig.contains("\"useDefineForClassFields\": false"), true)
        @Expect(appSource.contains("@customElement(\"metis-app\")"), true)
        @Expect(appSource.contains("export class MetisApp"), true)
        @Expect(storageSource.contains("metis.control.settings.v1"), true)
        @Expect(storageSource.contains("metis.control.token.v1"), true)
    }

    @TestCase
    public func bootstrapDoesNotWriteGatewayTokenIntoUrlHash(): Unit {
        let index = readUtf8(controlUiAssetsRoot().join("index.html"))
        let sourceIndex = readUtf8(controlUiSourceRoot().join("index.html"))

        @Expect(index.contains("window.location.hash ="), false)
        @Expect(index.contains("hash = \"token=\""), false)
        @Expect(index.contains("metis.control.token.v1"), true)
        @Expect(index.contains("writeTokenVariants(sessionStorage"), true)
        @Expect(index.contains("writeTokenVariants(localStorage"), false)
        @Expect(sourceIndex.contains("window.location.hash ="), false)
        @Expect(sourceIndex.contains("hash = \"token=\""), false)
        @Expect(sourceIndex.contains("metis.control.token.v1"), true)
        @Expect(sourceIndex.contains("writeTokenVariants(sessionStorage"), true)
        @Expect(sourceIndex.contains("writeTokenVariants(localStorage"), false)
    }

    @TestCase
    public func chatRouteBundleDoesNotStartNodesPollingForChatTab(): Unit {
        let bundle = joinedControlUiAssetJavaScript()
        let pollingSource = readUtf8(controlUiSourceRoot().join("src").join("ui").join("app-polling.ts"))
        let gatewaySource = readUtf8(controlUiSourceRoot().join("src").join("ui").join("app-gateway.ts"))
        let settingsSource = readUtf8(controlUiSourceRoot().join("src").join("ui").join("app-settings.ts"))
        let boundarySource = readUtf8(controlUiSourceRoot().join("src").join("ui").join("app-render-boundary.ts"))

        @Expect(bundle.contains("function Ar(e){e.nodesPollInterval??=window.setInterval(()=>void kr(e,{quiet:!0}),5e3)}"), false)
        @Expect(bundle.contains("CC(e),kr(e,{quiet:!0}),Qi(e"), false)
        @Expect(pollingSource.contains("function isNodesPollingTab(tab: string): boolean"), true)
        @Expect(pollingSource.contains("if (!isNodesPollingTab(host.tab))"), true)
        @Expect(gatewaySource.contains("if (host.tab === \"nodes\" || host.tab === \"overview\")"), true)
        @Expect(settingsSource.contains("next === \"nodes\" || next === \"overview\""), true)
        @Expect(settingsSource.contains("stopNodesPolling(host as unknown as"), true)
        @Expect(boundarySource.contains("shouldMetisAppRenderForChangedKeys"), true)
        @Expect(boundarySource.contains("\"nodesLoading\""), true)
    }

    @TestCase
    public func controlUiBundleDoesNotContainRawDecoratorSyntax(): Unit {
        let bundle = joinedControlUiAssetJavaScript()

        @Expect(bundle.contains("}(@"), false)
        @Expect(bundle.contains("\n@"), false)
        @Expect(bundle.contains("@customElement"), false)
        @Expect(bundle.contains("@property"), false)
        @Expect(bundle.contains("@state"), false)
    }

    @TestCase
    public func controlUiIndexUsesStableAssetNamesForGatewayStaticRoutes(): Unit {
        let index = readUtf8(controlUiAssetsRoot().join("index.html"))

        @Expect(index.contains("src=\"./assets/index.js\""), true)
        @Expect(index.contains("href=\"./assets/index.css\""), true)
        @Expect(index.contains("assets/index-"), false)
    }

    @TestCase
    public func chatRouteDoesNotServeLegacyInlineFallbackWhenAssetsAreMissing(): Unit {
        let routes = readUtf8(Path(".").join("src").join("gateway").join("runtime").join("gateway_control_ui_routes.cj"))

        @Expect(routes.contains("gatewayBuildControlUiContentHtml(cfg)"), false)
        @Expect(routes.contains("gatewayControlUiAssetsUnavailableHtml(cfg, state)"), true)
    }
}
