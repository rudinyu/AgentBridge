# AgentBridge project instructions

## Required model for code changes

- Unless the user explicitly overrides the model or reasoning effort in the current task's prompt, all code creation and modification must use GPT-6 Luna Max first: `gpt-6-luna` with `model_reasoning_effort = "max"`. Only when GPT-6 Luna Max is unavailable in the current environment may the agent fall back to GPT-5.6 Luna Max with the same `max` effort. Report the reason when using this fallback.
- This requirement includes implementation, bug fixes, refactoring, tests, build scripts, and code changes made to address review findings, regardless of change size.
- If the current agent is not running the required Luna Max model, delegate each code-writing task to an agent explicitly configured with `model = "gpt-6-luna"` and `reasoning_effort = "max"`, using bounded file ownership and preserving other changes.
- If neither required Luna Max model is available, do not silently use another model; report the blocker and request an explicit model override.
