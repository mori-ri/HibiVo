// Soniox real-time transcription (wss://stt-rt.soniox.com/transcribe-websocket).
// Port of SonioxProtocol.swift and SonioxProvider.swift (dictation only; no diarization yet).

import {
  TranscriptionError,
  type TranscriptionConfig,
  type TranscriptionProvider,
  type TranscriptionSession,
} from "./types";

export const sonioxEndpoint = "wss://stt-rt.soniox.com/transcribe-websocket";
const finalizeMessage = '{"type":"finalize"}';
const finalizeMarker = "<fin>";
const endMarker = "<end>";

export interface SonioxToken {
  text: string;
  is_final?: boolean;
}

export interface SonioxResponse {
  tokens?: SonioxToken[];
  finished?: boolean;
  error_code?: number;
  error_message?: string;
}

/** Preferred spellings first, then readings, without duplicates, within Soniox's 200-term budget. */
export function sonioxTerms(config: TranscriptionConfig): string[] {
  return [...new Set([...(config.vocabulary ?? []), ...(config.readings ?? [])])].slice(0, 200);
}

/** Hint English as well so technical terms stay in Latin script ("AppSync", not "アップシンク"). */
export function sonioxLanguageHints(language: string): string[] {
  return language === "en" ? ["en"] : [language, "en"];
}

export function sonioxConfigMessage(config: TranscriptionConfig, sampleRate: number): string {
  const terms = sonioxTerms(config);
  return JSON.stringify({
    api_key: config.apiKey,
    model: config.model,
    audio_format: "pcm_s16le",
    sample_rate: Math.round(sampleRate),
    num_channels: 1,
    language_hints: sonioxLanguageHints(config.language),
    ...(terms.length > 0 ? { context: { terms } } : {}),
  });
}

/** Folds Soniox token messages into a transcript. Final tokens arrive once; non-final ones are replaced each time. */
export class SonioxTranscript {
  finalText = "";
  tentativeText = "";
  didFinalize = false;
  didFinish = false;

  get displayText(): string {
    return this.finalText + this.tentativeText;
  }

  apply(response: SonioxResponse): void {
    if (response.finished === true) this.didFinish = true;
    if (!response.tokens) return;
    let tentative = "";
    for (const token of response.tokens) {
      if (token.text === finalizeMarker) this.didFinalize = true;
      else if (token.text === endMarker) continue;
      else if (token.is_final) this.finalText += token.text;
      else tentative += token.text;
    }
    this.tentativeText = tentative;
  }
}

/** The subset of the browser WebSocket the session uses, so tests can drive it. */
export interface WebSocketLike {
  binaryType: string;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onclose: ((event: { code: number; reason: string }) => void) | null;
  send(data: string | Uint8Array): void;
  close(code?: number, reason?: string): void;
}

export type WebSocketFactory = (url: string) => WebSocketLike;

export class SonioxProvider implements TranscriptionProvider {
  readonly id = "soniox";
  readonly displayName = "Soniox";
  readonly sampleRate = 16_000;
  readonly defaultModel = "stt-rt-v5";

  constructor(
    private readonly makeSocket: WebSocketFactory = (url) => new WebSocket(url) as unknown as WebSocketLike,
    private readonly finalizeTimeoutMs = 4_000,
  ) {}

  makeSession(config: TranscriptionConfig, onPartial?: (text: string) => void): TranscriptionSession {
    return new SonioxSession(config, this.sampleRate, this.makeSocket, this.finalizeTimeoutMs, onPartial);
  }
}

/**
 * One Soniox WebSocket connection for one utterance.
 *
 * Audio sent before the connection is ready is buffered, so speech from the moment the key goes down is never lost.
 * On `finish()` we send a short tail of silence plus `finalize`, then wait for the `<fin>` token, which marks every
 * earlier token as final.
 */
export class SonioxSession implements TranscriptionSession {
  /** Soniox recommends a little trailing silence before a manual finalize: 200 ms of PCM16. */
  private readonly trailingSilence: Uint8Array;

  private socket: WebSocketLike | null = null;
  private isReady = false;
  private isClosed = false;
  private finalizeRequested = false;
  private pending: Uint8Array[] = [];
  private transcript = new SonioxTranscript();
  private failure: TranscriptionError | null = null;
  private waiter: { resolve: () => void; reject: (error: TranscriptionError) => void } | null = null;
  private timeout: ReturnType<typeof setTimeout> | undefined;

  constructor(
    private readonly config: TranscriptionConfig,
    private readonly sampleRate: number,
    private readonly makeSocket: WebSocketFactory,
    private readonly finalizeTimeoutMs: number,
    private readonly onPartial?: (text: string) => void,
  ) {
    this.trailingSilence = new Uint8Array(Math.round((sampleRate * 2) / 5));
  }

  start(): void {
    if (this.socket || this.isClosed) return;
    let socket: WebSocketLike;
    try {
      socket = this.makeSocket(sonioxEndpoint);
    } catch (error) {
      this.fail(new TranscriptionError("network", String(error)));
      return;
    }
    this.socket = socket;
    socket.binaryType = "arraybuffer";
    socket.onopen = () => {
      if (this.isClosed) return;
      socket.send(sonioxConfigMessage(this.config, this.sampleRate));
      for (const chunk of this.pending) socket.send(chunk);
      this.pending = [];
      this.isReady = true;
      if (this.finalizeRequested) this.sendFinalize();
    };
    socket.onmessage = (event) => this.handle(event.data);
    socket.onerror = () => {
      if (!this.isClosed) this.fail(new TranscriptionError("network", "socket error"));
    };
    socket.onclose = (event) => {
      if (!this.isClosed) this.fail(new TranscriptionError("network", `closed ${event.code} ${event.reason}`));
    };
  }

  send(pcm16: Uint8Array): void {
    if (this.isClosed || this.failure) return;
    if (this.isReady) this.socket?.send(pcm16);
    else this.pending.push(pcm16);
  }

  async finish(): Promise<string> {
    let waitError: TranscriptionError | null = null;
    if (!this.failure && !this.transcript.didFinalize) {
      this.finalizeRequested = true;
      if (this.isReady) this.sendFinalize();
      try {
        await this.waitForFinalize();
      } catch (error) {
        waitError = error instanceof TranscriptionError ? error : new TranscriptionError("network", String(error));
      }
    }
    this.close();
    // After a successful finalize every token is final. On timeout or a dropped connection,
    // keep whatever we have (including tentative text) rather than losing the utterance.
    const text = this.transcript.displayText.trim();
    const error = this.failure ?? waitError;
    if (!text && error) throw error;
    if (error) console.info(`Returning partial transcript after ${error.message}`);
    return text;
  }

  cancel(): void {
    this.fail(new TranscriptionError("cancelled"));
    this.close();
  }

  private sendFinalize(): void {
    this.socket?.send(this.trailingSilence);
    this.socket?.send(finalizeMessage);
  }

  private waitForFinalize(): Promise<void> {
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      this.waiter = { resolve, reject };
      this.timeout = setTimeout(() => this.reject(new TranscriptionError("timedOut")), this.finalizeTimeoutMs);
    });
  }

  private resolve(): void {
    const waiter = this.waiter;
    if (!waiter) return;
    this.waiter = null;
    clearTimeout(this.timeout);
    waiter.resolve();
  }

  private reject(error: TranscriptionError): void {
    const waiter = this.waiter;
    if (!waiter) return;
    this.waiter = null;
    clearTimeout(this.timeout);
    waiter.reject(error);
  }

  private handle(data: unknown): void {
    const text = typeof data === "string" ? data : data instanceof ArrayBuffer ? new TextDecoder().decode(data) : null;
    if (text === null) return;
    let response: SonioxResponse;
    try {
      response = JSON.parse(text) as SonioxResponse;
    } catch {
      return;
    }
    if (response.error_code !== undefined) {
      console.error(`Soniox error ${response.error_code}: ${response.error_message ?? ""}`);
      this.fail(
        response.error_code === 401
          ? new TranscriptionError("unauthorized")
          : new TranscriptionError("server", response.error_message ?? String(response.error_code)),
      );
      return;
    }
    this.transcript.apply(response);
    this.onPartial?.(this.transcript.displayText);
    if (this.transcript.didFinalize || this.transcript.didFinish) this.resolve();
  }

  private fail(error: TranscriptionError): void {
    if (!this.failure) this.failure = error;
    this.reject(error);
  }

  private close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    const socket = this.socket;
    if (socket) {
      socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
      try {
        socket.close(1000);
      } catch {
        // Already closed.
      }
    }
  }
}
