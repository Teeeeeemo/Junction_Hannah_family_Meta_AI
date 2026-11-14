import type { Analysis, ArtworkCandidate, ArtworkROI, ArtworkSearch, Box, Detail, Language, Source } from '../src/contracts.ts';
import { MET_SOURCE } from './content.ts';

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}

export function languageOf(value: unknown): Language { return value === 'zh' ? 'zh' : 'en'; }
export function textOf(value: unknown, max = 1600): string { return typeof value === 'string' ? value.trim().slice(0, max) : ''; }
export function imageData(value: unknown): { mimeType: string; data: string } {
  if (typeof value !== 'string') throw new ApiError(400, 'INVALID_IMAGE', 'Provide an image data URL.');
  const match = /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/]+={0,2})$/.exec(value);
  if (!match || match[2].length % 4 === 1) throw new ApiError(400, 'INVALID_IMAGE', 'Only base64 JPEG, PNG, or WebP images are accepted.');
  if (match[2].length > 8_000_000) throw new ApiError(413, 'IMAGE_TOO_LARGE', 'Resize the image below 6 MB.');
  const bytes = Buffer.from(match[2], 'base64');
  if (bytes.length < 16) throw new ApiError(400, 'INVALID_IMAGE', 'The image is empty or incomplete.');
  return { mimeType: match[1], data: match[2] };
}

export function validBox(value: unknown, thousand = false): Box | null {
  if (!Array.isArray(value) || value.length !== 4 || !value.every(Number.isFinite)) return null;
  let [x, y, width, height] = value as number[];
  if (thousand) {
    const [ymin, xmin, ymax, xmax] = value as number[];
    x = xmin / 1000; y = ymin / 1000; width = (xmax - xmin) / 1000; height = (ymax - ymin) / 1000;
  }
  if (x < 0 || y < 0 || x > 1 || y > 1 || width < 0.01 || height < 0.01 || x + width > 1.001 || y + height > 1.001) return null;
  return [x, y, Math.min(width, 1 - x), Math.min(height, 1 - y)];
}

/** Server controls source URLs: the model can refer to known IDs, never mint citations. */
export function normalizeAnalysis(raw: unknown, mode: 'gemini' | 'demo', knownArtwork = false): Analysis {
  if (!raw || typeof raw !== 'object') throw new ApiError(502, 'INVALID_MODEL_RESPONSE', 'The model returned no usable analysis.');
  const value = raw as Record<string, any>;
  const artwork = value.artwork && typeof value.artwork === 'object' ? value.artwork : {};
  const verified = knownArtwork && artwork.id === MET_SOURCE.id;
  const sources: Source[] = verified ? [MET_SOURCE] : [];
  const sourceIds = new Set(sources.map(source => source.id));
  const details: Detail[] = [];
  const candidates = Array.isArray(value.details) ? value.details.slice(0, 8) : [];
  for (const candidate of candidates) {
    if (!candidate || typeof candidate !== 'object') continue;
    const box = candidate.box_2d ? validBox(candidate.box_2d, true) : validBox(candidate.box);
    const title = textOf(candidate.title, 100);
    const description = textOf(candidate.description, 1800);
    if (!box || !title || !description || details.some(detail => detail.title.toLowerCase() === title.toLowerCase())) continue;
    const proposedId = textOf(candidate.id, 80);
    if (proposedId && details.some(detail => detail.id === proposedId)) continue;
    const id = /^[a-zA-Z0-9_-]{1,80}$/.test(proposedId) ? proposedId : `detail-${details.length + 1}`;
    details.push({ id, number: details.length + 1, title, description, box, sourceIds: Array.isArray(candidate.sourceIds) ? candidate.sourceIds.filter((id: unknown) => typeof id === 'string' && sourceIds.has(id)) : [] });
    if (details.length === 5) break;
  }
  const overview = textOf(value.overview, 3000);
  if (!overview) throw new ApiError(502, 'INVALID_MODEL_RESPONSE', 'The model returned no introduction. Please retry with a clearer image.');
  return {
    mode,
    // This is the curated record already supplied by trustedArtworkContext, not model-created metadata.
    artwork: verified
      ? { id: MET_SOURCE.id, title: /[\u3400-\u9fff]/.test(textOf(artwork.title)) ? '麦田与柏树' : 'Wheat Field with Cypresses', artist: 'Vincent van Gogh', year: '1889' }
      : { id: 'unidentified', title: textOf(artwork.title, 160) || 'Unidentified artwork', artist: 'Unknown', year: 'Unknown' },
    overview, details, sources,
  };
}

/** Validate the frontend context without letting it invent source URLs or unlimited prompt data. */
export function clientAnalysis(raw: unknown): Analysis {
  if (!raw || typeof raw !== 'object') throw new ApiError(400, 'INVALID_CONTEXT', 'Start a tour before asking a question.');
  const input = raw as Analysis;
  if (!['gemini', 'demo'].includes(input.mode) || !input.artwork || !Array.isArray(input.details) || input.details.length > 8) throw new ApiError(400, 'INVALID_CONTEXT', 'Invalid tour context.');
  const normalized = normalizeAnalysis(input, input.mode, input.artwork.id === 'met-436535');
  if (normalized.details.length !== input.details.length || input.details.some(detail => !detail || !Number.isInteger(detail.number) || detail.number < 1 || detail.number > 8 || !/^[a-zA-Z0-9_-]{1,80}$/.test(detail.id)) || new Set(input.details.map(detail => detail.id)).size !== input.details.length || new Set(input.details.map(detail => detail.number)).size !== input.details.length) throw new ApiError(400, 'INVALID_CONTEXT', 'Tour point numbers and stable IDs must be valid and unique.');
  // Keep only stable IDs already present in this bounded context.
  normalized.details = normalized.details.map((detail, index) => ({ ...detail, id: input.details[index].id, number: input.details[index].number }));
  if (input.schemaVersion === 2) {
    normalized.schemaVersion = 2;
    normalized.recognition = artworkSearchContext(input.recognition);
    if (!['frame', 'artwork_roi'].includes(input.coordinateSpace || '')) throw new ApiError(400, 'INVALID_CONTEXT', 'Missing coordinate space.');
    normalized.coordinateSpace = input.coordinateSpace;
    if (input.roi) normalized.roi = artworkROI(input.roi);
    if (input.coordinateSpace === 'artwork_roi' && !normalized.roi) throw new ApiError(400, 'INVALID_CONTEXT', 'Missing crop transform.');
  }
  return normalized;
}

export function decodeModelJson(value: string): unknown {
  const trimmed = value.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  try { return JSON.parse(trimmed); }
  catch { throw new ApiError(502, 'INVALID_MODEL_RESPONSE', 'The model returned an invalid response. Please retry.'); }
}

export function artworkCandidates(raw: unknown): ArtworkCandidate[] {
  if (!Array.isArray(raw)) return [];
  const result: ArtworkCandidate[] = [];
  for (const item of raw.slice(0, 8)) {
    if (!item || typeof item !== 'object') continue;
    const box = validBox(item.box), identityKey = textOf(item.identityKey, 100), label = textOf(item.label, 160), evidence = textOf(item.evidence, 500);
    if (!box || !identityKey || !label || !evidence || !Number.isFinite(item.confidence) || item.confidence < 0.8 || item.confidence > 1 || !['planar', 'object'].includes(item.kind)) continue;
    // Identity uses an appearance key, independent of translated display labels.
    const id = typeof item.id === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(item.id) ? item.id : '';
    if (result.some(value => value.identityKey === identityKey)) continue;
    result.push({ id, identityKey, label, box, evidence, confidence: item.confidence, kind: item.kind });
  }
  return result;
}
export function artworkSearchContext(raw: unknown): ArtworkSearch {
  const value = raw as ArtworkSearch;
  if (!value || value.schemaVersion !== 2 || !['searching', 'needs_confirmation', 'locked', 'no_artwork', 'uncertain'].includes(value.status) || !Array.isArray(value.candidates) || value.candidates.length > 8) throw new ApiError(400, 'INVALID_LOCK', 'Lock an artwork before analyzing details.');
  const candidates = artworkCandidates(value.candidates);
  if (candidates.length !== value.candidates.length || candidates.some(item => !item.id) || new Set(candidates.map(item => item.id)).size !== candidates.length) throw new ApiError(400, 'INVALID_LOCK', 'Invalid artwork candidates.');
  return { schemaVersion: 2, status: value.status, reason: textOf(value.reason, 600), candidates, observationCount: Number.isInteger(value.observationCount) ? Math.min(3, Math.max(0, value.observationCount)) : 0, ...(candidates.some(item => item.id === value.selectedCandidateId) ? { selectedCandidateId: value.selectedCandidateId } : {}) };
}
export function artworkROI(raw: unknown): ArtworkROI {
  const value = raw as ArtworkROI;
  const box = validBox(value?.box);
  if (!value || !box || !textOf(value.frameId, 100) || !Number.isInteger(value.frameWidth) || !Number.isInteger(value.frameHeight) || value.frameWidth < 1 || value.frameHeight < 1 || value.frameWidth > 20000 || value.frameHeight > 20000) throw new ApiError(400, 'INVALID_ROI', 'Provide the original frame size and crop transform.');
  return { frameId: textOf(value.frameId, 100), frameWidth: value.frameWidth, frameHeight: value.frameHeight, box };
}
