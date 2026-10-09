import http from 'node:http';
import crypto from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { fileURLToPath } from 'node:url';
import { PluginHost, resolvePluginNames } from './plugins.mjs';

const VERSION = 'lab-v1';
const MAX_FRAME = 16 * 1024;
const MAX_CONNECTIONS = 16;
const MAX_PER_IP = 4;
const MAX_MESSAGES_PER_SECOND = 30;
const MAX_QUEUED = 32;
const ALLOWED_COMMANDS = Object.freeze({
  move: { unitId: 'id', x: 'coord', y: 'coord' },
  fire: { unitId: 'id', targetId: 'id' },
  setMatchFlags: { friendlyFire: 'bool' }
});

export function validateCommand(input, role) {
  if (!isPlainObject(input) || !hasKeys(input, ['type', 'seq', 'name', 'args']) ||
      input.type !== 'command' || !Number.isSafeInteger(input.seq) ||
      input.seq < 1 || input.seq > 2_000_000_000 ||
      typeof input.name !== 'string' || !(input.name in ALLOWED_COMMANDS) ||
      !Object.hasOwn(ALLOWED_COMMANDS, input.name)) return 'INVALID_COMMAND';
  if (input.name === 'setMatchFlags' && role !== 'tester') return 'UNAUTHORIZED';
  const spec = ALLOWED_COMMANDS[input.name];
  if (!isPlainObject(input.args) || !hasKeys(input.args, Object.keys(spec))) return 'INVALID_ARGUMENTS';
  for (const [name, kind] of Object.entries(spec)) {
    const value = input.args[name];
    if (kind === 'id' && !(Number.isSafeInteger(value) && value >= 1 && value <= 1_000_000)) return 'INVALID_ARGUMENTS';
    if (kind === 'coord' && !(Number.isFinite(value) && Math.abs(value) <= 100_000)) return 'INVALID_ARGUMENTS';
    if (kind === 'bool' && typeof value !== 'boolean') return 'INVALID_ARGUMENTS';
  }
  return null;
}

function isPlainObject(obj) {
  return obj != null && typeof obj === 'object' && !Array.isArray(obj) &&
    Object.getPrototypeOf(obj) === Object.prototype;
}
function hasKeys(value, keys) {
  return Object.keys(value).length === keys.length &&
    keys.every(key => Object.hasOwn(value, key));
}
function tokenEquals(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const aa = Buffer.from(a), bb = Buffer.from(b);
  return aa.length === bb.length && crypto.timingSafeEqual(aa, bb);
}
function respond(ws, value) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(value));
}
function reject(ws, code, close = false) {
  respond(ws, { type: 'reject', code });
  if (close) ws.close(1008, 'Policy violation');
}
function assertConfig(config) {
  if (!['127.0.0.1', '::1'].includes(config.host) && !config.allowLan) {
    throw new Error('Public/LAN binding requires explicit --allow-lan and strong token.');
  }
  if (typeof config.playerToken !== 'string' || config.playerToken.length < 24) {
    throw new Error('ISTROLIDR_TEST_TOKEN must be at least 24 characters.');
  }
  if (config.testerToken != null && (config.testerToken.length < 24 ||
      tokenEquals(config.playerToken, config.testerToken))) {
    throw new Error('Tester token must be distinct and at least 24 characters.');
  }
}
export async function startServer(config = {}) {
  const options = {
    host: '127.0.0.1', port: 8765, playerToken: process.env.ISTROLIDR_TEST_TOKEN,
    testerToken: process.env.ISTROLIDR_TEST_ADMIN_TOKEN, allowLan: false,
    pluginNames: [], pluginDirectory: fileURLToPath(new URL('../plugins/', import.meta.url)),
    audit: () => {}, ...config
  };
  assertConfig(options);
  const pluginPaths = resolvePluginNames(options.pluginDirectory, options.pluginNames);
  const plugins = new PluginHost(pluginPaths);
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME, perMessageDeflate: false });
  const sessions = new Map();
  const byIp = new Map();
  const audit = (event, session, code) => {
    // NEVER store authentication tokens, raw frames, full payloads, or IPs in audit logs.
    try { options.audit({ time: new Date().toISOString(), event, session: session?.id ?? null,
      role: session?.role ?? null, code: code ?? null }); } catch {}
  };
  const httpServer = http.createServer((request, response) => {
    if (request.method === 'GET' && request.url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ service: 'istrolidr-security-lab', version: VERSION, status: 'ok' }));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  httpServer.on('upgrade', (request, socket, head) => {
    if (request.url !== '/lab') { socket.write('HTTP/1.1 404 Not Found\r\n\r\n'); socket.destroy(); return; }
    const ip = request.socket.remoteAddress ?? 'unknown';
    if (sessions.size >= MAX_CONNECTIONS || (byIp.get(ip) ?? 0) >= MAX_PER_IP) {
      socket.write('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
      socket.destroy(); return;
    }
    wss.handleUpgrade(request, socket, head, ws => { wss.emit('connection', ws, request); });
  });

  wss.on('connection', (ws, request) => {
    const ip = request.socket.remoteAddress ?? 'unknown';
    const session = { id: crypto.randomUUID(), role: null, joined: false, seq: 0,
      queue: Promise.resolve(), pending: 0, rateStart: Date.now(), rateCount: 0 };
    sessions.set(ws, session);
    byIp.set(ip, (byIp.get(ip) ?? 0) + 1);
    audit('connect', session);
    const authTimer = setTimeout(() => {
      if (!session.role) { audit('auth_timeout', session); ws.close(1008, 'Authentication timeout'); }
    }, 5_000);
    ws.on('close', () => {
      clearTimeout(authTimer);
      sessions.delete(ws);
      byIp.set(ip, Math.max(0, (byIp.get(ip) ?? 1) - 1));
      audit('disconnect', session);
    });
    ws.on('error', () => { /* Do not crash on a malformed/aborted transport. */ });

    async function handle(frame, isBinary) {
      if (ws.readyState !== WebSocket.OPEN) return;
      if (isBinary) { audit('reject', session, 'BINARY_NOT_SUPPORTED'); reject(ws, 'BINARY_NOT_SUPPORTED', true); return; }
      let message;
      try { message = JSON.parse(frame.toString('utf8')); }
      catch { audit('reject', session, 'INVALID_JSON'); reject(ws, 'INVALID_JSON', true); return; }
      if (!isPlainObject(message) || typeof message.type !== 'string') {
        audit('reject', session, 'INVALID_ENVELOPE'); reject(ws, 'INVALID_ENVELOPE', true); return;
      }
      if (!session.role) {
        if (!hasKeys(message, ['type','version','token']) || message.type !== 'hello' ||
            message.version !== VERSION) {
          audit('reject', session, 'AUTH_REQUIRED'); reject(ws, 'AUTH_REQUIRED', true); return;
        }
        if (tokenEquals(message.token, options.testerToken)) session.role = 'tester';
        else if (tokenEquals(message.token, options.playerToken)) session.role = 'player';
        else { audit('reject', session, 'BAD_TOKEN'); reject(ws, 'BAD_TOKEN', true); return; }
        clearTimeout(authTimer);
        audit('auth_ok', session);
        respond(ws, { type: 'hello-ok', version: VERSION, role: session.role, session: session.id });
        return;
      }
      if (message.type === 'ping' && hasKeys(message, ['type'])) {
        respond(ws, { type: 'pong' }); return;
      }
      if (message.type === 'join' && hasKeys(message, ['type', 'room']) && message.room === 'sandbox') {
        session.joined = true;
        audit('join', session);
        respond(ws, { type: 'join-ok', room: 'sandbox', simulation: 'protocol-stub' });
        return;
      }
      if (message.type !== 'command') {
        audit('reject', session, 'UNKNOWN_MESSAGE'); reject(ws, 'UNKNOWN_MESSAGE'); return;
      }
      if (!session.joined) { audit('reject', session, 'NOT_JOINED'); reject(ws, 'NOT_JOINED'); return; }
      const error = validateCommand(message, session.role);
      if (error) { audit('reject', session, error); reject(ws, error); return; }
      if (message.seq <= session.seq) { audit('reject', session, 'REPLAY_SEQUENCE'); reject(ws, 'REPLAY_SEQUENCE'); return; }
      // Advance sequence before invoking external plugins; a rejected command cannot be replayed.
      session.seq = message.seq;
      const result = await plugins.onCommand({ session: { id: session.id, role: session.role, joined: true },
        command: { name: message.name, args: structuredClone(message.args), seq: message.seq } });
      if (ws.readyState !== WebSocket.OPEN) return;
      if (!result.allow) {
        audit('reject', session, result.code);
        reject(ws, result.code); return;
      }
      audit('command', session, message.name);
      respond(ws, { type: 'ack', seq: message.seq, command: message.name, tags: result.tags,
        simulated: false });
    }

    ws.on('message', (frame, isBinary) => {
      const now = Date.now();
      if (now - session.rateStart >= 1000) { session.rateStart = now; session.rateCount = 0; }
      if (++session.rateCount > MAX_MESSAGES_PER_SECOND || frame.length > MAX_FRAME ||
          session.pending >= MAX_QUEUED) {
        audit('reject', session, 'RATE_OR_SIZE_LIMIT'); ws.close(1008, 'Rate or size limit'); return;
      }
      session.pending++;
      session.queue = session.queue.then(() => handle(frame, isBinary))
        .catch(() => { audit('internal_error', session); reject(ws, 'INTERNAL_ERROR', true); })
        .finally(() => { session.pending--; });
    });
  });

  try {
    await new Promise((resolve, reject) => {
      httpServer.once('error', reject);
      httpServer.listen(options.port, options.host, () => {
        httpServer.off('error', reject);
        resolve();
      });
    });
  } catch (error) {
    await plugins.close();
    throw error;
  }
  const address = httpServer.address();
  return {
    url: 'ws://' + (address.address.includes(':') ? '[' + address.address + ']' : address.address) +
      ':' + address.port + '/lab',
    address, sessions,
    async close() {
      for (const socket of sessions.keys()) socket.terminate();
      await plugins.close();
      await new Promise(resolve => wss.close(() => resolve()));
      await new Promise(resolve => httpServer.close(() => resolve()));
    }
  };
}
