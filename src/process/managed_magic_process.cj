package metis.process

import magic.utils.{ProcessHandle, ProcessLaunchProvider, setProcessLaunchProvider}
import std.collection.{ArrayList, HashMap, Map}
import std.env.getVariables
import std.io.{InputStream, OutputStream}
import std.process.ProcessRedirect
import std.sync.Mutex
import std.time.MonoTime

private class ManagedMagicOwnedHandle <: ProcessHandle {
    private let child: ManagedOwnedChild
    private let state = Mutex()
    private var closed = false
    private var reaped = false
    public init(child: ManagedOwnedChild) { this.child = child }
    public prop pid: Int64 { get() { this.child.pid } }
    public prop stdInPipe: OutputStream { get() { this.child.stdInPipe } }
    public prop stdOutPipe: InputStream { get() { this.child.stdOutPipe } }
    public prop stdErrPipe: InputStream { get() { this.child.stdErrPipe } }
    public func isAlive(): Bool { this.child.isAlive() }
    public func isClosed(): Bool { synchronized(this.state) { this.closed } }
    public func terminate(force!: Bool): Unit { this.child.terminate(force: force) }
    public func wait(timeout!: ?Duration): Int64 {
        let code = this.child.wait(timeout: timeout)
        synchronized(this.state) { this.reaped = true }
        this.child.closeStreams()
        this.refreshClosed()
        code
    }
    private func refreshClosed(): Unit {
        let streamsClosed = this.child.streamsAreClosed()
        synchronized(this.state) { this.closed = this.reaped && streamsClosed }
    }
    public func close(): Unit {
        let settled = this.closeUntil(MonoTime.now() + Duration.second * 3)
        if (!settled && !this.isClosed()) { throw Exception("owned_process_cleanup_pending") }
    }
    func closeUntil(deadline: MonoTime): Bool {
        if (this.isClosed()) { return true }
        try {
            try { if (this.child.isAlive()) { this.child.terminate(force: true) } } catch (_: Exception) { () }
            if (MonoTime.now() >= deadline) { return false }
            let _ = this.wait(timeout: Some(deadline - MonoTime.now()))
            this.isClosed()
        } finally { this.child.closeStreams(); this.refreshClosed() }
    }
}

/** Captures one recovery generation; refusal never falls back to an unowned SDK launch. */
private class ManagedMagicLaunchProvider <: ProcessLaunchProvider {
    private let context: (String, String)
    private let state = Mutex()
    private let children = ArrayList<ManagedMagicOwnedHandle>()
    private var closing = false
    private var launching: Int64 = 0
    public init(context: (String, String)) { this.context = context }
    public func launch(command: String, args: Array<String>, env: Array<(String, String)>, redirectErr: Bool): ProcessHandle {
        synchronized(this.state) {
            if (this.closing) { throw Exception("process_recovery_generation_closing") }
            this.launching += 1
        }
        var launched = None<ManagedOwnedChild>
        var registered = false
        try {
            let variables = HashMap<String, String>(getVariables())
            variables.add(all: env)
            let child = managedRecoveryLaunchInContext(this.context, command, args, None,
                Some<Map<String, String>>(variables), ProcessRedirect.Pipe, ProcessRedirect.Pipe,
                if (redirectErr) { ProcessRedirect.Pipe } else { ProcessRedirect.Inherit })
            launched = Some(child)
            let handle = ManagedMagicOwnedHandle(child)
            synchronized(this.state) { this.children.add(handle); registered = true }
            handle
        } finally {
            if (!registered) {
                if (let Some(child) <- launched) {
                    try { child.terminate(); let _ = child.wait(timeout: Some(Duration.second * 3)) } catch (_: Exception) { () }
                    child.closeStreams()
                }
            }
            synchronized(this.state) { this.launching -= 1 }
        }
    }
    public func fence(): Unit { synchronized(this.state) { this.closing = true } }
    public func stop(deadline: MonoTime): Bool {
        this.fence()
        while (synchronized(this.state) { this.launching > 0 }) {
            if (MonoTime.now() >= deadline) { return false }
            sleep(Duration.millisecond * 5)
        }
        let children = synchronized(this.state) { this.children.toArray() }
        var settled = true
        for (child in children) {
            if (MonoTime.now() >= deadline) { return false }
            try { let _ = child.closeUntil(deadline) } catch (_: Exception) { settled = false }
            if (!child.isClosed()) { settled = false }
        }
        settled
    }
}

/** Owns only handles returned by its provider; borrowed process-wide LSP is not adopted. */
public class ManagedMagicRecoveryLaunchScope {
    private let provider: ManagedMagicLaunchProvider
    private let previous: ?ProcessLaunchProvider
    private var restored = false
    public init(context: (String, String)) {
        this.provider = ManagedMagicLaunchProvider(context)
        this.previous = setProcessLaunchProvider(Some<ProcessLaunchProvider>(this.provider))
    }
    public func fence(): Unit { this.provider.fence() }
    public func stop(deadline: MonoTime): Bool { this.provider.stop(deadline) }
    public func restoreAfterTerminal(deadline: MonoTime): Bool {
        if (this.restored) { return true }
        if (!this.provider.stop(deadline)) { return false }
        let _ = setProcessLaunchProvider(this.previous)
        this.restored = true
        true
    }
}

public func managedRecoveryInstallMagicProcessProvider(): ?ManagedMagicRecoveryLaunchScope {
    let context = managedRecoveryContext()
    if (context[0].isEmpty()) { None<ManagedMagicRecoveryLaunchScope> }
    else { Some(ManagedMagicRecoveryLaunchScope(context)) }
}
