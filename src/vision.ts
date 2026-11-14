import type { Box } from './contracts';
import cvScriptUrl from '@techstark/opencv-js/dist/opencv.js?url';

export type Homography = number[];
export interface TrackingResult {
  status: 'tracking' | 'lost';
  polygon?: number[][];
  homography?: Homography;
  confidence: number;
}
export interface Tracker {
  update(currentCanvas: HTMLCanvasElement): TrackingResult;
  project(box: Box): number[][] | null;
  dispose(): void;
}

/** Project image pixels; returns null when a point projects behind/at infinity. */
export function projectPoint(h: Homography, x: number, y: number): number[] | null {
  if (h.length !== 9 || !h.every(Number.isFinite)) return null;
  const d = h[6] * x + h[7] * y + h[8];
  if (!Number.isFinite(d) || Math.abs(d) < 1e-8) return null;
  const point = [(h[0] * x + h[1] * y + h[2]) / d, (h[3] * x + h[4] * y + h[5]) / d];
  return point.every(Number.isFinite) ? point : null;
}

/** Reference-normalized box -> current canvas pixel polygon. */
export function projectBox(box: Box, h: Homography, referenceWidth: number, referenceHeight: number): number[][] | null {
  const [x, y, w, z] = box;
  if (![x, y, w, z, referenceWidth, referenceHeight].every(Number.isFinite) || w <= 0 || z <= 0 || x < 0 || y < 0 || x + w > 1.00001 || y + z > 1.00001 || referenceWidth <= 0 || referenceHeight <= 0) return null;
  const points = [[x, y], [x + w, y], [x + w, y + z], [x, y + z]].map(([u, v]) => projectPoint(h, u * referenceWidth, v * referenceHeight));
  return points.every(Boolean) ? points as number[][] : null;
}

export function polygonArea(points: number[][]): number {
  if (points.length < 3 || points.some(p => p.length !== 2 || !p.every(Number.isFinite))) return 0;
  return Math.abs(points.reduce((sum, p, i) => {
    const q = points[(i + 1) % points.length];
    return sum + p[0] * q[1] - q[0] * p[1];
  }, 0)) / 2;
}

/** Reject folded, degenerate, wildly off-screen, and absurdly large estimates. */
export function isPlausiblePolygon(points: number[][], width: number, height: number): boolean {
  if (points.length !== 4 || width <= 0 || height <= 0) return false;
  const area = polygonArea(points);
  if (area < width * height * 0.012 || area > width * height * 5) return false;
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4];
    if (a.some((v, j) => !Number.isFinite(v) || v < -(j ? height : width) * 2 || v > (j ? height : width) * 3)) return false;
    const cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (Math.abs(cross) < 1e-6) return false;
    if (sign && Math.sign(cross) !== sign) return false;
    sign = Math.sign(cross);
  }
  return true;
}

/** Synthetic demo only. time is seconds; H maps natural source pixels to canvas. */
export function getDemoTransform(time: number, width: number, height: number, referenceWidth = width, referenceHeight = height): Homography {
  const fit = Math.min(width / referenceWidth, height / referenceHeight) * 0.9;
  const scale = fit * (1 + 0.04 * Math.sin(time * 0.65));
  const angle = 0.035 * Math.sin(time * 0.42);
  const a = Math.cos(angle) * scale, b = Math.sin(angle) * scale;
  const cx = width * (0.5 + 0.025 * Math.sin(time * 0.55));
  const cy = height * (0.5 + 0.022 * Math.cos(time * 0.45));
  return [a, -b, cx - a * referenceWidth / 2 + b * referenceHeight / 2, b, a, cy - b * referenceWidth / 2 - a * referenceHeight / 2, 0, 0, 1];
}

function imageSize(image: CanvasImageSource): [number, number] {
  const source = image as unknown as Record<string, number>;
  return [source.naturalWidth || source.videoWidth || source.width, source.naturalHeight || source.videoHeight || source.height];
}

/** Draw synthetic camera motion; never call its known H a measured CV result. */
export function drawDemoScene(ctx: CanvasRenderingContext2D, image: CanvasImageSource, time: number): Homography {
  const [rw, rh] = imageSize(image);
  const { width, height } = ctx.canvas;
  const h = getDemoTransform(time, width, height, rw, rh);
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = '#161513';
  ctx.fillRect(0, 0, width, height);
  ctx.setTransform(h[0], h[3], h[1], h[4], h[2], h[5]);
  ctx.drawImage(image, 0, 0, rw, rh);
  ctx.restore();
  return h;
}

let cvPromise: Promise<any> | null = null;
export function loadOpenCV(): Promise<any> {
  if (!cvPromise) cvPromise = (async () => {
    // The upstream CommonJS module exports a Promise. Bundling it as an ESM
    // namespace can make its `then` run with the wrong receiver. Load its
    // browser build as a classic script instead; Vite emits the asset lazily.
    if (typeof document === 'undefined') throw new Error('OpenCV browser initialization requires a document.');
    const globals = globalThis as unknown as { cv?: any };
    if (!globals.cv) await new Promise<void>((resolve, reject) => {
      const script = document.createElement('script');
      script.src = cvScriptUrl;
      script.async = true;
      script.onload = () => resolve();
      script.onerror = () => { script.remove(); reject(new Error('Unable to load the local OpenCV engine.')); };
      document.head.appendChild(script);
    });
    let cv: any = globals.cv;
    if (typeof cv?.then === 'function') cv = await cv;
    if (cv?.Mat) return cv;
    return await new Promise<any>((resolve, reject) => {
      const started = Date.now();
      const poll = () => {
        if (cv?.Mat) resolve(cv);
        else if (Date.now() - started > 25000) reject(new Error('OpenCV initialization timed out. Reload and try again.'));
        else setTimeout(poll, 50);
      };
      poll();
    });
  })().catch(error => { cvPromise = null; throw error; });
  return cvPromise;
}

/** Actual image tracking, independent of Gemini semantics and synthetic motion. */
export async function createTracker(referenceCanvas: HTMLCanvasElement, suppliedCV?: any): Promise<Tracker> {
  if (!referenceCanvas.width || !referenceCanvas.height) throw new Error('Reference image is empty.');
  const cv = suppliedCV ?? await loadOpenCV();
  if (!cv.ORB || !cv.findHomography) throw new Error('This OpenCV build does not expose ORB / homography.');
  const rw = referenceCanvas.width, rh = referenceCanvas.height;
  const maxDimension = 720;
  const refScale = Math.min(1, maxDimension / Math.max(rw, rh));
  const orb = new cv.ORB(1400);
  const matcher = new cv.BFMatcher(cv.NORM_HAMMING, false);
  const refKeypoints = new cv.KeyPointVector();
  const refDescriptors = new cv.Mat();
  let lastH: Homography | null = null;
  let disposed = false;

  function grayscale(canvas: HTMLCanvasElement, scale: number): any {
    const context = canvas.getContext('2d', { willReadFrequently: true });
    if (!context) throw new Error('Cannot read camera frame.');
    const rgba = cv.matFromImageData(context.getImageData(0, 0, canvas.width, canvas.height));
    const gray = new cv.Mat();
    const sized = new cv.Mat();
    try {
      cv.cvtColor(rgba, gray, cv.COLOR_RGBA2GRAY);
      if (scale < 0.999) {
        cv.resize(gray, sized, new cv.Size(Math.max(1, Math.round(canvas.width * scale)), Math.max(1, Math.round(canvas.height * scale))), 0, 0, cv.INTER_AREA);
        return sized;
      }
      return gray.clone();
    } finally { rgba.delete(); gray.delete(); if (scale >= 0.999) sized.delete(); }
  }

  const referenceGray = grayscale(referenceCanvas, refScale);
  const mask = new cv.Mat();
  try { orb.detectAndCompute(referenceGray, mask, refKeypoints, refDescriptors); }
  catch (error) { orb.delete(); matcher.delete(); refKeypoints.delete(); refDescriptors.delete(); throw error; }
  finally { referenceGray.delete(); mask.delete(); }

  const lost = (): TrackingResult => { lastH = null; return { status: 'lost', confidence: 0 }; };
  return {
    update(currentCanvas) {
      if (disposed || !currentCanvas.width || !currentCanvas.height || refDescriptors.empty() || refKeypoints.size() < 12) return lost();
      const currentScale = Math.min(1, maxDimension / Math.max(currentCanvas.width, currentCanvas.height));
      let gray: any, keypoints: any, descriptors: any, emptyMask: any, matches: any, src: any, dst: any, homography: any, inlierMask: any;
      try {
        gray = grayscale(currentCanvas, currentScale);
        keypoints = new cv.KeyPointVector(); descriptors = new cv.Mat(); emptyMask = new cv.Mat();
        orb.detectAndCompute(gray, emptyMask, keypoints, descriptors);
        if (descriptors.empty() || keypoints.size() < 12) return lost();
        matches = new cv.DMatchVectorVector();
        matcher.knnMatch(refDescriptors, descriptors, matches, 2);
        const from: number[] = [], to: number[] = [];
        const seenTrain = new Set<number>();
        for (let i = 0; i < matches.size(); i++) {
          const pair = matches.get(i);
          try {
            if (pair.size() < 2) continue;
            const best = pair.get(0), next = pair.get(1);
            if (best.distance >= 0.73 * next.distance || seenTrain.has(best.trainIdx)) continue;
            seenTrain.add(best.trainIdx);
            const a = refKeypoints.get(best.queryIdx).pt, b = keypoints.get(best.trainIdx).pt;
            from.push(a.x, a.y); to.push(b.x, b.y);
          } finally { pair.delete(); }
        }
        if (from.length < 24) return lost();
        src = cv.matFromArray(from.length / 2, 1, cv.CV_32FC2, from);
        dst = cv.matFromArray(to.length / 2, 1, cv.CV_32FC2, to);
        inlierMask = new cv.Mat();
        homography = cv.findHomography(src, dst, cv.RANSAC, 3.5, inlierMask);
        if (homography.empty()) return lost();
        const hs = Array.from(homography.data64F as Float64Array);
        if (hs.length !== 9 || !hs.every(Number.isFinite)) return lost();
        let inliers = 0, error = 0;
        for (let i = 0; i < from.length / 2; i++) if (inlierMask.data[i]) {
          const p = projectPoint(hs, from[i * 2], from[i * 2 + 1]);
          if (p) { inliers++; error += Math.hypot(p[0] - to[i * 2], p[1] - to[i * 2 + 1]); }
        }
        const ratio = inliers / (from.length / 2);
        if (inliers < 10 || ratio < 0.45 || error / inliers > 4) return lost();
        const h = [hs[0] * refScale / currentScale, hs[1] * refScale / currentScale, hs[2] / currentScale, hs[3] * refScale / currentScale, hs[4] * refScale / currentScale, hs[5] / currentScale, hs[6] * refScale, hs[7] * refScale, hs[8]];
        const polygon = projectBox([0, 0, 1, 1], h, rw, rh);
        if (!polygon || !isPlausiblePolygon(polygon, currentCanvas.width, currentCanvas.height)) return lost();
        lastH = h;
        return { status: 'tracking', polygon, homography: [...h], confidence: Math.min(1, ratio * Math.min(1, inliers / 35)) };
      } catch { return lost(); }
      finally { for (const mat of [gray, keypoints, descriptors, emptyMask, matches, src, dst, homography, inlierMask]) mat?.delete(); }
    },
    project(box) { return !disposed && lastH ? projectBox(box, lastH, rw, rh) : null; },
    dispose() {
      if (disposed) return;
      disposed = true; lastH = null;
      orb.delete(); matcher.delete(); refKeypoints.delete(); refDescriptors.delete();
    },
  };
}
