import { strict as assert } from 'node:assert';
import { randomBytes } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import type { Server } from 'node:http';
import { WebSocket } from 'ws';
import { createMuseumServer } from '../server/index.ts';
import { createDevicePreviewServer } from '../server/device-preview.ts';
import { runtimeConfig, hasKey } from '../server/gemini.ts';
import type { Analysis, ArtworkSearch } from '../src/contracts.ts';

// Opt-in, paid real-service acceptance. Only the bundled public-domain Met
// painting is uploaded. No microphone, private images, keys or cookies are saved.
const cfg = runtimeConfig();
const output = resolve(process.env.MUSE_GEMINI_EVIDENCE || '../build-artifacts/gemini-real-' + new Date().toISOString().replace(/[:.]/g, '-'));
const summary: Record<string, unknown> = { startedAt: new Date().toISOString(), model: cfg.model, liveModel: cfg.liveModel, input: 'Bundled public-domain Met 436535 image; synthetic one-pixel crop for second observation', checks: {} };
const checks = summary.checks as Record<string, unknown>;
const safe = (value: string) => (cfg.apiKey ? value.replaceAll(cfg.apiKey, '[redacted]') : value).replace(/(?:https?|wss?):\/\/\S+/g, '[endpoint]');
const save = async (name: string, value: unknown) => writeFile(resolve(output, name), JSON.stringify(value, null, 2));
let museum: Server | undefined, preview: Server | undefined, socket: WebSocket | undefined;
const events: Array<Record<string, unknown>> = [];
const listen = (server: Server) => new Promise<number>((done, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', () => done((server.address() as { port: number }).port)); });
const close = (server?: Server) => new Promise<void>(done => { if (!server) return done(); server.close(() => done()); server.closeAllConnections(); });

async function main() {
  assert(hasKey(cfg), 'Configure the project .env.local before running this paid integration check.');
  await mkdir(output, { recursive: true });
  const modelsResponse = await fetch('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000', { headers: { 'x-goog-api-key': cfg.apiKey }, signal: AbortSignal.timeout(20_000) });
  assert.equal(modelsResponse.status, 200, 'Real Gemini model listing failed');
  const catalog = await modelsResponse.json() as any;
  const models = catalog.models.map((model: any) => ({ name: model.name, methods: model.supportedGenerationMethods || [] }));
  await save('models.json', models);
  assert(models.some((model: any) => model.name === 'models/' + cfg.liveModel && model.methods.includes('bidiGenerateContent')), 'Configured Live model does not advertise bidiGenerateContent');
  checks.modelCatalogue = 'passed'; console.log('Real model catalogue verified.');
  if (process.argv.includes('--models-only')) return;

  museum = createMuseumServer();
  const museumPort = await listen(museum);
  const token = randomBytes(32).toString('base64url');
  preview = createDevicePreviewServer({ token, upstream: `http://127.0.0.1:${museumPort}` });
  const previewPort = await listen(preview);
  const host = `127.0.0.1:${previewPort}`, origin = `https://${host}`;
  const entry = await fetch(`http://${host}/?access=${token}`);
  assert.equal(entry.status, 200, 'Authenticated preview entry failed');
  const cookie = entry.headers.get('set-cookie')?.split(';')[0]; assert(cookie, 'Preview did not issue an authentication cookie');
  const post = async <T>(path: string, body: unknown): Promise<T> => {
    const response = await fetch(`http://${host}${path}`, { method: 'POST', headers: { Cookie: cookie, Origin: origin, 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(60_000) });
    const result = await response.json() as any;
    assert.equal(response.status, 200, `${path}: ${result.code || response.status}: ${result.error || ''}`);
    return result as T;
  };
  let analysis: Analysis;
  if (process.env.MUSE_GEMINI_ANALYSIS) {
    analysis = JSON.parse(await readFile(resolve(process.env.MUSE_GEMINI_ANALYSIS), 'utf8'));
    summary.reusedRealAnalysis = true;
  } else {
    const source = resolve('public/artworks/wheat-field.jpg');
    const dimensions = execFileSync('/usr/bin/sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', source], { encoding: 'utf8' });
    const width = Number(dimensions.match(/pixelWidth: (\d+)/)?.[1]);
    const height = Number(dimensions.match(/pixelHeight: (\d+)/)?.[1]);
    assert(width > 96 && height > 96);
    const secondPath = resolve(output, 'public-artwork-second-frame.jpg');
    execFileSync('/usr/bin/sips', ['--cropToHeightWidth', String(height - 1), String(width), source, '--out', secondPath], { stdio: 'ignore' });
    const image = (bytes: Buffer) => 'data:image/jpeg;base64,' + bytes.toString('base64');
    const first = await post<ArtworkSearch>('/api/artwork-candidates', { image: image(await readFile(source)), language: 'en', demo: false });
    await save('search-first.json', first); console.log('First real artwork search:', first.status);
    const second = await post<ArtworkSearch>('/api/artwork-candidates', { image: image(await readFile(secondPath)), language: 'en', demo: false, previous: first });
    await save('search-second.json', second); console.log('Second real artwork search:', second.status);
    assert.equal(second.status, 'locked', 'Two real image observations did not lock the same artwork');
    const selected = second.candidates.find(candidate => candidate.id === second.selectedCandidateId); assert(selected);
    const [x, y, w, h] = selected.box;
    const cropX = Math.floor(x * width), cropY = Math.floor(y * (height - 1));
    const cropWidth = Math.min(width - cropX, Math.ceil(w * width)), cropHeight = Math.min(height - 1 - cropY, Math.ceil(h * (height - 1)));
    const roiPath = resolve(output, 'public-artwork-roi.jpg');
    execFileSync('/usr/bin/sips', ['--cropToHeightWidth', String(cropHeight), String(cropWidth), '--cropOffset', String(cropY), String(cropX), secondPath, '--out', roiPath], { stdio: 'ignore' });
    const roi = { frameId: 'public-met-synthetic-frame-2', frameWidth: width, frameHeight: height - 1, box: selected.box };
    analysis = await post<Analysis>('/api/analyze', { image: image(await readFile(roiPath)), language: 'en', demo: false, artworkId: 'met-436535', lock: second, roi });
    assert.equal(analysis.mode, 'gemini'); assert.equal(analysis.artwork.id, 'met-436535'); assert(analysis.details.length > 0); assert.equal(analysis.coordinateSpace, 'artwork_roi');
    checks.realSearchLockROIAnalysis = { status: 'passed', details: analysis.details.length, sourceIds: analysis.sources.map(source => source.id), originalWidth: width, originalHeight: height - 1, cropWidth, cropHeight };
    await save('analysis.json', analysis); console.log('Real locked-ROI artwork analysis verified.');
  }

  const pcm: Buffer[] = [];
  let expectedID = 0, discardedOld = 0;
  socket = new WebSocket(`ws://${host}/api/live`, { headers: { Cookie: cookie, Origin: origin }, handshakeTimeout: 15_000 });
  const inbox: any[] = [];
  let wake: (() => void) | undefined;
  socket.on('message', bytes => {
    const event = JSON.parse(bytes.toString());
    const metadata = { type: event.type, playbackId: event.playbackId, ...(event.type === 'audio' ? { mimeType: event.mimeType, bytes: Buffer.from(event.data, 'base64').length } : {}), ...(event.type === 'transcript' ? { role: event.role, text: event.text } : {}), ...(event.type === 'error' ? { message: safe(event.message) } : {}) };
    events.push(metadata);
    if (event.playbackId < expectedID) { discardedOld++; return; }
    inbox.push(event); wake?.();
  });
  let socketError = false;
  socket.on('error', () => { socketError = true; wake?.(); });
  const next = async (kind: string, id: number, milliseconds = 60_000) => {
    const until = Date.now() + milliseconds;
    while (Date.now() < until) {
      assert(!socketError, 'Live websocket transport failed');
      const failure = inbox.find(event => event.type === 'error' || event.type === 'closed');
      assert(!failure, safe(failure?.message || 'Live session closed'));
      const index = inbox.findIndex(event => event.type === kind && event.playbackId === id);
      if (index >= 0) return inbox.splice(index, 1)[0];
      await new Promise<void>(done => { const timer = setTimeout(() => { wake = undefined; done(); }, Math.min(500, until - Date.now())); wake = () => { clearTimeout(timer); wake = undefined; done(); }; });
    }
    throw new Error(`Timed out waiting for real Live ${kind}, playback ${id}`);
  };
  await new Promise<void>((done, reject) => { socket!.once('open', done); socket!.once('error', () => reject(new Error('Live websocket handshake failed'))); });
  const send = (message: unknown) => socket!.send(JSON.stringify(message));
  send({ type: 'start', context: analysis, language: 'en', playbackRate: 1 });
  await next('ready', 0); console.log('Real Gemini Live ready via authenticated preview.');
  send({ type: 'text', text: 'Read exactly once: The cypress trees rise above the golden wheat field. The clouds move across a blue sky. Keep describing the visible landscape in six short sentences.' });
  const audio = await next('audio', 0); assert.equal(audio.mimeType, 'audio/pcm;rate=24000');
  const firstPCM = Buffer.from(audio.data, 'base64'); assert(firstPCM.length > 0 && firstPCM.length % 2 === 0); pcm.push(firstPCM);
  expectedID = 1;
  send({ type: 'interrupt', playbackId: 1 });
  send({ type: 'context', context: analysis, language: 'en', currentDetailId: analysis.details[0].id });
  send({ type: 'text', text: 'Read exactly this short sentence once: Golden wheat fills the foreground.' });
  await next('resumed', 1);
  const fresh = await next('audio', 1); assert.equal(fresh.mimeType, 'audio/pcm;rate=24000');
  pcm.push(Buffer.from(fresh.data, 'base64'));
  await next('transcript', 1);
  await next('turn_complete', 1);
  checks.realLive = { status: 'passed', ready: true, resumed: true, audio24k: true, assistantTranscript: events.some(event => event.type === 'transcript' && event.playbackId === 1 && event.role === 'assistant'), turnComplete: true, manualInterruptPlaybackId: 1, discardedOldPackets: discardedOld, note: 'Actual service PCM received; no native AVAudioEngine or physical output/microphone validation.' };
  // A small WAV is received public-artwork narration, never microphone input.
  const samples = Buffer.concat(pcm), wav = Buffer.alloc(44);
  wav.write('RIFF'); wav.writeUInt32LE(samples.length + 36, 4); wav.write('WAVEfmt ', 8); wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(24_000, 24); wav.writeUInt32LE(48_000, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36); wav.writeUInt32LE(samples.length, 40);
  await writeFile(resolve(output, 'artifact.wav'), Buffer.concat([wav, samples]));
  send({ type: 'stop' }); console.log('Real Live PCM, transcript, completion and interrupted playback epoch verified.');
}

try { await main(); summary.result = 'passed'; }
catch (error) { summary.result = 'failed'; summary.error = safe(error instanceof Error ? error.message : 'Integration check failed'); console.error(summary.error); process.exitCode = 1; }
finally {
  socket?.terminate(); await close(preview); await close(museum);
  await save('live-events.json', events);
  await mkdir(output, { recursive: true }); await save('summary.json', { ...summary, finishedAt: new Date().toISOString() });
  console.log('Evidence:', output);
}
