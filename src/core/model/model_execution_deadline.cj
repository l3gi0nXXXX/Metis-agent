package metis.core.model

import std.collection.HashMap
import std.sync.Mutex

private let modelExecutionDeadlineLock = Mutex()
private let modelExecutionRemainingByThread = HashMap<Int64, () -> Int64>()

/** Gateway 在当前 model 调用线程内注入的剩余预算；普通调用无值。 */
public func pushModelExecutionRemainingMs(hook: () -> Int64): Unit {
    synchronized(modelExecutionDeadlineLock) {
        modelExecutionRemainingByThread[Thread.currentThread.id] = hook
    }
}

public func popModelExecutionRemainingMs(): Unit {
    synchronized(modelExecutionDeadlineLock) {
        modelExecutionRemainingByThread.remove(Thread.currentThread.id)
    }
}

public func currentModelExecutionRemainingMs(): Int64 {
    let hook = synchronized(modelExecutionDeadlineLock) {
        modelExecutionRemainingByThread.get(Thread.currentThread.id)
    }
    match (hook) {
        case Some(read) => max(0, read())
        case None => 0
    }
}
