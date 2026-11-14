import { createServer } from 'node:https';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import type { Server } from 'node:http';
import { createMuseumServer } from '../server/index.ts';
import { createDevicePreviewServer } from '../server/device-preview.ts';
import { runtimeConfig, hasKey } from '../server/gemini.ts';

const output = resolve(process.argv[2]);
const cfg = runtimeConfig();
if (!hasKey(cfg)) throw new Error('Project Gemini configuration is required.');
await mkdir(output, { recursive: true });
const listen = (server: Server) => new Promise<number>((done, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', () => done((server.address() as { port: number }).port)); });
const museum = createMuseumServer();
const port = await listen(museum);
const token = randomBytes(32).toString('base64url');
const preview = createDevicePreviewServer({ token, upstream: `http://127.0.0.1:${port}` });
const requests: Array<{ method: string; path: string; status: number; elapsedMs: number }> = [];
const https = createServer({ key: await readFile(resolve(output, 'localhost.key')), cert: await readFile(resolve(output, 'localhost.crt')) }, (request, response) => {
  const started = Date.now(), path = new URL(request.url || '/', 'https://localhost').pathname;
  response.once('finish', () => requests.push({ method: request.method || '', path, status: response.statusCode, elapsedMs: Date.now() - started }));
  preview.emit('request', request, response);
});
https.on('upgrade', (request, socket, head) => { requests.push({ method: 'UPGRADE', path: '/api/live', status: 101, elapsedMs: 0 }); preview.emit('upgrade', request, socket, head); });
const securePort = await listen(https);
await writeFile(resolve(output, 'museum-cloud-entrance.json'), JSON.stringify({ link: `https://127.0.0.1:${securePort}/?access=${token}`, artworkId: 'met-436535' }), { mode: 0o600 });
await writeFile(resolve(output, 'backend-ready.json'), JSON.stringify({ ready: true, model: cfg.model, liveModel: cfg.liveModel }), { mode: 0o600 });
console.log('Private localhost HTTPS integration backend ready.');
let stopping = false;
const stop = async () => {
  if (stopping) return; stopping = true;
  await writeFile(resolve(output, 'backend-requests.json'), JSON.stringify(requests, null, 2));
  preview.close(); https.close(); museum.close(); https.closeAllConnections(); museum.closeAllConnections();
  setTimeout(() => process.exit(0), 500).unref();
};
process.once('SIGTERM', stop); process.once('SIGINT', stop);
