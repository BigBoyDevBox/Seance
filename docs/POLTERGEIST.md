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

- **Git-pinned dependencies, never forks:** `seance_protocol` and
  `seance_core` (records/crypto/DTOs, `SyncEngine`/`HttpSyncClient`/
  `LocalRecordStore`, `RemoteFileSystem` + adapter, `TofuVerifier`, stores,
  ssh_config import, probe service). The pin is a Séance tag, bumped as a
  routine chore.
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
`bookmark` record kind travels inside the encrypted payload, which the
server cannot see — no endpoint, schema, or protocol-version change.

## Upstream asks (sequenced; each is small and self-contained)

| Id | Change | Why |
|---|---|---|
| PR-S0 | Add a LICENSE to Séance (suggest Unlicense, matching Poltergeist) | The repo currently has no license file; Poltergeist's copy-with-attribution step is gated on it (and downstream users of either repo need it anyway) |
| PR-S1 | **Forward-compatible record kinds** — add `RecordKind.unknown`; change `recordKindFromName`'s `orElse` from `serverConfig` to `unknown`; skip-and-preserve unknown kinds in `SyncCoordinator.applyToStores` with a per-record try/catch; add the `bookmark` kind + `Bookmark` model | Today an unknown kind decodes as `serverConfig`: a pulled `bookmark` record either throws in `ServerConfig.fromJson` (bricking every subsequent sync round on the old client) or — worse — half-parses into a **phantom server** that the old client then re-seals and pushes as first-class data. This is a real forward-compat bug independent of Poltergeist; it is also the hard gate before the two apps may share a sync account |
| PR-S2 | Extract `openAuthenticatedClient(...)` (socket + TOFU + auth + connection log + failure summarizer, minus shell/PTY) from `SshSessionManager.connect`; recompose `connect()` on top, behavior unchanged | Lets a file manager authenticate without opening a shell channel; it is also what Séance's own "dedicated transfer connection" future item (docs/SFTP.md) needs |
| PR-S3 | Additive `RemoteFileSystem` methods: `setTimes` (SFTP setstat atime+mtime), `setOwner` (chown/chgrp), an optional per-call hashing flag, ranged read | `setTimes` is a hard prerequisite for sync convergence (mtime-based comparison); the rest closes documented interface gaps. All additive; in-memory-fake test coverage included |
| PR-S4 | ssh-agent auth (`$SSH_AUTH_SOCK` / Windows named pipe, custom `SSHKeyPair` signer) and ProxyJump execution behind the already-modeled `jumpHostId` | Séance's own STATUS.md item #1 and a deliberately deferred item — both apps' power users need it; Poltergeist schedules it as its first post-v1 fast-follow and would land it here |

Until PR-S1 ships in a Séance release **and every device runs it**,
Poltergeist defaults to a *separate* account on the same sync server
(works against unmodified Séance today) and treats the shared-account mode
as locked.

## What flows back

Poltergeist's plan commits to porting improvements back rather than
forking: the persistent local record store with real tombstones (fixes the
delete-resurrection gap — today nothing in Séance ever writes a tombstone,
so a deleted server resurrects on the next full pull), theme-aware status
colors, staged responsive collapse, keyboard/command-registry patterns, and
any bug fix made in a ported file. The `PORTS.md` ledger on the Poltergeist
side is the tracking mechanism; nothing in that flow blocks Séance work.

## Cross-app behaviors worth knowing about

- In shared-account mode Poltergeist reads `serverConfig` records
  **read-only** (the user's Séance servers appear as ready-made bookmark
  sources) and syncs host-key pins bidirectionally as standard
  `hostkey:<host:port>` records — the same trust the user's other Séance
  devices already exchange.
- Poltergeist writes only `bookmark:` and `hostkey:` records; it never
  edits `serverConfig`/`secret`/`snippet` records and never exposes
  `DELETE /v1/account` in shared mode (that endpoint nukes both apps'
  data).
- Record sizes are a few hundred bytes — far under the server's 1 MiB blob
  cap; sync tokens coexist per app (one row per login, no expiry).
