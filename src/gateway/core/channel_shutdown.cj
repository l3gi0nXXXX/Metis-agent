package metis.gateway.core

import std.time.MonoTime

/** A stopped flag alone does not prove that an adapter's resources have settled. */
public class GatewayChannelShutdownResult {
    public let ok: Bool
    public let status: String
    public let pendingCount: Int64
    public let diagnostic: String

    public init(ok: Bool, status: String, pendingCount!: Int64 = 0, diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.pendingCount = pendingCount
        this.diagnostic = diagnostic
    }
}

/** Optional lifecycle capability; transport ownership remains inside the adapter. */
public interface GatewayBoundedChannelShutdown {
    /** Prevent new work and initiate cancellation without waiting on remote confirmation. */
    func beginShutdown(deadline: MonoTime): Unit

    /** Keep ownership of unfinished work when the shared absolute deadline expires. */
    func awaitShutdown(deadline: MonoTime): GatewayChannelShutdownResult
}
