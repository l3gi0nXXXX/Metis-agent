package metis

import metis.utils.InfoUtils

import std.env.{getVariable, setVariable}
import std.fs.{Path, exists}
import std.unittest.testmacro.*

@Test
public class ProgramRunnerStartupEnvironmentTest {
    @TestCase
    public func localCliAppliesMacosTlsCaDefaultsBeforeDispatch(): Unit {
        let oldSslCertFile = getVariable("SSL_CERT_FILE")
        setVariable("SSL_CERT_FILE", "")

        try {
            let _ = runCliProgram(["--help"])

            if (InfoUtils.os == "macos" && exists(Path("/etc/ssl/cert.pem"))) {
                @Expect(getVariable("SSL_CERT_FILE").getOrThrow(), "/etc/ssl/cert.pem")
            }
        } finally {
            match (oldSslCertFile) {
                case Some(value) => setVariable("SSL_CERT_FILE", value)
                case None => setVariable("SSL_CERT_FILE", "")
            }
        }
    }
}
