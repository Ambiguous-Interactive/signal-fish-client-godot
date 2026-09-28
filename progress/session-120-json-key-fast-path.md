# Session 120: speed up ordinary JSON key checks

Branch: `perf/json-key-fast-path` from `origin/main` at `cf936cf`.

- Audited the prior #161 hot-path measurements and tested MessagePack array
  reservation. Its 3-4% change was below the benchmark noise floor, so it
  was discarded.
- Used native byte-array operations for unescaped JSON keys. The existing
  escape canonicalization remains in place. Adjacent Godot 4.3 bench runs
  measured the clean control guard at 31.3 to 24.1 us; escaped dense keys
  stayed within noise.

Local checks: changed runtime gate, full runtime gate, LLM harness, and
protocol duplicate-key and fuzz suites. #161 remains open for broader work.
