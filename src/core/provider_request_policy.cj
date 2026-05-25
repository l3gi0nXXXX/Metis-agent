package metis.core

public class ProviderRequestDiagnostics {
    public let providerKind: String
    public let model: String
    public let endpointClass: String
    public let baseUrlRedacted: String
    public let requestUrlRedacted: String
    public let attemptIndex: Int64
    public let fallbackCount: Int64
    public let errorCategory: String
    public let statusCode: Int64
    public let providerRequestId: String
    public let message: String

    public init(
        providerKind!: String = "",
        model!: String = "",
        endpointClass!: String = "",
        baseUrlRedacted!: String = "",
        requestUrlRedacted!: String = "",
        attemptIndex!: Int64 = 0,
        fallbackCount!: Int64 = 0,
        errorCategory!: String = "",
        statusCode!: Int64 = 0,
        providerRequestId!: String = "",
        message!: String = ""
    ) {
        this.providerKind = providerKind
        this.model = model
        this.endpointClass = endpointClass
        this.baseUrlRedacted = redactProviderEndpoint(baseUrlRedacted)
        this.requestUrlRedacted = redactProviderEndpoint(requestUrlRedacted)
        this.attemptIndex = attemptIndex
        this.fallbackCount = fallbackCount
        this.errorCategory = errorCategory
        this.statusCode = statusCode
        this.providerRequestId = providerRequestId
        this.message = redactProviderSecret(message)
    }
}

private func providerRedactQueryValue(input: String, key: String): String {
    var out = input
    let lower = out.toAsciiLower()
    let keys = ["${key}=", "${key.toAsciiLower()}=", "${key.toAsciiUpper()}="]
    for (prefix in keys) {
        var searchFrom: Int64 = 0
        while (searchFrom < out.size) {
            match (out.indexOf(prefix, searchFrom)) {
                case Some(start) =>
                    let valueStart = start + prefix.size
                    var valueEnd = out.size
                    match (out.indexOf("&", valueStart)) {
                        case Some(idx) => valueEnd = idx
                        case None => ()
                    }
                    out = out[..valueStart] + "[redacted]" + out[valueEnd..]
                    searchFrom = valueStart + 10
                case None => break
            }
        }
    }
    out
}

public func redactProviderSecret(input: String): String {
    var out = input
    let markers = [
        "Authorization",
        "authorization",
        "Bearer ",
        "apiKey",
        "api_key",
        "x-api-key",
        "secret",
        "token",
        "Signature",
        "X-DashScope-Async"
    ]
    for (marker in markers) {
        if (out.contains(marker)) {
            out = out.replace(marker, "[redacted]")
        }
    }
    out
}

public func redactProviderEndpoint(input: String): String {
    var out = input.trimAscii()
    match (out.indexOf("://")) {
        case Some(schemeIdx) =>
            let authorityStart = schemeIdx + 3
            match (out.indexOf("@", authorityStart)) {
                case Some(atIdx) =>
                    match (out.indexOf("/", authorityStart)) {
                        case Some(slashIdx) =>
                            if (atIdx < slashIdx) {
                                out = out[..authorityStart] + "[redacted]@" + out[atIdx + 1..]
                            }
                        case None => out = out[..authorityStart] + "[redacted]@" + out[atIdx + 1..]
                    }
                case None => ()
            }
        case None => ()
    }
    for (key in ["api_key", "apikey", "apiKey", "token", "access_token", "signature", "Signature", "Expires", "X-Amz-Signature"]) {
        out = providerRedactQueryValue(out, key)
    }
    redactProviderSecret(out)
}
