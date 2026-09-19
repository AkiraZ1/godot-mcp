# Contributing

Thanks for considering a contribution. This project stays deliberately small,
so please keep changes focused.

## Setup

```bash
cd server && npm install
```

Then copy `addon/godot_mcp_bridge` into a Godot 4 project's `addons/` folder
and enable it under Project Settings > Plugins to test against a real editor.

## Guidelines

- New tools live in `addon/godot_mcp_bridge/tool_executor.gd`. Each one is a
  plain function returning `{ok, output, error, data?, image_path?}` — no
  signals, no `await`. Add its schema to `get_tool_definitions()` and a case
  in `execute_tool()`.
- Tools that don't need a scene open should say so clearly in their error
  message (see `_require_scene()` usage) rather than crashing.
- CLI-only tools (that work without the editor open) live in
  `server/server.mjs`'s `LOCAL_TOOLS`.
- Don't assume a specific project layout (no hardcoded scene/script paths,
  project names, or build systems) — this targets any Godot 4 project.
- Test manually against a real Godot editor before opening a PR; headless
  (`godot --headless --editor --path <project>`) works for most tools except
  `capture_editor_screenshot`, which needs a real window.

## Pull requests

Open an issue first for anything beyond a small fix, so we can agree on the
approach. Keep PRs scoped to one tool/fix at a time where possible — it makes
review much faster.
