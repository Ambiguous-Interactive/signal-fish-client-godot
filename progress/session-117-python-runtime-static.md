# Session 117: move runtime static checks to Python

Branch: `refactor/python-runtime-static` from `origin/main` at `5f6214a`.

- Moved GDScript file discovery, sharding, static check execution, and Python
  quality checks from Bash into `scripts/run-runtime-static.py` for issue #168.
- Kept `scripts/run-runtime-checks.sh` as the public local and CI entry point.
  Its full, scoped, and standalone static commands retain their behavior.
- Verified `all`, `static`, and `changed` locally. A malformed GDScript file
  made scoped checks fail with a parse diagnostic.

The Godot suite runner and dev container lifecycle scripts remain candidates
for later Python migration under #168.
