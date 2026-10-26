#!/usr/bin/env python3
"""Validate macro consumers against an explicitly selected runtime source tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


SOURCE_SCHEMA = "yjson.package-source/1"


def source_identity(root: Path) -> dict[str, object]:
    """Bind the manifest, lockfile, optional build script and every src/**/*.cj."""
    paths = [root / "cjpm.toml", root / "cjpm.lock", root / "build.cj"]
    paths.extend((root / "src").rglob("*.cj"))
    files = []
    for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix()):
        if not path.exists():
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"source entry must be a regular file: {path.relative_to(root)}")
        data = path.read_bytes()
        files.append({"path": path.relative_to(root).as_posix(), "bytes": len(data),
                      "sha256": hashlib.sha256(data).hexdigest()})
    if not any(item["path"] == "cjpm.toml" for item in files) or not any(
            str(item["path"]).startswith("src/") for item in files):
        raise ValueError("selected package must contain cjpm.toml and src/**/*.cj")
    encoded = json.dumps(files, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {"schema": SOURCE_SCHEMA, "sha256": hashlib.sha256(encoded).hexdigest(), "files": files}


def snapshot_package(source: Path, destination: Path) -> dict[str, object]:
    identity = source_identity(source)
    destination.mkdir(parents=True)
    for item in identity["files"]:
        relative = str(item["path"])
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, target)
    if identity != source_identity(source) or identity != source_identity(destination):
        raise ValueError("package source changed while it was being frozen; select a stable source tree")
    return identity


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
    result.extend(["", "[test-dependencies]", f'yjson_macros = {{ path = "{macros}" }}'])
    manifest.write_text("\n".join(result).rstrip() + "\n", encoding="utf-8")


def apply_compile_override(manifest: Path, option: str) -> None:
    value, count = re.subn(r'^override-compile-option\s*=.*$',
                          f'override-compile-option = {json.dumps(option)}',
                          manifest.read_text(encoding="utf-8"), flags=re.M)
    if count != 1:
        raise ValueError("expected exactly one package override-compile-option")
    manifest.write_text(value, encoding="utf-8")


def write_consumer_manifest(template: Path, destination: Path, runtime: Path, macros: Path,
                            package: str = "yjson_macros_characterization") -> None:
    value = template.read_text(encoding="utf-8")
    value = value.replace("__YJSON_RUNTIME__", str(runtime)).replace("__YJSON_MACROS__", str(macros))
    value = value.replace('name = "yjson_macros_characterization"', f'name = "{package}"')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(value, encoding="utf-8")


def read_examples(repo: Path) -> list[dict[str, str]]:
    profile_path = repo / "tests/doc_examples/profile.json"
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    if profile.get("schema") != "yjson.macro-doc-examples/1":
        raise ValueError("unknown macro documentation example profile")
    examples = []
    for qualified_name, symbol in profile["symbols"].items():
        source = (profile_path.parent / symbol["source"]).resolve()
        if not source.is_relative_to(repo):
            raise ValueError("example source must stay inside the macro repository")
        name = qualified_name.rsplit(".", 1)[1]
        blocks = re.finditer(r"/\*\*(.*?)\*/\s*public macro (\w+)\(", source.read_text(encoding="utf-8"), re.S)
        body = next((match.group(1) for match in blocks if match.group(2) == name), None)
        if body is None:
            raise ValueError(f"missing source documentation for {qualified_name}")
        body = "\n".join(re.sub(r"^\s*\* ?", "", line) for line in body.splitlines())
        if not re.search(r"@example[^\n]*\{run\}", body):
            raise ValueError(f"missing run directive for {qualified_name}")
        fences = re.findall(r"```(cangjie|output)\s*\n(.*?)\n```", body, re.S)
        snippets = [code for language, code in fences if language == "cangjie"]
        outputs = [code for language, code in fences if language == "output"]
        if not snippets or len(outputs) != 1:
            raise ValueError(f"expected executable snippet and one output block for {qualified_name}")
        context = profile["profiles"][symbol["profile"]]
        prelude = profile_path.parent / context["prelude"]
        if not prelude.resolve().is_relative_to(repo):
            raise ValueError("example prelude must stay inside the macro repository")
        imports = "\n".join(f"import {item}" for item in context["imports"])
        code = (f"package macro_doc_{name.lower()}\n\n" + imports + "\n\n" + prelude.read_text(encoding="utf-8") +
                "\nmain(): Unit {\n" + "\n".join(snippets) + "\n}\n")
        examples.append({"qualifiedName": qualified_name, "code": code, "output": outputs[0]})
    return examples


class Acceptance:
    def __init__(self, output: Path, runtime_source: Path, macro_source: Path):
        self.output = output
        self.replacements = [(str(output), "<stage>"), (str(runtime_source), "<runtime-source>"),
                             (str(macro_source), "<macro-source>"), (str(Path.home()), "$HOME")]
        self.commands: list[dict[str, object]] = []

    def normalize(self, value: str) -> str:
        for source, target in self.replacements:
            value = value.replace(source, target)
        return value

    def invoke(self, label: str, command: list[str], cwd: Path, *, must_succeed: bool = True,
               timeout: int = 600) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=timeout)
        output = completed.stdout + completed.stderr
        (self.output / f"{label}.log").write_text(self.normalize(output), encoding="utf-8")
        self.commands.append({"label": label, "command": [self.normalize(item) for item in command],
                              "cwd": self.normalize(str(cwd)), "exitCode": completed.returncode})
        print(f"{label}: exit={completed.returncode}", flush=True)
        if must_succeed and (completed.returncode != 0 or "An exception has occurred" in output):
            print(self.normalize(output), flush=True)
            raise RuntimeError(f"{label} failed; see {label}.log")
        return completed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True,
                        help="local runtime source tree to snapshot; no implicit historical revision")
    parser.add_argument("--runtime-sha256", help="expected yjson.package-source/1 inventory SHA-256")
    parser.add_argument("--consumer-only", action="store_true", help="skip the selected runtime's own tests")
    parser.add_argument("--output-dir", type=Path, help="new directory retaining snapshots, full examples and logs")
    parser.add_argument("--override-compile-option", default="-O2", help="cjpm dependency override (default: -O2)")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime_source = args.runtime.resolve(strict=True)
    if args.output_dir:
        output = args.output_dir.resolve()
        output.mkdir(parents=True, exist_ok=False)
        retained = True
    else:
        output = Path(tempfile.mkdtemp(prefix="yjson-macros-characterization-"))
        retained = False
    acceptance = Acceptance(output, runtime_source, repo)
    report: dict[str, object] = {"schema": "yjson.macro-characterization/2", "status": "failed",
                                 "runtimeTests": "not-run", "commands": acceptance.commands}
    succeeded = False
    try:
        runtime = output / "runtime"
        macros = output / "macros"
        report["runtimeSource"] = snapshot_package(runtime_source, runtime)
        report["macroSource"] = snapshot_package(repo, macros)
        if args.runtime_sha256 and args.runtime_sha256 != report["runtimeSource"]["sha256"]:
            raise ValueError("selected runtime source inventory does not match --runtime-sha256")
        acceptance.invoke("compiler-version", ["cjc", "-v"], output)
        acceptance.invoke("package-manager-version", ["cjpm", "--version"], output)
        align_macro_test_dependency(runtime / "cjpm.toml", macros)
        (runtime / "cjpm.lock").unlink(missing_ok=True)
        apply_compile_override(runtime / "cjpm.toml", args.override_compile_option)
        apply_compile_override(macros / "cjpm.toml", args.override_compile_option)
        report["compileOverride"] = args.override_compile_option
        options = ["--no-color"]
        if not args.consumer_only:
            acceptance.invoke("runtime-test", ["cjpm", "test", *options], runtime)
            report["runtimeTests"] = "passed"
        consumer = output / "consumer"
        shutil.copytree(repo / "tests/consumer/src", consumer / "src")
        template = repo / "tests/consumer/cjpm.toml.template"
        write_consumer_manifest(template, consumer / "cjpm.toml", runtime, macros)
        apply_compile_override(consumer / "cjpm.toml", args.override_compile_option)
        acceptance.invoke("consumer-test", ["cjpm", "test", *options], consumer)
        report["consumerTests"] = "passed"
        negative = output / "removed-json-value"
        (negative / "src").mkdir(parents=True)
        shutil.copyfile(repo / "tests/compile_fail/removed_json_value.cj", negative / "src/main.cj")
        write_consumer_manifest(template, negative / "cjpm.toml", runtime, macros)
        apply_compile_override(negative / "cjpm.toml", args.override_compile_option)
        rejected = acceptance.invoke("removed-json-value", ["cjpm", "build"], negative,
                                     must_succeed=False)
        diagnostic = rejected.stdout + rejected.stderr
        if rejected.returncode == 0 or not re.search(
                r"(?im)^.*(?:undeclared|undefined|cannot find|not (?:defined|found|imported)).*JsonValue.*$|"
                r"(?im:^.*JsonValue.*(?:undeclared|undefined|not (?:defined|found|imported)).*$)", diagnostic):
            raise RuntimeError("removed @JsonValue did not fail with its missing-macro diagnostic")
        report["removedMacro"] = "rejected"
        report["examples"] = []
        for example in read_examples(repo):
            name = example["qualifiedName"].rsplit(".", 1)[1].lower()
            example_dir = output / f"example-{name}"
            (example_dir / "src").mkdir(parents=True)
            (example_dir / "src/main.cj").write_text(example["code"], encoding="utf-8")
            write_consumer_manifest(template, example_dir / "cjpm.toml", runtime, macros,
                                    package=f"macro_doc_{name}")
            apply_compile_override(example_dir / "cjpm.toml", args.override_compile_option)
            acceptance.invoke(f"example-{name}-build", ["cjpm", "build"], example_dir)
            binary = example_dir / "target/release/bin/main"
            if not binary.is_file():
                binary = binary.with_suffix(".exe")
            executed = acceptance.invoke(f"example-{name}-run", [str(binary)], example_dir, timeout=10)
            if executed.stdout.replace("\r\n", "\n").strip("\n") != example["output"].strip("\n"):
                raise RuntimeError(f"{example['qualifiedName']} output differs from its source output block")
            report["examples"].append({"qualifiedName": example["qualifiedName"], "status": "passed",
                                        "consumer": f"example-{name}/src/main.cj",
                                        "sha256": hashlib.sha256(example["code"].encode()).hexdigest()})
        report["status"] = "passed"
        succeeded = True
        print("PASS: runtime selection, consumer semantics, removed macro diagnostic and four source examples", flush=True)
        return 0
    finally:
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if succeeded and not retained:
            shutil.rmtree(output)
        else:
            print(f"evidence: {str(output).replace(str(Path.home()), '$HOME')}", flush=True)
            print("output directory retained for inspection", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
