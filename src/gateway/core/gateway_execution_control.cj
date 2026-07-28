package metis.gateway.core

/**
 * Gateway 一次请求的中性执行控制。
 *
 * 该接口不得引用 Cron/runtime 类型；普通请求继续传 `None`。
 */
public interface GatewayExecutionControl {
    func remainingMs(): Int64
    func heartbeat(): Unit
    func throwIfCancelled(): Unit
    func isCancelled(): Bool
}

public class GatewayExecutionCancelledException <: Exception {
    public let reason: String

    public init(reason: String) {
        super(if (reason.trimAscii().isEmpty()) { "cancelled" } else { reason.trimAscii() })
        this.reason = if (reason.trimAscii().isEmpty()) { "cancelled" } else { reason.trimAscii() }
    }
}
