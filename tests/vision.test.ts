import { describe, expect, it } from 'vitest';
import { createRequire } from 'node:module';
import { createTracker, getDemoTransform, isPlausiblePolygon, polygonArea, projectBox, projectPoint } from '../src/vision';

describe('reference image geometry', () => {
  it('maps a normalized detail through translation and scale', () => {
    expect(projectBox([0.2, 0.1, 0.3, 0.4], [2, 0, 30, 0, 2, 50, 0, 0, 1], 100, 200)).toEqual([[70, 90], [130, 90], [130, 250], [70, 250]]);
  });
  it('divides by the projective component', () => {
    expect(projectPoint([1, 0, 0, 0, 1, 0, 0.01, 0, 1], 100, 50)).toEqual([50, 25]);
  });
  it('rejects invalid regions and infinity rather than drawing stale coordinates', () => {
    expect(projectBox([-0.1, 0, 0.3, 0.2], [1, 0, 0, 0, 1, 0, 0, 0, 1], 100, 100)).toBeNull();
    expect(projectBox([0, 0, 0, 0.2], [1, 0, 0, 0, 1, 0, 0, 0, 1], 100, 100)).toBeNull();
    expect(projectPoint([1, 0, 0, 0, 1, 0, 0, 0, 0], 10, 10)).toBeNull();
    expect(projectPoint([NaN, 0, 0, 0, 1, 0, 0, 0, 1], 10, 10)).toBeNull();
  });
  it('rejects crossed or degenerate tracked polygons', () => {
    expect(isPlausiblePolygon([[0, 0], [100, 100], [100, 0], [0, 100]], 600, 600)).toBe(false);
    expect(isPlausiblePolygon([[20, 20], [500, 20], [500, 500], [20, 500]], 600, 600)).toBe(true);
    expect(isPlausiblePolygon([[0, 0], [1, 0], [1, 1], [0, 1]], 600, 600)).toBe(false);
  });
});

describe('explicit synthetic motion', () => {
  it('preserves the image aspect ratio and produces a plausible scene', () => {
    const h = getDemoTransform(0, 600, 600, 1200, 900);
    const polygon = projectBox([0, 0, 1, 1], h, 1200, 900)!;
    expect(isPlausiblePolygon(polygon, 600, 600)).toBe(true);
    const w = Math.hypot(polygon[1][0] - polygon[0][0], polygon[1][1] - polygon[0][1]);
    const height = Math.hypot(polygon[3][0] - polygon[0][0], polygon[3][1] - polygon[0][1]);
    expect(w / height).toBeCloseTo(1200 / 900);
    expect(polygonArea(polygon)).toBeGreaterThan(100000);
  });
  it('changes the tracked location over time without changing reference detail identity', () => {
    const box: [number, number, number, number] = [0.6, 0.3, 0.1, 0.2];
    const a = projectBox(box, getDemoTransform(0, 600, 600, 1200, 900), 1200, 900)!;
    const b = projectBox(box, getDemoTransform(3, 600, 600, 1200, 900), 1200, 900)!;
    expect(a).not.toEqual(b);
    expect(polygonArea(b)).toBeGreaterThan(0);
    expect(box).toEqual([0.6, 0.3, 0.1, 0.2]);
  });
});

describe('actual OpenCV image tracking', () => {
  it('recovers a measured translation, clears the box on blank frames, and reacquires', async () => {
    const width = 420, height = 320;
    const pixels = new Uint8ClampedArray(width * height * 4);
    let seed = 3;
    const random = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed >>> 24; };
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const value = ((Math.floor(x / 11) + Math.floor(y / 13)) % 2 ? 170 : 20) + random() % 60;
      pixels[i] = pixels[i + 1] = pixels[i + 2] = value; pixels[i + 3] = 255;
    }
    const moved = new Uint8ClampedArray(pixels.length);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4, xx = x - 18, yy = y - 12;
      if (xx >= 0 && yy >= 0 && xx < width && yy < height) {
        const j = (yy * width + xx) * 4;
        for (let k = 0; k < 4; k++) moved[i + k] = pixels[j + k];
      } else moved[i + 3] = 255;
    }
    // This shim supplies real RGBA image data; the matching/ORB/RANSAC are actual OpenCV.
    const canvas = (data: Uint8ClampedArray) => ({ width, height, getContext: () => ({ getImageData: () => ({ width, height, data }) }) }) as unknown as HTMLCanvasElement;
    // Require the genuine upstream runtime directly so its Promise retains its
    // receiver; Vite's browser path loads the identical classic-script asset.
    const require = createRequire(import.meta.url);
    const cv = await require('@techstark/opencv-js');
    const tracker = await createTracker(canvas(pixels), cv);
    try {
      const result = tracker.update(canvas(moved));
      expect(result.status).toBe('tracking');
      expect(result.confidence).toBeGreaterThan(0.45);
      expect(result.homography![2]).toBeCloseTo(18, 0);
      expect(result.homography![5]).toBeCloseTo(12, 0);
      const point = tracker.project([0.2, 0.2, 0.1, 0.1])![0];
      expect(Math.hypot(point[0] - 102, point[1] - 76)).toBeLessThan(2);
      expect(tracker.update(canvas(new Uint8ClampedArray(pixels.length))).status).toBe('lost');
      expect(tracker.project([0.2, 0.2, 0.1, 0.1])).toBeNull();
      expect(tracker.update(canvas(moved)).status).toBe('tracking');
    } finally { tracker.dispose(); }
    expect(tracker.project([0.2, 0.2, 0.1, 0.1])).toBeNull();
  }, 30000);
});
