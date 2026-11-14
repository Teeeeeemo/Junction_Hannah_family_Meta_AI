import type { Analysis, Box, Detail, Language, Source } from '../src/contracts.ts';
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

function validBox(value: unknown, thousand = false): Box | null {
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
  const sources: Source[] = knownArtwork && artwork.id === 'met-436535' ? [MET_SOURCE] : [];
  const sourceIds = new Set(sources.map(source => source.id));
  const details: Detail[] = [];
  const candidates = Array.isArray(value.details) ? value.details.slice(0, 8) : [];
  for (const candidate of candidates) {
    if (!candidate || typeof candidate !== 'object') continue;
    const box = candidate.box_2d ? validBox(candidate.box_2d, true) : validBox(candidate.box);
    const title = textOf(candidate.title, 100);
    const description = textOf(candidate.description, 1800);
    if (!box || !title || !description || details.some(detail => detail.title.toLowerCase() === title.toLowerCase())) continue;
    const id = `detail-${details.length + 1}`;
    details.push({ id, number: details.length + 1, title, description, box, sourceIds: Array.isArray(candidate.sourceIds) ? candidate.sourceIds.filter((id: unknown) => typeof id === 'string' && sourceIds.has(id)) : [] });
    if (details.length === 5) break;
  }
  const overview = textOf(value.overview, 3000);
  if (!overview) throw new ApiError(502, 'INVALID_MODEL_RESPONSE', 'The model returned no introduction. Please retry with a clearer image.');
  return {
    mode,
    artwork: { id: knownArtwork && artwork.id === 'met-436535' ? 'met-436535' : 'unidentified', title: textOf(artwork.title, 160) || 'Unidentified artwork', artist: textOf(artwork.artist, 120) || 'Unknown', year: textOf(artwork.year, 60) || 'Unknown' },
    overview, details, sources,
  };
}

/** Validate the frontend context without letting it invent source URLs or unlimited prompt data. */
export function clientAnalysis(raw: unknown): Analysis {
  if (!raw || typeof raw !== 'object') throw new ApiError(400, 'INVALID_CONTEXT', 'Start a tour before asking a question.');
  const input = raw as Analysis;
  if (!['gemini', 'demo'].includes(input.mode) || !input.artwork || !Array.isArray(input.details) || input.details.length > 8) throw new ApiError(400, 'INVALID_CONTEXT', 'Invalid tour context.');
  const normalized = normalizeAnalysis(input, input.mode, input.artwork.id === 'met-436535');
  if (normalized.details.length !== input.details.length || input.details.some((detail, index) => !detail || detail.number !== index + 1 || !/^[a-zA-Z0-9_-]{1,80}$/.test(detail.id)) || new Set(input.details.map(detail => detail.id)).size !== input.details.length) throw new ApiError(400, 'INVALID_CONTEXT', 'Tour point numbers and stable IDs must be valid and unique.');
  // Keep only stable IDs already present in this bounded context.
  normalized.details = normalized.details.map((detail, index) => ({ ...detail, id: input.details[index].id }));
  return normalized;
}

export function decodeModelJson(value: string): unknown {
  const trimmed = value.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  try { return JSON.parse(trimmed); }
  catch { throw new ApiError(502, 'INVALID_MODEL_RESPONSE', 'The model returned an invalid response. Please retry.'); }
}
