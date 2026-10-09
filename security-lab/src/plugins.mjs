import { Worker } from 'node:worker_threads';
import { realpathSync } from 'node:fs';
import { resolve, sep } from 'node:path';

export function resolvePluginNames(directory, names) {
  const root = realpathSync(directory);
  return names.map(name => {
    if (typeof name !== 'string' || !/^[a-zA-Z0-9_-]+\.mjs$/.test(name)) {
      throw new Error('Plugin must be a basename ending with .mjs; no paths allowed.');
    }
    const actual = realpathSync(resolve(root, name));
    if (!actual.startsWith(root + sep)) throw new Error('Plugin path escaped plugin directory.');
    return actual;
  });
}

// Plugin execution is deliberately opt-in. Never execute code received over WebSocket.
// Only install/audit trusted local plugins. worker_threads is fault containment,
// NOT a sandbox against hostile Node.js code (workers may access filesystem/network).
export class PluginHost {
  constructor(paths = [], timeoutMs = 250) {
    this.plugins = paths.map(path => this.makeWorker(path, timeoutMs));
  }

  makeWorker(path, timeoutMs) {
    const worker = new Worker(new URL('./plugin-worker.mjs', import.meta.url), { workerData: { path } });
    const pending = new Map();
    let counter = 0;
    let failure = null;
    let ready = false;
    const failAll = error => {
      failure = String(error?.message ?? error);
      for (const { reject, timer } of pending.values()) {
        clearTimeout(timer);
        reject(new Error(failure));
      }
      pending.clear();
    };
    worker.on('error', failAll);
    worker.on('exit', code => { if (!failure) failAll(new Error('Plugin worker exited: ' + code)); });
    worker.on('message', data => {
      if (data.ready) { ready = true; return; }
      if (data.fatal) { failAll(new Error(data.fatal)); return; }
      const request = pending.get(data.id);
      if (!request) return;
      pending.delete(data.id);
      clearTimeout(request.timer);
      if (data.error) request.reject(new Error(data.error));
      else request.resolve(data.result);
    });
    return {
      path,
      worker,
      call(event) {
        if (failure) return Promise.reject(new Error(failure));
        return new Promise((resolve, reject) => {
          const id = ++counter;
          const timer = setTimeout(() => {
            pending.delete(id);
            failAll(new Error('Plugin exceeded execution deadline'));
            worker.terminate().catch(() => {});
            reject(new Error('Plugin exceeded execution deadline'));
          }, timeoutMs);
          pending.set(id, { resolve, reject, timer });
          worker.postMessage({ id, event });
        });
      },
      async close() { failAll(new Error('Plugin shut down')); await worker.terminate().catch(() => {}); },
      get ready() { return ready; }
    };
  }

  async onCommand(event) {
    const tags = [];
    for (const plugin of this.plugins) {
      let result;
      try { result = await plugin.call(event); }
      catch (error) { return { allow: false, code: 'PLUGIN_FAILURE', note: String(error.message).slice(0, 120) }; }
      if (result == null) continue;
      if (typeof result !== 'object' || Array.isArray(result)) return { allow: false, code: 'PLUGIN_INVALID_RESPONSE' };
      if (result.reject === true) {
        return { allow: false, code: 'PLUGIN_REJECT', note: String(result.reason ?? '').slice(0, 100) };
      }
      if (result.reject !== undefined && result.reject !== false) {
        return { allow: false, code: 'PLUGIN_INVALID_RESPONSE' };
      }
      if (Array.isArray(result.tags)) {
        for (const tag of result.tags.slice(0, 8)) {
          if (typeof tag === 'string' && /^[a-zA-Z0-9_-]{1,32}$/.test(tag)) tags.push(tag);
        }
      }
    }
    return { allow: true, tags: tags.slice(0, 12) };
  }

  async close() { await Promise.all(this.plugins.map(plugin => plugin.close())); }
}
