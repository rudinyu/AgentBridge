#!/usr/bin/env python3
"""Create a private, offline fixture for the chat-first GUI workflow."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import tempfile
import textwrap
import uuid


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
BUILD_ROOT = REPOSITORY_ROOT / "build"
PRIVATE_TMP_ROOT = Path("/private/tmp")
SAFE_CHILD_NAME = re.compile(r"^[A-Za-z0-9._-]+$")


class FixtureError(Exception):
    pass


def output_root_from_argument(raw_path: str) -> Path:
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        raise FixtureError("--root must be an absolute path under this repository's build/ directory.")
    if ".." in candidate.parts:
        raise FixtureError("--root must not contain a dot-dot path component.")
    if BUILD_ROOT.is_symlink() or not BUILD_ROOT.is_dir():
        raise FixtureError(f"The repository build directory must already exist and must not be a symlink: {BUILD_ROOT}")
    try:
        canonical_build = BUILD_ROOT.resolve(strict=True)
        canonical_repository = REPOSITORY_ROOT.resolve(strict=True)
        canonical_build.relative_to(canonical_repository)
        canonical_parent = candidate.parent.resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        raise FixtureError("Could not safely resolve the requested fixture path.") from error
    if canonical_parent != canonical_build:
        raise FixtureError(f"--root must be a new direct child of {canonical_build}.")
    if not candidate.name or candidate.name in {".", ".."} or ".." in candidate.name:
        raise FixtureError("--root must have a simple new child directory name without dot-dot.")
    if not SAFE_CHILD_NAME.fullmatch(candidate.name):
        raise FixtureError("--root child name may contain only letters, numbers, dot, underscore, and hyphen.")
    destination = canonical_build / candidate.name
    if destination.exists() or destination.is_symlink():
        raise FixtureError(f"Refusing to reuse an existing fixture output directory: {destination}")
    return destination


def is_inside_git_repository(path: Path) -> bool:
    current = path.resolve(strict=True)
    while True:
        if (current / ".git").exists():
            return True
        if current == current.parent:
            return False
        current = current.parent


def make_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700)
    os.chmod(path, 0o700)


def write_private_file(path: Path, contents: str, mode: int = 0o600) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.write(contents)
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise
    os.chmod(path, mode)


def codex_fake(*, prompt_log_path: Path, provider_delay_seconds: float) -> str:
    values = {
        "@PROMPT_LOG_PATH@": shlex.quote(str(prompt_log_path)),
        "@PROVIDER_DELAY_SECONDS@": f"{provider_delay_seconds:.6f}",
    }
    template = textwrap.dedent(
        """\
        #!/bin/sh
        set -eu
        umask 077
        PROMPT_LOG_PATH=@PROMPT_LOG_PATH@

        if [ "$#" -eq 2 ] && [ "$1" = "login" ] && [ "$2" = "status" ]; then
          printf '%s\\n' 'Logged in using ChatGPT'
          exit 0
        fi

        has_exec=false
        for argument in "$@"; do
          if [ "$argument" = "exec" ]; then
            has_exec=true
            break
          fi
        done
        if [ "$has_exec" != true ]; then
          printf '%s\\n' 'Offline Codex fixture rejects unsupported commands.' >&2
          exit 64
        fi

        {
          printf '\\n--- OFFLINE CODEX PROMPT BEGIN ---\\n'
          /bin/cat
          printf '\\n--- OFFLINE CODEX PROMPT END ---\\n'
        } >> "$PROMPT_LOG_PATH"

        if [ "@PROVIDER_DELAY_SECONDS@" != "0.000000" ]; then
          /bin/sleep @PROVIDER_DELAY_SECONDS@
        fi

        printf '%s\\n' \\
          '{"type":"thread.started","thread_id":"offline-codex-fixture"}' \\
          '{"type":"item.completed","item":{"type":"agent_message","text":"Offline Codex fixture reply. No real provider was called."}}' \\
          '{"type":"turn.completed"}'
        """
    )
    for placeholder, value in values.items():
        template = template.replace(placeholder, value)
    return template


def claude_fake(*, prompt_log_path: Path) -> str:
    values = {"@PROMPT_LOG_PATH@": shlex.quote(str(prompt_log_path))}
    template = textwrap.dedent(
        """\
        #!/bin/sh
        set -eu
        umask 077
        PROMPT_LOG_PATH=@PROMPT_LOG_PATH@

        saw_auth=false
        saw_auth_status=false
        for argument in "$@"; do
          if [ "$argument" = "auth" ]; then
            saw_auth=true
          elif [ "$saw_auth" = true ] && [ "$argument" = "status" ]; then
            saw_auth_status=true
          fi
        done

        if [ "$saw_auth_status" = true ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"offline-fixture","email":"fixture@example.invalid"}'
          exit 0
        fi
        if [ "$saw_auth" = true ]; then
          printf '%s\\n' 'Offline Claude fixture does not implement login or other auth commands.' >&2
          exit 64
        fi

        {
          printf '\\n--- OFFLINE CLAUDE PROMPT BEGIN ---\\n'
          /bin/cat
          printf '\\n--- OFFLINE CLAUDE PROMPT END ---\\n'
        } >> "$PROMPT_LOG_PATH"

        printf '%s\\n' \\
          '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Offline Claude fixture reply. No real provider was called."}}}' \\
          '{"type":"result","subtype":"success","is_error":false,"session_id":"offline-claude-fixture","result":"Offline Claude fixture reply. No real provider was called."}'
        """
    )
    for placeholder, value in values.items():
        template = template.replace(placeholder, value)
    return template


def bootstrap_script(
    *,
    private_home: Path,
    tmp_directory: Path,
    data_root: Path,
    codex_executable: Path,
    claude_executable: Path,
) -> str:
    values = {
        "@PRIVATE_HOME@": shlex.quote(str(private_home)),
        "@TMP_DIRECTORY@": shlex.quote(str(tmp_directory)),
        "@DATA_ROOT@": shlex.quote(str(data_root)),
        "@CODEX_EXECUTABLE@": shlex.quote(str(codex_executable)),
        "@CLAUDE_EXECUTABLE@": shlex.quote(str(claude_executable)),
    }
    template = textwrap.dedent(
        """\
        #!/bin/bash
        set -euo pipefail

        if [[ $# -ne 1 ]]; then
          printf 'Usage: %s /absolute/path/to/AgentBridge.app/Contents/Helpers/agentbridge\\n' "$0" >&2
          exit 2
        fi
        CLI_PATH="$1"
        if [[ "$CLI_PATH" != /* || ! -x "$CLI_PATH" ]]; then
          printf 'The AgentBridge CLI must be an executable absolute path.\\n' >&2
          exit 2
        fi
        case "$CLI_PATH" in
          */Contents/Helpers/agentbridge|*/build/swiftpm/release/agentbridge) ;;
          *)
            printf 'Use the agentbridge helper from the dev app bundle or this checkout build.\\n' >&2
            exit 2
            ;;
        esac

        export CFFIXED_USER_HOME=@PRIVATE_HOME@
        export CODEX_HOME=@PRIVATE_HOME@/.codex
        export CLAUDE_CONFIG_DIR=@PRIVATE_HOME@/.claude
        export TMPDIR=@TMP_DIRECTORY@
        export USER=offline-fixture
        export LANG=en_US.UTF-8
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_BASE_URL

        if [[ -e "$CFFIXED_USER_HOME/Library/Application Support/AgentBridge" ]]; then
          printf 'This fixture home has already been bootstrapped; refusing to reuse it.\\n' >&2
          exit 2
        fi

        "$CLI_PATH" workspace set @DATA_ROOT@
        "$CLI_PATH" settings usage subscription
        "$CLI_PATH" settings binary codex @CODEX_EXECUTABLE@
        "$CLI_PATH" settings binary claude @CLAUDE_EXECUTABLE@

        create_profile() {
          local provider="$1"
          local name="$2"
          local output
          local profile_id
          output="$("$CLI_PATH" profiles create --provider "$provider" --name "$name" --share-memory)"
          printf '%s\\n' "$output"
          profile_id="$(printf '%s\\n' "$output" | /usr/bin/sed -nE 's/.*設定：([[:xdigit:]-]{36}).*/\\1/p')"
          if [[ ! "$profile_id" =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
            printf 'Could not read the created %s fixture profile ID.\\n' "$provider" >&2
            exit 1
          fi
          case "$provider/$name" in
            'codex/UI Fixture Codex A') CODEX_A_ID="$profile_id" ;;
            'codex/UI Fixture Codex B') CODEX_B_ID="$profile_id" ;;
            'claude/UI Fixture Claude A') CLAUDE_A_ID="$profile_id" ;;
            'claude/UI Fixture Claude B') CLAUDE_B_ID="$profile_id" ;;
          esac
        }

        create_profile codex 'UI Fixture Codex A'
        create_profile codex 'UI Fixture Codex B'
        create_profile claude 'UI Fixture Claude A'
        create_profile claude 'UI Fixture Claude B'
        "$CLI_PATH" profiles select --provider codex "$CODEX_A_ID"
        "$CLI_PATH" profiles select --provider claude "$CLAUDE_A_ID"
        {
          printf 'codex_fixture_a=%s\\n' "$CODEX_A_ID"
          printf 'codex_fixture_b=%s\\n' "$CODEX_B_ID"
          printf 'claude_fixture_a=%s\\n' "$CLAUDE_A_ID"
          printf 'claude_fixture_b=%s\\n' "$CLAUDE_B_ID"
        } > "$CFFIXED_USER_HOME/chat-first-profile-ids.txt"
        /bin/chmod 600 "$CFFIXED_USER_HOME/chat-first-profile-ids.txt"

        printf '\\nFixture app data is isolated. No provider login command was run.\\n'
        printf 'Private data root: %s\\n' @DATA_ROOT@
        printf 'Use the app account picker to switch between the fixture profiles.\\n'
        """
    )
    for placeholder, value in values.items():
        template = template.replace(placeholder, value)
    return template


def launch_script(
    *,
    private_home: Path,
    tmp_directory: Path,
    fixture_app_bundle: Path,
    fixture_bundle_identifier: str,
) -> str:
    values = {
        "@PRIVATE_HOME@": shlex.quote(str(private_home)),
        "@TMP_DIRECTORY@": shlex.quote(str(tmp_directory)),
        "@FIXTURE_APP_BUNDLE@": shlex.quote(str(fixture_app_bundle)),
        "@FIXTURE_BUNDLE_IDENTIFIER@": shlex.quote(fixture_bundle_identifier),
    }
    template = textwrap.dedent(
        """\
        #!/bin/bash
        set -euo pipefail

        if [[ $# -ne 1 ]]; then
          printf 'Usage: %s /absolute/path/to/AgentBridge.app\\n' "$0" >&2
          exit 2
        fi
        APP_BUNDLE="$1"
        FIXTURE_APP_BUNDLE=@FIXTURE_APP_BUNDLE@
        FIXTURE_BUNDLE_IDENTIFIER=@FIXTURE_BUNDLE_IDENTIFIER@
        if [[ "$APP_BUNDLE" != /* || "$APP_BUNDLE" == *'/../'* || "$APP_BUNDLE" == */.. ]]; then
          printf 'The app bundle path must be absolute and must not contain dot-dot traversal.\\n' >&2
          exit 2
        fi
        SOURCE_APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AgentBridgeApp"
        if [[ ! -x "$SOURCE_APP_EXECUTABLE" || ! -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
          printf 'AgentBridgeApp is not executable at the supplied app bundle path.\\n' >&2
          exit 2
        fi
        if [[ -e "$FIXTURE_APP_BUNDLE" || -L "$FIXTURE_APP_BUNDLE" ]]; then
          printf 'The isolated fixture app already exists; refusing to replace it.\\n' >&2
          exit 2
        fi

        /usr/bin/ditto "$APP_BUNDLE" "$FIXTURE_APP_BUNDLE"
        FIXTURE_INFO_PLIST="$FIXTURE_APP_BUNDLE/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $FIXTURE_BUNDLE_IDENTIFIER" "$FIXTURE_INFO_PLIST"
        APP_EXECUTABLE="$FIXTURE_APP_BUNDLE/Contents/MacOS/AgentBridgeApp"
        if [[ ! -x "$APP_EXECUTABLE" ]]; then
          printf 'The copied fixture app is missing its executable.\\n' >&2
          exit 1
        fi

        export CFFIXED_USER_HOME=@PRIVATE_HOME@
        export CODEX_HOME=@PRIVATE_HOME@/.codex
        export CLAUDE_CONFIG_DIR=@PRIVATE_HOME@/.claude
        export TMPDIR=@TMP_DIRECTORY@
        export USER=offline-fixture
        export LANG=en_US.UTF-8
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_BASE_URL
        exec "$APP_EXECUTABLE"
        """
    )
    for placeholder, value in values.items():
        template = template.replace(placeholder, value)
    return template


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create local fake Codex/Claude executables and private paths for an offline chat-first GUI walkthrough."
    )
    parser.add_argument(
        "--root",
        required=True,
        help="new absolute direct child under this repository's build/ directory",
    )
    parser.add_argument(
        "--provider-delay-seconds",
        type=float,
        default=0.0,
        help="delay fake Codex responses by 0 to 10 seconds to allow offline cancellation checks (default: 0)",
    )
    args = parser.parse_args()
    if not 0 <= args.provider_delay_seconds <= 10:
        parser.error("--provider-delay-seconds must be between 0 and 10.")

    try:
        output_root = output_root_from_argument(args.root)
        if not PRIVATE_TMP_ROOT.is_dir() or PRIVATE_TMP_ROOT.is_symlink():
            raise FixtureError(f"Expected a real private temporary root at {PRIVATE_TMP_ROOT}.")

        fixture_parent = Path(tempfile.mkdtemp(prefix="AgentBridgeChatFirstUI-", dir=str(PRIVATE_TMP_ROOT)))
        os.chmod(fixture_parent, 0o700)
        if is_inside_git_repository(fixture_parent):
            raise FixtureError(f"Refusing a temporary fixture parent inside a Git repository: {fixture_parent}")

        private_home = fixture_parent / "private-home"
        data_root = fixture_parent / "user-data"
        tmp_directory = fixture_parent / "tmp"
        project_destination = fixture_parent / "new-project"
        fixture_app_bundle = output_root / "AgentBridge-UIFixture.app"
        fixture_bundle_identifier = f"org.agentbridge.fixture.{uuid.uuid4()}"
        for directory in (private_home, data_root, tmp_directory):
            make_private_directory(directory)
        for directory in (private_home / ".codex", private_home / ".claude"):
            make_private_directory(directory)
        prompt_log = private_home / "received-prompts.log"
        write_private_file(prompt_log, "")

        if project_destination.exists() or project_destination.is_symlink():
            raise FixtureError("The new Git project destination unexpectedly exists.")
        if is_inside_git_repository(data_root) or is_inside_git_repository(project_destination.parent):
            raise FixtureError("Fixture data and project destination must remain outside all Git repositories.")

        output_root.mkdir(mode=0o700)
        os.chmod(output_root, 0o700)
        fake_provider_directory = output_root / "fake-providers"
        make_private_directory(fake_provider_directory)
        codex_executable = fake_provider_directory / "codex"
        claude_executable = fake_provider_directory / "claude"
        write_private_file(
            codex_executable,
            codex_fake(prompt_log_path=prompt_log, provider_delay_seconds=args.provider_delay_seconds),
            0o700,
        )
        write_private_file(claude_executable, claude_fake(prompt_log_path=prompt_log), 0o700)

        bootstrap_path = output_root / "bootstrap-fixture.sh"
        launch_path = output_root / "launch-fixture-app.sh"
        write_private_file(
            bootstrap_path,
            bootstrap_script(
                private_home=private_home,
                tmp_directory=tmp_directory,
                data_root=data_root,
                codex_executable=codex_executable,
                claude_executable=claude_executable,
            ),
            0o700,
        )
        write_private_file(
            launch_path,
            launch_script(
                private_home=private_home,
                tmp_directory=tmp_directory,
                fixture_app_bundle=fixture_app_bundle,
                fixture_bundle_identifier=fixture_bundle_identifier,
            ),
            0o700,
        )

        fixture_marker = "CHAT_FIRST_FIXTURE_" + uuid.uuid4().hex[:12].upper()
        manifest = {
            "schemaVersion": 1,
            "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "purpose": "Offline GUI fixture for the chat-before-project flow.",
            "outputRoot": str(output_root),
            "privateFixtureParent": str(fixture_parent),
            "privateHome": str(private_home),
            "dataRoot": str(data_root),
            "fixtureAppBundle": str(fixture_app_bundle),
            "fixtureBundleIdentifier": fixture_bundle_identifier,
            "newGitProjectDestination": str(project_destination),
            "newGitProjectDestinationExists": project_destination.exists(),
            "promptLog": str(prompt_log),
            "realProviderCalls": False,
            "networkAccess": False,
            "realProviderCredentialsUsed": False,
            "fakeProviders": {
                "codex": {
                    "executable": str(codex_executable),
                    "authenticationStatus": "Logged in using ChatGPT",
                    "generalOutput": "Codex JSON event stream with a completed agent_message and turn.completed.",
                    "responseDelaySeconds": args.provider_delay_seconds,
                },
                "claude": {
                    "executable": str(claude_executable),
                    "authenticationStatus": {
                        "loggedIn": True,
                        "authMethod": "claude.ai",
                        "subscriptionType": "offline-fixture",
                    },
                    "generalOutput": "Claude stream-json content delta followed by a successful result event.",
                },
            },
            "environment": {
                "CFFIXED_USER_HOME": str(private_home),
                "CODEX_HOME": str(private_home / ".codex"),
                "CLAUDE_CONFIG_DIR": str(private_home / ".claude"),
                "TMPDIR": str(tmp_directory),
                "USER": "offline-fixture",
                "LANG": "en_US.UTF-8",
            },
            "apiCredentialEnvironmentVariablesRemoved": [
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "OPENAI_BASE_URL",
                "ANTHROPIC_BASE_URL",
            ],
            "bootstrapCommand": [
                "bash",
                str(bootstrap_path),
                "/absolute/path/to/AgentBridge.app/Contents/Helpers/agentbridge",
            ],
            "launchCommand": [
                "bash",
                str(launch_path),
                "/absolute/path/to/AgentBridge-0.9.0-dev.app",
            ],
            "suggestedGUIFlow": [
                "Run bootstrap-fixture.sh with the CLI inside the dev app bundle; it configures an isolated user data root, fake provider paths, and four shared-memory test accounts without running provider login.",
                f"Launch the dev app with launch-fixture-app.sh. It copies the source app to {fixture_app_bundle}, sets bundle ID {fixture_bundle_identifier} for isolated app preferences, and supplies this fixture's CFFIXED_USER_HOME, CODEX_HOME, CLAUDE_CONFIG_DIR, and TMPDIR.",
                f"Create a Codex chat and send: Please plan a tiny local-only plant-watering tracker. Keep data on this Mac. Marker: {fixture_marker}",
                "Switch the discussion to a Claude fixture account and ask it to continue the local-only plan. The private prompt log can confirm that the approved earlier context was included.",
                "Open Create Git Project, choose the provided newGitProjectDestination, review the selected turns and digest, then apply the preview.",
                "Continue in the created project session with a request to preserve the local-only scope. Check the private prompt log for the original marker to confirm project memory carried forward.",
            ],
        }
        write_private_file(
            output_root / "manifest.json",
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        )
        write_private_file(
            output_root / "README.txt",
            textwrap.dedent(
                f"""\
                Offline chat-first GUI fixture

                This fixture uses local fake provider executables only. It does not make
                network requests, call a model, read provider credentials, or initialize
                Git. The new project destination below remains absent until the GUI apply
                action is explicitly used.

                Fixture output: {output_root}
                Private home: {private_home}
                User data root: {data_root}
                Fixture app copy: {fixture_app_bundle}
                Fixture app bundle ID: {fixture_bundle_identifier}
                Fake Codex response delay: {args.provider_delay_seconds:g} seconds
                New project destination (not created): {project_destination}
                Received prompt log (private): {prompt_log}

                1. Bootstrap with the helper CLI from the packaged app:
                   bash {shlex.quote(str(bootstrap_path))} /absolute/path/to/AgentBridge-0.9.0-dev.app/Contents/Helpers/agentbridge
                2. Launch with the isolated environment; the script copies the supplied app and changes only the copy's bundle ID:
                   bash {shlex.quote(str(launch_path))} /absolute/path/to/AgentBridge-0.9.0-dev.app
                3. Follow suggestedGUIFlow in manifest.json.
                """
            ),
        )

        if project_destination.exists() or project_destination.is_symlink():
            raise FixtureError("Fixture generation unexpectedly created the Git project destination.")
        print(f"Created offline GUI fixture: {output_root}")
        print(f"Manifest: {output_root / 'manifest.json'}")
        print(f"Private data root: {data_root}")
        print(f"Fixture app copy: {fixture_app_bundle}")
        print(f"Fixture app bundle ID: {fixture_bundle_identifier}")
        print(f"New project destination (not created): {project_destination}")
        print(f"Bootstrap: bash {shlex.quote(str(bootstrap_path))} /path/to/AgentBridge.app/Contents/Helpers/agentbridge")
        print(f"Launch: bash {shlex.quote(str(launch_path))} /path/to/AgentBridge-0.9.0-dev.app")
        print("Real provider calls: false")
        return 0
    except (FixtureError, OSError) as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
