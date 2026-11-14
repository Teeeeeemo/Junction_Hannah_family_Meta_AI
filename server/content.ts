import type { Analysis, Language, Source } from '../src/contracts.ts';

export const MET_SOURCE: Source = {
  id: 'met-436535',
  title: 'The Metropolitan Museum of Art — Wheat Field with Cypresses',
  url: 'https://www.metmuseum.org/art/collection/search/436535',
};

/** Explicit demonstration fixture. Never use this as an automatic fallback. */
export function demoAnalysis(language: Language): Analysis {
  const zh = language === 'zh';
  return {
    mode: 'demo',
    artwork: { id: 'met-436535', title: zh ? '麦田与柏树' : 'Wheat Field with Cypresses', artist: 'Vincent van Gogh', year: '1889' },
    overview: zh
      ? '这是梵高于 1889 年创作的《麦田与柏树》。馆方资料将它与梵高在圣雷米时期对柏树的研究联系起来。先看整体：金色麦田、深色柏树与起伏的天空组成了这幅风景。接下来，我们会依次观察画面中的三个细节。当前是明确标记的离线演示，点位经过预先准备，并非实时 AI 发现。'
      : 'This is Wheat Field with Cypresses, painted by Vincent van Gogh in 1889. The Met connects it to his studies of cypress trees in Saint-Rémy. Notice the golden field, the dark trees, and the flowing sky. We will explore three details. This is the labeled offline demonstration: these points are prepared examples, not live AI discoveries.',
    details: [
      { id: 'cypress', number: 1, title: zh ? '柏树' : 'Cypress trees', box: [0.69, 0.055, 0.23, 0.60], sourceIds: [MET_SOURCE.id], description: zh ? '看右侧高耸的深色柏树。它们的竖向轮廓与横向铺开的麦田形成对比。馆方资料指出，梵高在 1889 年六月底开始把柏树作为圣雷米时期一组作品的重要主题。' : 'Look at the tall dark cypresses on the right. Their upright forms contrast with the broad horizontal field. The Met notes that cypresses became an important subject in Van Gogh’s Saint-Rémy work by late June 1889.' },
      { id: 'clouds', number: 2, title: zh ? '云层与天空' : 'Clouds and sky', box: [0.05, 0.06, 0.62, 0.43], sourceIds: [], description: zh ? '观察上方云层中弯曲、重复的线条。这里描述的是画面可见的形状与笔触方向：它们把视线带过天空，并与树木和山脉的曲线呼应。我们不把这种视觉观察说成画家意图的唯一解释。' : 'Notice the curving, repeated strokes in the clouds. This is a visual observation: the marks carry your eye across the sky and echo curves in the trees and hills. It is not a claim that there is only one interpretation of the artist’s intention.' },
      { id: 'wheat', number: 3, title: zh ? '金色麦田' : 'Golden wheat field', box: [0.08, 0.69, 0.76, 0.24], sourceIds: [], description: zh ? '看前景麦田里短而密集的线条，以及金黄色与绿色的变化。尝试比较这里的短笔触和上方云层的长曲线。你可以切换两倍或四倍放大来观察，但数字放大不会恢复原始图像中没有的细节。' : 'Look at the short, dense marks and the shifts between gold and green in the foreground. Compare these shorter strokes with the long curves in the clouds. Try two or four times zoom, remembering that digital magnification cannot recover detail missing from the source image.' },
    ],
    sources: [MET_SOURCE],
  };
}

export function trustedArtworkContext(artworkId?: string): string {
  return artworkId === 'met-436535' || artworkId === 'wheat-field' || artworkId === 'wheat-field-with-cypresses'
    ? 'Trusted museum record: The Met, object 436535: Wheat Field with Cypresses; Vincent van Gogh; 1889; oil on canvas. Cypresses became a subject in his Saint-Rémy work by late June 1889. The Met describes this as a summer landscape and notes he later made studio renditions. This context is only applicable if the supplied image actually matches the work. Source ID met-436535, https://www.metmuseum.org/art/collection/search/436535. Do not infer additional historical symbolism from the image.'
    : 'No verified museum record has been supplied for this image. Identify uncertainty explicitly. Describe visible details; do not invent artist, date, provenance, historical symbolism, or citations.';
}
