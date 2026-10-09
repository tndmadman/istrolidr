import { randomBytes } from 'node:crypto';
import { mkdirSync, appendFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { startServer } from './server.mjs';

const argv = process.argv.slice(2);
const opts = { pluginNames: [] };
function value(i) {
  if (i + 1 >= argv.length || argv[i + 1].startsWith('--')) throw new Error('Missing value for ' + argv[i]);
  return argv[i + 1];
}
for (let i = 0; i < argv.length; i++) {
  switch (argv[i]) {
    case '--host': opts.host = value(i++); break;
    case '--port': opts.port = Number(value(i++)); break;
    case '--plugin': opts.pluginNames.push(value(i++)); break;
    case '--allow-lan': opts.allowLan = true; break;
    case '--audit': opts.auditPath = resolve(value(i++)); break;
    case '--help':
      console.log('node src/cli.mjs [--host 127.0.0.1] [--port 8765] [--plugin NAME.mjs] [--audit PATH] [--allow-lan]');
      process.exit(0);
    default: throw new Error('Unknown argument: ' + argv[i]);
  }
}
if (opts.port !== undefined && (!Number.isInteger(opts.port) || opts.port < 1 || opts.port > 65535)) {
  throw new Error('Port must be between 1 and 65535.');
}
if (opts.allowLan && !process.env.ISTROLIDR_TEST_TOKEN) {
  throw new Error('LAN mode requires manually supplied ISTROLIDR_TEST_TOKEN (>=24 chars).');
}
const generated = !process.env.ISTROLIDR_TEST_TOKEN;
opts.playerToken = process.env.ISTROLIDR_TEST_TOKEN ?? randomBytes(24).toString('hex');
opts.testerToken = process.env.ISTROLIDR_TEST_ADMIN_TOKEN;
const auditPath = opts.auditPath ?? resolve('.build', 'audit.jsonl');
mkdirSync(dirname(auditPath), { recursive: true });
opts.audit = entry => appendFileSync(auditPath, JSON.stringify(entry) + '\n', { mode: 0o600 });
const server = await startServer(opts);
console.log('IstrolidR SECURITY LAB (NOT a production server, NOT Istrolid protocol compatible)');
console.log('Listening at: ' + server.url);
console.log('Audit log: ' + auditPath);
if (generated) console.log('Local test PLAYER token (never commit or share): ' + opts.playerToken);
else console.log('Player token read from environment.');
if (opts.testerToken) console.log('TESTER role enabled; token is read from environment.');
else console.log('TESTER role disabled. Set ISTROLIDR_TEST_ADMIN_TOKEN to enable privileged tests.');
console.log('Plugins: ' + (opts.pluginNames.length ? opts.pluginNames.join(', ') : 'disabled'));
console.log('Press Ctrl+C to stop.');
let closing = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    if (closing) return;
    closing = true;
    await server.close();
    process.exit(0);
  });
}
