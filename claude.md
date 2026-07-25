# Séance — independent review pass (2026-07-25)

A fresh, whole-repo review of the Séance SSH client: bugs, performance,
interface and layout, missing features, and ideas worth stealing. Written to be
merged into [ANALYSIS.md](ANALYSIS.md) once the actionable items are shipped.

Findings are numbered `SEA-nnn` to keep them distinct from the `SOL-nnn` series
of the previous analysis pass. Where a finding refines or contradicts an
existing `SOL-` item, that is called out explicitly.

---

## 1. Method and baseline

Read end-to-end: `app/seance_app/lib/**` (all 36 files), `packages/seance_core`,
`packages/seance_protocol`, `packages/seance_sync_server`, the relevant parts of
the vendored `third_party/xterm` fork, `AGENTS.md`, `docs/STATUS.md`,
`PROPOSAL.md`, `ANALYSIS.md`, and the committed `screenshot.png`.

Baseline verified on this container (Dart 3.12.2 / Flutter 3.44.8):

| Check | Result |
|---|---|
| `dart analyze` (3 packages) | clean |
| `dart test` (3 packages) | **187 passed** |
| `flutter analyze` (app) | clean |
| `flutter test` (app) | **136 passed** |

The codebase is in genuinely good shape: the seams are real, the security
invariants are load-bearing and tested, and the comments explain *why* rather
than *what*. Almost everything below is polish on a solid base — with three
exceptions (SEA-001, SEA-002, SEA-010) that are real defects.

---

## 2. Scorecard

| Area | Verdict |
|---|---|
| Correctness / crypto / sync | Strong. No new defects found in the protocol or server. |
| SSH + TOFU | Strong. Failure diagnostics are unusually good. |
| App state management | One monolithic notifier; causes a real rebuild storm on connect (SEA-001). |
| Terminal presentation | **Weakest area.** No appearance control at all; no session identity. |
| Discoverability / navigation | Weak at >10 servers; no search, no palette, few shortcuts. |
| Assistant UX | Functional but lossy on mobile (SEA-010) and visually cramped (SEA-016). |
| Robustness of local state | One silent-data-reset path (SEA-002). |
| Docs | Mostly excellent; three stale claims (SEA-030). |

---

## 3. Bugs and correctness

### SEA-001 · The whole app rebuilds once per SSH trace line while connecting
**Severity: P1 (performance defect with visible stutter).**

`AppState` constructs each session's log as
`SshConnectionLog(onUpdate: notifyListeners)`
(`app_state.dart:325`, `:424`, `:862`). `SshConnectionLog.add` calls `onUpdate`
on *every* line (`ssh_session.dart:67-74`), and dartssh2's `printTrace` fires
per packet during the handshake (`ssh_session.dart:386`). So every KEX packet
triggers `AppState.notifyListeners()`, which rebuilds the server list, the
terminal pane (and thus every mounted `TerminalView`), and the utility panel.

A handshake produces on the order of 10²–10³ trace lines, so opening a session
schedules hundreds of full-tree rebuilds in a fraction of a second. This is the
most likely source of the "stuttering on connect" the brief asks about. The log
is correctly frozen once connected (`app_state.dart:382`) — which is why the
problem disappears after connect and has gone unnoticed — but a *failing* or
slow connection never freezes, so the worst case is exactly the case where the
user is already waiting.

**Fix:** make `SshConnectionLog` its own `Listenable` and let only the widget
that displays it (`_ConnectionLogView`) rebuild. Coalesce notifications to at
most one per frame.

### SEA-002 · A corrupt `settings.json` silently resets every setting
**Severity: P1 (silent data loss).**

`SettingsStore.load` swallows any decode error and returns a default
`AppSettings()` (`app_settings.dart:228-237`). That silently discards the sync
server URL and username, the LLM provider config, editor registry, remote
bookmarks, and — worst — the **`deviceId`**. A fresh `deviceId` is not cosmetic:
it is the tiebreaker in `Lww.resolve`, so the device re-enters sync as a
stranger, and previously-written records lose their authorship for conflict
resolution. The next save then overwrites the (recoverable) file with the
defaults, making the loss permanent.

**Fix:** on decode failure, move the bad file aside (`settings.json.corrupt-<ts>`)
before writing defaults, and surface a one-time notice. Salvaging just
`deviceId`/`syncBaseUrl`/`syncUsername` from a partially-parseable document is
cheap insurance.

### SEA-003 · Reachability probes ignore servers that already have a live session
`ProbeService`'s own doc comment states that "servers with an active session are
reported online for free via keepalives and can be excluded here"
(`probe_service.dart:60-61`) — but nothing ever excludes them. `AppState.load`
passes the full server list (`app_state.dart:203`) and `probeAll` probes all of
them (`probe_service.dart:85-91`).

Consequence: every connected host gets an *extra* TCP connect + banner read
every ~45 s, on top of dartssh2's 10 s keepalives. That is pure waste, adds a
line to the remote `sshd` log every 45 s per host (exactly the fail2ban noise
the comment says it is avoiding), and costs battery/data on mobile.

### SEA-004 · Probe fan-out is unbounded
`probeAll` does `Future.wait` over every configured server
(`probe_service.dart:86`). With 30–50 imported `~/.ssh/config` hosts that is
30–50 simultaneous socket connects every sweep, each with a 5 s timeout. On
mobile radios and on hosts behind a captive VPN this is a burst that competes
with the live session. Cap concurrency (6–8) and keep the existing jitter.

### SEA-005 · `AppState.dispose()` abandons its teardown futures
```dart
for (final t in sessions) {
  _disposeSession(t);   // Future ignored
}
```
(`app_state.dart:880-882`). SSH sockets, SFTP clients, and engines are closed
fire-and-forget, and any error becomes an unhandled async error. Prefer
`unawaited(...)` with a `.catchError` or an explicit async teardown.

### SEA-006 · String truncation can split a grapheme cluster
`AppState._snippetTitle` does `firstLine.substring(0, 39)`
(`app_state.dart:645-647`) and `_shortError` does `s.substring(0, 200)`
(`app_state.dart:576-577`). Both can cut a surrogate pair in half and produce a
lone surrogate — the exact class of bug `MiddleEllipsisText` was written to
avoid (`middle_ellipsis_text.dart:49`). Reuse the grapheme-safe helper.

### SEA-007 · Repeated SSH-config import silently duplicates hosts
`AppState.importSshConfig` assigns a fresh `uuidV4()` per parsed host and stores
it unconditionally (`app_state.dart:282-295`). Importing the same file twice
yields two copies of every host, with no dedupe by `host`/`port`/`user` and no
preview. `ANALYSIS.md` already asks for import-with-preview (P1, "Daily
workflow"); this note pins the concrete cause.

### SEA-008 · The macOS terminal-focus flag is never cleared on dispose
`_SessionViewState` reports focus to the native menu through the `seance/menu`
channel on every focus change (`terminal_pane.dart:423-429`), but `dispose()`
removes the listener without sending a final `false`
(`terminal_pane.dart:411-419`). If the last terminal is torn down while focused
(closing the tab, or navigating back on narrow layouts), the native Edit menu
keeps believing a terminal is focused. The Dart handlers are null-safe, so this
degrades to "⌘C does nothing" rather than a crash — but it is a real dead-key
state. Send `false` from `dispose`.

### SEA-009 · Nothing prevents closing a tab from the keyboard bypassing the
### local-edit guard
`AppState.closeTab` calls `_disposeSession(..., deleteLocalCopies: true)`
(`app_state.dart:789`), which permanently deletes unsaved managed SFTP edits.
The only guard is the dialog in `TerminalPane._closeTab`
(`terminal_pane.dart:86-122`) — i.e. the guard lives in one call site, not in
the operation. There is no ⌘W today, so the hole is not currently reachable, but
any new call site (a shortcut, a menu item, a swipe on mobile) silently deletes
user data. **Move the guard behind the state operation, or make the destructive
variant a distinct, explicitly-named method** — this should be settled *before*
tab shortcuts land.

### SEA-010 · On mobile, closing the assistant drawer destroys the conversation
`SidebarPanel` is hosted in a `Drawer` on narrow layouts
(`terminal_pane.dart:59-63`). All chat state — `_messages` and the
`ChatController` that owns the provider history — lives in `_ChatSidebarState`
(`chat_sidebar.dart:31-41`). Closing the drawer disposes the subtree, so the
entire conversation is gone. The same happens on the desktop when the layout
crosses the 960 px breakpoint. There is no "the chat is gone" affordance; it
just silently starts empty next time.

This is the single most user-hostile behavior I found: on a phone, the assistant
is *only* reachable through the drawer, so the assistant is effectively
single-turn there.

**Fix:** hoist the conversation into a service that outlives the widget (per
active session, ideally), so the drawer becomes a view onto persistent state.

### SEA-011 · `recentText` serializes the entire scrollback to return 200 lines
```dart
final all = terminal.buffer.getText().split('\n');
```
(`xterm_engine.dart:346-350`). `Buffer.getText()` with no range materializes the
whole buffer — up to `maxLines: 10000` × terminal width — into one `String`,
which is then split into a 10 000-element `List<String>` so the last 200 can be
kept. That runs on every assistant send (`chat_sidebar.dart:97`) and every ⌘K
(`command_generator.dart:78`). At 10 000 × 200 cols that is a multi-megabyte
allocation and a visible hitch on a long-lived session.

`getText` accepts a `BufferRange`; passing a range that covers only the last N
lines makes this O(N).

### SEA-012 · Every session of every server stays fully mounted
`TerminalPane._body` builds an `IndexedStack` over `state.sessions` — *all*
sessions, across all servers (`terminal_pane.dart:171-192`). The instant-switch
rationale in the doc comment is sound, but the cost scales with total open tabs,
not with tabs of the visible server: each mounted `TerminalView` keeps a render
object, a paragraph cache, and participates in every layout pass; each also
forwards a PTY resize to its remote host whenever the window is resized. For a
handful of tabs this is fine; the design has no ceiling. Consider mounting
eagerly only the active server's tabs (plus the last-active of others), or an
LRU cap.

---

## 4. Interface, layout, and visual issues

### SEA-013 · The terminal has no appearance settings at all
**The biggest single gap in the product.** `TerminalView` is constructed with no
`textStyle:` and no `theme:` (`terminal_pane.dart:447-461`), so every session
renders at xterm's defaults: **13 px**, family `monospace`, and
`TerminalThemes.defaultTheme` — a hardcoded dark VS Code palette
(`third_party/xterm/lib/src/ui/themes.dart:5-29`).

Consequences:
- No font size control, and no zoom shortcuts (⌘+ / ⌘− / ⌘0). On a 4K display
  13 px is unreadable; on a phone it is too large for 80 columns.
- `SeanceTheme.monoFallback` (`theme.dart:24-31`) — a carefully chosen stack of
  JetBrains Mono / SF Mono / Menlo / Consolas — **is dead code**. Nothing
  references it. The terminal uses xterm's stack instead.
- In light mode the app chrome is light and the terminal is `#1E1E1E`. That may
  be a defensible default, but it should be a *choice*.
- The theme is not derived from, and cannot be matched to, the app's violet
  seed — so the product's own visual identity stops at the terminal edge.

### SEA-014 · A session has no identity anywhere on screen
Tabs are labelled `'Session ${i + 1}'` with the comment "no OSC title yet"
(`terminal_pane.dart:232-240`) — but `XtermTerminalEngine` **already tracks**
`terminalTitle` (OSC 0/2) and `workingDirectory` (OSC 7) as `ValueNotifier`s
(`xterm_engine.dart:76-80`), and `shellIntegration` even carries the last exit
code (`xterm_engine.dart:84-85`). None of it is surfaced outside the Files pane.

In the wide layout the terminal pane has **no app bar at all**
(`adaptive_shell.dart:47`), so with one tab open the only indication of *which
machine you are typing into* is the selected row in the server list. Combined
with a shell prompt that may be `$`, this is a real "wrong window" hazard — the
kind that ends with a command run on production.

### SEA-015 · The layout collapses to the phone UI below 960 px
`AdaptiveShell.breakpoint` = 200 + 480 + 260 + 2×10 = **960 px**
(`adaptive_shell.dart:25-29`). Below that, all three panes collapse to
single-screen navigation. A half-screen window on a 13" laptop (≈720 px) or an
iPad in split view therefore gets the phone experience, losing the server list
*and* the tiled utility panel simultaneously. A two-stage response would be far
better: first drop the utility pane to a drawer (keeping list + terminal tiled
down to ~700 px), then collapse fully.

### SEA-016 · Chat bubbles are pinned to 300 px in a pane up to 680 px wide
`constraints: const BoxConstraints(maxWidth: 300)` (`chat_sidebar.dart:254`)
while the utility pane can be dragged to `maximumUtilityWidth = 680`
(`adaptive_shell.dart:23`). Widening the assistant does nothing but add
whitespace. Bubbles should be a fraction of the available width
(`LayoutBuilder`, ~85%).

### SEA-017 · Assistant replies are unformatted plain text
`SelectableText(m.text)` (`chat_sidebar.dart:264`). Model answers routinely come
back with fenced code, lists, and inline code; all of it renders as a wall of
proportional text with no copy affordance per block. `ANALYSIS.md` lists
Markdown rendering as P1 — still entirely open.

### SEA-018 · Pane widths, active host, and utility tab are not remembered
`_AdaptivePaneLayoutState` initialises to the constants on every launch
(`adaptive_shell.dart:185-188`). Same for the sidebar's selected tab and the
last active server. (`ANALYSIS.md` P2 "Remember last active host, utility tab,
pane ratios" — confirmed still open.)

### SEA-019 · Status colors are hardcoded and theme-blind
`StatusColors.online/offline/unknown` take a `BuildContext` and ignore it,
returning fixed GitHub-dark hexes (`theme.dart:35-39`). On a light surface
`#3FB950` on white is ~2.1:1 contrast — below WCAG's 3:1 for non-text
indicators. The signature is already right; the implementation just needs to
consult the theme brightness.

### SEA-020 · Touch targets on the tab strip are below the platform minimum
The tab close button is `iconSize: 15` inside `minWidth/minHeight: 28`
(`terminal_pane.dart:322-330`); the strip itself is 38 px tall. Material and
HIG both want ≥44–48 px for touch. The strip is shown on touch platforms too.

### SEA-021 · Two similar dots per server row read as one broken indicator
`_ServerTile` shows a filled 12 px connection dot on the left and a 10 px
outlined reachability dot on the right (`server_list_pane.dart:344-368`). Both
are grey when idle. The distinction is documented and intentional, but visually
it reads as a bug ("why are there two dots and why is one hollow?"). A single
composed indicator — filled = session, ring = reachability — would say the same
thing in one glyph.

### SEA-022 · Long-running work has no completion feedback
Nothing surfaces when a command finishes while you are in another tab or app,
even though OSC 133 `D` with an exit status is already parsed
(`xterm_engine.dart:177-188`). See SEA-031.

---

## 5. Missing features

Ordered by how often a daily SSH user would reach for them.

### SEA-023 · No scrollback search (⌘F / Ctrl+Shift+F)
The most conspicuous missing terminal feature. The vendored fork already carries
`searchHitBackground` / `searchHitForeground` / `searchHitBackgroundCurrent` in
`TerminalTheme` (`third_party/xterm/lib/src/ui/themes.dart`), so the render path
has a slot for hit highlighting — but no search controller, no UI, and no
`grep`-the-buffer path exists. Non-trivial (needs viewport control in the fork),
which is why it is *documented, not implemented*, in this pass.

### SEA-024 · No server search / filter / palette
`SnippetsPane` grows a filter box past four items (`snippets_pane.dart:70-92`),
which is exactly right — and `ServerListPane` has nothing equivalent
(`server_list_pane.dart:70-105`), despite being the list most likely to hold 40
imported hosts. Type-to-filter is the cheap 80% of the "Planchette" palette
already proposed in `ANALYSIS.md`.

### SEA-025 · Almost no keyboard shortcuts
`AppMenus` binds exactly two: new tab and settings (`app_menus.dart:100-111`).
Missing, in rough priority order: close tab (⌘W / Ctrl+Shift+W), select tab
1–9 (⌘1…⌘9), cycle tabs (Ctrl+Tab, ⌘⇧[ / ⌘⇧]), focus the server filter (⌘L or
⌘P), clear terminal (⌘K is taken by the generator — use ⌘⇧K), zoom (⌘+/−/0).
Note the constraint that makes this subtle: the terminal handles most `Ctrl`
chords itself and returns `handled` (`third_party/xterm/lib/src/terminal_view.dart:456-493`),
so app-level bindings must use ⌘ on Apple and `Ctrl+Shift` elsewhere — the
pattern `_handleKeyEvent` already establishes (`terminal_pane.dart:471-509`).

### SEA-026 · No auto-reconnect and no session restore
A dropped connection leaves a "Disconnected" placeholder with a manual Reconnect
button (`terminal_pane.dart:589-621`). For a mobile client that changes network
constantly, an opt-in reconnect-with-backoff (and a "reopen my tabs at launch"
option) is the difference between usable and irritating. Note that the app
*already* restores placeholder tabs — but only for durable file edits
(`app_state.dart:844-871`), so the mechanism exists.

### SEA-027 · SSH config import is paste-only
The tooltip says "Import ~/.ssh/config" but the dialog can only accept pasted
text (`server_list_pane.dart:161-199`) — on desktop, where the file is readable
and the app already has a native file-picker + security-scoped bookmark path for
identity files (`identity_bookmarks.dart`). Add a Browse… button; reuse the
existing bookmark plumbing.

### SEA-028 · No "copy last command output"
With OSC 133 marks already parsed, `Copy last output` / `Copy last command` /
`Rerun` are a short step away and are the actions people actually want.
(`ANALYSIS.md` proposes the full command-block treatment; this is the minimum
viable slice.)

### SEA-029 · Still open from the previous pass (confirmed, not re-derived)
ssh-agent auth (`ssh_session.dart:314-322` still throws), port forwarding,
ProxyJump execution, splits, Mosh, provider-native web search, streaming
assistant replies (`streamChat` exists in the providers and is unused by the
sidebar), OSC 133 command-block context for the LLM.

### SEA-030 · Documentation is stale in three places
- `docs/STATUS.md:74-76` lists "Honor the redaction toggle" as an open next
  step. It is **done**: `chat_sidebar.dart:62-63` and `command_generator.dart:74-75`
  both construct `SecretRedactor(enabled: settings.redactionEnabled)`.
- `docs/STATUS.md:15` says the tab strip "appears only at 2+ tabs, so a single
  session looks title-bar-less as before". The code shows it whenever a session
  is active (`terminal_pane.dart:68-76`) — it now doubles as the toolbar.
- `AGENTS.md:353` names `claude/ssh-client-design-proposal-esejrg` as the
  development branch; work has long since moved on.

---

## 6. Delightful, novel, and quirky ideas

Deliberately *not* repeating the previous pass's list (spirit sigils, Safe Draft
Dock, the Planchette, production wards, last words, presence/heartbeat, mobile
key decks, context ledger, visual identity) — all of those remain good. New
ones:

### SEA-031 · "The spirit answered" — completion notices
When an OSC 133 `D` arrives for a session that is **not** on screen, pulse that
tab and (optionally) post an OS notification with the command, its exit code,
and how long it took. Everything needed is already parsed
(`xterm_engine.dart:177-188`). Long `apt upgrade` on a background tab is the
canonical use case; the séance framing ("the machine has finished speaking")
writes itself.

### SEA-032 · Ghost tabs — undo close
A closed tab leaves a translucent chip in the strip for ~10 s. Clicking it
reopens a session on the same host and, when shell integration is present,
`cd`s back to the last known `workingDirectory`. Cheap, and it defuses SEA-009's
destructive-close problem for the common "wrong tab" mistake.

### SEA-033 · Host hues — one deterministic color per machine
Hash the host key fingerprint (already the canonical identity, per
`AGENTS.md §6`) into a hue, and use it for the tab underline, the status bar
edge, and the server row accent. Unlike the proposed "production wards" (which
require the user to tag things), this is automatic, zero-config, and makes
"which box am I on" a peripheral-vision question. It also composes with the
spirit-sigil idea: same input, two representations.

### SEA-034 · Whisper mode
A one-key toggle (and an automatic trigger when the shell reports a no-echo
prompt) that suspends command capture *and* excludes the next N lines from
assistant context, with a small visual "the room is quiet" indicator. This
directly retires the caveat that command suggestions "can't tell a shell command
from a password" (`docs/STATUS.md:97-101`) — instead of solving it with an
opt-out, solve it with an explicit, visible mode.

### SEA-035 · Séance transcript
Export a session as Markdown — commands, outputs, timestamps, host, duration —
with redaction applied, straight into a snippet, a file, or the clipboard. The
scrollback, the OSC 133 marks, and the redactor all already exist; this is
assembly, not invention. It is also the natural "what did I just do on this box
for two hours" artifact.

### SEA-036 · Latency as a pulse, not a number
dartssh2 sends a keepalive every 10 s and gets a reply
(`dartssh2/lib/src/ssh_client.dart:225`). Surfacing the round-trip as a slow,
low-contrast pulse on the connection dot (with the millisecond figure on hover)
gives the "is this link alive or is the box wedged?" answer without another
readout. Must respect reduced-motion.

### SEA-037 · Two-hand mobile key deck
The current key row is a single scrolling strip (`terminal_keyboard_bar.dart`).
On a phone held in two hands, the reachable zones are the two lower corners. A
split deck (modifiers left, navigation right, punctuation in a pull-up drawer)
is a meaningfully better ergonomic story, and pairs with the per-host decks the
previous pass proposed.

### SEA-038 · Idle divination
When a session is idle and reachable, occasionally sample cheap facts the
assistant would otherwise have to ask for (uptime, disk pressure, pending
reboots) — **only** with explicit per-server opt-in, and shown as a passive
"reading" on the server row rather than injected into the terminal. Handles the
`HostContext`-is-empty gap noted in `ANALYSIS.md` without the assistant guessing.

---

## 7. What this pass implements

Chosen for high confidence, contained blast radius, and mostly-disjoint files so
the pull requests can land in any order.

| Branch | Covers |
|---|---|
| `claude/terminal-appearance` | SEA-013 (+ SEA-025 zoom keys) |
| `claude/session-tab-identity` | SEA-014 |
| `claude/server-list-search` | SEA-024 |
| `claude/connect-perf` | SEA-001, SEA-011 |
| `claude/probe-hygiene` | SEA-003, SEA-004 |
| `claude/chat-continuity` | SEA-010, SEA-016 |
| `claude/settings-recovery` | SEA-002 |

Deliberately **not** implemented here, with reasons:

- **SEA-023 (scrollback search)** — needs viewport/scroll control inside the
  vendored xterm fork and a new render-layer highlight path. Worth doing, worth
  doing properly, too large for this pass.
- **SEA-009 / SEA-025 (tab shortcuts)** — the destructive-close guard must be
  moved into `AppState` *first*; shipping ⌘W before that would create a
  data-loss path. Sequenced deliberately.
- **SEA-015 (two-stage breakpoint)** — touches the same layout allocator that
  PR #26 recently stabilised and that has widget tests pinned to the current
  contract; wants its own focused change.
- **SEA-012, SEA-026, SEA-027, SEA-028, SEA-031…SEA-038** — real, but design
  decisions the owner should make rather than have made for them.
