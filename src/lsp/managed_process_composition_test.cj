package metis.lsp

import magic.mcp.StdioMCPClient
import magic.utils.{ProcessHandle, ProcessLaunchProvider, setProcessLaunchProvider}
import metis.process.{ManagedMagicRecoveryLaunchScope, managedRecoveryInitialize, managedRecoveryContext,
    currentProcessInstanceIdentity, managedRecoveryProbeRecords, managedRecoveryStopOwnedChildren, observeProcessBirthIdentity}
import std.env.{getVariable, setVariable, removeVariable}
import std.fs.{Path, File, exists, remove}
import std.convert.Parsable
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonObject, JsonBool, JsonInt, JsonString}

private class CompositionPreviousProvider <: ProcessLaunchProvider {
    public var calls: Int64 = 0
    public func launch(command: String, args: Array<String>, env: Array<(String, String)>, redirectErr: Bool): ProcessHandle {
        this.calls += 1
        throw Exception("previous_provider_seen")
    }
}

@When[os == "macOS"]
@Test
public class ManagedProcessCompositionTest {
    @TestCase
    public func lMcp2LiveLspAndTwoClientsRetainIndependentOwnership(): Unit {
        let home = Path("/private/tmp/metis-mcp-composition-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        let directory = home.join("inventory")
        let priorDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
        let priorParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
        let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        let prior = CompositionPreviousProvider()
        let previous = setProcessLaunchProvider(Some<ProcessLaunchProvider>(prior))
        var scope = None<ManagedMagicRecoveryLaunchScope>
        var formal = false; var beforeTerminal = false; var proofSaved = false
        let lspScript = "const mode=process.argv[1];let pending=Buffer.alloc(0);process.stdin.on('data',chunk=>{pending=Buffer.concat([pending,chunk]);for(;;){const end=pending.indexOf('\\r\\n\\r\\n');if(end<0)return;const match=/Content-Length: ([0-9]+)/.exec(pending.subarray(0,end).toString());if(!match)process.exit(62);const n=Number(match[1]);if(pending.length<end+4+n)return;const q=JSON.parse(pending.subarray(end+4,end+4+n).toString());pending=pending.subarray(end+4+n);if(q.method==='exit')process.exit(0);if(mode==='unresponsive')continue;const body=JSON.stringify({jsonrpc:'2.0',id:q.id,result:{text:'中文😀'}});process.stdout.write('Content-Length: '+Buffer.byteLength(body)+'\\r\\n\\r\\n'+body);}});if(mode==='eof')process.exit(0);if(mode==='invalid')process.stdout.write(Buffer.from([255,10]));if(mode==='json')process.stdout.write('Content-Length: 4\\r\\n\\r\\nnope');if(mode==='stderr')process.stderr.write(Buffer.alloc(262144,120));"
        let mcpScript = "const fs=require('fs');if(process.env.OWNED_MCP_READY)fs.writeFileSync(process.env.OWNED_MCP_READY,String(process.pid));const mode=process.argv[1];require('readline').createInterface({input:process.stdin}).on('line',line=>{const q=JSON.parse(line);if(q.id===undefined)return;if(mode==='invalid'){process.stdout.write(Buffer.from([255,10]));return}if(mode==='json'){process.stdout.write('{中文😀broken\\n');return}if(mode==='eof')process.exit(0);let result={};if(q.method==='initialize')result={protocolVersion:q.params.protocolVersion,capabilities:{prompts:{listChanged:false},resources:{subscribe:false,listChanged:false},tools:{listChanged:false}},instructions:null,serverInfo:{name:'owned-composition',version:'1'}};else if(q.method==='tools/list')result={tools:[]};process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:q.id,result})+'\\n');});"
        try {
            let initialized = managedRecoveryInitialize(directory, parent, "composition-fixture")
            @Expect(initialized, true)
            if (!initialized) { throw Exception("composition_inventory_initialization_failed") }
            let owned = ManagedMagicRecoveryLaunchScope(managedRecoveryContext())
            scope = Some(owned)
            let warmLsp = JSONRPCClient("node", serverArgs: ["-e", lspScript, "normal"])
            warmLsp.close()
            let warmMcp = StdioMCPClient("node", ["-e", mcpScript, "normal"])
            warmMcp.close()
            let baseline = lspResourceFdCount()
            var modesPassed = true; var sourcesTerminal = true; var completedModes: Int64 = 0
            for (mode in ["invalid", "json", "eof"]) {
                var lsp = None<JSONRPCClient>
                var first = None<StdioMCPClient>
                var second = None<StdioMCPClient>
                var modeFormal = false; var cleanupSettled = true
                try {
                    let client = JSONRPCClient("node", serverArgs: ["-e", lspScript, "normal"])
                    lsp = Some(client)
                    let firstReady = home.join("first-${mode}")
                    let secondReady = home.join("second-${mode}")
                    first = Some(StdioMCPClient("node", ["-e", mcpScript, "normal"], env: [("OWNED_MCP_READY", firstReady.toString())]))
                    second = Some(StdioMCPClient("node", ["-e", mcpScript, "normal"], env: [("OWNED_MCP_READY", secondReady.toString())]))
                    let firstText = try { String.fromUtf8(File.readFrom(firstReady)) } catch (_: Exception) { throw Exception("composition_invalid_encoding") }
                    let secondText = try { String.fromUtf8(File.readFrom(secondReady)) } catch (_: Exception) { throw Exception("composition_invalid_encoding") }
                    let firstBirth = observeProcessBirthIdentity(Int64.parse(firstText)).getOrThrow()
                    let secondBirth = observeProcessBirthIdentity(Int64.parse(secondText)).getOrThrow()
                    let reply = client.sendRequest("unicode-live")
                    let unicode = reply.asObject().get("text").getOrThrow().asString().getValue()
                    @Expect(unicode, "中文😀")
                    var failed = false
                    try { let _ = StdioMCPClient("node", ["-e", mcpScript, mode]) } catch (_: Exception) { failed = true }
                    @Expect(failed, true)
                    // These close while the later clients still live: no sibling may retain their raw pipes.
                    client.close(); let lspClosed = client.closedForTest(); @Expect(lspClosed, true)
                    let secondLiveBefore = observeProcessBirthIdentity(secondBirth.pid).isSome()
                    @Expect(secondLiveBefore, true)
                    first.getOrThrow().close()
                    let firstGone = observeProcessBirthIdentity(firstBirth.pid).isNone()
                    @Expect(firstGone, true)
                    let secondLiveAfter = observeProcessBirthIdentity(secondBirth.pid).isSome()
                    @Expect(secondLiveAfter, true)
                    second.getOrThrow().close()
                    let secondGone = observeProcessBirthIdentity(secondBirth.pid).isNone()
                    @Expect(secondGone, true)
                    let descriptors = lspResourceFdCount()
                    @Expect(descriptors, baseline)
                    let before = managedRecoveryProbeRecords(directory, parent, "composition-fixture", MonoTime.now() + Duration.second)
                    @Expect(before.terminal, true)
                    sourcesTerminal = sourcesTerminal && before.ok && before.terminal
                    modeFormal = unicode == "中文😀" && failed && lspClosed && secondLiveBefore && firstGone &&
                        secondLiveAfter && secondGone && descriptors == baseline && before.ok && before.terminal
                    let proof = JsonObject(); proof.put("mode", JsonString(mode)); proof.put("formal", JsonBool(modeFormal))
                    proof.put("recordedBeforeFallback", JsonBool(true)); proof.put("sourceOk", JsonBool(before.ok))
                    proof.put("sourceTerminal", JsonBool(before.terminal)); proof.put("sourceStatus", JsonString(before.status))
                    proof.put("fd", JsonInt(descriptors)); proof.put("baselineFd", JsonInt(baseline))
                    File.writeTo(home.join("mode-${mode}-source-before-fallback.txt"), before.original.toArray())
                    File.writeTo(home.join("mode-${mode}-formal-before-fallback.json"), proof.toJsonString().toArray())
                } finally {
                    if (let Some(value) <- first) { try { value.close() } catch (_: Exception) { cleanupSettled = false } }
                    if (let Some(value) <- second) { try { value.close() } catch (_: Exception) { cleanupSettled = false } }
                    if (let Some(value) <- lsp) { try { value.close() } catch (_: Exception) { cleanupSettled = false } }
                    @Expect(cleanupSettled, true)
                }
                modesPassed = modesPassed && modeFormal && cleanupSettled
                completedModes += 1
            }
            beforeTerminal = completedModes == 3 && sourcesTerminal
            owned.fence()
            var refused = false
            try { let _ = StdioMCPClient("node", ["-e", mcpScript, "normal"]) } catch (_: Exception) { refused = true }
            @Expect(refused, true)
            let callsBeforeRestore = prior.calls
            @Expect(callsBeforeRestore, 0)
            let scopeRestored = owned.restoreAfterTerminal(MonoTime.now() + Duration.second * 5)
            @Expect(scopeRestored, true)
            let restored = setProcessLaunchProvider(None)
            let _ = setProcessLaunchProvider(restored)
            var restoredCalled = false
            try { let _ = restored.getOrThrow().launch("fixture", [], [], false) }
            catch (error: Exception) { restoredCalled = error.message == "previous_provider_seen" }
            let callsAfterRestore = prior.calls
            @Expect(restoredCalled, true); @Expect(callsAfterRestore, 1)
            formal = modesPassed && beforeTerminal && refused && callsBeforeRestore == 0 && scopeRestored && restoredCalled && callsAfterRestore == 1
            let proof = JsonObject(); proof.put("formal", JsonBool(formal)); proof.put("recordedBeforeFallback", JsonBool(true))
            proof.put("completedModes", JsonInt(completedModes)); proof.put("expectedModes", JsonInt(3))
            proof.put("sourceTerminalBeforeFallback", JsonBool(beforeTerminal)); proof.put("scopeRestored", JsonBool(scopeRestored))
            proof.put("refused", JsonBool(refused)); proof.put("previousCallsBefore", JsonInt(callsBeforeRestore)); proof.put("previousCallsAfter", JsonInt(callsAfterRestore))
            File.writeTo(home.join("formal-before-fallback.json"), proof.toJsonString().toArray()); proofSaved = true
        } finally {
            var scopeStopped = scope.isNone(); var stopped = false; var restored = true; var cleanupSaved = false
            try {
                try { if (let Some(value) <- scope) { scopeStopped = value.stop(MonoTime.now() + Duration.second * 5) } }
                catch (_: Exception) { @Expect(false, true) }
                finally {
                    try { stopped = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5) }
                    catch (_: Exception) { @Expect(false, true) }
                }
            } finally {
                try { let _ = setProcessLaunchProvider(previous) }
                catch (_: Exception) { restored = false; @Expect(false, true) }
                try {
                    match (priorDirectory) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_DIRECTORY", value) case None => removeVariable("METIS_PROCESS_RECOVERY_DIRECTORY") }
                } catch (_: Exception) { restored = false; @Expect(false, true) }
                try {
                    match (priorParent) { case Some(value) => setVariable("METIS_PROCESS_RECOVERY_PARENT", value) case None => removeVariable("METIS_PROCESS_RECOVERY_PARENT") }
                } catch (_: Exception) { restored = false; @Expect(false, true) }
            }
            try {
                let proof = JsonObject(); proof.put("scopeStopped", JsonBool(scopeStopped)); proof.put("ownedStopComplete", JsonBool(stopped))
                proof.put("providerAndEnvironmentRestored", JsonBool(restored)); proof.put("formalBeforeFallback", JsonBool(formal))
                proof.put("sourceTerminalBeforeFallback", JsonBool(beforeTerminal)); proof.put("proofSaved", JsonBool(proofSaved))
                File.writeTo(home.join("cleanup.json"), proof.toJsonString().toArray()); cleanupSaved = true
            } catch (_: Exception) { @Expect(false, true) }
            @Expect(scopeStopped, true); @Expect(stopped, true); @Expect(restored, true)
            if (formal && beforeTerminal && proofSaved && scopeStopped && stopped && restored && cleanupSaved && exists(home)) {
                try { remove(home, recursive: true) } catch (_: Exception) { @Expect(false, true) }
            }
        }
    }
}
