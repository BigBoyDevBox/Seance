# Poltergeist — the sibling file-transfer app, and what it asks of Séance

[Poltergeist](https://github.com/L-K-M/Poltergeist) is a cross-platform,
SFTP-first, two-pane file transfer client patterned after Transmit and
ForkLift — a sibling of Séance that reuses this repo's transport, security,
sync, and editor foundations. Its full design plan lives in
[Poltergeist's docs/plan/](https://github.com/L-K-M/Poltergeist/tree/main/docs/plan);
this file records the Séance-facing part: what Poltergeist consumes, the
small upstream changes it needs, and the porting-back arrangement — so a
Séance session touching these areas knows a second consumer exists.

## How Poltergeist consumes Séance

- **Git-pinned dependencies, never forks**: `seance_protocol` and
  `seance_core` (records/crypto/DTOs, `SyncEngine`/`HttpSyncClient`/
  `LocalRecordStore`, `RemoteFileSystem` + adapter, `TofuVerifier`, stores,
  ssh_config import, probe service). The pin is a Séance tag, bumped as a
  routine chore.

  Pinning is deliberately not gated on PR-S0: both repos share one owner,
  so consuming the unlicensed packages is the rights holder's own call —
  a rationale that holds only while Séance has no external contributions
  (verified at this writing: every author and co-author identity in
  `git shortlog -sne --group=author --group=trailer:Co-authored-by` is
  either the owner's own accounts and machines or the owner's own
  AI-assistant sessions — tools the owner operates, whose output the
  owner holds; no external human contributor appears. History cannot
  reveal a squash-merged external contribution, which is one reason
  PR-S0 still re-verifies manually). PR-S0
  re-verifies sole authorship, or collects contributor sign-off, before
  the license is chosen; the LICENSE is what the copy-with-attribution
  path and any downstream user need.
- **Copy-with-attribution** for app-layer assets that live outside the pure
  packages (managed-checkout pipeline, atomic-file helpers, the built-in
  editor stack, toasts, `MiddleEllipsisText`, adaptive layout math, the
  appearance/accent module, the Swift channel patterns). Each copy is
  recorded in Poltergeist's `docs/PORTS.md` with the source path + Séance
  commit, so fixes can flow both ways.
- **Never touched:** Argon2/HKDF parameters and domain-separation salts, the
  sealed-blob layout, the LWW tuple `(updatedAt, deviceId, seq)`, the record
  envelope, and the "UI never sees dartssh2 types" boundary.

Bookmark backup rides the **existing sync server unchanged**: a new
`bookmark` record kind travels inside the encrypted payload — no
endpoint, schema, or protocol-version change, because kind is not a
field of the server's record schema at all. Precision on what the
server *does* see: record **ids** follow Séance's existing kind-prefix
convention (`sync_coordinator.dart` writes `hostkey:<host:port>` today;
bookmarks follow as `bookmark:<uuid>`), so the id prefix — and, for
pins, the host:port inside it — is plaintext on the server, the same
accepted privacy nit Séance already carries. The *serialized envelope* —
the wire form `{id, updatedAt, deviceId, deleted, seq?, blob}` that
wraps the sealed blob — carries no kind string; the kind name itself
travels only inside the sealed blob. That narrower claim is what the
PR-S1 regression test pins.

## Upstream asks (sequenced; each is small and self-contained)

| Id | Change | Why |
|---|---|---|
| PR-S0 | Add a LICENSE to Séance (suggest Unlicense, matching Poltergeist — under it the PORTS.md attribution ledger is deliberately an engineering-provenance convention, not a license term; MIT for both repos would be the pick if attribution ever needed to be enforceable) | The repo currently has no license file; Poltergeist's copy-with-attribution step is gated on it (and downstream users of either repo need it anyway) |
| PR-S1 | **Forward-compatible record kinds** ([#53](https://github.com/L-K-M/Seance/issues/53)) — add `RecordKind.unknown`, map unknown kind names to it, skip-and-preserve unknown kinds in `SyncCoordinator.applyToStores`, add the `bookmark` kind + `Bookmark` model (full spec below the table) | Today an unknown kind decodes as `serverConfig`, which bricks sync rounds or mints a phantom server; a real forward-compat bug independent of Poltergeist, and the hard gate before the two apps may share a sync account |
| PR-S2 | Extract `openAuthenticatedClient(...)` (socket + TOFU + auth + connection log + failure summarizer, minus shell/PTY) from `SshSessionManager.connect`; recompose `connect()` on top, behavior unchanged | Lets a file manager authenticate without opening a shell channel; it is also what Séance's own "dedicated transfer connection" future item (docs/SFTP.md) needs |
| PR-S3 | Additive `RemoteFileSystem` methods: `setTimes` (SFTP setstat atime+mtime; note SFTP v3 timestamps are whole seconds — consumers must round or tolerance-compare mtimes, never compare exactly), `setOwner` (chown/chgrp), an optional per-call hashing flag. Ranged read is deliberately **not** included — Poltergeist defers it to its resumable-transfer work (v2) and would file it as its own small PR then | `setTimes` is a hard prerequisite for sync convergence (mtime-based comparison); the rest closes documented interface gaps. All additive; in-memory-fake test coverage included |
| PR-S4 | ssh-agent auth (`$SSH_AUTH_SOCK` / Windows named pipe, custom `SSHKeyPair` signer) and ProxyJump execution behind the already-modeled `jumpHostId` | Séance's own STATUS.md item #1 and a deliberately deferred item — both apps' power users need it; Poltergeist schedules it as its first post-v1 fast-follow and would land it here |

**PR-S1 detail** (the table row's full spec): change
`recordKindFromName`'s `orElse` from `serverConfig` to `unknown`, and
skip-and-preserve unknown kinds in `SyncCoordinator.applyToStores` with a
per-record try/catch. Preserved records keep their original sealed blobs
and kind strings — never re-sealed under a lossy `unknown` name, never
re-pushed — and the pull high-water mark still advances past them so they
aren't re-fetched every round. That no-refetch property (and its
stranding flip side) only bites once the record store **persists across
rounds** — Poltergeist's store today, Séance's after the
persistent-store flow-back; present-day Séance rebuilds its in-memory
store per round, so every pull harmlessly re-delivers preserved records
(see "What flows back"). With a persistent store, a build whose
known-kind set grew must re-scan the **local** store to apply previously
preserved records — the pull will never deliver them again; a fresh
store recovers them on its first full pull. Add the
`bookmark` kind + `Bookmark`
model. Séance's apply path never decodes bookmark payloads at all
(`case bookmark: break;` — there is no bookmark store), and the
per-record try/catch additionally fail-softs a malformed payload of
*any* known kind, so a future Poltergeist schema change cannot brick a
Séance round through either door — keep both properties when touching
this code. Include a regression test pinning that a sealed record's
serialized envelope carries no kind string (the narrower "kinds never
leave the sealed envelope" invariant above — the id prefix stays
server-visible, as already noted).

Until PR-S1 ships in a Séance release **and every device runs it**,
Poltergeist defaults to a *separate* account on the same sync server
(works against unmodified Séance today) and treats the shared-account mode
as locked. Nothing server-side enforces this gate (kind is not in the
server's schema — it cannot police what it does not model), so unlocking
shared mode is a **user-asserted switch**. The normative requirements on
Poltergeist's setup flow, one per bullet:

- **Ask before the first write:** the user confirms every device on the
  account runs a PR-S1-era build before the first `bookmark:` record is
  written.
- **Cover pin trust too:** PR-S1 gates *record integrity* (#53); pin
  trust is a second axis. With
  [#56](https://github.com/L-K-M/Seance/issues/56) unfixed, Séance
  devices auto-apply synced pins — pre-existing behavior among Séance's
  own devices, which is why it is not a second hard gate. Recommended:
  land the #56 fix in the **same minimum release** as PR-S1 so one
  version assertion covers both axes; if the minimum release lacks it,
  the setup copy must disclose that Séance devices will trust pushed
  pins without a conflict warning — and this axis carries the same
  permanence caveat as PR-S1's: a pre-#56 build that joins the account
  later (or is rolled back) silently overwrites pins again.
- **State the permanence:** the assertion covers devices present at
  unlock only — a pre-PR-S1 build that joins later (or a device rolled
  back to one) still decodes `bookmark:` records as a phantom
  `serverConfig` (#53) — so the copy says the account stays unsafe for
  old builds *permanently after* unlocking, not only at the switch.
- **Warn in separate mode too:** the same exposure exists through one
  manual path — signing an old Séance build into the Poltergeist-owned
  account — and separate-account setup copy warns against it.

## What flows back

Poltergeist's plan commits to porting improvements back rather than
forking: the persistent local record store with real tombstones (fixes the
delete-resurrection gap — today nothing in Séance ever writes a tombstone,
so a deleted server resurrects on the next pull, and every Séance pull
is effectively full: the app rebuilds its in-memory record store each
round, so the high-water mark restarts at zero; when tombstones
land, applying one must remove the record regardless of kind
decodability — preserved unknown-kind records included — or a deleted
bookmark resurrects on any device that later learns the kind, a
preserved-record variant of [#54](https://github.com/L-K-M/Seance/issues/54)),
theme-aware status
colors, staged responsive collapse, keyboard/command-registry patterns, and
any bug fix made in a ported file. The `PORTS.md` ledger on the Poltergeist
side is the tracking mechanism; nothing in that flow blocks Séance work.

## Cross-app behaviors worth knowing about

- In shared-account mode Poltergeist reads `serverConfig` records
  **read-only** (the user's Séance servers appear as ready-made bookmark
  sources) — and **endpoint-pinned**: each Poltergeist device records
  the endpoint it bookmarked, so a Séance-side edit that changes a
  server's host/port/username costs a one-time confirmation on each
  Poltergeist device before it connects to the new endpoint (otherwise
  one compromised device could LWW-rewrite a server record and redirect
  bookmarks to a credential-collecting host that no pin conflict would
  ever flag) — and syncs host-key pins bidirectionally as standard
  `hostkey:<host:port>` records — the same trust the user's other Séance
  devices already exchange. Shared-account mode therefore extends TOFU
  trust to every app on the account — **including first-seen keys**:
  where a device holds no local pin to conflict with, a synced pin is
  applied as trusted with no warning (that silent propagation *is* the
  multi-device pin-sync feature), which means one compromised device on
  the account can mint trust for hosts the fleet has never seen — a
  residual risk the shared-mode setup copy must disclose, quarantine or
  no quarantine. A synced pin that conflicts with a
  locally known key must surface a user-visible warning (treated as a
  possible MITM), never a silent overwrite — and the conflicting incoming
  pin is **quarantined at the application layer**: held unapplied to the
  local TOFU store until the user resolves the warning. The record store
  itself still merges by LWW (the wire behavior stays untouched, per the
  never-touch list above); what is gated is applying the synced key as
  trusted — otherwise a newer LWW tuple from a compromised device would
  replace the locally trusted key and the warning would be cosmetic.
  Resolution semantics: **keep local** re-pushes the kept pin under a
  newer LWW tuple, so the user's trust decision becomes canonical — the
  conflict stops re-arming here and stops firing on devices that never
  applied the conflicting pin. One caveat: a device that already chose
  **accept synced** holds the conflicting key locally, so the canonical
  pin fires one more warning there — and opposite answers ping-pong
  (each keep-local re-pushes its own key under a newer tuple, re-arming
  the other side) until the affected devices agree; convergence costs
  one resolution per device that applied the conflicting key. **Accept
  synced** applies the quarantined key. And the protection is only as wide as its weakest device: Séance
  itself currently applies pulled pins unconditionally
  (`sync_coordinator.dart` — filed as
  [#56](https://github.com/L-K-M/Seance/issues/56)), so until that lands,
  shared mode silently overwrites trust on Séance devices even while
  Poltergeist quarantines.
- Poltergeist writes only `bookmark:` and `hostkey:` records; it never
  edits `serverConfig`/`secret`/`snippet` records and never exposes
  `DELETE /v1/account` in shared mode (that endpoint nukes both apps'
  data).
- Record sizes are a few hundred bytes — far under the server's 1 MiB blob
  cap; sync tokens coexist per app (one row per login, no expiry).
