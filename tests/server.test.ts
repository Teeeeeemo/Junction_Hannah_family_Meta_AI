import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { Server } from 'node:http';
import { createMuseumServer } from '../server/index.ts';
import { demoAnalysis } from '../server/content.ts';
import { analyze, demoQuestion, localCommand, translateAnalysis } from '../server/gemini.ts';
import { clientAnalysis, imageData, normalizeAnalysis } from '../server/validation.ts';

const IMAGE = 'data:image/png;base64,' + Buffer.alloc(64, 42).toString('base64');

describe('visual analysis validation and tour commands', () => {
  it('converts Gemini yxyx/1000 proposals to normalized xywh and filters bad regions/citations', () => {
    const result = normalizeAnalysis({ artwork: { id: 'met-436535', title: 'A work' }, overview: 'Intro', details: [
      { title: 'Tree', description: 'Visible tree.', box_2d: [200, 700, 800, 900], sourceIds: ['met-436535', 'invented-source'] },
      { title: 'Impossible', description: 'Outside.', box_2d: [-10, 0, 1000, 1500] },
      { title: 'Tree', description: 'Duplicate.', box_2d: [200, 700, 800, 900] },
    ], sources: [{ id: 'invented-source', url: 'https://invented.example' }] }, 'gemini', true);
    expect(result.details).toHaveLength(1);
    expect(result.details[0].box).toEqual([0.7, 0.2, 0.2, 0.6]);
    expect(result.details[0].sourceIds).toEqual(['met-436535']);
    expect(result.sources).toHaveLength(1);
    expect(result.sources[0].url).toContain('metmuseum.org');
  });
  it('never attaches museum provenance to an unknown image merely because the model invents it', () => {
    const result = normalizeAnalysis({ ...demoAnalysis('en'), artwork: { id: 'met-436535', title: 'Invented' } }, 'gemini', false);
    expect(result.artwork.id).toBe('unidentified');
    expect(result.sources).toEqual([]);
    expect(result.details.every(detail => detail.sourceIds.length === 0)).toBe(true);
  });
  it('accepts a verified empty detail list rather than filling prepared points', async () => {
    const result = await analyze({ data: 'AAAA', mimeType: 'image/png' }, 'en', undefined, async () => ({ artwork: { id: 'unidentified', title: 'Blank image' }, overview: 'No artwork can be identified.', details: [] }));
    expect(result.mode).toBe('gemini');
    expect(result.details).toEqual([]);
  });
  it('rejects remote URLs and malformed image payloads', () => {
    expect(() => imageData('https://internal.example/secret')).toThrow();
    expect(() => imageData('data:image/svg+xml;base64,PHN2Zz4=')).toThrow();
    expect(() => imageData('data:image/png;base64,not valid')).toThrow();
    expect(imageData(IMAGE).mimeType).toBe('image/png');
  });
  it('preserves stable detail IDs across context validation and rejects duplicate or reordered numbering', () => {
    expect(clientAnalysis(demoAnalysis('en')).details.map(detail => detail.id)).toEqual(['cypress', 'clouds', 'wheat']);
    const duplicate = demoAnalysis('en'); duplicate.details[1].id = duplicate.details[0].id;
    expect(() => clientAnalysis(duplicate)).toThrow();
    const renumbered = demoAnalysis('en'); renumbered.details[0].number = 3;
    expect(() => clientAnalysis(renumbered)).toThrow();
  });
  it('maps bilingual explicit point selection to the same stable ID and never wraps an invalid index', () => {
    const context = demoAnalysis('en');
    expect(localCommand('Tell me about point three', context)?.selectedDetailId).toBe('wheat');
    expect(localCommand('讲第 3 个', context)?.selectedDetailId).toBe('wheat');
    expect(localCommand('讲第三个', context)?.selectedDetailId).toBe('wheat');
    expect(localCommand('point 9', context)?.selectedDetailId).toBeUndefined();
    expect(localCommand('continue', context)?.command).toBe('resume');
    expect(localCommand('放大四倍', context)?.zoom).toBe(4);
  });
  it('labels canned answers as offline demonstration', () => {
    const answer = demoQuestion('What is the meaning?', 'en', demoAnalysis('en'), 'cypress');
    expect(answer.mode).toBe('demo');
    expect(answer.answer).toContain('not a live Gemini answer');
  });
  it('translates text without changing stable IDs, numbering, boxes or citations, even if model order differs', async () => {
    const context = { ...demoAnalysis('en'), mode: 'gemini' as const };
    const translated = await translateAnalysis(context, 'zh', async () => ({ artworkTitle: '中文画名', overview: '中文介绍', details: [...context.details].reverse().map(detail => ({ id: detail.id, title: '中文'+detail.number, description: '中文讲解'+detail.number })) }));
    expect(translated.details.map(({ id, number, box, sourceIds }) => ({ id, number, box, sourceIds }))).toEqual(context.details.map(({ id, number, box, sourceIds }) => ({ id, number, box, sourceIds })));
    expect(translated.artwork.id).toBe(context.artwork.id);
    expect(translated.sources).toEqual(context.sources);
    expect(translated.details[0].title).toBe('中文1');
    expect(context.details[0].title).toBe('Cypress trees');
  });
  it('rejects incomplete translation instead of silently replacing geometry or dropping a point', async () => {
    const context = { ...demoAnalysis('en'), mode: 'gemini' as const };
    await expect(translateAnalysis(context, 'zh', async () => ({ artworkTitle: '画名', overview: '介绍', details: [] }))).rejects.toThrow('incomplete translation');
  });
});

describe('local HTTP API boundaries', () => {
  let server: Server;
  let base: string;
  let modelCalls = 0;
  beforeAll(async () => {
    server = createMuseumServer({ config: { apiKey: '' }, generate: async () => { modelCalls++; throw new Error('Should never run without credentials'); } });
    await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); });
  const post = async (path: string, payload: unknown, origin?: string) => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(origin ? { Origin: origin } : {}) }, body: JSON.stringify(payload) });

  it('returns safe config metadata without credentials', async () => {
    const response = await fetch(base + '/api/config');
    const value = await response.json();
    expect(value.configured).toBe(false);
    expect(value.apiKey).toBeUndefined();
    expect(Object.keys(value).sort()).toEqual(['configured', 'liveModel', 'model']);
  });
  it('does not silently substitute demo results when Gemini is not configured', async () => {
    const response = await post('/api/analyze', { image: IMAGE, language: 'en' });
    expect(response.status).toBe(503);
    expect((await response.json()).code).toBe('CONFIG_REQUIRED');
    expect(modelCalls).toBe(0);
  });
  it('requires explicit demo opt-in and keeps its visible mode label', async () => {
    const response = await post('/api/analyze', { image: IMAGE, language: 'zh', demo: true });
    expect(response.status).toBe(200);
    const value = await response.json();
    expect(value.mode).toBe('demo');
    expect(value.overview).toContain('离线演示');
    expect(value.details.map((detail: any) => detail.number)).toEqual([1, 2, 3]);
  });
  it('rejects cross-site attempts to spend the local API quota', async () => {
    const response = await post('/api/analyze', { image: IMAGE, demo: true }, 'https://unrelated.example');
    expect(response.status).toBe(403);
  });
  it('does not expose local configuration files through static serving', async () => {
    const response = await fetch(base + '/.env.local');
    expect(response.status).toBe(404);
  });
  it('keeps free-form offline answers explicit and returns stable selected IDs', async () => {
    const response = await post('/api/question', { question: '讲第 3 个', language: 'zh', analysis: demoAnalysis('zh'), currentDetailId: 'cypress', demo: true });
    const value = await response.json();
    expect(response.status).toBe(200);
    expect(value.mode).toBe('demo');
    expect(value.selectedDetailId).toBe('wheat');
  });
  it('supports offline translation with the same detail geometry and IDs', async () => {
    const original = demoAnalysis('en');
    const response = await post('/api/translate', { analysis: original, language: 'zh', demo: true });
    const value = await response.json();
    expect(response.status).toBe(200);
    expect(value.details.map((detail: any) => [detail.id, detail.number, detail.box])).toEqual(original.details.map(detail => [detail.id, detail.number, detail.box]));
    expect(value.artwork.title).toBe('麦田与柏树');
  });
});
