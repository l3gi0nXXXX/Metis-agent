package metis.core.model

import std.unittest.testmacro.*

@Test
public class CliModelManagerTest {
    @TestCase
    public func emptyHttpResponseBodyIsFallbackEligible(): Unit {
        @Expect(CliModelManager.fallbackErrorEligibleForTest(Exception("Http response body is empty")), true)
    }

    @TestCase
    public func emptyHttpResponseBodyMatchingIgnoresCaseAndOuterWhitespace(): Unit {
        @Expect(CliModelManager.fallbackErrorEligibleForTest(Exception("  HTTP RESPONSE BODY IS EMPTY  ")), true)
        @Expect(CliModelManager.fallbackErrorEligibleForTest(Exception("\nHttp response body is empty\n")), true)
        @Expect(CliModelManager.fallbackErrorEligibleForTest(Exception("\tresponse body is empty\t")), true)
        @Expect(CliModelManager.fallbackErrorEligibleForTest(Exception("empty response body")), true)
    }
}
