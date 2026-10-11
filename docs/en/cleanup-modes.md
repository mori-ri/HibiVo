English | [日本語](../cleanup-modes.md)

# AI Cleanup modes

HibiVo cleans up the transcribed text with an LLM before entering it. You choose how it is cleaned up from five modes.

> The cleanup rules are written for Japanese speech. The examples below are Japanese, with English glosses. For English speech, Raw or Custom (with your own instructions) works best.

Choose a mode under "Default Mode" in Main Window › AI Cleanup. Each mode has a description, and a sample output for the selected mode is shown below it (except Custom). You can also switch modes from "Cleanup Mode" in the menu bar.

## Modes at a glance

| Mode | Good for | Fillers and restarts | Tone | Line breaks and lists |
|---|---|---|---|---|
| **Raw** (as spoken) | Keeping exactly what you said (no LLM) | Kept | Unchanged | Unchanged |
| **Natural** (natural text) | Everyday writing such as chat and notes | Removed | Unchanged | Breaks where the topic changes |
| **Business** (polite text) | Email, chat with people outside your company | Removed | Polite Japanese (です・ます with honorifics) | One sentence per line; greeting and closing in separate paragraphs |
| **Prompt** (instructions for AI) | Instructions for Claude Code, ChatGPT, Cursor, and so on | Removed | Unchanged | Bullets only for items you listed |
| **Custom** (your instructions) | Your own style that none of the above fits | Removed | Per your instructions | Per your instructions |

## Comparing the same utterance

Here is one utterance cleaned up with Raw, Natural, Business, and Prompt. Actual output varies slightly with what you say and the model you use.

> **What was said**
> えーと昨日送ったデザイン案なんだけど、ボタンの色を、あ、いや、見出しの色をもうちょっと明るくして、あと余白も広げてほしい。で金曜までにできるか教えて
>
> *(Gloss: "Um, about the design draft I sent yesterday, make the button color, oh, no, the heading color a bit brighter, and also widen the margins. And let me know if you can do it by Friday.")*

**Raw**

```text
えーと昨日送ったデザイン案なんだけど、ボタンの色を、あ、いや、見出しの色をもうちょっと明るくして、あと余白も広げてほしい。で金曜までにできるか教えて
```

The transcript is entered as is. The filler "えーと" (um) and the restart ("ボタンの色を、あ、いや" — "the button color, oh, no") remain.

**Natural**

```text
昨日送ったデザイン案なんだけど、見出しの色をもうちょっと明るくして、余白も広げてほしい。
金曜までにできるか教えて。
```

Fillers are removed, and for the restart the final wording ("見出しの色", the heading color) is used. Casual endings such as "なんだけど" and "教えて" are kept.

**Business**

```text
昨日お送りしたデザイン案ですが、見出しの色をもう少し明るくして、余白も広げていただきたいです。
金曜までにできるか教えていただけますか。
```

Rewritten in polite language ("送った" → "お送りした", "教えて" → "教えていただけますか"). Greetings you did not say (such as "お世話になっております") are not added.

**Prompt**

```text
昨日送ったデザイン案なんだけど、
- 見出しの色をもうちょっと明るくする
- 余白を広げる
をしてほしい。
金曜までにできるか教えて。
```

The items you listed become bullets. Endings are not rewritten as "〜してください" (please do …), and no conditions or steps you did not say are added.

Custom output depends on what you write, so no example is shown. See [Custom](#custom).

## Common to every mode except Raw

Every mode except Raw always does the following:

- Removes fillers such as "えー", "あの", and "えっと"
- For restarts, uses what you said last ("明日の、いや明後日の" — "tomorrow's, no, the day after's" → "明後日の")
- Removes unneeded repetition and adds punctuation

It also follows these rules:

- Does not change your intent, facts, numbers, or proper nouns, and does not add anything you did not say
- Even if what you said is a question or a request, it does not answer it; only the cleaned-up text is entered
- Fixes obvious recognition errors from context ("アップシンク" → "AppSync", and so on)
- Writes product names, technical terms, and abbreviations in their official Latin spelling (AWS, Claude Code, API, and so on)
- Uses Arabic numerals, and writes URLs and email addresses exactly
- Uses the spellings of words registered in the [Dictionary](dictionary.md)
- Matches the format of the app you are entering text into

## Each mode in detail

### Raw

Enters the recognition result as is, without an LLM. Punctuation is only what speech recognition added, and recognition errors are not fixed. Replacements from the [Dictionary](dictionary.md) are still applied.

This behaves the same as turning AI Cleanup off (AI Cleanup › "Clean Up Text with AI"). To stop cleanup only in certain apps, set those apps to Raw in App Modes. Because no LLM is called, there is no cleanup cost and no waiting for cleanup.

### Natural

Makes the text easy to read while keeping your tone (です・ます, だ・である, or casual speech). Wording is changed as little as possible; only fillers and restarts are removed. If in doubt, use this mode.

### Business

Produces polite text you can send outside your company.

- Uses です・ます, humble forms (謙譲語) for your own actions and respectful forms (尊敬語) for the other party's ("聞いた" → "伺った", "見ました" → "拝見しました", "もらえますか" → "いただけますか")
- Avoids overusing "させていただく" and double honorifics such as "おっしゃられる"
- Apart from rewording for politeness, keeps your wording and word order
- Does not add set phrases such as "お世話になっております" unless you said them
- Puts each sentence on its own line, with the greeting and closing as separate paragraphs

### Prompt

Shapes the text as instructions for an AI, so the goal, target, conditions, and expected result come across.

- Keeps the order in which you spoke; does not reorder sentences or add headings
- Does not change endings (does not rewrite "〜したい" or "〜して" as "〜してください")
- Uses bullets only when you listed several items
- Keeps file names, commands, and code as is
- Does not add requirements, constraints, or steps you did not say

### Custom

Follows the instructions you write with "Edit Instructions…" under Custom in AI Cleanup › "Default Mode". Instructions can be up to **500 characters**.

- Basic cleanup such as removing fillers happens even if your instructions do not mention it
- Instructions that conflict with "Common to every mode except Raw" above (such as "do not add anything you did not say") are not followed
- With empty instructions, it behaves almost the same as Natural

Example instructions:

- Make a bulleted list of the key points only
- Translate into English
- Use the だ・である style throughout
- Keep sentences short and put the conclusion first

## Using different modes per app

In Main Window › App Modes you can choose the mode for each app. Apps not in the list use the "Default Mode".

On first launch, the following two are registered. You can change or remove them.

| App | Mode |
|---|---|
| Terminal | Prompt |
| Mail | Business |

The mode is decided when recording starts. Changing settings or switching apps while you speak does not affect that utterance.

## When cleanup fails

In the following cases, the recognition result is entered as is without cleanup. What you said is never lost.

- No API key is set
- The LLM returned an error, or did not respond in time (5 s, extended by 1 s per 50 characters for long text, up to 30 s)
- The output was far longer or shorter than the original utterance (for example, when the model answered what you said)

You can clean up a failed utterance again with "Redo Cleanup" in History. It uses the same mode (or the default mode if it was Raw).
