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
  const { runBroker } = await import(pathToFileURL(source).href);
  runBroker({ exit: (code) => process.exit(code === 0 ? 70 : code) });
} catch {
  process.stderr.write('historical broker fixture initialization failed\n');
  process.exit(64);
}
