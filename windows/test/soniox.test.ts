// Ported from the macOS app's SonioxProtocolTests.swift, plus session tests against a fake socket.

import { describe, expect, it } from "vitest";
import {
  SonioxProvider,
  SonioxTranscript,
  sonioxConfigMessage,
  sonioxTerms,
  type SonioxResponse,
  type WebSocketLike,
} from "../src/core/transcription/soniox";
import { TranscriptionError } from "../src/core/transcription/types";

const response = (tokens: [string, boolean][], finished?: boolean): SonioxResponse => ({
  tokens: tokens.map(([text, is_final]) => ({ text, is_final })),
  finished,
});

class FakeSocket implements WebSocketLike {
  binaryType = "blob";
  onopen: WebSocketLike["onopen"] = null;
  onmessage: WebSocketLike["onmessage"] = null;
  onerror: WebSocketLike["onerror"] = null;
  onclose: WebSocketLike["onclose"] = null;
  sent: (string | Uint8Array)[] = [];
  closed = false;

  send(data: string | Uint8Array) {
    this.sent.push(data);
  }
  close() {
    this.closed = true;
  }
  open() {
    this.onopen?.({});
  }
  receive(message: SonioxResponse) {
    this.onmessage?.({ data: JSON.stringify(message) });
  }
  get strings(): string[] {
    return this.sent.filter((d): d is string => typeof d === "string");
  }
}

function makeSession(finalizeTimeoutMs = 4_000) {
  const socket = new FakeSocket();
  const partials: string[] = [];
  const provider = new SonioxProvider(() => socket, finalizeTimeoutMs);
  const session = provider.makeSession({ apiKey: "k", model: "stt-rt-v5", language: "ja" }, (t) => partials.push(t));
  return { socket, session, partials };
}

describe("Soniox protocol", () => {
  it("includes Japanese and English hints and terms in the config", () => {
    const object = JSON.parse(
      sonioxConfigMessage(
        { apiKey: "k", model: "stt-rt-v5", language: "ja", vocabulary: ["AppSync", "Bedrock"] },
        16_000,
      ),
    );
    expect(object).toEqual({
      api_key: "k",
      model: "stt-rt-v5",
      audio_format: "pcm_s16le",
      sample_rate: 16_000,
      num_channels: 1,
      language_hints: ["ja", "en"],
      context: { terms: ["AppSync", "Bedrock"] },
    });
  });

  it("hints readings after spellings without duplicates, within 200 terms", () => {
    expect(
      sonioxTerms({
        apiKey: "k",
        model: "m",
        language: "ja",
        vocabulary: ["HibiVo", "AppSync"],
        readings: ["ヒビボ", "AppSync"],
      }),
    ).toEqual(["HibiVo", "AppSync", "ヒビボ"]);
    const terms = sonioxTerms({
      apiKey: "k",
      model: "m",
      language: "ja",
      vocabulary: Array.from({ length: 150 }, (_, i) => `v${i}`),
      readings: Array.from({ length: 150 }, (_, i) => `r${i}`),
    });
    expect(terms).toHaveLength(200);
    expect(terms.at(0)).toBe("v0");
    expect(terms.at(-1)).toBe("r49");
  });

  it("omits context without vocabulary, and hints only English for English", () => {
    const json = sonioxConfigMessage({ apiKey: "k", model: "m", language: "en" }, 16_000);
    expect(json).not.toContain("context");
    expect(JSON.parse(json).language_hints).toEqual(["en"]);
  });

  it("accumulates final tokens and replaces tentative ones", () => {
    const t = new SonioxTranscript();
    t.apply(response([["今日の", true], ["15", false]]));
    expect(t.displayText).toBe("今日の15");
    t.apply(response([["15時から", false]]));
    expect(t.finalText).toBe("今日の");
    expect(t.displayText).toBe("今日の15時から");
    t.apply(response([["15時から", true], ["AWSの", true], ["AppSync", false]]));
    expect(t.displayText).toBe("今日の15時からAWSのAppSync");
    expect(t.didFinalize).toBe(false);
  });

  it("detects the finalize marker and keeps it out of the text", () => {
    const t = new SonioxTranscript();
    t.apply(response([["打ち合わせをします", true], ["<fin>", true]]));
    expect(t.didFinalize).toBe(true);
    expect(t.finalText).toBe("打ち合わせをします");
  });
});

describe("Soniox session", () => {
  it("buffers audio until the socket opens, then sends config first", () => {
    const { socket, session } = makeSession();
    session.start();
    session.send(new Uint8Array([1, 2]));
    expect(socket.sent).toHaveLength(0);
    socket.open();
    session.send(new Uint8Array([3, 4]));
    expect(socket.sent.map((d) => (typeof d === "string" ? "config" : Array.from(d)))).toEqual([
      "config",
      [1, 2],
      [3, 4],
    ]);
    expect(JSON.parse(socket.strings[0]!).api_key).toBe("k");
  });

  it("finalizes and returns the text once <fin> arrives", async () => {
    const { socket, session, partials } = makeSession();
    session.start();
    socket.open();
    socket.receive(response([["今日は", true], ["晴れ", false]]));
    const finished = session.finish();
    expect(socket.strings.at(-1)).toBe('{"type":"finalize"}');
    // 200 ms of silence goes out before the finalize message.
    expect((socket.sent.at(-2) as Uint8Array).byteLength).toBe(6_400);
    socket.receive(response([["晴れ", true], ["<fin>", true]]));
    await expect(finished).resolves.toBe("今日は晴れ");
    expect(partials).toEqual(["今日は晴れ", "今日は晴れ"]);
    expect(socket.closed).toBe(true);
  });

  it("sends finalize after connecting when finish comes first", async () => {
    const { socket, session } = makeSession();
    session.start();
    const finished = session.finish();
    expect(socket.sent).toHaveLength(0);
    socket.open();
    expect(socket.strings.at(-1)).toBe('{"type":"finalize"}');
    socket.receive(response([["はい", true], ["<fin>", true]]));
    await expect(finished).resolves.toBe("はい");
  });

  it("keeps the tentative text when finalize times out", async () => {
    const { socket, session } = makeSession(20);
    session.start();
    socket.open();
    socket.receive(response([["途中まで", false]]));
    await expect(session.finish()).resolves.toBe("途中まで");
  });

  it("reports a bad key as unauthorized", async () => {
    const { socket, session } = makeSession();
    session.start();
    socket.open();
    socket.receive({ error_code: 401, error_message: "Invalid API key" });
    await expect(session.finish()).rejects.toMatchObject({ code: "unauthorized" });
  });

  it("reports a dropped connection with nothing heard as a network error", async () => {
    const { socket, session } = makeSession();
    session.start();
    socket.onclose?.({ code: 1006, reason: "" });
    const error = await session.finish().catch((e: unknown) => e);
    expect(error).toBeInstanceOf(TranscriptionError);
    expect((error as TranscriptionError).code).toBe("network");
  });
});
