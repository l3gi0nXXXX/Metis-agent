package metis.gateway.runtime

import std.unittest.testmacro.*

@Test
public class GatewayMethodAliasesTest {
    @TestCase
    public func dashboardAliasNormalizesSharedGatewayMethods(): Unit {
        @Expect(gatewayDashboardMethodAlias("health"), "dashboard.status")
        @Expect(gatewayDashboardMethodAlias("chat.send"), "dashboard.chat.send")
        @Expect(gatewayDashboardMethodAlias("models.list"), "dashboard.models")
        @Expect(gatewayDashboardMethodAlias("skills"), "skills.status")
        @Expect(gatewayDashboardMethodAlias("skills.list"), "skills.status")
        @Expect(gatewayDashboardMethodAlias("skills.compatibility"), "skills.compatibilityMatrix")
        @Expect(gatewayDashboardMethodAlias("sessions.reset"), "")
        @Expect(gatewayDashboardMethodAlias("unknown.method"), "")
    }

    @TestCase
    public func canvasNodeAliasesRouteThroughNodeInvoke(): Unit {
        @Expect(gatewayDashboardMethodAlias("nodes.canvas.present"), "node.invoke")
        @Expect(gatewayDashboardMethodAlias("nodes.canvas.snapshot"), "node.invoke")
        @Expect(gatewayDashboardMethodAlias("nodes.canvas.navigate"), "node.invoke")
        @Expect(gatewayDashboardMethodAlias("nodes.canvas.eval"), "node.invoke")
        @Expect(gatewayDashboardMethodAlias("nodes.canvas.a2ui_push"), "node.invoke")
        @Expect(gatewayDashboardMethodAlias("nodes.canvas.a2ui_reset"), "node.invoke")
    }
}
