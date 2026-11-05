package metis.cliapp

public func runEmbeddedPrompt(prompt: String): Unit {
    let app = CliApp()
    try { app.startNonInteractive(prompt) } finally { let _ = app.close() }
}
