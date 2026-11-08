#!/usr/bin/env python3
"""Create a private loopback-only fixture for local-model CLI and App review."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
import textwrap
import uuid


REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "build"
PRIVATE_TMP = Path("/private/tmp")
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
MODEL = "agentbridge-offline-fixture"


class FixtureError(Exception):
    pass


def output_path(raw: str) -> Path:
    candidate = Path(raw)
    if not candidate.is_absolute() or ".." in candidate.parts:
        raise FixtureError("--root must be an absolute path under this checkout's build/ directory.")
    if BUILD.is_symlink() or not BUILD.is_dir():
        raise FixtureError(f"The repository build directory must already exist and must not be a symlink: {BUILD}")
    try:
        canonical_build = BUILD.resolve(strict=True)
        canonical_build.relative_to(REPO.resolve(strict=True))
        if candidate.parent.resolve(strict=True) != canonical_build:
            raise FixtureError(f"--root must be a new direct child of {canonical_build}.")
    except (OSError, RuntimeError, ValueError) as error:
        raise FixtureError("Could not safely resolve the requested fixture path.") from error
    if not SAFE_NAME.fullmatch(candidate.name) or ".." in candidate.name:
        raise FixtureError("--root child name may contain only letters, numbers, dot, underscore, and hyphen.")
    destination = canonical_build / candidate.name
    if destination.exists() or destination.is_symlink():
        raise FixtureError(f"Refusing to reuse an existing fixture output directory: {destination}")
    return destination


def inside_git(path: Path) -> bool:
    current = path.resolve(strict=True)
    while True:
        if (current / ".git").exists():
            return True
        if current == current.parent:
            return False
        current = current.parent


def private_dir(path: Path) -> None:
    path.mkdir(mode=0o700)
    os.chmod(path, 0o700)


def private_file(path: Path, content: str, mode: int = 0o600) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(content)
    os.chmod(path, mode)


def make_server_source() -> str:
    return textwrap.dedent(
        """\
        #!/usr/bin/env python3
        import argparse, datetime, json, os, signal, threading, time
        from pathlib import Path
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        MODEL = "agentbridge-offline-fixture"
        REPLY = "Offline local model fixture reply. No cloud service was contacted."
        MAX_REQUEST_BYTES = 2 * 1024 * 1024

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, _format, *_args): pass
            def send_json(self, value):
                body = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            def do_GET(self):
                if self.client_address[0] != "127.0.0.1":
                    self.send_error(403); return
                if self.path == "/api/tags":
                    self.send_json({"models": [{"name": MODEL, "model": MODEL, "size": 1,
                        "digest": "offline-fixture", "details": {"family": "offline", "parameter_size": "fixture"}}]})
                elif self.path == "/v1/models":
                    self.send_json({"object": "list", "data": [{"id": MODEL, "object": "model",
                        "created": 0, "owned_by": "offline-fixture", "context_window": 8192}]})
                else:
                    self.send_error(404)
            def do_POST(self):
                if self.client_address[0] != "127.0.0.1":
                    self.send_error(403); return
                if self.path not in ("/api/chat", "/v1/chat/completions"):
                    self.send_error(404); return
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    if size <= 0 or size > MAX_REQUEST_BYTES:
                        self.send_error(413); return
                    request = json.loads(self.rfile.read(size))
                    if request.get("model") != MODEL or request.get("stream") is not True:
                        self.send_error(400, "Expected the fixture model and streaming mode."); return
                    messages = request.get("messages")
                    if not isinstance(messages, list):
                        self.send_error(400, "Expected messages."); return
                    prompt = "\\n".join(str(item.get("content", "")) for item in messages if isinstance(item, dict))
                except (ValueError, TypeError, json.JSONDecodeError):
                    self.send_error(400, "Invalid JSON request."); return

                log_path = self.server.prompt_log
                entry = {"receivedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "path": self.path, "model": MODEL, "prompt": prompt}
                fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0))
                with os.fdopen(fd, "ab") as stream:
                    stream.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")).encode() + b"\\n")
                    stream.flush()
                time.sleep(self.server.response_delay)
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson" if self.path == "/api/chat" else "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    pieces = (REPLY[:24], REPLY[24:])
                    if self.path == "/api/chat":
                        for piece in pieces:
                            event = {"model": MODEL, "message": {"role": "assistant", "content": piece}, "done": False}
                            self.wfile.write(json.dumps(event, separators=(",", ":")).encode() + b"\\n")
                            self.wfile.flush()
                        event = {"model": MODEL, "message": {"role": "assistant", "content": ""}, "done": True,
                            "done_reason": "stop", "prompt_eval_count": max(1, len(prompt.encode()) // 5),
                            "eval_count": max(1, len(REPLY.split()))}
                        self.wfile.write(json.dumps(event, separators=(",", ":")).encode() + b"\\n")
                    else:
                        for piece in pieces:
                            event = {"id": "offline-fixture", "choices": [{"index": 0,
                                "delta": {"content": piece}, "finish_reason": None}]}
                            self.wfile.write(b"data: " + json.dumps(event, separators=(",", ":")).encode() + b"\\n\\n")
                            self.wfile.flush()
                        finish = {"id": "offline-fixture", "choices": [{"index": 0,
                            "delta": {}, "finish_reason": "stop"}]}
                        self.wfile.write(b"data: " + json.dumps(finish, separators=(",", ":")).encode() + b"\\n\\n")
                        usage = {"id": "offline-fixture", "choices": [], "usage": {
                            "prompt_tokens": max(1, len(prompt.encode()) // 5),
                            "completion_tokens": max(1, len(REPLY.split()))}}
                        self.wfile.write(b"data: " + json.dumps(usage, separators=(",", ":")).encode() + b"\\n\\n")
                        self.wfile.write(b"data: [DONE]\\n\\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument("--private-home", required=True, type=Path)
            parser.add_argument("--state-path", required=True, type=Path)
            parser.add_argument("--fixture-id", required=True)
            parser.add_argument("--response-delay", type=float, default=0)
            args = parser.parse_args()
            if not 0 <= args.response_delay <= 10: parser.error("response delay must be from 0 to 10 seconds")
            os.umask(0o077)
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.daemon_threads = True
            server.prompt_log = args.private_home / "local-model-prompts.jsonl"
            server.response_delay = args.response_delay
            state = {"host": "127.0.0.1", "port": server.server_address[1], "pid": os.getpid(), "fixtureID": args.fixture_id}
            fd = os.open(args.state_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(state, stream, separators=(",", ":")); stream.write("\\n")
            def stop(_signum, _frame): threading.Thread(target=server.shutdown, daemon=True).start()
            signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
            print("READY 127.0.0.1:%d" % state["port"], flush=True)
            try:
                server.serve_forever(poll_interval=0.2)
            finally:
                server.server_close()
                try:
                    current = json.loads(args.state_path.read_text(encoding="utf-8"))
                    if current.get("pid") == os.getpid() and current.get("fixtureID") == args.fixture_id:
                        args.state_path.unlink()
                except (OSError, ValueError): pass

        if __name__ == "__main__": main()
        """
    )


def base_environment(home: Path, temp: Path) -> str:
    return textwrap.dedent(
        f"""\
        export CFFIXED_USER_HOME={shlex.quote(str(home))}
        export CODEX_HOME={shlex.quote(str(home / '.codex'))}
        export CLAUDE_CONFIG_DIR={shlex.quote(str(home / '.claude'))}
        export TMPDIR={shlex.quote(str(temp))}
        export USER=offline-local-fixture
        export LANG=en_US.UTF-8
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_BASE_URL
        """
    ).rstrip()


def start_script(
    *,
    home: Path,
    server: Path,
    state: Path,
    log: Path,
    fixture_id: str,
    delay: float,
    backend: str,
    python: str,
) -> str:
    server_q, state_q, log_q = map(shlex.quote, (str(server), str(state), str(log)))
    home_q, id_q, python_q = map(shlex.quote, (str(home), fixture_id, python))
    prompt_log_q = shlex.quote(str(home / "local-model-prompts.jsonl"))
    endpoint_suffix = "/v1" if backend == "openai-compatible" else ""
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        STATE={state_q}; SERVER={server_q}; ID={id_q}
        if [[ -s "$STATE" ]]; then
          PID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$STATE" 2>/dev/null || true)"
          CMD=""; if [[ "$PID" =~ ^[0-9]+$ ]]; then CMD="$(/bin/ps -p "$PID" -o command= 2>/dev/null || true)"; fi
          if [[ "$CMD" == *"$SERVER"* && "$CMD" == *"$ID"* ]]; then printf 'Fixture server is already running.\\n'; exit 0; fi
          if [[ -n "$CMD" ]]; then printf 'Refusing to start: recorded PID does not match this fixture.\\n' >&2; exit 2; fi
          /bin/rm "$STATE"
        fi
        {python_q} "$SERVER" --private-home {home_q} --state-path "$STATE" --fixture-id "$ID" --response-delay {delay:.6f} > {log_q} 2>&1 < /dev/null &
        PID=$!
        for _ in {{1..80}}; do
          if [[ -s "$STATE" ]]; then break; fi
          if ! kill -0 "$PID" 2>/dev/null; then cat {log_q} >&2; exit 1; fi
          sleep 0.1
        done
        if [[ ! -s "$STATE" ]]; then kill "$PID" 2>/dev/null || true; printf 'Fixture server did not become ready.\\n' >&2; exit 1; fi
        PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$STATE")"
        printf 'Started loopback fixture on 127.0.0.1:%s ({backend}).\\n' "$PORT"
        printf 'AgentBridge endpoint: http://127.0.0.1:%s{endpoint_suffix}\\n' "$PORT"
        printf 'Prompt log (private): {prompt_log_q}\\n'
        """
    )


def stop_script(*, server: Path, state: Path, fixture_id: str) -> str:
    server_q, state_q, id_q = map(shlex.quote, (str(server), str(state), fixture_id))
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        STATE={state_q}; SERVER={server_q}; ID={id_q}
        if [[ ! -s "$STATE" ]]; then printf 'Fixture server is not running.\\n'; exit 0; fi
        PID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$STATE")"
        CMD="$(/bin/ps -p "$PID" -o command= 2>/dev/null || true)"
        if [[ "$CMD" != *"$SERVER"* || "$CMD" != *"$ID"* ]]; then
          printf 'Refusing to stop a process that does not match this fixture.\\n' >&2
          exit 2
        fi
        kill -TERM "$PID"
        for _ in {{1..50}}; do [[ -e "$STATE" ]] || break; sleep 0.1; done
        printf 'Stopped offline fixture server.\\n'
        """
    )


def bootstrap_script(
    *,
    home: Path,
    temp: Path,
    data: Path,
    state: Path,
    backend: str,
) -> str:
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        if [[ $# -ne 1 ]]; then printf 'Usage: %s /path/to/AgentBridge-0.12.2-dev.app/Contents/Helpers/agentbridge\\n' "$0" >&2; exit 2; fi
        CLI="$1"
        if [[ "$CLI" != /* || ! -x "$CLI" ]]; then printf 'AgentBridge CLI must be executable and absolute.\\n' >&2; exit 2; fi
        case "$CLI" in */Contents/Helpers/agentbridge|*/build/swiftpm/release/agentbridge) ;; *) printf 'Use the CLI helper from the dev app bundle or checkout build.\\n' >&2; exit 2 ;; esac
        {base_environment(home, temp)}
        STATE={shlex.quote(str(state))}
        if [[ ! -s "$STATE" ]]; then printf 'Start the fixture first with start-fixture-server.sh.\\n' >&2; exit 2; fi
        PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$STATE")"
        ENDPOINT="http://127.0.0.1:$PORT"
        if [[ "{backend}" == "openai-compatible" ]]; then ENDPOINT="$ENDPOINT/v1"; fi
        "$CLI" workspace set {shlex.quote(str(data))}
        "$CLI" local configure --backend {backend} --endpoint "$ENDPOINT" --model {MODEL} --context-window 8192 --max-output 1024
        "$CLI" local models
        "$CLI" local test
        "$CLI" chat new --provider local
        printf '\\nFixture settings are isolated under CFFIXED_USER_HOME.\\n'
        """
    )


def launch_script(*, home: Path, temp: Path, fixture_app: Path, bundle_id: str) -> str:
    setup = base_environment(home, temp)
    setup = setup.replace("export USER=offline-local-fixture\n", "")
    setup = setup.replace("export LANG=en_US.UTF-8\n", "")
    setup = setup.replace("export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n", "")
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        if [[ $# -ne 1 ]]; then printf 'Usage: %s /path/to/AgentBridge-0.12.2-dev.app\\n' "$0" >&2; exit 2; fi
        SOURCE="$1"; FIXTURE={shlex.quote(str(fixture_app))}
        if [[ "$SOURCE" != /* || "$SOURCE" == *'/../'* || "$SOURCE" == */.. ]]; then printf 'Source app path must be absolute without dot-dot traversal.\\n' >&2; exit 2; fi
        if [[ ! -x "$SOURCE/Contents/MacOS/AgentBridgeApp" || ! -f "$SOURCE/Contents/Info.plist" ]]; then printf 'Source app bundle is incomplete.\\n' >&2; exit 2; fi
        if [[ -e "$FIXTURE" || -L "$FIXTURE" ]]; then printf 'Fixture app copy exists; refusing to replace it.\\n' >&2; exit 2; fi
        /usr/bin/ditto "$SOURCE" "$FIXTURE"
        /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier {bundle_id}' "$FIXTURE/Contents/Info.plist"
        {setup}
        exec "$FIXTURE/Contents/MacOS/AgentBridgeApp"
        """
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="absolute path to a new child directory under this checkout's build/")
    parser.add_argument("--backend", choices=("ollama", "openai-compatible"), default="ollama")
    parser.add_argument("--response-delay-seconds", type=float, default=0.0)
    args = parser.parse_args()
    if not 0 <= args.response_delay_seconds <= 10:
        parser.error("--response-delay-seconds must be between 0 and 10.")
    try:
        root = output_path(args.root)
        if not PRIVATE_TMP.is_dir() or PRIVATE_TMP.is_symlink():
            raise FixtureError(f"Expected a real private temporary root at {PRIVATE_TMP}.")
        parent = Path(tempfile.mkdtemp(prefix="AgentBridgeLocalModelUI-", dir=str(PRIVATE_TMP)))
        os.chmod(parent, 0o700)
        if inside_git(parent):
            raise FixtureError(f"Refusing a temporary fixture parent inside a Git repository: {parent}")
        home, data, temp = parent / "private-home", parent / "user-data", parent / "tmp"
        for path in (home, data, temp, home / ".codex", home / ".claude"):
            private_dir(path)
        prompt_log = home / "local-model-prompts.jsonl"
        private_file(prompt_log, "")
        state, log = home / "local-model-server.json", home / "local-model-server.log"
        server = root / "local-model-server.py"
        fixture_id = uuid.uuid4().hex
        bundle_id = f"org.agentbridge.fixture.localmodel.{uuid.uuid4()}"
        fixture_app = root / "AgentBridge-LocalModelFixture.app"
        if inside_git(data):
            raise FixtureError("Fixture user data must remain outside all Git repositories.")
        root.mkdir(mode=0o700)
        os.chmod(root, 0o700)
        generated = {
            "local-model-server.py": (make_server_source(), 0o700),
            "start-fixture-server.sh": (start_script(home=home, server=server, state=state, log=log,
                fixture_id=fixture_id, delay=args.response_delay_seconds, backend=args.backend, python=sys.executable), 0o700),
            "stop-fixture-server.sh": (stop_script(server=server, state=state, fixture_id=fixture_id), 0o700),
            "bootstrap-fixture.sh": (bootstrap_script(home=home, temp=temp, data=data, state=state, backend=args.backend), 0o700),
            "launch-fixture-app.sh": (launch_script(home=home, temp=temp, fixture_app=fixture_app, bundle_id=bundle_id), 0o700),
        }
        for name, (contents, mode) in generated.items():
            private_file(root / name, contents, mode)
        suffix = "/v1" if args.backend == "openai-compatible" else ""
        manifest = {
            "schemaVersion": 1,
            "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "purpose": "Private loopback-only local-model fixture for CLI and optional GUI review.",
            "outputRoot": str(root),
            "privateFixtureParent": str(parent),
            "privateHome": str(home),
            "dataRoot": str(data),
            "fixtureAppBundle": str(fixture_app),
            "fixtureBundleIdentifier": bundle_id,
            "backend": args.backend,
            "model": MODEL,
            "configuredEndpointAfterStart": f"http://127.0.0.1:<ephemeral-port>{suffix}",
            "serverBind": "127.0.0.1 only; ephemeral port",
            "serverState": str(state),
            "serverLog": str(log),
            "privatePromptLog": str(prompt_log),
            "responseDelaySeconds": args.response_delay_seconds,
            "realProviderCalls": False,
            "networkAccess": "127.0.0.1 loopback only",
            "realProviderCredentialsUsed": False,
            "modelDownloads": False,
            "autoLaunch": False,
            "environment": {
                "CFFIXED_USER_HOME": str(home),
                "CODEX_HOME": str(home / ".codex"),
                "CLAUDE_CONFIG_DIR": str(home / ".claude"),
                "TMPDIR": str(temp),
                "API key and base URL environment variables are unset": True,
            },
            "commands": {
                "startServer": ["bash", str(root / "start-fixture-server.sh")],
                "bootstrapCLI": ["bash", str(root / "bootstrap-fixture.sh"), "/path/to/AgentBridge-0.12.2-dev.app/Contents/Helpers/agentbridge"],
                "launchApp": ["bash", str(root / "launch-fixture-app.sh"), "/path/to/AgentBridge-0.12.2-dev.app"],
                "stopServer": ["bash", str(root / "stop-fixture-server.sh")],
            },
        }
        private_file(root / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        readme = textwrap.dedent(
            f"""\
            Local model offline fixture

            The fake model server binds only 127.0.0.1 on an OS-selected ephemeral port.
            It returns streamed fixture text and records prompts in a private log. It
            never contacts a provider, reads provider credentials, downloads a model,
            or starts automatically.

            Fixture: {root}
            Backend/model: {args.backend} / {MODEL}
            Private CFFIXED_USER_HOME: {home}
            User data root: {data}
            Private prompt log: {prompt_log}
            Optional app copy: {fixture_app}

            1. Start the server:
               bash {shlex.quote(str(root / 'start-fixture-server.sh'))}
            2. Bootstrap the isolated CLI profile and create a local chat:
               bash {shlex.quote(str(root / 'bootstrap-fixture.sh'))} /path/to/AgentBridge-0.12.2-dev.app/Contents/Helpers/agentbridge
            3. Use the chat ID printed by bootstrap:
               printf '%s\\n' 'Preserve this marker: LOCAL_FIXTURE_CONTEXT_42' | agentbridge chat send CHAT-ID
               printf '%s\\n' 'What marker should remain in the context?' | agentbridge local preview discussion CHAT-ID
               printf '%s\\n' 'What marker should remain in the context?' | agentbridge chat send CHAT-ID
            4. Stop the server:
               bash {shlex.quote(str(root / 'stop-fixture-server.sh'))}
            5. Optional GUI review, only when explicitly run:
               bash {shlex.quote(str(root / 'launch-fixture-app.sh'))} /path/to/AgentBridge-0.12.2-dev.app

            No app is launched and no service is started by this generator.
            """
        )
        private_file(root / "README.txt", readme)
        print(f"Created local-model offline fixture: {root}")
        print(f"Manifest: {root / 'manifest.json'}")
        print(f"Private home and prompt log: {home}")
        print(f"Start server: bash {shlex.quote(str(root / 'start-fixture-server.sh'))}")
        print("Real provider calls: false; network: loopback only; app auto-launch: false")
        return 0
    except (FixtureError, OSError) as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
