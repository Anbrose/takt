import type { GeoPoint } from './types.ts';

const EARTH_RADIUS_KM = 6371;
const RAD = Math.PI / 180;

/** Great-circle (straight-line) distance. Placeholder until real routing distances exist. */
export function haversineKm(a: GeoPoint, b: GeoPoint): number {
  const dLat = (b.lat - a.lat) * RAD;
  const dLng = (b.lng - a.lng) * RAD;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * RAD) * Math.cos(b.lat * RAD) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

/** Total length of the path visiting points in the given order. */
export function routeKm(points: readonly GeoPoint[]): number {
  let total = 0;
  for (let i = 1; i < points.length; i++) total += haversineKm(points[i - 1]!, points[i]!);
  return total;
}

/**
 * Display rule: under 100 km one decimal, otherwise an integer ("约 18.1 km", "约 483 km").
 * Rounding follows JS toFixed / Math.round (exact binary value, ties away from zero for halves).
 */
export function formatKm(km: number): string {
  if (km < 100) {
    const s = km.toFixed(1);
    if (s !== '100.0') return s;
  }
  return String(Math.round(km));
}
