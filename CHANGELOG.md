# Changelog

## 0.11.1 — 2026-11-05

- Code structure (no behaviour change): the largest types in `ActiveExtensionRuntime`, `AutonomousOrchestration`, `ProviderAdapters`, `ActiveExtensionsView` and `DiscussionChatView` moved into files of their own; `runReadOnly` lost four self-contained steps to helper functions (269 to 218 lines); and the long `switch` functions in the CLI now call one function per subcommand (the longest went from 244 to 135 lines). 137 CLI invocations across every command group were compared against the previous build with identical output and exit codes.
- A new test fails when a Core message is added without a Traditional Chinese translation. 513 existing English messages without one (mostly store integrity checks) are frozen in `Tests/AgentBridgeCoreTests/Fixtures/untranslated-core-messages.txt`, so the list can only shrink; regenerate it with `UPDATE_L10N_BASELINE=1`.
- The version and build number are now written once, in `AppVersion.swift`; the CLI reports it and `scripts/package-app.sh` reads it for the app's Info.plist. The CLI source is split into one file per command group (a pure move).
- The CLI compatibility check now probes every flag the provider adapters pass (it covered 22 of 33; the 13 it missed included `--resume`, `--session-id`, `--mcp-config`, `--ephemeral` and `--skip-git-repo-check`), and a test fails if an adapter starts passing a flag the check does not know about. The App shows the result as a warning under the CLI paths when a CLI is older than the verified version or no longer lists a flag AgentBridge needs. `--max-turns` (paid Claude API path) is not advertised by `claude --help`, so whether it is still accepted cannot be probed.
- The limit of three concurrent runs now lives in Core and holds across the App, the CLI and autonomous workflows. Each run takes one of three slot lock files in the private root besides its session lease, so a crashed run frees its slot. Previously only the App enforced it and CLI runs did not count. A fourth run is refused with a clear message.
- The App no longer reads its data on the main thread every two seconds. The periodic refresh now loads sessions, audit events, discussions and the rest in the background and applies the result on the main thread, which went from about 122 ms to about 2 ms per refresh with 1,500 sessions and 20,000 events. A synchronous refresh that runs meanwhile discards an older background result. Shared-memory snapshots and handoffs are now Equatable, so reloading them unchanged no longer notifies the views.
- Added `AgentBridgeAppTests`: the App had no tests. It covers the localization display logic (including a round trip of every Traditional Chinese table entry) and the refresh behaviour.
- Every child process AgentBridge starts (git, the provider CLIs, verification scripts) no longer waits an extra 0.75 s after it exits. The runner waited out its process-group cleanup grace period even when nothing else was left in the group; it now skips the wait when only the exited leader remains, and still cleans up stray descendants. This speeds up viewing diffs, applying changes and verification, and cuts the full test suite from about 737 s to about 30 s.

## 0.11.0 — 2026-11-05

- Fixed the main window header overlapping the window buttons and showing the title twice: the system title bar is hidden and the header now leaves room under the window buttons. Build 10 had this problem; build 11 supersedes it.

- Release record: build 11 was signed with Developer ID Application (team LYK4LV2859, hardened runtime), accepted by Apple notarization (submission `1c727b40-f4a9-44fa-bb09-7bed5f6cf584`), stapled, and passed signature, Gatekeeper and staple checks on a freshly extracted copy. Delivery ZIP `build/AgentBridge-notarized.zip` has SHA-256 `31dd57c26129a8d7387eeb649dc3c34732e61efe4ba70db5247935fabc0aca70`. Build 10 (submission `dc69a199-e249-4d9c-b7e3-d0664ffdef7e`) was also notarized but is superseded because of the header overlap fixed below. The unsigned development build of the same code was confirmed to fix the overlap; the signed build itself has not been launched.

- Core, CLI and App messages are now written in English instead of Traditional Chinese. The App shows Traditional Chinese through `zh-Hant.lproj`, matching whole sentences or whole-sentence templates (captured values are translated in turn) instead of replacing fragments inside a sentence. Audit events saved before this change stay readable in English through `en.lproj/Legacy.strings`. **The CLI now prints English only**; it previously printed Chinese. A test fails if Chinese text reappears in Core sources.
- `agentbridge doctor` now prints each provider CLI's version against the one AgentBridge was last verified with (Claude Code 2.1.311, Codex 0.166.0) and warns when a flag AgentBridge passes no longer appears in the CLI's help. The check is advisory and never blocks a run.
- Added `agentbridge memory relink-candidates` and `memory relink SESSION-ID KEY --confirm` for repositories that were moved or renamed: shared memory stored for the same commit under a path that no longer exists can be copied into the session's memory. Nothing is linked automatically, the original is left unchanged, a non-empty memory is never merged into, and a second clone is not offered because its old path still exists.
- The model rule in AGENTS.md is now split by vendor: OpenAI/Codex agents keep GPT-6 Luna Max, Claude agents use Opus 5.5, and local-model agents have no required model.
- A Claude API session can now make several paid calls, each with its own reservation, so the work-session USD cap counts every call in the session instead of only ever covering one. Manual settlement by session settles that session's unresolved call.
- Added **Use reserved amount** in the App and `budget reconcile --settle-at-reserved` in the CLI to settle an unconfirmed API call conservatively at its full reservation when the bill is not available yet. The blocked-call message now says where to settle, and the App and CLI show the amount a paid call reserves before it runs.
- The App and CLI warn when the workspace-data root is inside iCloud Drive, Dropbox, OneDrive, Google Drive or Box, because its transcripts, memory and workspace copies would leave the Mac and file locks only coordinate one Mac.
- A root change now repoints all sessions in one write, and selecting the same root again finishes a change that stopped before every session was repointed.

- Moved extension policy grants and active-extension execution consent from the selected workspace folder to private Application Support, importing a valid legacy document once without modifying the legacy copy.
- Workspace-root changes now carry task-board records, stopping without overwriting when a destination task differs.
- Rejected new workspace roots placed inside discussion, task-board, or legacy extension folders of a current or prior root.
- Legacy extension imports now read the old folder without creating lock files or changing permissions there.
- Added English translations for 272 previously untranslated Core messages, mainly discussions, local models and workspace operations, plus a test that fails when a new Chinese Core message lacks an English entry.
- Fixed English message display capitalizing status words inside translated sentences.
- Consolidated eight hand-written store locks into one shared lock helper, so every store now retries interrupted lock waits, opens lock files close-on-exec, and requires an owner-only, single-link regular lock file. File locations and formats are unchanged.
- Merged the Claude API monthly ledger and the day/session ledger into one ledger per account, so each paid call is reserved and settled once against all three caps. Existing records are imported once by session and the earlier files are left unchanged; manual settlement no longer reports a separate status for each ledger.

## 0.10.0 — 2026-11-03

- Added the MIT License and project copyright notice, included in packaged Apps alongside the existing third-party notices.

- Added an explicit Local provider for Ollama and OpenAI-compatible loopback model servers, with model discovery, streaming, cancellation and separate local usage.
- Added readable context compression and previews, preserving the complete current request, attributed protected passages and recent verbatim history, with safe refusal when protected content cannot fit.
- Kept local model requests independent of cloud API credentials, subscriptions and paid fallback; unsupported local tool/edit workflows remain unavailable.
- Added separate English and Traditional Chinese local-model setup and context design documentation.

## 0.9.0 — 2026-11-02

- Added project-independent discussion chats before Git selection, with persistent redacted transcripts, account-bound subscription calls and consent-aware context sharing.
- Added reviewed context handoffs to create a new local Git project or link an existing repository while preserving the original chat.
- Made Chats the default app entry and added CLI chat operations and separate English/Traditional Chinese guidance.

## 0.8.0 — 2026-11-02

- Added a subscription-only autonomous planner and dependency scheduler with explicit role accounts, digest-bound plan approval, bounded concurrency and repair, exact-diff review, optional approved verification, persistent status and cancellation.
- Kept project memory available through a consent-aware frozen context, with explicit dependency sharing and an optional bounded result summary; no provider or account switch bypasses sharing consent.
- Added actual Skill instruction snapshots and installed local stdio MCP activation, separate from legacy metadata grants. Per-run proxy tickets, exact tool filtering, revocation, execution limits and minimal child environments control MCP use without changing global provider settings.
- Added a Mac Control preset with target-App restrictions, separate Observe/Control and screen/input consent, readiness checks and Stop Control. Screen capture includes the full main display; macOS permissions remain manual.
- Added dedicated Autonomous Workflow and Skills & MCP app views, CLI operations and separate English and Traditional Chinese design/use documentation. No automatic commit, push, merge, API fallback, package installation or Skill script execution was added.

## 0.7.0 — 2026-11-01

- Added a resumable first-use setup wizard with language and provider selection, a required workspace-data folder, optional CLI-path and subscription-login checks, per-account shared-memory consent, local usage settings, and an honest readiness summary.
- Added a Settings Wizard entry for existing installations; opening it does not change saved provider, usage mode, CLI paths, or account memory consent.
- Kept official CLI subscription login as the setup path. The wizard does not install CLIs, collect API keys, make automatic model requests, or activate paid API usage; sign-in and status checks run only after an explicit action.
- Added a wizard sign-in terminal while retaining the main app's inline conversation terminal.

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
