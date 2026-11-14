import { EventEmitter } from 'node:events';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WebSocket } from 'ws';
import { attachLiveSocket } from '../server/live.ts';
import { demoAnalysis } from '../server/content.ts';

class Socket extends EventEmitter {
  readyState = WebSocket.OPEN;
  bufferedAmount = 0;
  sent: any[] = [];
  send(data: string) { this.sent.push(JSON.parse(data)); }
  receive(message: unknown) { this.emit('message', Buffer.from(JSON.stringify(message))); }
  close() { this.emit('close'); }
}
const sockets: Socket[] = [];
afterEach(() => { sockets.splice(0).forEach(socket => socket.close()); });
function setup() {
  const socket = new Socket(); sockets.push(socket);
  const connections: any[] = [];
  const connect = vi.fn(async (options: any) => {
    const session = { close: vi.fn(() => options.callbacks.onclose()), sendClientContent: vi.fn(), sendRealtimeInput: vi.fn(), sendToolResponse: vi.fn() };
    connections.push({ ...options, session });
    return session;
  });
  attachLiveSocket(socket as unknown as WebSocket, { apiKey: 'unit-test', model: 'unused', liveModel: 'test-live', port: 0 }, connect);
  const context = { ...demoAnalysis('en'), mode: 'gemini' as const };
  socket.receive({ type: 'start', language: 'en', context });
  return { socket, connections, context };
}
const emit = (connection: any, serverContent: any) => connection.callbacks.onmessage({ serverContent });

describe('Live interruption recovery', () => {
  it('does not forward internal thought parts as visitor captions', async () => {
    const { socket, connections } = setup();
    await vi.waitFor(() => expect(socket.sent.some(event => event.type === 'ready')).toBe(true));
    emit(connections[0], { modelTurn: { parts: [{ thought: true, text: 'internal-diagnostic' }, { text: 'Visible caption.' }] }, outputTranscription: { text: 'Spoken sentence.' } });
    expect(socket.sent.filter(event => event.type === 'transcript').map(event => event.text)).toEqual(['Visible caption.', 'Spoken sentence.']);
  });
  it('validates bilingual tour controls and rejects invalid zoom/language tools', async () => {
    const { socket, connections } = setup();
    await vi.waitFor(() => expect(socket.sent.some(event => event.type === 'ready')).toBe(true));
    const command = (args: unknown) => connections[0].callbacks.onmessage({ toolCall: { functionCalls: [{ id: 'control', name: 'tour_control', args }] } });
    command({ action: 'pause' }); command({ action: 'resume' }); command({ action: 'next' });
    command({ action: 'zoom', value: 4 }); command({ action: 'language', language: 'zh' }); command({ action: 'sources' });
    command({ action: 'zoom', value: 3 }); command({ action: 'language', language: 'fr' }); command({ action: 'delete' });
    expect(socket.sent.filter(event => event.type === 'command').map(({ action, value, language }) => ({ action, value, language }))).toEqual([
      { action: 'pause' }, { action: 'resume' }, { action: 'next' }, { action: 'zoom', value: 4 }, { action: 'language', language: 'zh' }, { action: 'sources' },
    ]);
    expect(connections[0].session.sendToolResponse.mock.calls.slice(-3).every((args: any[]) => args[0].functionResponses[0].response.ok === false)).toBe(true);
  });
  it('applies supported voice speed tools, rejects invalid values, and keeps them separate from point selection', async()=>{
    const {socket,connections}=setup();
    await vi.waitFor(()=>expect(socket.sent.some(event=>event.type==='ready')).toBe(true));
    const call=(rate:unknown)=>connections[0].callbacks.onmessage({toolCall:{functionCalls:[{id:'speed',name:'set_playback_speed',args:{rate}}]}});
    call(1.5);call(3);call('2');
    const commands=socket.sent.filter(event=>event.type==='command');
    expect(commands.map(({action,rate})=>({action,rate}))).toEqual([{action:'set_playback_speed',rate:1.5}]);
    expect(connections[0].session.sendToolResponse.mock.calls.map((args:any[])=>args[0].functionResponses[0].response.ok)).toEqual([true,false,false]);
    expect(connections[0].config.tools[0].functionDeclarations.map((tool:any)=>tool.name)).toContain('set_playback_speed');
    socket.receive({type:'playback_rate',rate:1.75});
    expect(JSON.stringify(connections[0].session.sendClientContent.mock.lastCall)).toContain('1.75x');
  });
  it('switches points without waiting for an acknowledgement and discards late old-session audio', async () => {
    const { socket, connections, context } = setup();
    await vi.waitFor(() => expect(connections).toHaveLength(1));
    await vi.waitFor(() => expect(socket.sent.some(event => event.type === 'ready')).toBe(true));
    socket.receive({ type: 'text', text: 'Old overview' });
    emit(connections[0], { modelTurn: { parts: [{ inlineData: { data: 'old-audio' } }] } });
    socket.receive({ type: 'interrupt', playbackId: 1 });
    socket.receive({ type: 'context', context, currentDetailId: context.details[1].id });
    socket.receive({ type: 'text', text: 'Point 2 narration' });
    // Rapid selection changes keep only the latest request while reconnecting.
    socket.receive({ type: 'interrupt', playbackId: 2 });
    socket.receive({ type: 'text', text: 'Point 3 narration' });
    await vi.waitFor(() => expect(socket.sent.some(event => event.type === 'resumed')).toBe(true));
    expect(connections).toHaveLength(2);
    expect(connections[0].session.close).toHaveBeenCalledOnce();
    const requests = connections[1].session.sendClientContent.mock.calls.map((call: any[]) => call[0]);
    expect(requests.some((request: any) => request.turnComplete && request.turns[0].parts[0].text === 'Point 3 narration')).toBe(true);
    expect(requests.some((request: any) => request.turnComplete && request.turns[0].parts[0].text === 'Point 2 narration')).toBe(false);
    expect(JSON.stringify(requests)).toContain(context.details[1].id);
    const before = socket.sent.length;
    emit(connections[0], { modelTurn: { parts: [{ inlineData: { data: 'late-old-audio' } }] }, turnComplete: true });
    expect(socket.sent).toHaveLength(before);
    emit(connections[1], { modelTurn: { parts: [{ inlineData: { data: 'new-audio' } }] }, turnComplete: true });
    expect(socket.sent.find(event => event.data === 'new-audio')?.playbackId).toBe(2);
    expect(socket.sent.some(event => event.type === 'error')).toBe(false);
  });

  it('advances normally after a completed narration without reconnecting', async () => {
    const { socket, connections } = setup();
    await vi.waitFor(() => expect(socket.sent.some(event => event.type === 'ready')).toBe(true));
    socket.receive({ type: 'text', text: 'Overview' });
    emit(connections[0], { turnComplete: true });
    socket.receive({ type: 'interrupt', playbackId: 1 });
    socket.receive({ type: 'text', text: 'Point 1' });
    expect(connections).toHaveLength(1);
    expect(connections[0].session.close).not.toHaveBeenCalled();
    expect(connections[0].session.sendClientContent.mock.lastCall?.[0].turns[0].parts[0].text).toBe('Point 1');
  });

  it('retains the audio session during voice VAD interruption and can respond to the question', async () => {
    const { socket, connections } = setup();
    await vi.waitFor(() => expect(socket.sent.some(event => event.type === 'ready')).toBe(true));
    socket.receive({ type: 'text', text: 'Overview' });
    socket.receive({ type: 'audio', data: 'AAAA' });
    emit(connections[0], { interrupted: true });
    emit(connections[0], { inputTranscription: { text: 'Why is the sky blue?' } });
    emit(connections[0], { modelTurn: { parts: [{ inlineData: { data: 'answer-audio' } }] }, turnComplete: true });
    expect(connections).toHaveLength(1);
    expect(socket.sent.some(event => event.type === 'interrupted')).toBe(true);
    expect(socket.sent.some(event => event.data === 'answer-audio')).toBe(true);
    expect(connections[0].session.sendClientContent).toHaveBeenCalledTimes(2); // context + overview, no control prompt
  });
});
