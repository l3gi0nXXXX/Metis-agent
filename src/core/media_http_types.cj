package metis.core

import std.collection.HashMap

public class GatewayMediaHttpResponse {
    public let statusCode: Int64
    public let headers: HashMap<String, String>
    public let body: Array<Byte>
    public let requestId: String

    public init(
        statusCode: Int64,
        headers!: HashMap<String, String> = HashMap<String, String>(),
        body!: Array<Byte> = [],
        requestId!: String = ""
    ) {
        this.statusCode = statusCode
        this.headers = headers
        this.body = body
        this.requestId = requestId
    }
}
