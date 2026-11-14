export type Language = 'en' | 'zh';
export type Box = [number, number, number, number]; // x,y,width,height in [0,1]
export interface Source { id: string; title: string; url: string; }
export interface Detail { id: string; number: number; title: string; description: string; box: Box; sourceIds: string[]; }
export interface ArtworkCandidate { id: string; identityKey: string; label: string; box: Box; confidence: number; evidence: string; kind: 'planar' | 'object'; }
export interface ArtworkSearch {
  schemaVersion: 2;
  status: 'searching' | 'needs_confirmation' | 'locked' | 'no_artwork' | 'uncertain';
  reason: string;
  candidates: ArtworkCandidate[];
  selectedCandidateId?: string;
  observationCount: number;
}
export interface ArtworkROI { frameId: string; frameWidth: number; frameHeight: number; box: Box; }
export interface Analysis {
  schemaVersion?: 2;
  recognition?: ArtworkSearch;
  coordinateSpace?: 'artwork_roi' | 'frame';
  roi?: ArtworkROI;
  mode: 'gemini' | 'demo';
  artwork: { id: string; title: string; artist: string; year: string; };
  overview: string;
  details: Detail[];
  sources: Source[];
}
export interface QuestionResponse {
  answer: string;
  selectedDetailId?: string;
  command?: 'pause' | 'resume' | 'next' | 'zoom';
  zoom?: number;
  sources?: Source[];
  mode: 'gemini' | 'demo';
}
