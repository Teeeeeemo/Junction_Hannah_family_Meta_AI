import { createServer, request as httpRequest, type IncomingMessage, type IncomingHttpHeaders } from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

interface PreviewOptions { token: string; upstream?: string; expiresAt?: number; }
const COOKIE = 'museum_device_preview';
function sameToken(value: string | undefined, expected: string) {
  if (!value) return false;
  const supplied = Buffer.from(value), wanted = Buffer.from(expected);
  return supplied.length === wanted.length && timingSafeEqual(supplied, wanted);
}

// Temporary, authenticated HTTPS-tunnel entrance. The existing backend remains
// loopback-only; public requests never get blanket access to its paid AI APIs.
export function createDevicePreviewServer(options: PreviewOptions) {
  if (options.token.length < 32) throw new Error('A random preview token of at least 32 characters is required.');
  const upstream = new URL(options.upstream || 'http://127.0.0.1:4173');
  if (upstream.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(upstream.hostname)) throw new Error('Preview upstream must be a local HTTP service.');
  const expiresAt = options.expiresAt ?? Date.now() + 8 * 60 * 60_000;
  function authorized(request: IncomingMessage, allowQuery: boolean) {
    const cookie = request.headers.cookie?.split(';').map(part => part.trim()).find(part => part.startsWith(COOKIE + '='))?.slice(COOKIE.length + 1);
    const url = new URL(request.url || '/', 'http://preview.local');
    return sameToken(cookie, options.token) || (allowQuery && request.method === 'GET' && url.pathname === '/' && sameToken(url.searchParams.get('access') || undefined, options.token));
  }
  function sameOrigin(request: IncomingMessage) {
    if (!request.headers.origin) return true;
    try { const origin = new URL(request.headers.origin); return origin.protocol === 'https:' && origin.host === request.headers.host; }
    catch { return false; }
  }
  const server = createServer((request, response) => {
    if (Date.now() >= expiresAt) { response.writeHead(410, { 'Cache-Control': 'no-store' }); response.end('This device-test session has expired.'); return; }
    if (!authorized(request, true) || !sameOrigin(request)) { response.writeHead(401, { 'Cache-Control': 'no-store' }); response.end('Open the complete device-test link supplied for this session.'); return; }
    const url = new URL(request.url || '/', 'http://preview.local'); url.searchParams.delete('access');
    const headers: IncomingHttpHeaders = { ...request.headers, host: upstream.host };
    if (headers.origin) headers.origin = upstream.origin;
    delete headers.cookie; delete headers['x-forwarded-for']; delete headers['x-forwarded-host']; delete headers['x-forwarded-proto'];
    const outgoing = httpRequest(new URL(url.pathname + url.search, upstream), { method: request.method, headers }, incoming => {
      const outgoingHeaders = { ...incoming.headers, 'cache-control': 'no-store', 'referrer-policy': 'no-referrer', 'set-cookie': `${COOKIE}=${options.token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${Math.max(0, Math.floor((expiresAt - Date.now()) / 1000))}` };
      response.writeHead(incoming.statusCode || 502, outgoingHeaders); incoming.pipe(response);
    });
    outgoing.on('error', () => { if (!response.headersSent) response.writeHead(502, { 'Cache-Control': 'no-store' }); response.end('The museum app is not running on this Mac.'); });
    request.on('aborted', () => outgoing.destroy()); response.on('close', () => outgoing.destroy());
    request.pipe(outgoing);
  });
  const sockets = new WebSocketServer({ noServer: true, maxPayload: 2_000_000 });
  const remotes = new Set<WebSocket>();
  server.on('upgrade', (request, socket, head) => {
    const reject = (status = 401) => { if (!socket.destroyed) { socket.write(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\n\r\n`); socket.destroy(); } };
    if (Date.now() >= expiresAt || !authorized(request, false) || !sameOrigin(request) || request.url !== '/api/live') { reject(); return; }
    const remote = new WebSocket(new URL('/api/live', upstream.origin.replace(/^http:/, 'ws:')), { origin: upstream.origin, handshakeTimeout: 8000, maxPayload: 2_000_000 });
    remotes.add(remote); remote.once('close', () => remotes.delete(remote));
    socket.once('close', () => { if (remote.readyState === WebSocket.CONNECTING) remote.terminate(); });
    remote.once('error', () => reject(502));
    remote.once('unexpected-response', (_request, response) => { response.resume(); reject(response.statusCode || 502); remote.terminate(); });
    remote.once('open', () => {
      if (socket.destroyed) { remote.close(); return; }
      sockets.handleUpgrade(request, socket, head, client => {
        client.on('message', (data, binary) => { if (remote.readyState === WebSocket.OPEN) remote.send(data, { binary }); });
        remote.on('message', (data, binary) => { if (client.readyState === WebSocket.OPEN) client.send(data, { binary }); });
        client.on('error', () => remote.close()); remote.on('error', () => client.close(1011));
        client.once('close', () => remote.close()); remote.once('close', () => client.close());
      });
    });
  });
  server.once('close', () => { for (const client of sockets.clients) client.terminate(); for (const remote of remotes) remote.terminate(); sockets.close(); });
  return server;
}

async function main() {
  const token = randomBytes(32).toString('base64url');
  const port = Number(process.env.DEVICE_PREVIEW_PORT || 4174);
  const expiresAt = Date.now() + 8 * 60 * 60_000;
  const statePath = process.env.DEVICE_PREVIEW_STATE || resolve(tmpdir(), 'museum-device-preview.json');
  const server = createDevicePreviewServer({ token, expiresAt });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  await mkdir(dirname(statePath), { recursive: true });
  await writeFile(statePath, JSON.stringify({ token, port, expiresAt, pid: process.pid }), { mode: 0o600 });
  console.log(`Device preview ready at http://127.0.0.1:${port}; access credential saved in the temporary session state.`);
  process.once('SIGTERM', () => server.close()); process.once('SIGINT', () => server.close());
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) void main();
