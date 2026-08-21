# at-at

Type `@@` in any text field on your Mac, get a floating prompt box, type a question, and the answer from your own Claude Code CLI is pasted right back where you were. A screenshot of what you were looking at is attached automatically.

A free, open-source take on [atatapp.com](https://atatapp.com) built with [Hammerspoon](https://www.hammerspoon.org/) and `claude -p`. No API keys — it uses your existing Claude Code login.

## How it works

```
type @@ anywhere
      │
      ▼
eventtap detects "@@" (swallows 2nd @, removes the 1st)
      │
      ├── screencapture -l <focused window id>   → ~/.cache/atat/shot-*.png
      │
      └── floating panel opens (textarea + model picker)
                │  type prompt, ⌘⏎ to send
                ▼
      claude -p "<prompt>" --model <pick> \
        --append-system-prompt "Return ONLY the text to insert..." \
        --allowedTools Read --add-dir ~/.cache/atat
                │
                ▼
      focus returns to your app → clipboard paste → old clipboard restored
```

## Install

```bash
git clone https://github.com/Alnamkani/atat.git
cd atat
./install.sh
```

`install.sh` symlinks `atat.lua` into `~/.hammerspoon/` and adds a single guarded `require("atat")` line to your `init.lua`. It never touches anything else in your config.

Then click the Hammerspoon menu bar icon → **Reload Config**.

### Permissions (macOS will prompt)

| Permission | Why | Where |
|---|---|---|
| Accessibility | keystroke detection + pasting results | System Settings → Privacy & Security → Accessibility |
| Screen Recording | so screenshots contain window content, not just wallpaper | System Settings → Privacy & Security → Screen Recording |

## Usage

- Type `@@` in any text field — panel opens, screenshot already taken
- Type your prompt, **⌘⏎** sends, **Esc** cancels
- **⌘P** cycles model (Haiku → Sonnet → Opus); last pick is remembered
- **⌥⇧A** toggles the whole thing off/on without unloading Hammerspoon

## Configuration

Everything lives in the `M.config` block at the top of `atat.lua`:

- `models` — the dropdown list; aliases like `"haiku"`, `"sonnet"`, `"opus"` or exact IDs (`"claude-opus-4-5"`)
- `cacheDir` — where screenshots go (also passed via `--add-dir`)
- `formatRule` — the system prompt that keeps output clean for insertion
- `pasteDelayMs` / `restoreDelayMs` — timing knobs for the paste + clipboard restore dance

Set `M.screenshotEnabled = false` in the file to run text-only.

## Known limitations

- **Slack / Notion / Linear:** the first `@` opens their mention popup; our cleanup backspace closes it. Harmless but visible.
- **Focus flicker:** the panel briefly takes focus, then hands it back before pasting. Cosmetic tradeoff for reliability.
- **Clipboard restore** happens on a fixed timer after paste; on a very slow/busy target app the restore can theoretically win the race.
- **Terminals** that ignore synthetic ⌘V will not receive the paste.

## Troubleshooting

- **Panel never appears** — check Accessibility permission, then reload config.
- **Screenshots are all wallpaper** — grant Screen Recording, reload.
- **`claude binary not found`** — symlink or copy `claude` into `/opt/homebrew/bin/`, `~/.local/bin/`, or `/usr/local/bin/`.
- **First answer takes a few seconds** — that's `claude -p` cold start; subsequent runs are faster.

## License

MIT
