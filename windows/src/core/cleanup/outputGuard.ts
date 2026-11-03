// Sanity-checks LLM output before it is pasted. Port of CleanupOutputGuard.swift.

import { charCount } from "../text";
import type { CleanupMode } from "./mode";

/** Returns the text to paste, or null when the raw transcript should be used instead. */
export function validateCleanupOutput(output: string, raw: string, mode: CleanupMode): string | null {
  let text = output;
  for (const tag of ["think", "thinking", "reasoning"]) {
    text = text.replace(new RegExp(`<${tag}>[\\s\\S]*?</${tag}>`, "gi"), "");
  }
  text = text.replace(/<\/?transcript>/g, "");
  text = text.trim();
  text = strippingCodeFence(text);
  text = strippingPreamble(text);
  text = text.trim();
  if (text.length === 0) return null;

  // Guard against the model answering the transcript or inventing content.
  const rawCount = charCount(raw);
  const count = charCount(text);
  // Custom instructions may legitimately lengthen the text, e.g. translating Japanese into English.
  const maxRatio = mode === "prompt" || mode === "custom" ? 3.0 : 2.0;
  if (count > rawCount * maxRatio + 40) return null;
  // …or silently dropping most of it. Short inputs are legitimately shortened a lot by filler removal.
  // Custom instructions may ask for a summary; the raw transcript stays in the history.
  if (mode !== "custom" && rawCount >= 30 && count < rawCount * 0.25) return null;
  return text;
}

function strippingCodeFence(text: string): string {
  if (!text.startsWith("```") || !text.endsWith("```") || charCount(text) <= 6) return text;
  const lines = text.split("\n");
  if (lines.length < 3) return text;
  return lines.slice(1, -1).join("\n");
}

/** Drops a leading line like 「以下が整形後の文章です：」 or "Here is the cleaned text:". */
function strippingPreamble(text: string): string {
  const newline = text.indexOf("\n");
  if (newline < 0) return text;
  const first = text.slice(0, newline).trim();
  const looksLikePreamble =
    (first.endsWith("：") || first.endsWith(":")) &&
    ["整形", "修正", "以下", "清書", "Here", "here"].some((word) => first.includes(word));
  return looksLikePreamble ? text.slice(newline + 1) : text;
}
