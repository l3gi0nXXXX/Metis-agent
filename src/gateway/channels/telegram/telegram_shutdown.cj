package metis.gateway.channels.telegram

import std.collection.ArrayList
import std.net.TcpSocket
import std.sync.*
import std.time.*
import stdx.net.http.Client

// Cancellation requests are not evidence that a worker's execution body has exited.
class TelegramShutdownWorker {
    private let finished = AtomicBool(false)
    private var future: Option<Future<Unit>> = None

    func start(action: () -> Unit): Unit {
        this.future = Some(spawn {
            try {
                action()
            } finally {
                this.finished.store(true)
            }
        })
    }

    func isSettled(): Bool {
        if (!this.finished.load()) { return false }
        match (this.future) {
            case Some(worker) =>
                try { worker.tryGet().isSome() } catch (_: Exception) { true }
            case None => false
        }
    }

    func awaitUntil(deadline: MonoTime): Bool {
        if (this.isSettled()) { return true }
        let remaining = deadline - MonoTime.now()
        // Future.get(0) is an unbounded wait in the SDK.
        if (remaining <= Duration.Zero) { return false }
        match (this.future) {
            case Some(worker) =>
                try {
                    worker.get(remaining)
                } catch (_: TimeoutException) {
                    return false
                } catch (_: Exception) {
                    ()
                }
            case None => return false
        }
        this.isSettled()
    }
}

// A scope keeps both pre-handoff sockets and the HTTP client until the request and
// its asynchronous cancellation cleanup have actually finished.
class TelegramRequestScope {
    private let lock = Mutex()
    private var cancelled = false
    private var requestFinished = false
    private var client: Option<Client> = None
    private let sockets = ArrayList<TcpSocket>()
    private var cleanup: Option<TelegramShutdownWorker> = None

    func attachClient(value: Client): Bool {
        synchronized(this.lock) {
            if (!this.cancelled) {
                this.client = Some(value)
                return true
            }
        }
        try { value.close() } catch (_: Exception) { () }
        false
    }

    func attachSocket(value: TcpSocket): Bool {
        synchronized(this.lock) {
            if (!this.cancelled) {
                this.sockets.add(value)
                return true
            }
        }
        try { value.close() } catch (_: Exception) { () }
        false
    }

    func isCancelled(): Bool {
        synchronized(this.lock) { this.cancelled }
    }

    func cancel(): Unit {
        synchronized(this.lock) {
            if (this.cancelled) { return }
            this.cancelled = true
            let worker = TelegramShutdownWorker()
            this.cleanup = Some(worker)
            // Client.close may attempt TLS graceful shutdown; beginShutdown must not wait for it.
            worker.start({ => this.closeResources() })
        }
    }

    func finish(): Unit {
        try {
            this.closeResources()
        } finally {
            synchronized(this.lock) { this.requestFinished = true }
        }
    }

    func isSettled(): Bool {
        synchronized(this.lock) {
            if (!this.requestFinished) { return false }
            match (this.cleanup) {
                case Some(worker) => worker.isSettled()
                case None => true
            }
        }
    }

    private func closeResources(): Unit {
        var ownedSockets: Array<TcpSocket> = []
        var ownedClient: Option<Client> = None
        synchronized(this.lock) {
            ownedSockets = this.sockets.toArray()
            ownedClient = this.client
        }
        // Abort TCP/CONNECT/TLS IO first, including sockets not yet known to stdx's pool.
        for (socket in ownedSockets) {
            try { socket.close() } catch (_: Exception) { () }
        }
        if (let Some(value) <- ownedClient) {
            try { value.close() } catch (_: Exception) { () }
        }
    }
}

class TelegramRequestOwner {
    private let lock = Mutex()
    private var cancelled = false
    private let requests = ArrayList<TelegramRequestScope>()

    func beginRequest(): Option<TelegramRequestScope> {
        synchronized(this.lock) {
            if (this.cancelled) { return None }
            this.reapSettled()
            let request = TelegramRequestScope()
            this.requests.add(request)
            Some(request)
        }
    }

    func cancel(): Unit {
        var requests: Array<TelegramRequestScope> = []
        synchronized(this.lock) {
            this.cancelled = true
            requests = this.requests.toArray()
        }
        for (request in requests) { request.cancel() }
    }

    func isCancelled(): Bool {
        synchronized(this.lock) { this.cancelled }
    }

    func activeCount(): Int64 {
        synchronized(this.lock) {
            this.reapSettled()
            this.requests.size
        }
    }

    func awaitUntil(deadline: MonoTime): Int64 {
        while (this.activeCount() > 0 && MonoTime.now() < deadline) {
            let remaining = deadline - MonoTime.now()
            if (remaining > Duration.Zero) {
                sleep(if (remaining < Duration.millisecond * 5) { remaining } else { Duration.millisecond * 5 })
            }
        }
        this.activeCount()
    }

    private func reapSettled(): Unit {
        var i = this.requests.size
        while (i > 0) {
            i -= 1
            if (this.requests[i].isSettled()) { this.requests.remove(at: i) }
        }
    }
}
