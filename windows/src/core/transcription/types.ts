/** Everything a provider needs to open one streaming session. */
export interface TranscriptionConfig {
  apiKey: string;
  model: string;
  /** BCP-47 primary language, e.g. "ja". */
  language: string;
  /** Preferred spellings to bias recognition toward (e.g. "AppSync", "Claude Code"). */
  vocabulary?: string[];
  /** How dictionary terms sound, to hint alongside the spellings. */
  readings?: string[];
}

export type TranscriptionErrorCode = "unauthorized" | "network" | "server" | "timedOut" | "cancelled";

export class TranscriptionError extends Error {
  constructor(
    readonly code: TranscriptionErrorCode,
    detail?: string,
  ) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = "TranscriptionError";
  }
}

/**
 * A speech-to-text service. Stateless: each utterance gets its own session,
 * so back-to-back dictations can never mix audio.
 */
export interface TranscriptionProvider {
  readonly id: string;
  readonly displayName: string;
  /** Sample rate of the mono PCM16 audio this provider expects. */
  readonly sampleRate: number;
  readonly defaultModel: string;
  makeSession(config: TranscriptionConfig, onPartial?: (text: string) => void): TranscriptionSession;
}

/** One utterance of streaming recognition. */
export interface TranscriptionSession {
  /** Starts connecting. Audio may be sent immediately; it is buffered until the connection is ready. */
  start(): void;
  send(pcm16: Uint8Array): void;
  /** Flushes the remaining audio and returns the final transcript. */
  finish(): Promise<string>;
  cancel(): void;
}
