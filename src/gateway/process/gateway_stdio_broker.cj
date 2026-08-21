package metis.gateway.process

import metis.process.{ManagedStdioBrokerClient, ManagedStdioOperationResult, managedStdioBroker, shutdownManagedStdioBroker}
import stdx.encoding.json.{JsonBool, JsonInt, JsonObject, JsonString}

/** Gateway lifecycle/readiness facade; all process ownership remains in metis.process. */
public func gatewayStdioBroker(): ManagedStdioBrokerClient {
    managedStdioBroker()
}

public func gatewayStdioBrokerSnapshot(): JsonObject {
    let snapshot = managedStdioBroker().snapshot()
    let out = JsonObject()
    out.put("running", JsonBool(snapshot.running))
    out.put("responsive", JsonBool(snapshot.responsive))
    out.put("status", JsonString(snapshot.status))
    out.put("generation", JsonInt(snapshot.generation))
    out.put("brokerPid", JsonInt(snapshot.brokerPid))
    out.put("ownerCount", JsonInt(snapshot.ownerCount))
    out.put("readerCount", JsonInt(snapshot.readerCount))
    out
}

public func gatewayStdioBrokerReady(timeoutMs!: Int64 = 500): ManagedStdioOperationResult {
    managedStdioBroker().probeBroker(timeoutMs: timeoutMs)
}

public func shutdownGatewayStdioBroker(timeoutMs!: Int64 = 2000): ManagedStdioOperationResult {
    shutdownManagedStdioBroker(timeoutMs: timeoutMs)
}
