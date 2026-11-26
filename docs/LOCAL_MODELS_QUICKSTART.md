# Local models quick start: Ollama and LM Studio

[Traditional Chinese](LOCAL_MODELS_QUICKSTART.zh-TW.md) · [Full guide](LOCAL_MODELS_AND_CONTEXT.md)

AgentBridge has a built-in **Local** provider that connects directly to Ollama or LM Studio running on this Mac. It does not go through Codex or Claude, needs no API key and uses no paid service. AgentBridge connects only to loopback addresses (`127.0.0.1`/`localhost`).

This page shows how to connect each server. For limits and details, see [Local Models and Readable Context Compression](LOCAL_MODELS_AND_CONTEXT.md).

## Ollama

Ollama is the easiest to set up, and AgentBridge has a guided flow for it.

### In the app

1. Choose **Local** as the provider and open the Local model settings.
2. Under **Guided Ollama setup** at the top, click **Check Ollama setup**, then follow the result:
   - **Not installed:** click **Open the Ollama download page** and install it yourself.
   - **Installed but not running:** click **Start Ollama**.
   - **Running:** AgentBridge recommends a model for this Mac's memory; you can also enter any other model name. Click **Download model**.

   | Physical memory | Recommended model | Download |
   | --- | --- | --- |
   | Under 12 GB | `qwen2.5-coder:3b` | about 1.9 GB |
   | 12 GB or more | `qwen2.5-coder:7b` | about 4.7 GB |
   | 24 GB or more | `qwen2.5-coder:14b` | about 9 GB |
   | 48 GB or more | `qwen2.5-coder:32b` | about 20 GB |

3. When the download finishes, the Local settings switch to the Ollama backend and this model, are saved, and a connection test runs.
4. Click **Detect context size**, then **Use N tokens**, then save.

Ollama uses the context length AgentBridge sends with each request. The suggestion is therefore the model's maximum context, capped by memory: 8k under 12 GB, 16k under 24 GB, 32k under 48 GB, and 64k tokens above that.

Ollama unloads an idle model after 5 minutes by default. If you come back to it often, set **Keep model loaded** (for example 1 hour) so it answers sooner; the model then holds its memory while idle. CLI: `--keep-alive MINUTES|forever|default` with `agentbridge local configure`.

### With the CLI

```sh
agentbridge local setup-check
agentbridge local pull qwen2.5-coder:7b --confirm
agentbridge local context --apply
```

`local pull` switches to the model once it is downloaded. For a model you pulled with Ollama yourself:

```sh
agentbridge local configure --backend ollama --endpoint http://127.0.0.1:11434 --model MODEL-ID
agentbridge local context --apply
```

## LM Studio

LM Studio connects through its OpenAI-compatible API.

1. In LM Studio, download and load a model, then start the local server on the Developer tab. The default address is `http://127.0.0.1:1234`.
   - **Set the Context Length when LM Studio loads the model.** LM Studio keeps the length it loaded with and ignores the value in AgentBridge's requests.
2. In AgentBridge, choose **Local**, set the backend to **OpenAI-compatible · LM Studio**, and enter `http://127.0.0.1:1234/v1`. Click **Refresh models** and select the model.
3. Click **Detect context size**. The suggestion is the length LM Studio loaded the model with. Click **Use N tokens**, then save.

With the CLI:

```sh
agentbridge local configure --backend openai-compatible --endpoint http://127.0.0.1:1234/v1 --model MODEL-ID
agentbridge local context --apply
```

Before each run, AgentBridge checks the context LM Studio actually loaded. If the AgentBridge context window is larger, the run is refused before anything is sent, and the message shows both numbers. Lower the AgentBridge setting, or reload the model in LM Studio with a longer context.

Other OpenAI-compatible servers connect the same way, but they do not report their context size, so set the context window yourself.

## Check the connection

```sh
agentbridge local models
agentbridge local test
```

`local models` only lists the server's models. `local test` checks the connection without generating a reply.

## What you can do with it

- **Discussions and read-only project conversations:** create a Local chat in the app, or run `agentbridge chat new --provider local`.
- **Isolated changes:** choose **Isolated changes** when creating a project session. The flow is: draft a plan → review and approve it → select files in **Changes** → preview → run. The model returns complete file contents, and AgentBridge shows them as a diff for you to review.
  - When the selected files do not fit, the preview suggests splitting them into groups, each with a **Select these files** button. Approve the plan again before running each group.
- **Local model helper:** in Codex and Claude work, the local model can draft commit and pull request text, explain a failed verification, write a handoff summary or summarize changes. It is off by default; turn it on under **Local model helper** in the Local model settings.

## What Local cannot do

A local model has no tools: it cannot read files, run commands or search the project, and sees only the files you select. Local also does not support the native CLI terminal, Skills/MCP, autonomous workflow roles or desktop control.

Local suits focused work on a few files. When the model needs to explore the project or run tests, use Codex or Claude.

## Troubleshooting

- **The model list is empty:** check that the server is running, the model is downloaded or loaded, and the address is a loopback address.
- **A run is refused because LM Studio loaded a smaller context:** lower the AgentBridge context window, or reload the model in LM Studio with a longer context.
- **The preview says the input or output is over budget:** select fewer or smaller files, run the suggested groups one at a time, or raise the context window and output reserve in the Local model settings (with the CLI, `agentbridge local configure` with `--context-window` and `--max-output`, together with `--backend`, `--endpoint` and `--model`).
- **Replies are slow or memory runs out:** switch to a smaller model, or lower the context window.
