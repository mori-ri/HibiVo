// The app's composition root, living in the main window: settings, keys, the dictation controller and the HUD.
// The main window stays loaded (hidden) while HibiVo runs in the tray, so dictation keeps working.

import { CleanupCoordinator } from "../core/cleanup/coordinator";
import { makeContextBuilder } from "../core/dictation/context";
import { DictationController } from "../core/dictation/controller";
import type { DictationSnapshot, HistoryRecord } from "../core/dictation/types";
import type { SecretAccount, Settings } from "../core/settings";
import { SonioxProvider } from "../core/transcription/soniox";
import {
  RustAudioCapture,
  SettingsFile,
  configureHotkey,
  fetchViaRust,
  onHotkey,
  openSettings,
  rustInserter,
  secrets,
  sendHUDState,
  setHUDVisible,
} from "../platform/tauri";
import { keepAwake } from "../platform/keepAwake";

const secretAccounts: SecretAccount[] = ["soniox", "anthropic", "openai-compatible", "gemini"];
const historyLimit = 30;

export class AppRuntime {
  private listeners = new Set<() => void>();
  private keys = new Map<SecretAccount, string>();
  private recording = false;
  private hudVisible = false;
  private hudQueue: Promise<void> = Promise.resolve();
  readonly controller: DictationController;
  history: HistoryRecord[] = [];
  snapshot: DictationSnapshot;
  /** Bumped on every change, for React's useSyncExternalStore. */
  version = 0;

  private constructor(
    private readonly file: SettingsFile,
    public settings: Settings,
  ) {
    this.controller = new DictationController({
      audio: new RustAudioCapture(),
      inserter: rustInserter,
      cleanup: new CleanupCoordinator(),
      makeContext: makeContextBuilder({
        settings: () => this.settings,
        secret: (account) => this.keys.get(account),
        transcription: new SonioxProvider(),
        fetch: fetchViaRust,
      }),
      cleanupEnabled: () => this.settings.cleanupEnabled && this.settings.cleanupMode !== "raw",
      onChange: (snapshot) => this.dictationChanged(snapshot),
      onHistory: (record) => {
        this.history = [record, ...this.history].slice(0, historyLimit);
        this.changed();
      },
    });
    this.snapshot = this.controller.snapshot;
  }

  static async start(): Promise<AppRuntime> {
    const file = await SettingsFile.open();
    const runtime = new AppRuntime(file, await file.read());
    await Promise.all(
      secretAccounts.map(async (account) => {
        const value = await secrets.get(account).catch(() => null);
        if (value) runtime.keys.set(account, value);
      }),
    );
    await onHotkey((event) => runtime.controller.handle(event.action, event.time, event.foreground));
    await configureHotkey(runtime.settings.trigger, false);
    keepAwake("hibivo-main");
    // First run: there is nothing to dictate with until a Soniox key is saved.
    if (!runtime.hasSecret("soniox")) await openSettings();
    return runtime;
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  hasSecret(account: SecretAccount): boolean {
    return this.keys.has(account);
  }

  async saveSecret(account: SecretAccount, value: string): Promise<void> {
    await secrets.set(account, value);
    if (value.trim()) this.keys.set(account, value.trim());
    else this.keys.delete(account);
    this.changed();
  }

  async updateSettings(patch: Partial<Settings>): Promise<void> {
    const previous = this.settings;
    this.settings = { ...previous, ...patch };
    this.changed();
    if (this.settings.trigger !== previous.trigger) await configureHotkey(this.settings.trigger, this.recording);
    await this.file.write(this.settings);
  }

  private dictationChanged(snapshot: DictationSnapshot): void {
    const recording = snapshot.phase.kind === "recording";
    if (recording !== this.recording) {
      this.recording = recording;
      // Esc is swallowed only while recording.
      configureHotkey(this.settings.trigger, recording).catch((e: unknown) => console.error(e));
    }
    const phaseChanged = snapshot.phase !== this.snapshot.phase;
    this.snapshot = snapshot;
    // State first, so the HUD has something to draw by the time it shows.
    const sent = sendHUDState(snapshot);
    const visible = snapshot.phase.kind !== "idle";
    sent.catch((e: unknown) => console.error(e));
    if (visible !== this.hudVisible) {
      this.hudVisible = visible;
      // Queued, so a quick show-then-hide can't arrive out of order.
      this.hudQueue = this.hudQueue
        .then(() => sent)
        .then(() => setHUDVisible(visible))
        .catch((e: unknown) => console.error(e));
    }
    if (phaseChanged) this.changed();
  }

  private changed(): void {
    this.version++;
    for (const listener of this.listeners) listener();
  }
}
