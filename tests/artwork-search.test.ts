import { describe, expect, it } from 'vitest';
import { searchArtwork, analyze } from '../server/gemini.ts';
import { clientAnalysis } from '../server/validation.ts';
const image = { data: 'AAAA', mimeType: 'image/jpeg' };
const painting = { identityKey: 'blue-cypress-landscape', label: 'Small painting', box: [0.06, 0.12, 0.19, 0.2], confidence: 0.94, evidence: 'framed painted image beside a museum label', kind: 'planar' };
const raw = (candidates: unknown[], status = 'candidates') => ({ status, reason: 'Visible exhibition context.', candidates });

describe('artwork search and locked ROI protocol', () => {
  it('locks a small painting across independent observations while ignoring unsupported clutter', async () => {
    const generate = async () => raw([painting, { identityKey: 'bottle', label: 'Bottle', box: [0.4, 0.3, 0.5, 0.6], confidence: 0.96, evidence: '', kind: 'object' }]);
    const first = await searchArtwork(image, 'en', undefined, undefined, generate);
    expect(first.status).toBe('searching');
    expect(first.candidates).toHaveLength(1);
    const second = await searchArtwork(image, 'en', first, undefined, generate);
    expect(second.status).toBe('locked');
    expect(second.selectedCandidateId).toBe(first.candidates[0].id);
    expect(second.observationCount).toBe(2);
  });
  it('refuses automatic choice among multiple supported works but accepts explicit confirmation', async () => {
    const generate = async () => raw([painting, { ...painting, identityKey: 'red-portrait', label: 'Portrait', box: [0.5, 0.2, 0.3, 0.4] }]);
    const first = await searchArtwork(image, 'en', undefined, undefined, generate);
    expect(first.status).toBe('needs_confirmation');
    expect((await searchArtwork(image, 'en', first, undefined, generate)).status).toBe('needs_confirmation');
    const chosen = first.candidates[1].id;
    expect((await searchArtwork(image, 'en', first, chosen, generate)).selectedCandidateId).toBe(chosen);
    expect((await searchArtwork(image, 'en', first, chosen, generate)).status).toBe('locked');
  });
  it('rejects empty, blurred, occluded and weak evidence instead of making a tour', async () => {
    for (const value of [raw([], 'no_artwork'), raw([painting], 'uncertain'), raw([{ ...painting, confidence: 0.4 }])]) {
      const result = await searchArtwork(image, 'en', undefined, undefined, async () => value);
      expect(['no_artwork', 'uncertain']).toContain(result.status);
      expect(result.selectedCandidateId).toBeUndefined();
    }
  });
  it('allows an everyday object when actual exhibition context supports it, without a class blacklist', async () => {
    const generate = async () => raw([{ ...painting, identityKey: 'exhibited-bottle', label: 'Bottle installation', evidence: 'Bottle on labelled gallery plinth', kind: 'object' }]);
    const first = await searchArtwork(image, 'en', undefined, undefined, generate);
    expect((await searchArtwork(image, 'en', first, undefined, generate)).status).toBe('locked');
  });
  it('does not carry stability across a different identity or discontinuous region', async () => {
    const first = await searchArtwork(image, 'en', undefined, undefined, async () => raw([painting]));
    const moved = await searchArtwork(image, 'en', first, undefined, async () => raw([{ ...painting, box: [0.7, 0.7, 0.2, 0.2] }]));
    expect(moved.status).toBe('searching');
    expect(moved.observationCount).toBe(1);
  });
  it('requires a lock, re-verifies ROI, retains stable IDs and records crop coordinates', async () => {
    const first = await searchArtwork(image, 'en', undefined, undefined, async () => raw([painting]));
    const lock = await searchArtwork(image, 'en', first, undefined, async () => raw([painting]));
    const roi = { frameId: 'frame-22', frameWidth: 3000, frameHeight: 2000, box: painting.box };
    await expect(analyze(image, 'en', undefined, async () => ({}), { lock: first, roi })).rejects.toThrow('Lock');
    const generated = { artwork: { id: 'unidentified', title: 'Painting' }, overview: 'Visible blue landscape.', roiVerified: true, details: [{ identityKey: 'left-tree', title: 'Tree', description: 'Dark tree.', box_2d: [100, 100, 600, 300], sourceIds: [] }] };
    const result = await analyze(image, 'en', undefined, async () => generated, { lock, roi });
    expect(result.coordinateSpace).toBe('artwork_roi');
    expect(result.roi).toEqual(roi);
    expect(result.recognition?.selectedCandidateId).toBe(lock.selectedCandidateId);
    expect(result.details[0].id).not.toBe('detail-1');
    expect(clientAnalysis(result)).toEqual(result);
    await expect(analyze(image, 'en', undefined, async () => ({ ...generated, roiVerified: false }), { lock, roi })).rejects.toThrow('verify');
  });
  it('does not publish invented authors or duplicate detail identity keys for an unknown exhibit', async () => {
    const first = await searchArtwork(image, 'en', undefined, undefined, async () => raw([painting]));
    const lock = await searchArtwork(image, 'en', first, undefined, async () => raw([painting]));
    const detail = { identityKey: 'tree', title: 'Tree', description: 'Visible.', box_2d: [100,100,600,300] };
    const result = await analyze(image, 'en', undefined, async () => ({ artwork: {id:'unidentified', title:'Unknown exhibit',artist:'Invented artist',year:'1650'}, overview:'Visible scene.',roiVerified:true,details:[null,detail,{...detail,title:'Other name'}] }), {lock,roi:{frameId:'f1',frameWidth:3000,frameHeight:2000,box:painting.box}});
    expect(result.artwork.artist).toBe('Unknown');
    expect(result.artwork.year).toBe('Unknown');
    expect(result.details).toHaveLength(1);
  });

  it('keeps IDs independent of model detail order when appearance keys remain identical', async () => {
    const first = await searchArtwork(image, 'en', undefined, undefined, async () => raw([painting]));
    const lock = await searchArtwork(image, 'en', first, undefined, async () => raw([painting]));
    const roi = {frameId:'rescan',frameWidth:3000,frameHeight:2000,box:painting.box};
    const tree = {identityKey:'left-tree',title:'Tree',description:'Visible tree.',box_2d:[100,100,600,300]};
    const cloud = {identityKey:'upper-cloud',title:'Cloud',description:'Visible cloud.',box_2d:[100,400,300,800]};
    const run = (details: unknown[]) => analyze(image,'en',undefined,async()=>({artwork:{id:'unidentified',title:'Painting'},overview:'Visible scene.',roiVerified:true,details}),{lock,roi});
    const initial = await run([tree,cloud]), reordered = await run([cloud,tree]);
    expect(reordered.details.find(detail=>detail.title==='Tree')?.id).toBe(initial.details[0].id);
    // Current protocol creates a fresh list per analysis: cross-rescan numbering is not reconciled.
    expect(reordered.details.find(detail=>detail.title==='Tree')?.number).toBe(2);
    // Same physical feature with a new generated appearance key currently has no semantic matching.
    const renamed = await run([{...tree,identityKey:'dark-cypress'}]);
    expect(renamed.details[0].id).not.toBe(initial.details[0].id);
  });

});
