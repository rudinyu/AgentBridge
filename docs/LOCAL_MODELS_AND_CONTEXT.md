# Local models and readable context compression

[Traditional Chinese](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)

## Provider boundary

AgentBridge 0.10 adds an explicit Local provider alongside Codex and Claude. Selecting Local connects directly to an already running model server on this Mac. It does not change the default cloud provider, use a CLI subscription, collect an API key, download a model or fall back to a paid service.

The supported protocols are Ollama's native chat API and an OpenAI-compatible local chat-completions API, including LM Studio. Default service roots are `http://127.0.0.1:11434` and `http://127.0.0.1:1234/v1`, respectively. Model discovery runs only after an explicit action. A server with no installed models is reported as such.

Only loopback endpoints are accepted. Remote hosts, URL credentials, redirects and implicit HTTP proxies are refused. Ollama cloud-model names and reported remote-model metadata are rejected. AgentBridge's network boundary covers its connection to the local service; the operator of that service remains responsible for its own routing. To disable Ollama's cloud features at the server level, see its official FAQ rather than changing global server settings from AgentBridge.

Local currently supports project-independent discussions and read-only project conversations. A read-only local conversation receives approved App-owned context; it does not gain filesystem or command tools simply because a project is selected. Isolated edits, native CLI terminals, autonomous workflow roles, active Skills/MCP and desktop control require separate tool runtimes and are unavailable for Local in this version.

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
