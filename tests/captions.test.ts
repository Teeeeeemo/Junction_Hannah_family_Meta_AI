import { describe, expect, it } from 'vitest';
import { SentenceBuffer, sentencesOf } from '../src/captions';

describe('streaming sentence boundaries', () => {
  it('joins packets split inside a word without adding spaces', () => {
    const buffer = new SentenceBuffer();
    expect(buffer.push('The cy')).toEqual([]);
    expect(buffer.push('press trees')).toEqual([]);
    expect(buffer.push(' rise above the field.')).toEqual(['The cypress trees rise above the field.']);
  });
  it('splits Chinese, English, questions, exclamations and closing quotes', () => {
    expect(sentencesOf('先看天空。What do you see?「再看这里！」最后一处细节')).toEqual(['先看天空。', 'What do you see?', '「再看这里！」', '最后一处细节']);
  });
  it('keeps decimals and common abbreviated titles inside their sentence', () => {
    const buffer = new SentenceBuffer();
    expect(buffer.push('Dr. Li measured 3.')).toEqual([]);
    expect(buffer.push('5 metres. Look closer.')).toEqual(['Dr. Li measured 3.5 metres.', 'Look closer.']);
  });
  it('keeps an unpunctuated final sentence and never repeats it on flush', () => {
    const buffer = new SentenceBuffer();
    expect(buffer.push('A final thought')).toEqual([]);
    expect(buffer.finish()).toEqual(['A final thought']);
    expect(buffer.finish()).toEqual([]);
  });
  it('drops unfinished old text when a new turn begins', () => {
    const buffer = new SentenceBuffer(); buffer.push('Old unfinished'); buffer.reset();
    expect(buffer.push('A new sentence.')).toEqual(['A new sentence.']);
    expect(sentencesOf('   ')).toEqual([]);
  });
});
