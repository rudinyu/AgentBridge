# Changelog

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
