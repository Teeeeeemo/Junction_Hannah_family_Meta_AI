import { describe, expect, it } from 'vitest';
import { limitTitleWords, shortenDetailTitles, titleWordCount } from '../server/validation.ts';

describe('PRD v0.4 three-word list titles', () => {
  it('counts English and Chinese words', () => {
    expect(titleWordCount('Towering Cypress Trees')).toBe(3);
    expect(titleWordCount('Turbulent Sky and Rolling Clouds')).toBe(5);
    expect(titleWordCount('高耸的柏树')).toBe(3);
    expect(titleWordCount('金色麦田里的收割痕迹')).toBeGreaterThan(3);
  });
  it('prefers the model short title and falls back without function words', () => {
    const [a, b, c] = shortenDetailTitles([
      { id: 'p1', title: 'Turbulent Sky and Rolling Clouds', shortTitle: 'Turbulent Sky' },
      { id: 'p2', title: 'Rippling Golden Wheat Field' },
      { id: 'p3', title: 'Silvery Olive Trees', shortTitle: 'A very long short title' },
    ]);
    expect(a).toMatchObject({ id: 'p1', title: 'Turbulent Sky' });
    expect(b).toMatchObject({ id: 'p2', title: 'Rippling Golden Wheat' });
    expect(c).toMatchObject({ id: 'p3', title: 'Silvery Olive Trees' });
    expect(limitTitleWords('翻滚的云层与天空')).toBe('翻滚云层天空');
    for (const item of [a, b, c]) expect(titleWordCount(item.title)).toBeLessThanOrEqual(3);
  });
  it('never creates duplicate titles that would drop a point', () => {
    const result = shortenDetailTitles([
      { id: 'p1', title: 'Golden Wheat Field Left' },
      { id: 'p2', title: 'Golden Wheat Field Right' },
    ]);
    expect(result.map(item => item.id)).toEqual(['p1', 'p2']);
    expect(new Set(result.map(item => item.title.toLowerCase())).size).toBe(2);
  });
});
