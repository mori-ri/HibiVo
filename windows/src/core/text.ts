// Text helpers that match Swift's `String` semantics, so the ported rules count characters the same way.

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** User-perceived characters (Swift `Character`s), not UTF-16 code units. */
export function graphemes(text: string): string[] {
  return Array.from(segmenter.segment(text), (s) => s.segment);
}

/** Swift `String.count`. */
export function charCount(text: string): number {
  let count = 0;
  for (const _ of segmenter.segment(text)) count++;
  return count;
}

/** Swift `String.prefix(n)` by characters. */
export function prefixChars(text: string, n: number): string {
  return graphemes(text).slice(0, n).join("");
}

/** Swift `Character.isNewline`. */
export function isNewline(character: string): boolean {
  return /^[\n\r\v\f\u0085\u2028\u2029]/u.test(character);
}

/** Swift `Character.isWhitespace`. */
export function isWhitespace(character: string): boolean {
  return /^\s/u.test(character);
}

export type Script = "latin" | "hiragana" | "katakana" | "kanji" | "other";

/** The script of one character, for finding word boundaries in Japanese text. */
export function scriptOf(character: string): Script {
  const folded = Array.from(character.normalize("NFKC"));
  if (folded.length !== 1) return "other";
  const v = folded[0]!.codePointAt(0)!;
  if ((v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5a) || (v >= 0x61 && v <= 0x7a)) return "latin";
  if (v >= 0x3041 && v <= 0x309f) return "hiragana";
  if (v === 0x30fb) return "other"; // "・" separates words.
  if (v >= 0x30a0 && v <= 0x30ff) return "katakana";
  if (v === 0x3005 || (v >= 0x3400 && v <= 0x4dbf) || (v >= 0x4e00 && v <= 0x9fff) || (v >= 0xf900 && v <= 0xfaff))
    return "kanji";
  return "other";
}

/** Scripts a vocabulary word is written in. Hiragana is left out: particles and okurigana are hiragana. */
export function isWordScript(script: Script): boolean {
  return script === "latin" || script === "katakana" || script === "kanji";
}
