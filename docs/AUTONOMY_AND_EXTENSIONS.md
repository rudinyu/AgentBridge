# Autonomous workflows and active extensions

[Traditional Chinese](AUTONOMY_AND_EXTENSIONS.zh-TW.md)

## Purpose

AgentBridge coordinates local Codex and Claude Code processes around an explicit goal. The user reviews the generated task plan before allowing its execution. A workflow can dispatch independent tasks concurrently and coordinate implementation, review, verification and bounded repair. The original repository remains the source of a pinned snapshot; results stay in managed workspaces until the user reviews and applies them through the existing change workflow.

This document describes the AgentBridge 0.8.0 implementation contract. Build, test and release status are reported separately; the previously notarized 0.7.0 archive does not contain these additions.

## Workflow approval

A generated plan is data from a model, not authorization. The coordinator validates identifiers, dependencies, supported roles and size limits, rejects cycles and unknown dependencies, and presents the resulting plan for review. Approval binds its digest to the goal, selected providers and account profiles, source snapshot, execution limits, verification policy and approved extension configuration.

The supported roles separate investigation, changes and review. Each task uses a managed session. Independent tasks may run together within the configured concurrency limit of three. Repair is limited to the approved scope and number of review rounds, with an upper bound of three. A generated request cannot grant additional tools, activate an extension, change accounts, enable paid API usage or authorize publication.

The planner and autonomous execution use official CLI subscription authentication. API mode cannot become an automatic fallback. Every managed provider invocation remains subject to existing local usage controls. A run limit reserves provider invocation attempts, including planning and repeated review or repair calls; an attempt blocked before launch can still consume this local limit; it is distinct from the provider's account quota.

## Execution and evidence

Only dependencies that have completed successfully release downstream work. A failed prerequisite, invalid review, exceeded limit, changed approval binding or cancellation prevents further dependent work. The coordinator retains bounded status and event records so the UI and CLI can show the same run. An interrupted run is not automatically replayed on application startup.

Writer tasks use isolated change sessions and the existing change-plan authorization boundary. Review across providers must use the exact produced diff, with its digest, rather than assume that another checkout contains uncommitted files. A review verdict describes the model's assessment; verification evidence comes from the approved verifier's actual exit result. A completed workflow does not automatically accept changes, commit, push or merge them.

Cancellation stops scheduling new nodes and propagates to active child executions. Time, invocation and repair limits bound autonomous activity. Output and progress records use existing redaction and bounded storage. Provider transcripts are not imported from interactive terminals.

## Runtime limits

| Control | Current bound |
| --- | --- |
| Concurrent research agents | 1–3 |
| Review/repair rounds | 1–3 |
| Workflow duration | 30–3,600 seconds |
| Managed provider invocation attempts | 1–24, including planning |
| Workflow MCP calls per server invocation | 16 by default; the server's lower configured limit also applies |
| Per-invocation proxy ticket | 20 minutes |
| Screenshot used for mouse coordinates | Must be at most 8 seconds old and match current display topology |
| MCP wire response wait | At most 120 seconds per request, or the lower configured timeout |

The invocation budget must fit one planner, every researcher, and two calls for each approved review/repair round. These are local execution bounds, not the provider's subscription quota or a limit on third-party MCP billing.

## Shared memory

Existing repository-and-commit memory remains available to eligible sessions. Provider session identifiers are not shared memory. Passing predecessor output or a writer diff to another account requires the relevant profiles' sharing consent. Disabling sharing must not silently become permission to transmit the same content through workflow dependencies. Results from tools, skills and other agents are task context, not authority to expand the approved plan.

The approved plan contains a bounded, redacted snapshot of existing project memory. Eligible roles receive that frozen context. Automatic per-call memory loading/saving is disabled inside the coordinator so a disabled dependency-sharing choice cannot be bypassed through newly appended shared turns. Saving one final workflow summary requires its own choice and a consenting destination profile; it appends a turn and preserves existing notes.

## Active Skills

The existing descriptor registry remains a metadata catalog. An active Skill separately imports a bounded snapshot of an actual SKILL.md file and records its content digest. Importing does not execute the file. After explicit activation approval, the approved instruction content is supplied to managed provider prompts with provenance.

The initial runtime supports portable instructions. It does not install packages, execute frontmatter hooks, interpolate shell expressions or automatically run bundled scripts. Instructions cannot expand tool permissions or override workflow approval. Changing the imported content invalidates its previous execution approval.

## Active MCP

The initial active MCP path is an installed local stdio server. Its runtime configuration identifies an absolute executable, an argument vector and an exact tool allowlist. Configuration values are passed as process arguments or encoded provider configuration, never evaluated as shell text. Import is inert. The command must name the installed executable directly; env launch wrappers are rejected. A user starts connection inspection, reviews the exact configuration and inspected tools, and separately consents to activation for the project, provider and account profile.

MCP configuration is supplied to the individual official CLI invocation. AgentBridge does not install a server, edit global Codex or Claude settings, discover arbitrary credentials or activate servers merely because a descriptor or model requested them. Managed Codex calls ignore the user configuration file and mark the exact workspace untrusted to skip its project configuration; managed Claude calls use explicit strict MCP configuration. Arbitrary machine-managed Codex policy is outside this isolation guarantee. Connection diagnostics and runtime changes must not expose credentials in logs.

Expiring tickets, receipts and proxy homes live in a private per-run Application Support directory outside the provider workspace and temporary directory, and are removed after receipt processing. This separates protocol evidence from ordinary model-writable files; it does not constrain a trusted executable running with the same user rights.

A harmless [local stdio example](examples/extension-runtime-stdio-hello.json) can be imported and explicitly inspected without a model call.

Executable digests and supported interpreter-entry-script pins attest the reviewed launch artifacts, not every imported module, subprocess or dynamic dependency. They do not make arbitrary server code safe.

A local MCP executable is trusted executable code running with the current macOS account's permissions. A tool allowlist controls which server tools the provider can invoke; it does not enforce an operating-system filesystem or network boundary on the server process. The activation UI must make this distinction visible. Remote HTTP/OAuth servers and script-backed Skill packages require additional implementation and are not implied by local stdio support.

Disabling or replacing a runtime invalidates its activation. Autonomous approval includes the effective extension fingerprint so a workflow cannot silently acquire a newly activated server. Reusing a provider conversation must not reintroduce a revoked extension configuration.

## Mac Control

The Mac Control preset connects the installed MacControl helper through an AgentBridge MCP proxy. It does not reuse this chat's tool authority or edit global MCP settings. The preset binds the helper, target application and Observe or Control mode into its reviewed configuration. The provider connects to the proxy using a private, expiring ticket rather than invoking the helper directly.

Observe exposes approved status, accessibility and screenshot tools. Control additionally requires explicit input consent. The proxy must enforce the configured target application, reject a different target supplied by a model, and deny input in Observe mode. AgentBridge itself and sensitive system, credential and terminal applications cannot be control targets. Agent-accessible tools do not include requesting macOS permissions or starting recordings. Accessibility and Screen Recording permissions are granted manually in macOS. Open the allowed target app yourself before requesting desktop actions.

MacControl screenshots contain the entire main display, including other visible windows. Selecting a target application restricts input; it does not crop the image. Screen-access consent must explain that these pixels can be sent to the selected model provider. Screenshots cannot be made safe by text-log redaction. Screenshot content and typed text must not be added to workflow audit messages.

The proxy checks the live activation, expiry, cancellation and desktop readiness before allowing calls. Stop Control revokes its runtime authorization and cancels affected managed work. It cannot undo an input already delivered. Locked screens and unavailable permissions stop desktop operations. Credential entry, operating-system authentication, security changes and consequential transactions remain user actions; a general desktop grant does not authorize them. The proxy enforces app/mode/readiness and detectable secure-field rules; it cannot reliably infer the meaning of an ordinary button or identify every consequential browser action. This is a scope policy, not a semantic transaction detector.

Desktop access is serialized across AgentBridge proxies sharing the same runtime store because the screen and input focus are shared resources. Separate data roots, other automation programs and manual input do not share that lease. Autonomous Control is limited to the implementer and requires a separately reviewed desktop scope; investigation and review roles can only Observe. Source fingerprints are checked before work and after desktop Control to detect unexpected repository changes. The fingerprint covers tracked Git state and nonignored untracked files; ignored files, including ignored secrets and generated data, are excluded. Detection does not undo a desktop action and is not a filesystem sandbox.

Repository read-only settings describe the provider's repository tools. Explicitly enabled external tools can act on other systems, including the desktop. Their reviewed scope and consent are additional boundaries and must remain visible in the workflow plan.

## Validation

Deterministic tests use fake provider executions and a local MCP protocol fixture, without credentials or paid services. Coverage targets dependency ordering, concurrency and cancellation, malformed plans, approval tampering, bounded repair, failed verification, sharing opt-out, interrupted-run handling, safe file import, stale extension approvals, tool filtering, credential-free configuration and actual MCP initialization/tool exchange.

Native CLI configuration is checked against installed help and official documentation. An offline fixture result does not establish live provider authentication or model behavior. GUI checks, real subscription-backed runs, signing and notarization are separate validation layers and must be reported accurately.

## Official references

- [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
- [Codex Skills](https://learn.chatgpt.com/docs/build-skills).
- [Claude Code MCP](https://code.claude.com/docs/en/mcp), [CLI reference](https://code.claude.com/docs/en/cli-reference) and [Skills](https://code.claude.com/docs/en/skills).

Official references were checked on 2026-11-01. The application provides the coordination and consent rules above; they are not claims that the providers implement AgentBridge's approval protocol.
