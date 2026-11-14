import { afterAll, beforeAll, expect, it } from 'vitest';
import { createMuseumServer } from '../server/index.ts';
import type { Server } from 'node:http';
let server: Server, base: string, calls = 0;
const image = 'data:image/png;base64,' + Buffer.alloc(64, 42).toString('base64');
beforeAll(async () => {
  server = createMuseumServer({ config: { apiKey: 'test-only-credential' }, generate: async request => {
    calls++;
    if (request.prompt.startsWith('Search the ENTIRE')) return { status: 'candidates', reason: 'Framed exhibit.', candidates: [{identityKey:'test-work',label:'Small framed exhibit',evidence:'Gallery label and frame.',kind:'planar',confidence:.92,box:[.1,.1,.3,.4]}] };
    return {roiVerified:true,artwork:{id:'unidentified',title:'Visible work'},overview:'A visual observation.',details:[{identityKey:'red-mark',title:'Red mark',description:'A visible red shape.',box_2d:[200,200,400,500],sourceIds:[]}]};
  }});
  await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  base = `http://127.0.0.1:${(server.address() as any).port}`;
});
afterAll(async () => {server.closeAllConnections();await new Promise<void>(resolve=>server.close(()=>resolve()));});
const post = (path: string, payload: unknown) => fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
it('runs v2 search/lock/ROI HTTP flow and rejects absent locks or undersampled crops before generation', async () => {
  const missing = await post('/api/analyze',{image,language:'en'});
  expect(missing.status).toBe(400);
  expect(calls).toBe(0);
  const first = await (await post('/api/artwork-candidates',{image,language:'en'})).json();
  expect(first.status).toBe('searching');
  const lock = await (await post('/api/artwork-candidates',{image,language:'en',previous:first})).json();
  expect(lock.status).toBe('locked');
  const insufficient = await post('/api/analyze',{image,lock,roi:{frameId:'tiny',frameWidth:100,frameHeight:100,box:lock.candidates[0].box}});
  expect(insufficient.status).toBe(422);
  expect(calls).toBe(2);
  const response = await post('/api/analyze',{image,lock,roi:{frameId:'frame-3',frameWidth:2000,frameHeight:1200,box:lock.candidates[0].box}});
  expect(response.status).toBe(200);
  const guide = await response.json();
  expect(guide.schemaVersion).toBe(2);
  expect(guide.coordinateSpace).toBe('artwork_roi');
  expect(guide.recognition.selectedCandidateId).toBe(lock.selectedCandidateId);
  expect(guide.details[0].box).toEqual([.2,.2,.3,.2]);
  expect(guide.sources).toEqual([]);
});
