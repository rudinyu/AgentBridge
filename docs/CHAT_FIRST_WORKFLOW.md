# Chat first, then a Git project

[Traditional Chinese](CHAT_FIRST_WORKFLOW.zh-TW.md)

## User journey

Start with **New Chat**. Discuss the idea, requirements and tradeoffs with Codex, Claude or a configured Local model before choosing a repository. When the direction is clear, choose **Create Git Project** or **Link Existing Project**, review the exact context and destination, then continue in the normal project conversation.

The first-use workspace-data folder remains required. It stores the user's discussion data and project memory; it is not a Git project and does not need to contain a repository. Creating or sending a discussion does not initialize Git or clone a repository.

## Discussion identity and accounts

A discussion has its own UUID, revision, transcript and selected provider/account profile. It does not use a made-up repository path or commit hash. Cloud sends use the explicitly bound profile's official CLI subscription authentication; Local uses its configured loopback server. Neither path uses the saved Claude API mode for discussions or falls back to API credits.

Provider/account changes are local to the discussion. They do not rewrite the provider's global profile selection. Native provider session IDs are not resumed across sends; eligible prior turns are supplied as bounded, redacted application-owned context.

Discussion sends use a fresh empty private temporary directory under the selected data root. Codex uses its documented non-Git execution option with read-only restrictions, shell/agent/goal/web-search controls disabled, ephemeral sessions and ignored user configuration. Claude uses restricted print mode with no enabled tools, strict empty MCP settings and prompt-history suppression. The discussion does not activate project Skills, MCP, desktop control, Git changes or autonomous agents.

## Transcript and shared context

The transcript is stored under the selected data root's discussions directory. A current prompt is always sent to the selected provider; successful responses become visible in the same discussion. Text is bounded and redacted before persistence.

The storage limits are 64 discussions, 256 saved turns per discussion, 64 KiB per message and a 4 MiB encoded record. New over-cap writes are refused without silently shortening older originals. Legacy truncation markers remain visible. Up to 40 turns may be selected for a project handoff, and at most four current previews are retained per discussion revision; completing a handoff or continuing the discussion retires obsolete previews. Readable context compression has a separate model-input budget; see [Local Models and Context](LOCAL_MODELS_AND_CONTEXT.md).

Sharing is on by default, subject to account consent. A turn enters later context or a project handoff only when it is complete, shareable, had source consent when saved, and both the source and destination accounts currently allow sharing. Turning sharing off keeps the local visible transcript while excluding that turn from later context and transfer. It does not prevent sending the current message.

Choosing a different data root migrates discussions with conflict checks and retains the old data. A running send or project transition blocks a root change. Discussion runs participate in existing local account usage limits and cancellation; these local counts do not represent the provider's actual subscription quota.

## Create or link a project

1. Choose a new absolute folder path or an existing Git repository.
2. Select the destination provider/account and the completed, eligible turns to carry forward.
3. Preview the exact context, source revision, destination, mode and digest. Existing repositories also bind their current HEAD.
4. Confirm that exact preview. Changed discussion content, consent, destination or repository HEAD requires a new preview.
5. Open the returned normal project session. The original discussion remains available.

Creating a new project creates only a new local repository and an empty initial commit so the normal workspace flow can pin a real commit. It does not commit the transcript, add a remote, publish or push. A new destination must not already exist, be reached through a symlink, or be nested in another repository.

Linking an existing project reads its committed state and creates the normal isolated workspace. It does not alter the existing repository's files, configuration or history.

Approved turns are copied separately into AgentBridge's project memory, scoped by canonical repository and pinned commit. They are not copied into source files or the Git commit. Subsequent changes, verification and applying results retain their existing approval boundaries.

## CLI

Choose the workspace data root once, then use these commands. Prompts are read from bounded standard input.

```sh
agentbridge workspace set /absolute/path/to/data
agentbridge chat new --provider codex
agentbridge chat send CHAT-ID < prompt.txt
agentbridge chat send CHAT-ID --no-share < private-prompt.txt
agentbridge chat target CHAT-ID --provider claude --profile PROFILE-ID
agentbridge chat project preview CHAT-ID --mode new --path /absolute/path/to/new-project --provider codex --profile PROFILE-ID
agentbridge chat project apply HANDOFF-ID --digest REVIEW-DIGEST --confirm
```

Use mode existing to link a repository. The default target access is read-only; changes requests an isolated-change session. Omitted turn selectors choose completed eligible shared turns; repeated --turn TURN-ID chooses an exact subset. Use --no-context to transfer no turns, including when creating a project from a private discussion. Review the printed payload before apply.

## Validation and status

Deterministic tests use fake CLI/local HTTP responses and local fixture repositories. Real model calls, GUI interaction, signing and notarization are separate validation layers. The latest signed 0.9.0 release remains separate from the 0.10.0 development build.

See the [0.9.0 validation record](CHAT_FIRST_VALIDATION.md) for exact results and GUI acceptance gaps.

Official non-Git execution support was checked against installed Codex 0.166.0 and the [Codex non-interactive documentation](https://learn.chatgpt.com/docs/non-interactive-mode), with controls described by the [configuration reference](https://developers.openai.com/codex/config-reference). Claude's print-mode and configuration flags were checked against installed Claude Code 2.1.309 and its [official CLI reference](https://code.claude.com/docs/en/cli-reference). This check used help/version output and documentation, without a live model request.
