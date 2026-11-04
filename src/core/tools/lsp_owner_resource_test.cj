package metis.core.tools

import metis.lsp.closeLspProcessRecoveryOwner
import metis.process.{managedRecoveryInitialize, managedRecoveryStopOwnedChildren, managedRecoveryContext,
    currentProcessInstanceIdentity, observeProcessBirthIdentity, managedRecoveryProbeRecords}
import metis.core.config.{CliConfig, CliSettingManager, MetisConfigManager}
import std.collection.ArrayList
import std.convert.Parsable
import std.env.{getVariable, setVariable, removeVariable, getProcessId}
import std.fs.{Directory, File, Path, exists, remove}
import std.posix.chmod
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import magic.config.Config
import metis.process.{ManagedOwnedChild, ProcessBirthIdentity, ProcessFileClaim, acquireProcessFileClaim,
    launchManagedRawChild, managedStdioResolveNodeCommand, managedRecoveryReadText,
    managedRecoveryParseFields, parseProcessBirthIdentity}
import std.collection.{HashMap, Map}
import std.env.{getCommand, getVariables}
import std.fs.{OpenMode, canonicalize, rename}
import std.process.ProcessRedirect
import std.runtime.{getMaxHeapSize, getThreadCount, getBlockingThreadCount}
import stdx.encoding.json.*

@When[os == "macOS"]
foreign { func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, bufferSize: Int32): Int32 }

@When[os == "macOS"]
private func lspOwnerFixtureFds(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("lsp_owner_fixture_fd_unknown") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func lspOwnerReuseRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("lsp_owner_fixture_contract_failed") }
}

@When[os == "macOS"]
@Test
public class LSPRecoveryOwnerResourceTest {
    @TestCase
    public func lLspOwnerPendingInitializationRetriesAfterRealClaimConflict(): Unit {
        if (getVariable("METIS_LSP_PENDING_CHILD") == Some("1")) {
            let fixture = LspPendingChildFixture()
            try { fixture.run(); fixture.formal = true }
            finally { fixture.finish() }
            return
        }
        lspPendingParent()
    }

    @TestCase
    public func lLspOwnerReuseForeignBorrowAndExactShutdown(): Unit {
        let home = Path("/private/tmp/metis-lsp-owner-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let names = ["METIS_HOME", "PATH", "METIS_FAKE_LSP_READY", "METIS_FAKE_LSP_STARTS",
            "METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT"]
        let previous = ArrayList<?String>()
        for (name in names) { previous.add(getVariable(name)) }
        let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        let directory = home.join("owned")
        Directory.create(home)
        let executable = home.join("LSPServer")
        var formal = false
        var firstError = None<Exception>
        try {
            File.writeTo(executable, ("#!/usr/bin/env node\n" + "const fs=require('fs');fs.writeFileSync(process.env.METIS_FAKE_LSP_READY,String(process.pid));fs.appendFileSync(process.env.METIS_FAKE_LSP_STARTS,'1');let p=Buffer.alloc(0);process.stdin.on('data',b=>{p=Buffer.concat([p,b]);for(;;){const at=p.indexOf('\\r\\n\\r\\n');if(at<0)return;const n=Number(/Content-Length: ([0-9]+)/.exec(p.subarray(0,at).toString())[1]);if(p.length<at+4+n)return;const q=JSON.parse(p.subarray(at+4,at+4+n).toString());p=p.subarray(at+4+n);if(q.method==='exit')process.exit(0);if(q.id===undefined)continue;const result=q.method==='initialize'?{capabilities:{semanticTokensProvider:{legend:{tokenTypes:['variable','中文😀'],tokenModifiers:[]},full:{delta:false},range:false},hoverProvider:false,documentSymbolProvider:false}}:{};const text=JSON.stringify({jsonrpc:'2.0',id:q.id,result});process.stdout.write('Content-Length: '+Buffer.byteLength(text)+'\\r\\n\\r\\n'+text);}});process.stderr.write('诊断😀'.repeat(16384));" + "\n").toArray())
            chmod(executable.toString(), 0o700)
            let ready = home.join("ready"); let starts = home.join("starts")
            setVariable("METIS_HOME", home.toString())
            setVariable("PATH", home.toString() + ":" + getVariable("PATH").getOrDefault({ => "/usr/bin:/bin" }))
            setVariable("METIS_FAKE_LSP_READY", ready.toString()); setVariable("METIS_FAKE_LSP_STARTS", starts.toString())
            CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
            lspOwnerReuseRequire(managedRecoveryInitialize(directory, parent, "lsp-owner"))
            let context = managedRecoveryContext()
            lspOwnerReuseRequire(!LSPToolset.debugRecoveryOwnerForTest()[1])
            lspOwnerReuseRequire(LSPToolset.initialize())
            lspOwnerReuseRequire(closeLspProcessRecoveryOwner(context))
            let baseline = lspOwnerFixtureFds()
            remove(starts)
            lspOwnerReuseRequire(LSPToolset.initialize())
            lspOwnerReuseRequire(LSPToolset.initialize())
            let text = try { String.fromUtf8(File.readFrom(ready)) } catch (_: Exception) { throw Exception("lsp_owner_fixture_invalid_encoding") }
            let birth = observeProcessBirthIdentity(Int64.parse(text)).getOrThrow()
            let actualStarts = File.readFrom(starts)
            @Expect(actualStarts, [49u8])
            lspOwnerReuseRequire(actualStarts.size == 1 && actualStarts[0] == 49u8)
            lspOwnerReuseRequire(LSPToolset.debugRecoveryOwnerForTest() == (context, true))
            lspOwnerReuseRequire(closeLspProcessRecoveryOwner(("", "")))
            lspOwnerReuseRequire(closeLspProcessRecoveryOwner((directory.toString() + "-foreign", parent)))
            lspOwnerReuseRequire(observeProcessBirthIdentity(birth.pid)?.serialize() == Some(birth.serialize()))
            lspOwnerReuseRequire(LSPToolset.debugRecoveryOwnerForTest() == (context, true))
            lspOwnerReuseRequire(closeLspProcessRecoveryOwner(context))
            lspOwnerReuseRequire(observeProcessBirthIdentity(birth.pid).isNone())
            lspOwnerReuseRequire(LSPToolset.debugRecoveryOwnerForTest() == (("", ""), false))
            lspOwnerReuseRequire(lspOwnerFixtureFds() == baseline)
            let source = managedRecoveryProbeRecords(directory, parent, "lsp-owner", MonoTime.now() + Duration.second)
            lspOwnerReuseRequire(source.ok && source.terminal)
            formal = true
        } catch (error: Exception) { firstError = Some(error) }
        finally {
            var proofSaved = false
            var lspStopped = false
            var terminal = false
            var restored = true
            try {
                File.writeTo(home.join("formal-before-fallback"),
                    "formal:${formal};bodyFailed:${firstError.isSome()}\n".toArray())
                proofSaved = true
            } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try {
                    lspStopped = closeLspProcessRecoveryOwner((directory.toString(), parent))
                    if (!lspStopped) { throw Exception("lsp_owner_fixture_cleanup_pending") }
                } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                finally {
                    try {
                        terminal = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5)
                        if (!terminal) { throw Exception("lsp_owner_fixture_cleanup_pending") }
                    } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                    finally {
                        for (index in 0..names.size) {
                            try { match (previous[index]) { case Some(value) => setVariable(names[index], value) case None => removeVariable(names[index]) } }
                            catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                        }
                        try { CliConfig.invalidatePathCache() } catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                        try { MetisConfigManager.invalidate() } catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                        try { CliSettingManager.invalidate() } catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                    }
                }
            }
            if (formal && proofSaved && lspStopped && terminal && restored && firstError.isNone()) { remove(home, recursive: true) }
        }
        if (let Some(error) <- firstError) { throw error }
    }
}


// All additions below belong only to L-LSP-OWNER-PENDING. No production factory is replaced.
@When[os == "macOS"]
foreign {
    func getpgid(pid: Int32): Int32
    func kill(pid: Int32, signal: Int32): Int32
    func __error(): CPointer<Int32>
}

private func lspPendingRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("lsp_pending_owner_contract_failed") }
}

private func lspPendingText(path: Path): String {
    try { String.fromUtf8(File.readFrom(path)) }
    catch (_: Exception) { throw Exception("lsp_pending_fixture_invalid_encoding") }
}

private func lspPendingJson(path: Path): JsonObject {
    try { JsonValue.fromStr(lspPendingText(path)).asObject() }
    catch (_: Exception) { throw Exception("lsp_pending_fixture_malformed_json") }
}

private func lspPendingAtomic(path: Path, bytes: Array<Byte>): Unit {
    let temporary = path.parent.join(path.fileName + ".tmp")
    File.writeTo(temporary, bytes)
    rename(temporary, to: path)
}

private func lspPendingWait(test: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.second * 5
    while (MonoTime.now() < deadline) {
        if (test()) { return true }
        sleep(Duration.millisecond * 5)
    }
    test()
}

@When[os == "macOS"]
private func lspPendingGroupGone(pid: Int64): Bool {
    if (unsafe { kill(Int32(-pid), 0) } == 0) { return false }
    unsafe { __error().read() } == 3
}

// The actor emits only Content-Length frames to stdout. Control records use atomic owned files.
private func lspPendingServer(node: String): String {
    "#!" + node + "\n" + #"
'use strict';
const fs=require('fs'), path=require('path');
const run=process.env.METIS_LSP_PENDING_RUN, nonce=process.env.METIS_LSP_PENDING_NONCE;
const inventory=process.env.METIS_PROCESS_RECOVERY_DIRECTORY, parent=process.env.METIS_PROCESS_RECOVERY_PARENT;
const key=process.env.METIS_PROCESS_RECOVERY_BROKER_KEY;
if(!run || !nonce || !inventory || !parent || !/^r-[1-9][0-9]*$/.test(key||'')) process.exit(64);
const atomic=(name,text)=>{const p=path.join(run,name);fs.writeFileSync(p+'.tmp',text,{flag:'wx',mode:0o600});fs.renameSync(p+'.tmp',p);};
atomic('started',String(process.pid));
const frame=(q,value,error=false)=>{const body=JSON.stringify({jsonrpc:'2.0',id:q.id,[error?'error':'result']:value});process.stdout.write('Content-Length: '+Buffer.byteLength(body)+'\r\n\r\n'+body);};
const initialize=q=>{
 const helper=fs.readFileSync(path.join(inventory,key+'.birth'),'utf8');
 const owner=fs.readFileSync(path.join(inventory,key+'-o-1.birth'),'utf8');
 atomic('initialize-received.json',JSON.stringify({nonce,pid:process.pid,key,parent,helper,owner}));
 if(path.basename(run)==='error'){
  const timer=setInterval(()=>{if(fs.existsSync(path.join(run,'release-error'))){clearInterval(timer);frame(q,{code:-32001,message:'受控初始化失败😀'},true);}},5);
 }else frame(q,{capabilities:{semanticTokensProvider:{legend:{tokenTypes:['variable','中文😀'],tokenModifiers:[]},full:{delta:false},range:false},hoverProvider:false,documentSymbolProvider:false}});
};
let pending=Buffer.alloc(0);
process.stdin.on('data',bytes=>{pending=Buffer.concat([pending,bytes]);for(;;){
 const at=pending.indexOf('\r\n\r\n');if(at<0)return;
 const header=pending.subarray(0,at).toString('ascii'), match=/^Content-Length: ([0-9]+)\r?$/m.exec(header);
 if(!match)process.exit(65);const size=Number(match[1]);if(!Number.isSafeInteger(size)||size<0||size>1048576)process.exit(65);
 if(pending.length<at+4+size)return;
 const request=JSON.parse(pending.subarray(at+4,at+4+size).toString('utf8'));pending=pending.subarray(at+4+size);
 if(request.method==='exit')process.exit(0);
 if(request.id===undefined)continue;
 if(request.method==='initialize')initialize(request);else frame(request,{});
}});
process.stdin.on('end',()=>process.exit(0));
process.stderr.write('诊断中文😀'.repeat(16384));
"#
}

@When[os == "macOS"]
private class LspPendingChildFixture {
    let home = canonicalize(Path(getVariable("METIS_LSP_PENDING_HOME").getOrThrow()))
    let nonce = getVariable("METIS_LSP_PENDING_NONCE").getOrThrow()
    let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
    let deadline = MonoTime.now() + Duration.second * 60
    let names = ["METIS_HOME", "PATH", "METIS_LSP_PENDING_RUN", "METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT"]
    let previous = ArrayList<?String>()
    let oldWorkspace = CliConfig.workspaceDirOverride
    let oldLog = Config.logFile
    let births = ArrayList<ProcessBirthIdentity>()
    let workers = ArrayList<Future<Bool>>()
    let joined = ArrayList<Bool>()
    var claim = None<ProcessFileClaim>
    var warmFd: Int64 = 0
    var warmTasks: Int64 = 0
    var warmBlocking: Int64 = 0
    var formal = false
    var phase = "created"

    init() {
        lspPendingRequire(home.toString().startsWith("/private/tmp/") && !nonce.isEmpty())
        lspPendingRequire(lspPendingText(home.join("owner")) == "lsp-pending-owner-v1\n" + nonce)
        lspPendingRequire(getMaxHeapSize() == 67108864 && managedRecoveryContext() == ("", ""))
        lspPendingRequire(lspPendingWait({ => exists(home.join("expected-writer")) }))
        let expected = lspPendingJson(home.join("expected-writer"))
        lspPendingRequire(expected.getFields().size == 3 && expected.get("nonce").getOrThrow().asString().getValue() == nonce &&
            expected.get("pid").getOrThrow().asInt().getValue() == getProcessId() &&
            observeProcessBirthIdentity(getProcessId())?.serialize() == Some(expected.get("birth").getOrThrow().asString().getValue()))
        lspPendingRequire(unsafe { getpgid(Int32(getProcessId())) } == Int32(getProcessId()))
        for (name in names) { previous.add(getVariable(name)) }
        setVariable("METIS_HOME", home.toString()); setVariable("PATH", home.join("bin").toString())
        CliConfig.workspaceDirOverride = home.toString(); Config.logFile = home.join("diagnostic.log").toString()
        CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
        File.writeTo(home.join("parent-identity"), parent.toArray())
        lspPendingRequire(managedRecoveryInitialize(home.join("A"), parent, nonce + "-A"))
        lspPendingRequire(managedRecoveryInitialize(home.join("B"), parent, nonce + "-B"))
        useA()
    }

    func contextA(): (String, String) { (home.join("A").toString(), parent) }
    func contextB(): (String, String) { (home.join("B").toString(), parent) }
    func useA(): Unit {
        setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", home.join("A").toString())
        setVariable("METIS_PROCESS_RECOVERY_PARENT", parent)
    }
    func prepare(name: String): Path {
        let run = home.join("runs").join(name); Directory.create(run)
        setVariable("METIS_LSP_PENDING_RUN", run.toString()); run
    }
    func startCount(): Int64 {
        var count: Int64 = 0
        for (entry in Directory.readFrom(home.join("runs"))) { if (exists(entry.path.join("started"))) { count += 1 } }
        count
    }
    func issued(directory: Path): Int64 {
        let path = directory.join(".issued")
        if (!exists(path)) { return 0 }
        let value = managedRecoveryParseFields(managedRecoveryReadText(path).getOrThrow()).getOrThrow()
        let number = Int64.parse(value["issued"])
        lspPendingRequire(value.size == 2 && value["parent"] == parent && number > 0 && value["issued"] == number.toString())
        number
    }
    func validateServer(run: Path): Unit {
        let record = lspPendingJson(run.join("initialize-received.json"))
        lspPendingRequire(record.getFields().size == 6 && record.get("nonce").getOrThrow().asString().getValue() == nonce &&
            record.get("parent").getOrThrow().asString().getValue() == parent)
        let pid = record.get("pid").getOrThrow().asInt().getValue()
        lspPendingRequire(lspPendingText(run.join("started")) == pid.toString())
        let key = record.get("key").getOrThrow().asString().getValue()
        lspPendingRequire(key == "r-" + issued(home.join("A")).toString())
        for ((field, sourceKey, sourcePgid) in [("helper", key, Int64(0)), ("owner", key + "-o-1", pid)]) {
            let raw = record.get(field).getOrThrow().asString().getValue()
            let fields = managedRecoveryParseFields(raw).getOrThrow()
            let birth = parseProcessBirthIdentity(fields["birth"]).getOrThrow()
            lspPendingRequire(fields.size == 6 && fields["phase"] == "birth" && fields["key"] == sourceKey &&
                fields["parent"] == parent && fields["pid"] == birth.pid.toString() && fields["pgid"] == sourcePgid.toString())
            lspPendingRequire(raw == "managed-recovery-v1\nkey:${sourceKey}\nphase:birth\nparent:${parent}\npid:${birth.pid}\npgid:${sourcePgid}\nbirth:${birth.serialize()}\n")
            lspPendingRequire(raw == managedRecoveryReadText(home.join("A").join(sourceKey + ".birth")).getOrThrow())
            lspPendingRequire(observeProcessBirthIdentity(birth.pid)?.serialize() == Some(birth.serialize()))
            if (field == "owner") { lspPendingRequire(birth.pid == pid && unsafe { getpgid(Int32(pid)) } == Int32(pid)) }
            lspPendingRequire(observeProcessBirthIdentity(birth.pid)?.serialize() == Some(birth.serialize()))
            births.add(birth)
        }
    }
    func sourcesTerminal(until!: MonoTime = MonoTime.now() + Duration.second * 2): Bool {
        for (name in ["A", "B"]) {
            let result = managedRecoveryProbeRecords(home.join(name), parent, nonce + "-" + name, until)
            if (!result.ok || !result.terminal) { return false }
        }
        for (birth in births) { if (observeProcessBirthIdentity(birth.pid).isSome()) { return false } }
        true
    }
    func checkpoint(): Unit {
        let deadline = MonoTime.now() + Duration.second * 2
        var settled = false
        while (MonoTime.now() < deadline) {
            if (sourcesTerminal(until: deadline) && lspOwnerFixtureFds() == warmFd && getThreadCount() <= warmTasks &&
                getBlockingThreadCount() <= warmBlocking) { settled = true; break }
            sleep(Duration.millisecond * 5)
        }
        let value = JsonObject(); value.put("settled", JsonBool(settled)); value.put("fd", JsonInt(lspOwnerFixtureFds()))
        value.put("warmFd", JsonInt(warmFd)); value.put("tasks", JsonInt(getThreadCount())); value.put("warmTasks", JsonInt(warmTasks))
        value.put("blocking", JsonInt(getBlockingThreadCount())); value.put("warmBlocking", JsonInt(warmBlocking))
        File.writeTo(home.join("resource-checkpoint.json"), value.toJsonString().toArray())
        lspPendingRequire(settled)
    }
    func run(): Unit {
        for (index in 0..2) {
            phase = "warm-${index}"
            let run = prepare(phase)
            lspPendingRequire(LSPToolset.initialize()); validateServer(run)
            lspPendingRequire(closeLspProcessRecoveryOwner(contextA()))
            lspPendingRequire(LSPToolset.debugRecoveryOwnerForTest() == (("", ""), false) && sourcesTerminal())
        }
        warmFd = lspOwnerFixtureFds(); warmTasks = getThreadCount(); warmBlocking = getBlockingThreadCount()
        lspPendingRequire(startCount() == 2 && issued(home.join("A")) == 2 && issued(home.join("B")) == 0)
        phase = "error"
        let errorRun = prepare("error")
        let worker = spawn { LSPToolset.initialize() }; workers.add(worker); joined.add(false)
        lspPendingRequire(lspPendingWait({ => exists(errorRun.join("initialize-received.json")) }))
        validateServer(errorRun)
        let held = acquireProcessFileClaim(home.join("A/.resource-claim"), MonoTime.now() + Duration.second)
        claim = Some(held); lspPendingRequire(held.ok)
        lspPendingAtomic(errorRun.join("release-error"), "release".toArray())
        let initializeRemaining = deadline - MonoTime.now()
        lspPendingRequire(initializeRemaining > Duration.Zero)
        let initialized = worker.get(initializeRemaining); joined[0] = true
        lspPendingRequire(!initialized && LSPToolset.debugRecoveryOwnerForTest() == (contextA(), true))
        lspPendingRequire(startCount() == 3 && issued(home.join("A")) == 3)
        phase = "foreign-refusal"
        lspPendingRequire(closeLspProcessRecoveryOwner(("", "")))
        lspPendingRequire(closeLspProcessRecoveryOwner(contextB()))
        lspPendingRequire(LSPToolset.debugRecoveryOwnerForTest() == (contextA(), true))
        setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", home.join("B").toString())
        lspPendingRequire(!LSPToolset.initialize())
        lspPendingRequire(LSPToolset.debugRecoveryOwnerForTest() == (contextA(), true) && startCount() == 3 && issued(home.join("B")) == 0)
        useA(); phase = "held-same-context-refusal"
        let retry = spawn { LSPToolset.initialize() }; workers.add(retry); joined.add(false)
        let retryRemaining = deadline - MonoTime.now()
        lspPendingRequire(retryRemaining > Duration.Zero)
        let retried = retry.get(retryRemaining); joined[1] = true
        lspPendingRequire(!retried && LSPToolset.debugRecoveryOwnerForTest() == (contextA(), true))
        lspPendingRequire(startCount() == 3 && issued(home.join("A")) == 3 && issued(home.join("B")) == 0)
        held.release(); claim = None<ProcessFileClaim>; phase = "exact-close-retry"
        lspPendingRequire(closeLspProcessRecoveryOwner(contextA()))
        lspPendingRequire(LSPToolset.debugRecoveryOwnerForTest() == (("", ""), false))
        lspPendingRequire(closeLspProcessRecoveryOwner(contextA()) && sourcesTerminal())
        checkpoint()
        phase = "normal-after-recovery"
        let normal = prepare("normal-after-recovery")
        lspPendingRequire(LSPToolset.initialize()); validateServer(normal)
        lspPendingRequire(closeLspProcessRecoveryOwner(contextA()))
        lspPendingRequire(LSPToolset.debugRecoveryOwnerForTest() == (("", ""), false))
        lspPendingRequire(startCount() == 4 && issued(home.join("A")) == 4 && issued(home.join("B")) == 0)
        checkpoint(); phase = "complete"
    }
    func finish(): Unit {
        var proofSaved = false
        var before = false
        var terminal = false
        var cleanupSaved = false
        try {
            try {
                var workersJoined = true
                for (value in joined) { workersJoined = workersJoined && value }
                before = sourcesTerminal()
                let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("phase", JsonString(phase))
                proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("sourceTerminalBeforeFallback", JsonBool(before))
                proof.put("workersJoined", JsonBool(workersJoined)); proof.put("starts", JsonInt(startCount()))
                proof.put("heapBytes", JsonInt(getMaxHeapSize())); proof.put("pending", JsonBool(LSPToolset.debugRecoveryOwnerForTest()[1]))
                File.writeTo(home.join("child-formal-before-fallback.json"), proof.toJsonString().toArray())
                proofSaved = true
            } catch (_: Exception) {
                @Expect(false, true)
                try { eprintln("lsp_pending_child_formal_proof_failed") } catch (_: Exception) { () }
            }
        } finally {
            // One cleanup deadline. The synchronous production close API cannot be interrupted by it.
            let cleanupDeadline = MonoTime.now() + Duration.second * 3
            var released = true
            try {
                if (let Some(held) <- claim) { held.release(); claim = None<ProcessFileClaim> }
            } catch (_: Exception) { released = false; @Expect(false, true) }
            finally {
                for (index in 0..workers.size) {
                    if (!joined[index]) {
                        let remaining = cleanupDeadline - MonoTime.now()
                        if (remaining > Duration.Zero) {
                            try { let _ = workers[index].get(remaining); joined[index] = true }
                            catch (_: Exception) { @Expect(false, true) }
                        }
                    }
                }
                var lspClosed = false
                if (MonoTime.now() < cleanupDeadline) {
                    try { lspClosed = closeLspProcessRecoveryOwner(contextA()) }
                    catch (_: Exception) { @Expect(false, true) }
                }
                // Pass the same absolute deadline even when an earlier synchronous close consumed it.
                var a = false; var b = false
                try { a = managedRecoveryStopOwnedChildren(contextA(), cleanupDeadline) }
                catch (_: Exception) { @Expect(false, true) }
                finally {
                    try { b = managedRecoveryStopOwnedChildren(contextB(), cleanupDeadline) }
                    catch (_: Exception) { @Expect(false, true) }
                }
                var allJoined = true
                for (value in joined) { allJoined = allJoined && value }
                try {
                    terminal = released && lspClosed && a && b && allJoined && MonoTime.now() < cleanupDeadline &&
                        !LSPToolset.debugRecoveryOwnerForTest()[1] && sourcesTerminal(until: cleanupDeadline) && MonoTime.now() <= cleanupDeadline
                } catch (_: Exception) { terminal = false; @Expect(false, true) }
                try {
                    File.writeTo(home.join("child-cleanup.json"),
                        ("{\"terminal\":${terminal},\"workersJoined\":${allJoined},\"proofSaved\":${proofSaved},\"formal\":${formal && before && proofSaved}}").toArray())
                    cleanupSaved = true
                } catch (_: Exception) {
                    @Expect(false, true)
                    try { eprintln("lsp_pending_child_cleanup_proof_failed") } catch (_: Exception) { () }
                } finally {
                    if (terminal) {
                        try {
                            for (index in 0..names.size) { match (previous[index]) { case Some(value) => setVariable(names[index], value) case None => removeVariable(names[index]) } }
                            CliConfig.workspaceDirOverride = oldWorkspace; Config.logFile = oldLog
                            CliConfig.invalidatePathCache(); MetisConfigManager.invalidate(); CliSettingManager.invalidate()
                        } catch (_: Exception) { @Expect(false, true); try { eprintln("lsp_pending_child_restore_failed") } catch (_: Exception) { () } }
                    }
                }
                // Non-throwing expectations preserve an original body exception and still fail a successful body.
                @Expect(terminal, true)
                @Expect(proofSaved, true)
                @Expect(cleanupSaved, true)
            }
        }
    }
}

@When[os == "macOS"]
private func lspPendingParent(): Unit {
    lspPendingRequire(getMaxHeapSize() == 67108864)
    let node = managedStdioResolveNodeCommand()
    lspPendingRequire(Path(node).isAbsolute() && exists(Path(node)))
    let home = canonicalize(Directory.createTemp("/private/tmp"))
    let nonce = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let initialFd = lspOwnerFixtureFds(); let initialTasks = getThreadCount(); let initialBlocking = getBlockingThreadCount()
    var child = None<ManagedOwnedChild>; var birth = None<ProcessBirthIdentity>; var formal = false; var driverTerminal = false
    File.writeTo(home.join("owner"), ("lsp-pending-owner-v1\n" + nonce).toArray())
    println("L-LSP-OWNER-PENDING fixture=${home.fileName};nonce=${nonce}")
    try {
        Directory.create(home.join("bin")); Directory.create(home.join("runs"))
        File.writeTo(home.join("cjpm.toml"), "[package]\nname = \"owned_lsp_fixture\"\nversion = \"1.0.0\"\n".toArray())
        File.writeTo(home.join("bin/LSPServer"), lspPendingServer(node).toArray())
        lspPendingRequire(chmod(home.join("bin/LSPServer").toString(), 0o700) == 0)
        let env = HashMap<String, String>()
        for ((name, value) in getVariables()) {
            if (["PATH", "LANG", "CANGJIE_HOME", "MAGIC_PATH", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "SDKROOT", "cjHeapSize"].contains(name)) { env[name] = value }
        }
        env["HOME"] = home.toString(); env["TMPDIR"] = home.toString(); env["METIS_HOME"] = home.toString()
        env["METIS_LSP_PENDING_CHILD"] = "1"; env["METIS_LSP_PENDING_HOME"] = home.toString(); env["METIS_LSP_PENDING_NONCE"] = nonce
        env["METIS_STDIO_BROKER_NODE_COMMAND"] = node
        let project = canonicalize(Path(getVariable("METIS_CJPM_ROOT").getOrThrow()))
        env["METIS_CJPM_ROOT"] = project.toString()
        let inputs = home.join("source-inputs"); Directory.create(inputs)
        for (relative in ["src/core/tools/lsp_toolset.cj", "src/core/tools/lsp_owner_resource_test.cj", "src/lsp/json_rpc_client.cj",
            "src/lsp/lsp_client.cj", "src/lsp/lsp_process_recovery_owner.cj", "src/process/managed_owned_child.cj",
            "src/process/managed_process_recovery_roots.cj", "scripts/metis-stdio-broker.mjs"]) {
            File.writeTo(inputs.join(Path(relative).fileName), File.readFrom(project.join(relative)))
        }
        File.writeTo(home.join("stdin"), [])
        try (input = File(home.join("stdin"), OpenMode.Read), output = File(home.join("stdout"), OpenMode.Write), error = File(home.join("stderr"), OpenMode.Write)) {
            let launched = launchManagedRawChild(getCommand(), ["--filter=LSPRecoveryOwnerResourceTest.lLspOwnerPendingInitializationRetriesAfterRealClaimConflict",
                "--parallel=false", "--no-progress", "--no-color", "--no-capture-output"], newGeneration: true,
                workingDirectory: Some(home), environment: Some<Map<String, String>>(env),
                stdIn: ProcessRedirect.FromFile(input), stdOut: ProcessRedirect.FromFile(output), stdErr: ProcessRedirect.FromFile(error))
            child = Some(launched); birth = observeProcessBirthIdentity(launched.pid)
            lspPendingRequire(birth.isSome() && unsafe { getpgid(Int32(launched.pid)) } == Int32(launched.pid))
            let expected = JsonObject(); expected.put("nonce", JsonString(nonce)); expected.put("pid", JsonInt(launched.pid))
            expected.put("birth", JsonString(birth.getOrThrow().serialize()))
            lspPendingAtomic(home.join("expected-writer"), expected.toJsonString().toArray())
            let code = launched.wait(timeout: Some(Duration.second * 60)); launched.closeStreams()
            driverTerminal = code == 0 && launched.wait() == 0 && !launched.isAlive() && launched.streamsAreClosed() &&
                observeProcessBirthIdentity(launched.pid).isNone() && lspPendingGroupGone(launched.pid)
            lspPendingRequire(driverTerminal && !input.isClosed() && !output.isClosed() && !error.isClosed())
        }
        let proof = lspPendingJson(home.join("child-formal-before-fallback.json"))
        let cleanup = lspPendingJson(home.join("child-cleanup.json"))
        lspPendingRequire(proof.get("formal").getOrThrow().asBool().getValue() && proof.get("sourceTerminalBeforeFallback").getOrThrow().asBool().getValue() &&
            proof.get("recordedBeforeFallback").getOrThrow().asBool().getValue() && proof.get("workersJoined").getOrThrow().asBool().getValue() &&
            proof.get("starts").getOrThrow().asInt().getValue() == 4 && !proof.get("pending").getOrThrow().asBool().getValue() &&
            proof.get("heapBytes").getOrThrow().asInt().getValue() == 67108864 && cleanup.get("terminal").getOrThrow().asBool().getValue())
        let identity = lspPendingText(home.join("parent-identity"))
        let resourceDeadline = MonoTime.now() + Duration.second * 2
        for (name in ["A", "B"]) {
            let source = managedRecoveryProbeRecords(home.join(name), identity, nonce + "-" + name, resourceDeadline)
            File.writeTo(home.join("parent-source-" + name), source.original.toArray())
            lspPendingRequire(source.ok && source.terminal)
        }
        var resourcesSettled = false
        while (MonoTime.now() < resourceDeadline) {
            if (lspOwnerFixtureFds() == initialFd && getThreadCount() <= initialTasks && getBlockingThreadCount() <= initialBlocking) { resourcesSettled = true; break }
            sleep(Duration.millisecond * 5)
        }
        lspPendingRequire(resourcesSettled)
        formal = true
    } finally {
        var proofSaved = false
        var cleanupSaved = false
        var terminal = false
        try {
            try {
                File.writeTo(home.join("parent-formal-before-fallback.json"),
                    ("{\"formal\":${formal},\"driverTerminalBeforeFallback\":${driverTerminal},\"recordedBeforeFallback\":true}").toArray())
                proofSaved = true
            } catch (_: Exception) {
                @Expect(false, true)
                try { eprintln("lsp_pending_parent_formal_proof_failed") } catch (_: Exception) { () }
            }
        } finally {
            let cleanupDeadline = MonoTime.now() + Duration.second * 3
            try {
                if (let Some(handle) <- child) {
                    try {
                        if (handle.isAlive() && birth.isSome() && observeProcessBirthIdentity(handle.pid)?.serialize() == birth?.serialize()) { handle.terminate() }
                        let remaining = cleanupDeadline - MonoTime.now()
                        if (remaining > Duration.Zero) {
                            let code = handle.wait(timeout: Some(remaining))
                            terminal = code >= 0 && code <= 255 && handle.wait() == code && !handle.isAlive() &&
                                observeProcessBirthIdentity(handle.pid).isNone() && lspPendingGroupGone(handle.pid)
                        }
                    } catch (_: Exception) { terminal = false; @Expect(false, true) }
                    finally {
                        try { handle.closeStreams(); terminal = terminal && handle.streamsAreClosed() && MonoTime.now() <= cleanupDeadline }
                        catch (_: Exception) { terminal = false; @Expect(false, true) }
                    }
                }
            } finally {
                try {
                    File.writeTo(home.join("parent-cleanup.json"),
                        ("{\"driverTerminal\":${terminal},\"proofSaved\":${proofSaved},\"retained\":${!(formal && proofSaved && terminal)}}").toArray())
                    cleanupSaved = true
                } catch (_: Exception) {
                    @Expect(false, true)
                    try { eprintln("lsp_pending_parent_cleanup_proof_failed") } catch (_: Exception) { () }
                } finally {
                    if (formal && proofSaved && terminal && cleanupSaved) {
                        try { remove(home, recursive: true) }
                        catch (_: Exception) { @Expect(false, true); try { eprintln("lsp_pending_parent_owned_cleanup_failed") } catch (_: Exception) { () } }
                    }
                }
                @Expect(terminal, true)
                @Expect(proofSaved, true)
                @Expect(cleanupSaved, true)
            }
        }
    }
}
