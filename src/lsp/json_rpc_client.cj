package metis.lsp

import metis.process.{ManagedOwnedChild, managedRecoveryLaunchOwned}

import magic.dsl.jsonable
import magic.log.LogUtils

import std.fs.{File, Path}
import std.io.*
import std.process.*
import std.convert.*
import std.collection.*
import std.collection.concurrent.ConcurrentHashMap
import std.unicode.*
import std.sync.Mutex
import stdx.encoding.json.*

private enum RPCMessageType {
    | Request(LSPRequest)
    | Response(LSPResponse)
    | Notification(LSPNotification)
}

/**
 * JSON-RPC 2.0 Client for LSP communication
 */
public class JSONRPCClient {
    private var process: ManagedOwnedChild
    private var reader: StringReader<InputStream>
    private var writer: StringWriter<OutputStream>
    private var nextId: Int64 = 1
    private let pendingRequests = ConcurrentHashMap<Int64, Promise<JsonValue>>()
    private var workerFuture: Option<Future<Unit>> = None
    private var stderrFuture: Option<Future<Unit>> = None
    private let sendLock = Mutex()
    private let writerLock = Mutex()
    private let cleanupLock = Mutex()
    private var shutdownFuture = None<Future<Bool>>
    private var closing = false
    private var closed = false
    private var receiverStopped = false
    private var receiverStatus = ""

    public init(serverPath: String, serverArgs!: Array<String> = Array<String>()) {
        var launched = None<ManagedOwnedChild>
        try {
            let child = managedRecoveryLaunchOwned(serverPath, serverArgs,
                stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
            launched = Some(child)
            this.process = child
            this.reader = StringReader<InputStream>(child.stdOutPipe)
            this.writer = StringWriter(child.stdInPipe)
            this.stderrFuture = Some(spawn {
                let buffer = Array<Byte>(8192, repeat: 0)
                try { while (child.stdErrPipe.read(buffer) > 0) { () } } catch (_: Exception) { () }
            })
            this.workerFuture = Some(spawn { this.doReceiving() })
        } catch (_: Exception) {
            if (let Some(child) <- launched) {
                try { child.terminate(force: true); let _ = child.wait(timeout: Some(Duration.second * 2)) }
                catch (_: Exception) { () }
                child.closeStreams()
                if (let Some(worker) <- this.stderrFuture) { try { let _ = worker.get(Duration.second * 2) } catch (_: Exception) { () } }
            }
            throw Exception("lsp_process_initialization_failed")
        }
    }

    public func sendRequest(method: String, params!: Option<JsonObject> = None): JsonValue {
        this.sendRequestInternal(method, params, false)
    }

    private func sendRequestInternal(method: String, params: ?JsonObject, shutdown: Bool): JsonValue {
        let promise = Promise<JsonValue>()
        let reservation = synchronized(this.sendLock) {
            if (this.closed || this.receiverStopped || (this.closing && !shutdown)) { throw Exception("lsp_client_closed") }
            let requestId = this.nextId
            this.nextId += 1
            let text = LSPRequest(id: requestId, method: method, params: params).toJsonValue().toString()
            this.pendingRequests.add(requestId, promise)
            (requestId, text)
        }
        try {
            synchronized(this.writerLock) {
                synchronized(this.sendLock) {
                    if (this.closed || this.receiverStopped || (this.closing && !shutdown)) { throw Exception("lsp_client_closed") }
                }
                this.writer.write("Content-Length: ${reservation[1].toArray().size}\r\n\r\n")
                this.writer.write(reservation[1])
                this.writer.flush()
            }
        } catch (_: Exception) {
            synchronized(this.sendLock) {
                this.pendingRequests.remove(reservation[0])
                promise.reject("lsp_request_send_failed")
            }
        }
        promise.get()
    }

    public func sendNotification(method: String, params!: Option<JsonObject> = None): Unit {
        synchronized(this.writerLock) {
            synchronized(this.sendLock) {
                if (this.closed || this.closing) { throw Exception("lsp_client_closed") }
            }
            this.writeNotification(method, params)
        }
    }

    private func writeNotification(method: String, params: ?JsonObject): Unit {
        let text = LSPNotification(method: method, params: params).toJsonValue().toString()
        this.writer.write("Content-Length: ${text.toArray().size}\r\n\r\n")
        this.writer.write(text)
        this.writer.flush()
    }

    private func rejectPending(): Unit {
        for ((id, promise) in this.pendingRequests) {
            this.pendingRequests.remove(id)
            promise.reject("lsp_receiver_closed")
        }
    }

    private func doReceiving(): Unit {
        try {
            while (true) { this.handleMessage(this.parseMessage(this.readMessage())) }
        } catch (error: Exception) {
            synchronized(this.sendLock) {
                this.receiverStopped = true
                this.receiverStatus = if (error.message == "lsp_invalid_response_encoding" || error.message == "lsp_malformed_json" || error.message == "lsp_response_eof") {
                    error.message
                } else { "lsp_receiver_closed" }
                this.rejectPending()
            }
        }
    }

    private func readMessage(): JsonValue {
        try {
            // Read headers first
            var contentLength: Option<Int64> = None

            while (true) {
                let line = this.readLine()
                if (line.isEmpty()) {
                    break
                }

                if (line.startsWith("Content-Length:")) {
                    let lengthStr = line["Content-Length:".size..].trimAsciiStart()
                    contentLength = Int64.parse(lengthStr)
                }
            }

            match (contentLength) {
                case Some(length) =>
                    // Read the JSON content
                    let content = this.readContent(length)
                    return try { JsonValue.fromStr(content) } catch (_: Exception) { throw Exception("lsp_malformed_json") }
                case _ =>
                    throw Exception("Missing Content-Length header in LSP response")
            }
        } catch (ex: Exception) {
            if (ex.message == "lsp_invalid_response_encoding" || ex.message == "lsp_malformed_json" || ex.message == "lsp_response_eof") { throw ex }
            throw Exception("lsp_response_failed")
        }
    }

    private func parseMessage(jsonValue: JsonValue): RPCMessageType {
        // Validate JSON-RPC version
        let jo = jsonValue.asObject()

        if (((jo.get("jsonrpc")?.asString())?.getValue() ?? "") != "2.0") {
            throw Exception("Unsupported JSON-RPC version")
        }

        // Determine message type
        if (jo.containsKey("method")) {
            if (jo.containsKey("id")) {
                return RPCMessageType.Request(LSPRequest.fromJsonValue(jsonValue))
            } else {
                return RPCMessageType.Notification(LSPNotification.fromJsonValue(jsonValue))
            }
        } else if (jo.containsKey("id")) {
            return RPCMessageType.Response(LSPResponse.fromJsonValue(jsonValue))
        } else {
            throw Exception("Unknown message type: {data}")
        }
    }

    // Handle an incoming message
    private func handleMessage(message: RPCMessageType): Unit {
        match (message) {
            case RPCMessageType.Request(request) =>
                this.handleServerRequest(request)
            case RPCMessageType.Response(response) =>
                this.handleServerResponse(response)
            case RPCMessageType.Notification(notification) =>
                this.handleServerNotification(notification)
        }
    }

    // Handle a response message
    private func handleServerResponse(response: LSPResponse): Unit {
        let requestId = response.id

        if (this.pendingRequests.contains(requestId)) {
            let promise = this.pendingRequests[requestId]
            this.pendingRequests.remove(requestId)
            if (let Some(error) <- response.error) {
                LogUtils.error("LSP Error ${error.code}: ${error.message}")
                promise.reject(error.toJsonValue().toJsonString())
            } else {
                // Send the result to the pending request
                let result = match (response.result) {
                    case Some(result) => result.toJsonValue()
                    case _ => JsonValue.fromStr("{}")
                }
                promise.resolve(result)
            }
        } else {
            LogUtils.error("Received response for unknown request ID: ${requestId}")
            throw UnsupportedException("Unreachable")
        }
    }

    // Handle a notification message
    private func handleServerNotification(notification: LSPNotification): Unit {
        // For now, we'll just log unknown server notification
        LogUtils.info("Received server notification: ${notification.method}")
    }

    // Handle a request from the server
    private func handleServerRequest(request: LSPRequest): Unit {
        // For now, we'll just log unknown server requests
        LogUtils.info("Received server request: ${request.method}")
    }

    private func readLine(): String {
        return try {
            this.reader.readln() ?? String.empty
        } catch (_: Exception) {
            throw Exception("lsp_invalid_response_encoding")
        }
    }

    private func readContent(length: Int64): String {
        let contentBuilder = StringBuilder()
        var bytesRead: Int64 = 0

        while (bytesRead < length) {
            let charOption = try {
                this.reader.read()
            } catch (_: Exception) {
                throw Exception("lsp_invalid_response_encoding")
            }
            match (charOption) {
                case Some(char) =>
                    bytesRead += String([char]).size
                    if (bytesRead > length) { throw Exception("lsp_malformed_json") }
                    contentBuilder.append(char)
                case _ => throw Exception("lsp_response_eof")
            }
        }

        return contentBuilder.toString()
    }

    func receiverStatusForTest(): String { synchronized(this.sendLock) { this.receiverStatus } }

    func closedForTest(): Bool { synchronized(this.sendLock) { this.closed } }

    public func close(): Unit { synchronized(this.cleanupLock) { this.closeClient() } }

    private func closeClient(): Unit {
        let shouldClose = synchronized(this.sendLock) {
            if (this.closed) { false } else { this.closing = true; true }
        }
        if (!shouldClose) { return }
        var reaped = false
        try {
            if (this.shutdownFuture.isNone()) {
                this.shutdownFuture = Some(spawn {
                    try {
                        let _ = this.sendRequestInternal("shutdown", None, true)
                        synchronized(this.writerLock) { this.writeNotification("exit", None) }
                        true
                    } catch (_: Exception) { false }
                })
            }
            if (!this.shutdownFuture.getOrThrow().get(Duration.second * 2)) { throw Exception("lsp_shutdown_failed") }
            let _ = this.process.wait(timeout: Some(Duration.second * 2))
            reaped = true
        } catch (_: Exception) {
            try { this.process.terminate(force: true); let _ = this.process.wait(timeout: Some(Duration.second * 2)); reaped = true }
            catch (_: Exception) { () }
        } finally {
            this.process.closeStreams()
            this.rejectPending()
            var joined = true
            if (let Some(worker) <- this.shutdownFuture) {
                try { let _ = worker.get(Duration.second * 2) } catch (_: Exception) { joined = false }
            }
            for (worker in [this.workerFuture, this.stderrFuture]) {
                if (let Some(value) <- worker) {
                    try { let _ = value.get(Duration.second * 2) } catch (_: Exception) { joined = false }
                }
            }
            this.process.closeStreams()
            let streamsClosed = this.process.streamsAreClosed()
            synchronized(this.sendLock) { this.closed = reaped && joined && streamsClosed; this.closing = !this.closed }
            if (!reaped || !joined || !streamsClosed) { throw Exception("lsp_cleanup_pending") }
        }
    }
}
