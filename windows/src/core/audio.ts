/** RMS level of little-endian PCM16 in 0...1 (roughly), for the HUD meter and silence detection. */
export function pcm16Level(pcm16: Uint8Array): number {
  const count = Math.floor(pcm16.byteLength / 2);
  if (count === 0) return 0;
  const view = new DataView(pcm16.buffer, pcm16.byteOffset, count * 2);
  let sum = 0;
  for (let i = 0; i < count; i++) {
    const s = view.getInt16(i * 2, true) / 32767;
    sum += s * s;
  }
  return Math.sqrt(sum / count);
}
