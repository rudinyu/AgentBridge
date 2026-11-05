# AgentBridge

[繁體中文](README.zh-TW.md)

![AgentBridge macOS app icon](Assets/AppIcon-1024.png)

AgentBridge 0.11.1 is a Swift project for macOS 14 and later. It includes a shared core, the `agentbridge` command-line tool, and a native SwiftUI app. It works through the official Codex CLI and Claude Code CLI installed on the Mac. Read-only conversations from the app and CLI can share memory by source repository and pinned commit; users can explicitly carry selected memory to a different commit. A first-use setup wizard guides language, provider, workspace folder, CLI path, subscription login, shared memory, and local usage settings; open it again from **Setup Wizard** in the app header. The CLI uses the same saved workspace root. The app defaults to English and supports Traditional Chinese.

AgentBridge uses each official CLI's subscription login by default. Codex is subscription-only. Claude API is an optional paid mode that requires an API key, a per-run USD budget, and explicit confirmation every time. The local US$140 monthly ledger is not a hard limit on Anthropic's billing.

Start with **New Chat** to discuss an idea without a Git repository. When ready, create or link a project after reviewing the context handoff. Discussions retain their own transcript and account consent; see [Chat-first Workflow](docs/CHAT_FIRST_WORKFLOW.md).

## Documentation

- [Local Models and Readable Context Compression](docs/LOCAL_MODELS_AND_CONTEXT.md) · [繁體中文](docs/LOCAL_MODELS_AND_CONTEXT.zh-TW.md)
- [Architecture and Design](ARCHITECTURE.md) · [繁體中文](ARCHITECTURE.zh-TW.md)
- [Chat-first Workflow](docs/CHAT_FIRST_WORKFLOW.md) · [繁體中文](docs/CHAT_FIRST_WORKFLOW.zh-TW.md)
- [How to Use](docs/HOW_TO_USE.md) · [繁體中文](docs/HOW_TO_USE.zh-TW.md)
- [Product Gap Study](docs/PRODUCT_GAP_STUDY.md) · [繁體中文](docs/PRODUCT_GAP_STUDY.zh-TW.md)
- [Feature Plan](docs/FEATURE_PLAN.md) · [繁體中文](docs/FEATURE_PLAN.zh-TW.md)
- [Autonomous Workflows, Active Extensions and Mac Control](docs/AUTONOMY_AND_EXTENSIONS.md) · [繁體中文](docs/AUTONOMY_AND_EXTENSIONS.zh-TW.md)

## Quick start

Choose **Local** to connect to an existing Ollama or OpenAI-compatible loopback server without a cloud API key. Local supports discussions and read-only project conversations; local edit/tool execution is unavailable. Context compression keeps readable attributed passages and the complete current request, with a preview and a safe refusal when protected content cannot fit. See the [local-model guide](docs/LOCAL_MODELS_AND_CONTEXT.md).

Requirements: macOS 14 or later, Swift 6, and an Xcode toolchain. Install and sign in to the official provider CLI you intend to use; each CLI manages its own login. The app's embedded terminal uses the pinned SwiftTerm 1.20.0 dependency. See [LICENSES/SwiftTerm-LICENSE.txt](LICENSES/SwiftTerm-LICENSE.txt) for its license.

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh --app-name AgentBridge-0.11.1-dev.app
open build/AgentBridge-0.11.1-dev.app
```

`.codex/ci.sh` builds the CLI and app and runs the core tests. `scripts/package-app.sh --app-name AgentBridge-0.11.1-dev.app` bundles the icon into a separate unsigned development app and keeps the signed 0.9.0 release separate. The script default still creates `build/AgentBridge.app`. For distribution, sign with Developer ID, submit it to Apple for notarization, staple the ticket, and verify the app; see the [How to Use guide](docs/HOW_TO_USE.md). Building and checking do not require provider login, call a model, or incur Claude API charges. The CLI is at `build/swiftpm/debug/agentbridge`.

### Default boundaries

- Read-only remains the default. Isolated-change sessions use a detached workspace snapshot, require a reviewed and explicitly approved plan before writing, and keep all provider edits inside that session workspace.
- Review full file diffs, restore individual files, or export a patch. Accept/apply requires successful verification of the exact current diff. Applying creates an uncommitted worktree on a named local branch after checking the source base commit; AgentBridge never commits, pushes, or merges.
- Verification runs only after the user starts it. The default is the repository's `.codex/ci.sh`; a custom executable and its separate argv must be explicitly approved. Verification is isolated to the session workspace and reports the command, exit code, duration, and redacted output.
- The activity timeline and task board show ordered, redacted events and launched run records across sessions. Up to three different sessions can run concurrently; cancellation targets a session.
- Codex and Claude can share AgentBridge App/CLI memory for the same repository and commit. Carry-forward to a different commit is an explicit selection of App-owned turns and/or notes, bound to an account that permits shared memory. Native TUI transcripts are not imported.
- Autonomous workflows generate a task graph for review, then execute the digest-approved plan with explicit account bindings, at most three concurrent agents, bounded review/repair and cancellation. Results remain isolated for manual acceptance and apply. Autonomous mode uses subscriptions only.
- Legacy Skills/MCP descriptors remain inert metadata. Active Skill instruction snapshots and local stdio MCP configurations require separate execution approval for the project, provider and account. An MCP proxy enforces the exact tool list. No automatic installation or Skill scripts are supported.
- Mac Control uses a target-bound proxy with separate Observe and Control consent and a Stop Control action. Screenshots include the entire main display and may be sent to the selected provider. macOS permissions must be granted manually; desktop control is an explicit additional capability beyond repository access.
- The local terminal runs with the current macOS user's permissions. A Git workspace is not an operating-system sandbox.

## Checking provider subscription usage

From the subscription usage dashboard, open the official CLI usage terminal for the selected Codex or Claude account. Wait until that account's CLI is ready and signed in, then use the terminal's fixed Send /usage button. The button sends only /usage followed by Enter; it does not accept command text. API mode does not offer this action.

AgentBridge starts the official interactive TUI in a fresh private empty temporary directory, applies read-only restrictions, and routes the process through the selected account's existing or dedicated CLI configuration. After you press the fixed /usage button, the app copies only a bounded amount of visible screen text into memory and uses a provider-aware best-effort parser to fill a unified card. Sampling ends after usage values are recognized or 15 seconds; another fixed button press can re-arm it. Unknown fields show “Not provided / 未提供”; the original TUI stays visible for verification. This screen reading depends on provider wording and is not a stable API. AgentBridge does not persist or log the captured text or send it to a model. The temporary directory is removed when the CLI exits; Claude's usage-only launch also disables prompt-history and session-transcript writes.

## License

Copyright (c) 2026 rudin. AgentBridge is licensed under the [MIT License](LICENSE).

Distributed App bundles include `AgentBridge-LICENSE.txt` and the separate [SwiftTerm license](LICENSES/SwiftTerm-LICENSE.txt). Third-party components retain their own copyright and license notices. Codex, Claude Code and local model services are separate products governed by their respective terms.

## Official CLI references

- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive) · [authentication](https://developers.openai.com/codex/auth) · [configuration](https://developers.openai.com/codex/config-reference)
- [Codex CLI](https://developers.openai.com/codex/cli)
- [Claude Code headless mode](https://code.claude.com/docs/en/headless) · [CLI reference](https://code.claude.com/docs/en/cli-reference) · [authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code slash commands](https://code.claude.com/docs/en/commands)
- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0)
