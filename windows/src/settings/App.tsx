import { useState, useSyncExternalStore, type ReactNode } from "react";
import { cleanupModeInfo, cleanupModes, customInstructionsLimit } from "../core/cleanup/mode";
import { cleanupProviderInfo, cleanupProviderKinds, openAIDefaultBaseURL } from "../core/cleanup/provider";
import type { HistoryRecord } from "../core/dictation/types";
import { languageNames, languages, secretAccount, triggerInfo, triggers, type SecretAccount } from "../core/settings";
import { charCount } from "../core/text";
import type { AppRuntime } from "./runtime";

export function App({ runtime }: { runtime: AppRuntime }) {
  useSyncExternalStore(runtime.subscribe, () => runtime.version);
  const { settings } = runtime;
  const update = (patch: Parameters<AppRuntime["updateSettings"]>[0]) => void runtime.updateSettings(patch);
  const trigger = triggerInfo[settings.trigger].name;
  const provider = settings.cleanupProvider;

  return (
    <main>
      <header>
        <h1>HibiVo</h1>
        <p className="lead">
          <kbd>{trigger}</kbd> を押して話し、もう一度押すと、カーソルの位置に入力します。長押しした場合は、離したときに入力します。
          <kbd>Esc</kbd> で取り消します。
        </p>
        {!runtime.hasSecret("soniox") && (
          <p className="notice">はじめに、下の「音声認識」に Soniox の API Key を保存してください。</p>
        )}
      </header>

      <Section title="ホットキー">
        <Row label="トリガーキー" note={triggerInfo[settings.trigger].note}>
          <select value={settings.trigger} onChange={(e) => update({ trigger: e.target.value as typeof settings.trigger })}>
            {triggers.map((t) => (
              <option key={t} value={t}>
                {triggerInfo[t].name}
              </option>
            ))}
          </select>
        </Row>
      </Section>

      <Section title="音声認識">
        <Row label="言語" note="話す言語。AI 整形のプロンプトもこの言語に合わせます。">
          <select value={settings.language} onChange={(e) => update({ language: e.target.value as typeof settings.language })}>
            {languages.map((l) => (
              <option key={l} value={l}>
                {languageNames[l]}
              </option>
            ))}
          </select>
        </Row>
        <SecretRow runtime={runtime} account="soniox" label="Soniox の API Key" />
      </Section>

      <Section title="AI 整形">
        <Row label="AI で整形する" note="オフのときは、文字起こしをそのまま入力します。">
          <input
            type="checkbox"
            className="switch"
            checked={settings.cleanupEnabled}
            onChange={(e) => update({ cleanupEnabled: e.target.checked })}
          />
        </Row>
        <fieldset className="modes" disabled={!settings.cleanupEnabled}>
          {cleanupModes.map((mode) => (
            <label key={mode} className={mode === settings.cleanupMode ? "mode selected" : "mode"}>
              <input
                type="radio"
                name="mode"
                checked={mode === settings.cleanupMode}
                onChange={() => update({ cleanupMode: mode })}
              />
              <span>
                <strong>{cleanupModeInfo[mode].name}</strong>
                <small>{cleanupModeInfo[mode].summary}</small>
              </span>
            </label>
          ))}
        </fieldset>
        {settings.cleanupMode === "custom" && (
          <div className="row stacked">
            <label htmlFor="custom">カスタム指示</label>
            <textarea
              id="custom"
              rows={4}
              maxLength={customInstructionsLimit * 2}
              value={settings.customInstructions}
              placeholder="例: 英語に翻訳する"
              onChange={(e) => update({ customInstructions: e.target.value })}
            />
            <small className={charCount(settings.customInstructions) > customInstructionsLimit ? "over" : ""}>
              {charCount(settings.customInstructions)} / {customInstructionsLimit} 文字
            </small>
          </div>
        )}
        <Row label="プロバイダ">
          <select value={provider} onChange={(e) => update({ cleanupProvider: e.target.value as typeof provider })}>
            {cleanupProviderKinds.map((kind) => (
              <option key={kind} value={kind}>
                {cleanupProviderInfo[kind].name}
              </option>
            ))}
          </select>
        </Row>
        <SecretRow
          runtime={runtime}
          account={secretAccount(provider)}
          label={`${cleanupProviderInfo[provider].name} の API Key`}
        />
        {provider === "openai-compatible" && (
          <Row label="ベース URL">
            <input
              type="url"
              value={settings.openAIBaseURL}
              placeholder={openAIDefaultBaseURL}
              onChange={(e) => update({ openAIBaseURL: e.target.value })}
            />
          </Row>
        )}
        <Row label="モデル" note={provider === "openai-compatible" ? "OpenAI 互換ではモデルの指定が必要です。" : undefined}>
          <input
            type="text"
            value={settings.cleanupModels[provider]}
            placeholder={cleanupProviderInfo[provider].defaultModel || "モデル ID"}
            onChange={(e) => update({ cleanupModels: { ...settings.cleanupModels, [provider]: e.target.value } })}
          />
        </Row>
      </Section>

      <Section title="最近の入力">
        {runtime.history.length === 0 ? (
          <p className="empty">まだありません。HibiVo を終了すると消えます。</p>
        ) : (
          <ul className="history">
            {runtime.history.map((record) => (
              <HistoryItem key={record.timestamp} record={record} />
            ))}
          </ul>
        )}
      </Section>
    </main>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h2>{title}</h2>
      <div className="card">{children}</div>
    </section>
  );
}

function Row({ label, note, children }: { label: string; note?: string; children: ReactNode }) {
  return (
    <div className="row">
      <div className="label">
        <span>{label}</span>
        {note && <small>{note}</small>}
      </div>
      <div className="control">{children}</div>
    </div>
  );
}

function SecretRow({ runtime, account, label }: { runtime: AppRuntime; account: SecretAccount; label: string }) {
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);
  const saved = runtime.hasSecret(account);
  const save = async (next: string) => {
    try {
      await runtime.saveSecret(account, next);
      setValue("");
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  };
  return (
    <Row label={label} note={error ?? (saved ? "保存済み（Windows の資格情報マネージャー）" : "未設定")}>
      <form
        className="secret"
        onSubmit={(e) => {
          e.preventDefault();
          if (value.trim()) void save(value);
        }}
      >
        <input
          type="password"
          autoComplete="off"
          spellCheck={false}
          value={value}
          placeholder={saved ? "••••••••" : "API Key を入力"}
          onChange={(e) => setValue(e.target.value)}
        />
        <button type="submit" disabled={!value.trim()}>
          保存
        </button>
        {saved && (
          <button type="button" className="secondary" onClick={() => void save("")}>
            削除
          </button>
        )}
      </form>
    </Row>
  );
}

const statusLabels: Record<HistoryRecord["status"], string> = {
  pasted: "入力済み",
  pastedRaw: "整形せずに入力",
  copiedOnly: "コピーのみ",
  failed: "失敗",
};

function HistoryItem({ record }: { record: HistoryRecord }) {
  const text = record.cleanedTranscript ?? record.rawTranscript;
  const time = new Date(record.timestamp).toLocaleTimeString("ja-JP", { hour: "2-digit", minute: "2-digit" });
  return (
    <li>
      <div className="meta">
        <span>{time}</span>
        {record.appName && <span>{record.appName}</span>}
        <span className={record.status === "failed" ? "status failed" : "status"}>{statusLabels[record.status]}</span>
      </div>
      <p>{text || record.errorMessage}</p>
      {text && (
        <button type="button" className="secondary small" onClick={() => void navigator.clipboard.writeText(text)}>
          コピー
        </button>
      )}
    </li>
  );
}
