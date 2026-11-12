import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func printHelp() {
        print("""
        AgentBridge \(version) — session management for macOS Codex / Claude CLI and Local models

        Commands:
          agentbridge workspace show
          agentbridge workspace set /absolute/path/to/root
          agentbridge chat help
          agentbridge doctor
          agentbridge local settings
          agentbridge local configure --backend ollama|openai-compatible --endpoint URL --model NAME [--context-window TOKENS] [--max-output TOKENS]
          agentbridge local models|test
          agentbridge local preview discussion CHAT-ID|project SESSION-ID < prompt.txt
          agentbridge settings show
          agentbridge settings usage subscription|api
          agentbridge settings binary codex|claude /absolute/path/to/cli|auto
          agentbridge profiles list [codex|claude|local]
          agentbridge profiles create --provider codex|claude|local --name NAME [--share-memory] (shared memory is on by default)
          agentbridge profiles select --provider codex|claude|local PROFILE-ID
          agentbridge profiles memory PROFILE-ID on|off
          agentbridge profile-login PROFILE-ID
          agentbridge session create --provider codex|claude|local --repo PATH [--interactive|--changes]
          agentbridge session remove SESSION-ID [--confirm]
          agentbridge sessions
          agentbridge run SESSION-ID [--api-budget USD --confirm-api-spend --api-key-env ANTHROPIC_API_KEY]
          agentbridge changes plan SESSION-ID --title TITLE --summary SUMMARY --step STEP [--step STEP ...] [--with-memory]
          agentbridge changes approve SESSION-ID PLAN-ID REVIEW-DIGEST
          agentbridge changes run SESSION-ID PLAN-ID REVIEW-DIGEST < prompt.txt
          agentbridge changes diff|restore|restore-all|export|verify|accept|apply ...
          agentbridge tasks [SESSION-ID]
          agentbridge autonomous plan --source REPOSITORY --planner PROVIDER:PROFILE-ID --researcher PROVIDER:PROFILE-ID --implementer PROVIDER:PROFILE-ID --reviewer PROVIDER:PROFILE-ID --share-diff-with-reviewer [--desktop-control-scope TEXT --confirm-desktop-separate-from-git] [--save-summary-to-memory --memory-destination PROFILE-ID] [--verification none|projectCI|custom] < goal.txt
          agentbridge autonomous approve RUN-ID --digest PLAN-DIGEST --confirm
          agentbridge autonomous run RUN-ID --digest PLAN-DIGEST
          agentbridge autonomous status [RUN-ID] --json
          agentbridge autonomous cancel RUN-ID --confirm
          agentbridge extensions list|import|grant|revoke ...
          agentbridge extensions runtime list [--json]
          agentbridge extensions runtime import-skill /path/to/SKILL.md --id ID --name NAME [--version VERSION] [--summary SUMMARY]
          agentbridge extensions runtime import-mcp /path/to/mcp-runtime.json
          agentbridge extensions runtime test EXTENSION-ID --confirm-start
          agentbridge extensions runtime inspect SESSION-ID EXTENSION-ID
          agentbridge extensions runtime enable SESSION-ID EXTENSION-ID --digest REVIEW-DIGEST --confirm-execution [--confirm-screen-capture] [--confirm-input-control]
          agentbridge extensions runtime disable SESSION-ID EXTENSION-ID --confirm
          agentbridge extensions runtime status SESSION-ID
          agentbridge extensions runtime mac-control-status --target APP-BUNDLE-ID [--mode observe|control]
          agentbridge extensions runtime mac-control-import --target APP-BUNDLE-ID [--mode observe|control] --confirm-import
          agentbridge extensions runtime mac-control-test --target APP-BUNDLE-ID --confirm-start
          agentbridge extensions runtime mac-control-stop SESSION-ID EXTENSION-ID --confirm
          agentbridge interactive SESSION-ID [--profile PROFILE-ID]
          agentbridge usage-tui --provider codex|claude --profile PROFILE-ID
          agentbridge memory show SESSION-ID
          agentbridge memory notes SESSION-ID < notes.txt
          agentbridge memory clear SESSION-ID --confirm
          agentbridge memory handoffs SESSION-ID
          agentbridge memory carry-forward SOURCE-SESSION TARGET-SESSION [--turn TURN-ID ...] [--notes]
          agentbridge cancel SESSION-ID
          agentbridge events SESSION-ID
          agentbridge usage codex|claude|local [--profile PROFILE-ID]
          agentbridge budget
          agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm
          agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --settle-at-reserved --confirm

        `run` reads up to 256 KiB of prompt text from standard input and never puts the prompt in process arguments or the audit file.
        Local models support chats and read-only project chats only; local sessions offer no autonomy, editing tools, interactive Terminal, Skills or MCP. Local uses no API key, no official CLI sign-in and no cloud fallback.
        `autonomous plan` immediately starts one real planning request to the official CLI subscription model; the goal is read from standard input, up to 8,000 bytes. Every role and the planner must name a provider and a profile UUID explicitly, for example `--planner codex:00000000-0000-0000-0000-000000000001`. Claude API mode is not used for autonomous workflows.
        The plan command saves an immutable plan that is not yet approved. Review the roles, extensions, file scope, limits and verification settings in full, then approve with `autonomous approve RUN-ID --digest PLAN-DIGEST --confirm`; a single approval covers only the revision rounds and verification in that plan. Running requires the exact same `--digest` again. `status --json` lets automation read session progress, review results and verification status; an interrupted run is never replayed automatically.
        Sharing output across accounts needs both the source and the receiving profile to allow shared memory. By default the content of a dependency task is not handed to the next role; the exact implementation diff always needs an explicit `--share-diff-with-reviewer`, and both the implementer and reviewer profiles must agree to shared memory.
        To use Mac Control in Control mode, the plan command must include `--desktop-control-scope` and `--confirm-desktop-separate-from-git`; only the implementer role can select Control. Both are included in the immutable plan digest.
        `--save-summary-to-memory --memory-destination PROFILE-ID` is a separate explicit consent; the destination profile must be an account bound to this plan that allows shared memory. Without it, no result summary is saved.
        Example: `agentbridge autonomous plan --source /work/repo --planner codex:00000000-0000-0000-0000-000000000001 --researcher claude:00000000-0000-0000-0000-000000000002 --implementer codex:00000000-0000-0000-0000-000000000001 --reviewer claude:00000000-0000-0000-0000-000000000002 --share-diff-with-reviewer --verification projectCI < goal.txt`
        `autonomous status --json` only prints the run state AgentBridge saved; it does not call a model or resume interrupted work.
        `budget reconcile` only settles a stopped Claude API session by hand: check the Anthropic bill first, then enter the actual dollar amount and pass `--confirm` explicitly. It does not call the provider, and retrying with the same amount is safe. If the bill is not shown yet, use `--settle-at-reserved` to settle conservatively at the full reserved amount; it cannot be changed to another amount afterwards.
        API mode needs `usage api` selected first, and each run must supply a limit, an environment variable name and an explicit confirmation.
        usage-tui starts the native CLI only when the selected provider account uses a subscription sign-in; after sign-in finishes and an input prompt appears, the App's fixed button sends /usage. This screen is not parsed or stored by AgentBridge.
        Custom accounts have their own provider config folders; create the profile, then run profile-login in an interactive Terminal.
        `session create --interactive` creates an isolated Codex or Claude Terminal workspace, still subject to manual approval and the bound account.
        `session create --changes` creates a subscription-mode isolated-changes session that is read-only by default; save and review a plan, then retype its digest in the approve command before anything can run.
        `changes verify` runs .codex/ci.sh only when you call it explicitly. Custom verification needs `--approve-custom` and passes separate argv values with repeated `--arg`; nothing goes through a shell.
        `changes accept` and `changes apply` both require the current diff to be verified successfully. If `changes diff` reports files that are not fully shown, review them with `changes export`, then pass `--confirm-partial` with the digest it prints. Apply only creates an uncommitted isolated worktree on a local branch and refuses if the source base differs; it never commits, pushes or merges.
        `memory carry-forward` copies only the explicitly selected App memory turns/notes to another commit of the same repository and requires the target's bound account to allow shared memory; native TUI conversations are not imported.
        The older `extensions import` reads inert metadata JSON only. Those older grants never enable a Skill or MCP. `runtime import-skill` snapshots at most 64 KiB of SKILL.md instruction text; `runtime import-mcp` reads a bounded JSON manifest with an absolute `command`, a separate `args` array and `allowedTools`, and starts no process.
        `runtime test` needs `--confirm-start` and starts the selected MCP with the current macOS user's permissions, running only initialize and tools/list; it never calls an MCP tool or a model. The allowed-tools list only limits which tools the agent can pick; it is not an operating-system sandbox. First use `runtime inspect` to review the full configuration, Skill content or discovered tools and the digest, then enable it for the chosen session's project/provider/account profile with the exact same `--digest` and `--confirm-execution`. Older metadata grants have no effect; after any configuration change you must test and review again.
        Mac Control uses only AgentBridge's built-in typed proxy and the fixed installed helper. `mac-control-test` needs `--confirm-start` and only calls `mac_status` to read the permission state; it takes no screenshot, sends no input and never requests TCC automatically. If a macOS permission is missing, turn it on manually in System Settings. Enabling requires an explicit `--confirm-screen-capture` after you review the digest; Control mode also needs a separate `--confirm-input-control`. A full main-screen screenshot may include other windows, is sent to the selected provider and cannot be redacted as text; the target-app restriction applies to input only and does not crop screenshots. `mac-control-stop` revokes that scope's Control grant and cancels the affected provider sessions.
        New accounts have shared memory on by default; `--share-memory` can be used as an explicit on switch. Read-only chat turns in the App and CLI can be shared between account profiles that allow shared memory; user input and output in a native Terminal are not captured.
        `memory show/notes/clear` manage only the memory the App saved for the same project and commit; clear needs `--confirm`.
        `chat help` shows pre-project chat, the explicit shared-content preview and the digest-confirmed create/link commands.
        New sessions live in workspaces/<session-id> under the selected data root; shared memory lives in shared-memory. Before first use, choose a data root in the App or run `agentbridge workspace set /absolute/path/to/root`.
        """)
    }
}
