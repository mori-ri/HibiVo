// The HUD: a black capsule at the bottom of the screen while recording, processing or showing an error.
// Follows DESIGN.md's HUD rules (black at 0.78, white text, level bar coloured only when AI cleanup is on).

import { listen } from "@tauri-apps/api/event";
import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import type { DictationSnapshot } from "../core/dictation/types";
import { keepAwake } from "../platform/keepAwake";
import "./hud.css";

const idle: DictationSnapshot = { phase: { kind: "idle" }, level: 0, partialTranscript: "", cleanupEnabled: true };
const bars = 5;

function HUD() {
  const [snapshot, setSnapshot] = useState<DictationSnapshot>(idle);
  useEffect(() => {
    const unlisten = listen<DictationSnapshot>("hud-state", (event) => setSnapshot(event.payload));
    return () => void unlisten.then((stop) => stop());
  }, []);

  const { phase } = snapshot;
  if (phase.kind === "idle") return null;
  return (
    <div className="capsule">
      {phase.kind === "recording" && (
        <>
          <Level level={snapshot.level} colored={snapshot.cleanupEnabled} />
          <span className="text">{tail(snapshot.partialTranscript) || "聞き取り中…"}</span>
        </>
      )}
      {phase.kind === "processing" && (
        <>
          <span className="dots" aria-hidden>
            <i />
            <i />
            <i />
          </span>
          <span className="text">{snapshot.cleanupEnabled ? "整形中…" : "文字起こし中…"}</span>
        </>
      )}
      {phase.kind === "error" && <span className="text">{phase.message}</span>}
    </div>
  );
}

function Level({ level, colored }: { level: number; colored: boolean }) {
  // Speech RMS rarely goes past ~0.3, so scale it up for a lively meter.
  const amount = Math.min(1, Math.sqrt(level * 4));
  return (
    <span className={colored ? "level colored" : "level"} aria-hidden>
      {Array.from({ length: bars }, (_, i) => {
        const shape = 1 - Math.abs(i - (bars - 1) / 2) / bars;
        return <i key={i} style={{ height: `${Math.max(3, Math.round(18 * amount * shape))}px` }} />;
      })}
    </span>
  );
}

/** The live transcript's end, so the newest words stay visible in a fixed-width capsule. */
function tail(text: string): string {
  const chars = Array.from(text.trim());
  return chars.length > 28 ? "…" + chars.slice(-28).join("") : chars.join("");
}

// Hidden most of the time, but it must draw at once when shown.
keepAwake("hibivo-hud");

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <HUD />
  </StrictMode>,
);
