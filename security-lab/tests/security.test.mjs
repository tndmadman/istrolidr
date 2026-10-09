import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { startServer, validateCommand } from '../src/server.mjs';
const PLAYER = 'test-player-secret-0000000000000000000000000';
const TESTER = 'test-admin-secret-00000000000000000000000000';
let lab;
before(async () => {
  lab = await startServer({ host: '127.0.0.1', port: 0, playerToken: PLAYER, testerToken: TESTER,
    pluginNames: ['deny-unit-13.mjs'] });
});
after(async () => { await lab?.close(); });

function open() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(lab.url);
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}
function recv(ws) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error('WebSocket response timed out')); }, 1500);
    const onMessage = data => { cleanup(); resolve(JSON.parse(data.toString())); };
    const onClose = () => { cleanup(); reject(new Error('Connection closed without response')); };
    const cleanup = () => {
      clearTimeout(timer); ws.off('message', onMessage); ws.off('close', onClose);
    };
    ws.on('message', onMessage); ws.on('close', onClose);
  });
}
async function exchange(ws, data) {
  const answer = recv(ws);
  ws.send(typeof data === 'string' ? data : JSON.stringify(data));
  return await answer;
}
async function authenticated(token = PLAYER) {
  const ws = await open();
  const reply = await exchange(ws, { type: 'hello', version: 'lab-v1', token });
  assert.equal(reply.type, 'hello-ok');
  return ws;
}
async function joined(token = PLAYER) {
  const ws = await authenticated(token);
  assert.equal((await exchange(ws, { type: 'join', room: 'sandbox' })).type, 'join-ok');
  return ws;
}
const cmd = (seq, name, args) => ({ type: 'command', seq, name, args });

test('unauthenticated command is rejected', async () => {
  const ws = await open();
  try { assert.equal((await exchange(ws, { type: 'join', room: 'sandbox' })).code, 'AUTH_REQUIRED'); }
  finally { ws.terminate(); }
});
test('incorrect login token is rejected', async () => {
  const ws = await open();
  try { assert.equal((await exchange(ws, { type: 'hello', version: 'lab-v1', token: 'wrong' })).code, 'BAD_TOKEN'); }
  finally { ws.terminate(); }
});
test('cannot use a command before joining', async () => {
  const ws = await authenticated();
  try { assert.equal((await exchange(ws, cmd(1, 'move', { unitId: 1, x: 3, y: 4 }))).code, 'NOT_JOINED'); }
  finally { ws.terminate(); }
});
test('valid move is acknowledged as protocol stub, not simulated game state', async () => {
  const ws = await joined();
  try {
    const result = await exchange(ws, cmd(1, 'move', { unitId: 2, x: 3, y: 4 }));
    assert.equal(result.type, 'ack');
    assert.equal(result.simulated, false);
    assert.deepEqual(result.tags, ['sample-policy', 'player']);
  } finally { ws.terminate(); }
});
test('tester-only command is protected by role', async () => {
  const ws = await joined();
  try { assert.equal((await exchange(ws, cmd(1, 'setMatchFlags', { friendlyFire: true }))).code, 'UNAUTHORIZED'); }
  finally { ws.terminate(); }
  const admin = await joined(TESTER);
  try { assert.equal((await exchange(admin, cmd(1, 'setMatchFlags', { friendlyFire: true }))).type, 'ack'); }
  finally { admin.terminate(); }
});
test('replayed sequence is rejected', async () => {
  const ws = await joined();
  try {
    assert.equal((await exchange(ws, cmd(1, 'move', { unitId: 1, x: 0, y: 0 }))).type, 'ack');
    assert.equal((await exchange(ws, cmd(1, 'move', { unitId: 1, x: 100, y: 0 }))).code, 'REPLAY_SEQUENCE');
  } finally { ws.terminate(); }
});
test('unknown fields, out-of-bounds values and prototype pollution keys rejected', async () => {
  const ws = await joined();
  try {
    assert.equal((await exchange(ws, cmd(1, 'move', { unitId: 1, x: 100001, y: 0 }))).code, 'INVALID_ARGUMENTS');
    assert.equal((await exchange(ws, { ...cmd(2, 'move', { unitId: 1, x: 0, y: 0 }), extra: 1 })).code, 'INVALID_COMMAND');
    assert.equal((await exchange(ws, '{"type":"command","seq":3,"name":"move","args":{"unitId":1,"x":0,"y":0,"__proto__":{"admin":true}}}')).code, 'INVALID_ARGUMENTS');
  } finally { ws.terminate(); }
});
test('locally installed plugin can deny specific command', async () => {
  const ws = await joined();
  try {
    assert.equal((await exchange(ws, cmd(1, 'fire', { unitId: 13, targetId: 2 }))).code, 'PLUGIN_REJECT');
    assert.equal((await exchange(ws, cmd(2, 'fire', { unitId: 12, targetId: 2 }))).type, 'ack');
  } finally { ws.terminate(); }
});
test('malformed JSON and unsupported binary payload rejected', async () => {
  const ws = await open();
  try { assert.equal((await exchange(ws, '{garbage')).code, 'INVALID_JSON'); }
  finally { ws.terminate(); }
  const other = await authenticated();
  try {
    const message = recv(other);
    other.send(Buffer.from([1,2,3]), { binary: true });
    assert.equal((await message).code, 'BINARY_NOT_SUPPORTED');
  } finally { other.terminate(); }
});
test('large frames are closed by maxPayload', async () => {
  const ws = await authenticated();
  try {
    const close = new Promise(resolve => ws.once('close', code => resolve(code)));
    ws.send('x'.repeat(32768));
    assert.equal(await close, 1009);
  } finally { ws.terminate(); }
});
test('public binds require explicit LAN mode; tokens must be strong', async () => {
  await assert.rejects(() => startServer({ host: '0.0.0.0', port: 0, playerToken: PLAYER }), /allow-lan/);
  await assert.rejects(() => startServer({ port: 0, playerToken: 'short' }), /at least 24/);
});
test('validation helper rejects unauthorized privileged command', () => {
  assert.equal(validateCommand(cmd(1, 'setMatchFlags', {friendlyFire:false}), 'player'), 'UNAUTHORIZED');
});
