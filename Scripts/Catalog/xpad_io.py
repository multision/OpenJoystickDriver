"""xpad catalog retrieval and output operations."""

from __future__ import annotations

import base64
import json
import pathlib
import subprocess
import urllib.parse
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
LINUX_REPOSITORY = "torvalds/linux"
XPAD_PATH = "drivers/input/joystick/xpad.c"


def run_gh(args: list[str], failure: type[Exception]) -> str:
    command = ["gh", *args]
    result = subprocess.run(
        command, cwd=ROOT, capture_output=True, check=False, text=True
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise failure(f"{' '.join(command)} failed: {detail}")
    return result.stdout


def load_github_source(
    ref: str, failure: type[Exception]
) -> tuple[str, dict[str, Any]]:
    encoded_ref = urllib.parse.quote(ref, safe="")
    commit_document = json.loads(
        run_gh(["api", f"repos/{LINUX_REPOSITORY}/commits/{encoded_ref}"], failure)
    )
    commit = str(commit_document["sha"])
    source_document = json.loads(
        run_gh(
            [
                "api",
                "-X",
                "GET",
                f"repos/{LINUX_REPOSITORY}/contents/{XPAD_PATH}",
                "-f",
                f"ref={commit}",
            ],
            failure,
        )
    )
    source = base64.b64decode(source_document["content"]).decode()
    return source, {
        "kind": "github",
        "repository": LINUX_REPOSITORY,
        "path": XPAD_PATH,
        "requested_ref": ref,
        "commit": commit,
    }


def load_local_source(path: pathlib.Path) -> tuple[str, dict[str, Any]]:
    source = path.read_text()
    return source, {
        "kind": "local",
        "repository": LINUX_REPOSITORY,
        "path": str(path.resolve()),
        "requested_ref": None,
        "commit": None,
    }


def json_text(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def write_output(
    path: pathlib.Path, content: str, force: bool, failure: type[Exception]
) -> None:
    if path.exists():
        current = path.read_text()
        if current == content:
            return
        if not force:
            raise failure(
                f"Refusing to overwrite different file {path}; pass --force after review"
            )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def write_catalog(
    output_dir: pathlib.Path,
    candidates: list[Any],
    force: bool,
    failure: type[Exception],
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    planned = {
        output_dir / candidate.filename: json_text(candidate.profile)
        for candidate in candidates
    }

    if not force:
        conflicts = [
            path
            for path, content in planned.items()
            if path.exists() and path.read_text() != content
        ]
        if conflicts:
            names = ", ".join(str(path) for path in conflicts)
            raise failure(
                f"Refusing to overwrite different file(s): {names}; "
                "pass --force after review"
            )

    for path, content in planned.items():
        write_output(path, content, force=force, failure=failure)
