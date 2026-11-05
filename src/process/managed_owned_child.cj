package metis.process

import std.collection.{ArrayList, HashMap, Map}
import std.env.{getVariable, getVariables}
import std.fs.{FSException, FileInfo, Path, canonicalize, exists}
import std.io.{InputStream, OutputStream, IOStream}
import std.process.{ProcessException, ProcessRedirect, SubProcess, launch, executeWithOutput}
import std.sync.Mutex
import std.time.MonoTime
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonString}

@When[os == "macOS"]
import std.posix.read as managedPosixRead
@When[os == "macOS"]
import std.posix.write as managedPosixWrite

/** Only a direct-child handle and its byte streams; scheduling remains with the existing caller. */
public interface ManagedOwnedChild {
    prop pid: Int64
    prop stdInPipe: OutputStream
    prop stdOutPipe: InputStream
    prop stdErrPipe: InputStream
    func isAlive(): Bool
    func wait(timeout!: ?Duration): Int64
    func terminate(force!: Bool): Unit
    func closeStreams(): Unit
    func closeInput(): Unit
    func streamsAreClosed(): Bool
    func wait(): Int64 { this.wait(timeout: None) }
    func terminate(): Unit { this.terminate(force: false) }
}

class ManagedNativeSpawnException <: Exception {
    let errorCode: Int32
    init(errorCode: Int32) { super("owned_process_spawn_failed"); this.errorCode = errorCode }
}

class ManagedNativeSpawnUnknownException <: Exception {
    init() { super("owned_process_spawn_identity_unknown") }
}

class ManagedNativeSetupException <: Exception {
    let child: ManagedOwnedChild
    let birth: ?ProcessBirthIdentity
    init(child: ManagedOwnedChild, birth: ?ProcessBirthIdentity) {
        super("owned_process_spawned_setup_failed"); this.child = child; this.birth = birth
    }
}

@When[os == "macOS"]
private func managedSdkWaitCodeValid(code: Int64): Bool { code >= 0 && code <= 255 }

@When[os != "macOS"]
private func managedSdkWaitCodeValid(_code: Int64): Bool { true }

class ManagedSdkChild <: ManagedOwnedChild {
    private let child: SubProcess
    private let state = Mutex()
    private let ownsPipes: Bool
    private var waiter = None<Future<Int64>>
    private var exitCode = None<Int64>
    private var waitFailed = false
    public init(child: SubProcess, redirects: Array<ProcessRedirect>) {
        this.child = child
        var owned = false
        for (redirect in redirects) { match (redirect) { case ProcessRedirect.Pipe => owned = true case _ => () } }
        this.ownsPipes = owned
    }
    public prop pid: Int64 { get() { this.child.pid } }
    public prop stdInPipe: OutputStream { get() { this.child.stdInPipe } }
    public prop stdOutPipe: InputStream { get() { this.child.stdOutPipe } }
    public prop stdErrPipe: InputStream { get() { this.child.stdErrPipe } }
    public func isAlive(): Bool {
        synchronized(this.state) {
            if (this.exitCode.isSome()) { return false }
            if (this.waitFailed) { throw Exception("owned_process_wait_failed") }
            this.child.isAlive()
        }
    }
    public func wait(timeout!: ?Duration): Int64 {
        let future = synchronized(this.state) {
            match (this.waiter) {
                case Some(value) => value
                case None =>
                    let value = spawn {
                        try {
                            // SDK timeout creates an unretained reaper. Only this waiter owns SDK.wait.
                            let code = this.child.wait(timeout: None)
                            if (!managedSdkWaitCodeValid(code)) { throw Exception("owned_process_wait_failed") }
                            // SDK closes its owned Pipe streams before wait returns; wrappers themselves
                            // do not expose Resource. Borrowed FromFile streams remain caller-owned.
                            synchronized(this.state) { this.exitCode = Some(code) }
                            code
                        } catch (_: Exception) {
                            synchronized(this.state) { this.waitFailed = true }
                            throw Exception("owned_process_wait_failed")
                        }
                    }
                    this.waiter = Some(value)
                    value
            }
        }
        match (timeout) {
            case Some(value) => if (value > Duration.Zero) { future.get(value) } else { future.get() }
            case None => future.get()
        }
    }
    public func terminate(force!: Bool): Unit {
        synchronized(this.state) {
            if (this.exitCode.isSome()) { return }
            if (this.waitFailed) { throw Exception("owned_process_wait_failed") }
            this.child.terminate(force: force)
        }
    }
    // SDK exposes no close on the outer Pipe wrappers. Its successful wait closes only
    // owned pipes; closing a FromFile Resource here would close the caller's file.
    public func closeInput(): Unit {}
    public func closeStreams(): Unit {}
    public func streamsAreClosed(): Bool {
        synchronized(this.state) { !this.ownsPipes || this.exitCode.isSome() }
    }
}

// Preserve the SDK getter surface without borrowing its wait-before-reader-close behavior.
// The returned native child is explicitly closed after callers join their pipe readers.
@When[os == "macOS"]
private class ManagedNoContextInput <: InputStream {
    private let stream: InputStream
    init(stream: InputStream) { this.stream = stream }
    public func read(buffer: Array<Byte>): Int64 { this.stream.read(buffer) }
}

@When[os == "macOS"]
private class ManagedNoContextOutput <: OutputStream {
    private let stream: OutputStream
    init(stream: OutputStream) { this.stream = stream }
    public func write(buffer: Array<Byte>): Unit { this.stream.write(buffer) }
    public func flush(): Unit {}
}

@When[os == "macOS"]
private class ManagedNoContextNullStream <: IOStream & Resource {
    public func read(_: Array<Byte>): Int64 { -1 }
    public func write(_: Array<Byte>): Unit { throw ProcessException("owned_process_stream_unavailable") }
    public func flush(): Unit {}
    public func close(): Unit {}
    public func isClosed(): Bool { true }
}

@When[os == "macOS"]
private class ManagedNoContextChild <: ManagedOwnedChild {
    private let child: ManagedOwnedChild
    private let input: OutputStream
    private let output: InputStream
    private let error: InputStream
    init(child: ManagedOwnedChild, redirects: Array<ProcessRedirect>) {
        this.child = child
        this.input = match (redirects[0]) { case ProcessRedirect.Pipe => ManagedNoContextOutput(child.stdInPipe) case _ => ManagedNoContextNullStream() }
        this.output = match (redirects[1]) { case ProcessRedirect.Pipe => ManagedNoContextInput(child.stdOutPipe) case _ => ManagedNoContextNullStream() }
        this.error = match (redirects[2]) { case ProcessRedirect.Pipe => ManagedNoContextInput(child.stdErrPipe) case _ => ManagedNoContextNullStream() }
    }
    public prop pid: Int64 { get() { this.child.pid } }
    public prop stdInPipe: OutputStream { get() { this.input } }
    public prop stdOutPipe: InputStream { get() { this.output } }
    public prop stdErrPipe: InputStream { get() { this.error } }
    public func isAlive(): Bool { this.child.isAlive() }
    public func terminate(force!: Bool): Unit { this.child.terminate(force: force) }
    public func wait(timeout!: ?Duration): Int64 { this.child.wait(timeout: timeout) }
    public func closeInput(): Unit { this.child.closeInput() }
    public func closeStreams(): Unit { this.child.closeStreams() }
    public func streamsAreClosed(): Bool { this.child.streamsAreClosed() }
}

@When[os == "macOS"]
private func managedLaunchWithoutContext(command: String, arguments: Array<String>, workingDirectory: ?Path,
    environment: ?Map<String, String>, redirects: Array<ProcessRedirect>): ManagedOwnedChild {
    // SDK rejects closed/unlinked FromFile inputs; these files always remain caller-owned.
    for (redirect in redirects) {
        match (redirect) {
            case ProcessRedirect.FromFile(file) =>
                if (file.isClosed() || !exists(file.info.path)) { throw ProcessException("owned_process_redirect_invalid") }
            case _ => ()
        }
    }
    let child = try {
        managedNativeLaunch(command, arguments, workingDirectory, environment, redirects, detachedProcessGroup: false)
    } catch (_: ManagedNativeSpawnException) { throw ProcessException("owned_process_launch_failed") }
      catch (error: Exception) {
        // Only these fixed pre-spawn preparation failures have no child ownership to retain.
        // Unknown identity and setup exceptions carry their original safety/handle information.
        if (["owned_process_actions_failed", "owned_process_attributes_failed", "owned_process_pipe_failed",
            "owned_process_pipe_flags_failed", "owned_process_directory_failed"].contains(error.message)) {
            throw ProcessException("owned_process_launch_failed")
        }
        throw error
    }
    ManagedNoContextChild(child, redirects)
}

@When[os != "macOS"]
private func managedLaunchWithoutContext(command: String, arguments: Array<String>, workingDirectory: ?Path,
    environment: ?Map<String, String>, redirects: Array<ProcessRedirect>): ManagedOwnedChild {
    ManagedSdkChild(launch(command, arguments, workingDirectory: workingDirectory, environment: environment,
        stdIn: redirects[0], stdOut: redirects[1], stdErr: redirects[2]), redirects)
}

@When[os == "macOS"]
foreign {
    func pipe(fds: CPointer<Int32>): Int32
    func fcntl(fd: Int32, command: Int32, ...): Int32
    func waitpid(pid: Int32, status: CPointer<Int32>, flags: Int32): Int32
    func posix_spawnattr_init(value: CPointer<CPointer<Unit>>): Int32
    func posix_spawnattr_destroy(value: CPointer<CPointer<Unit>>): Int32
    func posix_spawnattr_setpgroup(value: CPointer<CPointer<Unit>>, group: Int32): Int32
    func posix_spawnattr_setflags(value: CPointer<CPointer<Unit>>, flags: Int16): Int32
    func posix_spawn_file_actions_init(value: CPointer<CPointer<Unit>>): Int32
    func posix_spawn_file_actions_destroy(value: CPointer<CPointer<Unit>>): Int32
    func posix_spawn_file_actions_adddup2(value: CPointer<CPointer<Unit>>, descriptor: Int32, target: Int32): Int32
    func posix_spawn_file_actions_addopen(value: CPointer<CPointer<Unit>>, descriptor: Int32, path: CString, flags: Int32, mode: UInt16): Int32
    func posix_spawn_file_actions_addchdir_np(value: CPointer<CPointer<Unit>>, path: CString): Int32
    func posix_spawn(pid: CPointer<Int32>, command: CString, actions: CPointer<CPointer<Unit>>,
        attributes: CPointer<CPointer<Unit>>, arguments: CPointer<CString>, environment: CPointer<CString>): Int32
}

@When[os == "macOS"]
func managedNativeDuplicateAtLeast(fd: Int32, minimum: Int32): Int32 { unsafe { fcntl(fd, 67, minimum) } }

@When[os == "macOS"]
func managedNativeDescriptorIsNullForTest(fd: Int32): Bool {
    let path = LibC.malloc<Byte>(count: 1024)
    if (path.isNull()) { return false }
    try {
        if (unsafe { fcntl(fd, 50, path) } != 0) { return false }
        let expected = "/dev/null".toArray()
        for (index in 0..expected.size) { if (unsafe { path.read(index) } != expected[index]) { return false } }
        unsafe { path.read(expected.size) } == 0
    } finally { unsafe { LibC.free(path) } }
}

@When[os == "macOS"]
private class ManagedNativePipe <: InputStream & OutputStream & Resource {
    private let lock = Mutex()
    private var descriptor: Int32
    private var closed = false
    private var inFlight: Int64 = 0
    public init(descriptor: Int32) { this.descriptor = descriptor }
    public func isClosed(): Bool { synchronized(this.lock) { this.closed } }
    func fullyClosed(): Bool { synchronized(this.lock) { this.closed && this.inFlight == 0 && this.descriptor < 0 } }
    func snapshotForTest(): (Int64, Int32) { synchronized(this.lock) { (this.inFlight, this.descriptor) } }
    private func beginIo(): Int32 {
        synchronized(this.lock) {
            if (this.closed) { throw Exception("owned_process_stream_closed") }
            this.inFlight += 1
            this.descriptor
        }
    }
    private func endIo(): Unit {
        synchronized(this.lock) {
            this.inFlight -= 1
            this.closeWhenIdle()
        }
    }
    // An active syscall retains its descriptor even after logical close. No new FD is
    // needed under EMFILE, and the number cannot be reused until the syscall returns.
    private func closeWhenIdle(): Unit {
        if (this.closed && this.inFlight == 0 && this.descriptor >= 0) {
            let _ = unsafe { close(this.descriptor) }
            this.descriptor = -1
        }
    }
    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.isEmpty()) { return 0 }
        let descriptor = this.beginIo()
        var nativeBuffer = CPointer<Byte>()
        try {
            let capacity = min(buffer.size, 65536)
            nativeBuffer = LibC.malloc<Byte>(count: capacity)
            if (nativeBuffer.isNull()) { throw Exception("owned_process_read_failed") }
            while (true) {
                // Native storage remains stable while the syscall blocks; no managed array is pinned.
                let count = unsafe { managedPosixRead(descriptor, nativeBuffer, UIntNative(capacity)) }
                if (count >= 0) {
                    for (index in 0..Int64(count)) { buffer[index] = unsafe { nativeBuffer.read(index) } }
                    return Int64(count)
                }
                if (unsafe { __error().read() } != 4) { throw Exception("owned_process_read_failed") }
            }
            throw Exception("owned_process_read_failed")
        } finally { unsafe { LibC.free(nativeBuffer) }; this.endIo() }
    }
    public func write(buffer: Array<Byte>): Unit {
        if (buffer.isEmpty()) { return }
        let descriptor = this.beginIo()
        var nativeBuffer = CPointer<Byte>()
        try {
            let capacity = min(buffer.size, 65536)
            nativeBuffer = LibC.malloc<Byte>(count: capacity)
            if (nativeBuffer.isNull()) { throw Exception("owned_process_write_failed") }
            var offset: Int64 = 0
            while (offset < buffer.size) {
                let chunk = min(capacity, buffer.size - offset)
                for (index in 0..chunk) { unsafe { nativeBuffer.write(index, buffer[offset + index]) } }
                var written: Int64 = 0
                while (written < chunk) {
                    let count = unsafe { managedPosixWrite(descriptor, nativeBuffer + written, UIntNative(chunk - written)) }
                    if (count > 0) { written += Int64(count) }
                    else if (count == 0 || unsafe { __error().read() } != 4) { throw Exception("owned_process_write_failed") }
                }
                offset += chunk
            }
        } finally { unsafe { LibC.free(nativeBuffer) }; this.endIo() }
    }
    public func close(): Unit {
        synchronized(this.lock) {
            this.closed = true
            this.closeWhenIdle()
        }
    }
}

@When[os == "macOS"]
func managedNativePipeStateForTest(stream: InputStream): (Int64, Int32) {
    (stream as ManagedNativePipe).getOrThrow().snapshotForTest()
}

@When[os == "macOS"]
func managedNativeOutputPipeStateForTest(stream: OutputStream): (Int64, Int32) {
    (stream as ManagedNativePipe).getOrThrow().snapshotForTest()
}

@When[os == "macOS"]
private class ManagedNativeChild <: ManagedOwnedChild {
    private var child: Int32
    private let streams: Array<?ManagedNativePipe>
    private let lock = Mutex()
    private var exitCode = None<Int64>
    private var waitFailed = false
    public init(child: Int32, streams: Array<?ManagedNativePipe>) { this.child = child; this.streams = streams }
    func bindSpawned(pid: Int32): Unit { this.child = pid }
    public prop pid: Int64 { get() { Int64(this.child) } }
    public prop stdInPipe: OutputStream { get() { this.streams[0].getOrThrow() } }
    public prop stdOutPipe: InputStream { get() { this.streams[1].getOrThrow() } }
    public prop stdErrPipe: InputStream { get() { this.streams[2].getOrThrow() } }
    private func poll(): ?Int64 {
        synchronized(this.lock) {
            if (this.waitFailed) { throw Exception("owned_process_wait_failed") }
            if (this.exitCode.isSome()) { return this.exitCode }
            var status: Int32 = 0
            let result = unsafe { waitpid(this.child, inout status, 1) }
            if (result == this.child) {
                this.exitCode = Some(if ((status & 0x7f) == 0) { Int64((status >> 8) & 0xff) } else { Int64(status & 0x7f) })
            } else if (result < 0 && unsafe { __error().read() } != 4) {
                this.waitFailed = true
                throw Exception("owned_process_wait_failed")
            }
            this.exitCode
        }
    }
    public func isAlive(): Bool { this.poll().isNone() }
    public func wait(timeout!: ?Duration): Int64 {
        let deadline = timeout.map({ value => MonoTime.now() + value })
        while (true) {
            match (this.poll()) {
                case Some(code) => return code
                case None => ()
            }
            if (deadline.isSome() && MonoTime.now() >= deadline.getOrThrow()) { throw TimeoutException("owned_process_wait_timeout") }
            sleep(Duration.millisecond * 5)
        }
        throw Exception("owned_process_wait_failed")
    }
    public func terminate(force!: Bool): Unit {
        synchronized(this.lock) {
            if (this.waitFailed) { throw Exception("owned_process_wait_failed") }
            if (this.exitCode.isNone() && unsafe { kill(this.child, if (force) { Int32(9) } else { Int32(15) }) } != 0 &&
                unsafe { __error().read() } != 3) { throw Exception("owned_process_signal_failed") }
        }
    }
    public func closeInput(): Unit { match (this.streams[0]) { case Some(value) => value.close() case None => () } }
    public func closeStreams(): Unit {
        for (stream in this.streams) { match (stream) { case Some(value) => value.close() case None => () } }
    }
    public func streamsAreClosed(): Bool {
        for (stream in this.streams) { if (let Some(value) <- stream) { if (!value.fullyClosed()) { return false } } }
        true
    }
}

@When[os == "macOS"]
private func managedNativeStrings(values: Array<String>, failAllocation!: Bool = false): CPointer<CString> {
    let result = if (failAllocation) { CPointer<CString>() }
        else { unsafe { LibC.malloc<CString>(count: values.size + 1) } }
    if (result.isNull()) { throw Exception("owned_process_allocation_failed") }
    unsafe { for (index in 0..=values.size) { result.write(index, CString(CPointer<Byte>())) } }
    try {
        for (index in 0..values.size) {
            if (values[index].contains("\u{0}")) { throw Exception("owned_process_invalid_argument") }
            unsafe { result.write(index, LibC.mallocCString(values[index])) }
        }
        result
    } catch (error: Exception) { managedNativeFreeStrings(result, values.size); throw error }
}

@When[os == "macOS"]
private func managedNativeFreeStrings(values: CPointer<CString>, count: Int64): Unit {
    if (values.isNull()) { return }
    unsafe { for (index in 0..count) { LibC.free(values.read(index)) }; LibC.free(values) }
}

@When[os == "macOS"]
private func managedNativePipePair(): (Int32, Int32) {
    var pair = VArray<Int32, $2>(repeat: -1)
    if (unsafe { pipe(inout pair) } != 0) { throw Exception("owned_process_pipe_failed") }
    try {
        for (index in 0..2) {
            if (pair[index] < 3) {
                let replacement = unsafe { fcntl(pair[index], 67, Int32(3)) }
                if (replacement < 0) { throw Exception("owned_process_pipe_failed") }
                let _ = unsafe { close(pair[index]) }; pair[index] = replacement
            }
            if (unsafe { fcntl(pair[index], 2, Int32(1)) } != 0 || (unsafe { fcntl(pair[index], 1) } & 1) != 1) {
                throw Exception("owned_process_pipe_flags_failed")
            }
        }
        if (unsafe { fcntl(pair[1], 73, Int32(1)) } != 0) { throw Exception("owned_process_pipe_flags_failed") }
        (pair[0], pair[1])
    } catch (error: Exception) {
        for (index in 0..2) { if (pair[index] >= 0) { let _ = unsafe { close(pair[index]) } } }
        throw error
    }
}

@When[os == "macOS"]
private func managedNativeExecSearch(command: String, arguments: Array<String>, environment: Map<String, String>,
    actions: CPointer<Unit>, attributes: CPointer<Unit>, argv: CPointer<CString>, envp: CPointer<CString>): (Int32, Int32) {
    let candidates = ArrayList<String>()
    if (command.contains("/")) { candidates.add(command) } else {
        let searchPath = environment.get("PATH").getOrDefault({ => "/usr/bin:/bin" })
        let directories = if (searchPath.isEmpty()) { [""] } else { searchPath.split(":") }
        for (directory in directories) {
            candidates.add("${if (directory.isEmpty()) { "." } else { directory }}/${command}")
        }
    }
    var denied = false
    var actionValue = actions; var attributeValue = attributes
    for (candidate in candidates) {
        let path = unsafe { LibC.mallocCString(candidate) }
        var pid: Int32 = 0
        let result = try { unsafe { posix_spawn(inout pid, path, inout actionValue, inout attributeValue, argv, envp) } }
            finally { unsafe { LibC.free(path) } }
        if (result == 0) { return (result, pid) }
        if (result == 8) {
            let shellArguments = ArrayList<String>(["/bin/sh", candidate]); shellArguments.add(all: arguments)
            let shellArgv = managedNativeStrings(shellArguments.toArray())
            try {
                let status = unsafe { posix_spawn(inout pid, shellArgv.read(), inout actionValue, inout attributeValue, shellArgv, envp) }
                return (status, pid)
            } finally { managedNativeFreeStrings(shellArgv, shellArguments.size) }
        }
        if (result == 13) { denied = true }
        else if (result != 2 && result != 20) { return (result, pid) }
    }
    (if (denied) { Int32(13) } else { Int32(2) }, Int32(0))
}

enum ManagedNativeLaunchFault {
    NoFault | InvalidProcessGroup | InvalidDupAction | AfterSpawnSetup | ArgumentsAllocation | EnvironmentAllocation
}

@When[os == "macOS"]
func managedNativeLaunch(command: String, arguments: Array<String>, workingDirectory: ?Path,
    environment: ?Map<String, String>, redirects: Array<ProcessRedirect>,
    fault!: ManagedNativeLaunchFault = ManagedNativeLaunchFault.NoFault,
    detachedProcessGroup!: Bool = true): ManagedOwnedChild {
    var actions = CPointer<Unit>(); var attributes = CPointer<Unit>()
    var actionsReady = false; var attributesReady = false; var transferred = false
    var launched = None<ManagedOwnedChild>
    let descriptors = ArrayList<Int32>(); let retained = ArrayList<Int32>()
    var argv = CPointer<CString>(); var envp = CPointer<CString>()
    let args = ArrayList<String>([command]); args.add(all: arguments)
    let variables = environment.getOrDefault({ => HashMap<String, String>(getVariables()) })
    let entries = ArrayList<String>()
    for ((key, value) in variables) {
        if (key.contains("=") || key.contains("\u{0}") || value.contains("\u{0}")) { throw Exception("owned_process_invalid_environment") }
        entries.add("${key}=${value}")
    }
    var nullPath = unsafe { LibC.mallocCString("/dev/null") }
    var cwd = CString(CPointer<Byte>())
    try {
        let failArguments = match (fault) { case ManagedNativeLaunchFault.ArgumentsAllocation => true case _ => false }
        argv = managedNativeStrings(args.toArray(), failAllocation: failArguments)
        let failEnvironment = match (fault) { case ManagedNativeLaunchFault.EnvironmentAllocation => true case _ => false }
        envp = managedNativeStrings(entries.toArray(), failAllocation: failEnvironment)
        if (unsafe { posix_spawn_file_actions_init(inout actions) } != 0) { throw Exception("owned_process_actions_failed") }
        actionsReady = true
        if (unsafe { posix_spawnattr_init(inout attributes) } != 0) { throw Exception("owned_process_attributes_failed") }
        attributesReady = true
        let flags: Int16 = if (detachedProcessGroup) { 0x4002 } else { 0x4000 }
        if ((detachedProcessGroup && unsafe { posix_spawnattr_setpgroup(inout attributes, 0) } != 0) ||
            unsafe { posix_spawnattr_setflags(inout attributes, flags) } != 0) { throw Exception("owned_process_attributes_failed") }
        for (index in 0..3) {
            match (redirects[index]) {
                case ProcessRedirect.Pipe =>
                    let pair = managedNativePipePair(); descriptors.add(pair[0]); descriptors.add(pair[1])
                    let source = if (index == 0) { pair[0] } else { pair[1] }
                    retained.add(if (index == 0) { pair[1] } else { pair[0] })
                    if (unsafe { posix_spawn_file_actions_adddup2(inout actions, source, Int32(index)) } != 0) { throw Exception("owned_process_actions_failed") }
                case ProcessRedirect.Inherit =>
                    retained.add(-1)
                    let flags = unsafe { fcntl(Int32(index), 1) }
                    if (flags < 0) {
                        if (unsafe { __error().read() } != 9 ||
                            unsafe { posix_spawn_file_actions_addopen(inout actions, Int32(index), nullPath,
                                if (index == 0) { Int32(0) } else { Int32(1) }, UInt16(0)) } != 0) {
                            throw Exception("owned_process_actions_failed")
                        }
                    } else if (unsafe { posix_spawn_file_actions_adddup2(inout actions, Int32(index), Int32(index)) } != 0) {
                        throw Exception("owned_process_actions_failed")
                    }
                case ProcessRedirect.Discard =>
                    retained.add(-1)
                    if (unsafe { posix_spawn_file_actions_addopen(inout actions, Int32(index), nullPath, if (index == 0) { Int32(0) } else { Int32(1) }, UInt16(0)) } != 0) { throw Exception("owned_process_actions_failed") }
                case ProcessRedirect.FromFile(file) =>
                    let descriptor = file.fileDescriptor.fileHandle
                    if (file.isClosed() || descriptor < 0 || descriptor > IntNative(Int32.Max)) {
                        throw Exception("owned_process_actions_failed")
                    }
                    retained.add(-1)
                    if (unsafe { posix_spawn_file_actions_adddup2(inout actions, Int32(descriptor), Int32(index)) } != 0) {
                        throw Exception("owned_process_actions_failed")
                    }
            }
        }
        match (fault) {
            case ManagedNativeLaunchFault.NoFault | ManagedNativeLaunchFault.AfterSpawnSetup => ()
            case ManagedNativeLaunchFault.ArgumentsAllocation | ManagedNativeLaunchFault.EnvironmentAllocation =>
                throw Exception("owned_process_fault_not_rejected")
            case ManagedNativeLaunchFault.InvalidProcessGroup =>
                if (unsafe { posix_spawnattr_setpgroup(inout attributes, -1) } != 0) {
                    throw Exception("owned_process_attributes_failed")
                }
            case ManagedNativeLaunchFault.InvalidDupAction =>
                if (unsafe { posix_spawn_file_actions_adddup2(inout actions, -1, 0) } == 0) {
                    throw Exception("owned_process_fault_not_rejected")
                }
                throw Exception("owned_process_actions_failed")
        }
        match (workingDirectory) {
            case Some(path) =>
                cwd = unsafe { LibC.mallocCString(path.toString()) }
                if (path.toString().contains("\u{0}") || unsafe { posix_spawn_file_actions_addchdir_np(inout actions, cwd) } != 0) { throw Exception("owned_process_directory_failed") }
            case None => ()
        }
        let streams = Array<?ManagedNativePipe>(3, repeat: None)
        for (index in 0..3) { if (retained[index] >= 3) { streams[index] = Some(ManagedNativePipe(retained[index])) } }
        let prepared = ManagedNativeChild(0, streams)
        let spawned = managedNativeExecSearch(command, arguments, variables, actions, attributes, argv, envp)
        let spawnStatus = spawned[0]
        let pid = spawned[1]
        if (spawnStatus == 0 && pid > 1) {
            prepared.bindSpawned(pid)
            launched = Some(prepared)
            transferred = true
        }
        match (fault) {
            case ManagedNativeLaunchFault.InvalidProcessGroup =>
                if (spawnStatus != 22 || pid > 1) { throw Exception("owned_process_fault_not_rejected") }
                throw Exception("owned_process_attributes_failed")
            case _ => ()
        }
        if (spawnStatus != 0) { throw ManagedNativeSpawnException(spawnStatus) }
        if (pid <= 1) { throw ManagedNativeSpawnUnknownException() }
        match (fault) {
            case ManagedNativeLaunchFault.AfterSpawnSetup =>
                if (let Some(output) <- streams[1]) {
                    let ready = Array<Byte>(1, repeat: 0)
                    if (output.read(ready) != 1) { throw Exception("owned_process_setup_fixture_not_ready") }
                }
                throw Exception("owned_process_setup_failed")
            case _ => ()
        }
        prepared
    } catch (error: Exception) {
        if (let Some(child) <- launched) {
            let birth = observeProcessBirthIdentity(child.pid)
            try { child.terminate(); let _ = child.wait(timeout: Some(Duration.second * 3)) } catch (_: Exception) { () }
            child.closeStreams()
            throw ManagedNativeSetupException(child, birth)
        }
        throw error
    } finally {
        for (descriptor in descriptors) { if (!transferred || !retained.contains(descriptor)) { let _ = unsafe { close(descriptor) } } }
        if (attributesReady) { let _ = unsafe { posix_spawnattr_destroy(inout attributes) } }
        if (actionsReady) { let _ = unsafe { posix_spawn_file_actions_destroy(inout actions) } }
        managedNativeFreeStrings(argv, args.size); managedNativeFreeStrings(envp, entries.size)
        unsafe { LibC.free(nullPath); LibC.free(cwd) }
    }
}

/** Already registered supervisor, or an explicit new-generation launch; never an unregistered business child. */
public func launchManagedRawChild(command: String, arguments: Array<String>, workingDirectory!: ?Path = None,
    environment!: ?Map<String, String> = None, stdIn!: ProcessRedirect = ProcessRedirect.Inherit,
    stdOut!: ProcessRedirect = ProcessRedirect.Inherit, stdErr!: ProcessRedirect = ProcessRedirect.Inherit,
    newGeneration!: Bool = false): ManagedOwnedChild {
    managedLaunchPlatformChild(command, arguments, workingDirectory, environment, [stdIn, stdOut, stdErr], newGeneration)
}

@When[os == "macOS"]
private func managedLaunchPlatformChild(command: String, args: Array<String>, cwd: ?Path, environment: ?Map<String, String>, redirects: Array<ProcessRedirect>, newGeneration: Bool): ManagedOwnedChild {
    if (newGeneration || !managedRecoveryContext()[0].isEmpty()) { return managedNativeLaunch(command, args, cwd, environment, redirects) }
    managedValidateCaptureArguments(command, args, cwd, environment)
    if (command.isEmpty()) { throw ProcessException("owned_process_launch_failed") }
    managedLaunchWithoutContext(command, args, cwd, environment, redirects)
}

@When[os != "macOS"]
private func managedLaunchPlatformChild(command: String, args: Array<String>, cwd: ?Path, environment: ?Map<String, String>, redirects: Array<ProcessRedirect>, _newGeneration: Bool): ManagedOwnedChild {
    ManagedSdkChild(launch(command, args, workingDirectory: cwd, environment: environment, stdIn: redirects[0], stdOut: redirects[1], stdErr: redirects[2]), redirects)
}

@When[os == "macOS"]
private func managedLaunchContextChild(command: String, args: Array<String>, cwd: ?Path,
    environment: ?Map<String, String>, redirects: Array<ProcessRedirect>, fault: ManagedNativeLaunchFault): ManagedOwnedChild {
    managedNativeLaunch(command, args, cwd, environment, redirects, fault: fault)
}

@When[os != "macOS"]
private func managedLaunchContextChild(command: String, args: Array<String>, cwd: ?Path,
    environment: ?Map<String, String>, redirects: Array<ProcessRedirect>, _fault: ManagedNativeLaunchFault): ManagedOwnedChild {
    managedLaunchPlatformChild(command, args, cwd, environment, redirects, true)
}

private class ManagedOwnedGeneration {
    let lock = Mutex()
    var closing = false
    var launching: Int64 = 0
    let children = HashMap<Int64, ManagedOwnedChild>()
}

private let managedOwnedGenerationsLock = Mutex()
private let managedOwnedGenerations = HashMap<String, ManagedOwnedGeneration>()

private func managedOwnedGeneration(context: (String, String)): ManagedOwnedGeneration {
    synchronized(managedOwnedGenerationsLock) {
        if (!managedOwnedGenerations.contains(context[0])) {
            managedOwnedGenerations[context[0]] = ManagedOwnedGeneration()
        }
        managedOwnedGenerations[context[0]]
    }
}

/** Admission and handle ownership share the existing generation, not a new scheduler. */
public func managedRecoveryCloseOwnedAdmission(context: (String, String)): Unit {
    if (context[0].isEmpty()) { return }
    let generation = managedOwnedGeneration(context)
    synchronized(generation.lock) { generation.closing = true }
}

public func managedRecoveryStopOwnedChildren(context: (String, String), deadline: MonoTime): Bool {
    if (context[0].isEmpty()) { return true }
    managedRecoveryCloseOwnedAdmission(context)
    let generation = managedOwnedGeneration(context)
    while (MonoTime.now() < deadline) {
        let (launching, children) = synchronized(generation.lock) {
            (generation.launching, generation.children.values().toArray())
        }
        if (launching == 0 && children.isEmpty()) { return true }
        for (child in children) { try { child.terminate() } catch (_: Exception) { () } }
        for (child in children) {
            if (MonoTime.now() >= deadline) { return false }
            try {
                let _ = child.wait(timeout: Some(deadline - MonoTime.now()))
                child.closeStreams()
            } catch (_: Exception) { () }
        }
        sleep(Duration.millisecond * 5)
    }
    synchronized(generation.lock) { generation.launching == 0 && generation.children.isEmpty() }
}

private class ManagedRecoveryChild <: ManagedOwnedChild {
    private let child: ManagedOwnedChild
    private let context: (String, String)
    private let key: String
    private let binding: String
    private let generation: ManagedOwnedGeneration
    private let completionLock = Mutex()
    private var completed = None<Int64>
    private var execError = None<ManagedRecoveryExecError>
    public init(child: ManagedOwnedChild, context: (String, String), key: String, binding: String, generation: ManagedOwnedGeneration) {
        this.child = child; this.context = context; this.key = key; this.binding = binding; this.generation = generation
    }
    public prop pid: Int64 { get() { this.child.pid } }
    public prop stdInPipe: OutputStream { get() { this.child.stdInPipe } }
    public prop stdOutPipe: InputStream { get() { this.child.stdOutPipe } }
    public prop stdErrPipe: InputStream { get() { this.child.stdErrPipe } }
    public func isAlive(): Bool { this.child.isAlive() }
    public func wait(timeout!: ?Duration): Int64 {
        let cached = synchronized(this.completionLock) { this.completed }
        if (cached.isSome()) { return cached.getOrThrow() }
        let code = this.child.wait(timeout: timeout)
        synchronized(this.completionLock) {
            if (this.completed.isNone()) {
                let outcome = managedRecoveryReadExecError(Path(this.context[0]), this.context[1], this.binding, "${this.key}-o-1")
                let original = outcome.map({ value => value.originalText }).getOrDefault({ => "" })
                if (!managedRecoveryRetireRoot(this.context, this.key, this.child.pid,
                    expectedBinding: Some(this.binding), expectedExecText: Some(original))) {
                    throw Exception("owned_process_terminal_evidence_pending")
                }
                this.execError = outcome
                this.completed = Some(code)
            }
            this.completed.getOrThrow()
        }
    }
    public func checkCaptureOutcome(): Unit {
        let outcome = synchronized(this.completionLock) { this.execError }
        if (let Some(failed) <- outcome) {
            if (failed.phase == "exec" || failed.phase == "spawn") { throw ProcessException("owned_process_launch_failed") }
            throw Exception("owned_process_exec_outcome_unknown")
        }
    }
    // The helper owns TERM->KILL of its business group. Force-killing that helper
    // would lose the only cleanup owner, so cancellation always requests helper TERM.
    public func terminate(force!: Bool): Unit { this.child.terminate(force: false) }
    public func closeStreams(): Unit {
        this.child.closeStreams()
        let reaped = synchronized(this.completionLock) { this.completed.isSome() }
        if (reaped && this.child.streamsAreClosed()) {
            synchronized(this.generation.lock) { this.generation.children.remove(this.pid) }
        }
    }
    public func streamsAreClosed(): Bool { this.child.streamsAreClosed() }
    public func closeInput(): Unit { this.child.closeInput() }
}

/** Preserve only the Darwin runtime-mutated key across the private attached Node hop. */
@When[os == "macOS"]
public func managedRecoveryPrepareAttachedEnvironment(environment: HashMap<String, String>): Unit {
    let marker = "METIS_STDIO_ATTACHED_CF_ENV_V1"
    let cf = "__CF_USER_TEXT_ENCODING"
    if ((environment.contains(cf) && environment[cf].contains("\u{0}")) ||
        (environment.contains(marker) && environment[marker].contains("\u{0}"))) {
        throw IllegalArgumentException("owned_process_invalid_environment")
    }
    let witness = JsonArray()
    witness.add(JsonInt(1))
    witness.add(JsonBool(environment.contains(cf)))
    witness.add(JsonString(if (environment.contains(cf)) { environment[cf] } else { "" }))
    witness.add(JsonBool(environment.contains(marker)))
    witness.add(JsonString(if (environment.contains(marker)) { environment[marker] } else { "" }))
    environment[marker] = witness.toJsonString()
}

@When[os != "macOS"]
public func managedRecoveryPrepareAttachedEnvironment(_environment: HashMap<String, String>): Unit { () }

/** Binds watchdog to the current native parent before any helper is spawned. */
public func managedRecoveryBindHelperParent(environment: HashMap<String, String>): Unit {
    let identity = currentProcessInstanceIdentity().getOrThrow()
    let birth = observeProcessBirthIdentity(identity.pid).getOrThrow()
    environment["METIS_PROCESS_RECOVERY_OWNER_PID"] = identity.pid.toString()
    environment["METIS_PROCESS_RECOVERY_OWNER_BIRTH"] = birth.serialize()
}

/** Same stdio contract as SDK launch; only context-bearing resources enter recovery ownership. */
public func managedRecoveryLaunchOwned(command: String, arguments: Array<String>, workingDirectory!: ?Path = None,
    environment!: ?Map<String, String> = None, stdIn!: ProcessRedirect = ProcessRedirect.Inherit,
    stdOut!: ProcessRedirect = ProcessRedirect.Inherit, stdErr!: ProcessRedirect = ProcessRedirect.Inherit): ManagedOwnedChild {
    managedRecoveryLaunchInContext(managedRecoveryContext(), command, arguments, workingDirectory, environment, stdIn, stdOut, stdErr)
}

func managedRecoveryLaunchInContext(context: (String, String), command: String, arguments: Array<String>,
    workingDirectory: ?Path, environment: ?Map<String, String>, stdIn: ProcessRedirect,
    stdOut: ProcessRedirect, stdErr: ProcessRedirect,
    fault!: ManagedNativeLaunchFault = ManagedNativeLaunchFault.NoFault): ManagedOwnedChild {
    // Validation precedes context admission and native creation, preserving SDK exception precedence.
    managedValidateCaptureArguments(command, arguments, workingDirectory, environment)
    if (command.isEmpty()) { throw ProcessException("owned_process_launch_failed") }
    if (context[0].isEmpty()) {
        return managedLaunchWithoutContext(command, arguments, workingDirectory, environment, [stdIn, stdOut, stdErr])
    }
    let generation = managedOwnedGeneration(context)
    synchronized(generation.lock) {
        if (generation.closing) { throw Exception("process_recovery_generation_closing") }
        generation.launching += 1
    }
    var key = ""
    var child = None<ManagedOwnedChild>
    try {
        let binding = managedRecoveryBinding(context)
        let brokerScript = try {
            let configured = managedStdioResolveBrokerScriptPath()
            if (configured.isEmpty()) { throw Exception("owned_process_internal_asset_invalid") }
            let path = canonicalize(Path(configured))
            if (!FileInfo(path).isRegular()) { throw Exception("owned_process_internal_asset_invalid") }
            path.toString()
        } catch (_: Exception) { throw Exception("owned_process_internal_asset_invalid") }
        let variables = HashMap<String, String>(environment.getOrDefault({ => HashMap<String, String>(getVariables()) }))
        managedRecoveryPrepareAttachedEnvironment(variables)
        key = managedRecoveryNativeIntent(context: context)
        variables["METIS_PROCESS_RECOVERY_DIRECTORY"] = context[0]
        variables["METIS_PROCESS_RECOVERY_PARENT"] = context[1]
        variables["METIS_PROCESS_RECOVERY_BROKER_KEY"] = key
        managedRecoveryBindHelperParent(variables)
        let args = ArrayList<String>([brokerScript, "--attached", command])
        args.add(all: arguments)
        let launched = managedLaunchContextChild(managedStdioResolveNodeCommand(), args.toArray(),
            workingDirectory, Some<Map<String, String>>(variables), [stdIn, stdOut, stdErr], fault)
        child = Some(launched)
        if (!managedRecoveryCommitAttachedLaunch(Path(context[0]), key, context[1])) {
            throw Exception("owned_process_recovery_handshake_failed")
        }
        let owned = ManagedRecoveryChild(launched, context, key, binding, generation)
        synchronized(generation.lock) { generation.children[owned.pid] = owned }
        return owned
    } catch (error: Exception) {
        if (let Some(spawned) <- (error as ManagedNativeSetupException)) {
            child = Some(spawned.child)
            let _ = managedRecoveryNativeSpawned(key, spawned.child.pid, 0, context: context)
            if (let Some(birth) <- spawned.birth) {
                let _ = managedRecoveryPublishFact(Path(context[0]), key, "birth", context[1],
                    pid: spawned.child.pid, birth: birth.serialize())
            }
        }
        match (child) {
            case Some(value) =>
                try { value.terminate(); let _ = value.wait(timeout: Some(Duration.second * 5)); let _ = managedRecoveryRetireObservedHelper(key, context) }
                catch (_: Exception) { () }
                value.closeStreams()
            case None =>
                if ((error as ManagedNativeSpawnUnknownException).isNone()) {
                    managedRecoveryNativeTerminal(key, 0, 0, false, true, context: context)
                }
        }
        throw error
    } finally { synchronized(generation.lock) { generation.launching -= 1 } }
}

private func managedOwnedReadAll(stream: InputStream): Array<Byte> {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { return bytes.toArray() }
        bytes.add(all: buffer[..count])
    }
    bytes.toArray()
}

private func managedValidateCaptureArguments(command: String, arguments: Array<String>, workingDirectory: ?Path,
    environment: ?Map<String, String>): Unit {
    if (command.contains("\u{0}")) { throw IllegalArgumentException("owned_process_invalid_argument") }
    for (argument in arguments) {
        if (argument.contains("\u{0}")) { throw IllegalArgumentException("owned_process_invalid_argument") }
    }
    if (let Some(variables) <- environment) {
        for ((key, value) in variables) {
            if (key.contains("=") || key.contains("\u{0}") || value.contains("\u{0}")) {
                throw IllegalArgumentException("owned_process_invalid_environment")
            }
        }
    }
    if (let Some(path) <- workingDirectory) {
        try {
            if (!FileInfo(path).isDirectory()) { throw IllegalArgumentException("owned_process_directory_failed") }
        } catch (_: FSException) { throw IllegalArgumentException("owned_process_directory_failed") }
    }
}

@When[os == "macOS"]
private func managedCaptureWithoutContext(command: String, arguments: Array<String>, workingDirectory: ?Path,
    environment: ?Map<String, String>): (Int64, Array<Byte>, Array<Byte>) {
    managedValidateCaptureArguments(command, arguments, workingDirectory, environment)
    let child = try {
        managedNativeLaunch(command, arguments, workingDirectory, environment,
            [ProcessRedirect.Inherit, ProcessRedirect.Pipe, ProcessRedirect.Pipe], detachedProcessGroup: false)
    } catch (error: Exception) {
        if ((error as ManagedNativeSpawnUnknownException).isSome() || (error as ManagedNativeSetupException).isSome()) { throw error }
        throw ProcessException("owned_process_launch_failed")
    }
    managedOwnedCapture(child)
}

@When[os != "macOS"]
private func managedCaptureWithoutContext(command: String, arguments: Array<String>, workingDirectory: ?Path,
    environment: ?Map<String, String>): (Int64, Array<Byte>, Array<Byte>) {
    executeWithOutput(command, arguments, workingDirectory: workingDirectory, environment: environment)
}

/** Unlimited byte capture and no implicit deadline, matching the original SDK entry. */
public func managedRecoveryExecuteWithOutput(command: String, arguments: Array<String>,
    workingDirectory!: ?Path = None, environment!: ?Map<String, String> = None): (Int64, Array<Byte>, Array<Byte>) {
    if (managedRecoveryContext()[0].isEmpty()) {
        return managedCaptureWithoutContext(command, arguments, workingDirectory, environment)
    }
    managedValidateCaptureArguments(command, arguments, workingDirectory, environment)
    // libc rejects an empty immutable command before PATH or filesystem lookup.
    if (command.isEmpty()) { throw ProcessException("owned_process_launch_failed") }
    let child = try {
        managedRecoveryLaunchOwned(command, arguments, workingDirectory: workingDirectory, environment: environment,
            stdIn: ProcessRedirect.Inherit, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
    } catch (_: ManagedNativeSpawnException) { throw ProcessException("owned_process_launch_failed") }
    let output = managedOwnedCapture(child)
    if (let Some(owned) <- (child as ManagedRecoveryChild)) { owned.checkCaptureOutcome() }
    output
}

/** Command-result semantics without changing the raw owned handle's wait/cache contract. */
public func managedRecoveryWaitForCommand(child: ManagedOwnedChild, timeout!: ?Duration = None): Int64 {
    let code = child.wait(timeout: timeout)
    if (let Some(owned) <- (child as ManagedRecoveryChild)) { owned.checkCaptureOutcome() }
    code
}

/** Explicit OS handoff: clear the old generation, retain raw native inheritance safety. */
public func managedRecoveryExecuteHandoffWithOutput(command: String, arguments: Array<String>,
    workingDirectory!: ?Path = None): (Int64, Array<Byte>, Array<Byte>) {
    if (managedRecoveryContext()[0].isEmpty()) {
        return managedCaptureWithoutContext(command, arguments, workingDirectory, None)
    }
    let environment = HashMap<String, String>(getVariables())
    for (name in ["METIS_PROCESS_RECOVERY_DIRECTORY", "METIS_PROCESS_RECOVERY_PARENT",
        "METIS_PROCESS_RECOVERY_BROKER_KEY", "METIS_PROCESS_RECOVERY_OWNER_PID", "METIS_PROCESS_RECOVERY_OWNER_BIRTH"]) {
        environment.remove(name)
    }
    managedOwnedCapture(launchManagedRawChild(command, arguments, workingDirectory: workingDirectory,
        environment: environment, newGeneration: true, stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe))
}

private func managedOwnedCapture(child: ManagedOwnedChild): (Int64, Array<Byte>, Array<Byte>) {
    var stdout = None<Future<Array<Byte>>>
    var stderr = None<Future<Array<Byte>>>
    try {
        stdout = Some(spawn { managedOwnedReadAll(child.stdOutPipe) })
        stderr = Some(spawn { managedOwnedReadAll(child.stdErrPipe) })
        let code = child.wait()
        (code, stdout.getOrThrow().get(), stderr.getOrThrow().get())
    } finally {
        try { if (child.isAlive()) { child.terminate(); let _ = child.wait(timeout: Some(Duration.second * 5)) } }
        catch (_: Exception) { () }
        child.closeStreams()
        try { if (let Some(worker) <- stdout) { let _ = worker.get() } } catch (_: Exception) { () }
        try { if (let Some(worker) <- stderr) { let _ = worker.get() } } catch (_: Exception) { () }
    }
}
