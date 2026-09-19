@tool
extends EditorPlugin
## Godot MCP Bridge
##
## Starts a local TCP bridge (see mcp_bridge.gd) exposing this editor's
## ToolExecutor to an external MCP server, so any MCP-speaking AI coding
## agent (Claude Code, Codex, Antigravity, Hermes, OpenClaw, ...) can drive
## the Godot editor directly: create/edit scenes, nodes, scripts and
## resources, run the game, and inspect editor state.
##
## Configure the port via Project Settings > Mcp Bridge > Port (default 8756).

const ToolExecutorScript = preload("res://addons/godot_mcp_bridge/tool_executor.gd")
const McpBridgeScript = preload("res://addons/godot_mcp_bridge/mcp_bridge.gd")

var executor
var bridge

func _enter_tree() -> void:
	_ensure_project_setting("mcp_bridge/port", 8756)

	executor = ToolExecutorScript.new()
	executor.setup(get_undo_redo())

	bridge = McpBridgeScript.new()
	bridge.setup(executor, ProjectSettings.get_setting("mcp_bridge/port", 8756))

	set_process(true)
	print("[Godot MCP Bridge] active. Listening for an MCP client on port %d." % bridge.port)

func _process(_delta: float) -> void:
	if bridge:
		bridge.poll()

func _exit_tree() -> void:
	if bridge:
		bridge.shutdown()
		bridge = null
	executor = null
	print("[Godot MCP Bridge] deactivated.")

func _ensure_project_setting(name: String, default_value) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default_value)
	ProjectSettings.set_initial_value(name, default_value)
