# Changelog

## 0.6.1 — 2026-10-29

- Apply the exact diff bytes whose verification digest was checked, bound to the session's base commit and successful verification state.
- Keep plan approval and change runs disabled while the editable plan differs from its saved, normalized form; show a clear save-before-review state.
- Read imported extension descriptors through one bounded file-descriptor reader shared by the App and CLI, rejecting links, special files, oversize input, and size changes during reads.

## 0.6.0 — 2026-10-27

- Added subscription-only isolated change sessions with reviewable plan approval, full file diffs, per-file restore, patch export, and verified accept/apply to a named local branch.
- Added explicit user-started verification in the isolated workspace using `.codex/ci.sh` by default or an approved custom executable plus argv; results include exit status and duration.
- Added a redacted activity timeline and persistent task board for actually launched operations, with bounded concurrency across different sessions and per-session cancellation.
- Added explicit selected-turn/note memory handoffs between commits in the same canonical repository; target prompts include matching handoffs as provenance-bearing, untrusted JSON under a 16 KiB limit.
- Added inert Skills/MCP descriptor import and per-project permission metadata. Import and grants do not activate provider extensions or execute scripts.
- Updated the English and Traditional Chinese app labels and operator documentation for the safe change, verification, task, memory handoff, and extension-policy workflows.

## 0.5.0 — 2026-10-27

- Added a first-use workspace data-root picker, a change-root control, and shared App/CLI root configuration.
- Moved isolated workspaces and shared memory under the selected user root while keeping settings, credentials, usage ledgers, and audit/session metadata in Application Support.
- Added safe additive migration of existing workspaces and memory, preserving old copies and refusing conflicting destination data.
- Added `agentbridge workspace show` and `agentbridge workspace set /absolute/path/to/root`.
- Refused workspace data roots inside Git repositories, including linked worktrees.

## 0.4.0 — 2026-10-27

- Made English the default app language and added bundled English and Traditional Chinese UI localization with a persisted in-app language picker.
- Updated the app package to include and resolve both localization resource sets.

## 0.3.0 — 2026-10-26

- Added provider usage reporting and local usage controls, plus bilingual documentation and the app icon.

## 0.2.0 — 2026-10-26

- Added provider account profiles with isolated CLI configuration directories and in-app interactive login.
- Added shared App chat memory keyed by canonical repository path and committed snapshot, including opt-in sharing for additional accounts and manual terminal handoff notes.
- Added an embedded SwiftTerm terminal for Codex and Claude interactive sessions, account login, and local PTY checks.
- Added provider/account-aware session switching and plan reporting only when the official CLI exposes it.
- Updated CI and app packaging to pin and bundle SwiftTerm resources and license using project-local SwiftPM caches.

## 0.1.0 — 2026-10-25

- Initial standalone macOS Swift package with a shared core, command-line tool, and SwiftUI app.
- Added isolated committed Git snapshots, subscription-only credential checks, bounded no-shell process execution, cancellation, private JSONL session/audit storage, and output redaction.
- Added read-only Codex and Claude runs plus manually approved Claude interactive sessions.
- Added explicit Claude API runs with a per-run provider limit and shared US$140 UTC-month local budget ledger; API mode remains opt-in and is not exercised by development checks.
