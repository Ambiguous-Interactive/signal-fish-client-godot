# LLM Context Index

Generated Markdown inventory by `scripts/generate-llm-index.ps1`; do not edit by hand.

## Skills

- [Adversarial Verification](skills/adversarial-verification.md) (`Quality`) - Use when hardening plans, implementations, tests, or reviews with independent adversarial checks.
  Triggers: adversarial, red team, green team, zero knowledge, handoff, verification, deterministic, quality gate
- [Agent Harness](skills/agent-harness.md) (`Core`) - Use when changing AI context, vendor pointer files, indexes, hooks, or LLM automation.
  Triggers: agent harness, llm, context, skills, index, hooks, ci, automation
- [Architectural Planning](skills/architectural-planning.md) (`Planning`) - Use when planning runtime architecture, protocol boundaries, state machines, or multi-file features.
  Triggers: planning, architecture, design doc, state machine, data flow, feature plan, technical plan
- [Dev Container Tooling](skills/devcontainer-tooling.md) (`Tooling`) - Use when changing the VS Code dev container, installed tools, shell profiles, or post-create setup.
  Triggers: devcontainer, container, codex, cli, post-create, postcreate, powershell profile, pwsh profile, PSReadLine, toolchain
- [Godot GDScript Bindings](skills/godot-gdscript.md) (`Godot`) - Use when writing or reviewing Godot addon code, GDScript APIs, scenes, resources, or exports.
  Triggers: godot, gdscript, addon, plugin, scene, resource, export, api
- [Godot Transport Adapters](skills/godot-transport.md) (`Godot`) - Use when implementing or reviewing Godot transport adapters for WebSocket, WebRTC, polling, reconnect, or multiplayer APIs.
  Triggers: godot transport, client, runtime client, connect, connection, websocketpeer, WebSocketPeer, WebSocketClient, websocketmultiplayerpeer, browser export, Godot 3, Godot 4, webrtc, poll, reconnect, networking, protocol fixture
- [Review And Debugging](skills/review-debugging.md) (`Quality`) - Use when reviewing code, investigating bugs, or validating fixes before merge.
  Triggers: review, code review, debug, investigate, root cause, bug, regression, production risk
- [Security And Privacy](skills/security-privacy.md) (`Protocol`) - Use when handling tokens, user identifiers, logs, persistence, networking, or dependency decisions.
  Triggers: security, privacy, token, secret, logging, storage, tls, dependency
- [Signal Fish Protocol](skills/signal-fish-protocol.md) (`Protocol`) - Use when implementing protocol messages, transports, sessions, auth, or compatibility with upstream Signal Fish projects.
  Triggers: signal fish, protocol, websocket, session, auth, message, rust client, server
- [Testing And Automation](skills/testing-automation.md) (`Testing`) - Use when adding validation scripts, hooks, CI, Godot tests, fixtures, or generated-file checks.
  Triggers: test, ci, github actions, hook, pre-commit, lint, generated, fixture
- [Godot Web Export Constraints](skills/web-export.md) (`Godot`) - Use when code may run in browser exports, WebSocket or WebRTC transport, storage, crypto, or platform-specific Godot behavior.
  Triggers: web export, browser export, html5, browser, websocket, WebSocketPeer, WebSocketClient, client, runtime client, connect, connection, webrtc, cors, origin, mixed content, tls, storage, crypto, Godot 4

## Other LLM Files

- [GDScript Client Shape](code-samples/gdscript-client-shape.md) - Sketch of the intended GDScript-facing Signal Fish client shape.
- [LLM Context Organization](README.md) - Organization guide for repo-specific AI context files.
- [Godot Networking And Web Notes](research/godot-networking-web.md) - Source-backed notes for Godot WebSocket, WebRTC, browser export, and cross-platform networking decisions.
- [Godot Target Notes](research/godot-targets.md) - Compatibility notes for targeting major Godot versions from a GDScript Signal Fish addon.
- [GStack Adaptation Notes](research/gstack-adaptations.md) - Practical gstack practices adapted for this repo's lightweight LLM harness.
- [Signal Fish Upstream References](research/protocol-links.md) - Curated upstream references for Signal Fish protocol and client compatibility work.
