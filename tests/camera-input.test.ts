import {describe,expect,it,vi,afterEach} from 'vitest';
import {cameraFailure,hasVideoFrame,openBrowserVideo} from '../src/camera-input';
afterEach(()=>vi.useRealTimers());
function fixture(){
  const track={stop:vi.fn()};const stream={getTracks:()=>[track]} as unknown as MediaStream;
  const video={srcObject:null,muted:false,playsInline:false,readyState:2,videoWidth:1280,videoHeight:720,play:vi.fn(async()=>{}),pause:vi.fn()} as unknown as HTMLVideoElement;
  const getUserMedia=vi.fn(async(_constraints:MediaStreamConstraints)=>stream);
  return {track,stream,video,getUserMedia};
}
describe('live camera acquisition',()=>{
  it('rejects missing camera support without making up a frame',async()=>{
    await expect(openBrowserVideo(undefined)).rejects.toMatchObject({code:'unsupported'});
    expect(hasVideoFrame(null)).toBe(false);
  });
  it('waits for a real decoded frame and requests video without microphone audio',async()=>{
    const {stream,video,getUserMedia}=fixture();
    const result=await openBrowserVideo({getUserMedia},()=>video);
    expect(result).toEqual({stream,video});expect(video.srcObject).toBe(stream);
    expect(getUserMedia.mock.calls[0][0]).toMatchObject({audio:false,video:{facingMode:{ideal:'environment'}}});
    expect(video.muted).toBe(true);expect(video.playsInline).toBe(true);
  });
  it('does not treat dimensions-only metadata or a blank frame as video input',()=>{
    expect(hasVideoFrame({readyState:1,videoWidth:1280,videoHeight:720})).toBe(false);
    expect(hasVideoFrame({readyState:2,videoWidth:0,videoHeight:720})).toBe(false);
    expect(hasVideoFrame({readyState:2,videoWidth:1280,videoHeight:720})).toBe(true);
  });
  it('releases the stream if the video cannot play',async()=>{
    const {track,video,getUserMedia}=fixture();vi.mocked(video.play).mockRejectedValue(new Error('decoder unavailable'));
    await expect(openBrowserVideo({getUserMedia},()=>video)).rejects.toThrow('decoder unavailable');
    expect(track.stop).toHaveBeenCalledOnce();expect(video.srcObject).toBeNull();
  });
  it('releases the stream after decoded frames fail to arrive',async()=>{
    vi.useFakeTimers();const {track,video,getUserMedia}=fixture();Object.assign(video,{readyState:1});
    const opening=openBrowserVideo({getUserMedia},()=>video);
    const failure=expect(opening).rejects.toMatchObject({code:'timeout'});
    await vi.advanceTimersByTimeAsync(7100);await failure;expect(track.stop).toHaveBeenCalledOnce();
  });
  it('recovers when a first decoded frame arrives after metadata',async()=>{
    vi.useFakeTimers();const {video,getUserMedia}=fixture();Object.assign(video,{readyState:1});
    const opening=openBrowserVideo({getUserMedia},()=>video);
    await vi.advanceTimersByTimeAsync(100);Object.assign(video,{readyState:2});await vi.advanceTimersByTimeAsync(40);
    expect((await opening).video).toBe(video);
  });
  it('distinguishes permission denial, unsupported APIs and device failures',()=>{
    expect(cameraFailure(new DOMException('no','NotAllowedError'))).toBe('denied');
    expect(cameraFailure(new DOMException('no','NotSupportedError'))).toBe('unsupported');
    expect(cameraFailure(new Error('disconnected'))).toBe('unavailable');
  });
});
