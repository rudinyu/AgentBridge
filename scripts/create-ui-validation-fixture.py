#!/usr/bin/env python3
"""Create an isolated, offline AgentBridge UI validation repository.

The destination must be a new directory below this checkout's build/ folder.
The generated `codex` executable returns synthetic subscription status and
deterministic JSONL responses; it never contacts a provider or reads secrets.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import textwrap


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
BUILD_ROOT = REPOSITORY_ROOT / "build"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        required=True,
        type=Path,
        help="absolute path to a new fixture directory below this checkout's build/ folder",
    )
    parser.add_argument(
        "--repair-round",
        action="store_true",
        help="make the first fake review request one in-scope repair before passing",
    )
    parser.add_argument(
        "--workspace-root",
        type=Path,
        help="optional absolute path for fresh temporary workspace data under /private/tmp",
    )
    return parser.parse_args()


def git(executable: str, source: Path, home: Path, *arguments: str) -> None:
    environment = {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_AUTHOR_NAME": "AgentBridge UI Fixture",
        "GIT_AUTHOR_EMAIL": "agentbridge-ui-fixture@example.invalid",
        "GIT_COMMITTER_NAME": "AgentBridge UI Fixture",
        "GIT_COMMITTER_EMAIL": "agentbridge-ui-fixture@example.invalid",
    }
    subprocess.run(
        [executable, "-C", str(source), *arguments],
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )


def fake_codex_source(repair_round: bool) -> str:
    repair_literal = "True" if repair_round else "False"
    return textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import os
        from pathlib import Path
        import re
        import sys

        REPAIR_ROUND = {repair_literal}

        if sys.argv[1:] == ["login", "status"]:
            print("Logged in using ChatGPT")
            raise SystemExit(0)

        prompt = sys.stdin.read()
        home = Path(os.environ.get("HOME", "."))
        home.mkdir(parents=True, exist_ok=True)
        with (home / "agentbridge-ui-fixture-prompts.log").open("a", encoding="utf-8") as stream:
            stream.write(prompt + "\\n---END PROMPT---\\n")

        def emit(text):
            events = [
                {{"type": "thread.started", "thread_id": "22222222-2222-4222-8222-222222222222"}},
                {{"type": "item.completed", "item": {{"type": "agent_message", "text": text}}}},
                {{"type": "turn.completed"}},
            ]
            for event in events:
                print(json.dumps(event, separators=(",", ":")))

        if "You are the read-only planner" in prompt:
            plan = {{
                "version": 1,
                "tasks": [
                    {{"id": "research", "role": "researcher", "title": "Inspect greeting", "prompt": "Read the isolated greeting file.", "dependencies": []}},
                    {{"id": "implement", "role": "implementer", "title": "Update greeting", "prompt": "Update greeting.txt in the isolated workspace.", "dependencies": ["research"]}},
                    {{"id": "review", "role": "reviewer", "title": "Review exact diff", "prompt": "Review only the exact diff snapshot.", "dependencies": ["implement"]}},
                ],
                "changeScope": {{
                    "title": "Update greeting",
                    "summary": "Change only greeting.txt in the isolated workspace.",
                    "steps": ["Replace the isolated greeting text."],
                }},
            }}
            emit(json.dumps(plan, separators=(",", ":")))
        elif "Autonomous role: researcher" in prompt:
            emit("Inspected the isolated greeting file.")
        elif "Autonomous role: implementer" in prompt:
            Path("greeting.txt").write_text("Updated greeting.\\n", encoding="utf-8")
            emit("Updated greeting.txt in the isolated workspace.")
        elif "You are a read-only independent reviewer" in prompt:
            match = re.search(r'"diffDigest":"([0-9a-f]{{64}})"', prompt)
            if not match:
                raise SystemExit(3)
            review_count_path = home / "agentbridge-ui-fixture-review-count.txt"
            review_count = int(review_count_path.read_text(encoding="utf-8")) + 1 if review_count_path.exists() else 1
            review_count_path.write_text(str(review_count), encoding="utf-8")
            if REPAIR_ROUND and review_count == 1:
                review = {{
                    "version": 1,
                    "diffDigest": match.group(1),
                    "verdict": "changesRequested",
                    "summary": "One bounded in-scope repair is requested.",
                    "findings": [{{"path": "greeting.txt", "severity": "low", "summary": "Keep the approved punctuation.", "inScope": True}}],
                }}
            else:
                review = {{
                    "version": 1,
                    "diffDigest": match.group(1),
                    "verdict": "pass",
                    "summary": "No findings.",
                    "findings": [],
                }}
            emit(json.dumps(review, separators=(",", ":")))
        else:
            raise SystemExit(4)
        """
    )


def workspace_root_for_fixture(root: Path, requested: Path | None) -> Path:
    temporary_parent = Path("/private/tmp").resolve()
    if requested is None:
        identifier = re.sub(r"[^A-Za-z0-9_-]+", "-", root.name).strip("-")[:80] or "fixture"
        candidate = temporary_parent / f"AgentBridge-UI-{identifier}"
    else:
        if not requested.is_absolute():
            raise ValueError("--workspace-root must be an absolute path.")
        if os.path.lexists(requested):
            raise FileExistsError(f"Refusing to overwrite an existing workspace data path: {requested}")
        candidate = requested.resolve()

    if candidate == temporary_parent or temporary_parent not in candidate.parents:
        raise ValueError("The workspace data root must be a child of /private/tmp.")
    if os.path.lexists(candidate):
        raise FileExistsError(f"Refusing to overwrite an existing workspace data path: {candidate}")
    for ancestor in (candidate, *candidate.parents):
        if os.path.lexists(ancestor / ".git"):
            raise ValueError(f"The workspace data root must be outside Git repositories: {ancestor}")
    return candidate


def create_fixture(
    root_argument: Path,
    repair_round: bool,
    workspace_root_argument: Path | None = None,
) -> dict[str, str | bool]:
    if not root_argument.is_absolute():
        raise ValueError("--root must be an absolute path.")

    build_root = BUILD_ROOT.resolve()
    root = root_argument.resolve()
    if root == build_root or build_root not in root.parents:
        raise ValueError(f"--root must be a new child directory under {build_root}.")
    if os.path.lexists(root_argument) or os.path.lexists(root):
        raise FileExistsError(f"Refusing to overwrite an existing path: {root_argument}")
    workspace_root = workspace_root_for_fixture(root, workspace_root_argument)

    git_executable = shutil.which("git", path="/usr/bin:/bin:/usr/sbin:/sbin")
    if not git_executable:
        raise FileNotFoundError("git is required to create the local fixture repository.")

    root.parent.mkdir(parents=True, exist_ok=True)
    root.mkdir(exist_ok=False)
    workspace_root_created = False
    try:
        workspace_root.mkdir(parents=True, exist_ok=False)
        workspace_root_created = True
        source = root / "source"
        home = root / "home"
        codex_home = root / "codex-home"
        app_data = home / "Library" / "Application Support" / "AgentBridge"
        binary_directory = root / "bin"
        for directory in (source, home, codex_home, binary_directory):
            directory.mkdir(parents=True)
        app_data.mkdir(parents=True)

        (source / "README.md").write_text(
            "# AgentBridge Offline UI Fixture\n\n"
            "This disposable repository is for local UI validation only. Its fake `codex` executable returns synthetic subscription status and JSONL; it makes no provider calls and has no API key.\n",
            encoding="utf-8",
        )
        (source / "greeting.txt").write_text("Original greeting.\n", encoding="utf-8")
        (source / ".gitignore").write_text(".ui-fixture-ci-ran\n", encoding="utf-8")
        codex_directory = source / ".codex"
        codex_directory.mkdir()
        ci_script = codex_directory / "ci.sh"
        ci_script.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "test -s greeting.txt\n"
            "printf 'offline fixture CI passed\\n' > .ui-fixture-ci-ran\n",
            encoding="utf-8",
        )
        ci_script.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)

        git(git_executable, source, home, "init", "-q")
        git(git_executable, source, home, "add", "README.md", "greeting.txt", ".gitignore", ".codex/ci.sh")
        git(git_executable, source, home, "commit", "-q", "-m", "Create offline UI fixture")

        codex = binary_directory / "codex"
        codex.write_text(fake_codex_source(repair_round), encoding="utf-8")
        codex.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)

        manifest: dict[str, str | bool] = {
            "fixtureType": "offline-fake-subscription",
            "realProviderCalls": False,
            "apiKeyRequired": False,
            "repairRoundEnabled": repair_round,
            "root": str(root),
            "sourceRepositoryPath": str(source),
            "codexBinaryPath": str(codex),
            "homePath": str(home),
            "codexHomePath": str(codex_home),
            "appSupportPath": str(app_data),
            "workspaceRootPath": str(workspace_root),
            "projectCIPath": str(ci_script),
        }
        (root / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        return manifest
    except Exception:
        shutil.rmtree(root, ignore_errors=True)
        if workspace_root_created:
            shutil.rmtree(workspace_root, ignore_errors=True)
        raise


def main() -> int:
    arguments = parse_arguments()
    try:
        manifest = create_fixture(arguments.root, arguments.repair_round, arguments.workspace_root)
    except (FileExistsError, FileNotFoundError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"fixture creation failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
