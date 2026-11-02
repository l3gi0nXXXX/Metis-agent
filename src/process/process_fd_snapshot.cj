package metis.process

import std.env.getProcessId
import std.time.MonoTime

/** Bounded descriptor metadata only: never captures paths or socket peers. */
public class ProcessFdSnapshot {
    public let status: String
    public let fdCount: Int64
    public let fdLimit: Int64
    public let vnodeCount: Int64
    public let socketCount: Int64
    public let pipeCount: Int64
    public let otherCount: Int64

    public init(status: String, fdCount!: Int64 = -1, fdLimit!: Int64 = -1,
        vnodeCount!: Int64 = -1, socketCount!: Int64 = -1, pipeCount!: Int64 = -1, otherCount!: Int64 = -1) {
        this.status = status
        this.fdCount = fdCount
        this.fdLimit = fdLimit
        this.vnodeCount = vnodeCount
        this.socketCount = socketCount
        this.pipeCount = pipeCount
        this.otherCount = otherCount
    }
}

/** Darwin proc_fdinfo consists of a UInt32 fd followed by a UInt32 type. */
public func processFdSnapshotFromNativeResult(records: Array<UInt64>, returnedBytes: Int64,
    requiredBytes: Int64, fdLimit: Int64): ProcessFdSnapshot {
    if (returnedBytes < 0 || requiredBytes < 0) { return ProcessFdSnapshot("probe_failed", fdLimit: fdLimit) }
    if (returnedBytes % 8 != 0 || requiredBytes % 8 != 0) {
        return ProcessFdSnapshot("invalid_native_result", fdLimit: fdLimit)
    }
    let capacity = records.size * 8
    if (requiredBytes > capacity || returnedBytes >= capacity && capacity > 0) {
        return ProcessFdSnapshot("truncated", fdLimit: fdLimit)
    }
    if (returnedBytes > capacity) { return ProcessFdSnapshot("invalid_native_result", fdLimit: fdLimit) }
    var vnodes: Int64 = 0
    var sockets: Int64 = 0
    var pipes: Int64 = 0
    var others: Int64 = 0
    let count = returnedBytes / 8
    for (index in 0..count) {
        let kind = records[index] >> 32
        match (kind) {
            case 1 => vnodes += 1
            case 2 => sockets += 1
            case 6 => pipes += 1
            case _ => others += 1
        }
    }
    ProcessFdSnapshot("ok", fdCount: count, fdLimit: fdLimit, vnodeCount: vnodes,
        socketCount: sockets, pipeCount: pipes, otherCount: others)
}

/** Classifies late observations without allocating a timeout worker or an extra descriptor. */
public func captureCurrentProcessFdSnapshotUntil(deadline: MonoTime): ProcessFdSnapshot {
    if (MonoTime.now() >= deadline) { return ProcessFdSnapshot("deadline_exceeded") }
    let snapshot = captureCurrentProcessFdSnapshot()
    if (MonoTime.now() >= deadline) {
        return ProcessFdSnapshot("deadline_exceeded", fdLimit: snapshot.fdLimit)
    }
    snapshot
}

@When[os == "macOS"]
foreign {
    func getrlimit(resource: Int32, limit: CPointer<UInt64>): Int32
}

@When[os == "macOS"]
public func captureCurrentProcessFdSnapshot(): ProcessFdSnapshot {
    var limits: VArray<UInt64, $2> = [0, 0]
    let limitResult = unsafe { getrlimit(Int32(8), inout limits) }
    let limit = if (limitResult == 0 && limits[0] <= UInt64(Int64.Max)) { Int64(limits[0]) } else { -1 }
    // PROC_PIDLISTFDS uses an eight-byte proc_fdinfo. No opened diagnostic FD,
    // subprocess, or unbounded allocation is needed, even at EMFILE.
    let pid = Int32(getProcessId())
    let required = unsafe { proc_pidinfo(pid, Int32(1), UInt64(0), CPointer<UInt64>(), Int32(0)) }
    if (required < 0) { return ProcessFdSnapshot("probe_failed", fdLimit: limit) }
    var records: VArray<UInt64, $4096> = VArray<UInt64, $4096>(repeat: 0)
    if (required >= 32768) { return ProcessFdSnapshot("truncated", fdLimit: limit) }
    let returned = unsafe { proc_pidinfo(pid, Int32(1), UInt64(0), inout records, Int32(32768)) }
    if (returned < 0 || returned == 0 && required > 0) {
        return ProcessFdSnapshot("probe_failed", fdLimit: limit)
    }
    // The decoder also bounds native short/malformed replies before indexing.
    let copied = Array<UInt64>(4096, repeat: 0)
    for (index in 0..4096) { copied[index] = records[index] }
    processFdSnapshotFromNativeResult(copied, Int64(returned), Int64(required), limit)
}

@When[os != "macOS"]
public func captureCurrentProcessFdSnapshot(): ProcessFdSnapshot { ProcessFdSnapshot("unsupported") }
