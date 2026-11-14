import type { Analysis, Language } from './contracts';
import { SentenceBuffer, sentencesOf } from './captions';
import { isPlaybackRate, type PlaybackRate } from './playback-speed';

type AudioCallback = {
  onTranscript?: (role: string, text: string) => void;
  onInterrupt?: () => void;
  onCommand?: (number: number) => void;
  onSpeedChange?: (rate: PlaybackRate) => void;
  onTurnComplete?: () => void;
  onError?: (message: string) => void;
  onMicLevel?: (level: number) => void;
};
let sharedContext: AudioContext | null = null;
let browserSpeechRun = 0;
let finishBrowserUtterance: (() => void) | null = null;
let browserSpeechRate: PlaybackRate = 1;
let restartBrowserUtterance: (() => void) | null = null;
export function setBrowserSpeechRate(rate: PlaybackRate) {
  if (!isPlaybackRate(rate) || rate === browserSpeechRate) return;
  browserSpeechRate = rate; restartBrowserUtterance?.();
}
export async function unlockAudio() {
  sharedContext ??= new AudioContext();
  if (sharedContext.state === 'suspended') await sharedContext.resume();
}
export function stopBrowserSpeech() {
  ++browserSpeechRun; restartBrowserUtterance = null; window.speechSynthesis?.cancel();
  const finish = finishBrowserUtterance; finishBrowserUtterance = null; finish?.();
}
export async function speakBrowser(text: string, language: Language, onSentence?: (sentence: string) => void): Promise<void> {
  stopBrowserSpeech();
  if (!('speechSynthesis' in window) || !text) return;
  const run = browserSpeechRun;
  for (const sentence of sentencesOf(text)) {
    if (run !== browserSpeechRun) return;
    onSentence?.(sentence);
    await new Promise<void>(resolve => {
      let current: SpeechSynthesisUtterance;
      let offset = 0;
      let boundary = 0;
      const finish = () => {
        if (finishBrowserUtterance === finish) { finishBrowserUtterance = null; restartBrowserUtterance = null; }
        resolve();
      };
      const start = () => {
        const utterance = new SpeechSynthesisUtterance(sentence.slice(offset)); current = utterance;
        utterance.lang = language === 'zh' ? 'zh-CN' : 'en-US';
        const voices = window.speechSynthesis.getVoices();
        utterance.voice = voices.find(v => v.lang.startsWith(language === 'zh' ? 'zh' : 'en')) ?? null;
        utterance.rate = browserSpeechRate;
        finishBrowserUtterance = finish;
        utterance.onboundary = event => { if (current === utterance) boundary = offset + event.charIndex; };
        utterance.onend = () => { if (current === utterance) finish(); };
        utterance.onerror = () => { if (current === utterance) finish(); };
        window.speechSynthesis.speak(utterance);
      };
      restartBrowserUtterance = () => {
        current.onend = null; current.onerror = null; current.onboundary = null;
        window.speechSynthesis.cancel(); offset = boundary; start();
      };
      start();
    });
  }
}
const encode = (bytes: Uint8Array) => {
  let binary = ''; for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary);
};
function decode(data: string) {
  const binary = atob(data), bytes = new Uint8Array(binary.length);
  for (let i = 0; i < bytes.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
export class LiveAudioClient {
  private socket: WebSocket | null = null;
  private stream: MediaStream | null = null;
  private capture: AudioContext | null = null;
  private processor: ScriptProcessorNode | null = null;
  private captureSource: MediaStreamAudioSourceNode | null = null;
  private scheduled = new Map<AudioBufferSourceNode, { buffer: AudioBuffer; when: number; offset: number; end: number }>();
  private playbackRate: PlaybackRate = 1;
  private turnEnded = false;
  private nextTime = 0;
  private speakResolve: (() => void) | null = null;
  private silenceTimer: ReturnType<typeof setTimeout> | null = null;
  private voiceFrames = 0;
  private interruptedAt = 0;
  private playbackId = 0;
  private playbackSuppressed = false;
  private sentenceBuffer = new SentenceBuffer();
  private captionTimers = new Map<ReturnType<typeof setTimeout>, { sentence: string; at: number }>();
  private captionCursor = 0;
  private lastCaptionAt = 0;
  public ready = false;
  public listening = false;
  constructor(private callbacks: AudioCallback = {}) {}
  async connect(context: Analysis, language: Language) {
    await unlockAudio();
    return new Promise<void>((resolve, reject) => {
      const socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/api/live`);
      this.socket = socket;
      const timer = setTimeout(() => { socket.close(); reject(new Error('Gemini Live connection timed out')); }, 18000);
      socket.onopen = () => socket.send(JSON.stringify({ type: 'start', language, context, playbackRate: this.playbackRate }));
      socket.onmessage = event => {
        let message: any; try { message = JSON.parse(event.data); } catch { return; }
        if (typeof message.playbackId === 'number' && message.playbackId !== this.playbackId) return;
        if (message.type === 'ready') { clearTimeout(timer); this.ready = true; resolve(); }
        if (message.type === 'resumed') this.playbackSuppressed = false;
        if (message.type === 'audio' && message.data && !this.playbackSuppressed) this.playPCM(message.data, message.mimeType);
        if (message.type === 'transcript') {
          if (message.role === 'user') this.playbackSuppressed = false;
          if (!this.playbackSuppressed) {
            if (message.role === 'assistant' || message.role === 'model') this.queueCaptions(this.sentenceBuffer.push(message.text));
            else this.callbacks.onTranscript?.(message.role, message.text);
          }
        }
        if (message.type === 'interrupted') { this.stopPlayback(); this.playbackSuppressed = false; this.callbacks.onInterrupt?.(); }
        if (message.type === 'command' && message.action === 'select_detail') this.callbacks.onCommand?.(message.number);
        if (message.type === 'command' && message.action === 'set_playback_speed' && isPlaybackRate(message.rate)) this.callbacks.onSpeedChange?.(message.rate);
        if (message.type === 'turn_complete' && !this.playbackSuppressed) { this.turnEnded = true; this.queueCaptions(this.sentenceBuffer.finish()); this.finishAfterAudio(); }
        if (message.type === 'error') { clearTimeout(timer); this.callbacks.onError?.(message.message || 'Gemini Live error'); if (!this.ready) reject(new Error(message.message || 'Gemini Live failed')); this.stopPlayback(); }
      };
      socket.onerror = () => { clearTimeout(timer); reject(new Error('Could not connect to Gemini Live')); };
      socket.onclose = () => { clearTimeout(timer); this.ready = false; this.stopMicrophone(); this.stopPlayback(); };
    });
  }
  private send(message: unknown) { if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify(message)); }
  say(text: string) {
    this.stopPlayback();
    this.playbackSuppressed = false;
    return new Promise<void>(resolve => {
      this.speakResolve = resolve;
      this.send({ type: 'text', text: `Read the following museum narration naturally, without adding an introduction or changing the selected point: ${text}` });
      this.silenceTimer = setTimeout(() => this.finishSpeech(), 90000);
    });
  }
  ask(text: string) { this.interrupt(); this.send({ type: 'text', text }); }
  interrupt() { this.playbackSuppressed = true; this.send({ type: 'interrupt', playbackId: ++this.playbackId }); this.stopPlayback(); }
  setContext(context: Analysis, currentDetailId?: string) { this.send({ type: 'context', context, currentDetailId }); }
  image(dataUrl: string) { this.send({ type: 'image', data: dataUrl.split(',')[1] || dataUrl, mimeType: 'image/jpeg' }); }
  setPlaybackRate(rate: PlaybackRate) {
    if (!isPlaybackRate(rate) || rate === this.playbackRate) return;
    const previous = this.playbackRate, now = sharedContext?.currentTime || 0;
    this.playbackRate = rate;
    this.send({ type: 'playback_rate', rate });
    const chunks = [...this.scheduled.entries()].filter(([, chunk]) => chunk.end > now);
    for (const [source] of this.scheduled) { source.onended = null; try { source.stop(); } catch {} source.disconnect(); }
    this.scheduled.clear(); this.nextTime = 0;
    let when = chunks.length && chunks[0][1].when > now ? now + (chunks[0][1].when - now) * previous / rate : now + .005;
    for (const [, chunk] of chunks) {
      const offset = chunk.offset + Math.max(0, now - chunk.when) * previous;
      if (offset >= chunk.buffer.duration) continue;
      this.scheduleBuffer(chunk.buffer, offset, when); when = this.nextTime;
    }
    const retime = (at: number) => now + Math.max(0, at - now) * previous / rate;
    const captions = [...this.captionTimers.values()];
    this.captionTimers.forEach((_, timer) => clearTimeout(timer)); this.captionTimers.clear();
    for (const caption of captions) this.scheduleCaption(caption.sentence, retime(caption.at));
    this.captionCursor = retime(this.captionCursor); this.lastCaptionAt = retime(this.lastCaptionAt);
    if (this.turnEnded) this.finishAfterAudio();
  }
  private playPCM(data: string, mimeType = '') {
    if (!sharedContext) return;
    const bytes = decode(data);
    const count = Math.floor(bytes.byteLength / 2);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const rate = Number(/rate=(\d+)/.exec(mimeType)?.[1] || 24000);
    const buffer = sharedContext.createBuffer(1, count, rate), out = buffer.getChannelData(0);
    for (let i = 0; i < count; i++) out[i] = view.getInt16(i * 2, true) / 32768;
    this.scheduleBuffer(buffer, 0, Math.max(sharedContext.currentTime + .035, this.nextTime));
  }
  private scheduleBuffer(buffer: AudioBuffer, offset: number, when: number) {
    if (!sharedContext) return;
    const source = sharedContext.createBufferSource(); source.buffer = buffer; source.connect(sharedContext.destination);
    source.playbackRate.value = this.playbackRate;
    source.start(when, offset); this.nextTime = when + (buffer.duration - offset) / this.playbackRate;
    this.scheduled.set(source, { buffer, when, offset, end: this.nextTime });
    source.onended = () => this.scheduled.delete(source);
  }
  private finishAfterAudio() {
    const wait = Math.max(0, Math.max(this.nextTime, this.lastCaptionAt) - (sharedContext?.currentTime || 0));
    if (this.silenceTimer) clearTimeout(this.silenceTimer);
    this.silenceTimer = setTimeout(() => { this.finishSpeech(); this.callbacks.onTurnComplete?.(); }, wait * 1000 + 60);
  }
  private queueCaptions(sentences: string[]) {
    const now = sharedContext?.currentTime || 0;
    for (let i = 0; i < sentences.length; i++) {
      const when = Math.max(now, this.captionCursor);
      this.scheduleCaption(sentences[i], when);
      this.lastCaptionAt = when;
      // Audio is queued ahead of playback. Keep the sentence visible through
      // the audio received with it, sharing that interval for batched sentences.
      const audioSpan = Math.max(0, this.nextTime - when) / (sentences.length - i);
      this.captionCursor = when + Math.max(1.5 / this.playbackRate, audioSpan);
    }
  }
  private scheduleCaption(sentence: string, at: number) {
    const delay = at - (sharedContext?.currentTime || 0);
    if (delay <= 0) { this.callbacks.onTranscript?.('assistant', sentence); return; }
    const timer = setTimeout(() => { this.captionTimers.delete(timer); this.callbacks.onTranscript?.('assistant', sentence); }, delay * 1000);
    this.captionTimers.set(timer, { sentence, at });
  }
  private finishSpeech() {
    if (this.silenceTimer) clearTimeout(this.silenceTimer); this.silenceTimer = null;
    const done = this.speakResolve; this.speakResolve = null; done?.();
  }
  stopPlayback() {
    this.turnEnded = false;
    this.sentenceBuffer.reset(); this.captionTimers.forEach((_, timer) => clearTimeout(timer)); this.captionTimers.clear();
    this.captionCursor = 0; this.lastCaptionAt = 0;
    for (const [source] of this.scheduled) { try { source.stop(); } catch {} source.disconnect(); }
    this.scheduled.clear(); this.nextTime = 0; this.finishSpeech(); stopBrowserSpeech();
  }
  async startMicrophone() {
    if (this.listening) return;
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false });
    this.stream = stream; this.capture = new AudioContext(); await this.capture.resume();
    this.captureSource = this.capture.createMediaStreamSource(stream);
    this.processor = this.capture.createScriptProcessor(4096, 1, 1);
    this.processor.onaudioprocess = event => {
      const input = event.inputBuffer.getChannelData(0), inputRate = event.inputBuffer.sampleRate;
      let power = 0; for (const sample of input) power += sample * sample;
      const rms = Math.sqrt(power / input.length); this.callbacks.onMicLevel?.(rms);
      this.voiceFrames = rms > .025 ? this.voiceFrames + 1 : 0;
      if (this.voiceFrames === 2 && performance.now() - this.interruptedAt > 1000) {
        this.interruptedAt = performance.now(); this.playbackSuppressed = true; this.stopPlayback(); this.callbacks.onInterrupt?.();
      }
      const length = Math.floor(input.length * 16000 / inputRate), bytes = new Uint8Array(length * 2), out = new DataView(bytes.buffer);
      for (let i = 0; i < length; i++) {
        const at = i * inputRate / 16000, lo = Math.floor(at), mix = at - lo;
        const value = input[lo] * (1 - mix) + (input[Math.min(lo + 1, input.length - 1)] || 0) * mix;
        out.setInt16(i * 2, Math.max(-1, Math.min(1, value)) * 32767, true);
      }
      this.send({ type: 'audio', data: encode(bytes) });
    };
    this.captureSource.connect(this.processor); this.processor.connect(this.capture.destination); this.listening = true;
  }
  stopMicrophone() {
    if (this.listening) this.send({ type: 'audio_end' });
    this.processor?.disconnect(); this.captureSource?.disconnect(); this.stream?.getTracks().forEach(track => track.stop());
    void this.capture?.close(); this.processor = null; this.captureSource = null; this.capture = null; this.stream = null; this.listening = false;
  }
  disconnect() { this.stopMicrophone(); this.stopPlayback(); this.send({ type: 'stop' }); this.socket?.close(); this.socket = null; this.ready = false; }
}
