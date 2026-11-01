// The bridge to the Rust side (src-tauri): commands, events and Tauri plugins.

import { Channel, invoke } from "@tauri-apps/api/core";
import { emitTo, listen, type UnlistenFn } from "@tauri-apps/api/event";
import { fetch as tauriFetch } from "@tauri-apps/plugin-http";
import { load, type Store } from "@tauri-apps/plugin-store";
import { pcm16Level } from "../core/audio";
import type { FetchLike } from "../core/cleanup/provider";
import type {
  AudioCapture,
  AudioChunk,
  DictationSnapshot,
  HotkeyEvent,
  InsertOutcome,
  TargetApp,
  TextInserter,
} from "../core/dictation/types";
import { sanitizeSettings, type SecretAccount, type Settings, type TriggerId } from "../core/settings";

/**
 * HTTP through Rust: no CORS, and the Origin header the webview would add is dropped (an empty value removes it)
 * so APIs treat cleanup requests as the server-side calls they are.
 */
export const fetchViaRust: FetchLike = async (url, init) => {
  const response = await tauriFetch(url, { ...init, headers: { ...init.headers, Origin: "" } });
  return { status: response.status, text: () => response.text() };
};

function toBytes(data: unknown): Uint8Array {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (Array.isArray(data)) return Uint8Array.from(data as number[]);
  return new Uint8Array();
}

/** The microphone, captured by Rust (cpal/WASAPI) and streamed over a channel. */
export class RustAudioCapture implements AudioCapture {
  /** The recording in progress; each start gets its own, so a late end marker can't end the next one. */
  private current: { ended: Promise<void> } | null = null;

  async start(sampleRate: number, onChunk: (chunk: AudioChunk) => void): Promise<void> {
    let resolveEnded = () => {};
    const ended = new Promise<void>((resolve) => (resolveEnded = resolve));
    const channel = new Channel<ArrayBuffer>((data) => {
      const pcm16 = toBytes(data);
      // An empty chunk marks the end of the stream after audio_stop.
      if (pcm16.byteLength === 0) resolveEnded();
      else onChunk({ pcm16, level: pcm16Level(pcm16) });
    });
    this.current = { ended };
    await invoke("audio_start", { sampleRate, onChunk: channel });
  }

  async stop(): Promise<void> {
    const current = this.current;
    this.current = null;
    await invoke("audio_stop");
    // Don't hang the utterance on a lost end marker.
    if (current) await Promise.race([current.ended, new Promise((resolve) => setTimeout(resolve, 1_000))]);
  }
}

interface RawTargetApp {
  hwnd: number;
  pid: number;
  name: string;
  isSelf: boolean;
}

export const rustInserter: TextInserter = {
  async insert(text: string, target: TargetApp | null): Promise<InsertOutcome> {
    try {
      return await invoke<InsertOutcome>("paste_text", { text, targetHwnd: target?.hwnd ?? null });
    } catch (error) {
      console.error("Paste failed", error);
      // Keep the promise the message makes: the text really is on the clipboard.
      await navigator.clipboard.writeText(text);
      return { kind: "copiedOnly", reason: "貼り付けできませんでした" };
    }
  },
};

export function onHotkey(handler: (event: HotkeyEvent) => void): Promise<UnlistenFn> {
  return listen<{ action: HotkeyEvent["action"]; time: number; foreground: RawTargetApp | null }>("hotkey", (e) =>
    handler(e.payload),
  );
}

export function configureHotkey(trigger: TriggerId, recording: boolean): Promise<void> {
  return invoke("hotkey_configure", { trigger, recording });
}

export function sendHUDState(snapshot: DictationSnapshot): Promise<void> {
  return emitTo("hud", "hud-state", snapshot);
}

/** Shows the HUD without taking focus from the app being dictated into, or hides it. */
export function setHUDVisible(visible: boolean): Promise<void> {
  return invoke("hud_set_visible", { visible });
}

export function openSettings(): Promise<void> {
  return invoke("open_settings");
}

export const secrets = {
  get: (account: SecretAccount) => invoke<string | null>("secret_get", { account }),
  set: (account: SecretAccount, value: string) => invoke<void>("secret_set", { account, value }),
};

export class SettingsFile {
  private constructor(private readonly store: Store) {}

  static async open(): Promise<SettingsFile> {
    return new SettingsFile(await load("settings.json", { autoSave: 200, defaults: {} }));
  }

  async read(): Promise<Settings> {
    return sanitizeSettings(await this.store.get("settings"));
  }

  async write(settings: Settings): Promise<void> {
    await this.store.set("settings", settings);
  }
}
