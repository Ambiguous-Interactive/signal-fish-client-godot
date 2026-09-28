# Session 115: deploy validated docs after Dependabot merges

Branch: `fix/dependabot-docs-deploy` from `origin/main` at `5663234`.

- PR #231 proved that bot merges start main CI, but a token-dispatched Docs
  Validation run did not trigger Docs Deploy.
- Dependabot Auto Merge now dispatches Docs Deploy with the exact validation
  run ID. The deploy waits for success and checks the run's commit and source
  before downloading its site artifact.
- Auto Merge waits for pending PR checks and reacts to Docs Validation and Dev
  Container reruns, so a slower check can finish without a manual CI rerun.
- Fake GitHub tests and workflow config checks cover the new handoff.

Live verification on the next Dependabot auto merge remains in #234.
