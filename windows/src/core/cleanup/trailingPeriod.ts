// Drops the period that STT and cleanup put after a lone word ("AppSync。", "Lambda."), which gets in the way
// when dictating into a search box, a form field or the middle of a sentence. Port of TrailingPeriod.swift.

import { graphemes, isNewline, isWhitespace, isWordScript, scriptOf } from "../text";

/** Longer text is left alone even without other punctuation: it is likely a sentence. */
const maxWordLength = 20;

export function trimTrailingPeriod(text: string): string {
  const word = graphemes(text.trim());
  const period = word.at(-1);
  if (period !== "。" && period !== ".") return text;
  const body = word.slice(0, -1);
  const last = body.at(-1);
  if (last === undefined || body.length > maxWordLength) return text;
  if (body.some((c) => isNewline(c) || isPunctuation(c))) return text;
  if (hasParticle(body)) return text;
  // Japanese sentences end in hiragana (です, ました, ね); words end in kanji, katakana or letters.
  if (!isWordScript(scriptOf(last))) return text;
  // An English sentence ends in a letter too, so only a single English word loses its ".".
  if (period === "." && body.some(isWhitespace)) return text;
  return body.join("");
}

/**
 * "次回は来週" ends in kanji but is a sentence: a lone は, が, を… between words marks a clause.
 * の and と are left out because they join nouns ("会議の資料", "AWSとGCP").
 */
function hasParticle(characters: string[]): boolean {
  for (let i = 1; i < characters.length - 1; i++) {
    if (
      "はがをにでもへ".includes(characters[i]!) &&
      isWordScript(scriptOf(characters[i - 1]!)) &&
      isWordScript(scriptOf(characters[i + 1]!))
    )
      return true;
  }
  return false;
}

function isPunctuation(character: string): boolean {
  return "、。，．,.！？!?…".includes(character);
}
