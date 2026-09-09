package metis.core.model

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex

private let modelExecutionDeadlineLock = Mutex()
private let modelExecutionRemainingByThread = HashMap<Int64, ArrayList<ModelExecutionDeadlineScopeEntry>>()
private var modelExecutionDeadlineNextToken: Int64 = 0

public class ModelExecutionDeadlineScopeToken {
    public let threadId: Int64
    public let value: Int64

    init(threadId: Int64, value: Int64) {
        this.threadId = threadId
        this.value = value
    }
}

public class ModelExecutionDeadlineSnapshot {
    public let status: String
    public let remainingMs: Int64

    init(status: String, remainingMs: Int64) {
        this.status = status
        this.remainingMs = remainingMs
    }
}

private class ModelExecutionDeadlineScopeEntry {
    let token: ModelExecutionDeadlineScopeToken
    let hook: () -> Int64

    init(token: ModelExecutionDeadlineScopeToken, hook: () -> Int64) {
        this.token = token
        this.hook = hook
    }
}

private func modelExecutionDeadlineStack(threadId: Int64): ArrayList<ModelExecutionDeadlineScopeEntry> {
    match (modelExecutionRemainingByThread.get(threadId)) {
        case Some(existing) => existing
        case None =>
            let created = ArrayList<ModelExecutionDeadlineScopeEntry>()
            modelExecutionRemainingByThread[threadId] = created
            created
    }
}

public func pushModelExecutionRemainingMsScope(hook: () -> Int64): ModelExecutionDeadlineScopeToken {
    synchronized(modelExecutionDeadlineLock) {
        modelExecutionDeadlineNextToken += 1
        let token = ModelExecutionDeadlineScopeToken(Thread.currentThread.id, modelExecutionDeadlineNextToken)
        modelExecutionDeadlineStack(token.threadId).add(ModelExecutionDeadlineScopeEntry(token, hook))
        token
    }
}

/** Gateway 在当前 model 调用线程内注入的剩余预算；普通调用无值。 */
public func pushModelExecutionRemainingMs(hook: () -> Int64): Unit {
    let _ = pushModelExecutionRemainingMsScope(hook)
}

public func popModelExecutionRemainingMs(): Unit {
    synchronized(modelExecutionDeadlineLock) {
        let threadId = Thread.currentThread.id
        match (modelExecutionRemainingByThread.get(threadId)) {
            case Some(stack) =>
                if (stack.size > 0) {
                    stack.remove(at: stack.size - 1)
                }
                if (stack.size == 0) {
                    modelExecutionRemainingByThread.remove(threadId)
                }
            case None => ()
        }
    }
}

public func popModelExecutionRemainingMsScope(token: ModelExecutionDeadlineScopeToken): Bool {
    synchronized(modelExecutionDeadlineLock) {
        let threadId = Thread.currentThread.id
        if (token.threadId != threadId) {
            return false
        }
        match (modelExecutionRemainingByThread.get(threadId)) {
            case Some(stack) =>
                if (stack.size == 0 || stack[stack.size - 1].token.value != token.value) {
                    return false
                }
                stack.remove(at: stack.size - 1)
                if (stack.size == 0) {
                    modelExecutionRemainingByThread.remove(threadId)
                }
                true
            case None => false
        }
    }
}

public func currentModelExecutionDeadlineSnapshot(): ModelExecutionDeadlineSnapshot {
    let hook = synchronized(modelExecutionDeadlineLock) {
        match (modelExecutionRemainingByThread.get(Thread.currentThread.id)) {
            case Some(stack) =>
                if (stack.size > 0) {
                    Some(stack[stack.size - 1].hook)
                } else {
                    None<() -> Int64>
                }
            case None => None<() -> Int64>
        }
    }
    match (hook) {
        case Some(read) =>
            try {
                let remaining = read()
                if (remaining > 0) {
                    ModelExecutionDeadlineSnapshot("active", remaining)
                } else {
                    ModelExecutionDeadlineSnapshot("expired", 0)
                }
            } catch (_: Exception) {
                ModelExecutionDeadlineSnapshot("expired", 0)
            }
        case None => ModelExecutionDeadlineSnapshot("absent", 0)
    }
}

public func currentModelExecutionRemainingMs(): Int64 {
    currentModelExecutionDeadlineSnapshot().remainingMs
}
