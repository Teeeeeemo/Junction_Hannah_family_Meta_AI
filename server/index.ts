import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { demoAnalysis } from './content.ts';
import { analyze, answerQuestion, demoQuestion, hasKey, requireKey, restGenerator, runtimeConfig, translateAnalysis, type Generate, type RuntimeConfig } from './gemini.ts';
import { attachLiveSocket } from './live.ts';
import { ApiError, clientAnalysis, imageData, languageOf, textOf } from './validation.ts';

export interface ServerOptions { config?: Partial<RuntimeConfig>; generate?: Generate; root?: string; }

function allowedOrigin(origin: string | undefined): boolean {
  if (!origin) return true;
  try { const url = new URL(origin); return ['http:', 'https:'].includes(url.protocol) && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname); }
  catch { return false; }
}
function localHost(host: string | undefined): boolean {
  if (!host) return false;
  try { return ['localhost', '127.0.0.1', '[::1]'].includes(new URL(`http://${host}`).hostname); } catch { return false; }
}
function json(response: ServerResponse, status: number, value: unknown): void {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  response.end(JSON.stringify(value));
}
async function body(request: IncomingMessage): Promise<Record<string, any>> {
  const chunks: Buffer[] = []; let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 10_000_000) throw new ApiError(413, 'BODY_TOO_LARGE', 'Request exceeds the 10 MB limit.');
    chunks.push(Buffer.from(chunk));
  }
  try { const value = JSON.parse(Buffer.concat(chunks).toString('utf8')); if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error(); return value; }
  catch { throw new ApiError(400, 'INVALID_JSON', 'Send a JSON object.'); }
}

export function createMuseumServer(options: ServerOptions = {}): Server {
  const root = options.root || process.cwd();
  let inFlight = 0;
  const requests: number[] = [];
  const config = () => runtimeConfig(options.config);
  const server = createServer(async (request, response) => {
    try {
      if (!localHost(request.headers.host) || !allowedOrigin(request.headers.origin)) throw new ApiError(403, 'ORIGIN_REJECTED', 'This local service accepts localhost requests only.');
      const url = new URL(request.url || '/', 'http://localhost');
      const pathname = decodeURIComponent(url.pathname);
      if (request.method === 'GET' && pathname === '/api/config') {
        const cfg = config(); json(response, 200, { configured: hasKey(cfg), model: cfg.model, liveModel: cfg.liveModel }); return;
      }
      if (request.method === 'GET' && ['/api/health', '/health'].includes(pathname)) { json(response, 200, { ok: true, service: 'museum-companion' }); return; }
      if (request.method === 'POST' && ['/api/analyze', '/api/question', '/api/translate'].includes(pathname)) {
        if (!/application\/json/i.test(request.headers['content-type'] || '')) throw new ApiError(415, 'JSON_REQUIRED', 'Use application/json.');
        const data = await body(request);
        const language = languageOf(data.language);
        const cfg = config();
        if (data.demo !== true) requireKey(cfg);
        if (inFlight >= 2) throw new ApiError(429, 'BUSY', 'Two AI requests are already running. Please wait.');
        const now = Date.now(); while (requests.length && requests[0] < now - 60_000) requests.shift();
        if (requests.length >= 30) throw new ApiError(429, 'RATE_LIMIT', 'Too many requests. Please wait a minute.');
        requests.push(now); inFlight++;
        try {
          if (pathname === '/api/analyze') {
            // Validate actual image input even in demo mode: the UI must supply its input frame.
            const image = imageData(data.image);
            if (data.demo === true) { json(response, 200, demoAnalysis(language)); return; }
            json(response, 200, await analyze(image, language, textOf(data.artworkId, 100), options.generate || restGenerator(cfg)));
          } else if (pathname === '/api/translate') {
            const context = clientAnalysis(data.analysis);
            if ((data.demo === true) !== (context.mode === 'demo')) throw new ApiError(400, 'DEMO_CONTEXT', 'Translation mode must match the current tour.');
            json(response, 200, await translateAnalysis(context, language, data.demo === true ? undefined : options.generate || restGenerator(cfg)));
          } else {
            const question = textOf(data.question, 2000);
            if (!question) throw new ApiError(400, 'QUESTION_REQUIRED', 'Enter a question.');
            const context = clientAnalysis(data.analysis);
            if (data.demo !== true && context.mode === 'demo') throw new ApiError(400, 'DEMO_CONTEXT', 'Run Gemini image analysis before using live questions, or explicitly use demo mode.');
            json(response, 200, data.demo === true ? demoQuestion(question, language, context, textOf(data.currentDetailId, 80)) : await answerQuestion(question, language, context, textOf(data.currentDetailId, 80), options.generate || restGenerator(cfg)));
          }
        } finally { inFlight--; }
        return;
      }
      if (pathname.startsWith('/api/')) throw new ApiError(404, 'NOT_FOUND', 'API endpoint not found.');
      if (!['GET', 'HEAD'].includes(request.method || '')) throw new ApiError(405, 'METHOD_NOT_ALLOWED', 'Method not allowed.');
      if (pathname.split('/').some(part => part.startsWith('.'))) throw new ApiError(404, 'NOT_FOUND', 'File not found.');
      const relative = pathname.replace(/^\/+/, '');
      let selected: string | undefined;
      for (const directory of ['dist', 'public']) {
        const base = resolve(root, directory); const candidate = resolve(base, relative || 'index.html');
        if (candidate !== base && !candidate.startsWith(base + sep)) continue;
        try { if ((await stat(candidate)).isFile()) { selected = candidate; break; } } catch { /* Try next public directory. */ }
      }
      if (!selected && !extname(pathname)) {
        const candidate = resolve(root, 'dist/index.html');
        try { if ((await stat(candidate)).isFile()) selected = candidate; } catch { /* Build not available. */ }
      }
      if (!selected) throw new ApiError(404, 'NOT_BUILT', 'Application not built yet. Run npm run build, then npm start.');
      const types: Record<string, string> = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.wasm': 'application/wasm', '.mp4': 'video/mp4', '.webm': 'video/webm', '.woff2': 'font/woff2' };
      const content = await readFile(selected);
      response.writeHead(200, { 'Content-Type': types[extname(selected)] || 'application/octet-stream', 'Content-Length': content.length, 'Cache-Control': extname(selected) === '.html' ? 'no-store' : 'public, max-age=3600', 'X-Content-Type-Options': 'nosniff' });
      response.end(request.method === 'HEAD' ? undefined : content);
    } catch (error) {
      const safe = error instanceof ApiError ? error : error instanceof URIError ? new ApiError(400, 'INVALID_URL', 'Invalid URL.') : new ApiError(500, 'SERVER_ERROR', 'The local service encountered an error. Please retry.');
      if (!response.headersSent) json(response, safe.status, { error: safe.message, code: safe.code }); else response.end();
    }
  });
  const sockets = new WebSocketServer({ noServer: true, maxPayload: 2_000_000 });
  let liveCount = 0;
  server.on('upgrade', (request, socket, head) => {
    if (!localHost(request.headers.host) || !allowedOrigin(request.headers.origin) || request.url?.split('?')[0] !== '/api/live') { socket.write('HTTP/1.1 403 Forbidden\r\n\r\n'); socket.destroy(); return; }
    const cfg = config();
    if (!hasKey(cfg) || liveCount >= 2) { socket.write(`HTTP/1.1 ${hasKey(cfg) ? '429 Too Many Requests' : '503 Service Unavailable'}\r\n\r\n`); socket.destroy(); return; }
    sockets.handleUpgrade(request, socket, head, connection => {
      liveCount++;
      connection.once('close', () => { liveCount--; });
      attachLiveSocket(connection, cfg);
    });
  });
  server.on('close', () => { for (const socket of sockets.clients) socket.close(1001); sockets.close(); });
  return server;
}

export function startServer(): Server {
  const cfg = runtimeConfig();
  const server = createMuseumServer();
  server.listen(Number.isFinite(cfg.port) ? cfg.port : 4173, '127.0.0.1', () => console.log(`Museum Companion ready at http://127.0.0.1:${(server.address() as any).port}/ — Gemini ${hasKey(runtimeConfig()) ? 'configured' : 'not configured; explicit offline demo available'}`));
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) startServer();
