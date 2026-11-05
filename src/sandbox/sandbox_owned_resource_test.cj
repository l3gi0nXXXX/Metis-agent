package metis.sandbox

import metis.core.config.CliConfig
import metis.process.{ManagedOwnedChild, ProcessBirthIdentity, launchManagedRawChild, managedStdioResolveNodeCommand,
    parseProcessBirthIdentity, observeProcessBirthIdentity, probeProcessBirthIdentity, managedRecoveryReadText, managedRecoveryParseFields}
import magic.config.Config
import std.collection.{ArrayList, HashMap, Map, map, collectArray}
import std.convert.Parsable
import std.env.{getVariables, getCommand}
import std.fs.{FileInfo, OpenMode, canonicalize, copy, rename}
import std.io.SeekPosition
import std.process.{ProcessRedirect, ProcessException}
import std.runtime.{getThreadCount, getBlockingThreadCount, getMaxHeapSize}
import std.sync.AtomicBool
import stdx.crypto.digest.SHA256
import stdx.encoding.json.*

import std.posix.chmod
import metis.process.{currentProcessInstanceIdentity, managedRecoveryInitialize, managedRecoveryStopOwnedChildren, managedRecoveryProbeRecords}
import std.env.{getVariable, setVariable, removeVariable, getProcessId}
import std.fs.{Path, File, Directory, exists, remove}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*

@When[os == "macOS"]
foreign { func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, bufferSize: Int32): Int32 }

@When[os == "macOS"]
private func ownedFixtureFds(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("owned_fixture_fd_unknown") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func ownedFixtureContext(action: (Path, String) -> (Bool, Bool)): Unit {
    let home = Path("/private/tmp/metis-caller-owned-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
    let directory = home.join("inventory")
    let priorDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
    let priorParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    var formal = false; var beforeTerminal = false; var proofSaved = false
    try {
        let initialized = managedRecoveryInitialize(directory, parent, "caller-fixture")
        @Expect(initialized, true)
        if (!initialized) { throw Exception("owned_fixture_inventory_initialization_failed") }
        let result = action(home, parent)
        formal = result[0]; beforeTerminal = result[1]; proofSaved = true
    } finally {
        var stopped = false; var restored = true; var cleanupSaved = false
        try { stopped = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5) }
        catch (_: Exception) { @Expect(false, true) }
        finally {
            try {
                match (priorDirectory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value)
                    case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
            } catch (_: Exception) { restored = false; @Expect(false, true) }
            try {
                match (priorParent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value)
                    case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
            } catch (_: Exception) { restored = false; @Expect(false, true) }
        }
        try {
            File.writeTo(home.join("cleanup.json"), ("{\"ownedStopComplete\":${stopped},\"environmentRestored\":${restored},\"formalBeforeFallback\":${formal},\"sourceTerminalBeforeFallback\":${beforeTerminal},\"proofSaved\":${proofSaved}}").toArray())
            cleanupSaved = true
        } catch (_: Exception) { @Expect(false, true) }
        @Expect(stopped, true); @Expect(restored, true)
        if (formal && beforeTerminal && proofSaved && stopped && restored && cleanupSaved && exists(home)) {
            try { remove(home, recursive: true) } catch (_: Exception) { @Expect(false, true) }
        }
    }
}

@When[os == "macOS"]
@Test
public class SandboxOwnedResourceTest {
    @TestCase
    public func lN3FakeImageCaptureDrainsAndCloses(): Unit {
        ownedFixtureContext({ home, parent =>
            let directory = home.join("inventory")
            let executable = home.join("fake-sandbox")
            File.writeTo(executable, ("#!/usr/bin/env node\n" +
                "const mode=process.argv[2],image=process.argv[process.argv.length-1];process.stderr.write('错误😀'.repeat(65536));if(image==='invalid'){process.stdout.write(Buffer.from([255,0]));process.stderr.write(Buffer.from([255,0]));}else process.stdout.write('镜像😀');process.exitCode=image==='failed'?7:0;\n").toArray())
            chmod(executable.toString(), 0o700)
            let warm = imageExists(executable.toString(), "normal")
            @Expect(warm, true)
            var formal = warm
            let baseline = ownedFixtureFds()
            for (_ in 0..8) {
                let normal = imageExists(executable.toString(), "normal")
                @Expect(normal, true)
                let failed = imageExists(executable.toString(), "failed")
                @Expect(failed, false)
                let invalid = imageExists(executable.toString(), "invalid")
                @Expect(invalid, false)
                let pulled = pullImage(executable.toString(), "normal")
                @Expect(pulled, true)
                let pullFailed = pullImage(executable.toString(), "failed")
                @Expect(pullFailed, false)
                let pullInvalid = pullImage(executable.toString(), "invalid")
                @Expect(pullInvalid, false)
                let descriptors = ownedFixtureFds()
                @Expect(descriptors, baseline)
                formal = formal && normal && !failed && !invalid && pulled && !pullFailed && !pullInvalid && descriptors == baseline
            }
            let before = managedRecoveryProbeRecords(directory, parent, "caller-fixture", MonoTime.now() + Duration.second)
            @Expect(before.terminal, true)
            let proof = JsonObject()
            proof.put("formal", JsonBool(formal && before.terminal)); proof.put("recordedBeforeFallback", JsonBool(true))
            proof.put("sourceOk", JsonBool(before.ok)); proof.put("sourceTerminal", JsonBool(before.terminal)); proof.put("sourceStatus", JsonString(before.status))
            File.writeTo(home.join("source-before-fallback.txt"), before.original.toArray())
            File.writeTo(home.join("formal-before-fallback.json"), proof.toJsonString().toArray())
            (formal && before.terminal, before.ok && before.terminal)
        })
    }
}


// Direct caller tests. The fake is a standalone raw CLI, not a Docker daemon,
// Seatbelt execution, service-plugin, or a second process framework.
@When[os == "macOS"]
foreign {
    func getpgid(pid: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
}
private func scCheck(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("sandbox_caller_contract_failed") }
}
private func scText(path: Path): String {
    scCheck(FileInfo(path).isRegular() && FileInfo(path).size <= 1048576)
    try { String.fromUtf8(File.readFrom(path)) } catch (_: Exception) { throw Exception("sandbox_caller_invalid_fixture_encoding") }
}
private func scPublish(path: Path, text: String): Unit {
    let pending = Path(path.toString() + ".pending")
    File.writeTo(pending, text.toArray()); rename(pending, to: path, overwrite: true)
}
private func scObject(path: Path): JsonObject {
    try { JsonValue.fromStr(scText(path)).asObject() } catch (_: Exception) { throw Exception("sandbox_caller_invalid_fixture_json") }
}
private func scString(value: JsonObject, key: String): String { value.get(key).getOrThrow().asString().getValue() }
private func scInt(value: JsonObject, key: String): Int64 { value.get(key).getOrThrow().asInt().getValue() }
private func scArgs(value: JsonObject): Array<String> {
    let result = ArrayList<String>()
    for (arg in value.get("args").getOrThrow().asArray().getItems()) { result.add(arg.asString().getValue()) }
    result.toArray()
}
private func scSha(path: Path): String {
    let digest = SHA256(); let buffer = Array<Byte>(65536, repeat: 0)
    try (stream = File(path, OpenMode.Read)) {
        while (true) { let n = stream.read(buffer); if (n == 0) { break }; digest.write(buffer[0..n]) }
    }
    let digits = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    let result = StringBuilder()
    for (byte in digest.finish()) { result.append(digits[Int64(byte >> 4)]); result.append(digits[Int64(byte & 15)]) }
    result.toString()
}
@When[os == "macOS"]
private func scGroupGone(pid: Int64): Bool { unsafe { kill(-Int32(pid), 0) } != 0 && unsafe { __error().read() } == 3 }
private func scEnv(): HashMap<String, String> {
    let values = HashMap(getVariables())
    for (key in values.keys().toArray()) {
        let upper = key.toAsciiUpper()
        if (key.startsWith("METIS_PROCESS_RECOVERY_") || key.startsWith("SC_CALL_") || upper.contains("TOKEN") ||
            upper.contains("API_KEY") || upper.contains("ACCESS_KEY") || upper.contains("SECRET") || upper.contains("PASSWORD") ||
            upper.contains("CREDENTIAL") || upper.contains("PROXY") || upper.contains("AUTHORIZATION") ||
            ["ENV","BASH_ENV","NODE_OPTIONS","MRT_REPORT","METIS_EMBED_REPORT_DIAGNOSTIC","BUILD_SANDBOX","SEATBELT_PROFILE","SANDBOX_SET_UID_GID"].contains(key)) { values.remove(key) }
    }
    values
}
private func scPayload(nonce: String, ordinal: Int64, error: Bool): Array<Byte> {
    let result = ArrayList<Byte>(if (error) { [0xfeu8,0u8,0xffu8] } else { [0xffu8,0u8,0xfeu8] })
    result.add(all: ("SC-RAW-${ordinal}-${nonce}-" + if (error) { "错误😀\n" } else { "输出中文😀\n" }).toArray())
    result.add(all: String(Array<Rune>(16384, repeat: r'中')).toArray())
    result.add(all: [0u8,0xffu8,0xc3u8,0x28u8,0xf0u8,0x9fu8,0x98u8]); result.add(all: "😀SC-RAW-END\n".toArray()); result.toArray()
}
private func scRawSegment(path: Path, offset: Int64, expected: Array<Byte>): Unit {
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(8192, repeat: 0)
    try (stream = File(path, OpenMode.Read)) {
        let _ = stream.seek(SeekPosition.Begin(offset))
        while (true) {
            let n = stream.read(buffer); if (n == 0) { break }
            scCheck(bytes.size + n <= 1048576); bytes.add(all: buffer[0..n])
        }
    }
    scCheck(bytes.size >= expected.size)
    var count: Int64 = 0
    for (index in 0..(bytes.size - expected.size + 1)) {
        if (bytes[index] != expected[0]) { continue }
        var same = true
        for (j in 0..expected.size) { if (bytes[index+j] != expected[j]) { same = false; break } }
        if (same) { count++ }
    }
    scCheck(count == 1)
}
@When[os == "macOS"]
private class SandboxCallerFixture {
    let home = canonicalize(Path(getVariable("SC_CALL_HOME").getOrThrow()))
    let nonce = getVariable("SC_CALL_NONCE").getOrThrow()
    let bound = getVariable("SC_CALL_MODE") == Some("bound")
    let kind = getVariable("SC_CALL_KIND").getOrThrow()
    let scenario = getVariable("SC_CALL_SCENARIO").getOrThrow()
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let deadline = MonoTime.now() + Duration.second * 60
    let journal: Path
    let original = ArrayList<(String, Option<String>)>()
    let previousWorkspace = CliConfig.workspaceDirOverride
    let previousLog = Config.logFile
    var baseline: (Int64, Int64, Int64) = (0,0,0)
    var formal = false
    var auxiliaryJoined = true
    var calls: Int64 = 0
    init() {
        scCheck(home.toString().startsWith("/private/tmp/") && scText(home.join("owner")) == nonce)
        scCheck(getMaxHeapSize() == 67108864)
        scCheck(getVariable("HOME") == Some(home.toString()) && getVariable("TMPDIR") == Some(home.toString()) && getVariable("METIS_HOME") == Some(home.toString()))
        let binary = canonicalize(Path(getVariable("SC_CALL_ACTOR").getOrThrow()))
        scCheck(scSha(binary) == scText(home.parent.join("actor.sha")))
        for (name in ["METIS_PROCESS_RECOVERY_DIRECTORY","METIS_PROCESS_RECOVERY_PARENT","SC_CALL_DIR","SC_CALL_EXIT","SC_CALL_BEHAVIOR","SANDBOX_SET_UID_GID","BUILD_SANDBOX","SEATBELT_PROFILE"]) { original.add((name,getVariable(name))) }
        CliConfig.workspaceDirOverride = home.toString(); CliConfig.invalidatePathCache()
        scCheck(canonicalize(CliConfig.cwd) == home && canonicalize(CliConfig.dotDir) == home)
        Config.logFile = home.join("test.log").toString()
        for (name in ["business", "id"]) { copy(binary, to: home.join("bin/"+name)); scCheck(unsafe { chmod(home.join("bin/"+name).toString(),0o700) } == 0) }
        journal = home.join("inventory")
        if (bound) { scCheck(managedRecoveryInitialize(journal,parent,nonce)) }
        let boot = JsonObject(); boot.put("nonce",JsonString(nonce)); boot.put("pid",JsonInt(getProcessId()))
        boot.put("birth",JsonString(observeProcessBirthIdentity(getProcessId()).getOrThrow().serialize()))
        boot.put("parent",JsonString(parent)); boot.put("pgid",JsonInt(Int64(unsafe { getpgid(Int32(getProcessId())) })))
        scPublish(home.join("boot"),boot.toString())
        while (!exists(home.join("ack")) && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        scCheck(scText(home.join("ack")) == nonce)
    }
    func settled(): Bool {
        if (!auxiliaryJoined) { return false }
        if (bound) {
            let proof = managedRecoveryProbeRecords(journal,parent,nonce,MonoTime.now()+Duration.second)
            if (!proof.ok || !proof.terminal) { return false }
        }
        true
    }
    func stable(): Unit {
        let limit = min(deadline,MonoTime.now()+Duration.second*2)
        while ((ownedFixtureFds()!=baseline[0] || getThreadCount()>baseline[1] || getBlockingThreadCount()>baseline[2]) && MonoTime.now()<limit) { sleep(Duration.millisecond) }
        let observed=(ownedFixtureFds(),getThreadCount(),getBlockingThreadCount())
        let sourceTerminal=settled()
        scPublish(home.join("resource-checkpoint"),"fd:${observed[0]}\nfdBaseline:${baseline[0]}\ntasks:${observed[1]}\ntasksBaseline:${baseline[1]}\nblocking:${observed[2]}\nblockingBaseline:${baseline[2]}\nsourceTerminal:${sourceTerminal}\n")
        scCheck(observed[0]==baseline[0] && observed[1]<=baseline[1] && observed[2]<=baseline[2] && sourceTerminal)
    }
    func receipts(directory: Path, expected: Array<String>): Array<JsonObject> {
        let result = ArrayList<JsonObject>()
        let count = if (exists(directory.join("sequence"))) { Int64.parse(scText(directory.join("sequence"))) } else { 0 }
        scCheck(count == expected.size)
        for (i in 0..count) {
            let item = scObject(directory.join("call-${i+1}.json"))
            scCheck(scString(item,"nonce")==nonce && scString(item,"stage")==expected[i] && scInt(item,"ordinal")==i+1 && scString(item,"phase")=="complete")
            scCheck(scString(item,"cwd")==home.toString() && scString(item,"birth")==scString(item,"secondBirth"))
            let birth = parseProcessBirthIdentity(scString(item,"birth")).getOrThrow()
            scCheck(birth.pid==scInt(item,"pid"))
            let gone = probeProcessBirthIdentity(birth,MonoTime.now()+Duration.second)
            scCheck(gone.conclusive && !gone.alive)
            if (bound) { scCheck(scInt(item,"pgid")==birth.pid && scGroupGone(birth.pid)) }
            else { scCheck(scInt(item,"parentPid")==getProcessId() && scInt(item,"pgid")==Int64(unsafe { getpgid(Int32(getProcessId())) })) }
            result.add(item)
        }
        result.toArray()
    }
    func run(label: String, code: Int64, fault: String): Unit {
        scCheck(MonoTime.now()<deadline)
        let directory = home.join(label); Directory.create(directory)
        File.writeTo(directory.join("owner"),nonce.toArray())
        setVariable("SC_CALL_DIR",directory.toString()); setVariable("SC_CALL_EXIT",code.toString())
        setVariable("SC_CALL_BEHAVIOR",if (fault=="invalid_ps") { "invalid_ps" } else if (fault=="missing_image") { "missing_image" } else { "normal" })
        setVariable("SANDBOX_SET_UID_GID",if (fault=="uid") { "1" } else { "0" })
        removeVariable("BUILD_SANDBOX"); setVariable("SEATBELT_PROFILE","permissive-open")
        if (fault=="build_conflict") { setVariable("BUILD_SANDBOX","1") }
        if (fault=="invalid_profile") { setVariable("SEATBELT_PROFILE","owned-invalid-profile") }
        let config = SandboxConfig(home.join(if (fault=="missing_exec") { "bin/missing" } else { "bin/business" }).toString(),"owned-image")
        let arguments = ["owned-argument 中文😀", "quote'and\" NUL-free"]
        let output = home.join("stdout"); let error = home.join("stderr")
        let outputStart = FileInfo(output).size; let errorStart = FileInfo(error).size
        let expectRun = fault=="normal" || fault=="uid"
        let done = AtomicBool(false)
        auxiliaryJoined = false
        let worker = spawn {
            try {
                try {
                    let actual = if (kind=="container") { startContainerSandbox(config,arguments) } else { startMacOSSandbox(config,arguments) }
                    (actual,"none")
                } catch (error: FatalSandboxError) {
                    (-1i64,if (error.message=="sandbox_invalid_response_encoding") { "invalid_response_encoding" } else { "fatal_sandbox" })
                } catch (_: ProcessException) { (-1i64,"process_exception") }
                  catch (_: Exception) { (-1i64,"unexpected_exception") }
            } finally { done.store(true) }
        }
        var formalCase = false
        try {
            if (expectRun) {
                while (!exists(directory.join("ready")) && !done.load() && MonoTime.now()<deadline) { sleep(Duration.millisecond) }
                let ready = scObject(directory.join("ready")); scCheck(scString(ready,"nonce")==nonce)
                let birth = parseProcessBirthIdentity(scString(ready,"birth")).getOrThrow()
                scCheck(birth.pid==scInt(ready,"pid") && observeProcessBirthIdentity(birth.pid)?.serialize()==Some(birth.serialize()))
                scCheck(Int64(unsafe { getpgid(Int32(birth.pid)) })==scInt(ready,"pgid"))
                if (bound) {
                    scCheck(scInt(ready,"pgid")==birth.pid)
                    let ownerKeys = ArrayList<String>()
                    for (entry in Directory.readFrom(journal)) {
                        if (!entry.name.endsWith(".spawned")) { continue }
                        let fields = managedRecoveryParseFields(scText(entry.path)).getOrThrow()
                        if (fields.get("pid")==Some(birth.pid.toString())) { ownerKeys.add(fields.get("key").getOrThrow()) }
                    }
                    scCheck(ownerKeys.size==1)
                    let record = managedRecoveryParseFields(scText(journal.join(ownerKeys[0]+".birth"))).getOrThrow()
                    scCheck(record.get("birth")==Some(birth.serialize()) && record.get("parent")==Some(parent))
                } else { scCheck(scInt(ready,"parentPid")==getProcessId()) }
                scCheck(observeProcessBirthIdentity(birth.pid)?.serialize()==Some(birth.serialize()))
                scPublish(directory.join("release"),nonce)
            }
            scCheck(MonoTime.now()<deadline)
            let outcome = worker.get(deadline-MonoTime.now()); auxiliaryJoined = done.load(); scCheck(auxiliaryJoined)
            let expectedCategory = if (expectRun) { "none" } else if (fault=="missing_exec") { "process_exception" }
                else if (fault=="invalid_ps") { "invalid_response_encoding" } else { "fatal_sandbox" }
            scPublish(directory.join("actual"),"category:${outcome[1]}\ncode:${outcome[0]}\njoined:${auxiliaryJoined}\n")
            scCheck(outcome[1]==expectedCategory && outcome[0]==(if (expectRun) { code } else { -1 }))
            let expected: Array<String> = if (kind=="macos") { if (expectRun) { ["run"] } else { [] } }
                else if (fault=="missing_exec") { [] } else if (fault=="missing_image") { ["images","pull"] }
                else if (fault=="invalid_ps") { ["images","ps"] }
                else if (fault=="uid") { ["images","ps","id-u","id-g","run"] } else { ["images","ps","run"] }
            let observed = receipts(directory,expected)
            if (expectRun) {
                let last = observed[observed.size-1]; let args = scArgs(last)
                scCheck(scInt(last,"code")==code && scString(last,"command")==config.command)
                if (kind=="container") {
                    scCheck(args[0]=="run" && args.contains("--rm") && args.contains("--workdir") && args.contains("/workspace") && args.contains("--volume"))
                    scCheck(args.contains(home.toString()+":/workspace") && args.contains("--name") && args.contains("--hostname") && args.contains("owned-image"))
                    scCheck(args[args.size-3]=="bash" && args[args.size-2]=="-c")
                    scCheck(scArgs(observed[0])==["images","-q","owned-image"] && scArgs(observed[1])==["ps","-a","--format","{{.Names}}"])
                    if (fault=="uid") {
                        scCheck(scArgs(observed[2])==["-u"] && scArgs(observed[3])==["-g"] && args.contains("--user") && args.contains("root"))
                        let uid = [53u8,48u8,49u8,10u8].toString().trimAscii(); let gid = [50u8,48u8,10u8].toString().trimAscii()
                        scCheck(args[args.size-1].contains("groupadd -f -g ${gid}") && args[args.size-1].contains("useradd -o -u ${uid}"))
                    }
                } else {
                    scCheck(args[0]=="-D" && args[1]=="WORK_DIR=${home}" && args[2]=="-D" && args[3]=="TMP_DIR=/tmp")
                    scCheck(args[4]=="-f" && args[5]==home.join("sandbox-macos-permissive-open.sb").toString() && args[6]=="sh" && args[7]=="-c")
                    scCheck(scText(Path(args[5]))==SEATBELT_PROFILES.get("permissive-open").getOrThrow())
                }
                let command = "MAGIC_CLI_IN_SANDBOX=sandbox-exec magic-cli " + String.join(arguments |> map { arg => "'${arg}'" } |> collectArray, delimiter: " ")
                if (fault=="uid") { scCheck(args[args.size-1].contains("su -p magic-user -c '" + command.replace("'","'\\''") + "'")) }
                else { for (arg in arguments) { scCheck(args[args.size-1].contains("'${arg}'")) } }
                scRawSegment(output,outputStart,scPayload(nonce,observed.size,false)); scRawSegment(error,errorStart,scPayload(nonce,observed.size,true))
            }
            if (!label.startsWith("warm-")) { stable(); calls++ }
            formalCase = true
        } finally {
            // The formal snapshot precedes release/join/stop fallback.
            try { scPublish(directory.join("formal"),"formal:${formalCase}\njoined:${auxiliaryJoined}\n") }
            catch (_: Exception) { eprintln("sandbox_caller_proof_write_failed") }
            finally {
                if (!auxiliaryJoined) {
                    try { scPublish(directory.join("release"),nonce); let _ = worker.get(Duration.second*3); auxiliaryJoined=done.load() }
                    catch (_: Exception) { auxiliaryJoined=false }
                }
            }
        }
    }
    func finish(): Unit {
        var before = false
        try { before = settled() } catch (_: Exception) { eprintln("sandbox_caller_source_unknown") }
        try { scPublish(home.join("result"),"formal:${formal}\nsource:${before}\njoined:${auxiliaryJoined}\ncalls:${calls}\nparent:${parent}\n") }
        catch (_: Exception) { eprintln("sandbox_caller_proof_write_failed") }
        finally {
            var terminal = false
            try { terminal = if (bound) { managedRecoveryStopOwnedChildren((journal.toString(),parent),MonoTime.now()+Duration.second*3) } else { auxiliaryJoined } }
            catch (_: Exception) { eprintln("sandbox_caller_cleanup_pending") }
            if (terminal && auxiliaryJoined) {
                for ((key,value) in original) { match (value) { case Some(old) => setVariable(key,old) case None => removeVariable(key) } }
                CliConfig.workspaceDirOverride=previousWorkspace; CliConfig.invalidatePathCache(); Config.logFile=previousLog
            }
            // The parent retains failed input; only it owns the outer directory.
        }
    }
}
@When[os == "macOS"]
private func scChild(): Unit {
    let fixture = SandboxCallerFixture()
    try {
        for (i in 0..2) { fixture.run("warm-${i}",0,"normal") }
        fixture.baseline=(ownedFixtureFds(),getThreadCount(),getBlockingThreadCount())
        let scenario = fixture.scenario
        let repeated = scenario=="zero" || scenario=="seven" || scenario=="business127" || scenario=="uid" || scenario=="invalid_ps"
        let code = if (scenario=="seven") { 7 } else if (scenario=="business127") { 127 } else { 0 }
        let fault = if (scenario=="zero" || scenario=="seven" || scenario=="business127") { "normal" } else { scenario }
        for (i in 0..(if (repeated) { 32 } else { 1 })) { fixture.run("formal-${i}",code,fault) }
        scCheck(fixture.calls==(if (repeated) { 32 } else { 1 })); fixture.stable(); fixture.formal=true
    } finally { fixture.finish() }
}
@When[os == "macOS"]
private func scParent(method: String, kind: String, scenarios: Array<String>): Unit {
    let root = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrDefault({ => canonicalize(Path(".")).toString() })))
    let home = canonicalize(Directory.createTemp("/private/tmp")); let nonce=DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let baseline=(ownedFixtureFds(),getThreadCount(),getBlockingThreadCount())
    let handles=ArrayList<ManagedOwnedChild>(); let births=ArrayList<ProcessBirthIdentity>()
    var formal=false
    var pendingLaunch=false
    let aggregate=MonoTime.now()+Duration.second*(65+scenarios.size*2*65)
    println("R-SANDBOX fixture=${home.fileName};nonce=${nonce};kind=${kind}")
    try {
        scCheck(getMaxHeapSize()==67108864)
        let sdk=canonicalize(Path(getVariable("CANGJIE_HOME").getOrThrow()))
        @When[arch == "aarch64"]
        let platform="darwin_aarch64_llvm"
        @When[arch == "x86_64"]
        let platform="darwin_x86_64_llvm"
        @When[arch == "aarch64"]
        let stdx=canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow())).join("libs/cangjie-stdx-mac-aarch64-1.0.0.1/"+platform+"/dynamic/stdx")
        @When[arch == "x86_64"]
        let stdx=canonicalize(Path(getVariable("MAGIC_PATH").getOrThrow())).join("libs/cangjie-stdx-mac-x64-1.0.0.1/"+platform+"/dynamic/stdx")
        let runtime=sdk.join("runtime/lib/"+platform); let actor=home.join("actor")
        let source=root.join("test/fixtures/service_plugin/stdio_protocol/sandbox_process_fixture.cj")
        scCheck(FileInfo(source).isRegular()); File.writeTo(home.join("source.sha"),scSha(source).toArray())
        try (output=File(home.join("compiler.stdout"),OpenMode.ReadWrite),error=File(home.join("compiler.stderr"),OpenMode.ReadWrite)) {
            pendingLaunch=true
            let compiler=launchManagedRawChild(sdk.join("bin/cjc").toString(),[source.toString(),"--import-path",stdx.toString(),"-L",stdx.toString(),"-lstdx.encoding.json","--link-options","-rpath ${runtime} -rpath ${stdx}","-o",actor.toString()],
                workingDirectory:Some(root),environment:Some<Map<String,String>>(scEnv()),stdIn:ProcessRedirect.Discard,stdOut:ProcessRedirect.FromFile(output),stdErr:ProcessRedirect.FromFile(error),newGeneration:true)
            handles.add(compiler); pendingLaunch=false; births.add(observeProcessBirthIdentity(compiler.pid).getOrThrow())
            scCheck(compiler.wait(timeout:Some(Duration.second*60))==0); compiler.closeStreams()
            scCheck(compiler.wait()==0 && compiler.streamsAreClosed() && scGroupGone(compiler.pid))
        }
        scCheck(exists(actor)); File.writeTo(home.join("actor.sha"),scSha(actor).toArray())
        let node=managedStdioResolveNodeCommand(); scCheck(Path(node).isAbsolute() && FileInfo(node).isRegular())
        for (mode in ["absent","bound"]) {
            for (scenario in scenarios) {
                scCheck(MonoTime.now()<aggregate)
                let childHome=home.join(mode+"-"+scenario); Directory.create(childHome); Directory.create(childHome.join("bin"))
                File.writeTo(childHome.join("owner"),nonce.toArray())
                let environment=scEnv()
                for ((key,value) in [("HOME",childHome.toString()),("TMPDIR",childHome.toString()),("METIS_HOME",childHome.toString()),("SC_CALL_HOME",childHome.toString()),("SC_CALL_NONCE",nonce),("SC_CALL_ACTOR",actor.toString()),("SC_CALL_KIND",kind),("SC_CALL_SCENARIO",scenario),("SC_CALL_MODE",mode),("METIS_CJPM_ROOT",root.toString()),("METIS_STDIO_BROKER_SCRIPT",root.join("scripts/metis-stdio-broker.mjs").toString()),("METIS_STDIO_BROKER_NODE_COMMAND",node),("PATH",childHome.join("bin").toString())]) { environment[key]=value }
                try (input=File(childHome.join("stdin"),OpenMode.ReadWrite),output=File(childHome.join("stdout"),OpenMode.ReadWrite),error=File(childHome.join("stderr"),OpenMode.ReadWrite)) {
                    pendingLaunch=true
                    let child=launchManagedRawChild(getCommand(),["--filter=SandboxCallerResourceTest."+method,"--parallel=false","--no-capture-output","--no-progress","--no-color"],workingDirectory:Some(childHome),environment:Some<Map<String,String>>(environment),stdIn:ProcessRedirect.FromFile(input),stdOut:ProcessRedirect.FromFile(output),stdErr:ProcessRedirect.FromFile(error),newGeneration:true)
                    handles.add(child); pendingLaunch=false; let birth=observeProcessBirthIdentity(child.pid).getOrThrow(); births.add(birth)
                    let deadline=min(aggregate,MonoTime.now()+Duration.second*60)
                    while (!exists(childHome.join("boot")) && child.isAlive() && MonoTime.now()<deadline) { sleep(Duration.millisecond) }
                    let boot=scObject(childHome.join("boot")); scCheck(scString(boot,"nonce")==nonce && scInt(boot,"pid")==child.pid && scString(boot,"birth")==birth.serialize() && scInt(boot,"pgid")==child.pid)
                    scCheck(observeProcessBirthIdentity(child.pid)?.serialize()==Some(birth.serialize()))
                    scPublish(childHome.join("ack"),nonce); scCheck(MonoTime.now()<deadline)
                    scCheck(child.wait(timeout:Some(deadline-MonoTime.now()))==0); child.closeStreams()
                    scCheck(child.wait()==0 && !child.isAlive() && child.streamsAreClosed())
                    let limit=min(aggregate,MonoTime.now()+Duration.second*2)
                    while (!scGroupGone(child.pid) && MonoTime.now()<limit) { sleep(Duration.millisecond) }
                    scCheck(scGroupGone(child.pid))
                    let result=scText(childHome.join("result")); scCheck(result.contains("formal:true\n") && result.contains("source:true\n") && result.contains("joined:true\n"))
                    if (mode=="bound") { let state=managedRecoveryProbeRecords(childHome.join("inventory"),scString(boot,"parent"),nonce,MonoTime.now()+Duration.second); scCheck(state.ok && state.terminal) }
                }
            }
        }
        let limit=MonoTime.now()+Duration.second*2
        while ((ownedFixtureFds()!=baseline[0] || getThreadCount()>baseline[1] || getBlockingThreadCount()>baseline[2]) && MonoTime.now()<limit) { sleep(Duration.millisecond) }
        scCheck(ownedFixtureFds()==baseline[0] && getThreadCount()<=baseline[1] && getBlockingThreadCount()<=baseline[2])
        for (birth in births) { let gone=probeProcessBirthIdentity(birth,MonoTime.now()+Duration.second); scCheck(gone.conclusive && !gone.alive) }
        formal=true
    } finally {
        try { scPublish(home.join("parent-formal"),"formal:${formal}\nrecordedBeforeFallback:true\n") }
        catch (_: Exception) { eprintln("sandbox_caller_proof_write_failed") }
        finally {
            var terminal= !pendingLaunch
            for (child in handles) {
                try { if (child.isAlive()) { child.terminate() }; let _=child.wait(timeout:Some(Duration.second*3)); child.closeStreams(); terminal=terminal && child.streamsAreClosed() && scGroupGone(child.pid) }
                catch (_: Exception) { terminal=false }
            }
            // Retain all input/proof in this draft's actual future runs. Final
            // task cleanup is manifest-based, never inferred from empty lists.
            println("R-SANDBOX formal=${formal};returnedHandlesTerminal=${terminal};retained=true")
        }
    }
}
@When[os == "macOS"]
@Test
public class SandboxCallerResourceTest {
    @TestCase
    public func containerStartWaitAndCloseActualOwnedProcess(): Unit {
        if (getVariable("SC_CALL_KIND")==Some("container")) { scChild(); return }
        scParent("containerStartWaitAndCloseActualOwnedProcess","container",["zero","seven","business127","uid","invalid_ps","missing_image","missing_exec"])
    }
    @TestCase
    public func macosStartWaitAndCloseActualOwnedProcess(): Unit {
        if (getVariable("SC_CALL_KIND")==Some("macos")) { scChild(); return }
        scParent("macosStartWaitAndCloseActualOwnedProcess","macos",["zero","seven","business127","build_conflict","invalid_profile","missing_exec"])
    }
}
