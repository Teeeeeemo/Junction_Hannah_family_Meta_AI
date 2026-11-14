export type Language = 'en' | 'zh';
export type Box = [number, number, number, number]; // x,y,width,height in [0,1]
export interface Source { id: string; title: string; url: string; }
export interface Detail { id: string; number: number; title: string; description: string; box: Box; sourceIds: string[]; }
export interface Analysis {
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
