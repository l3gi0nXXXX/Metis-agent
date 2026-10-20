package metis

import metis.process.{ManagedStdioOperationResult, shutdownManagedStdioBroker}


@When[os == "Windows"]
import magic.utils.winGetArgs

@When[os == "Windows"]
main(): Int64 {
    // On Windows, we cannot use main(args: Array<String>) because
    // the standard library has a bug when parsing Unicode command line arguments.
    let args = winGetArgs()
    return cliMain(args)
}

@When[os != "Windows"]
main(args: Array<String>): Int64 {
    return cliMain(args)
}

func cliMain(args: Array<String>): Int64 {
    cliRunWithBrokerCleanup({ => runCliProgram(args) }, { => shutdownManagedStdioBroker() })
}

/** Cleanup owns only this process singleton. It must never replace the primary error. */
func cliRunWithBrokerCleanup(run: () -> Int64, cleanup: () -> ManagedStdioOperationResult): Int64 {
    var code: Int64 = 1
    var returned = false
    try {
        code = run()
        returned = true
    } finally {
        let closed = try { cleanup().ok } catch (_: Exception) { false }
        if (!closed) {
            try { eprintln("Metis 子进程通道清理未完成。") } catch (_: Exception) { () }
            if (returned && code == 0) { code = 1 }
        }
    }
    code
}
