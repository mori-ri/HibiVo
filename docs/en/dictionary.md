English | [日本語](../dictionary.md)

# Dictionary

When you register words in the Dictionary, HibiVo enters them with the correct spelling. Use it for words speech recognition struggles with: company names, product names, technical terms, people's names, and so on.

Open the Dictionary from Main Window › Dictionary.

## How the Dictionary works

Registered words are used in three places on the way to your text.

1. **Hints for speech recognition**: the correct spelling (and, with Soniox, the reading) is passed to speech recognition (STT) so the word is heard as that word.
2. **Replacement**: when a reading or alias of the word appears in the transcript, it is replaced with the correct spelling. This works even with AI Cleanup turned off.
3. **AI Cleanup**: the Dictionary is passed to the AI so it uses the correct spelling where the context calls for it.

The same Dictionary is used for meeting transcripts and minutes.

## Adding words manually

Fill in "Add a Word" and press "Add" (Return also works).

| Field | What to enter | Example |
|---|---|---|
| Spelling | How you want the word written | `AppSync` |
| Sounds like | How the word is read (hiragana or katakana) | `アップシンク` |
| Aliases | Other spellings it is often misrecognized as. Separate several with `,` or `、` | `アップ シンク, App Sink` |

- Hiragana and katakana, and full-width and half-width characters, are treated the same. If you register the reading "ひびぼ", "ヒビボ" and "ﾋﾋﾞﾎﾞ" are replaced too.
- A space between Latin letters and kana is optional ("AWS ラムダ" and "AWSラムダ" match alike).
- **Kana readings of two characters or fewer** ("あい" → AI, and so on) are easily confused with ordinary words, so they are not replaced automatically. The correct spelling is used only when AI Cleanup judges from context that it fits.

## Adding corrected words automatically

If you fix a misrecognized word yourself right after dictating, HibiVo notices and adds it to the Dictionary.

Example: "アップシンクの設定を確認します" (I'll check the アップシンク settings) is entered, and you change "アップシンク" to "AppSync" → "AppSync (sounds like: アップシンク)" is added to the Dictionary.

### When a word is added

A card saying the word was added to the Dictionary appears at the bottom of the screen for about 10 seconds.

- Click the card to undo the addition.
- It stays while the pointer is over it, so you can read it before deciding.
- If you missed it or want to undo it later, delete it from the Dictionary screen (see "Organizing the Dictionary" below).

### Which words are added

A word is added only when the edit looks like a fix for a recognition error. These kinds of edits are not added:

- Rewriting the text (changing the wording or content, or changing several places at once)
- Changing the meaning (changing to a word that does not sound similar, such as "明日" (tomorrow) → "今日" (today))
- Changing only numbers, punctuation, particles, or okurigana
- Changing only the script, such as hiragana vs. katakana
- Kana of two characters or fewer
- **Words other than nouns** (verbs and adjectives such as "早く" → "速く"). Nouns used as "〜する", such as "校正する", are added.

Kanji conversion errors ("構成" → "校正", and so on) are added as an "Alias", not as "Sounds like".

If you fix a spelling that is already registered, no new entry is created; the word is added to that entry's aliases. Nothing is added if it overlaps with another entry's reading or alias.

### What is watched, and for how long

After pasting, HibiVo watches only the part of the text field it entered. Watching stops when any of the following happens:

- You move to another text field or app
- The text field becomes empty
- You start the next dictation
- 45 seconds pass

### Apps that are not supported

The contents of the text field are read with macOS accessibility features. In apps whose contents cannot be read, such as Terminal, words are not added automatically. In that case you can add them from **History**.

1. In History, select the entry and press "Edit"
2. Fix the misrecognized word and press "Save"
3. Press the button for the suggestion shown under "Add to Dictionary"

### Turning it off

Turn off Dictionary › Learned Automatically › "Add words you correct after dictating" to stop adding words automatically.

## Organizing the Dictionary

Each row in the list is one word.

| What you see | Meaning |
|---|---|
| ✨ icon | Added automatically from a word you corrected |
| I-beam icon | Added manually |
| Switch at the right of the row | Turn it off to stop using the entry while keeping it |
| Pencil button (shown when hovering) | Edit the spelling, sounds like, and aliases. Double-clicking the row also opens it |
| Trash button (shown when hovering) | Delete. This cannot be undone |

- Filter with "All / Manual / Automatic / Disabled" at the top, and search by spelling or reading in the search field at the right.
- To review automatically added words, filter by "Automatic".
- Words registered before this feature existed are all shown as "Manual".
- Disabled words are not used, and the same word is not added automatically again.

## Privacy

- The Dictionary is saved to `~/Library/Application Support/HibiVo/vocabulary.json`.
- Text field contents read for automatic adding are neither saved nor sent. Only the corrected word and its original spelling are added to the Dictionary.
- The Dictionary's contents are sent to the STT provider and LLM provider you have set up, as hints for speech recognition and for AI Cleanup.
