package metis.lsp

import metis.process.{currentProcessInstanceIdentity, managedRecoveryInitialize, managedRecoveryStopOwnedChildren,
    managedRecoveryProbeRecords}
import std.env.{getVariable, setVariable, removeVariable, getProcessId}
import std.fs.{Path, File, Directory, exists, remove}
import std.time.{DateTime, MonoTime}
import std.unittest.testmacro.*
import stdx.encoding.json.{JsonValue, JsonObject, JsonString, JsonBool, JsonInt}

@When[os == "macOS"]
foreign { func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, bufferSize: Int32): Int32 }

@When[os == "macOS"]
func lspResourceFdCount(): Int64 {
    let buffer = unsafe { LibC.malloc<UInt64>(count: 4096) }
    try {
        let bytes = unsafe { proc_pidinfo(Int32(getProcessId()), 1, 0, buffer, 32768) }
        if (bytes <= 0 || bytes >= 32768 || bytes % 8 != 0) { throw Exception("lsp_fixture_fd_unknown") }
        Int64(bytes / 8)
    } finally { unsafe { LibC.free(buffer) } }
}

private func lspResourceRequire(ok: Bool): Unit {
    @Expect(ok, true)
    if (!ok) { throw Exception("lsp_fixture_contract_failed") }
}

@When[os == "macOS"]
@Test
public class JSONRPCClientResourceTest {
    @TestCase
    public func lN3NormalAndFailedShutdownJoinRealOwners(): Unit {
        let home = Path("/private/tmp/metis-lsp-owned-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(home)
        let directory = home.join("inventory")
        var formal = false
        var completedModes = 0
        var firstError = None<Exception>
        let previousDirectory = getVariable("METIS_PROCESS_RECOVERY_DIRECTORY")
        let previousParent = getVariable("METIS_PROCESS_RECOVERY_PARENT")
        let parent = currentProcessInstanceIdentity().getOrThrow().serialize()
        let script = "const mode=process.argv[1];let pending=Buffer.alloc(0);if(mode!=='blocked')process.stdin.on('data',chunk=>{pending=Buffer.concat([pending,chunk]);for(;;){const end=pending.indexOf('\\r\\n\\r\\n');if(end<0)return;const match=/Content-Length: ([0-9]+)/.exec(pending.subarray(0,end).toString());if(!match)process.exit(62);const n=Number(match[1]);if(pending.length<end+4+n)return;const q=JSON.parse(pending.subarray(end+4,end+4+n).toString());pending=pending.subarray(end+4+n);if(q.method==='exit')process.exit(0);if(mode==='unresponsive'||mode==='body-eof'||mode==='body-invalid')continue;const body=JSON.stringify({jsonrpc:'2.0',id:q.id,result:{text:'中文😀'}});process.stdout.write('Content-Length: '+Buffer.byteLength(body)+'\\r\\n\\r\\n'+body);}});if(mode==='eof')process.exit(0);if(mode==='invalid')process.stdout.write(Buffer.from([255,10]));if(mode==='json')process.stdout.write('Content-Length: 4\\r\\n\\r\\nnope');if(mode==='stderr')process.stderr.write(Buffer.alloc(262144,120));if(mode==='body-invalid')process.stdout.write(Buffer.concat([Buffer.from('Content-Length: 3\\r\\n\\r\\n'),Buffer.from([255,0,254])]));if(mode==='body-eof')process.stdout.write('Content-Length: 10\\r\\n\\r\\n{',()=>require('fs').closeSync(1));if(mode==='blocked'){process.stdin.once('data',chunk=>{process.stdin.pause();require('fs').writeFileSync(process.argv[2],String(chunk.length))});setInterval(()=>{},1000)}"
        try {
            lspResourceRequire(managedRecoveryInitialize(directory, parent, "lsp-fixture"))
            // Warm native Node runtime before measuring repeated complete client lifecycles.
            let warm = JSONRPCClient("node", serverArgs: ["-e", script, "normal"])
            warm.close()
            lspResourceRequire(warm.closedForTest())
            let baseline = lspResourceFdCount()
            for (mode in ["normal", "unresponsive", "eof", "invalid", "json", "stderr", "body-invalid", "body-eof", "blocked"]) {
                let ready = home.join("blocked-ready")
                let client = JSONRPCClient("node", serverArgs: ["-e", script, mode, ready.toString()])
                var request = None<Future<JsonValue>>
                var modeError = None<Exception>
                try {
                    if (mode == "normal" || mode == "stderr") {
                        request = Some(spawn { client.sendRequest("unicode-fixture") })
                        let response = request.getOrThrow().get(Duration.second * 2)
                        lspResourceRequire(response.asObject().get("text").getOrThrow().asString().getValue() == "中文😀")
                    }
                    if (mode == "blocked") {
                        let params = JsonObject()
                        params.put("payload", JsonString(String(Array<Rune>(1048576, repeat: r'x'))))
                        request = Some(spawn { client.sendRequest("blocked-write", params: Some(params)) })
                        let deadline = MonoTime.now() + Duration.second * 2
                        while (!exists(ready) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                        lspResourceRequire(exists(ready))
                        // The peer consumed the first write chunk then paused while most of1MiB remains.
                    }
                    client.close()
                    lspResourceRequire(client.closedForTest())
                    client.close()
                    lspResourceRequire(client.closedForTest())
                    if (mode == "invalid" || mode == "body-invalid") { lspResourceRequire(client.receiverStatusForTest() == "lsp_invalid_response_encoding") }
                    if (mode == "body-eof") { lspResourceRequire(client.receiverStatusForTest() == "lsp_response_eof") }
                    if (mode == "json") { lspResourceRequire(client.receiverStatusForTest() == "lsp_malformed_json") }
                } catch (error: Exception) { modeError = Some(error) }
                finally {
                    try { client.close() }
                    catch (error: Exception) { if (modeError.isNone()) { modeError = Some(error) } }
                    finally {
                        if (let Some(worker) <- request) {
                            try {
                                if (mode == "blocked") {
                                    var rejected = false
                                    try { let _ = worker.get(Duration.second * 2) }
                                    catch (error: TimeoutException) { throw error }
                                    catch (_: Exception) { rejected = true }
                                    lspResourceRequire(rejected)
                                } else { let _ = worker.get(Duration.second * 2) }
                            } catch (error: Exception) { if (modeError.isNone()) { modeError = Some(error) } }
                        }
                    }
                }
                if (let Some(error) <- modeError) { throw error }
                lspResourceRequire(lspResourceFdCount() == baseline)
                let proof = managedRecoveryProbeRecords(directory, parent, "lsp-fixture", MonoTime.now() + Duration.second)
                let observed = JsonObject()
                observed.put("mode", JsonString(mode)); observed.put("status", JsonString(proof.status))
                observed.put("ok", JsonBool(proof.ok)); observed.put("terminal", JsonBool(proof.terminal))
                observed.put("fd", JsonInt(lspResourceFdCount())); observed.put("baselineFd", JsonInt(baseline))
                File.writeTo(home.join("mode-" + mode + ".json"), observed.toJsonString().toArray())
                println("LSP-RESOURCE mode=${mode};status=${proof.status};terminal=${proof.terminal}")
                lspResourceRequire(proof.ok && proof.terminal)
                completedModes++
            }
            formal = true
        } catch (error: Exception) { firstError = Some(error) }
        finally {
            var proofSaved = false
            var terminal = false
            var restored = true
            try {
                File.writeTo(home.join("formal-before-fallback"),
                    "formal:${formal};completedModes:${completedModes};bodyFailed:${firstError.isSome()}\n".toArray())
                proofSaved = true
            } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
            finally {
                try {
                    terminal = managedRecoveryStopOwnedChildren((directory.toString(), parent), MonoTime.now() + Duration.second * 5)
                    if (!terminal) { throw Exception("lsp_fixture_cleanup_pending") }
                } catch (error: Exception) { if (firstError.isNone()) { firstError = Some(error) } }
                finally {
                    for ((key, previous) in [("METIS_PROCESS_RECOVERY_DIRECTORY", previousDirectory), ("METIS_PROCESS_RECOVERY_PARENT", previousParent)]) {
                        try { match (previous) { case Some(value) => setVariable(key, value) case None => removeVariable(key) } }
                        catch (error: Exception) { restored = false; if (firstError.isNone()) { firstError = Some(error) } }
                    }
                }
            }
            if (formal && proofSaved && terminal && restored && firstError.isNone() && exists(home)) { remove(home, recursive: true) }
        }
        if (let Some(error) <- firstError) { throw error }
    }
}
