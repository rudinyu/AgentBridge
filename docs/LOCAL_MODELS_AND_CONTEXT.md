# Local models and readable context compression

[Traditional Chinese](LOCAL_MODELS_AND_CONTEXT.zh-TW.md) · [Quick start](LOCAL_MODELS_QUICKSTART.md)

## Provider boundary

AgentBridge 0.10 adds an explicit Local provider alongside Codex and Claude. Selecting Local connects directly to an already running model server on this Mac. It does not change the default cloud provider, use a CLI subscription, collect an API key or fall back to a paid service. It downloads a model only when you click **Download model** in the guided Ollama setup or run `agentbridge local pull MODEL --confirm`.

The supported protocols are Ollama's native chat API and an OpenAI-compatible local chat-completions API, including LM Studio. Default service roots are `http://127.0.0.1:11434` and `http://127.0.0.1:1234/v1`, respectively. Model discovery runs only after an explicit action. A server with no installed models is reported as such.

Only loopback endpoints are accepted. Remote hosts, URL credentials, redirects and implicit HTTP proxies are refused. Ollama cloud-model names and reported remote-model metadata are rejected. AgentBridge's network boundary covers its connection to the local service; the operator of that service remains responsible for its own routing. To disable Ollama's cloud features at the server level, see its official FAQ rather than changing global server settings from AgentBridge.

Local supports project-independent discussions, read-only project conversations, and plan-approved isolated changes. A read-only local conversation receives approved App-owned context; it does not gain filesystem or command tools simply because a project is selected. Local change sessions send only the approved plan, the user's request, selected complete file contents, and explicitly listed new paths to the loopback model. The model receives no tools and never runs commands. Native CLI terminals, autonomous workflow roles, active Skills/MCP and desktop control remain unavailable for Local.

## Configure and use

Start the server yourself and make a model available there. Choose **Local** in AgentBridge, select the backend, enter its loopback endpoint, refresh the model list, choose a model, and save the context-window and output limits. A connection check lists models without generating a model response.

Local has its own account/profile identity and sharing consent. Changing providers can carry eligible App-owned memory between Local, Codex and Claude. The source account's recorded/current consent and the destination's current consent still apply. Endpoint/model settings describe the local backend; they are not subscription plans or cloud credentials.

Local runs and server-reported token usage are separate from Codex/Claude subscription counters and Claude API spending. Local token usage is unavailable when the server does not report it; byte-based context estimates are not presented as actual model token counts.

The initial Local app ceilings are 200 authorized attempts per rolling 24 hours for a profile and 50 per discussion/session. These fixed app limits are shown with local counts; they are not a server quota or a bill. The context window must not exceed the model capacity when the service reports it.

After choosing the shared workspace-data folder, the CLI uses the same settings:

```sh
agentbridge local configure --backend ollama --endpoint http://127.0.0.1:11434 --model MODEL-ID --context-window 8192 --max-output 1024
agentbridge local models
agentbridge local test
agentbridge chat new --provider local
agentbridge local preview discussion CHAT-ID < prompt.txt
agentbridge chat send CHAT-ID < prompt.txt
```

For a compatible server, select `--backend openai-compatible` and its service root, such as `http://127.0.0.1:1234/v1`. `local preview project SESSION-ID` previews a read-only project's composed input. Configuration and previews do not start inference; `chat send` or a project run does.

## Context size

Each model supports a maximum context, and the server may load it with less. **Detect context size** in the Local model settings, or `agentbridge local context`, asks the configured loopback server about the selected model and shows its maximum context and the context it is loaded with, when the server reports them. It only reads: it never loads, unloads or downloads a model.

- **Ollama** reports the model's maximum through `/api/show` and, for a running model, the loaded context through `/api/ps`. Ollama uses the context window AgentBridge sends with every request (`num_ctx`), so the suggestion is the model's maximum, held to what this Mac's memory can carry: 8,192 tokens under 12 GB, 16,384 under 24 GB, 32,768 under 48 GB and 65,536 above that.
- **LM Studio** reports both through its REST API (`/api/v1/models` in LM Studio 0.4 and later; `/api/v0/models/{id}` in 0.3.6 and later gives the maximum only). An OpenAI-compatible server keeps the context it loaded the model with and ignores what a request asks for, so the suggestion is that loaded context. To use more, reload the model in LM Studio with a longer context length.
- Other OpenAI-compatible servers report nothing; set the context window yourself.

**Use N tokens** fills the suggestion into the form, lowering the output reserve to a quarter of the window if it would otherwise leave no room for input; nothing is used until you save. `agentbridge local context --apply` saves it. Suggestions stay within the App's 1,024–131,072 token range.

Before each OpenAI-compatible run, AgentBridge also asks LM Studio's `/api/v1/models` for the loaded context. When the configured context window is larger than the context LM Studio loaded the model with, the run is refused before anything is sent, and the message gives both numbers. A server without that API costs one extra request per run and is not checked.

### Keeping the model loaded

Ollama unloads a model 5 minutes after its last request by default, and the next request loads it again and rebuilds its prompt cache. **Keep model loaded** in the Local model settings (shown for the Ollama backend), or `agentbridge local configure ... --keep-alive MINUTES|forever|default`, sends Ollama's `keep_alive` with each chat request: a number of minutes (1–10,080), until Ollama stops, or nothing so Ollama's default applies. A model that stays loaded answers sooner, but holds its memory while idle. It is saved with the other Local settings. OpenAI-compatible servers such as LM Studio manage this themselves (in LM Studio, the model's idle TTL setting) and are sent nothing.

## Local patch mode

Local isolated changes work with either subscription or Claude API usage mode. Create a project session with **Isolated changes** access; Local does not offer a native interactive terminal. The first **Draft plan** request sends the user request and the workspace's candidate path list, not file contents. Review and save that plan, then explicitly approve it before running. Local change runs do not include shared memory.

In **Changes**, select existing candidate files, add any new relative paths, enter the change request and inspect the byte-count preview before running. The preview includes the exact prompt size and the input budget: the configured context window minus its output reserve and 512-token margin, using one byte per token, capped at 2 MiB. Requests and plan drafts are limited to 8 KiB; fix notes have the same limit. A fix run also includes only the last 12 KiB of failed verification output. Input that exceeds the calculated budget is refused before contacting the model. The model must return complete file contents, so the preview also estimates the output: every selected file in full, plus the path and 48 bytes for each file entry (new paths included) and 512 bytes for the summary and JSON wrapper. That estimate is checked against the output reserve (`maxOutputTokens`, one byte per token); a run that cannot fit is refused before contacting the model and recorded as `local.change.rejected` with `reason=output_over_budget`. Select fewer or smaller files, or raise the reserve with `agentbridge local configure --max-output N`. Previews and the candidate file list only read the workspace and do not hold the session's run lock, so a preview never blocks a run; the App waits for a short pause in typing before refreshing them and pauses them while the session runs.

The model receives no tools and cannot run commands. Existing inputs must be regular UTF-8 files inside the isolated workspace, tracked or untracked but not Git-ignored, with no symlinks; each file is limited to 256 KiB. The model may return at most 200 file operations, each path must be selected or explicitly listed as new, each output file is limited to 256 KiB, all output contents together are limited to 1 MiB, and the complete JSON response is limited to 2 MiB. Paths are relative; absolute paths, empty components, dot/dot-dot components, controls and .git components are rejected. All operations are validated before writing. Writes use temporary files and rollback if any write fails.

The response must be exactly one JSON object with summary and files, with no prose, markdown fence or diff:

~~~json
{"summary":"what changed","files":[{"path":"relative/path","action":"modify|create|delete","content":"full new file content"}]}
~~~

Each file entry contains only path, action and content. Modify and create require the complete new UTF-8 content. Delete omits content or uses null. The App shows the result as a diff for review. A failed verification exposes **Fix with Local model** and an optional note; it does not run verification itself. A fix adds the files changed in the workspace only when they are selectable candidates under the same rules as the file list; the others (binary, over 256 KiB, Git-ignored or not listed) are reported as left out and cannot be modified in that round, while a file you select explicitly must still be selectable. Every fix run consumes the current plan approval, so approve the reviewed plan again before the next run. Verification and acceptance are reset only when a run writes to the workspace; a run that writes nothing keeps them, so a failed fix can be approved and tried again.

When a selection is over the input budget or the output reserve, the preview also suggests a split: groups of the selected files that each fit both, packed largest first. **Select these files** (or the `--file` options the CLI prints) selects one group. Run the groups one at a time; each run consumes the plan approval, so approve the plan again before the next one. New file paths stay in the form and are counted in every group. Files that do not fit even on their own are listed separately. The split is only a suggestion: nothing is selected or run for you.

The CLI accepts the same flow:

~~~sh
agentbridge session create --provider local --repo /path/to/repo --changes
printf '%s' 'Handle the new file format.' | agentbridge changes draft SESSION-ID
agentbridge changes plan SESSION-ID --title 'Update parser' --summary 'Support the new format.' --step 'Update decoding'
printf '%s\n' 'APPROVE REVIEW_DIGEST' | agentbridge changes approve SESSION-ID PLAN-ID REVIEW_DIGEST
printf '%s' 'Implement the approved plan.' | agentbridge changes run SESSION-ID PLAN-ID REVIEW_DIGEST --file Sources/Parser.swift --new-file Sources/NewFormat.swift --preview
~~~

Repeat the final command without --preview to run it. For a fix, pass failed verification output on standard input to agentbridge changes fix SESSION-ID; optional --file and --new-file flags choose additional inputs, --note supplies the bounded note, and --command/--exit-code identify the failed check. Preview and plan approval are required before model writes; local output is never passed to Codex or Claude.

## Guided Ollama setup

**Guided Ollama setup**, at the top of the Local model settings, helps when Ollama is not set up yet. **Check Ollama setup** looks for the `ollama` command on your PATH, in `/opt/homebrew/bin` and `/usr/local/bin`, and inside `/Applications/Ollama.app`, and asks the Ollama endpoint for its model list: the configured endpoint when the backend is Ollama, otherwise `http://127.0.0.1:11434`. Nothing else happens until you click:

- **Not installed:** **Open the Ollama download page** opens <https://ollama.com/download> in your browser. You install Ollama yourself.
- **Installed but not running:** **Start Ollama** runs `open -a` on the Ollama app, so it runs on its own like any app you open, not as a hidden child of AgentBridge. Without the app bundle, the setup shows `ollama serve` for you to run in Terminal.
- **Running:** the setup recommends a code model for this Mac's physical memory and lets you type any other name. **Download model** runs `ollama pull NAME` (as arguments, never through a shell) against the Ollama endpoint, shows its progress and can be cancelled. When it finishes, the Local settings switch to the Ollama backend and that model, are saved, and the connection test runs.

| Physical memory | Recommended model | Download |
| --- | --- | --- |
| under 12 GB | `qwen2.5-coder:3b` | about 1.9 GB |
| 12 GB or more | `qwen2.5-coder:7b` | about 4.7 GB |
| 24 GB or more | `qwen2.5-coder:14b` | about 9 GB |
| 48 GB or more | `qwen2.5-coder:32b` | about 20 GB |

The table is one constant in Core (`OllamaSetup.recommendations`); the names are checked against the [Ollama library](https://ollama.com/library) before each release. The CLI has the same steps:

```sh
agentbridge local setup-check
agentbridge local pull qwen2.5-coder:7b --confirm
```

## Local model helper

The local model helper lets the configured Local model draft text for small tasks in Codex and Claude work. It is not a provider and never calls Codex or Claude. It uses the same endpoint, model, context window and output reserve as Local, and the same limits: each helper request is one authorized attempt against the Local profile's 200 per rolling 24 hours, and against the 50 per session for the session it helps with. Token counts the server reports are recorded for the Local profile, apart from Codex and Claude.

**Local model helper** in the Local model settings is the master switch, with one switch for each task under it. All are off by default. Turning the master switch on runs the connection test on the saved Local settings and stays off unless the server lists the configured model. The CLI is `agentbridge local helper show|on|off [--commit-text] [--explain-failure] [--handoff] [--change-summary]`; `on` and `off` with task flags switch those tasks, and without them the master switch.

| Task | Where | What is sent | Answer |
| --- | --- | --- | --- |
| Commit and pull request text | **Rewrite with local model** in the **Commit, Push and Open PR…** sheet; `changes pr SESSION-ID --draft-text-with-local` | The plan's title, summary and steps; the changed files with their added and removed line counts; the verification command and result AgentBridge recorded; the verified diff of the apply worktree | One JSON object with exactly `commitSubject`, `commitBody`, `prTitle` and `prBody` |
| Explain a failed verification | **Explain this failure** under a failed verification in **Changes**; `changes explain SESSION-ID` | The verification command, its exit code, the last part of its output (at most 12 KiB) and the changed file list, without the diff | Plain text: what went wrong and files to check |
| Handoff summary | **Draft with local model** in **Quick continue in another provider → Optional handoff details** | The conversation's last saved turns (at most 8, each side at most 4 KiB) and the repository folder name | One JSON object with exactly `done`, `next` and `prompt` |
| Summarize changes | **Summarize with local model** in the **Full file diff** panel of **Changes**; `changes summarize SESSION-ID` | The changed files with line counts and the diff | Plain text: a summary and things to check |

### Consent

Turning on the helper and a task's switch is the consent for that task's requests. Unlike Local conversations, helper requests do **not** need the shared-memory consent of the source account or of the Local profile. This is a deliberate exception: the requests go only to the loopback endpoint on this Mac, and nothing a helper request sends or returns is written to shared memory, project memory, handoff files or provider history. The audit log records `local_helper.started`, `local_helper.finished` and `local_helper.failed` with the task, byte counts and whether the input was truncated, never the prompt or the answer.

### What is sent and how it fits

Everything sent is redacted the same way as other output. The diff is sent in full by default. To fit the Local context window, AgentBridge keeps the same byte budget as the Local context preview: the context window less the output reserve and a 512-token margin, one byte per token. The instructions, the plan, the verification record and the full file list always go; then the file diffs follow in order for as long as they fit. When some do not, the note says "Truncated: only the first N of M files were sent." When not even the first fits, the start of it is sent, cut at a line. A file whose diff is too long to show is not sent, nor anything after it. For a failure, only the last part of the output that fits is sent; for a handoff, the newest turns that fit.

Each entry point has **What will be sent**, which shows the files with their byte counts, the other parts, the truncation notes and the exact text, without sending anything. In the CLI, `changes explain` and `changes summarize` take `--preview`, and `changes pr --draft-text-with-local --preview` does the same for the commit and pull request text.

### Drafts only

Every answer is a draft. Nothing is applied, saved, sent or committed by the helper. The commit and pull request text fills the sheet's fields: while they still hold the text AgentBridge proposed, the draft replaces it; if you edited them, the sheet asks first. The commit subject must be one line of up to 200 bytes, and the sheet notes when it is longer than 72 characters. If the description does not state the verification AgentBridge recorded, that line is added, so the description cannot claim more testing than ran. The CLI never combines a draft with `--confirm`: save the text you want and confirm with `--message-file`, `--body-file` and `--title`.

The failure explanation is shown under the verification result with **Use as change request**, which copies it into the **What should change?** field used by **Draft plan** (asking first if that field has text) and sends nothing. The handoff draft fills **What is done?**, **What should happen next?** and the suggested prompt, asking first if any of them has text. The change summary is labeled as the model's opinion; it is not a substitute for verification. None of these is saved.

Answers that fill fields are read strictly: exactly one JSON object with exactly the listed keys, all text, with no prose or code fence around it and no repair. Plain-text answers must be at most 32 KiB.

### When there is no draft

If the helper or the task is off, the server cannot be reached, the request times out, a limit is reached or the answer is not in the expected form, AgentBridge keeps the existing text (for the pull request, the proposed commit message, title and description) and shows a short note with the reason instead of an error dialog. Every request can be cancelled.

## Compression that remains readable

Compression changes the context supplied to a model, rather than overwriting the saved transcript with a generated summary. The compactor runs inside AgentBridge without calling another model or a paid summarization service. It extracts text from the approved history and labels it as historical, untrusted context.

The composed prompt distinguishes:

1. Protected earlier passages, with source-turn identifiers and chronological order.
2. Recent complete user/assistant turns, retained verbatim where the budget allows.
3. The complete current user request, kept separate from historical material.

Goals, decisions, constraints, negations, corrections, numbers, paths and code identifiers receive protection. Text remains ordinary language, with complete passage/code boundaries; it is not ZIP/base64, opaque abbreviations or a new private language that the model must decode. Older assistant statements remain attributed historical claims, not newly verified facts. Later instructions and corrections take precedence over earlier historical statements.

Ordinary safe compression is automatic. The preview exposes the composed text, source identifiers, byte sizes, retained/omitted counts and refusal details. It does not add an approval click to every message. When the complete current request, pinned notes or protected passages cannot fit, sending stops with an actionable explanation. A preview acknowledgement cannot override that refusal.

The selected model's context-window setting reserves space for the output and prompt overhead. Input sizing uses a conservative byte budget because different models tokenize differently. This reduces overflow risk; it is not an exact tokenizer measurement or a guarantee that a model will follow every instruction. Preservation tests check that specified constraints survive compression. Actual comprehension depends on the selected model and is a separate acceptance check.

Previously truncated legacy records cannot be reconstructed. Their loss markers remain visible. Storage capacity limits and model context limits are separate: reaching a storage limit must not silently destroy earlier source material to make a prompt fit.

Project shared-memory documents allow up to 256 turns and 2 MiB of encoded data, with 128 KiB per encoded turn pair and 64 KiB of notes. Discussion records allow 256 turns and 4 MiB, with 64 KiB per message. New writes that exceed these bounds fail while retaining the stored original. Project handoffs remain limited to 40 explicitly selected turns.

## Execution and validation

HTTP execution uses bounded streaming, cancellation and timeouts. Missing completion markers, malformed responses, server errors and over-limit output are failures rather than successful partial answers. Audit records redact sensitive text and distinguish context compression from provider-reported usage.

The repository's `.codex/ci.sh` remains the authoritative build/test entry point. Transport tests use local fixture servers, and compactor tests include Chinese/English constraints, numeric changes, negations, chronological history, code boundaries and an insufficient-budget refusal. Real-model comprehension, visible UI acceptance, Developer ID signing and Apple notarization are separate checks.

## Official references

See the [0.10.0 validation record](LOCAL_MODELS_VALIDATION.md) for completed checks and remaining acceptance gaps.

- [Ollama chat](https://docs.ollama.com/api/chat), [model listing](https://docs.ollama.com/api/tags) and [streaming](https://docs.ollama.com/api/streaming).
- [Ollama FAQ](https://docs.ollama.com/faq) and [official API metadata definitions](https://github.com/ollama/ollama/blob/main/api/types.go), including remote-model indicators.
- [LM Studio chat completions](https://lmstudio.ai/docs/developer/openai-compat/chat-completions) and [model listing](https://lmstudio.ai/docs/developer/openai-compat/models).
