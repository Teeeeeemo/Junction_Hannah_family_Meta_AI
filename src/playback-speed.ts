export const PLAYBACK_RATES = [0.75, 1, 1.25, 1.5, 1.75, 2] as const;
export type PlaybackRate = typeof PLAYBACK_RATES[number];
export const isPlaybackRate = (value: unknown): value is PlaybackRate => typeof value === 'number' && PLAYBACK_RATES.some(rate => rate === value);

// Deterministic shortcuts for typed controls. Live speech also has a validated
// Gemini tool, so natural requests do not depend on a transcript packet boundary.
export function parseSpeedCommand(text: string, current: PlaybackRate): PlaybackRate | null {
  const value = text.trim().toLowerCase();
  if (/放大|缩小|zoom/.test(value)) return null;
  if (/[?？]$|^(?:why|what|when|where|did|does)\b|为什么|什么是/.test(value)) return null;
  if (/恢复正常(?:语速|速度)|正常(?:语速|速度)|原速|normal (?:playback )?speed|regular speed/.test(value)) return 1;
  if (/^(?:(?:请)?(?:讲|说|读|播报)?(?:快一点|快点)|(?:please )?(?:speak |read |talk )?(?:a little |a bit )?faster)[。.!！]?$/.test(value)) return PLAYBACK_RATES[Math.min(PLAYBACK_RATES.length - 1, PLAYBACK_RATES.indexOf(current) + 1)];
  if (/^(?:(?:请)?(?:讲|说|读|播报)?(?:慢一点|慢点)|(?:please )?(?:speak |read |talk )?(?:a little |a bit )?slower)[。.!！]?$/.test(value)) return PLAYBACK_RATES[Math.max(0, PLAYBACK_RATES.indexOf(current) - 1)];
  if (!/倍速|语速|速度|朗读|播报|speed|speak|read/.test(value)) return null;
  const named: [RegExp, PlaybackRate][] = [
    [/零点七五|zero point seven five|three.quarter/, .75],
    [/一点二五|one point two five|one and a quarter/, 1.25],
    [/一点五|one point five|one and a half/, 1.5],
    [/一点七五|one point seven five|one and three.quarters/, 1.75],
    [/(?:两|二)倍(?:速)?|double (?:the )?speed|two times/, 2],
    [/一倍(?:速)?|one times?/, 1],
  ];
  const numeric = value.match(/(?:^|[^\d.])(\d+(?:\.\d+)?)(?=\s*(?:x|×|倍|times|speed|$))/);
  if (numeric) { const rate = Number(numeric[1]); return isPlaybackRate(rate) ? rate : null; }
  return named.find(([pattern]) => pattern.test(value))?.[1] ?? null;
}

export function remainingNarration(text: string, sentence: string): string {
  const index = sentence.trim() ? text.indexOf(sentence.trim()) : -1;
  return index >= 0 ? text.slice(index) : text;
}
