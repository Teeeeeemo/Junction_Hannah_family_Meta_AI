import {describe,expect,it} from 'vitest';
import {isPlaybackRate,parseSpeedCommand,remainingNarration} from '../src/playback-speed';
describe('playback speed controls',()=>{
  it.each([
    ['设置为零点七五倍速',.75],['恢复正常语速',1],['播报调到1.25倍速',1.25],
    ['调到一点五倍速',1.5],['一点七五倍速',1.75],['两倍速',2],['把语速调到两倍',2],
    ['set playback speed to 0.75x',.75],['normal speed',1],['read at one and a half speed',1.5],['double speed',2],
  ])('parses %s',(text,rate)=>{expect(parseSpeedCommand(text as string,1)).toBe(rate);});
  it('steps faster/slower and stops at the supported limits',()=>{
    expect(parseSpeedCommand('快一点',1.25)).toBe(1.5);
    expect(parseSpeedCommand('speak slower',1.25)).toBe(1);
    expect(parseSpeedCommand('慢一点',.75)).toBe(.75);
    expect(parseSpeedCommand('faster',2)).toBe(2);
  });
  it('keeps zoom and artwork questions separate and rejects unsupported speeds',()=>{
    for(const text of ['放大两倍','zoom 2x','why is the sky blue?','Did Van Gogh paint faster than Monet?','为什么他画得更快一点？','3倍速','playback speed 1.1x'])expect(parseSpeedCommand(text,1)).toBeNull();
    expect(isPlaybackRate('1.5')).toBe(false);expect(isPlaybackRate(NaN)).toBe(false);
  });
  it('resumes from the current complete sentence and safely handles paraphrased captions',()=>{
    expect(remainingNarration('First sentence. Second sentence. Third sentence.','Second sentence.')).toBe('Second sentence. Third sentence.');
    expect(remainingNarration('Original narration.','A paraphrase.')).toBe('Original narration.');
  });
});
