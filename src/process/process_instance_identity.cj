package metis.process

import std.convert.Parsable
import std.time.MonoTime

/** Stable, non-secret operating-system process instance identity. */
public class ProcessInstanceIdentity {
    public let platform: Int64
    public let pid: Int64
    public let value0: UInt64
    public let value1: UInt64
    public let value2: UInt64
    public let value3: UInt64
    public let value4: UInt64
    public let value5: UInt64
    public let value6: UInt64
    public let value7: UInt64
    public let value8: UInt64
    public let value9: UInt64

    public init(
        platform: Int64,
        pid: Int64,
        value0!: UInt64 = 0,
        value1!: UInt64 = 0,
        value2!: UInt64 = 0,
        value3!: UInt64 = 0,
        value4!: UInt64 = 0,
        value5!: UInt64 = 0,
        value6!: UInt64 = 0,
        value7!: UInt64 = 0,
        value8!: UInt64 = 0,
        value9!: UInt64 = 0
    ) {
        this.platform = platform
        this.pid = pid
        this.value0 = value0
        this.value1 = value1
        this.value2 = value2
        this.value3 = value3
        this.value4 = value4
        this.value5 = value5
        this.value6 = value6
        this.value7 = value7
        this.value8 = value8
        this.value9 = value9
    }

    public func matches(other: ProcessInstanceIdentity): Bool {
        this.platform == other.platform && this.pid == other.pid &&
            this.value0 == other.value0 && this.value1 == other.value1 &&
            this.value2 == other.value2 && this.value3 == other.value3 &&
            this.value4 == other.value4 && this.value5 == other.value5 &&
            this.value6 == other.value6 && this.value7 == other.value7 &&
            this.value8 == other.value8 && this.value9 == other.value9
    }

    public func serialize(): String {
        "${this.platform}:${this.pid}:${this.value0}:${this.value1}:${this.value2}:${this.value3}:${this.value4}:${this.value5}:${this.value6}:${this.value7}:${this.value8}:${this.value9}"
    }
}

public class ProcessInstanceProbeResult {
    public let conclusive: Bool
    public let alive: Bool
    public let status: String

    public init(conclusive: Bool, alive: Bool, status: String) {
        this.conclusive = conclusive
        this.alive = alive
        this.status = status.trimAscii()
    }
}

public class ProcessInstanceSignalResult {
    public let ok: Bool
    public let status: String

    public init(ok: Bool, status: String) {
        this.ok = ok
        this.status = status.trimAscii()
    }
}

private let PROCESS_INSTANCE_MACOS: Int64 = 1
private let PROCESS_INSTANCE_WINDOWS: Int64 = 2
private let PROCESS_INSTANCE_SIGNAL_TERM: Int64 = 15
private let PROCESS_INSTANCE_SIGNAL_KILL: Int64 = 9

public func processInstanceTermSignal(): Int64 { PROCESS_INSTANCE_SIGNAL_TERM }
public func processInstanceKillSignal(): Int64 { PROCESS_INSTANCE_SIGNAL_KILL }

public func parseProcessInstanceIdentity(text: String): Option<ProcessInstanceIdentity> {
    let parts = text.trimAscii().split(":")
    if (parts.size != 12) { return None<ProcessInstanceIdentity> }
    try {
        let platform = Int64.parse(parts[0])
        let pid = Int64.parse(parts[1])
        let parsed = ProcessInstanceIdentity(
            platform,
            pid,
            value0: UInt64.parse(parts[2]),
            value1: UInt64.parse(parts[3]),
            value2: UInt64.parse(parts[4]),
            value3: UInt64.parse(parts[5]),
            value4: UInt64.parse(parts[6]),
            value5: UInt64.parse(parts[7]),
            value6: UInt64.parse(parts[8]),
            value7: UInt64.parse(parts[9]),
            value8: UInt64.parse(parts[10]),
            value9: UInt64.parse(parts[11])
        )
        if (pid <= 1 || (platform != PROCESS_INSTANCE_MACOS && platform != PROCESS_INSTANCE_WINDOWS)) {
            return None<ProcessInstanceIdentity>
        }
        Some(parsed)
    } catch (_: Exception) {
        None<ProcessInstanceIdentity>
    }
}

@When[os == "macOS"]
foreign {
    func task_self_trap(): UInt32
    func task_info(task: UInt32, flavor: Int32, info: CPointer<UInt32>, count: CPointer<UInt32>): Int32
    func proc_signal_with_audittoken(token: CPointer<UInt32>, signal: Int32): Int32
    func proc_pidinfo(pid: Int32, flavor: Int32, arg: UInt64, buffer: CPointer<UInt64>, bufferSize: Int32): Int32
    func __error(): CPointer<Int32>
}

@When[os == "macOS"]
private func processInstanceMacErrno(): Int32 {
    unsafe { __error().read() }
}

@When[os == "macOS"]
private func processInstanceMacToken(identity: ProcessInstanceIdentity): VArray<UInt32, $8> {
    [
        UInt32(identity.value0), UInt32(identity.value1), UInt32(identity.value2), UInt32(identity.value3),
        UInt32(identity.value4), UInt32(identity.value5), UInt32(identity.value6), UInt32(identity.value7)
    ]
}

@When[os == "macOS"]
private func processInstanceMacStart(pid: Int64): Option<(UInt64, UInt64)> {
    if (pid <= 1 || pid > 2147483647) { return None<(UInt64, UInt64)> }
    // proc_bsdinfo is 136 bytes. Its two final UInt64 fields are start seconds/useconds.
    var info: VArray<UInt64, $17> = VArray<UInt64, $17>(repeat: 0)
    unsafe { __error().write(Int32(0)) }
    let size = unsafe { proc_pidinfo(Int32(pid), Int32(3), UInt64(0), inout info, Int32(136)) }
    if (size != 136) { return None<(UInt64, UInt64)> }
    Some((info[15], info[16]))
}

@When[os == "macOS"]
public func currentProcessInstanceIdentity(): Option<ProcessInstanceIdentity> {
    var token: VArray<UInt32, $8> = [0, 0, 0, 0, 0, 0, 0, 0]
    var count: UInt32 = 8
    let rc = unsafe { task_info(task_self_trap(), Int32(15), inout token, inout count) }
    if (rc != 0 || count != 8) { return None<ProcessInstanceIdentity> }
    let pid = Int64(token[5])
    if (pid <= 1) { return None<ProcessInstanceIdentity> }
    match (processInstanceMacStart(pid)) {
        case Some(start) =>
            Some(ProcessInstanceIdentity(
                PROCESS_INSTANCE_MACOS,
                pid,
                value0: UInt64(token[0]), value1: UInt64(token[1]), value2: UInt64(token[2]), value3: UInt64(token[3]),
                value4: UInt64(token[4]), value5: UInt64(token[5]), value6: UInt64(token[6]), value7: UInt64(token[7]),
                value8: start[0], value9: start[1]
            ))
        case None => None<ProcessInstanceIdentity>
    }
}

@When[os == "macOS"]
public func probeProcessInstance(identity: ProcessInstanceIdentity, deadline: MonoTime): ProcessInstanceProbeResult {
    if (identity.platform != PROCESS_INSTANCE_MACOS || identity.pid <= 1) {
        return ProcessInstanceProbeResult(false, false, "identity_unsupported")
    }
    if (MonoTime.now() >= deadline) { return ProcessInstanceProbeResult(false, false, "deadline_exceeded") }
    match (processInstanceMacStart(identity.pid)) {
        case Some(start) =>
            if (start[0] == identity.value8 && start[1] == identity.value9) {
                ProcessInstanceProbeResult(true, true, "alive")
            } else {
                ProcessInstanceProbeResult(true, false, "stale_identity")
            }
        case None =>
            let error = processInstanceMacErrno()
            if (error == 3) { ProcessInstanceProbeResult(true, false, "gone") }
            else if (error == 1) { ProcessInstanceProbeResult(false, true, "permission_denied") }
            else { ProcessInstanceProbeResult(false, false, "probe_failed") }
    }
}

@When[os == "macOS"]
public func signalProcessInstance(identity: ProcessInstanceIdentity, signal: Int64, deadline: MonoTime): ProcessInstanceSignalResult {
    if (identity.platform != PROCESS_INSTANCE_MACOS || identity.pid <= 1) {
        return ProcessInstanceSignalResult(false, "identity_unsupported")
    }
    if (signal != PROCESS_INSTANCE_SIGNAL_TERM && signal != PROCESS_INSTANCE_SIGNAL_KILL) {
        return ProcessInstanceSignalResult(false, "signal_unsupported")
    }
    if (MonoTime.now() >= deadline) { return ProcessInstanceSignalResult(false, "deadline_exceeded") }
    var token = processInstanceMacToken(identity)
    let rc = unsafe { proc_signal_with_audittoken(inout token, Int32(signal)) }
    if (rc == 0) { return ProcessInstanceSignalResult(true, "signaled") }
    let error = processInstanceMacErrno()
    if (error == 3) { return ProcessInstanceSignalResult(false, "stale_identity") }
    if (error == 1) { return ProcessInstanceSignalResult(false, "permission_denied") }
    ProcessInstanceSignalResult(false, "signal_failed")
}

@When[os == "Windows"]
foreign {
    func GetCurrentProcess(): CPointer<Unit>
    func GetCurrentProcessId(): UInt32
    func OpenProcess(desiredAccess: UInt32, inheritHandle: UInt32, processId: UInt32): CPointer<Unit>
    func GetProcessTimes(handle: CPointer<Unit>, creation: CPointer<UInt32>, exit: CPointer<UInt32>, kernel: CPointer<UInt32>, user: CPointer<UInt32>): UInt32
    func WaitForSingleObject(handle: CPointer<Unit>, milliseconds: UInt32): UInt32
    func TerminateProcess(handle: CPointer<Unit>, exitCode: UInt32): UInt32
    func CloseHandle(handle: CPointer<Unit>): UInt32
}

@When[os == "Windows"]
private func processInstanceWindowsIdentity(handle: CPointer<Unit>, pid: Int64): Option<ProcessInstanceIdentity> {
    var creation: VArray<UInt32, $2> = [0, 0]
    var exitTime: VArray<UInt32, $2> = [0, 0]
    var kernel: VArray<UInt32, $2> = [0, 0]
    var user: VArray<UInt32, $2> = [0, 0]
    let ok = unsafe { GetProcessTimes(handle, inout creation, inout exitTime, inout kernel, inout user) }
    if (ok == 0) { return None<ProcessInstanceIdentity> }
    Some(ProcessInstanceIdentity(PROCESS_INSTANCE_WINDOWS, pid, value0: UInt64(creation[0]), value1: UInt64(creation[1])))
}

@When[os == "Windows"]
public func currentProcessInstanceIdentity(): Option<ProcessInstanceIdentity> {
    let pid = Int64(unsafe { GetCurrentProcessId() })
    processInstanceWindowsIdentity(unsafe { GetCurrentProcess() }, pid)
}

@When[os == "Windows"]
private func processInstanceWindowsHandle(identity: ProcessInstanceIdentity): Option<CPointer<Unit>> {
    if (identity.platform != PROCESS_INSTANCE_WINDOWS || identity.pid <= 1 || identity.pid > 4294967295) {
        return None<CPointer<Unit>>
    }
    // SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE.
    let handle = unsafe { OpenProcess(UInt32(0x00101001), UInt32(0), UInt32(identity.pid)) }
    if (handle.isNull()) { return None<CPointer<Unit>> }
    match (processInstanceWindowsIdentity(handle, identity.pid)) {
        case Some(current) =>
            if (current.matches(identity)) { Some(handle) } else {
                let _ = unsafe { CloseHandle(handle) }
                None<CPointer<Unit>>
            }
        case None =>
            let _ = unsafe { CloseHandle(handle) }
            None<CPointer<Unit>>
    }
}

@When[os == "Windows"]
public func probeProcessInstance(identity: ProcessInstanceIdentity, deadline: MonoTime): ProcessInstanceProbeResult {
    if (MonoTime.now() >= deadline) { return ProcessInstanceProbeResult(false, false, "deadline_exceeded") }
    match (processInstanceWindowsHandle(identity)) {
        case Some(handle) =>
            try {
                let status = unsafe { WaitForSingleObject(handle, UInt32(0)) }
                if (status == UInt32(258)) {
                    ProcessInstanceProbeResult(true, true, "alive")
                } else if (status == UInt32(0)) {
                    ProcessInstanceProbeResult(true, false, "gone")
                } else {
                    ProcessInstanceProbeResult(false, false, "probe_failed")
                }
            } finally {
                let _ = unsafe { CloseHandle(handle) }
            }
        case None => ProcessInstanceProbeResult(false, false, "identity_unavailable")
    }
}

@When[os == "Windows"]
public func signalProcessInstance(identity: ProcessInstanceIdentity, signal: Int64, deadline: MonoTime): ProcessInstanceSignalResult {
    if (signal != PROCESS_INSTANCE_SIGNAL_TERM && signal != PROCESS_INSTANCE_SIGNAL_KILL) {
        return ProcessInstanceSignalResult(false, "signal_unsupported")
    }
    if (MonoTime.now() >= deadline) { return ProcessInstanceSignalResult(false, "deadline_exceeded") }
    match (processInstanceWindowsHandle(identity)) {
        case Some(handle) =>
            try {
                if (unsafe { TerminateProcess(handle, UInt32(1)) } != 0) {
                    ProcessInstanceSignalResult(true, "signaled")
                } else {
                    ProcessInstanceSignalResult(false, "signal_failed")
                }
            } finally {
                let _ = unsafe { CloseHandle(handle) }
            }
        case None => ProcessInstanceSignalResult(false, "stale_identity")
    }
}

@When[os != "macOS" && os != "Windows"]
public func currentProcessInstanceIdentity(): Option<ProcessInstanceIdentity> { None<ProcessInstanceIdentity> }

@When[os != "macOS" && os != "Windows"]
public func probeProcessInstance(_identity: ProcessInstanceIdentity, _deadline: MonoTime): ProcessInstanceProbeResult {
    ProcessInstanceProbeResult(false, false, "identity_unsupported")
}

@When[os != "macOS" && os != "Windows"]
public func signalProcessInstance(_identity: ProcessInstanceIdentity, _signal: Int64, _deadline: MonoTime): ProcessInstanceSignalResult {
    ProcessInstanceSignalResult(false, "identity_unsupported")
}
