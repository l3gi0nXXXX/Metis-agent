package metis.lsp

import std.sync.Mutex

// One process-wide LSP manager owner. Its toolset retains the actual client and joins it.
private let lspRecoveryOwnerLock = Mutex()
private var lspRecoveryOwnerContext = ("", "")
private var lspRecoveryOwnerClose = None<((String, String)) -> Bool>
private var lspRecoveryOwnerSequence: Int64 = 0

public func registerLspProcessRecoveryOwner(context: (String, String), closeOwner: ((String, String)) -> Bool): Unit {
    synchronized(lspRecoveryOwnerLock) {
        lspRecoveryOwnerSequence += 1
        lspRecoveryOwnerContext = context
        lspRecoveryOwnerClose = Some(closeOwner)
    }
}

public func closeLspProcessRecoveryOwner(context: (String, String)): Bool {
    let snapshot = synchronized(lspRecoveryOwnerLock) {
        if (context[0].isEmpty() || lspRecoveryOwnerContext != context) { return true }
        (lspRecoveryOwnerSequence, lspRecoveryOwnerClose)
    }
    let settled = match (snapshot[1]) { case Some(closeOwner) => closeOwner(context) case None => true }
    if (settled) {
        synchronized(lspRecoveryOwnerLock) {
            if (lspRecoveryOwnerSequence == snapshot[0]) {
                lspRecoveryOwnerClose = None<((String, String)) -> Bool>
                lspRecoveryOwnerContext = ("", "")
            }
        }
    }
    settled
}
