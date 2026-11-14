// Keep transport chunks private: a chunk can be a word, half a word, or
// several sentences. Only complete sentences are eligible for display.
export class SentenceBuffer {
  private pending = '';
  push(delta: string): string[] {
    this.pending += delta;
    const sentences: string[] = [];
    let start = 0;
    for (let i = 0; i < this.pending.length; i++) {
      const mark = this.pending[i];
      if (!/[。！？!?\n.]/.test(mark)) continue;
      if (mark === '.') {
        const prefix = this.pending.slice(start, i + 1);
        // A period in a number or a common abbreviation is not a boundary.
        if (/\d\.$/.test(prefix) && (i + 1 === this.pending.length || /\d/.test(this.pending[i + 1]))) continue;
        if (/(?:\b(?:Mr|Mrs|Ms|Dr|Prof|St|vs|etc)|\be\.g|\bi\.e|\b[A-Z])\.$/i.test(prefix)) continue;
        if (/[A-Za-z]/.test(this.pending[i + 1] || '')) continue;
      }
      while (i + 1 < this.pending.length && /[。！？!?.”’"」』）)\]]/.test(this.pending[i + 1])) i++;
      const sentence = this.pending.slice(start, i + 1).trim();
      if (sentence) sentences.push(sentence);
      start = i + 1;
    }
    this.pending = this.pending.slice(start);
    return sentences;
  }
  finish(): string[] {
    const tail = this.pending.trim(); this.pending = '';
    return tail ? [tail] : [];
  }
  reset() { this.pending = ''; }
}

export function sentencesOf(text: string): string[] {
  const buffer = new SentenceBuffer();
  return [...buffer.push(text), ...buffer.finish()];
}
