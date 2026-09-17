#!/usr/bin/env python3
"""Run consumer tests against the pinned yjson generated-support contract."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


YJSON_REVISION = "db1b9f414aa0e924f0455cad4f3a7e78bfe42ba4"
YJSON_REMOTE = "https://github.com/lIlIIlIll/yjson.git"


def run(*args: str, cwd: Path | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def checkout_runtime(destination: Path, runtime_source: Path | None) -> None:
    source = str(runtime_source) if runtime_source is not None else YJSON_REMOTE
    run("git", "clone", "--quiet", "--no-checkout", source, str(destination))
    run("git", "checkout", "--quiet", "--detach", YJSON_REVISION, cwd=destination)


def align_macro_test_dependency(manifest: Path, macros: Path) -> None:
    lines = manifest.read_text(encoding="utf-8").splitlines()
    result: list[str] = []
    skipping = False
    for line in lines:
        if line.strip() == "[test-dependencies]":
            skipping = True
            continue
        if skipping and line.startswith("["):
            skipping = False
        if not skipping:
            result.append(line)
    result.extend(
        [
            "",
            "[test-dependencies]",
            f'yjson_macros = {{ path = "{macros}" }}',
        ]
    )
    manifest.write_text("\n".join(result).rstrip() + "\n", encoding="utf-8")


def write_consumer_manifest(template: Path, destination: Path, runtime: Path, macros: Path) -> None:
    value = template.read_text(encoding="utf-8")
    value = value.replace("__YJSON_RUNTIME__", str(runtime))
    value = value.replace("__YJSON_MACROS__", str(macros))
    destination.write_text(value, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--runtime",
        type=Path,
        help="optional local yjson Git checkout used as the object source",
    )
    parser.add_argument(
        "--consumer-only",
        action="store_true",
        help="skip the pinned runtime's own tests",
    )
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    consumer_source = repo / "tests" / "consumer"
    with tempfile.TemporaryDirectory(prefix="yjson-macros-characterization-") as temp_value:
        temp = Path(temp_value)
        runtime = temp / "yjson"
        consumer = temp / "consumer"
        checkout_runtime(runtime, args.runtime.resolve() if args.runtime else None)
        align_macro_test_dependency(runtime / "cjpm.toml", repo)
        (runtime / "cjpm.lock").unlink(missing_ok=True)
        if not args.consumer_only:
            run("cjpm", "test", cwd=runtime)
        shutil.copytree(consumer_source / "src", consumer / "src")
        write_consumer_manifest(
            consumer_source / "cjpm.toml.template",
            consumer / "cjpm.toml",
            runtime,
            repo,
        )
        run("cjpm", "test", cwd=consumer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
