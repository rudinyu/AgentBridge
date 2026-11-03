# Local-model validation — 0.10.0 build 9

[Traditional Chinese](LOCAL_MODELS_VALIDATION.zh-TW.md) · [Usage guide](LOCAL_MODELS_AND_CONTEXT.md)

Validated on November 2, 2026, on local macOS/Xcode. This record covers a development build; Developer ID signing, notarization and release publication have not been performed for 0.10.0.

## Build and automated checks

- `./.codex/ci.sh`: **219 tests passed, 0 failures**. Log: `build/local-model-ci-final.log`.
- After the final Local autonomous-role guard and App draft/completion changes, 11 affected regression tests passed and the complete App recompiled. Log: `build/local-model-final-guard.log`. A subsequent full run on November 3, after the MIT packaging update, also passed all 219 tests. Log: `build/mit-license-ci.log`.
- `./scripts/package-app.sh --app-name AgentBridge-0.10.0-dev.app`: Release CLI and App built successfully; Info.plist validated. Log: `build/local-model-package.log`.
- Packaged binaries match Release outputs. Version: 0.10.0, build 9. ATS allows local networking without a global arbitrary-load exception.
- November 3 MIT follow-up: repackaging passed; the bundled project license matches root `LICENSE`, the SwiftTerm notice is retained, and `NSHumanReadableCopyright` contains the project copyright and MIT attribution. Log: `build/mit-license-package.log`.
- Diff whitespace, shell/Python syntax, localization syntax and key parity passed; English and Traditional Chinese each contain 1,322 keys.

Nonfatal SwiftPM native-build-system deprecation and Sendable-function conversion warnings remain visible in the build log.

The initial restricted SwiftPM attempt stopped at `sandbox_apply: Operation not permitted`. The same validation ran in the permitted host context with explicit Xcode and repository-owned build/cache paths. Global caches, authentication and service settings were not changed.

## Actual CLI and HTTP checks

Tests used isolated data and loopback fixture servers, with provider-key/base-URL environment variables removed. Fixture replies were deterministic, not real inference.

| Exercise | Result |
| --- | --- |
| Compatible model discovery and streamed chat completions | Passed |
| Native Ollama model discovery and NDJSON chat | Passed |
| Chat before any Git project exists | Passed |
| Follow-up/account switch retains eligible shared facts | Passed |
| Insufficient context | Refused before POST or transcript mutation |
| Long-history compression | 14,599 → 6,420 UTF-8 bytes; current request, “Maple Lantern,” US$140 and no-cloud constraint retained |
| Reviewed seven-turn handoff and Local project run | Passed; original chat retained, new Git tree empty and clean |
| Cancellation from another CLI invocation | Passed; cancelled answer not saved as completed; earlier completed turn retained |

Fixture servers were stopped afterward. The user's existing Ollama service was unchanged. A real connection/list check passed, but it reported **no installed models**. No download, real inference or paid/cloud request occurred. Preservation tests and inspected HTTP payloads do not prove arbitrary-model comprehension.

## UI, review and release boundary

GUI preflight reported `screen_locked=true` with `loginwindow` active. No UI runner or development App was launched. The [UI preflight skill](/Users/rudin_yu/.codex/skills/macos-ui-test-preflight/SKILL.md) explicitly requires: “Do not start or retry the UI tests.” Visible UI operation remains unverified.

Read-only Codex self-review covered the full changed scope and relevant call sites, including final draft/completion handling and the Local autonomous-role guard. No remaining P0/P1/P2 finding was identified. No nested Codex process or separate reviewer ran.

The existing 0.9.0 build 8 App still passes strict signature verification. Its notarized ZIP retains SHA-256 `f6a2e6576f82e01972a61a0bba5d7b63b3020461dce94fbff30855fcc95bba7c`; the development package did not replace it.

Remaining acceptance: run an installed model against the protected-fact/correction scenarios; exercise setup, streaming, cancellation and switching in an unlocked App; sign/notarize only when separately requested. Source commits and GitHub delivery are separate from release publication.
