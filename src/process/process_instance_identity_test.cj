package metis.process

import std.core.Duration
import std.time.MonoTime
import std.unittest.testmacro.*

@Test
public class ProcessInstanceIdentityTest {
    @TestCase
    public func s4U1CurrentIdentityRoundTripsAndStaleIdentityCannotSignal(): Unit {
        match (currentProcessInstanceIdentity()) {
            case Some(identity) =>
                let parsed = parseProcessInstanceIdentity(identity.serialize())
                @Expect(parsed.isSome(), true)
                @Expect(parsed.getOrThrow().matches(identity), true)
                let probe = probeProcessInstance(identity, MonoTime.now() + Duration.second)
                @Expect(probe.conclusive, true)
                @Expect(probe.alive, true)
                let stale = ProcessInstanceIdentity(
                    identity.platform,
                    identity.pid,
                    value0: identity.value0,
                    value1: identity.value1,
                    value2: identity.value2,
                    value3: identity.value3,
                    value4: identity.value4,
                    value5: identity.value5,
                    value6: identity.value6,
                    value7: identity.value7 + 1
                )
                let rejected = signalProcessInstance(stale, processInstanceTermSignal(), MonoTime.now() + Duration.second)
                @Expect(rejected.ok, false)
            case None =>
                let unsupported = ProcessInstanceIdentity(99, 42)
                @Expect(probeProcessInstance(unsupported, MonoTime.now() + Duration.second).status, "identity_unsupported")
        }
    }

    @TestCase
    public func s4B1IdentityParserAndDeadlineFailClosed(): Unit {
        @Expect(parseProcessInstanceIdentity("1:2:3").isNone(), true)
        @Expect(parseProcessInstanceIdentity("中文🙂").isNone(), true)
        match (currentProcessInstanceIdentity()) {
            case Some(identity) =>
                let expired = signalProcessInstance(identity, processInstanceTermSignal(), MonoTime.now() - Duration.millisecond)
                @Expect(expired.ok, false)
                @Expect(expired.status, "deadline_exceeded")
            case None => ()
        }
    }
}
