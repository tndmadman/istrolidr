// Trusted, operator-installed plugins run in a separate worker to contain hangs.
// Worker threads are NOT a security boundary against malicious plugin authors.
import { parentPort, workerData } from 'node:worker_threads';
import { pathToFileURL } from 'node:url';

try {
  const mod = await import(pathToFileURL(workerData.path).href);
  if (typeof mod.onCommand !== 'function') throw new Error('Plugin must export async function onCommand(event)');
  parentPort.on('message', async ({ id, event }) => {
    try {
      const result = await mod.onCommand(structuredClone(event));
      parentPort.postMessage({ id, result: result ?? null });
    } catch (error) {
      parentPort.postMessage({ id, error: String(error?.message ?? error).slice(0, 180) });
    }
  });
  parentPort.postMessage({ ready: true });
} catch (error) {
  parentPort.postMessage({ fatal: String(error?.message ?? error).slice(0, 180) });
}
