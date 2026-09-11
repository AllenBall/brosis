# brosis

[简体中文](README.zh-CN.md) · **English**

**A local activity recorder for macOS.** It records which app and window you were in and what was on the screen, turns that into a searchable timeline and ledger, keeps it encrypted on your own machine, and exposes it to AI assistants over MCP.

What sets it apart, in one line: **your data never leaves the machine, and the understanding layer does not depend on a large model.** The timeline, time accounting and activity patterns are produced by deterministic rules — brosis is fully useful with no model installed at all. Vector search is an optional second layer, and that model runs locally too.

```
what you see on screen  →  encrypted local database  →  MCP  →  your AI assistant
                           (never sent anywhere)
```

---

## Contents

- [What it does](#what-it-does)
- [Four hard constraints](#four-hard-constraints)
- [Install](#install)
- [Using it](#using-it)
- [Connecting an AI assistant (MCP)](#connecting-an-ai-assistant-mcp)
- [Privacy and your data](#privacy-and-your-data)
- [Development](#development)
- [Architecture](#architecture)
- [References](#references)
- [License](#license)

---

## What it does

**Record.** App switches, window titles, URLs, file paths, and the text actually visible on screen. Text is read through the macOS accessibility (AX) API where possible; apps that expose nothing that way (Electron, custom-drawn UIs) fall back to OCR of the viewport. Only what is **actually visible right now** is recorded — brosis does not scroll back to collect history you never looked at.

**Organize.** Scattered observations are merged into sessions, then into daily and weekly ledgers, time totals and activity patterns. This layer is pure rules: reproducible, explainable, zero model calls.

**Search.** Three channels are fused: exact fields (app, URL, path), full-text search (SQLite FTS5, with bigram tokenization for Chinese), and optional vector semantic search. Fusion is weighted RRF.

**Hand it to an AI assistant.** A built-in MCP server exposes 10 read-only tools: `search`, `get_evidence`, `get_context`, `get_timeline`, `get_day_ledger`, `get_week_ledger`, `get_patterns`, `get_item`, `recent_activity`, `list_activity`. Every time-bound tool takes the same `period` argument (`today`, `yesterday`, `2026-09-08..2026-09-10`, `2026-W37`, `24h` …), resolved in the server's time zone, and every result echoes the exact window it used plus the server's `serverToday`.

## Four hard constraints

These are design premises, not settings:

1. **Nothing leaves the machine by default.** No cloud, no account, no telemetry. The app never goes online on its own — `SUEnableAutomaticChecks` is off, so it does not even show the "check for updates automatically?" consent dialog. Exactly two things touch the network, and both need a click from you: "Check for Updates…" in the menu, and downloading an embedding model in the models panel.
2. **Redaction happens before storage.** Passwords, verification codes, tokens and keys are replaced **before the row is written** — the plaintext was never in the database to begin with. Titles and URLs go through the same redaction (a verification code in an email subject, an `access_token` in a query string).
3. **Storage is capped.** Everyday use adds **roughly 30 MB per day** (text and its full-text index are about 80% of that; heavy use or an active vector index adds more). The default cap is 10 GiB, measured as **raw text payload** — the FTS index, vectors and WAL are excluded, so the files on disk are larger than that number. At the limit brosis offers an encrypted export first and only deletes the oldest text after you confirm. Adjustable in Settings, and current usage is shown there.
4. **The app is self-contained.** Every dependency is statically linked into the bundle. No reliance on a build directory, no Homebrew, no background daemon installed anywhere.

On top of that, password managers, keychain access, authenticators, brokerage and banking apps are **excluded by default** (a built-in list of 25 bundle ids), as are browser private windows.

## Install

macOS 26 or later, Apple Silicon.

Download the DMG from [Releases](https://github.com/AllenBall/brosis/releases) and drag it into Applications. The app is Developer ID signed and notarized by Apple, so no Gatekeeper workaround is needed on first launch.

First run walks you through two permissions:

| Permission | Why | If you decline |
|---|---|---|
| Accessibility | Read window titles and text | Only app switches are recorded, with no content |
| Screen Recording | OCR fallback when AX yields nothing | Electron and custom-drawn apps have no text |
| Automation (optional) | Ask the browser for the current tab's URL and title when AX cannot provide them | Some browser cases lack a URL; everything else is unaffected |

brosis lives in the menu bar (no Dock icon). Updates use Sparkle, and a signature that fails to verify causes the update to be **refused**, never installed anyway.

## Using it

From the menu bar icon:

**App capture list** — one row per app, three modes:

| Mode | What is recorded |
|---|---|
| Do not capture | Nothing |
| Events only | App switches and window titles, no text |
| Events + content | Everything (default) |

Each row also shows the last 7 days of observation counts and a completeness breakdown (complete / partial / unavailable / excluded), so you can judge which apps are worth keeping. "Unavailable" is broken down further into **no text** (the app exposes nothing — needs OCR), **timeout**, and **blocked** (permissions, secure input, screen locked). Those three call for completely different fixes.

**Models** — manage the embedding model used for vector search. Download from Hugging Face, import from a local folder, or link an external folder (an LM Studio model directory, for instance — the path is remembered, nothing is copied). Qwen3-Embedding is supported at 0.6B / 4B / 8B, switchable at any time.

**Settings** — interface language, disk limit, auto-clean, fallback screenshot interval, strict screen lock, vector search toggle, auto-index and its interval, daily GPU budget.

**Encrypted export** — export to an encrypted archive for backup or migration to another machine.

**Cross-device sync** — optional, through your own iCloud Drive (`iCloud Drive/brosis-sync/`). What syncs is encrypted content; the key never enters the sync folder.

Global hotkeys: `⌃⌥⌘P` pause / resume capture, `⌃⌥⌘L` lock the database.

### Interface language

Settings → Language. Chinese and English, defaulting to **follow the system**: a Chinese system gets Chinese, everything else gets English. Changing it closes any open windows so they reopen in the new language; no restart is needed.

Self-check output and command-line tools stay in Chinese by design — they are debugging surfaces, and translating them would only make logs stop matching the notes that explain them.

### When it does not capture

- Screen locked, screensaver, sleep
- Secure input detected (the system is collecting a password)
- Browser private windows (the event is still recorded; text, title and URL are not stored at all)
- While you have it paused

Capture itself **ignores power state** — it keeps recording on battery. The AC-power gate applies only to GPU-heavy work such as index building (which pauses when unplugged and resumes when you plug back in).

## Connecting an AI assistant (MCP)

**This is automatic by default.** brosis checks every 30 minutes for harnesses you have installed — Claude Code, Codex CLI, Cursor, Grok CLI, ZCode, Kimi Code — writes each one's user-level config and issues it a grant. Harnesses you do not have installed are left alone: no directories are created for software you never installed. Turn the whole thing off with the checkbox in Menu bar → "MCP integration", and wire up individual harnesses by hand there instead.

**Turning one off by hand sticks.** Disabling a harness in that window records the choice, and auto-integration will never re-enable it. Turning the global checkbox off does *not* remove integrations that already exist — remove those one row at a time.

Each harness's official CLI is preferred; only when the CLI is unavailable does brosis edit the config file directly (backing it up first, replacing atomically, and refusing to write — with a snippet for you to paste — if the file cannot be parsed).

Manual setup works too:

```bash
claude mcp add brosis /Applications/brosis.app/Contents/MacOS/brosis-mcp
```

**The grant is the real gate.** An entry in a config file only means a client *can connect*. Whether it can read anything is decided by the `grants` table in the database, and a client with no grant is **refused on every tool**. A grant can restrict which apps are visible, over what time window, and at what field granularity (summary only, or full evidence):

```bash
brosis-mcp admin grant add --client claude-code --fields evidence
brosis-mcp admin grant list
brosis-mcp admin audit --limit 20     # who read what (never the content itself)
```

Grants are issued per client id, and a client picks its own name when it connects — so the name has to match or everything is refused. Every config brosis writes itself therefore pins `BROSIS_CLIENT_ID` to the harness's id, which makes the name match by construction rather than by luck.

For the cases that fall outside that — a config you wrote by hand, or an entry added through a harness's own CLI — the MCP integration window has a **learn mode**: turn it on for 60 seconds and any refused connection surfaces the name it claimed, for you to confirm. It is a 60-second, manually started poll, not a background watcher.

The command line works as well:

```bash
brosis --mcp list                          # config and grant status per harness
brosis --mcp enable --harness claude-code
brosis --mcp auto                          # is auto-integration on, and what is opted out
brosis --mcp auto --set off
```

## Privacy and your data

The database is encrypted with SQLCipher and the key lives in the **data-protection keychain** — which is unreadable while the screen is locked. A freshly installed app therefore cannot open the database on a locked screen; it retries automatically once you unlock. An already-running process keeps the key in memory and is unaffected by locking.

Everything lives in `~/Library/Application Support/brosis/`. Deleting that folder is a complete deletion — there is no copy anywhere else.

Deleting a single record, an entire app's data, or a time range cascades through the full-text and vector indexes, leaving no orphaned rows.

**Reading your data on another machine requires both the database file and the key from the keychain.** Copying the database file alone gets you nothing.

## Development

Requires Xcode 26 (including the Metal Toolchain, used to compile mlx's shader library). The repository is two independent SwiftPM packages.

```bash
# Storage core: encrypted database, search, ledgers, MCP service
swift test --package-path core

# Full app: build + sign + pre-notarization checks + release gate
bash app/build_app.sh
```

After signing, `build_app.sh` **temporarily renames the build directory** and runs the self-check and embedding self-test again. That gate is what guarantees the app is genuinely self-contained — a bundle that only worked because the build directory happened to be there cannot pass. All build products land in `~/Library/Caches/brosis-build/`, never in the project directory.

If `xcode-select` points at the Command Line Tools (which have no `metal` compiler), the script switches to Xcode for that build without touching your global setting.

### Repository layout

| Directory | Contents |
|---|---|
| `app/` | Menu bar app: event skeleton, AX and adapter rules, OCR, model management, windows, MCP integration |
| `core/` | Encrypted storage core: SQLCipher, schema and migrations, writes / deletes / quota, search, ledgers, sync, MCP service, the `brosis-store` CLI |
| `tools/eval/` | Retrieval evaluation pipeline: synthetic corpus, query sets, FTS-only vs. hybrid comparison, threshold sweeps |
| `tools/bench/` | OCR benchmarks, FTS tokenizer comparison, runtime benchmarks |
| `tools/proto/` | Schema prototype, synthetic data generation, correctness and capacity measurement |
| `dist/` | DMG packaging, notarization, appcast generation |

### Diagnostic tools

```bash
brosis --self-check     # 202 assertions covering every hard constraint and key decision
brosis --ax-probe       # measure whether an Electron app's AX tree actually yields text
brosis --dump-ocr       # OCR results, line by line, for manual checking
```

`--ax-probe` earns its keep when an app appears to have no readable text: it prints the role distribution, walks down from each `AXWebArea` level by level, and sweeps the two usual suspects (traversal depth and viewport clipping) — all along the exact same code path production uses.
Add `--dump-webarea [<AXTitle>|all]` (e.g. `brosis --ax-probe com.bytedance.macos.feishu --dump-webarea messenger-chat`) to list every `AXWebArea` in each window of the target app and print the chosen subtree node by node (role, DOM id / class, title, first 60 chars of text, frame, selection state) — the raw material for an adapter rule's locators. The output contains real on-screen text; keep it out of any directory that gets committed.

### Tests vs. self-check

- `swift test --package-path core` — unit and end-to-end tests for the storage core
- `brosis --self-check` — 202 assertions that run inside the real app bundle; the build gate requires them all to pass

The self-check deliberately asserts **relationships rather than literals** (for example, "the key Settings reads == the constant the feature itself owns", not "the default == 12.0"). Hard-coded literals are precisely what fails to catch a real drift when the owning side changes.

## Architecture

```
Capture       AX adapter rules → viewport OCR fallback → redaction before storage
  ↓
Storage       SQLCipher + FTS5 (bigram for Chinese) + sqlite-vec (int8[1024], cosine)
  ↓
Understand    sessionization → daily / weekly ledgers → activity patterns   ← rules only, no model
  ↓
Search        exact fields ∪ FTS ∪ vectors  →  weighted RRF fusion
  ↓
Egress        MCP (9 read-only tools, gated by grants)
```

**Adapter rules.** App UIs differ enough that each gets its own rule: Safari, Claude desktop, Feishu/Lark and WeChat have dedicated rules; everything else uses a generic one. A rule describes where the text lives, how to read it, and what to fall back to when that fails.

Electron apps need `AXManualAccessibility` set before they expose an accessibility tree at all. A single window often contains several `AXWebArea` nodes — the shell, the actual app, an embedded preview — and the one with the most content must be chosen rather than the first. Chromium builds the tree asynchronously, so an empty read is retried a moment later.

**Chromium-based browsers** (Chrome, Edge, Brave, Vivaldi, Arc) honor only the private `AXEnhancedUserInterface`, not the public `AXManualAccessibility`. Measured on Chrome 153, the accessibility tree is 43 nodes of browser shell with **no `AXWebArea`** at all. The default path is therefore: OCR the page viewport, and read the URL straight from the address bar's `AXTextField` — neither needs an extension. Screenshots are window-directed, so another window sitting on top of the browser never has its pixels recorded as page content.

**`AXEnhancedUserInterface` is on by default and can be turned off.** With it on, Chrome, Feishu and Feishu Meetings all build a real accessibility tree, and body text is read from the DOM (character-exact, includes content scrolled out of view, and skips OCR entirely), falling back to OCR when the read comes back empty. Measured: Chrome goes from "43 nodes of shell, zero body text" to readable; Feishu reads the `messenger-chat` web area that holds the open conversation (title + messages, with "me / peer" prefixes in 1:1 chats) and excludes the conversation-list sidebar entirely; on the Docs / Mail tabs it reads that module's own web area, whose AXTitle is the page title; `ModalWebViewWidget` popups (search, forward, profile card) are recorded as title only; and whatever still goes through OCR has the tiled "name + organisation" watermark stripped first (set it explicitly with `defaults write com.brosis.app adapter.watermark.text "Name Org"` if it cannot be learned). Turn it off and both fall back to full-page OCR.

⚠️ **Know the cost before turning it on.** The attribute puts Chromium into accessibility mode where it mirrors input, and when the client that set it **disconnects abruptly** it **replays recently buffered keystrokes into the focused field** — the reproduction is typing `abcd`, quitting the client, and finding `abcdbcdbcd`, i.e. **your recent keystrokes duplicated**, not random garbage (see [screenpipe #3884](https://github.com/mediar-ai/screenpipe/issues/3884); 1Password, Alfred and TextExpander have hit the same one).

The exposure window is **the moment brosis exits** (including when it is updated), and it lands on the focused field of a Chromium app. Simply having it on does not trigger it. That is why it is off by default and why upgrading never turns it on.

```bash
defaults write com.brosis.app ax.enhancedUserInterface -bool false  # off; restart the app
defaults delete com.brosis.app ax.enhancedUserInterface             # back to the default (on)
```

**Vector search is optional.** Every model size is truncated to a uniform 1024 dimensions, so switching models only requires rebuilding vectors, never a schema change. Models run locally through mlx-swift. Index building is gated on AC power, normal thermal state, an unlocked database and a daily GPU budget. With no model installed the vector channel simply reports as off; exact fields and full-text search are unaffected.

**The schema is versioned and migrated** (currently v9), applying migrations in order and rolling back on failure.

## References

Work this project draws on directly or leans on repeatedly:

**The deterministic ledger layer**

- *Activity Frames* — [arXiv:2608.05784](https://arxiv.org/abs/2608.05784), code at [nossa-y/activity-frames](https://github.com/nossa-y/activity-frames). Deterministically compiles screen snapshots into structured "activity frames" with zero LLM calls — reproducible and explainable. brosis's sessionization and ledger layer follow this approach.

  **Read the scope along with the result.** The author is listed as an independent researcher, and the reported 98.4% QA accuracy comes from **8 days of a single user's corpus and 64 questions**, concentrated on apps, durations, rankings and domain visits — not on article content or the reasons behind decisions. The paper itself distinguishes dwell time from attention and discusses double-counting across two displays. brosis treats it as evidence for an **explainable activity ledger**, not as proof of general memory quality — a distinction taken seriously in the design: foreground dwell, active intervals with input, and unknown state are recorded separately rather than collapsed into one "time used" number.

**Why AX and OCR must both exist**

- V. Muryn, M. Sumyk, M. Hirna, S. Garkot, M. Shamrai, *Screen2AX: Vision-Based Approach for Automatic macOS Accessibility Generation*, [arXiv:2507.16704](https://arxiv.org/abs/2507.16704) (MacPaw Research). Measured that **only about 33% of macOS apps offer full accessibility support**. That number is why brosis cannot rely on the accessibility API alone — two thirds of apps would be read incompletely.

**Search**

- G. V. Cormack, C. L. A. Clarke, S. Buettcher, *Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods*, SIGIR 2009. The method for fusing results from multiple retrieval channels; brosis fuses exact fields, full text and vectors, and takes the RRF constant k=60 from this paper.

- A. Kusupati et al., *Matryoshka Representation Learning*, [arXiv:2205.13147](https://arxiv.org/abs/2205.13147). Makes the first N dimensions of an embedding usable on their own. brosis uses this to truncate the 0.6B / 4B / 8B models to a common 1024 dimensions — switching models then requires rebuilding vectors, not changing the schema.

- Qwen Team, *Qwen3 Embedding: Advancing Text Embedding and Reranking Through Foundation Models*, [arXiv:2506.05176](https://arxiv.org/abs/2506.05176). The embedding model family used here (Apache 2.0).

**Capture**

- *Perceptual hash distance distributions*, [arXiv:2212.08035](https://arxiv.org/abs/2212.08035). The frame-deduplication threshold for on-demand screenshots comes from this paper's distance distributions (mean normalized pHash distance around 0.49 for unrelated images, around 0.005 for a recompression of the same image).

Projects this leans on heavily in implementation: [SQLCipher](https://github.com/sqlcipher/sqlcipher), [sqlite-vec](https://github.com/asg017/sqlite-vec), [mlx-swift](https://github.com/ml-explore/mlx-swift), [Sparkle](https://sparkle-project.org/), [Model Context Protocol](https://modelcontextprotocol.io/).

## License

[MIT](LICENSE).

Dependencies carry their own licenses: SQLCipher (BSD-style), sqlite-vec (Apache 2.0 / MIT), mlx-swift (MIT), Sparkle (MIT), Qwen3-Embedding weights (Apache 2.0).
