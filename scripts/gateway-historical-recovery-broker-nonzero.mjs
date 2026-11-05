// Fault injection at the existing broker's exit boundary only. All frames and
// owner drain decisions remain produced by the real broker implementation.
import { isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

const source = process.env.METIS_HR_REAL_BROKER ?? '';
if (!isAbsolute(source)) {
  process.stderr.write('historical broker fixture source missing\n');
  process.exit(64);
}
try {
  const { runBroker, runAttachedBroker } = await import(pathToFileURL(source).href);
  if (process.argv[2] === '--attached') {
    runAttachedBroker(process.argv[3], process.argv.slice(4));
  } else {
    let broker;
    broker = runBroker({ exit: (code) => {
      // The real constructor validates the header/binding and publishes this broker's spawn.
      // Unbound pre-serve discovery and pre-return failures keep the original exit result.
      const generationBound = Boolean(broker && broker.recoveryDirectory && broker.recoveryParent &&
        broker.recoveryKey && broker.recoveryBinding && !broker.recoveryPersistenceFailed);
      process.exit(code === 0 && generationBound ? 70 : code);
    } });
  }
} catch {
  process.stderr.write('historical broker fixture initialization failed\n');
  process.exit(64);
}
