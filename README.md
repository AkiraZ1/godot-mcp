# Godot MCP — MCP server for the Godot 4 editor

**An [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server
for Godot.** Drive the Godot 4 editor directly from any AI coding agent that
speaks MCP — Claude Code, Codex, Antigravity, Hermes, OpenClaw, Claude
Desktop, Cursor, and any other MCP client. Create and edit scenes, add and
configure nodes, write and patch scripts, run the game, and inspect editor
state, all from your agent's normal tool-calling loop.

This is not tied to any one AI product. MCP is an open, standard protocol —
this server works with whichever MCP client you already use.

It has two halves that talk to each other over a local TCP socket:

- **`addon/godot_mcp_bridge`** — a small Godot editor plugin. It implements
  every tool (file I/O, scene/node editing, running the game, ...) and opens
  a TCP server on `127.0.0.1:8756` while the editor is running.
- **`server/`** — a standalone MCP server (Node.js). It speaks MCP over
  stdio to your agent, and forwards tool calls to the editor plugin over
  that TCP socket. It also exposes a couple of tools that work without the
  editor open at all (`godot_build`, `godot_check_boot`).

Nothing here is Claude-specific. MCP is a standard protocol; any client that
implements it can use this server unmodified.

## Requirements

- Godot 4.x (tested on 4.7).
- Node.js 18+.
- Optional, only for the two "editor not required" tools: the `godot`
  executable on your `PATH` (or set `GODOT_BIN`), and the .NET SDK if your
  project uses C#.

## Install

0. **Clone this repo** somewhere on disk:

   ```bash
   git clone https://github.com/AkiraZ1/godot-mcp.git
   ```

1. **Copy the addon into your Godot project:**

   ```bash
   cp -r addon/godot_mcp_bridge <your-godot-project>/addons/
   ```

   Then in Godot: **Project > Project Settings > Plugins**, enable
   **Godot MCP Bridge**. You'll see `[Godot MCP Bridge] active. Listening for
   an MCP client on port 8756.` printed in the Output panel.

   The port is a project setting (`mcp_bridge/port`, default `8756`) — change
   it there if you need to run more than one Godot project's bridge at once.

2. **Install the server's dependencies:**

   ```bash
   cd server && npm install
   ```

3. **Point your MCP client at `server/server.mjs`.** Most clients (Claude
   Code, Claude Desktop, and others) use the same JSON shape:

   ```json
   {
     "mcpServers": {
       "godot": {
         "command": "node",
         "args": ["/absolute/path/to/godot-mcp/server/server.mjs"],
         "env": {
           "GODOT_PROJECT_PATH": "/absolute/path/to/your/godot/project"
         }
       }
     }
   }
   ```

   - **Claude Code**: put this in `.mcp.json` at your project root (or add it
     via `claude mcp add`).
   - **Codex CLI**: add to `~/.codex/config.toml`:

     ```toml
     [mcp_servers.godot]
     command = "node"
     args = ["/absolute/path/to/godot-mcp/server/server.mjs"]
     env = { GODOT_PROJECT_PATH = "/absolute/path/to/your/godot/project" }
     ```

     (check `codex mcp --help` / your Codex version's docs if the exact keys differ)

   - **Anything else**: check your client's docs for where it wants an MCP
     server entry — the `command`/`args`/`env` shape above is the same
     everywhere, only the surrounding file differs.

4. Open your project in the Godot editor (the plugin must be running for the
   scene/node/script tools to work), and start using the tools from your
   agent.

### Environment variables (all optional)

| Variable             | Default                  | Purpose                                                        |
|----------------------|---------------------------|-----------------------------------------------------------------|
| `GODOT_PROJECT_PATH`  | current working directory | Folder containing your `project.godot`, used by the CLI tools. |
| `GODOT_BIN`           | auto-detected (`godot4`/`godot`/`Godot` on `PATH`) | Path to the Godot executable. |
| `GODOT_MCP_PORT`      | `8756`                     | Must match the addon's `mcp_bridge/port` project setting.       |

## Tools

### Live-editor tools (require the project open in Godot)

| Tool | What it does |
|---|---|
| `list_dir`, `read_file`, `find_file`, `grep_search` | Browse and search the project's files. |
| `write_file`, `patch_file`, `delete_file`, `move_file` | Create, surgically edit, delete, or move/rename any file. |
| `reload_filesystem` | Force the editor to rescan `res://` after external edits. |
| `view_file_outline` | Structure of a `.gd` file (functions, signals, vars) with line numbers. |
| `get_class_info` | A Godot class's parent, properties, methods and signals. |
| `create_scene`, `open_scene`, `save_scene` | Create/open/save a `.tscn`. |
| `add_node`, `remove_node`, `instance_scene` | Build the scene tree. |
| `set_property`, `attach_script` | Configure a node. |
| `connect_signal`, `disconnect_signal` | Wire nodes together. |
| `create_resource` | Create a `.tres` resource with initial property values. |
| `get_scene_tree` | Dump a subtree (type, name, script) for orientation. |
| `select_node`, `get_editor_state` | Editor selection/state, e.g. before a screenshot. |
| `run_game`, `stop_game` | Play the main scene or a specific one; stop it. |
| `capture_editor_screenshot` | Screenshot of the editor window (needs a real window — not headless). |
| `get_project_setting`, `set_project_setting` | Read/write any `ProjectSettings` key (e.g. `application/config/name`), saved to `project.godot`. |
| `list_autoloads`, `add_autoload`, `remove_autoload` | Inspect and manage autoload singletons. Changes take effect on the next editor/project restart. |

### CLI tools (work even if the editor isn't running)

| Tool | What it does |
|---|---|
| `godot_build` | Runs `dotnet build` for C# projects and returns compiler errors. |
| `godot_check_boot` | Boots the project headless for a few seconds and reports startup/script errors. |
| `godot_run_gut_tests` | Runs the [GUT](https://github.com/bitwes/Gut) test suite headless (requires the GUT addon installed in your project). |
| `godot_export` | Runs a configured export preset (`export_presets.cfg`) to produce a build. |

## How it works

The addon's `tool_executor.gd` implements each tool as a plain function that
returns `{ok, output, error, data?, image_path?}` — no signals, no async, one
call in and one result out. `mcp_bridge.gd` is a thin `TCPServer` that reads
newline-delimited JSON requests and calls straight into the executor.
`server/server.mjs` is a standard MCP server that forwards `tools/list` and
`tools/call` to that socket and converts the tool schemas along the way.

## Known limitations / good first issues

- Editor mutations don't go through `EditorUndoRedoManager`, so they won't
  show up in the editor's Ctrl+Z history. Wiring that up per-tool would be a
  great contribution.
- `move_file` doesn't yet move a script's companion `.uid` file.
- `capture_editor_screenshot` only works with a real editor window (not
  `--headless`), since there's no framebuffer to read otherwise.
- No LSP-backed diagnostics tool yet (GDScript or C#) — `godot_check_boot`
  only catches startup errors, not deeper static analysis.
- `add_autoload`/`remove_autoload` edit `project.godot` directly; the running
  editor won't reflect the change (and won't instantiate/remove the
  singleton) until you restart it or reopen the project.

## Also on Smithery

This server is listed on [Smithery](https://smithery.ai) (see
[`smithery.yaml`](smithery.yaml)) for discovery alongside other MCP servers.
Since it bridges to a Godot editor running on your own machine, install it
locally either way — Smithery's cloud sandbox has no access to your editor.

## Contributing

PRs welcome — this project is intentionally kept small and dependency-light
(one runtime dependency: the official MCP SDK). Please:

- Keep new tools synchronous and return the same `{ok, output, error}` shape.
- Test against a real Godot editor instance (headless is fine for most tools;
  see "Known limitations" for what headless can't cover).
- Avoid adding tools that require a specific project layout — this repo
  targets any Godot 4 project, not a particular game.

## License

MIT — see [LICENSE](LICENSE).
