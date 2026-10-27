# AgentBridge Architecture and Design

[繁體中文](ARCHITECTURE.zh-TW.md)

```mermaid
flowchart LR
    App[SwiftUI App] --> Core[AgentBridgeCore]
    CLI[agentbridge CLI] --> Core
    Core --> Runner[SafeProcessRunner]
    Runner --> Codex[Codex CLI]
    Runner --> Claude[Claude Code CLI]
    Core --> Git[WorkspaceManager isolated Git clone]
    Core --> Stores[(Private local stores)]
    Stores --> Sessions[Sessions and audit events]
    Stores --> Memory[Shared App and CLI memory]
    Stores --> Ledger[Account-scoped Claude API ledgers]
    Stores --> Usage[Local usage controls and alert history]
    App --> Terminal[SwiftTerm embedded PTY]
    Terminal --> Codex
    Terminal --> Claude
```

The provider CLIs, SwiftTerm, and AgentBridgeCore in this diagram run on the user’s Mac. Shared memory, audit records, usage controls, and API ledgers stay local; model requests go to the selected provider through its official CLI.

### Purpose and implementation

AgentBridge 0.3.0 is a standalone SwiftPM repository with a shared `AgentBridgeCore`, the `agentbridge` CLI, and a native SwiftUI app. The app and CLI use the same settings, account profiles, sessions, access policies, workspaces, memory, audit store, usage controls, and API ledgers. The embedded terminal uses SwiftTerm 1.20.0. `scripts/package-app.sh` assembles the release bundle, so the project does not maintain a second Xcode project configuration.

Provider execution goes through the official CLIs installed locally: Codex uses `codex exec --json` or its native interactive CLI; Claude Code uses `claude -p --output-format stream-json` or its native interactive CLI. AgentBridge does not export or copy OAuth credentials and does not treat a provider session ID as cross-provider memory. It manages local processes in Swift and does not add a Codex or Claude SDK runtime.

### App icon design

![AgentBridge macOS app icon](Assets/AppIcon-1024.png)

The deep-indigo icon links two distinct assistant nodes with a luminous bridge arc, representing shared project context between Codex and Claude. The 1024×1024 PNG is the source asset; the packaging script generates a macOS `.icns` and places it in the app bundle.

Official CLI options and authentication behavior can change. The official references and the locally checked CLI versions are listed in the README. Event parsing fails closed: an unknown login method, malformed event stream, or missing success event is not treated as success. Before running the app, confirm that the installed CLI versions still support the options used by the current implementation.

### Component responsibilities

| Component | Responsibility |
| --- | --- |
| `Models` | Provider, settings, account, session, access policy, event, and error types |
| `SafeProcessRunner` | Launches an executable with argv; bounds I/O; manages process groups, timeouts, cancellation, and PTY foreground handoff |
| `ProviderAdapters` | Builds provider arguments and environments, identifies login modes, parses events, and reads reported provider costs |
| `WorkspaceManager` | Creates an isolated detached Git clone, removes its remote, disables Git hooks, and verifies the pinned commit |
| `AuditStore` | Private settings and session/event JSONL, cross-process file locks, one-run leases, and cancellation markers |
| `AccountProfileStore` | Provider account labels, selected profile, isolated CLI configuration directories, and per-account memory consent |
| `SharedMemoryStore` | Stores cross-provider App/CLI read-only turns and user notes by canonical repository path and pinned commit |
| `BudgetLedger` | Per-profile Claude API monthly limits, conservative reservations, and settlement; the built-in profile keeps the legacy US$140 ledger |
| `UsageControlStore` / `APICostControlLedger` | Per-account run and optional day/session USD caps, threshold deduplication, bounded settings audit, concurrent-call reservation, and bill-based recovery |
| `OutputRedactor` | Redacts common token formats and the API key supplied for the current run |
| CLI / SwiftUI App | Shared conversation, account switching, memory controls, embedded terminal, and per-run API confirmation |

### Sessions, workspace isolation, and accounts

When creating a session, AgentBridge reads the source repository's committed state, creates an isolated clone, checks out a detached commit, and records the full commit hash. Switching between Codex and Claude or between account profiles creates or reuses a session for the same source path and pinned commit. Later changes to the source `HEAD` do not silently change an existing session's scope. Uncommitted and untracked files are not copied.

Each session is bound to the provider account selected at creation. Switching the selected account does not change the account used by an existing session; return to that account or create another session. Each provider has a built-in profile for the current local login, plus optional isolated profiles. A custom profile receives its own `CODEX_HOME` or `CLAUDE_CONFIG_DIR`. The official CLI creates and reads credentials; AgentBridge does not parse or copy them. The built-in profile has no relogin action, to avoid changing the existing login.

Account and plan details come only from fields reported by the official CLI. Claude CLI can report its login account and subscription plan. If the Codex CLI does not report a plan name, the app shows the verified login status without guessing a plan. Users complete sign-in for additional profiles through the official CLI's interactive login flow.

### Shared memory

A successful non-interactive read-only run from the app or CLI is stored in shared memory only after the provider run succeeds. The app and CLI use the same private data directory. Memory is scoped by the canonical repository path and the commit pinned when the session was created, so Codex and Claude can use the same memory for the same repository snapshot. A different source path or commit has a separate memory scope. Stored content includes the explicitly submitted prompt, successful response, and user notes. It is redacted and bounded by Unicode-safe truncation, size, and turn-count limits before being written to owner-only files.

Built-in and newly created account profiles allow shared memory by default. Users can turn it off for each account; doing so preserves prior memory but stops that account from automatically loading or saving turns. Existing profiles retain their stored consent setting when the app is updated. Users can view or clear stored memory in the app.

Each provider CLI controls whether its native TUI transcript is persisted. AgentBridge does not capture general TUI screens or parse provider session files. The separate subscription-usage parser is described below. At interactive-session startup, if the profile allows memory and memory exists, AgentBridge supplies it through a private, temporary context file and removes that file when the process ends. Text entered in the TUI is not written back automatically; users can save handoff notes manually. Memory is treated as historical context and is instructed not to override provider policies, access rules, or payment rules.

### Process safety and access boundaries

Non-interactive commands launch an executable with a separate argv array; they do not build a shell command string. Prompts go over standard input. Child processes receive an allowlisted environment rather than inheriting API keys, proxy settings, or cloud credentials by default. Output and error buffers are bounded, and raw provider stderr is not written to the audit log. Runs use a per-session lease, cancellation marker, process-group termination, and bounded termination escalation. CLI SIGINT, SIGTERM, and SIGHUP are also converted into cancellation.

Non-interactive Codex uses a read-only sandbox and never requests elevated approval. Non-interactive Claude is restricted to `Read,Glob,Grep`, with hooks and MCP disabled, and uses `dontAsk`. Native interactive mode retains each provider TUI: Codex stays in its read-only sandbox, while Claude uses Manual permission mode. A Claude command approved by the user may edit the isolated clone, access files outside the workspace, or use the network. The clone is a workflow boundary, not a macOS sandbox.

The embedded terminal connects a PTY directly to the official CLI and does not save raw terminal input or screen output. Only after the fixed `/usage` action, the app copies a bounded number of visible SwiftTerm rows into memory for best-effort parsing; sampling stops when usage values are recognized or after 15 seconds, and another fixed action can re-arm it. The app discards that raw text after producing the normalized report and never logs, persists, or sends it to a model. SwiftTerm OSC 52 clipboard access and terminal link opening are disabled, and scrollback is bounded. The separate local-terminal action starts the user's shell with the current macOS account's permissions; the repository clone does not restrict its filesystem or network access.

Git cloning disables hooks, fsmonitor, untracked cache, and LFS smudge, removes `origin`, and uses a private Git configuration directory. Uncommitted content, LFS object material, and submodules not initialized separately are not guaranteed to be part of a complete snapshot. AgentBridge does not commit, push, merge, or clean the source repository automatically.

### Claude API budget and authorization

The default is subscription login through the official CLI. Claude API is an explicit paid path. Every run requires an API key, a per-run USD budget, and explicit authorization. The Codex UI has no Claude API controls; switching to Codex forces subscription mode. The built-in Claude profile preserves the legacy local US$140 monthly ledger. Each additional Claude profile requires its own monthly cap and ledger; its cap is fixed after the ledger is created so prior spend cannot be reinterpreted. App and CLI share these account-scoped ledgers. Each call reserves twice its requested budget against the monthly and optional UTC-day/session caps before launch, and only one unresolved paid call is allowed across both front ends. The API key is passed only to that run's child process and is not written to settings or audit files.

Claude CLI's `--max-budget-usd` uses client-side cost estimates; it is not a hard cap on the provider bill. AgentBridge uses `total_cost_usd` from a successful response for automatic settlement. If the cost is missing, the run fails, or it is cancelled, the reservation remains instead of assuming that unknown usage was free; the user can reconcile it against the provider bill in the app or CLI, with idempotent retries across the monthly and day/session ledgers. API sessions do not resume subscription sessions, and development checks do not call a model. The local ledger cannot see usage outside AgentBridge; use Anthropic Console spending controls if provider-side limits are needed.

### Usage statistics and alerts

The app charts AgentBridge-managed run attempts by selected account over rolling 5-hour, 24-hour, and 7-day windows, and the selected AgentBridge session. Optional local run-count caps are enforced before managed subscription or API launches. For Claude API, the dashboard separately shows monthly spent/reserved/available amounts and optional UTC-day/session USD caps, plus API run counts. One-time 50%, 75%, 90%, and 100% alerts are deduplicated by account and period; macOS notifications are optional, and threshold crossings are recorded in bounded local audit history. These figures count only AgentBridge-managed attempts and charges.

Codex and Claude do not expose the provider's subscription quota percentages and reset windows through a stable machine-readable source used by this app. The dashboard directs users to the official CLI `/usage` screen, then can show recognized fields in a unified best-effort card. It matches provider-specific usage-window wording and only reads percentages inside recognized usage sections; unknown fields show “Not provided / 未提供.” This parser is not a stable API, and the visible TUI remains the source of truth. Native interactive TUI turns are neither counted nor capped.

The subscription usage dashboard can open the selected account's official interactive CLI through the embedded PTY. The CLI helper rechecks subscription authentication for that exact profile, applies its existing CODEX_HOME or CLAUDE_CONFIG_DIR, and launches in a newly created private empty temporary working directory that is removed when the process exits. Codex starts with its read-only sandbox, no approval prompts, and optional integrations disabled. Claude starts in restricted Plan mode with no built-in tools, hooks, or MCP servers; it forces claude.ai authentication, sets CLAUDE_CODE_SKIP_PROMPT_HISTORY=1, and passes --no-session-persistence. The launch supplies no model prompt or non-interactive command. After the user sees the CLI prompt and completes sign-in if needed, a separate fixed UI action sends /usage followed by Enter. API mode hides the action and the core rejects it. API key variables are excluded from the child environment. The normalizer returns only the provider, selected account, recognized plan/window percentages/reset text, source, status, and capture time; unrecognized values stay nil. It does not claim structured quota values or make API/SDK/model calls.

### Local data and remaining limitations

App and CLI data live under `~/Library/Application Support/AgentBridge`, protected with private directory permissions and file locks. Redaction is best effort and cannot recognize every unknown secret format. Provider CLIs may save their own login, session, or cache data according to their own behavior. The same macOS user can manually alter local settings, usage controls, and ledgers, so this tool is not intended as a multi-user or remote untrusted service.

### Build and acceptance boundary

The packaging script converts `Assets/AppIcon-1024.png` into the standard macOS iconset, writes `Contents/Resources/AgentBridge.icns`, and sets the app icon key in Info.plist.

`.codex/ci.sh` is the primary local validation entry point and builds the CLI/app and runs core tests. `scripts/package-app.sh` creates an unsigned Release `.app` with the CLI helper, SwiftTerm resources, and license. For distribution, use a Developer ID Application certificate, sign the embedded helper first and then the `.app`, submit it to Apple for notarization, staple the ticket, and verify it. SwiftPM state, module caches, and DerivedData live under the repository's `build/` directory. If SwiftPM's default Metal shader backend cannot build SwiftTerm with the installed Xcode toolchain, the project scripts use SwiftPM's native backend, which is currently deprecated. Recheck toolchain compatibility before upgrading Xcode or SwiftTerm.

Tests use mock CLIs, temporary Git repositories, and local processes; they do not require an API key, provider login, or paid calls. Passing automated checks does not verify live provider execution, additional-account sign-in, Anthropic billing, or GUI operation. Report those as separate acceptance results. See the [README](README.md) for official CLI references and the [How to Use guide](docs/HOW_TO_USE.md) for operator steps.
