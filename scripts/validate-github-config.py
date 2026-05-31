#!/usr/bin/env python3
"""Deterministic policy checks for GitHub workflow and Dependabot config."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:
    print(
        "PyYAML is required. Install it with: "
        "python -m pip install -r requirements-automation.txt",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


EXPECTED_WORKFLOWS = {
    "Runtime CI": ".github/workflows/ci.yml",
    "LLM Harness": ".github/workflows/llm-harness.yml",
    "Dependabot Auto Merge": ".github/workflows/dependabot-auto-merge.yml",
}
EXPECTED_DEPENDABOT_UPDATES = {
    ("github-actions", "/"),
    ("pip", "/"),
    ("devcontainers", "/"),
    ("docker", "/.devcontainer"),
}
GROUPED_DEPENDABOT_ECOSYSTEMS = {"github-actions", "pip", "docker"}
DEVCONTAINER_GROUP_KEYS = {
    "groups",
    "applies-to",
    "dependency-type",
    "group-by",
    "multi-ecosystem-group",
    "update-types",
}


class ConfigError(Exception):
    pass


class UniqueKeyLoader(yaml.SafeLoader):
    pass


UniqueKeyLoader.yaml_implicit_resolvers = {
    key: list(value) for key, value in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
for key, resolvers in list(UniqueKeyLoader.yaml_implicit_resolvers.items()):
    UniqueKeyLoader.yaml_implicit_resolvers[key] = [
        (tag, regexp)
        for tag, regexp in resolvers
        if tag != "tag:yaml.org,2002:bool"
    ]


def _construct_mapping(loader: UniqueKeyLoader, node: yaml.Node, deep: bool = False) -> dict[Any, Any]:
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            line = key_node.start_mark.line + 1
            raise ConfigError(f"duplicate YAML key {key!r} at line {line}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_mapping,
)


class Reporter:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)


def load_yaml(path: Path) -> Any:
    try:
        text = path.read_text(encoding="utf-8")
        return load_yaml_text(text, str(path))
    except yaml.YAMLError as exc:
        raise ConfigError(f"{path}: YAML parse failed: {exc}") from exc


def load_yaml_text(text: str, name: str = "<memory>") -> Any:
    try:
        return yaml.load(text, Loader=UniqueKeyLoader)
    except ConfigError:
        raise
    except yaml.YAMLError as exc:
        raise ConfigError(f"{name}: YAML parse failed: {exc}") from exc


def as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def workflow_files(repo_root: Path) -> list[Path]:
    workflow_dir = repo_root / ".github" / "workflows"
    return sorted(list(workflow_dir.glob("*.yml")) + list(workflow_dir.glob("*.yaml")))


def iter_workflow_runs(data: Any) -> list[str]:
    runs: list[str] = []
    for job in as_dict(as_dict(data).get("jobs")).values():
        for step in as_list(as_dict(job).get("steps")):
            run = as_dict(step).get("run")
            if isinstance(run, str):
                runs.append(run)
    return runs


def iter_workflow_uses(data: Any) -> list[str]:
    uses: list[str] = []
    for job in as_dict(as_dict(data).get("jobs")).values():
        for step in as_list(as_dict(job).get("steps")):
            value = as_dict(step).get("uses")
            if isinstance(value, str):
                uses.append(value)
    return uses


def logical_shell_commands(script: str) -> list[str]:
    commands: list[str] = []
    current: list[str] = []
    for line in script.splitlines():
        stripped = line.strip()
        if not current and stripped.startswith("#"):
            continue
        current.append(line)
        if line.rstrip().endswith("\\"):
            continue
        commands.append("\n".join(current))
        current = []
    if current:
        commands.append("\n".join(current))
    return commands


def find_gh_api_slurp_jq(script: str) -> list[str]:
    offenders: list[str] = []
    for command in logical_shell_commands(script):
        if re.search(r"\bgh\s+api\b", command) and "--slurp" in command and "--jq" in command:
            offenders.append(command.strip())
    return offenders


def shebang_lf_error(path: Path, *, require_shebang: bool = False) -> str | None:
    data = path.read_bytes()
    if data.startswith(b"\xef\xbb\xbf#!"):
        return f"{path}: shebang must be the first bytes; UTF-8 BOM found before #!"
    if not data.startswith(b"#!"):
        if require_shebang:
            return f"{path}: executable script must start with a shebang"
        return None
    newline_index = data.find(b"\n")
    if newline_index < 0:
        return f"{path}: shebang line must end with LF"
    if newline_index > 0 and data[newline_index - 1] == 13:
        first_line = data[: newline_index + 1]
        hex_bytes = " ".join(f"{byte:02x}" for byte in first_line[:80])
        return (
            f"{path}: shebang line must use LF, not CRLF; "
            f"first-line bytes: {hex_bytes}"
        )
    return None


def has_trigger(data: Any, trigger_name: str) -> bool:
    on_value = as_dict(data).get("on")
    if isinstance(on_value, str):
        return on_value == trigger_name
    if isinstance(on_value, list):
        return trigger_name in on_value
    return trigger_name in as_dict(on_value)


def split_required_workflows(value: str) -> list[str]:
    return [item.strip() for item in value.split("|") if item.strip()]


def validate_workflows(repo_root: Path, reporter: Reporter) -> dict[str, tuple[Path, dict[str, Any]]]:
    workflows: dict[str, tuple[Path, dict[str, Any]]] = {}
    for path in workflow_files(repo_root):
        try:
            data = load_yaml(path)
        except ConfigError as exc:
            reporter.error(str(exc))
            continue
        if not isinstance(data, dict):
            reporter.error(f"{path}: workflow must be a YAML mapping")
            continue

        name = data.get("name")
        if not isinstance(name, str) or not name.strip():
            reporter.error(f"{path}: workflow must define a non-empty name")
        elif name in workflows:
            reporter.error(f"{path}: duplicate workflow name {name!r}")
        else:
            workflows[name] = (path, data)

        if has_trigger(data, "pull_request_target"):
            reporter.error(f"{path}: pull_request_target is not allowed")

        if data.get("permissions") == "write-all":
            reporter.error(f"{path}: top-level permissions must not be write-all")
        for job_name, job in as_dict(data.get("jobs")).items():
            if as_dict(job).get("permissions") == "write-all":
                reporter.error(f"{path}: job {job_name} permissions must not be write-all")

        for uses in iter_workflow_uses(data):
            if uses.startswith("./") or uses.startswith("docker://"):
                continue
            if "@" not in uses:
                reporter.error(f"{path}: action reference {uses!r} must include an explicit ref")
                continue
            ref = uses.rsplit("@", 1)[1]
            if ref.lower() in {"main", "master", "head", "latest", "trunk"}:
                reporter.error(f"{path}: action reference {uses!r} uses a floating branch-like ref")

        for run in iter_workflow_runs(data):
            for offender in find_gh_api_slurp_jq(run):
                reporter.error(
                    f"{path}: gh api must not combine --slurp and --jq; "
                    f"pipe to external jq instead: {offender}"
                )

    for name, expected in EXPECTED_WORKFLOWS.items():
        if name not in workflows:
            reporter.error(f"missing workflow named {name!r} ({expected})")
            continue
        path, _data = workflows[name]
        if path.as_posix().endswith(expected) is False:
            reporter.error(f"workflow {name!r} must live at {expected}, got {path}")
    return workflows


def validate_auto_merge(repo_root: Path, workflows: dict[str, tuple[Path, dict[str, Any]]], reporter: Reporter) -> None:
    path = repo_root / ".github" / "workflows" / "dependabot-auto-merge.yml"
    script_path = repo_root / "scripts" / "dependabot-auto-merge.sh"
    if not path.is_file():
        reporter.error(f"{path}: missing Dependabot auto-merge workflow")
        return
    if not script_path.is_file():
        reporter.error(f"{script_path}: missing Dependabot auto-merge script")
        return

    try:
        data = load_yaml(path)
    except ConfigError as exc:
        reporter.error(str(exc))
        return
    on_value = as_dict(data.get("on"))
    workflow_run = as_dict(on_value.get("workflow_run"))
    trigger_workflows = [str(item) for item in as_list(workflow_run.get("workflows"))]
    merge_job = as_dict(as_dict(data.get("jobs")).get("merge"))
    env = as_dict(merge_job.get("env"))
    required_workflows = split_required_workflows(str(env.get("REQUIRED_WORKFLOWS", "")))
    if trigger_workflows != required_workflows:
        reporter.error(
            f"{path}: workflow_run.workflows must match REQUIRED_WORKFLOWS "
            f"({trigger_workflows!r} != {required_workflows!r})"
        )
    for workflow in required_workflows:
        if workflow not in workflows:
            reporter.error(f"{path}: required workflow {workflow!r} does not exist")

    expected_top_permissions = {"contents": "read"}
    expected_job_permissions = {
        "actions": "read",
        "checks": "read",
        "contents": "write",
        "pull-requests": "write",
    }
    if data.get("permissions") != expected_top_permissions:
        reporter.error(f"{path}: top-level permissions must be exactly {expected_top_permissions}")
    if merge_job.get("permissions") != expected_job_permissions:
        reporter.error(f"{path}: merge job permissions must be exactly {expected_job_permissions}")

    run_steps = [run.strip() for run in iter_workflow_runs(data)]
    if "bash scripts/dependabot-auto-merge.sh" not in run_steps:
        reporter.error(f"{path}: workflow must delegate to scripts/dependabot-auto-merge.sh")

    shebang_error = shebang_lf_error(script_path, require_shebang=True)
    if shebang_error:
        reporter.error(shebang_error)

    script = script_path.read_text(encoding="utf-8")
    for offender in find_gh_api_slurp_jq(script):
        reporter.error(
            f"{script_path}: gh api must not combine --slurp and --jq; "
            f"pipe to external jq instead: {offender}"
        )
    required_tokens = [
        "set -euo pipefail",
        "DEPENDABOT_LOGIN",
        "dependabot[bot]",
        "DEPENDABOT_TARGET_BRANCH",
        ".user.login == $login",
        ".base.ref == $base",
        ".head.repo.full_name == $repo",
        ".head.sha == $sha",
        '[[ "${head_ref_oid}" != "${HEAD_SHA}" ]]',
        "--match-head-commit",
    ]
    for token in required_tokens:
        if token not in script:
            reporter.error(f"{script_path}: missing auto-merge safety token {token!r}")

    if "--jq" in script:
        reporter.error(f"{script_path}: use external jq instead of GitHub CLI --jq")

    result = subprocess.run(
        ["bash", "-n", str(script_path)],
        cwd=repo_root,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        reporter.error(f"{script_path}: bash -n failed: {result.stderr.strip()}")


def find_keys(value: Any, keys: set[str], path: str = "") -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}" if path else str(key)
            if str(key) in keys:
                found.append(child_path)
            found.extend(find_keys(child, keys, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(find_keys(child, keys, f"{path}[{index}]"))
    return found


def validate_dependabot_data(data: Any, source: str, reporter: Reporter) -> None:
    if not isinstance(data, dict):
        reporter.error(f"{source}: Dependabot config must be a YAML mapping")
        return
    if data.get("version") != 2:
        reporter.error(f"{source}: Dependabot version must be 2")

    updates = as_list(data.get("updates"))
    actual = {
        (str(update.get("package-ecosystem")), str(update.get("directory")))
        for update in updates
        if isinstance(update, dict)
    }
    if actual != EXPECTED_DEPENDABOT_UPDATES:
        reporter.error(
            f"{source}: expected Dependabot ecosystems/directories "
            f"{sorted(EXPECTED_DEPENDABOT_UPDATES)}, got {sorted(actual)}"
        )

    schedule_times: dict[str, str] = {}
    for index, update in enumerate(updates):
        if not isinstance(update, dict):
            reporter.error(f"{source}: updates[{index}] must be a mapping")
            continue
        ecosystem = str(update.get("package-ecosystem"))
        directory = str(update.get("directory"))
        label = f"{source}: {ecosystem} {directory}"

        if update.get("target-branch") != "main":
            reporter.error(f"{label}: target-branch must be main")
        limit = update.get("open-pull-requests-limit")
        if not isinstance(limit, int) or limit < 1 or limit > 2:
            reporter.error(f"{label}: open-pull-requests-limit must be an integer from 1 to 2")
        if update.get("rebase-strategy") != "auto":
            reporter.error(f"{label}: rebase-strategy must be auto")

        schedule = as_dict(update.get("schedule"))
        if schedule.get("interval") != "weekly":
            reporter.error(f"{label}: schedule.interval must be weekly")
        time = schedule.get("time")
        if not isinstance(time, str) or not time:
            reporter.error(f"{label}: schedule.time must be set")
        elif time in schedule_times:
            reporter.error(f"{label}: schedule.time {time} duplicates {schedule_times[time]}")
        else:
            schedule_times[time] = label
        if schedule.get("timezone") != "America/Los_Angeles":
            reporter.error(f"{label}: schedule.timezone must be America/Los_Angeles")

        commit_message = as_dict(update.get("commit-message"))
        if not commit_message.get("prefix") or commit_message.get("include") != "scope":
            reporter.error(f"{label}: commit-message must set prefix and include: scope")
        cooldown = as_dict(update.get("cooldown"))
        if not isinstance(cooldown.get("default-days"), int) or cooldown["default-days"] < 1:
            reporter.error(f"{label}: cooldown.default-days must be a positive integer")

        if ecosystem == "devcontainers":
            forbidden = find_keys(update, DEVCONTAINER_GROUP_KEYS)
            if forbidden:
                reporter.error(
                    f"{label}: devcontainers updater must not use group-related keys "
                    f"({', '.join(forbidden)})"
                )
            continue

        if ecosystem not in GROUPED_DEPENDABOT_ECOSYSTEMS:
            continue
        groups = as_dict(update.get("groups"))
        if not groups:
            reporter.error(f"{label}: grouped ecosystem must define groups")
            continue
        has_security_group = False
        has_minor_patch_group = False
        for group_name, group in groups.items():
            group_map = as_dict(group)
            patterns = [str(item) for item in as_list(group_map.get("patterns"))]
            if group_map.get("applies-to") == "security-updates" and "*" in patterns:
                has_security_group = True
            update_types = {str(item) for item in as_list(group_map.get("update-types"))}
            if {"minor", "patch"}.issubset(update_types) and "major" not in update_types:
                has_minor_patch_group = True
            if not patterns:
                reporter.error(f"{label}: group {group_name} must define patterns")
        if not has_security_group:
            reporter.error(f"{label}: must include a security-updates group with pattern '*'")
        if not has_minor_patch_group:
            reporter.error(f"{label}: must include a minor/patch version-update group")


def validate_dependabot(repo_root: Path, reporter: Reporter) -> None:
    path = repo_root / ".github" / "dependabot.yml"
    if not path.is_file():
        reporter.error(f"{path}: missing Dependabot config")
        return
    try:
        data = load_yaml(path)
    except ConfigError as exc:
        reporter.error(str(exc))
        return
    validate_dependabot_data(data, str(path), reporter)


def validate_repo(repo_root: Path) -> Reporter:
    reporter = Reporter()
    workflows = validate_workflows(repo_root, reporter)
    validate_auto_merge(repo_root, workflows, reporter)
    validate_dependabot(repo_root, reporter)
    return reporter


def run_self_test() -> int:
    reporter = Reporter()

    try:
        load_yaml_text("name: one\nname: two\n", "duplicate.yml")
        reporter.error("self-test: duplicate YAML keys were accepted")
    except ConfigError:
        pass

    try:
        parsed = load_yaml_text("on:\n  pull_request:\n", "on.yml")
        if "on" not in parsed:
            reporter.error("self-test: YAML loader did not preserve the 'on' key")
    except ConfigError as exc:
        reporter.error(f"self-test: failed to parse on.yml: {exc}")

    old_command = 'gh api --paginate --slurp "/repos/o/r/actions/runs" \\\n  --jq ".[0]"'
    if not find_gh_api_slurp_jq(old_command):
        reporter.error("self-test: gh api --slurp --jq command was not rejected")
    fixed_command = 'gh api --paginate --slurp "/repos/o/r/actions/runs" | jq -r ".[0]"'
    if find_gh_api_slurp_jq(fixed_command):
        reporter.error("self-test: external jq pipeline was rejected")

    bad_dependabot = load_yaml_text(
        """
version: 2
updates:
  - package-ecosystem: "devcontainers"
    directory: "/"
    target-branch: "main"
    schedule:
      interval: "weekly"
      time: "03:40"
      timezone: "America/Los_Angeles"
    open-pull-requests-limit: 2
    rebase-strategy: "auto"
    commit-message:
      prefix: "chore(devcontainer)"
      include: "scope"
    cooldown:
      default-days: 3
    groups:
      bad:
        patterns: ["*"]
        update-types: ["minor", "patch"]
""",
        "bad-dependabot.yml",
    )
    bad_reporter = Reporter()
    validate_dependabot_data(bad_dependabot, "bad-dependabot.yml", bad_reporter)
    if not any("devcontainers updater must not use group-related keys" in e for e in bad_reporter.errors):
        reporter.error("self-test: devcontainer groups were not rejected")

    bad_multi_ecosystem = load_yaml_text(
        """
version: 2
updates:
  - package-ecosystem: "devcontainers"
    directory: "/"
    target-branch: "main"
    schedule:
      interval: "weekly"
      time: "03:40"
      timezone: "America/Los_Angeles"
    open-pull-requests-limit: 2
    rebase-strategy: "auto"
    commit-message:
      prefix: "chore(devcontainer)"
      include: "scope"
    cooldown:
      default-days: 3
    multi-ecosystem-group: "devcontainer-stack"
""",
        "bad-multi-ecosystem-dependabot.yml",
    )
    multi_reporter = Reporter()
    validate_dependabot_data(
        bad_multi_ecosystem,
        "bad-multi-ecosystem-dependabot.yml",
        multi_reporter,
    )
    if not any("multi-ecosystem-group" in e for e in multi_reporter.errors):
        reporter.error("self-test: devcontainer multi-ecosystem-group was not rejected")

    with tempfile.TemporaryDirectory(prefix="github-config-self-test-") as temp:
        script = Path(temp) / "ok.sh"
        script.write_text("#!/usr/bin/env bash\nset -euo pipefail\necho ok\n", encoding="utf-8")
        result = subprocess.run(["bash", "-n", str(script)], check=False)
        if result.returncode != 0:
            reporter.error("self-test: bash -n smoke check failed")

        shebang_cases = [
            ("lf", b"#!/usr/bin/env bash\nexit 0\n", None),
            ("bom", b"\xef\xbb\xbf#!/usr/bin/env bash\nexit 0\n", "UTF-8 BOM"),
            ("crlf", b"#!/usr/bin/env bash\r\nexit 0\n", "CRLF"),
            ("missing", b"echo no shebang\n", "must start with a shebang"),
            ("unterminated", b"#!/usr/bin/env bash", "must end with LF"),
        ]
        for name, content, expected_error in shebang_cases:
            candidate = Path(temp) / f"{name}.sh"
            candidate.write_bytes(content)
            error = shebang_lf_error(candidate, require_shebang=True)
            if expected_error is None and error is not None:
                reporter.error(f"self-test: LF shebang was rejected: {error}")
            elif expected_error is not None and (
                error is None or expected_error not in error
            ):
                reporter.error(
                    f"self-test: shebang case {name!r} did not report "
                    f"{expected_error!r}; got {error!r}"
                )

    if reporter.errors:
        for error in reporter.errors:
            print(f"[github-config] ERROR: {error}", file=sys.stderr)
        return 1
    print("[github-config] Self-tests passed.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="Repository root to validate.")
    parser.add_argument("--self-test", action="store_true", help="Run validator self-tests.")
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_test()

    repo_root = Path(args.repo_root).resolve()
    reporter = validate_repo(repo_root)
    if reporter.errors:
        for error in reporter.errors:
            print(f"[github-config] ERROR: {error}", file=sys.stderr)
        return 1
    print("[github-config] GitHub workflow and Dependabot config checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
