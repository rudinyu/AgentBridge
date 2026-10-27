# AgentBridge: How to Use

[繁體中文](HOW_TO_USE.zh-TW.md)

This guide covers setup, sign-in, starting conversations, switching providers and accounts, shared memory, and enabling Claude API when needed. The app and CLI share local settings, sessions, memory, and the API budget ledger.

### 1. Set up and launch the app

Requirements: macOS 14 or later, Swift 6, and an Xcode toolchain. Install the official CLI you plan to use and sign in to its subscription account:

- Codex CLI: [official installation and sign-in guide](https://developers.openai.com/codex/cli)
- Claude Code: [official installation guide](https://code.claude.com/docs/en/quickstart)

Run these commands from the AgentBridge repository:

`Assets/AppIcon-1024.png` is the source app icon. Packaging converts it to a macOS `.icns` and bundles it in the app.

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh
open build/AgentBridge.app
```

The CI script builds the CLI and app and runs core tests. The packaging script creates an unsigned local app. These steps do not sign in to a provider, call a model, or incur Claude API charges. If you have already built the app, open `build/AgentBridge.app` again. To distribute it to other Macs, complete the Developer ID signing and Apple notarization steps at the end of this guide.

### 2. Check CLI sign-in and plan

The app's controls are currently displayed in Traditional Chinese. In this guide, each UI control is shown as “Chinese label” (English meaning). When the app opens, choose Codex or Claude under “助理” (Assistant), then click “檢查登入與方案” (Check login and plan) in the upper-right corner. The app displays only account and plan fields confirmed by the official CLI. If the Codex CLI does not report a plan name, AgentBridge does not guess one.

You can also check the environment and sign-in status from the CLI:

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" doctor
"$CLI" profiles list
```

If a CLI cannot be found, enter its executable path in “CLI 執行檔” (CLI Executables), or set it with `agentbridge settings binary codex|claude /absolute/path/to/cli`. The official CLI manages its own login data; AgentBridge does not copy existing credentials.

### 3. Start a read-only App conversation

1. Choose Codex or Claude under “助理” (Assistant). Codex only offers official CLI subscription login.
2. Confirm the account under “官方 CLI 帳戶” (Official CLI Accounts). To use another account, add and sign in to it first as described below.
3. Enter the Git repository path under “專案” (Project), or click “選擇儲存庫…” (Choose Repository…).
4. Leave “互動終端工作階段” (Interactive terminal session) off and click “建立同一專案的新工作階段” (Create a new session for this project). This creates a read-only chat session.
5. Enter a prompt on the right and click “傳送” (Send). A successfully completed turn is saved to shared memory for this repository and pinned commit.

Each session pins the source `HEAD` at creation and runs in an isolated clone owned by AgentBridge. Uncommitted and untracked files are not copied. If the source commit later changes, an existing session keeps its original snapshot. A new session uses the new source commit and a separate memory scope. AgentBridge does not merge or push workspace changes automatically.

### 4. Add accounts, sign in, and switch plans

Adding an account does not sign in again to or change the current local account:

1. Enter a display name under “官方 CLI 帳戶” (Official CLI Accounts). “建立後允許共用專案記憶” (Allow sharing project memory after creation) is checked by default. Clear it first if this account should not load or save project memory, then click “新增並切換帳戶” (Add and switch account).
2. Under the new account, click “在 App 內登入此帳戶” (Sign in to this account in the app) and complete the provider's official sign-in flow in the embedded terminal.
3. After sign-in, click “檢查登入與方案” (Check login and plan). The app shows the account and plan information reported by the official CLI.
4. New sessions are bound to the selected account when created. To switch accounts, select the other account and create or switch to a session bound to it.

The built-in “Current local login” profile uses the existing official CLI login. Each new account has a separate CLI configuration directory and must be signed in separately. Changing the selected account does not change the account bound to an existing session; select the original account to continue that session.

CLI account commands:

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" profiles create --provider claude --name work
"$CLI" profiles list claude
# Use the PROFILE_ID shown in the output to sign in in an interactive terminal:
"$CLI" profile-login PROFILE_ID
"$CLI" profiles select --provider claude PROFILE_ID
```

New accounts are allowed to use shared memory by default. To stop sharing for an account, clear “允許此帳戶載入與保存專案共用記憶” (Allow this account to load and save project memory) in the app or run `agentbridge profiles memory PROFILE_ID off`. This stops that account from automatically loading or saving turns, but does not delete existing memory. Updating the app does not change existing accounts' saved preference.

### 5. Switch between Codex and Claude with shared memory

Shared memory is scoped by source repository path and pinned commit. Successful read-only conversations from the app or CLI are added when the account allows sharing. When you switch from Codex to Claude or back, both can use the same completed App/CLI conversations and notes if the sessions use the same source path and commit. New accounts share memory by default; sharing can be disabled per account.

Use “專案共用記憶” (Project Shared Memory) to review chat turns. Open “記憶備註與終端機交接” (Memory Notes and Terminal Handoff) to save material for another assistant. Successful read-only App and CLI turns are added automatically when the account has consented. Native Codex and Claude TUI input and output are not captured; write any handoff details you need into the notes yourself. Clearing memory deletes chat memory and notes for that source and pinned commit. It does not delete provider-owned session data.

### 6. Use the native interactive terminal

To use the native interactive Codex or Claude interface:

1. Make sure subscription login is selected. Claude API mode does not support the interactive terminal.
2. Enable “互動終端工作階段” (Interactive terminal session) and create the session.
3. Click “開啟內嵌終端機” (Open embedded terminal) and enter prompts and control the next steps in the provider TUI.

This differs from the read-only chat on the right. Codex interactive sessions keep the read-only sandbox. Claude uses its native Manual permission flow; a user-approved action may change the isolated clone, read files outside the workspace, or access the network. Terminal transcripts stay in the current screen and are not written to AgentBridge memory or audit logs.

The upper-right “本機終端機” (Local Terminal) action opens a shell at the repository clone, but it runs with the current macOS user's permissions and may access files outside the clone or use the network. The Git clone is not an operating-system sandbox.

### 7. Usage dashboard and local run limits

The Usage panel is scoped to the selected provider and account profile. In subscription mode it charts AgentBridge-recorded managed run attempts for rolling 5-hour, 24-hour, and 7-day windows. These are local estimates, not provider quota or account-wide use; provider limits and sharing rules vary, and activity in other provider apps is not included. Interactive TUI turns are not recorded.

AgentBridge cannot read official subscription quota percentages. To check manually, open the provider's official interactive CLI and enter `/usage`: Codex CLI shows daily, weekly, and cumulative activity; Claude CLI shows session cost, plan usage limits, and activity statistics. AgentBridge does not parse terminal output or private provider endpoints.

Optional local run-count caps can be set for subscription runs over 5 hours, 24 hours, 7 days, and the current AgentBridge work session. Claude API has separate optional UTC-day and work-session USD caps, 24-hour and work-session run-count caps, and a switch that blocks future API runs for the selected account. The per-run USD budget, daily/session USD caps, monthly USD ledger, and run-count caps are distinct controls. A call reserves twice its per-run amount against configured USD caps before launch. Only one paid call may remain unresolved across the app and CLI.

If a completed or interrupted API call has no confirmed cost, the account remains blocked. To recover it, compare the specific Claude API session with the Anthropic bill, then select that bound account and session in the App's manual settlement panel, enter the bill's actual USD amount, and confirm. The CLI also supports `agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm`. Settlement does not contact the provider and records a secret-free audit event. Settlement first acquires the session's run lock: an active process is rejected, while a stale `running` status left by an interruption is marked failed and can then be settled. Settlement is safe to retry with the same amount if one local ledger finished before another. Never enter zero unless the provider bill confirms zero. A conflicting prior settlement is rejected. Historical unresolved entries that cannot be attributed to an account remain blocked rather than being assigned to the wrong profile.

Thresholds at 50%, 75%, 90%, and 100% appear in the app and are persisted per account and alert period; 100% indicates a configured local cap is reached and new managed runs are blocked. Changes to local limits and notification settings, plus threshold crossings, are kept in a bounded local audit history. macOS notifications are optional and require notification permission. The local windows are not the provider's quota windows.

### 8. Optional Claude API and budget controls

Subscription login is the default and does not need an API key. Claude API mode appears only when Claude is selected. Every API run requires an API key, a per-run USD budget, and a checked payment confirmation. Cancelling a run cannot reverse charges already accrued. Codex has no API mode. The app does not save the API key; switching providers or modes clears the current authorization fields. API mode is for read-only chat, not the native interactive terminal.

The built-in Claude profile retains the existing US$140-per-UTC-month local ledger, shared by the app and CLI. Its older entries do not identify an account, so historical spend cannot be split reliably among accounts. Each new Claude profile has a separate ledger and must have a local monthly USD cap configured in the app before API runs are allowed; after the ledger is created, its monthly cap is fixed so changing it cannot reset existing spend. Before each call, the ledger reserves twice the requested per-run budget to account for concurrent calls and unknown cost; a call is rejected when that reservation exceeds the available balance. Claude CLI's `--max-budget-usd` uses cost estimates and does not guarantee that the actual charge stays below the entered amount. Local ledgers do not count Anthropic usage outside AgentBridge and do not replace the Anthropic bill or provider-side spending limits.

For CLI API use, make `ANTHROPIC_API_KEY` available to the CLI process through a secure method; do not put the key in command-line arguments, documentation, or version-controlled files. Then explicitly change modes, create a Claude session, and supply a budget and confirmation flag for every call:

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" settings usage api
"$CLI" session create --provider claude --repo "$HOME/Projects/example"
# Set this to the session ID printed by the previous command:
SESSION_ID="paste-session-id-here"
printf '%s' 'Summarize the repository architecture.' | \
  "$CLI" run "$SESSION_ID" --api-budget 1.00 \
  --confirm-api-spend --api-key-env ANTHROPIC_API_KEY
"$CLI" budget
```

To return to subscription login, run `"$CLI" settings usage subscription`, then create or switch back to a subscription session. API mode cannot resume a subscription session that already has a provider session. The ledger only counts AgentBridge API calls; the provider's actual charges and Anthropic Console limits are authoritative.

### 9. Common CLI operations

After building, the CLI is at `build/swiftpm/debug/agentbridge`. Prompts are read from standard input rather than placed in process arguments:

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" doctor
"$CLI" session create --provider codex --repo "$HOME/Projects/example"
"$CLI" sessions
# Paste the ID printed for the new session here:
SESSION_ID="paste-session-id-here"
printf '%s' 'Summarize the repository architecture.' | "$CLI" run "$SESSION_ID"
"$CLI" events "$SESSION_ID"
"$CLI" memory show "$SESSION_ID"
printf '%s' 'Key decisions and next steps.' | "$CLI" memory notes "$SESSION_ID"
```

The CLI also supports `agentbridge cancel SESSION_ID` to cancel a run, `agentbridge budget` to view the API ledger, and `agentbridge help` to show all commands. Clearing shared memory requires explicit confirmation: `agentbridge memory clear SESSION_ID --confirm`.

### 10. Troubleshooting

- **Provider CLI not found:** Set its path in “CLI 執行檔” (CLI Executables), or add the official CLI to a path visible to the login environment, then click “檢查登入與方案” (Check login and plan).
- **Not signed in or plan not confirmed:** Complete subscription login in the provider's official CLI. For a new account, use AgentBridge's login terminal, then check again.
- **An existing session does not run after switching accounts:** A session is bound to the account used at creation. Switch back to that account or create a session under the selected account.
- **A new commit does not show older memory:** Memory is isolated by pinned commit. Confirm both sessions use the same repository path and commit.
- **API run is rejected or a reservation is not returned:** Check `agentbridge budget` or the UTC monthly balance shown in the app. Unknown, failed, or cancelled charges are not treated as free and the reservation is retained.
- **Workspace differs from the source repository:** This is the snapshot boundary. Source changes made after session creation are not copied into that workspace automatically.

### 11. Sign, notarize, and verify the app

`scripts/package-app.sh` rebuilds an unsigned development app. After preparing a release and passing `.codex/ci.sh`, use the shared `macos-notarization-release` helper for signing and notarization. It reads Apple notarization authentication from user-level configuration (a Keychain profile or App Store Connect API key), separate from the Claude API key. Do not place signing credentials or Apple's `.p8` private key in the repository. The app identity must be a Developer ID Application certificate. Sign the embedded `agentbridge` helper before signing the outer app bundle.

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
TOOL="$HOME/.codex/skills/macos-notarization-release/scripts/macos_notarization.py"
APP="$PWD/build/AgentBridge.app"
# Replace with the full identity label of the Developer ID Application certificate in Keychain.
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
AUTH_KIND="$(python3 "$TOOL" resolve-auth --project-root "$PWD")"

python3 "$TOOL" sign "$APP/Contents/Helpers/agentbridge" \
  --identity "$SIGNING_IDENTITY" --authorized
python3 "$TOOL" sign "$APP" --identity "$SIGNING_IDENTITY" --authorized
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" "$PWD/build/AgentBridge-notarization-upload.zip"
python3 "$TOOL" submit "$PWD/build/AgentBridge-notarization-upload.zip" \
  --authorized --wait --timeout 30m --auth "$AUTH_KIND" --project-root "$PWD"
python3 "$TOOL" staple "$APP"
python3 "$TOOL" verify "$APP"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" "$PWD/build/AgentBridge-notarized.zip"
```

The upload ZIP is the submission carrier. After Apple accepts it, the ticket is stapled to the `.app`, then a delivery ZIP is made from the stapled app. Verification covers the signature, Gatekeeper, and ticket. If the helper reports a timeout or unknown result, do not resubmit the same artifact automatically; resolve that submission using Apple's submission ID. `doctor` checks local configuration only and does not mean Apple has accepted the notarization. Running `package-app.sh` again replaces the app and removes its signature, so it must be signed and notarized again.

For the implementation boundaries and component design, see [Architecture and Design](../ARCHITECTURE.md).
