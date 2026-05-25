package metis.core.media_tests

public func mediaDiagnosticsLooksRedacted(text: String): Bool {
    !(text.contains("Authorization") ||
        text.contains("Bearer ") ||
        text.contains("api_key=secret") ||
        text.contains("token=secret") ||
        text.contains("password"))
}
