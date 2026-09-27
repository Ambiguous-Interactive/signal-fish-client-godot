# Session 091: extend source static analysis

Branch: `codex/session-091-source-static-analysis` from `origin/main` at
`7b0d6fa`.

- Added warning-as-error ShellCheck, ESLint, and PSScriptAnalyzer checks to
  local tooling and CI.
- Enabled Ruff security rules and documented narrow exceptions.
- Fixed the analyzer findings in shell, JavaScript, and PowerShell sources,
  including a broken system Python marker glob.
- The full runtime gate and LLM harness pass locally.

PR #205 is the session deliverable. Closes #170.
