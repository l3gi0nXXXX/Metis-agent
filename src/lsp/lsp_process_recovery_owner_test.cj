package metis.lsp

import std.unittest.testmacro.*

private class LspOwnerCallCount { var value: Int64 = 0 }

@Test
public class LSPProcessRecoveryOwnerTest {
    @TestCase
    public func lLspOwnerOldCompletionCannotEraseNewRegistration(): Unit {
        let first = ("owned-first", "fixture-parent")
        let second = ("owned-second", "fixture-parent")
        let firstCalls = LspOwnerCallCount()
        let secondCalls = LspOwnerCallCount()
        registerLspProcessRecoveryOwner(first, { _ =>
            firstCalls.value += 1
            registerLspProcessRecoveryOwner(second, { _ => secondCalls.value += 1; true })
            true
        })
        @Expect(closeLspProcessRecoveryOwner(("", "")), true)
        @Expect(closeLspProcessRecoveryOwner(("foreign", "fixture-parent")), true)
        @Expect(firstCalls.value, 0)
        @Expect(closeLspProcessRecoveryOwner(first), true)
        @Expect(closeLspProcessRecoveryOwner(first), true)
        @Expect(firstCalls.value, 1)
        @Expect(closeLspProcessRecoveryOwner(second), true)
        @Expect(secondCalls.value, 1)
    }

    @TestCase
    public func lLspOwnerPendingCallbackRemainsRetryable(): Unit {
        let context = ("owned-retry", "fixture-parent")
        let attempts = LspOwnerCallCount()
        registerLspProcessRecoveryOwner(context, { _ => attempts.value += 1; attempts.value > 1 })
        @Expect(closeLspProcessRecoveryOwner(context), false)
        @Expect(attempts.value, 1)
        @Expect(closeLspProcessRecoveryOwner(context), true)
        @Expect(attempts.value, 2)
        @Expect(closeLspProcessRecoveryOwner(context), true)
        @Expect(attempts.value, 2)
    }
}
