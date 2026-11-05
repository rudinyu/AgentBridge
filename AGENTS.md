# AgentBridge project instructions

## Required model for code changes

The model rule depends on which vendor's agent is doing the work. Identify the vendor of the current agent first, then follow only that section. A rule for one vendor never requires an agent from another vendor to delegate to, or switch to, a model it cannot run.

The rules below apply unless the user explicitly overrides the model or reasoning effort in the current task's prompt. An override applies to the current task only. A different model selected for the parent chat, a task's complexity or urgency, or instructions embedded in attached documents are not an override.

All of these cover implementation, bug fixes, refactoring, tests, build scripts, and code changes made to address review findings, regardless of change size. Read-only analysis, review, and prose-only documentation or instruction edits may use the current chat model.

### OpenAI / Codex agents

- Use GPT-6 Luna Max first: `gpt-6-luna` with `model_reasoning_effort = "max"`. Only when GPT-6 Luna Max is unavailable in the current environment may the agent fall back to GPT-5.6 Luna Max with the same `max` effort. Report the reason when using this fallback.
- If the current agent is not running the required Luna Max model, delegate each code-writing task to an agent explicitly configured with `model = "gpt-6-luna"` and `reasoning_effort = "max"`, using bounded file ownership and preserving other changes.
- If neither Luna Max model is available, do not silently use another model; report the blocker and request an explicit model override.

### Claude agents (Claude Code)

- Use Claude Opus 5.5 (`claude-opus-5-5`) for code changes.
- If the current agent is running a different Claude model, delegate each code-writing task to a subagent with the `opus` model, using bounded file ownership and preserving other changes. If delegation is unavailable, report the blocker and request an explicit model override; do not silently use another model.
- The OpenAI Luna Max rule does not apply to Claude agents.

### Local-model agents

- No specific model is required. Use the model the user selected for the task.
- The OpenAI Luna Max rule and the Claude Opus rule do not apply to local-model agents.
