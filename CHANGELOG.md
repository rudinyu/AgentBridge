# Changelog

## Unreleased

### Fixed

- In Traditional Chinese, more labels chosen by a condition showed in English: the Mac Control import buttons and hints, **Create Git Project** and **Link Existing Project**, the extension preview hint, the verification result, and the yes, no, confirmed and unknown values inside status lines.
- A task summary, name or ID that was exactly "yes", "no" or "pending" was shown translated, as if it were one of the App's own words. These values now use their own `value.` keys.
- In Traditional Chinese, sheets such as the Git handoff review showed most of their labels in English, because SwiftUI's language setting did not reach them. Each sheet now sets it.
- A new window could open at 980 by 732 points, smaller than the 1160 by 780 the main view needs, so both sides of the window were cut off. The window can no longer be smaller than the main view.

### Tests

- The conditional-label check in `AppLocalizationTests` covered only `localized(...)`. It now reads the Swift source properly and also covers `localizedFormat(...)`, SwiftUI labels, interpolated values and subfolders. A new test requires every sheet to set the language. 344 tests pass under the native build system: 309 Core, 29 App and 6 terminal-capture.

## 0.12.2 — 2026-11-08

- Release record: build 16 was signed with Developer ID Application (hardened runtime), accepted by Apple notarization (submission `faf39042-1de0-4864-868d-e4cce07cf419`), stapled, and passed signature, Gatekeeper and staple checks on a freshly extracted copy, whose helper reports `AgentBridge 0.12.2`. Delivery ZIP `build/AgentBridge-notarized.zip` has SHA-256 `c4f2177fdc8087f54f1574db6ee2508ec6d1144caa425083dfc0d813f1d529f5`. This record does not cover launching or clicking through the signed App.

### Fixed

- In Traditional Chinese, the terminal panel's **Close terminal**, **End the CLI, then close** and **Cancel and close** buttons, and the "yes" and "pending" values of an autonomous workflow's memory-summary line, showed in English. Each label is chosen by a condition inside `localized(...)`, which no check covered; a new test now reads every such label and requires a translation.

### Tests

- `AppLocalizationTests` now reads every label chosen inside `localized(...)` in the App and requires a Traditional Chinese translation for it. 339 tests pass under the native build system; under `swiftbuild`, 309 Core, 24 App and 6 terminal-capture tests pass.

## 0.12.1 — 2026-11-08

- Release record: build 15 was signed with Developer ID Application (hardened runtime), accepted by Apple notarization (submission `8d2f093d-7833-487a-9595-e0bfaa6e6d8f`), stapled, and passed signature, Gatekeeper and staple checks on a freshly extracted copy, whose helper reports `AgentBridge 0.12.1`. Delivery ZIP `build/AgentBridge-notarized.zip` has SHA-256 `34243fa707395e77119f9c0b93edb1e3a384eebe1f852e2be2e621276c044d47`. The signed App itself has not been launched or clicked through.

### Upgrade notes

- The usage card now remembers the last `/usage` reading for each account. Recognized readings are saved as parsed fields only (percentages, reset times, capture time, source), never screen text, in private files under `usage-reports/` in the App's data folder. Delete that folder to forget them.
- `agentbridge usage-tui` in your own terminal now runs the provider's TUI behind a pass-through pseudo-terminal, so that its readings reach the App. Keys, Control-C, resizing and exit status behave as before. The App's own usage terminal passes `--in-app` and is unchanged.

### Added

- `agentbridge usage-tui` run in your own terminal now feeds the App's usage card. Claude reads that terminal directly, so nothing in between saw its screen. The command now starts the usage TUI on a pseudo-terminal it owns and passes every key and byte through unchanged, while replaying the output into a headless copy of the terminal. Whenever the copy shows recognized limits, it saves only the parsed report (percentages, reset times, capture time, source), never screen text, to a private file per account under `usage-reports/`. The App shows the newest report for the selected account, labelled as read in your terminal, and reports read in the App are saved the same way, so the card keeps the last reading after a restart. The App's own usage terminal passes `--in-app` and runs the TUI directly as before. Checked with Claude Code 2.1.311 in a 16-row terminal: the report was saved and shown on the card, Control-C still exits the TUI, a stopped command ends it, and the folder-trust entry is still purged.

### Fixed

- The usage card read nothing from Claude Code 2.1.311's `/usage` screen and showed "No recognized fields". The screen is taller than the in-app terminal, so the session and weekly limits scrolled off before they were read, and Claude draws many spaces by moving the cursor, which SwiftTerm renders as NUL, so even a visible "Current session" did not match its label. The capture now starts at the row that was on top when `/usage` was sent, keeps the newest rows within the same row and byte bounds, and reads skipped cells as spaces. Checked in the App against the live screen: Current session 86% and Current week (all models) 33%, with their reset times.
- The in-app terminal did not take the keyboard when it opened, so arrow keys and Enter went to the rest of the window until you clicked it, and clicking did not always help: once a TUI such as Claude Code turns on mouse reporting, SwiftTerm hands the click to the TUI and leaves the keyboard where it was. The terminal now takes the keyboard when it opens and whenever it is clicked. Found by testing the signed 0.12.0 App: the Claude usage terminal's folder-trust prompt ignored the arrow keys.

### Tests

- New `AgentBridgeTerminalCaptureTests` for reading the usage screen and the terminal recorder, and `ProviderUsageReportStoreTests` for the saved reports. 337 tests pass under the native build system; under `swiftbuild`, 309 Core, 22 App and 6 terminal-capture tests pass.

## 0.12.0 — 2026-11-08

- Release record: build 14 was signed with Developer ID Application (hardened runtime), accepted by Apple notarization (submission `8bcedabd-8ee8-4ffe-920f-8222bf805f5d`), stapled, and passed signature, Gatekeeper and staple checks on a freshly extracted copy, whose helper reports `AgentBridge 0.12.0`. Delivery ZIP `build/AgentBridge-notarized.zip` has SHA-256 `b9b7f52748217a7f3db2fb2711a0d866aaaaab2f788da220236a9c55e3133b63`. The signed App itself has not been launched or clicked through.

### Upgrade notes

- A change run no longer sees shared memory or project handoffs unless its plan includes them. Select **Include shared memory in the change run** in the App, or pass `--with-memory` to `changes plan`. Plans saved earlier load without memory and keep their digest.
- Verification now runs in a fresh checkout inside a macOS sandbox. Build caches no longer carry over between runs, the home folder cannot be read, and network access stays on. macOS refuses nested sandboxes, so a verifier that starts its own sandbox must turn it off when `AGENTBRIDGE_VERIFICATION_SANDBOX` is set; `.codex/ci.sh` now does this for SwiftPM. A session pinned to an older commit keeps that commit's `.codex/ci.sh`. Verification is refused if `sandbox-exec` is unavailable.
- `.codex/ci.sh` runs as the default verification only when it is the executable file from the pinned commit. A changed script runs only as an approved custom verifier.
- Discussion turns now count toward the limit of three concurrent runs, except with a local model.

### Security

- Verification ran in the provider's workspace as your macOS user with no sandbox, so code a provider wrote could read your home folder, and a pass could depend on Git-ignored files that are not in the reviewed diff. It now runs in a throwaway checkout of the pinned commit plus the exact patch, under a Seatbelt profile that blocks the home folder, the data roots and the source repository. A verification that changes the checkout's diff fails.
- Claude change runs now run under a macOS sandbox too. Claude's edit tools decide for themselves which paths they may write; the OS now also limits them to the workspace and Claude's own folders, keeps the workspace's `.git` read-only, and blocks the rest of the home folder, the data roots and the source repository. Runs with MCP servers are not sandboxed yet. Codex change runs already use Codex's own sandbox.
- An isolated-change review no longer reads the workspace's own `.git`, which a provider or a terminal command can edit. Each session keeps a private copy of only its pinned commit under Application Support, and the diff, ignored-file list, restore actions, `.codex/ci.sh` check and verification checkout use it with a fresh index. A Git filter, an `info/exclude` entry, an index flag or a commit in the workspace can no longer hide an edit or run a program outside the sandbox. A folder in the workspace that is its own Git repository stops the review with a clear message. Older sessions get their private copy from the source repository on their first review.
- A change run that includes shared memory uses it only as approved: approval records the memory as it is then, and the run is refused if it changed.
- A provider or verification run, an MCP server the App or CLI started to inspect or test it, and a native TUI started from the CLI in a Terminal all kept running, with no timeout, after the App or CLI was crashed or killed, because AgentBridge enforces their timeouts itself. A small watchdog now ends them within a few seconds of AgentBridge stopping.

### Added

- Token monitoring. The usage dashboards and the new `agentbridge usage codex|claude|local [--profile PROFILE-ID]` command show the tokens Codex, Claude and local models reported for AgentBridge runs over the last 5 hours, 24 hours and 7 days and for the selected session, split into uncached input, cached input, cache write and output. Failed runs, interactive terminals and other apps are not counted.
- Per-account token limits for the last 5 hours, 24 hours and 7 days and the current session, under **AgentBridge Local Token Limits** in the usage panel, with the same 50%, 75%, 90% and 100% alerts as the run limits. They count all reported tokens in both subscription and API mode and are checked before each run, so the run that crosses a limit still finishes and the next one is refused.
- The review lists Git-ignored paths in the workspace, in the App and in `changes diff`. They are not in the patch or the digest, verification does not see them, and they do not reach your branch.
- Accepting or applying a diff with files that are not fully shown, meaning long or non-UTF-8 files, needs a separate confirmation bound to that exact diff: a checkbox in the App, or `--confirm-partial DIFF-DIGEST` in the CLI, with the digest printed by `changes diff`. Binary files need no confirmation.

### Changed

- An approved autonomous workflow now waits for a free run slot instead of failing when all three are in use. Runs started by hand still fail at once so you can choose what to stop.
- Applying to a local branch no longer requires the source repository's `HEAD` to still be the session's base commit, only that the commit still exists. The branch starts at that commit in its own worktree, as before.

### Fixed

- One file could stop a whole session being reviewed, accepted or applied. A file whose diff is over 1 MiB, such as a regenerated lockfile, or a text file that is not UTF-8, such as Big5, made the diff fail. Long diffs are now hidden with a note and non-UTF-8 text is shown with replacement characters; both stay complete in the patch that is verified, exported and applied. A combined diff over 10 MiB is still refused.
- The App showed English instead of Traditional Chinese on macOS 27, where bundle lookups are case-sensitive. The `.lproj` folder is now found regardless of case.
- A session left marked running by a process that crashed or was killed stayed that way and blocked changing the data root. It is now marked failed.
- The Claude usage terminal failed to start, because Claude Code 2.1.311 refuses `--no-session-persistence` outside `--print`. It now starts without it, and when it closes AgentBridge runs `claude purge --yes` for its one-time folder, which removes the trust entry that accepting Claude's folder prompt leaves in `.claude.json`, along with any transcript.

### Tests

- `.codex/ci.sh` builds and tests under both SwiftPM build systems, native and `swiftbuild`, because they lay out resources differently; 328 tests pass under the native one and 306 under `swiftbuild`.

## 0.11.2 — 2026-11-05

- Release record: build 13 was signed with Developer ID Application (hardened runtime), accepted by Apple notarization (submission `9b0fdbf7-8647-43e2-a646-b81539621a8c`), stapled, and passed signature, Gatekeeper and staple checks on a freshly extracted copy. Delivery ZIP `build/AgentBridge-notarized.zip` has SHA-256 `34ed645c1573803ca75b2dd80dec000f50dfb4e226097d384ee4095cccf7aa70`. The signed build itself has not been launched or clicked through.

- Fixed: AgentBridge stopped working once its data files filled up. The session index only ever grew (each save appended a whole record) and had a 10 MiB limit, so after about 21,400 saves no session could be saved, including new ones, and nothing said how to recover. The index is now compacted to one line per session (atomically) once it passes 2 MiB, so it cannot reach its limit. A session's audit file, which could fill with long run outputs and then fail a run after the provider had already answered, now trims the text of older `run.output` events instead; every event is kept because the local usage counters read their kinds and times, and the newest output stays complete.
- Faster: looking up one session no longer parses the whole index each time (about 170 ms with 20,000 records, and a run looked sessions up eight times), and the App's two-second refresh no longer re-decodes the selected session's audit file when it has not changed. Both reuse their decoded data until the file changes, including when another process changes it.
- Fixed: the three-run limit also counted short operations. While three runs were in progress, viewing a diff, approving a plan, accepting changes, restoring or exporting failed with "Up to 3 tasks can run at once", and the App's two-second refresh, which asks for the selected session's diff, raised that error repeatedly. Only provider runs (read-only, change and verification) take a slot now. This was introduced with the limit in 0.11.1.
- Fixed: showing English text that has no translation cost tens of milliseconds a call, because every call sorted and scanned all the table keys. Text without Chinese in it now returns immediately, and the keys are sorted once. Older stored Chinese text is translated as before.
- Code structure (no behaviour change): `runChanges` reuses the extension check that `runReadOnly` already had and lost three steps to helper functions (211 to 177 lines; the prompt text is byte-for-byte identical), and the custom verification command check moved out of `runVerification`.

## 0.11.1 — 2026-11-05

- Release record: build 12 was signed with Developer ID Application (hardened runtime), accepted by Apple notarization (submission `4fa3a5d3-d4b2-4511-8697-7621642ab588`), stapled, and passed signature, Gatekeeper and staple checks on a freshly extracted copy. Delivery ZIP `build/AgentBridge-notarized.zip` has SHA-256 `68c5e5f1540457576e60d435b66260455a6e92e61a0548eb59f91ec92473e889`. The signed build itself has not been launched or clicked through.

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

- Release record: build 11 was signed with Developer ID Application (hardened runtime), accepted by Apple notarization (submission `1c727b40-f4a9-44fa-bb09-7bed5f6cf584`), stapled, and passed signature, Gatekeeper and staple checks on a freshly extracted copy. Delivery ZIP `build/AgentBridge-notarized.zip` has SHA-256 `31dd57c26129a8d7387eeb649dc3c34732e61efe4ba70db5247935fabc0aca70`. Build 10 (submission `dc69a199-e249-4d9c-b7e3-d0664ffdef7e`) was also notarized but is superseded because of the header overlap fixed below. The unsigned development build of the same code was confirmed to fix the overlap; the signed build itself has not been launched.

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
