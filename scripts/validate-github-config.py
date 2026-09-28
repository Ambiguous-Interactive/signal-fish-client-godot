#!/usr/bin/env python3
"""Deterministic policy checks for GitHub workflow and Dependabot config."""

from __future__ import annotations

import argparse
import ast
import re
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    print(
        "PyYAML is required. Install it with: python -m pip install -r requirements-automation.txt",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


EXPECTED_WORKFLOWS = {
    "Runtime CI": ".github/workflows/ci.yml",
    "LLM Harness": ".github/workflows/llm-harness.yml",
    "Dependabot Auto Merge": ".github/workflows/dependabot-auto-merge.yml",
}
POST_MERGE_WORKFLOWS = {
    "Runtime CI": ".github/workflows/ci.yml",
    "LLM Harness": ".github/workflows/llm-harness.yml",
    "Docs Validation": ".github/workflows/docs-validation.yml",
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
# project.godot is the single source for the Godot version (read via
# extract_godot_pin_version, so any feature list is accepted); every other
# pin site must repeat it verbatim so a bump cannot leave one site behind.
# The ci.yml test matrix lists every tested Godot version, so the guard
# requires the pinned version to be a matrix leg (see ci_matrix_error).
# web-export-smoke.yml expands the pin to {version}.0-stable because
# setup-godot expects the full three-part version.
GODOT_PIN_SOURCE = "project.godot"
GODOT_PIN_SITES = (
    (".devcontainer/devcontainer.json", '"GODOT_VERSION": "{version}-stable"'),
    (".devcontainer/devcontainer.json", '"GODOT_RELEASE_LABEL": "{version}"'),
    (".devcontainer/Dockerfile", "ARG GODOT_VERSION={version}-stable"),
    (".devcontainer/Dockerfile", "ARG GODOT_RELEASE_LABEL={version}"),
    (".github/workflows/web-export-smoke.yml", "version: {version}.0-stable"),
)


class ConfigError(Exception):
    pass


class UniqueKeyLoader(yaml.SafeLoader):
    pass


UniqueKeyLoader.yaml_implicit_resolvers = {
    key: list(value) for key, value in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
for key, resolvers in list(UniqueKeyLoader.yaml_implicit_resolvers.items()):
    UniqueKeyLoader.yaml_implicit_resolvers[key] = [
        (tag, regexp) for tag, regexp in resolvers if tag != "tag:yaml.org,2002:bool"
    ]


def _construct_mapping(
    loader: UniqueKeyLoader, node: yaml.Node, deep: bool = False
) -> dict[object, object]:
    mapping: dict[object, object] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)  # type: ignore[no-untyped-call]
        if key in mapping:
            line = key_node.start_mark.line + 1
            raise ConfigError(f"duplicate YAML key {key!r} at line {line}")
        mapping[key] = loader.construct_object(value_node, deep=deep)  # type: ignore[no-untyped-call]
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


def load_yaml(path: Path) -> object:
    try:
        text = path.read_text(encoding="utf-8")
        return load_yaml_text(text, str(path))
    except yaml.YAMLError as exc:
        raise ConfigError(f"{path}: YAML parse failed: {exc}") from exc


def load_yaml_text(text: str, name: str = "<memory>") -> object:
    try:
        parsed: object = yaml.load(text, Loader=UniqueKeyLoader)  # noqa: S506
        return parsed
    except ConfigError:
        raise
    except yaml.YAMLError as exc:
        raise ConfigError(f"{name}: YAML parse failed: {exc}") from exc


def as_dict(value: object) -> dict[object, object]:
    return value if isinstance(value, dict) else {}


def as_list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def workflow_files(repo_root: Path) -> list[Path]:
    workflow_dir = repo_root / ".github" / "workflows"
    return sorted(list(workflow_dir.glob("*.yml")) + list(workflow_dir.glob("*.yaml")))


def iter_workflow_runs(data: object) -> list[str]:
    runs: list[str] = []
    for job in as_dict(as_dict(data).get("jobs")).values():
        for step in as_list(as_dict(job).get("steps")):
            run = as_dict(step).get("run")
            if isinstance(run, str):
                runs.append(run)
    return runs


def iter_workflow_uses(data: object) -> list[str]:
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
        return f"{path}: shebang line must use LF, not CRLF; first-line bytes: {hex_bytes}"
    return None


def has_trigger(data: object, trigger_name: str) -> bool:
    on_value = as_dict(data).get("on")
    if isinstance(on_value, str):
        return on_value == trigger_name
    if isinstance(on_value, list):
        return trigger_name in on_value
    return trigger_name in as_dict(on_value)


PR_TRIGGERS = ("pull_request", "pull_request_target")


def write_permission_scopes(permissions: object) -> list[str]:
    if not isinstance(permissions, dict):
        return []
    return sorted(str(scope) for scope, level in permissions.items() if str(level) == "write")


def pr_permission_errors(source: str, data: object) -> list[str]:
    if not any(has_trigger(data, trigger) for trigger in PR_TRIGGERS):
        return []
    errors: list[str] = []
    for scope in write_permission_scopes(as_dict(data).get("permissions")):
        errors.append(
            f"{source}: pull_request workflows must stay read-only; "
            f"top-level permissions grants write to {scope}"
        )
    for job_name, job in as_dict(as_dict(data).get("jobs")).items():
        for scope in write_permission_scopes(as_dict(job).get("permissions")):
            errors.append(
                f"{source}: pull_request workflows must stay read-only; "
                f"job {job_name} grants write to {scope}"
            )
    return errors


def split_required_workflows(value: str) -> list[str]:
    return [item.strip() for item in value.split("|") if item.strip()]


def validate_workflows(
    repo_root: Path, reporter: Reporter
) -> dict[str, tuple[Path, dict[object, object]]]:
    workflows: dict[str, tuple[Path, dict[object, object]]] = {}
    for path in workflow_files(repo_root):
        try:
            data = load_yaml(path)
        except ConfigError as exc:
            reporter.error(str(exc))
            continue
        if not isinstance(data, dict):
            reporter.error(f"{path}: workflow must be a YAML mapping")
            continue
        data = as_dict(data)

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
        for error in pr_permission_errors(str(path), data):
            reporter.error(error)

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


def validate_auto_merge(
    repo_root: Path, workflows: dict[str, tuple[Path, dict[object, object]]], reporter: Reporter
) -> None:
    path = repo_root / ".github" / "workflows" / "dependabot-auto-merge.yml"
    script_path = repo_root / "scripts" / "dependabot-auto-merge.py"
    if not path.is_file():
        reporter.error(f"{path}: missing Dependabot auto-merge workflow")
        return
    if not script_path.is_file():
        reporter.error(f"{script_path}: missing Dependabot auto-merge script")
        return

    try:
        data = as_dict(load_yaml(path))
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
        "actions": "write",
        "checks": "read",
        "contents": "write",
        "pull-requests": "write",
    }
    if data.get("permissions") != expected_top_permissions:
        reporter.error(f"{path}: top-level permissions must be exactly {expected_top_permissions}")
    if merge_job.get("permissions") != expected_job_permissions:
        reporter.error(f"{path}: merge job permissions must be exactly {expected_job_permissions}")

    run_steps = [run.strip() for run in iter_workflow_runs(data)]
    if "python3 scripts/dependabot-auto-merge.py" not in run_steps:
        reporter.error(f"{path}: workflow must delegate to scripts/dependabot-auto-merge.py")

    shebang_error = shebang_lf_error(script_path, require_shebang=True)
    if shebang_error:
        reporter.error(shebang_error)

    script = script_path.read_text(encoding="utf-8")
    required_tokens = [
        "DEPENDABOT_LOGIN",
        "dependabot[bot]",
        "DEPENDABOT_TARGET_BRANCH",
        'field(pr.get("user"), "login") == login',
        'field(pr.get("base"), "ref") == target',
        'field(field(pr.get("head"), "repo"), "full_name") == repo',
        'field(pr.get("head"), "sha") == sha',
        'pr.get("headRefOid") != sha',
        "--match-head-commit",
    ]
    for token in required_tokens:
        if token not in script:
            reporter.error(f"{script_path}: missing auto-merge safety token {token!r}")

    for name, expected_path in POST_MERGE_WORKFLOWS.items():
        entry = workflows.get(name)
        if entry is None:
            reporter.error(f"{path}: post-merge workflow {name!r} is missing")
            continue
        workflow_path, workflow_data = entry
        if not workflow_path.as_posix().endswith(expected_path):
            reporter.error(f"{workflow_path}: expected path {expected_path}")
        dispatch = as_dict(as_dict(workflow_data.get("on")).get("workflow_dispatch"))
        inputs = as_dict(dispatch.get("inputs"))
        if "expected_sha" not in inputs:
            reporter.error(f"{workflow_path}: workflow_dispatch needs expected_sha input")
        verify = as_dict(as_dict(workflow_data.get("jobs")).get("verify-dispatch"))
        if "EXPECTED_SHA" not in str(verify) or "GITHUB_SHA" not in str(verify):
            reporter.error(f"{workflow_path}: verify-dispatch must check the run SHA")
        concurrency = as_dict(workflow_data.get("concurrency"))
        group = str(concurrency.get("group", ""))
        cancel = str(concurrency.get("cancel-in-progress", ""))
        if "github.sha" not in group or "github.event_name == 'pull_request'" not in cancel:
            reporter.error(f"{workflow_path}: main checks must be grouped by SHA and not canceled")

    deploy = workflows.get("Docs Deploy")
    if deploy is None:
        reporter.error(f"{path}: Docs Deploy workflow is missing")
    else:
        deploy_path, deploy_workflow = deploy
        build = as_dict(as_dict(deploy_workflow.get("jobs")).get("build"))
        condition = str(build.get("if", ""))
        if "workflow_dispatch" not in condition or "head_branch == 'main'" not in condition:
            reporter.error(f"{deploy_path}: dispatched main docs must deploy after validation")

    docs = workflows.get("Docs Validation")
    if docs is not None:
        docs_path, docs_workflow = docs
        required = as_dict(as_dict(docs_workflow.get("jobs")).get("required"))
        if "verify-dispatch" not in as_list(required.get("needs")):
            reporter.error(f"{docs_path}: required gate must include dispatch verification")

    try:
        ast.parse(script, filename=str(script_path))
    except SyntaxError as exc:
        reporter.error(f"{script_path}: Python syntax failed: {exc}")


def bash_syntax_check(script_path: Path) -> tuple[bool, str]:
    """Run `bash -n` on a script without breaking WSL bash on Windows.

    WSL's bash.exe cannot open Windows-style absolute paths, so run bash with
    the script's directory as the working directory and pass the bare file
    name. This behaves identically under Git Bash, WSL, and native Linux.
    """
    result = subprocess.run(
        ["bash", "-n", script_path.name],
        cwd=str(script_path.parent),
        text=True,
        capture_output=True,
        check=False,
    )
    return result.returncode == 0, result.stderr.strip()


def find_keys(value: object, keys: set[str], path: str = "") -> list[str]:
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


def validate_dependabot_data(data: object, source: str, reporter: Reporter) -> None:
    if not isinstance(data, dict):
        reporter.error(f"{source}: Dependabot config must be a YAML mapping")
        return
    data = as_dict(data)
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
        default_days = cooldown.get("default-days")
        if not isinstance(default_days, int) or default_days < 1:
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
    yml_path = repo_root / ".github" / "dependabot.yml"
    yaml_path = repo_root / ".github" / "dependabot.yaml"
    present = [path for path in (yml_path, yaml_path) if path.is_file()]
    if len(present) > 1:
        reporter.error(
            f"{yml_path.parent}: both dependabot.yml and dependabot.yaml exist; keep one"
        )
        return
    if not present:
        reporter.error(f"{yml_path}: missing Dependabot config")
        return
    try:
        data = load_yaml(present[0])
    except ConfigError as exc:
        reporter.error(str(exc))
        return
    validate_dependabot_data(data, str(present[0]), reporter)


def extract_godot_pin_version(project_text: str) -> str | None:
    match = re.search(r'config/features=PackedStringArray\("(\d+\.\d+)"', project_text)
    return match.group(1) if match else None


def ci_matrix_error(ci_text: str, version: str) -> str:
    token = f"{version}-stable"
    try:
        data = load_yaml_text(ci_text)
    except ConfigError:
        return "Godot version pin drift: .github/workflows/ci.yml does not parse as YAML"
    node: object = data
    for key in ("jobs", "test", "strategy", "matrix", "godot"):
        node = node.get(key) if isinstance(node, dict) else None
    legs = [str(item) for item in node] if isinstance(node, list) else []
    if token not in legs:
        return (
            "Godot version pin drift: .github/workflows/ci.yml test matrix must include "
            f"{token!r} (project.godot pins {version})"
        )
    return ""


def godot_pin_errors(source_texts: dict[str, str]) -> list[str]:
    version = extract_godot_pin_version(source_texts.get("project.godot", ""))
    if version is None:
        return ["project.godot: could not read the config/features Godot version pin"]
    errors: list[str] = []
    for site, template in GODOT_PIN_SITES:
        token = template.format(version=version)
        if token not in source_texts.get(site, ""):
            errors.append(
                f"Godot version pin drift: {site} must contain {token!r} "
                f"(project.godot pins {version})"
            )
    ci_error = ci_matrix_error(source_texts.get(".github/workflows/ci.yml", ""), version)
    if ci_error:
        errors.append(ci_error)
    return errors


def validate_godot_pin(repo_root: Path, reporter: Reporter) -> None:
    source_path = repo_root / GODOT_PIN_SOURCE
    if not source_path.is_file():
        reporter.error(f"{source_path}: missing file required for the Godot version pin check")
        return
    source_texts = {GODOT_PIN_SOURCE: source_path.read_text(encoding="utf-8")}
    pin_sites = [site for site, _template in GODOT_PIN_SITES]
    pin_sites.append(".github/workflows/ci.yml")
    for site in pin_sites:
        path = repo_root / site
        if not path.is_file():
            reporter.error(f"{path}: missing file required for the Godot version pin check")
            return
        source_texts[site] = path.read_text(encoding="utf-8")
    for error in godot_pin_errors(source_texts):
        reporter.error(error)


def playwright_pin_error(action_text: str, quality_text: str, docs_text: str) -> str:
    action = as_dict(load_yaml_text(action_text))
    action_version = as_dict(as_dict(action.get("inputs")).get("playwright-version")).get("default")
    if not isinstance(action_version, str):
        return "Playwright pin must be set in the shared action"
    for label, requirements_text in (("Python quality", quality_text), ("docs", docs_text)):
        requirement = re.search(r"(?m)^playwright==([0-9]+\.[0-9]+\.[0-9]+)$", requirements_text)
        if requirement is None:
            return f"Playwright pin must be set in {label} requirements"
        if action_version != requirement.group(1):
            return (
                f"Playwright pin drift: action {action_version} != {label} {requirement.group(1)}"
            )
    return ""


def validate_playwright_pin(repo_root: Path, reporter: Reporter) -> None:
    action = repo_root / ".github/actions/playwright-chromium/action.yml"
    quality = repo_root / "requirements-python-quality.txt"
    docs = repo_root / "requirements-docs-accessibility.txt"
    try:
        error = playwright_pin_error(
            action.read_text(encoding="utf-8"),
            quality.read_text(encoding="utf-8"),
            docs.read_text(encoding="utf-8"),
        )
    except (OSError, ConfigError) as exc:
        reporter.error(f"Playwright pin check failed: {exc}")
        return
    if error:
        reporter.error(error)


def validate_repo(repo_root: Path) -> Reporter:
    reporter = Reporter()
    workflows = validate_workflows(repo_root, reporter)
    validate_auto_merge(repo_root, workflows, reporter)
    validate_dependabot(repo_root, reporter)
    validate_godot_pin(repo_root, reporter)
    validate_playwright_pin(repo_root, reporter)
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
        if "on" not in as_dict(parsed):
            reporter.error("self-test: YAML loader did not preserve the 'on' key")
    except ConfigError as exc:
        reporter.error(f"self-test: failed to parse on.yml: {exc}")

    pr_read_only = load_yaml_text(
        """
name: PR Read Only
on:
  pull_request:
permissions:
  contents: read
jobs:
  build:
    steps:
      - run: echo ok
""",
        "pr-read-only.yml",
    )
    if pr_permission_errors("pr-read-only.yml", pr_read_only):
        reporter.error("self-test: read-only pull_request workflow was rejected")

    pr_top_write = load_yaml_text(
        """
name: PR Top Write
on:
  pull_request:
permissions:
  contents: write
jobs:
  build:
    steps:
      - run: echo ok
""",
        "pr-top-write.yml",
    )
    if not any(
        "top-level permissions grants write to contents" in error
        for error in pr_permission_errors("pr-top-write.yml", pr_top_write)
    ):
        reporter.error("self-test: pull_request top-level write was not rejected")

    pr_job_write = load_yaml_text(
        """
name: PR Job Write
on:
  pull_request_target:
permissions:
  contents: read
jobs:
  build:
    permissions:
      issues: write
      contents: write
    steps:
      - run: echo ok
""",
        "pr-job-write.yml",
    )
    if not any(
        "job build grants write to contents" in error
        for error in pr_permission_errors("pr-job-write.yml", pr_job_write)
    ):
        reporter.error("self-test: pull_request job-level write was not rejected")

    push_write = load_yaml_text(
        """
name: Push Write
on:
  push:
permissions:
  contents: write
jobs:
  release:
    permissions:
      contents: write
    steps:
      - run: echo ok
""",
        "push-write.yml",
    )
    if pr_permission_errors("push-write.yml", push_write):
        reporter.error("self-test: push-triggered write workflow was rejected")

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
    if not any(
        "devcontainers updater must not use group-related keys" in e for e in bad_reporter.errors
    ):
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
        minimal_dependabot = "version: 2\nupdates: []\n"
        yml_only = Path(temp) / "yml-only"
        yaml_only = Path(temp) / "yaml-only"
        both = Path(temp) / "both"
        for case_dir in (yml_only, yaml_only, both):
            (case_dir / ".github").mkdir(parents=True)
        (yml_only / ".github" / "dependabot.yml").write_text(minimal_dependabot, encoding="utf-8")
        (yaml_only / ".github" / "dependabot.yaml").write_text(minimal_dependabot, encoding="utf-8")
        (both / ".github" / "dependabot.yml").write_text(minimal_dependabot, encoding="utf-8")
        (both / ".github" / "dependabot.yaml").write_text(minimal_dependabot, encoding="utf-8")

        duplicate_reporter = Reporter()
        validate_dependabot(both, duplicate_reporter)
        if not any(
            "dependabot.yml and dependabot.yaml" in error for error in duplicate_reporter.errors
        ):
            reporter.error("self-test: duplicate Dependabot config files were not rejected")
        for case_dir in (yml_only, yaml_only):
            case_reporter = Reporter()
            validate_dependabot(case_dir, case_reporter)
            if any("missing Dependabot config" in error for error in case_reporter.errors):
                reporter.error(f"self-test: Dependabot config in {case_dir.name} was not found")

    with tempfile.TemporaryDirectory(prefix="github-config-self-test-") as temp:
        script = Path(temp) / "ok.sh"
        script.write_text("#!/usr/bin/env bash\nset -euo pipefail\necho ok\n", encoding="utf-8")
        ok, _ = bash_syntax_check(script)
        if not ok:
            reporter.error("self-test: bash -n smoke check failed")

        ci_matrix_yaml = (
            "jobs:\n"
            "    test:\n"
            "        strategy:\n"
            "            matrix:\n"
            '                godot: ["4.3-stable", "4.4.1-stable"]\n'
        )
        pin_sources = {
            "project.godot": 'config/features=PackedStringArray("4.3", "GL Compatibility")\n',
            ".github/workflows/ci.yml": ci_matrix_yaml,
            ".devcontainer/devcontainer.json": (
                '"GODOT_VERSION": "4.3-stable",\n"GODOT_RELEASE_LABEL": "4.3"\n'
            ),
            ".devcontainer/Dockerfile": (
                "ARG GODOT_VERSION=4.3-stable\nARG GODOT_RELEASE_LABEL=4.3\n"
            ),
            ".github/workflows/web-export-smoke.yml": "version: 4.3.0-stable\n",
        }
        if godot_pin_errors(pin_sources):
            reporter.error("self-test: consistent Godot version pins were rejected")
        matrix_missing = dict(pin_sources)
        matrix_missing[".github/workflows/ci.yml"] = ci_matrix_yaml.replace('"4.3-stable", ', "")
        matrix_errors = godot_pin_errors(matrix_missing)
        if not any("4.3-stable" in error for error in matrix_errors):
            reporter.error("self-test: ci.yml matrix missing the pinned Godot was not reported")
        unparsed = dict(pin_sources)
        unparsed[".github/workflows/ci.yml"] = "\t: :\n"
        if not any("does not parse as YAML" in error for error in godot_pin_errors(unparsed)):
            reporter.error("self-test: unparseable ci.yml was not reported")
        for drift_site, drifted_token in (
            (".devcontainer/devcontainer.json", "4.4"),
            (".devcontainer/Dockerfile", "4.4-stable"),
            (".github/workflows/web-export-smoke.yml", "4.4"),
        ):
            drifted_sources = dict(pin_sources)
            drifted_sources[drift_site] = pin_sources[drift_site].replace("4.3", drifted_token)
            drifted = godot_pin_errors(drifted_sources)
            for site, template in GODOT_PIN_SITES:
                if site != drift_site:
                    continue
                token = template.format(version="4.3")
                if not any(token in error for error in drifted):
                    reporter.error(f"self-test: Godot version drift for {token!r} was not reported")
        missing_pin = godot_pin_errors({"project.godot": "no pin here\n"})
        if not any("could not read" in error for error in missing_pin):
            reporter.error("self-test: unreadable project.godot pin was not reported")

        action_pin = "inputs:\n  playwright-version:\n    default: '1.61.0'\n"
        python_pin = "ruff==0.16.9\nplaywright==1.61.0\n"
        if playwright_pin_error(action_pin, python_pin, python_pin):
            reporter.error("self-test: matching Playwright pins were rejected")
        if "pin drift" not in playwright_pin_error(
            action_pin, python_pin.replace("1.61.0", "1.60.0"), python_pin
        ):
            reporter.error("self-test: Playwright pin drift was not rejected")
        if "pin drift" not in playwright_pin_error(
            action_pin, python_pin, python_pin.replace("1.61.0", "1.60.0")
        ):
            reporter.error("self-test: docs Playwright pin drift was not rejected")

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
            elif expected_error is not None and (error is None or expected_error not in error):
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
