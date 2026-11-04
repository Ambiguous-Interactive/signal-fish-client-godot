---
description: Symbolized Godot 4.7.2 editor import shutdown crash from a null DocTools pointer in the deferred extension-doc callback (issue #447).
triggers: godot, editor, import, crash, doc tools, editorhelp, gdextension, shutdown, issue 447
category: Research
---

# Godot Editor Import Shutdown Crash

Issue #447 tracks intermittent native editor-import aborts that end after
`loading_editor_layout` with no engine-error marker. The retained official
Godot 4.7.2 ARM64 core is now symbolized and the crash is isolated to one
engine shutdown path, not to extension initialization.

## Verdict

`EditorHelp::_gen_extensions_docs()` runs as a deferred callback after
`EditorHelp::doc` is null. It calls `doc->generate(...)`, which dereferences
the null `DocTools` pointer and faults on the first hash-map access.

## Evidence

Two deterministic controls used the same generated project, the official
webrtc-native `1.2.2-stable` library
(`fdeb513e783e2b1416cb82831bf7d48e85ce3c7ab85cd9f957c2cd0d2f881b0d`)
and a local build of Godot 4.7.2 from source commit
`ed1daf0bf001b61586d9930840f2f1394092c079` with the official production
flags (`production=yes debug_symbols=yes separate_debug_symbols=yes
debug_paths_relative=yes`).

| Control                          | Result          |
| -------------------------------- | --------------- |
| Copy with `addons/webrtc_native` | abort, exit 134 |
| Same copy without `addons`       | clean, exit 0   |

The failing run crashed after the editor layout and import scan completed.
GDB stopped the SIGSEGV before the engine crash handler and produced this
backtrace:

```text
HashMap<String, DocData::ClassDoc, ...>::operator[] (this=0x8, ...)
    at core/string/ustring.cpp:2767
DocTools::generate(...) at editor/doc/doc_tools.cpp:452
EditorHelp::_gen_extensions_docs() at editor/doc/editor_help.cpp:3084
CallQueue::_call_function(...) at core/object/message_queue.cpp:218
CallQueue::flush(...) at core/object/message_queue.cpp:266
Main::cleanup(p_force=false) at main/main.cpp:5257
main(...) at platform/linuxbsd/godot_linuxbsd.cpp:126
```

The original official core has the same fault shape: SIGSEGV at engine PC
`0x19a9bd8`, `x23=0x8`, with return addresses `0x19ac3f0` and `0x19b152c`.
In the rebuilt engine those frames are `DocTools::generate` and
`EditorHelp::_gen_extensions_docs`; the faulting instruction is the first
access through the null `DocTools` pointer.

## Source Path

- `EditorHelp::_load_doc_thread()` schedules the deferred call:
  `editor/doc/editor_help.cpp:3041`.
- `EditorHelp::_gen_extensions_docs()` dereferences `doc` without a null
  check: `editor/doc/editor_help.cpp:3084`.
- `EditorHelp::cleanup_doc()` deletes `doc` and sets it to null:
  `editor/doc/editor_help.cpp:3365`.
- `Main::cleanup()` flushes the deferred queue at `main/main.cpp:5257`.

The deferred callback can outlive the `DocTools` instance, or run before it
is created, during a fast `--editor --import` shutdown. A guard in
`_gen_extensions_docs()` or cancellation of the deferred call before
`cleanup_doc()` removes the fault.

## Impact And Scope

- This is an engine shutdown defect. The project scan and import complete
  before the fault.
- The native extension changes timing and adds extension classes to the
  documentation pass, so it makes the queued callback more likely to remain
  at shutdown.
- A fresh `HOME` per editor boot changes that timing and has masked the
  abort in the shutdown lanes. That mitigation does not repair the null
  dereference.
- No client or addon code change is claimed. The import drivers keep
  attributing an abort separately from protocol results.

## Remaining Work

- Upstream needs a guard or deferred-call cancellation in `EditorHelp`.
  Writes outside the Ambiguous-Interactive org are not permitted here, so
  this note and issue #447 carry the report for a human-authored
  submission.
- Requalify the native import controls when an engine release adopts the
  fix. Keep the original and patched-extension failures and the
  warm/no-extension controls.

## Local Reproduction

```bash
cp -r <prepared-project> /tmp/editor-crash-case
rm -rf /tmp/editor-crash-case/.godot
ulimit -c unlimited
<godot-4.7.2-editor> --headless --path /tmp/editor-crash-case --editor --import
gdb --batch -ex 'handle SIGSEGV stop print nopass' -ex run -ex bt \
  --args <godot-debug-binary> --headless \
  --path /tmp/editor-crash-case --editor --import
```

Local rebuilt binaries and debug symbols:
`godot.linuxbsd.editor.arm64` SHA-256
`8e58cf725a6ac28b34ccc3c727a0c6ba8f0ca41f2b01b2071faccc885fc31f96`;
`godot.linuxbsd.editor.arm64.debugsymbols` SHA-256
`5a1600291cb0767537d174fe60c79b3c1e4bdcafecf9e7d78da9df0f48a72944`.
