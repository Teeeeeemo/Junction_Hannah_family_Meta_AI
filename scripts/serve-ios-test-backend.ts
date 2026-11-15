import { createServer } from 'node:https';
import { readFile, writeFile, mkdir, chmod } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { Server, ServerResponse } from 'node:http';
import { createMuseumServer } from '../server/index.ts';
import { createDevicePreviewServer } from '../server/device-preview.ts';
import { runtimeConfig, hasKey } from '../server/gemini.ts';

type ModelResponse = { path: string; status: number; body: unknown };
const modelResponsePaths = new Set(['/api/artwork-candidates', '/api/analyze']);
const maxResponseBytes = 512 * 1024;

/** Observe only public-fixture model JSON, without changing HTTP writes. */
export function recordModelResponse(path: string, response: ServerResponse,
  record: (entry: ModelResponse) => void): void {
  if (!modelResponsePaths.has(path)) return;
  let bytes = 0, discarded = false;
  const chunks: Buffer[] = [];
  const capture = (chunk: unknown, encoding: unknown) => {
    if (discarded || chunk == null || typeof chunk === 'function') return;
    try {
      const size = typeof chunk === 'string'
        ? Buffer.byteLength(chunk, typeof encoding === 'string' ? encoding as BufferEncoding : undefined)
        : chunk instanceof Uint8Array ? chunk.byteLength : -1;
      if (size < 0 || bytes + size > maxResponseBytes) {
        discarded = true; chunks.length = 0; return;
      }
      const buffer = typeof chunk === 'string'
        ? Buffer.from(chunk, typeof encoding === 'string' ? encoding as BufferEncoding : undefined)
        : chunk instanceof Uint8Array ? Buffer.from(chunk) : null;
      if (!buffer || bytes + buffer.length > maxResponseBytes) {
        discarded = true; chunks.length = 0; return;
      }
      bytes += buffer.length; chunks.push(buffer);
    } catch { discarded = true; chunks.length = 0; }
  };
  const originalWrite = response.write, originalEnd = response.end;
  response.write = function (this: ServerResponse, ...args: unknown[]) {
    capture(args[0], args[1]);
    return Reflect.apply(originalWrite, this, args);
  } as typeof response.write;
  response.end = function (this: ServerResponse, ...args: unknown[]) {
    capture(args[0], args[1]);
    return Reflect.apply(originalEnd, this, args);
  } as typeof response.end;
  response.once('finish', () => {
    if (discarded || response.statusCode < 200 || response.statusCode >= 300) return;
    try { record({ path, status: response.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }); }
    catch { /* Invalid or incomplete JSON is not model evidence. */ }
  });
}

async function main() {
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
  const modelResponses: ModelResponse[] = [];
  const responseLog = resolve(output, 'model-responses.json');
  await writeFile(responseLog, '[]\n', { mode: 0o600 });
  await chmod(responseLog, 0o600);
  let responseWrites = Promise.resolve(), responseLogFailed = false;
  const https = createServer({ key: await readFile(resolve(output, 'localhost.key')), cert: await readFile(resolve(output, 'localhost.crt')) }, (request, response) => {
    const started = Date.now(), path = new URL(request.url || '/', 'https://localhost').pathname;
    recordModelResponse(path, response, entry => {
      modelResponses.push(entry);
      const snapshot = JSON.stringify(modelResponses, null, 2) + '\n';
      responseWrites = responseWrites.then(() => writeFile(responseLog, snapshot, { mode: 0o600 }))
        .catch(() => { responseLogFailed = true; });
    });
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
    await responseWrites;
    if (responseLogFailed) console.error('Could not preserve model response diagnostics.');
    await writeFile(resolve(output, 'backend-requests.json'), JSON.stringify(requests, null, 2));
    preview.close(); https.close(); museum.close(); https.closeAllConnections(); museum.closeAllConnections();
    setTimeout(() => process.exit(0), 500).unref();
  };
  process.once('SIGTERM', stop); process.once('SIGINT', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
