package metis.gateway.channels.feishu

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*

private func feishuHealthTestTempRoot(label: String): Path {
    Path("/tmp/metis-feishu-health-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
}

private func feishuHealthWriteFile(path: Path, content!: String = "{}"): Unit {
    File.writeTo(path, content.toArray())
}

private func feishuHealthCreateProject(root: Path): Unit {
    Directory.create(root.join("scripts"), recursive: true)
    feishuHealthWriteFile(root.join("scripts").join("feishu-openclaw-sidecar.mjs"), content: "console.log('fake')")
}

private func feishuHealthCreateRuntimePackage(runtimeRoot: Path): Unit {
    Directory.create(runtimeRoot, recursive: true)
    feishuHealthWriteFile(runtimeRoot.join("package.json"), content: "{\"private\":true}")
    feishuHealthWriteFile(runtimeRoot.join("package-lock.json"), content: "{\"lockfileVersion\":3}")
}

private func feishuHealthCreateFakeNodeModules(runtimeRoot: Path): Unit {
    let sdkRoot = runtimeRoot.join("node_modules").join("@larksuiteoapi").join("node-sdk")
    let proxyRoot = runtimeRoot.join("node_modules").join("https-proxy-agent")
    Directory.create(sdkRoot, recursive: true)
    Directory.create(proxyRoot, recursive: true)
    feishuHealthWriteFile(sdkRoot.join("package.json"), content: "{\"name\":\"@larksuiteoapi/node-sdk\"}")
    feishuHealthWriteFile(proxyRoot.join("package.json"), content: "{\"name\":\"https-proxy-agent\"}")
}

private func feishuHealthProbe(ok!: Bool = true): (String, Array<String>) -> FeishuSidecarDependencyCommandProbeResult {
    { command: String, _args: Array<String> =>
        if (!ok && command == "node") {
            FeishuSidecarDependencyCommandProbeResult(false, "", "node missing")
        } else {
            FeishuSidecarDependencyCommandProbeResult(true, "v-test", "")
        }
    }
}

@Test
public class FeishuSidecarDependencyHealthTest {
    @TestCase
    public func reportsMissingSidecarScript(): Unit {
        let root = feishuHealthTestTempRoot("missing-script")
        try {
            let runtimeRoot = root.join("tools").join("feishu-openclaw-sidecar")
            feishuHealthCreateRuntimePackage(runtimeRoot)
            feishuHealthCreateFakeNodeModules(runtimeRoot)

            let health = feishuSidecarDependencyHealth(
                projectRoot: root,
                runtimeRoot: runtimeRoot,
                commandProbe: feishuHealthProbe()
            )
            @Expect(health.status, "missing")
            @Expect(health.missingRequirements.contains("sidecar_script"), true)
            @Expect(health.installHint.contains("npm --prefix tools/feishu-openclaw-sidecar install"), true)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func reportsMissingRuntimePackageJson(): Unit {
        let root = feishuHealthTestTempRoot("missing-package")
        try {
            feishuHealthCreateProject(root)
            let runtimeRoot = root.join("tools").join("feishu-openclaw-sidecar")
            Directory.create(runtimeRoot, recursive: true)

            let health = feishuSidecarDependencyHealth(
                projectRoot: root,
                runtimeRoot: runtimeRoot,
                commandProbe: feishuHealthProbe()
            )
            @Expect(health.status, "missing")
            @Expect(health.missingRequirements.contains("package_json"), true)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func reportsMissingNodeCommand(): Unit {
        let root = feishuHealthTestTempRoot("missing-node")
        try {
            feishuHealthCreateProject(root)
            let runtimeRoot = root.join("tools").join("feishu-openclaw-sidecar")
            feishuHealthCreateRuntimePackage(runtimeRoot)
            feishuHealthCreateFakeNodeModules(runtimeRoot)

            let health = feishuSidecarDependencyHealth(
                projectRoot: root,
                runtimeRoot: runtimeRoot,
                commandProbe: feishuHealthProbe(ok: false)
            )
            @Expect(health.status, "missing")
            @Expect(health.missingRequirements.contains("node"), true)
            @Expect(health.details.contains("node missing"), true)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func reportsMissingNodeModulesWithInstallHint(): Unit {
        let root = feishuHealthTestTempRoot("missing-node-modules")
        try {
            feishuHealthCreateProject(root)
            let runtimeRoot = root.join("tools").join("feishu-openclaw-sidecar")
            feishuHealthCreateRuntimePackage(runtimeRoot)

            let health = feishuSidecarDependencyHealth(
                projectRoot: root,
                runtimeRoot: runtimeRoot,
                commandProbe: feishuHealthProbe()
            )
            @Expect(health.status, "missing")
            @Expect(health.missingRequirements.contains("node_modules"), true)
            @Expect(health.missingRequirements.contains("@larksuiteoapi/node-sdk"), true)
            @Expect(health.missingRequirements.contains("https-proxy-agent"), true)
            @Expect(health.installHint, "Run `npm --prefix tools/feishu-openclaw-sidecar install` from the Metis repository root.")
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func reportsReadyWhenFakePackageIsComplete(): Unit {
        let root = feishuHealthTestTempRoot("ready")
        try {
            feishuHealthCreateProject(root)
            let runtimeRoot = root.join("tools").join("feishu-openclaw-sidecar")
            feishuHealthCreateRuntimePackage(runtimeRoot)
            feishuHealthCreateFakeNodeModules(runtimeRoot)

            let health = feishuSidecarDependencyHealth(
                projectRoot: root,
                runtimeRoot: runtimeRoot,
                commandProbe: feishuHealthProbe()
            )
            @Expect(health.status, "ready")
            @Expect(health.ready, true)
            @Expect(health.missingRequirements.size, 0)
            @Expect(health.toJson().toJsonString().contains("secret-never-visible"), false)
        } finally {
            try { remove(root, recursive: true) } catch (_e: Exception) { () }
        }
    }

    @TestCase
    public func readmeDocumentsSidecarDependencyInstallWithoutNativeNoNodeClaim(): Unit {
        @Expect(exists(Path("README.md")), true)
        let readme = String.fromUtf8(File.readFrom(Path("README.md")))
        @Expect(readme.contains("npm --prefix tools/feishu-openclaw-sidecar install"), true)
        @Expect(readme.contains("Feishu long-connect native adapter"), false)
        @Expect(readme.contains("no longer requires Node/npm"), false)
    }
}
