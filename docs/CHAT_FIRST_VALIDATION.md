# Chat-first validation — 0.9.0 development build 8

[Traditional Chinese](CHAT_FIRST_VALIDATION.zh-TW.md)

Validated on the local Apple Silicon Mac on 2026-11-02. This record describes development verification before the separately authorized 0.9.0 signing and notarization workflow; Apple acceptance does not replace the GUI acceptance checks below.

## Build and automated checks

- `.codex/ci.sh` passed: 183 XCTest tests, zero failures. Core, CLI and App debug builds passed. The full suite took about 684 seconds.
- The focused discussion and workspace-root suite passed 22 tests, including subscription-only operation under a saved API setting, account-scoped usage limits, source/destination sharing consent, cancellation, stale-run recovery, chronological context, explicit empty-context transfer, digest/consent/HEAD invalidation, untouched existing repositories and data-root migration.
- `./scripts/package-app.sh --app-name AgentBridge-0.9.0-dev.app` passed, including the final App localization changes. Release CLI/App compilation and the bundle property-list check passed.
- Swift parsing, both localization property lists, matching localization keys, shell/Python syntax, changed-document links and `git diff --check` passed.

SwiftPM could not start its manifest sandbox in the restricted context. The same project-local toolchain/cache validation succeeded in the permitted host context. No cache deletion, alternate home or approval bypass was used for the builds.

## Actual offline GUI walkthrough

With the desktop unlocked and existing Accessibility/Screen Recording permissions available, the development app was operated through its visible controls using fake provider executables:

1. Opened Chats with no Git project and created a Codex chat.
2. Sent a garden-tracker requirement with the codename “Maple Lantern.”
3. Switched the same chat to a Claude account and sent a follow-up. The private fake-provider prompt log contained the approved Codex context.
4. Reviewed the destination, selected turns, exact payload and SHA-256 digest, then explicitly created a local Git project.
5. Confirmed the project showed two shared-memory turns and sent a project follow-up. Its fake-provider prompt included the earlier codename and discussion.
6. Reopened the original discussion and confirmed its two turns remained available.

The fixture repository had an empty initial tree, clean status and no remote. No existing user repository was used for this walkthrough. No real model, API credits or provider credentials were used.

This walkthrough preceded the final chronology and immediate-cancellation display fixes. Those changes passed the focused/full automated checks and final Release compilation, respectively. A final additional GUI cancellation run was **not started** because the desktop was locked at preflight. Immediate Cancel visibility and interaction on the final bundle therefore remain a GUI acceptance gap; Core cancellation has automated coverage.

## Fixture isolation and review

The first walkthrough exposed that macOS UserDefaults still shared the original bundle's preference domain despite a private data home. Its test-only account preference was identified by the exact fixture UUIDs, and the original Traditional Chinese language preference was restored. The fixture generator now copies the development app and gives the copy a unique bundle identifier before launch, leaves `HOME` untouched, and supports a bounded offline Codex response delay. The corrected fixture was generated and bootstrapped; it was not launched after the locked-screen preflight.

Current-task read-only self-review covered tracked/untracked Core, App, CLI, tests, packaging, fixture and documentation changes plus related call sites. The chronology, obsolete-preview capacity, immediate-running display, version footer and localization findings were fixed. No remaining blocking findings were identified. No separate native reviewer or nested Codex process ran.

The signed 0.8.0 build 7 bundle was preserved. Its notarized delivery ZIP still has SHA-256 `71b30ee8c76132014adf02330ccf4c95ba3957d163983942b8d19b00b57fb445`. At the end of this development-verification stage, 0.9.0 had not yet been committed, pushed, signed or notarized. Subsequent release actions are recorded separately in the delivery notes.
