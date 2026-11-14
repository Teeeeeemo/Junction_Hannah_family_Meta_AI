import { afterEach, describe, expect, it, vi } from 'vitest';
import { LiveAudioClient, setBrowserSpeechRate, speakBrowser, stopBrowserSpeech } from '../src/audio.ts';
import { demoAnalysis } from '../server/content.ts';

class BrowserSocket {
  static OPEN = 1;
  static instances: BrowserSocket[] = [];
  readyState = 1;
  sent: any[] = [];
  onmessage?: (event: { data: string }) => void;
  onclose?: () => void;
  constructor() { BrowserSocket.instances.push(this); }
  send(data: string) { this.sent.push(JSON.parse(data)); }
  close() { this.onclose?.(); }
  receive(message: unknown) { this.onmessage?.({ data: JSON.stringify(message) }); }
}
const clients: LiveAudioClient[] = [];
const audioClock = { currentTime: 0 };
const audioSources: any[] = [];
afterEach(() => { clients.splice(0).forEach(client => client.disconnect()); if(typeof window!=='undefined'){stopBrowserSpeech();setBrowserSpeechRate(1);} BrowserSocket.instances = []; audioClock.currentTime = 0; audioSources.length=0; vi.useRealTimers(); vi.unstubAllGlobals(); });
async function setup(onInterrupt = vi.fn()) {
  vi.stubGlobal('AudioContext', class {
    state = 'running'; destination = {};
    get currentTime() { return audioClock.currentTime; }
    createBuffer(_channels:number, count:number, rate:number) { return {duration:count/rate,getChannelData:()=>new Float32Array(count)}; }
    createBufferSource() { const source={ playbackRate:{value:1},start:vi.fn(),stop:vi.fn(),connect:vi.fn(),disconnect:vi.fn(),onended:null };audioSources.push(source);return source; }
  });
  vi.stubGlobal('window', { speechSynthesis: { cancel: vi.fn() } });
  vi.stubGlobal('location', { protocol: 'http:', host: '127.0.0.1:4173' });
  vi.stubGlobal('WebSocket', BrowserSocket);
  const onTranscript = vi.fn();
  const onSpeedChange=vi.fn();
  const client = new LiveAudioClient({ onInterrupt, onTranscript, onSpeedChange }); clients.push(client);
  const connected = client.connect(demoAnalysis('en'), 'en');
  await vi.waitFor(() => expect(BrowserSocket.instances).toHaveLength(1));
  const socket = BrowserSocket.instances[0];
  socket.receive({ type: 'ready', playbackId: 0 }); await connected;
  const play = vi.spyOn(client as any, 'playPCM').mockImplementation(() => {});
  return { client, socket, play, onInterrupt, onTranscript, onSpeedChange };
}

describe('browser voice cancellation', () => {
  it('ignores buffered old audio even after the next narration has been requested', async () => {
    const { client, socket, play } = await setup();
    client.interrupt(); const narration = client.say('The next point');
    socket.receive({ type: 'audio', playbackId: 0, data: 'old' });
    expect(play).not.toHaveBeenCalled();
    socket.receive({ type: 'audio', playbackId: 1, data: 'new' });
    expect(play).toHaveBeenCalledWith('new', undefined);
    client.stopPlayback(); await narration;
  });
  it('handles the server VAD interruption without echoing a control interruption upstream', async () => {
    const { socket, onInterrupt } = await setup();
    const before = socket.sent.length;
    socket.receive({ type: 'interrupted', playbackId: 0 });
    expect(onInterrupt).toHaveBeenCalledOnce();
    expect(socket.sent).toHaveLength(before);
  });
});

describe('actual playback speed scheduling', () => {
  it('changes active and queued PCM from their current sample offset without replaying the beginning', async () => {
    const {client,socket,play}=await setup();play.mockRestore();
    const data=Buffer.alloc(48000).toString('base64');
    socket.receive({type:'audio',data,mimeType:'audio/pcm;rate=24000',playbackId:0});
    socket.receive({type:'audio',data,mimeType:'audio/pcm;rate=24000',playbackId:0});
    expect(audioSources[0].start).toHaveBeenCalledWith(.035,0);
    expect(audioSources[1].start.mock.calls[0][0]).toBeCloseTo(1.035);
    audioClock.currentTime=.535;client.setPlaybackRate(2);
    expect(audioSources[0].stop).toHaveBeenCalledOnce();
    expect(audioSources[1].stop).toHaveBeenCalledOnce();
    expect(audioSources[2].playbackRate.value).toBe(2);
    expect(audioSources[2].start.mock.calls[0][1]).toBeCloseTo(.5);
    expect(audioSources[3].start.mock.calls[0][0]).toBeCloseTo(.79);
    expect(audioSources[3].start.mock.calls[0][1]).toBe(0);
    audioClock.currentTime=.665;client.setPlaybackRate(.75);
    expect(audioSources[4].playbackRate.value).toBe(.75);
    expect(audioSources[4].start.mock.calls[0][1]).toBeCloseTo(.75);
    expect(audioSources[5].start.mock.calls[0][0]).toBeCloseTo(.67+.25/.75);
  });
  it('retimes queued sentence captions when speed changes', async () => {
    const {client,socket,onTranscript}=await setup();vi.useFakeTimers();
    socket.receive({type:'transcript',role:'assistant',text:'First sentence. Second sentence.',playbackId:0});
    vi.advanceTimersByTime(500);audioClock.currentTime=.5;client.setPlaybackRate(2);
    vi.advanceTimersByTime(499);expect(onTranscript).toHaveBeenCalledOnce();
    vi.advanceTimersByTime(1);expect(onTranscript.mock.lastCall).toEqual(['assistant','Second sentence.']);
  });
  it('recalculates the end of a fully received turn when slowed down', async () => {
    const {client,socket,play}=await setup();play.mockRestore();vi.useFakeTimers();
    let finished=false;const narration=client.say('One sentence.').then(()=>{finished=true;});
    socket.receive({type:'audio',data:Buffer.alloc(48000).toString('base64'),mimeType:'audio/pcm;rate=24000',playbackId:0});
    socket.receive({type:'turn_complete',playbackId:0});
    vi.advanceTimersByTime(535);audioClock.currentTime=.535;client.setPlaybackRate(.75);
    await vi.advanceTimersByTimeAsync(600);expect(finished).toBe(false);
    await vi.advanceTimersByTimeAsync(140);expect(finished).toBe(true);await narration;
  });
  it('dispatches only supported rate commands received over the voice connection', async () => {
    const {socket,onSpeedChange}=await setup();
    socket.receive({type:'command',action:'set_playback_speed',rate:1.75,playbackId:0});
    socket.receive({type:'command',action:'set_playback_speed',rate:3,playbackId:0});
    expect(onSpeedChange.mock.calls).toEqual([[1.75]]);
  });
  it('changes browser speech at the last reported word boundary and uses the rate for the next sentence', async () => {
    const utterances:any[]=[];
    vi.stubGlobal('window',{speechSynthesis:{cancel:vi.fn(),getVoices:()=>[],speak:(utterance:any)=>utterances.push(utterance)}});
    vi.stubGlobal('SpeechSynthesisUtterance',class{constructor(public text:string){}});
    const speaking=speakBrowser('The sky swirls. Look closer.','en');
    expect(utterances[0].rate).toBe(1);
    utterances[0].onboundary({charIndex:4});setBrowserSpeechRate(1.5);
    expect(utterances[1].text).toBe('sky swirls.');expect(utterances[1].rate).toBe(1.5);
    utterances[1].onend();await Promise.resolve();
    expect(utterances[2].text).toBe('Look closer.');expect(utterances[2].rate).toBe(1.5);
    stopBrowserSpeech();await speaking;
  });
});

describe('sentence captions', () => {
  it('keeps word fragments off screen, queues whole sentences and flushes the final tail', async () => {
    const { socket, onTranscript } = await setup();
    vi.useFakeTimers();
    const transcript = (text: string) => socket.receive({ type: 'transcript', role: 'assistant', playbackId: 0, text });
    transcript('The brush'); transcript('strokes are'); transcript(' bold');
    expect(onTranscript).not.toHaveBeenCalled();
    transcript('. The sky swirls. A final thought');
    expect(onTranscript.mock.calls).toEqual([['assistant', 'The brushstrokes are bold.']]);
    vi.advanceTimersByTime(1500);
    expect(onTranscript.mock.lastCall).toEqual(['assistant', 'The sky swirls.']);
    audioClock.currentTime = 1.5;
    socket.receive({ type: 'turn_complete', playbackId: 0 });
    vi.advanceTimersByTime(1500);
    expect(onTranscript.mock.lastCall).toEqual(['assistant', 'A final thought']);
  });
  it('discards both queued sentences and an unfinished fragment when interrupted', async () => {
    const { client, socket, onTranscript } = await setup();
    vi.useFakeTimers();
    socket.receive({ type: 'transcript', role: 'assistant', playbackId: 0, text: '旧的第一句。旧的第二句。未完' });
    expect(onTranscript.mock.calls).toEqual([['assistant', '旧的第一句。']]);
    client.interrupt();
    socket.receive({ type: 'transcript', role: 'assistant', playbackId: 0, text: '整的旧句。' });
    vi.advanceTimersByTime(5000);
    expect(onTranscript).toHaveBeenCalledOnce();
    client.say('New point.');
    socket.receive({ type: 'transcript', role: 'assistant', playbackId: 1, text: 'New point.' });
    expect(onTranscript.mock.lastCall).toEqual(['assistant', 'New point.']);
  });
  it('shows one sentence for each browser speech utterance and cancels the remaining sentences', async () => {
    const utterances: any[] = [];
    vi.stubGlobal('window', { speechSynthesis: { cancel: vi.fn(), getVoices: () => [], speak: (utterance: any) => utterances.push(utterance) } });
    vi.stubGlobal('SpeechSynthesisUtterance', class { constructor(public text: string) {} });
    const show = vi.fn();
    const speaking = speakBrowser('第一句。第二句。第三句。', 'zh', show);
    expect(show.mock.calls).toEqual([['第一句。']]);
    utterances[0].onend(); await Promise.resolve();
    expect(show.mock.calls).toEqual([['第一句。'], ['第二句。']]);
    stopBrowserSpeech(); await speaking;
    expect(utterances.map(utterance => utterance.text)).toEqual(['第一句。', '第二句。']);
  });
});
