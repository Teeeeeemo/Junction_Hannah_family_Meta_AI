import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { once } from 'node:events';
import { WebSocket, WebSocketServer } from 'ws';
import { createDevicePreviewServer } from '../server/device-preview.ts';

const TOKEN = 'unit-test-preview-token-32-characters';
describe('temporary device-test entrance', () => {
  let upstream: Server, preview: Server, base: string, origin: string;
  const wsServer = new WebSocketServer({ noServer: true });
  let receivedHeaders: Record<string, unknown> = {};
  let calls = 0;
  beforeAll(async () => {
    upstream = createServer((request, response) => { calls++; receivedHeaders = request.headers; response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ path: request.url })); });
    upstream.on('upgrade', (request, socket, head) => wsServer.handleUpgrade(request, socket, head, connection => connection.on('message', data => connection.send(data.toString()))));
    upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
    origin = `http://127.0.0.1:${(upstream.address() as any).port}`;
    preview = createDevicePreviewServer({ token: TOKEN, upstream: origin });
    preview.listen(0, '127.0.0.1'); await once(preview, 'listening');
    base = `http://127.0.0.1:${(preview.address() as any).port}`;
  });
  afterAll(async () => {
    for (const client of wsServer.clients) client.terminate();
    preview.closeAllConnections(); upstream.closeAllConnections();
    await Promise.all([new Promise<void>(resolve => preview.close(() => resolve())), new Promise<void>(resolve => upstream.close(() => resolve()))]);
    wsServer.close();
  });
  it('does not forward unauthenticated paid API requests', async () => {
    const before = calls;
    const response = await fetch(base + '/api/analyze', { method: 'POST', body: '{}' });
    expect(response.status).toBe(401); expect(calls).toBe(before);
  });
  it('accepts the complete entry link, issues a secure cookie and removes the access credential upstream', async () => {
    const response = await fetch(base + '/?access=' + TOKEN);
    expect(response.status).toBe(200);
    expect((await response.json()).path).toBe('/');
    expect(response.headers.get('set-cookie')).toContain('HttpOnly; Secure; SameSite=Strict');
    expect(response.headers.get('referrer-policy')).toBe('no-referrer');
    expect(receivedHeaders.cookie).toBeUndefined();
  });
  it('accepts a session cookie and rewrites same-site Origin only for the fixed local upstream', async () => {
    const response = await fetch(base + '/api/config', { headers: { Origin: 'https://' + new URL(base).host, Cookie: 'museum_device_preview=' + TOKEN } });
    expect(response.status).toBe(200);
    expect(receivedHeaders.origin).toBe(origin);
    expect(receivedHeaders.host).toBe(new URL(origin).host);
    expect(response.headers.get('cache-control')).toBe('no-store');
  });
  it('rejects foreign origins and does not accept credentials in arbitrary API query strings', async () => {
    const response = await fetch(base + '/api/analyze', { method: 'POST', headers: { Host: 'preview.example', Origin: 'https://foreign.example', Cookie: 'museum_device_preview=' + TOKEN }, body: '{}' });
    expect(response.status).toBe(401);
    expect((await fetch(base + '/api/config?access=' + TOKEN)).status).toBe(401);
  });
  it('forwards authenticated live WebSocket messages in both directions', async () => {
    const socket = new WebSocket(base.replace(/^http/, 'ws') + '/api/live', { origin: 'https://' + new URL(base).host, headers: { Cookie: 'museum_device_preview=' + TOKEN } });
    await once(socket, 'open');
    const reply = once(socket, 'message'); socket.send('test-live-voice-event');
    expect((await reply)[0].toString()).toBe('test-live-voice-event');
    socket.close(); await once(socket, 'close');
  });
  it('requires a long credential and rejects a remote proxy target', () => {
    expect(() => createDevicePreviewServer({ token: 'short' })).toThrow();
    expect(() => createDevicePreviewServer({ token: TOKEN, upstream: 'http://remote.example' })).toThrow();
  });
  it('rejects an unauthenticated Live WebSocket before it reaches the upstream', async () => {
    const socket = new WebSocket(base.replace(/^http/, 'ws') + '/api/live'); socket.on('error', () => {});
    const [, response] = await once(socket, 'unexpected-response');
    expect(response.statusCode).toBe(401); response.resume(); socket.terminate();
  });
  it('expires an old preview session even with the right credential', async () => {
    const expired = createDevicePreviewServer({ token: TOKEN, upstream: origin, expiresAt: 1 });
    expired.listen(0, '127.0.0.1'); await once(expired, 'listening');
    try { const response = await fetch(`http://127.0.0.1:${(expired.address() as any).port}/?access=${TOKEN}`); expect(response.status).toBe(410); }
    finally { expired.closeAllConnections(); await new Promise<void>(resolve => expired.close(() => resolve())); }
  });
});
