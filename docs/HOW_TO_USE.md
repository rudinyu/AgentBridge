# AgentBridge: How to Use

[Traditional Chinese](HOW_TO_USE.zh-TW.md)

This guide covers setup, sign-in, project-independent discussions, creating/linking projects, switching providers and accounts, shared memory, and enabling Claude API when needed. The app and CLI share a saved user-selected workspace data folder, while private settings, account profiles, session/audit metadata, and usage/budget ledgers stay in Application Support.

### 1. Set up and launch the app

Requirements: macOS 14 or later, Swift 6, and an Xcode toolchain. For full provider readiness, install the official CLI you plan to use and sign in to its subscription account:

- Codex CLI: [official installation and sign-in guide](https://developers.openai.com/codex/cli)
- Claude Code: [official installation guide](https://code.claude.com/docs/en/quickstart)

Run these commands from the AgentBridge repository:

`Assets/AppIcon-1024.png` is the source app icon. Packaging converts it to a macOS `.icns` and bundles it in the app.

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh --app-name AgentBridge-0.11.2-dev.app
open build/AgentBridge-0.11.2-dev.app
```

The CI script builds the CLI and app and runs core tests. The packaging script creates an unsigned local app. These steps do not sign in to a provider, call a model, or incur Claude API charges. If you have already built this development version, open `build/AgentBridge-0.11.2-dev.app` again. To distribute it to other Macs, complete the Developer ID signing and Apple notarization steps at the end of this guide.

The first time the app opens, choose or create a folder for workspace data. AgentBridge requires this selection before it can create sessions; it does not silently choose a folder under Application Support. The app and CLI use the same saved location. The selected folder contains isolated session workspaces and shared memory:

```text
<your chosen folder>/
  workspaces/<session-id>/   # one isolated Git copy per session
  shared-memory/             # shared App/CLI conversation memory
```

Private app data remains under `~/Library/Application Support/AgentBridge`, including app settings, account-profile data, dedicated provider CLI profile folders (where those CLIs store their profile credentials), session and audit records, and usage/budget ledgers. Built-in accounts continue to use the provider CLI's existing login folders. To change the selected folder in the app later, click **Change…** beside **Data root** in the **Project** panel. From the CLI, run `agentbridge workspace set /absolute/path/to/folder`; use `agentbridge workspace show` to see the saved folder. The CLI gives this setup command as an actionable error if no folder has been selected.

Changing the selected folder copies existing workspace folders and shared memory to the new location, then updates existing session records to use those copies. The original folders and files remain intact; new sessions use the newly selected folder. If a destination already contains different data for an existing workspace or memory file, AgentBridge stops and reports the conflict without overwriting either copy. Changing the folder does not change shared-memory identity: memory remains scoped by the canonical source repository path and the commit pinned for a session.

The setup wizard opens automatically when the app has no usable workspace folder. It walks through language and provider selection, the required data folder, optional CLI discovery or path selection, optional sign-in checking, account memory consent, and local usage settings. The workspace folder is required to continue. Missing CLI installation or unconfirmed sign-in can be skipped; the final review reports both clearly. The wizard does not install software, run a provider task, send a model request, or configure an API key. Saving account or default settings can prepare a local session. Sign-in and status checks start the official CLI only after you click those controls. Subscription login is the setup default. If you quit before finishing, the wizard resumes on the next launch. Existing installations with a usable folder are not interrupted; click **Setup Wizard** in the header to reopen it. Reopening keeps saved provider settings and existing memory consent unchanged unless you explicitly save a change.

### 2. Choose a language and check CLI sign-in

For Local models, use the local backend and model controls instead of CLI sign-in. Start your existing server, configure its loopback endpoint, refresh models and select a model. Context and output limits determine the conservative input budget; **Context preview** shows the exact prepared history and any refusal. See [Local Models and Context](LOCAL_MODELS_AND_CONTEXT.md) for the supported scope.

Fresh installs use English. Choose **English** or **Traditional Chinese** in the setup wizard or from the app header; the selection is saved and takes effect immediately. For an explicit sign-in check, choose Codex or Claude under **Assistant**, then click **Check Sign-in and Plan** in the upper-right corner. The app displays only account and plan fields confirmed by the official CLI. If the Codex CLI does not report a plan name, AgentBridge does not guess one.

You can also check the environment and sign-in status from the CLI:

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" doctor
"$CLI" profiles list
```

If a CLI cannot be found, enter its executable path under **CLI Executables**, or set it with `agentbridge settings binary codex|claude /absolute/path/to/cli`. The official CLI manages its own login data; AgentBridge does not copy existing credentials.

### 3. Start with a discussion, before Git

Open **Chats** and choose **New Chat**. Select a provider/account and send the first message; no repository is required. Discussion chats always use subscription login, keep their own bounded transcript, and apply account sharing consent to future context. When ready, choose **Create Git Project** or **Link Existing Project**, select exactly which completed turns to transfer (including none), inspect the destination and digest, and explicitly confirm. A new local repository starts with an empty commit; transferred context stays in AgentBridge memory. The original chat remains available. See [Chat-first Workflow](CHAT_FIRST_WORKFLOW.md).

### 3a. Open a read-only project conversation

1. Choose Codex or Claude under **Assistant**. Codex only offers official CLI subscription login.
2. Confirm the account under **Official CLI Accounts**. To use another account, add and sign in to it first as described below.
3. Enter the Git repository path under **Project**, or click **Choose Repository…**.
4. Leave **Interactive Terminal Session** off and click **Create a New Session for This Project**. This creates a read-only chat session.
5. Enter a prompt on the right and click **Send**. A successfully completed turn is saved to shared memory for this repository and pinned commit.

Each session pins the source `HEAD` at creation and runs in its own isolated clone under `<chosen folder>/workspaces/<session-id>/`. Uncommitted and untracked files are not copied. If the source commit later changes, an existing session keeps its original snapshot. A new session uses the new source commit and a separate memory scope. AgentBridge does not merge or push workspace changes automatically.

### 4. Add accounts, sign in, and switch plans

Adding an account does not sign in again to or change the current local account:

1. Enter a display name under **Official CLI Accounts**. **Allow shared project memory after creation (on by default)** is checked by default. Clear it first if this account should not load or save project memory, then click **Add and Switch Account**.
2. Under the new account, click **Sign In to This Account in the App** and complete the provider's official sign-in flow in the embedded terminal.
3. After sign-in, click **Check Sign-in and Plan**. The app shows the account and plan information reported by the official CLI.
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

New accounts are allowed to use shared memory by default. To stop sharing for an account, clear **Allow this account to load and save shared project memory** in the app or run `agentbridge profiles memory PROFILE_ID off`. This stops that account from automatically loading or saving turns, but does not delete existing memory. Updating the app does not change existing accounts' saved preference.

### 5. Switch between Codex and Claude with shared memory

Shared memory is stored in `<chosen folder>/shared-memory/` and scoped by canonical source repository path and pinned commit. Its scope does not depend on where the isolated workspace copies are stored. Successful read-only conversations from the app or CLI are added when the account allows sharing. When you switch from Codex to Claude or back, both can use the same completed App/CLI conversations and notes if the sessions use the same source path and commit. New accounts share memory by default; sharing can be disabled per account.

Use **Shared Project Memory** to review chat turns. Open **Memory Notes and Terminal Handoff** to save material for another assistant. Successful read-only App and CLI turns are added automatically when the account has consented. Native Codex and Claude TUI input and output are not captured; write any handoff details you need into the notes yourself. Clearing memory deletes chat memory and notes for that source and pinned commit. It does not delete provider-owned session data.

### 6. Use the native interactive terminal

To use the native interactive Codex or Claude interface:

1. Make sure subscription login is selected. Claude API mode does not support the interactive terminal.
2. Enable **Interactive Terminal Session** and create the session.
3. Click **Open Embedded Terminal** and enter prompts and control the next steps in the provider TUI.

This differs from the read-only chat on the right. Codex interactive sessions keep the read-only sandbox. Claude uses its native Manual permission flow; a user-approved action may change the isolated clone, read files outside the workspace, or access the network. Terminal transcripts stay in the current screen and are not written to AgentBridge memory or audit logs.

The upper-right **Local Terminal** action opens a shell at the repository clone, but it runs with the current macOS user's permissions and may access files outside the clone or use the network. The Git clone is not an operating-system sandbox.

### 7. Usage dashboard and local run limits

The Usage panel is scoped to the selected provider and account profile. In subscription mode it charts AgentBridge-recorded managed run attempts for rolling 5-hour, 24-hour, and 7-day windows. These are local estimates, not provider quota or account-wide use; provider limits and sharing rules vary, and activity in other provider apps is not included. Interactive TUI turns are not recorded.

AgentBridge cannot obtain official subscription quota percentages from a supported machine-readable source. To check them, open the provider's official interactive CLI and use the fixed **Send /usage** action: Codex CLI shows daily, weekly, and cumulative activity; Claude CLI shows session cost, plan usage limits, and activity statistics. After that explicit action, AgentBridge copies a bounded amount of visible screen text into memory and best-effort parses recognized fields into the unified card. Unknown fields show **Not provided**. The visible official TUI remains the source of truth; this screen-text parser is not a stable quota API. AgentBridge does not read other terminal output or access private provider endpoints.

Optional local run-count caps can be set for subscription runs over 5 hours, 24 hours, 7 days, and the current AgentBridge work session. Claude API has separate optional UTC-day and work-session USD caps, 24-hour and work-session run-count caps, and a switch that blocks future API runs for the selected account. The per-run USD budget, daily/session USD caps, monthly USD ledger, and run-count caps are distinct controls. A call reserves twice its per-run amount against configured USD caps before launch; the App and CLI show that amount before the call. A session can make several paid calls, and the work-session USD cap counts all of them. Only one paid call may remain unresolved across the app and CLI.

If a completed or interrupted API call has no confirmed cost, the account remains blocked. To recover it, compare the specific Claude API session with the Anthropic bill, then select that bound account and session in the App's manual settlement panel, enter the bill's actual USD amount, and confirm. The CLI also supports `agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm`. If the bill does not show the charge yet, use **Use reserved amount** in the App or `--settle-at-reserved` in place of `--actual-usd USD` to settle conservatively at the full reservation and resume API runs. That settlement cannot be changed afterwards, so the local ledger may overstate the call. Settlement does not contact the provider and records a secret-free audit event. Settlement first acquires the session's run lock: an active process is rejected, while a stale `running` status left by an interruption is marked failed and can then be settled. Settlement is safe to retry with the same amount. Never enter zero unless the provider bill confirms zero. A conflicting prior settlement is rejected. Historical unresolved entries that cannot be attributed to an account remain blocked rather than being assigned to the wrong profile.

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

### 9. Safe changes, activity, memory handoff, and extensions

Read-only stays the default. For an isolated change, choose **Isolated Changes** under **Access mode** and create a new session while subscription mode is selected. It uses a fresh workspace based on the source repository's committed `HEAD`; uncommitted source files are not copied. Native interactive TUI mode is separate.

In **Changes**, write a title, summary, and steps for the plan, then save and review it. Edit the plan until it matches the work you want. Click **Approve reviewed plan** before **Run approved changes** becomes available. The provider writes only in the isolated session workspace. Codex change runs use headless `codex exec`: AgentBridge does not enable automatic approval, and no runtime approval prompt is available. A command that needs permissions outside the configured sandbox fails closed; keep the work within the approved plan and workspace. The CLI offers the same sequence:

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" session create --provider codex --repo "$HOME/Projects/example" --changes
# Copy the session ID printed above.
SESSION_ID="paste-session-id-here"
"$CLI" changes plan "$SESSION_ID" --title "Update parser" \
  --summary "Handle the new record shape." --step "Update decoding" --step "Adjust focused coverage"
# Copy PLAN_ID and REVIEW_DIGEST from the output. Approval prints the plan and
# waits for the complete `APPROVE REVIEW_DIGEST` phrase on stdin.
printf '%s\n' 'APPROVE REVIEW_DIGEST' | "$CLI" changes approve "$SESSION_ID" PLAN_ID REVIEW_DIGEST
printf '%s' 'Implement the approved plan.' | \
  "$CLI" changes run "$SESSION_ID" PLAN_ID REVIEW_DIGEST
```

Review **Changes** for the complete file list and diff. Restore a selected file when rejecting its change, restore all to the base snapshot, or export the patch. A file whose diff is over 1 MiB is not shown, and non-UTF-8 text is shown with replacement characters; both stay complete in the patch, so export it to review them. Accept and apply then need a separate confirmation for that exact diff: a checkbox in the App, or `--confirm-partial DIFF-DIGEST` in the CLI, with the digest printed by `changes diff`. **Verify** starts `.codex/ci.sh` only after you click it, and refuses a script that differs from the pinned commit; restore it, or run it as an approved custom verifier. A custom verifier requires an explicit approval step and is passed as an executable plus separate argv values; AgentBridge does not assemble a shell command. The result shows the executable, arguments, working directory, exit code, duration, and redacted stdout/stderr. Accept and apply controls require a successful verification of the current exact diff. Apply asks for a local branch name, checks that the source base commit has not changed, and creates an uncommitted worktree. AgentBridge never commits, pushes, or merges.

The **Activity** timeline shows ordered redacted audit events, including recorded progress, plan approval, cancellation, errors, diff changes, and verification. It reports provider output only when the official CLI reports it. The **Parallel task board** lists actual launched runs across sessions and their status, approval, progress, cancellation, and diff/verification references. Up to three provider runs (read-only, change and verification runs) can be in progress at once across the App, the CLI and autonomous workflows; a fourth is refused until one finishes. Viewing a diff, approving a plan or accepting changes is never blocked by this limit. Shared process-level locks also prevent two managed runs in the same session. Use **Cancel this session** on the corresponding task.

To carry memory across commits, choose a source session and a target session for the same canonical repository and different commits. The target session's bound account must allow shared memory. Select the source turns and/or notes, review the source and target commits, and create the handoff. The next allowed target-session prompt receives only that selection as a bounded (16 KiB), clearly marked untrusted historical JSON envelope with provenance. Handoffs are stored below the selected workspace data root in `shared-memory/project-handoffs/`. Native provider TUI transcripts are never imported.

The legacy policy panel under **Skills & MCP** accepts descriptor JSON as inert metadata. Its grants do not execute anything. Use the separate active-runtime controls described below to load actual Skill instructions or connect an installed MCP server.

The CLI offers focused counterparts:

```sh
"$CLI" changes diff "$SESSION_ID"
"$CLI" changes restore "$SESSION_ID" Sources/example.swift
"$CLI" changes export "$SESSION_ID" "$HOME/Desktop/example.patch"
"$CLI" changes verify "$SESSION_ID" # starts .codex/ci.sh only on this explicit command
"$CLI" changes verify "$SESSION_ID" --custom /absolute/path/to/check --approve-custom --arg "--fast"
"$CLI" changes accept "$SESSION_ID" --confirm
"$CLI" changes apply "$SESSION_ID" reviewed-local-branch
"$CLI" tasks
"$CLI" memory handoffs "$SESSION_ID"
"$CLI" memory carry-forward SOURCE_SESSION TARGET_SESSION --turn TURN_UUID --notes
"$CLI" extensions import /absolute/path/to/descriptor.json
"$CLI" extensions grant "$SESSION_ID" extension-id --permission readSelectedFiles --path Sources --confirm
"$CLI" extensions revoke "$SESSION_ID" extension-id --confirm
```

`changes apply` returns a local uncommitted worktree. `changes verify` sends custom argv directly to the executable. The CLI commands do not bypass the same subscription, plan approval, verification, base-commit, and account-consent checks as the app.

### 10. Autonomous workflows

Open **Autonomous Workflow**, select the source repository and enter a specific goal. Select the actual provider/account for the planner, researcher, implementer and reviewer. Calls use subscription login. Confirm profile sharing consent before allowing dependencies or the exact implementation diff to reach other roles.

Choose concurrency, review/repair, duration and invocation limits; concurrency and review rounds cannot exceed three. Choose no verification, project CI or a reviewed custom executable with separate arguments. **Generate plan** makes a real planning request, but does not approve its work. Inspect every task, dependency, prompt, source commit, account, memory choice, extension, verifier and limit. Acknowledge review, approve the displayed digest, then start. Changed bindings require new approval.

Inspect the exact frozen project-memory context before approval. Each consenting role receives that snapshot across provider/account choices. Select Save final summary and a consenting destination profile to append one workflow result to shared memory. Dependency-output sharing is a separate choice.

Inspect task progress and review/verification results. Cancel stops scheduling and requests termination. Interrupted work is not replayed automatically. After completion, open the implementer's changes in **Project Conversations** and use existing diff, verification, acceptance and apply controls. No automatic commit, push or merge occurs. The CLI exposes matching plan/approve/run/status/cancel operations under `autonomous`; consult `agentbridge help` for exact flags and JSON status output.

### 11. Active Skills, MCP and Mac Control

With a project session selected, open **Skills & MCP**. Import an actual SKILL.md snapshot or a runtime manifest for an installed local stdio MCP server. Import is inert. Inspect the MCP command, argv and exact tool list before explicitly testing; testing starts that local program for initialization and tool discovery. Preview activation, review the digest, instructions/tools and trust warning, explicitly consent, then enable for the selected project/provider/profile. Old metadata grants are insufficient. Changes and revocation invalidate bindings; use a fresh session when prompted. Skill scripts/hooks and remote HTTP/OAuth MCP are not supported by this initial runtime.

For **Mac Control**, select the installed-helper preset and a target bundle ID. Open the target app yourself and start with **Observe**. Import the preset, then select **Test Connection** to inspect its tools before previewing and enabling it. Permission testing reads readiness and does not grant macOS permissions; grant Accessibility and Screen Recording manually if required. Enable only after reviewing screen-access consent; **Control** additionally requires input consent. Protected system, credential, terminal and AgentBridge targets are refused. Screenshots include the entire main display and may be sent to the selected provider; the target restricts input, not image capture. Close private windows first. **Stop Control** revokes scope and requests cancellation, but cannot undo delivered actions. General desktop consent does not authorize credentials, system authentication, security changes or consequential transactions.

Select enabled extension IDs for each workflow role before generating its plan. Their scope and limits are bound into approval. Repository read-only mode does not make a separately approved external tool read-only. See the [design and validation boundaries](AUTONOMY_AND_EXTENSIONS.md).

### 12. Common CLI operations

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

If you moved or renamed a repository, its shared memory stays under the old path and a new session starts empty. `agentbridge memory relink-candidates SESSION_ID` lists memory stored for the same commit under a path that no longer exists, and `agentbridge memory relink SESSION_ID KEY --confirm` copies it into the session. The original is not changed, and this only works while the session's own memory is empty. A second clone whose original folder still exists is not offered.

`agentbridge doctor` also prints each provider CLI's version next to the version AgentBridge was last verified with, and warns if a flag AgentBridge relies on is missing from the CLI's help. It does not block runs.

### 13. Troubleshooting

- **Provider CLI not found:** Set its path under **CLI Executables**, or add the official CLI to a path visible to the login environment, then click **Check Sign-in and Plan**.
- **Not signed in or plan not confirmed:** Complete subscription login in the provider's official CLI. For a new account, use AgentBridge's login terminal, then check again.
- **An existing session does not run after switching accounts:** A session is bound to the account used at creation. Switch back to that account or create a session under the selected account.
- **A new commit does not show older memory:** Memory is isolated by pinned commit. Confirm both sessions use the same repository path and commit.
- **API run is rejected or a reservation is not returned:** Check `agentbridge budget` or the UTC monthly balance shown in the app. Unknown, failed, or cancelled charges are not treated as free and the reservation is retained.
- **Workspace differs from the source repository:** This is the snapshot boundary. Source changes made after session creation are not copied into that workspace automatically.

### 14. Sign, notarize, and verify the app

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
