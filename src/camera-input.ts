export type CameraFailure = 'unsupported' | 'denied' | 'unavailable' | 'timeout';
export class CameraInputError extends Error {
  constructor(public code: CameraFailure) { super(code); }
}
export function hasVideoFrame(video: Pick<HTMLVideoElement, 'readyState' | 'videoWidth' | 'videoHeight'> | null): boolean {
  return !!video && video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0;
}
export function cameraFailure(error: unknown): CameraFailure {
  if (error instanceof CameraInputError) return error.code;
  const name = error instanceof Error ? error.name : '';
  if (name === 'NotAllowedError' || name === 'PermissionDeniedError') return 'denied';
  if (name === 'NotSupportedError' || name === 'TypeError') return 'unsupported';
  return 'unavailable';
}
export async function openBrowserVideo(devices: Pick<MediaDevices, 'getUserMedia'> | undefined, createVideo: () => HTMLVideoElement = () => document.createElement('video')) {
  if (typeof devices?.getUserMedia !== 'function') throw new CameraInputError('unsupported');
  const stream = await devices.getUserMedia({ video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
  let video: HTMLVideoElement | undefined;
  try {
    video = createVideo(); video.srcObject = stream; video.muted = true; video.playsInline = true;
    let playbackTimer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([video.play(),new Promise<never>((_,reject)=>{playbackTimer=setTimeout(()=>reject(new CameraInputError('timeout')),7000);})]);
    } finally { if(playbackTimer)clearTimeout(playbackTimer); }
    const deadline = performance.now() + 7000;
    while (!hasVideoFrame(video)) {
      if (performance.now() >= deadline) throw new CameraInputError('timeout');
      await new Promise(resolve => setTimeout(resolve, 40));
    }
    return { stream, video };
  } catch (error) {
    stream.getTracks().forEach(track => track.stop());
    if (video) { video.pause(); video.srcObject = null; }
    throw error;
  }
}
