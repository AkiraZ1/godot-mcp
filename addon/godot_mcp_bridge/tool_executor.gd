@tool
extends RefCounted
## Implements every tool exposed over the MCP bridge. Each function returns a
## plain Dictionary: {ok: bool, output: String, error: String, data?: Variant,
## image_path?: String}. No signals, no async — every tool call is
## synchronous and returns its result directly.

var _undo_redo: EditorUndoRedoManager

func setup(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo

# ---------------------------------------------------------------------------
# Tool catalogue (JSON Schema-style "parameters", ready to hand to an LLM).
# ---------------------------------------------------------------------------

func get_tool_definitions() -> Array:
	return [
		{"name": "list_dir", "description": "Lists files and subdirectories of a res:// directory.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "Directory path (res://...)."}
			}, "required": ["path"]}},
		{"name": "read_file", "description": "Reads a file's content, optionally a specific line range (1-indexed, inclusive).",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "File path (res://...)."},
				"start_line": {"type": "integer", "description": "First line to return (default 1)."},
				"end_line": {"type": "integer", "description": "Last line to return (default: end of file)."}
			}, "required": ["path"]}},
		{"name": "find_file", "description": "Finds files under res:// whose name contains the given (case-insensitive) substring.",
			"parameters": {"type": "object", "properties": {
				"pattern": {"type": "string", "description": "Substring to match against file names."}
			}, "required": ["pattern"]}},
		{"name": "grep_search", "description": "Searches file contents under res:// for a substring (case-insensitive), returning path:line and the matching line, up to max_results.",
			"parameters": {"type": "object", "properties": {
				"query": {"type": "string", "description": "Text to search for."},
				"include": {"type": "string", "description": "Optional glob-like extension filter, e.g. '*.gd'. Defaults to common text/source extensions."},
				"max_results": {"type": "integer", "description": "Maximum number of matches to return (default 50)."}
			}, "required": ["query"]}},
		{"name": "write_file", "description": "Creates a new file or overwrites an existing one at the given res:// path with the given content. Creates parent directories as needed.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "File path (res://...)."},
				"content": {"type": "string", "description": "Full file content."}
			}, "required": ["path", "content"]}},
		{"name": "patch_file", "description": "Replaces one exact occurrence of search_content with replace_content inside an existing file. Fails if search_content is not found exactly once, so you don't silently corrupt a file.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "File path (res://...)."},
				"search_content": {"type": "string", "description": "Exact text to find. Must occur exactly once in the file."},
				"replace_content": {"type": "string", "description": "Text to put in its place."}
			}, "required": ["path", "search_content", "replace_content"]}},
		{"name": "delete_file", "description": "Deletes a file at the given res:// path.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "File path (res://...)."}
			}, "required": ["path"]}},
		{"name": "move_file", "description": "Moves or renames a file/directory, keeping Godot's dependency tracking consistent where possible.",
			"parameters": {"type": "object", "properties": {
				"from": {"type": "string", "description": "Current res:// path."},
				"to": {"type": "string", "description": "New res:// path."}
			}, "required": ["from", "to"]}},
		{"name": "reload_filesystem", "description": "Forces the editor to rescan res:// so it picks up files changed outside the editor (e.g. by another tool or text editor).",
			"parameters": {"type": "object", "properties": {}}},
		{"name": "view_file_outline", "description": "Returns a GDScript file's structure (class_name, extends, funcs, signals, exported vars, consts) with line numbers, without returning the full source.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "Path to a .gd file (res://...)."}
			}, "required": ["path"]}},
		{"name": "get_class_info", "description": "Returns a Godot class's parent class, and its properties, methods and signals (built-in engine classes and registered custom classes).",
			"parameters": {"type": "object", "properties": {
				"class_name": {"type": "string", "description": "Class to inspect, e.g. 'CharacterBody2D'."}
			}, "required": ["class_name"]}},
		{"name": "create_scene", "description": "Creates a new .tscn scene file with the given root node type and opens it in the editor.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "Scene path (res://...), must end in .tscn."},
				"root_type": {"type": "string", "description": "Root node class, e.g. 'Node2D'."},
				"root_name": {"type": "string", "description": "Name of the root node."}
			}, "required": ["path", "root_type", "root_name"]}},
		{"name": "open_scene", "description": "Opens an existing .tscn scene in the editor, making it the active scene for node/property tools.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "Scene path (res://...)."}
			}, "required": ["path"]}},
		{"name": "save_scene", "description": "Saves the currently open scene."},
		{"name": "add_node", "description": "Adds a new child node to a node in the currently open scene.",
			"parameters": {"type": "object", "properties": {
				"parent_path": {"type": "string", "description": "Path to the parent node ('.' for the scene root)."},
				"type": {"type": "string", "description": "Node class name, e.g. 'Sprite2D'."},
				"name": {"type": "string", "description": "Name for the new node."},
				"script_path": {"type": "string", "description": "Optional script (res://...) to attach to the new node."}
			}, "required": ["parent_path", "type", "name"]}},
		{"name": "remove_node", "description": "Removes a node from the currently open scene.",
			"parameters": {"type": "object", "properties": {
				"node_path": {"type": "string", "description": "Path to the node to remove."}
			}, "required": ["node_path"]}},
		{"name": "instance_scene", "description": "Instantiates an existing .tscn scene as a child of a node in the currently open scene.",
			"parameters": {"type": "object", "properties": {
				"parent_path": {"type": "string", "description": "Path to the parent node ('.' for root)."},
				"scene_path": {"type": "string", "description": "Path to the .tscn to instantiate."},
				"name": {"type": "string", "description": "Name for the new instance."}
			}, "required": ["parent_path", "scene_path", "name"]}},
		{"name": "set_property", "description": "Sets a property on a node (position, text, color, etc). Accepts numbers, strings, bools, and arrays for Vector2/Vector3/Color ([x,y], [x,y,z], [r,g,b] or [r,g,b,a]).",
			"parameters": {"type": "object", "properties": {
				"node_path": {"type": "string", "description": "Path to the node."},
				"property": {"type": "string", "description": "Property name, e.g. 'position', 'text', 'modulate'."},
				"value": {"description": "The value to assign."}
			}, "required": ["node_path", "property", "value"]}},
		{"name": "attach_script", "description": "Attaches an existing script to a node.",
			"parameters": {"type": "object", "properties": {
				"node_path": {"type": "string", "description": "Path to the node."},
				"script_path": {"type": "string", "description": "Script path (res://...)."}
			}, "required": ["node_path", "script_path"]}},
		{"name": "connect_signal", "description": "Connects a signal from one node to a method on another node.",
			"parameters": {"type": "object", "properties": {
				"source_path": {"type": "string", "description": "Node emitting the signal."},
				"signal_name": {"type": "string", "description": "Signal name, e.g. 'pressed'."},
				"target_path": {"type": "string", "description": "Node receiving the callback."},
				"method_name": {"type": "string", "description": "Method to call on the target."}
			}, "required": ["source_path", "signal_name", "target_path", "method_name"]}},
		{"name": "disconnect_signal", "description": "Disconnects a previously connected signal.",
			"parameters": {"type": "object", "properties": {
				"source_path": {"type": "string"}, "signal_name": {"type": "string"},
				"target_path": {"type": "string"}, "method_name": {"type": "string"}
			}, "required": ["source_path", "signal_name", "target_path", "method_name"]}},
		{"name": "create_resource", "description": "Creates a new .tres Resource file of the given type with optional initial property values.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "Save path (res://.../file.tres)."},
				"type": {"type": "string", "description": "Resource class name, e.g. 'ShaderMaterial'."},
				"properties": {"type": "object", "description": "Optional initial property values."}
			}, "required": ["path", "type"]}},
		{"name": "get_scene_tree", "description": "Dumps the node tree of the currently open scene starting at node_path (type, name, script, key transform properties), up to max_depth levels deep.",
			"parameters": {"type": "object", "properties": {
				"node_path": {"type": "string", "description": "Root of the dump ('.' for the scene root)."},
				"max_depth": {"type": "integer", "description": "How many levels deep to recurse (default 5)."}
			}, "required": ["node_path"]}},
		{"name": "select_node", "description": "Selects a node in the editor's Scene tree and Inspector. Useful before capture_editor_screenshot.",
			"parameters": {"type": "object", "properties": {
				"node_path": {"type": "string", "description": "Path to the node in the currently open scene."}
			}, "required": ["node_path"]}},
		{"name": "get_editor_state", "description": "Returns which scene is open, whether the game is currently running, and the selected nodes."},
		{"name": "run_game", "description": "Runs the game in the editor. Without scene_path, runs the project's main scene (like pressing F5); with it, runs that scene specifically (like F6).",
			"parameters": {"type": "object", "properties": {
				"scene_path": {"type": "string", "description": "Optional res:// path of a specific scene to run."}
			}}},
		{"name": "stop_game", "description": "Stops the game session started by run_game."},
		{"name": "capture_editor_screenshot", "description": "Captures a screenshot of the full editor window and returns it as an image."},
		{"name": "get_project_setting", "description": "Reads a setting from ProjectSettings (e.g. 'display/window/size/viewport_width', 'application/config/name').",
			"parameters": {"type": "object", "properties": {
				"name": {"type": "string", "description": "Property path in ProjectSettings."}
			}, "required": ["name"]}},
		{"name": "set_project_setting", "description": "Sets and saves a setting in ProjectSettings (and saves to project.godot).",
			"parameters": {"type": "object", "properties": {
				"name": {"type": "string", "description": "Property path in ProjectSettings."},
				"value": {"description": "Value to set (string, number, bool, etc)."}
			}, "required": ["name", "value"]}},
		{"name": "list_autoloads", "description": "Lists all configured autoload singletons in the project.",
			"parameters": {"type": "object", "properties": {}}},
		{"name": "add_autoload", "description": "Registers an autoload singleton in project.godot (script or scene).",
			"parameters": {"type": "object", "properties": {
				"name": {"type": "string", "description": "Singleton name (e.g. 'GlobalState')."},
				"path": {"type": "string", "description": "Path to the script or scene (res://...)."}
			}, "required": ["name", "path"]}},
		{"name": "remove_autoload", "description": "Removes an autoload singleton from project.godot.",
			"parameters": {"type": "object", "properties": {
				"name": {"type": "string", "description": "Singleton name to remove."}
			}, "required": ["name"]}}
	]

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

func execute_tool(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"list_dir": return _list_dir(args)
		"read_file": return _read_file(args)
		"find_file": return _find_file(args)
		"grep_search": return _grep_search(args)
		"write_file": return _write_file(args)
		"patch_file": return _patch_file(args)
		"delete_file": return _delete_file(args)
		"move_file": return _move_file(args)
		"reload_filesystem": return _reload_filesystem()
		"view_file_outline": return _view_file_outline(args)
		"get_class_info": return _get_class_info(args)
		"create_scene": return _create_scene(args)
		"open_scene": return _open_scene(args)
		"save_scene": return _save_scene()
		"add_node": return _add_node(args)
		"remove_node": return _remove_node(args)
		"instance_scene": return _instance_scene(args)
		"set_property": return _set_property(args)
		"attach_script": return _attach_script(args)
		"connect_signal": return _connect_signal(args)
		"disconnect_signal": return _disconnect_signal(args)
		"create_resource": return _create_resource(args)
		"get_scene_tree": return _get_scene_tree(args)
		"select_node": return _select_node(args)
		"get_editor_state": return _get_editor_state()
		"run_game": return _run_game(args)
		"stop_game": return _stop_game()
		"capture_editor_screenshot": return _capture_editor_screenshot()
		"get_project_setting": return _get_project_setting(args)
		"set_project_setting": return _set_project_setting(args)
		"list_autoloads": return _list_autoloads()
		"add_autoload": return _add_autoload(args)
		"remove_autoload": return _remove_autoload(args)
		_:
			return _err("Unknown tool '%s'." % tool_name)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _ok(output: String, data = null) -> Dictionary:
	var r := {"ok": true, "output": output, "error": ""}
	if data != null:
		r["data"] = data
	return r

func _err(msg: String) -> Dictionary:
	return {"ok": false, "output": "", "error": msg}

func _scene_root():
	return EditorInterface.get_edited_scene_root()

func _require_scene():
	var root = _scene_root()
	if not is_instance_valid(root):
		return null
	return root

func _resolve_node(node_path: String):
	var root = _require_scene()
	if root == null:
		return null
	if node_path == "." or node_path == "":
		return root
	return root.get_node_or_null(NodePath(node_path))

func _value_from_variant(v):
	# Accepts plain JSON-safe values from the MCP client and converts arrays
	# into the Godot vector/color types most properties expect.
	if v is Array:
		if v.size() == 2:
			return Vector2(v[0], v[1])
		if v.size() == 3:
			return Vector3(v[0], v[1], v[2])
		if v.size() == 4:
			return Color(v[0], v[1], v[2], v[3])
	return v

# ---------------------------------------------------------------------------
# File tools
# ---------------------------------------------------------------------------

func _list_dir(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", "res://"))
	var dir = DirAccess.open(path)
	if dir == null:
		return _err("Could not open directory: " + path)
	var entries: Array = []
	dir.list_dir_begin()
	var f = dir.get_next()
	while f != "":
		if not f.begins_with("."):
			entries.append(f + ("/" if dir.current_is_dir() else ""))
		f = dir.get_next()
	dir.list_dir_end()
	entries.sort()
	return _ok("\n".join(entries), entries)

func _read_file(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err("File not found: " + path)
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _err("Could not open file: " + path)
	var text = f.get_as_text()
	f.close()
	var start_line = int(args.get("start_line", 1))
	var end_line = int(args.get("end_line", -1))
	if start_line <= 1 and end_line == -1:
		return _ok(text)
	var lines = text.split("\n")
	var s = max(0, start_line - 1)
	var e = lines.size() if end_line == -1 else min(lines.size(), end_line)
	return _ok("\n".join(lines.slice(s, e)))

func _find_file(args: Dictionary) -> Dictionary:
	var pattern = str(args.get("pattern", "")).to_lower()
	var results: Array = []
	_walk("res://", func(path):
		if path.get_file().to_lower().contains(pattern):
			results.append(path)
	)
	return _ok("\n".join(results) if results.size() > 0 else "(no matches)", results)

func _grep_search(args: Dictionary) -> Dictionary:
	var query = str(args.get("query", "")).to_lower()
	var include = str(args.get("include", ""))
	var max_results = int(args.get("max_results", 50))
	var ext_filter = include.replace("*", "").replace(".", "") if include != "" else ""
	var lines_out: Array = []
	_walk("res://", func(path):
		if lines_out.size() >= max_results:
			return
		if ext_filter != "" and not path.ends_with("." + ext_filter):
			return
		if ext_filter == "" and not _is_text_file(path):
			return
		var f = FileAccess.open(path, FileAccess.READ)
		if f == null:
			return
		var line_no = 0
		while not f.eof_reached() and lines_out.size() < max_results:
			var line = f.get_line()
			line_no += 1
			if line.to_lower().contains(query):
				lines_out.append("%s:%d: %s" % [path, line_no, line.strip_edges()])
		f.close()
	)
	return _ok("\n".join(lines_out) if lines_out.size() > 0 else "(no matches)", lines_out)

func _is_text_file(path: String) -> bool:
	var ext = path.get_extension().to_lower()
	return ext in ["gd", "cs", "tscn", "tres", "cfg", "json", "txt", "md", "gdshader", "import"]

func _walk(dir_path: String, callback: Callable) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f = dir.get_next()
	while f != "":
		if not f.begins_with(".") and f != "addons":
			var full = dir_path.path_join(f)
			if dir.current_is_dir():
				_walk(full, callback)
			else:
				callback.call(full)
		f = dir.get_next()
	dir.list_dir_end()

func _write_file(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	var content = str(args.get("content", ""))
	var dir_path = path.get_base_dir()
	if dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("Could not write file: " + path + " (error %d)" % FileAccess.get_open_error())
	f.store_string(content)
	f.close()
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok("Wrote " + path)

func _patch_file(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	var search_content = str(args.get("search_content", ""))
	var replace_content = str(args.get("replace_content", ""))
	if not FileAccess.file_exists(path):
		return _err("File not found: " + path)
	var f = FileAccess.open(path, FileAccess.READ)
	var text = f.get_as_text()
	f.close()
	var count = text.count(search_content)
	if count == 0:
		return _err("search_content not found in " + path)
	if count > 1:
		return _err("search_content occurs %d times in %s; must be unique. Add more surrounding context." % [count, path])
	var new_text = text.replace(search_content, replace_content)
	var wf = FileAccess.open(path, FileAccess.WRITE)
	wf.store_string(new_text)
	wf.close()
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok("Patched " + path)

func _delete_file(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	var err = DirAccess.remove_absolute(path)
	if err != OK:
		return _err("Could not delete %s (error %d)" % [path, err])
	EditorInterface.get_resource_filesystem().scan()
	return _ok("Deleted " + path)

func _move_file(args: Dictionary) -> Dictionary:
	var from = str(args.get("from", ""))
	var to = str(args.get("to", ""))
	var dir_path = to.get_base_dir()
	if dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var err = DirAccess.rename_absolute(from, to)
	if err != OK:
		return _err("Could not move %s -> %s (error %d)" % [from, to, err])
	EditorInterface.get_resource_filesystem().scan()
	return _ok("Moved %s -> %s" % [from, to])

func _reload_filesystem() -> Dictionary:
	EditorInterface.get_resource_filesystem().scan()
	return _ok("Filesystem rescan requested.")

func _view_file_outline(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err("File not found: " + path)
	var f = FileAccess.open(path, FileAccess.READ)
	var lines: Array = []
	var i = 0
	var re_func = RegEx.new(); re_func.compile("^\\s*(static\\s+)?func\\s+(\\w+)")
	var re_signal = RegEx.new(); re_signal.compile("^\\s*signal\\s+(\\w+)")
	var re_var = RegEx.new(); re_var.compile("^\\s*(@export[^\\n]*\\n\\s*)?var\\s+(\\w+)")
	var re_const = RegEx.new(); re_const.compile("^\\s*const\\s+(\\w+)")
	var re_class = RegEx.new(); re_class.compile("^\\s*class_name\\s+(\\w+)")
	var re_extends = RegEx.new(); re_extends.compile("^\\s*extends\\s+(\\S+)")
	while not f.eof_reached():
		var line = f.get_line()
		i += 1
		var m
		m = re_class.search(line)
		if m: lines.append("%d: class_name %s" % [i, m.get_string(1)])
		m = re_extends.search(line)
		if m: lines.append("%d: extends %s" % [i, m.get_string(1)])
		m = re_func.search(line)
		if m: lines.append("%d: func %s" % [i, m.get_string(2)])
		m = re_signal.search(line)
		if m: lines.append("%d: signal %s" % [i, m.get_string(1)])
		m = re_var.search(line)
		if m: lines.append("%d: var %s" % [i, m.get_string(2)])
		m = re_const.search(line)
		if m: lines.append("%d: const %s" % [i, m.get_string(1)])
	f.close()
	return _ok("\n".join(lines) if lines.size() > 0 else "(no top-level symbols found)")

func _get_class_info(args: Dictionary) -> Dictionary:
	var cname = str(args.get("class_name", ""))
	if not ClassDB.class_exists(cname):
		return _err("Unknown class: " + cname)
	var parent = ClassDB.get_parent_class(cname)
	var methods: Array = []
	for m in ClassDB.class_get_method_list(cname, true):
		methods.append(m.get("name", ""))
	var props: Array = []
	for p in ClassDB.class_get_property_list(cname, true):
		props.append(p.get("name", ""))
	var signals: Array = []
	for s in ClassDB.class_get_signal_list(cname, true):
		signals.append(s.get("name", ""))
	var data := {"class": cname, "parent": parent, "properties": props, "methods": methods, "signals": signals}
	return _ok(JSON.stringify(data), data)

# ---------------------------------------------------------------------------
# Scene / node tools
# ---------------------------------------------------------------------------

func _create_scene(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	var root_type = str(args.get("root_type", ""))
	var root_name = str(args.get("root_name", ""))
	if not path.ends_with(".tscn"):
		return _err("path must end in .tscn")
	if not ClassDB.class_exists(root_type):
		return _err("Unknown node class: " + root_type)
	var root = ClassDB.instantiate(root_type)
	if root == null:
		return _err("Could not instantiate root type: " + root_type)
	root.name = root_name
	var dir_path = path.get_base_dir()
	if dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var packed = PackedScene.new()
	var pack_err = packed.pack(root)
	if pack_err != OK:
		root.free()
		return _err("Could not pack scene (error %d)" % pack_err)
	var save_err = ResourceSaver.save(packed, path)
	root.free()
	if save_err != OK:
		return _err("Could not save scene (error %d)" % save_err)
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	return _ok("Created and opened scene: " + path)

func _open_scene(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err("Scene not found: " + path)
	EditorInterface.open_scene_from_path(path)
	return _ok("Opened scene: " + path)

func _save_scene() -> Dictionary:
	if _require_scene() == null:
		return _err("No scene is currently open.")
	var err = EditorInterface.save_scene()
	if err != OK:
		return _err("Could not save scene (error %d)" % err)
	return _ok("Scene saved.")

func _add_node(args: Dictionary) -> Dictionary:
	var root = _require_scene()
	if root == null:
		return _err("No scene is currently open. Use open_scene or create_scene first.")
	var parent = _resolve_node(str(args.get("parent_path", ".")))
	if parent == null:
		return _err("Parent node not found: " + str(args.get("parent_path")))
	var node_type = str(args.get("type", ""))
	if not ClassDB.class_exists(node_type):
		return _err("Unknown node class: " + node_type)
	var node = ClassDB.instantiate(node_type)
	if node == null:
		return _err("Could not instantiate node class: " + node_type)
	node.name = str(args.get("name", node_type))
	parent.add_child(node)
	node.owner = root
	var script_path = str(args.get("script_path", ""))
	if script_path != "":
		if not FileAccess.file_exists(script_path):
			return _err("Node added, but script not found: " + script_path)
		node.set_script(load(script_path))
	_save_scene()
	return _ok("Added %s '%s' under %s" % [node_type, node.name, args.get("parent_path")])

func _remove_node(args: Dictionary) -> Dictionary:
	var root = _require_scene()
	if root == null:
		return _err("No scene is currently open.")
	var node_path = str(args.get("node_path", ""))
	var node = _resolve_node(node_path)
	if node == null:
		return _err("Node not found: " + node_path)
	if node == root:
		return _err("Refusing to remove the scene root. Delete the scene file instead if that's intended.")
	node.get_parent().remove_child(node)
	node.queue_free()
	_save_scene()
	return _ok("Removed node: " + node_path)

func _instance_scene(args: Dictionary) -> Dictionary:
	var root = _require_scene()
	if root == null:
		return _err("No scene is currently open.")
	var parent = _resolve_node(str(args.get("parent_path", ".")))
	if parent == null:
		return _err("Parent node not found: " + str(args.get("parent_path")))
	var scene_path = str(args.get("scene_path", ""))
	if not FileAccess.file_exists(scene_path):
		return _err("Scene not found: " + scene_path)
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return _err("Could not load scene: " + scene_path)
	var instance = packed.instantiate()
	instance.name = str(args.get("name", instance.name))
	parent.add_child(instance)
	instance.owner = root
	_save_scene()
	return _ok("Instanced %s as '%s' under %s" % [scene_path, instance.name, args.get("parent_path")])

func _set_property(args: Dictionary) -> Dictionary:
	var node_path = str(args.get("node_path", ""))
	var node = _resolve_node(node_path)
	if node == null:
		return _err("Node not found: " + node_path)
	var prop = str(args.get("property", ""))
	if not (prop in node):
		return _err("Node %s has no property '%s'." % [node_path, prop])
	var value = _value_from_variant(args.get("value"))
	node.set(prop, value)
	_save_scene()
	return _ok("Set %s.%s = %s" % [node_path, prop, str(value)])

func _attach_script(args: Dictionary) -> Dictionary:
	var node_path = str(args.get("node_path", ""))
	var node = _resolve_node(node_path)
	if node == null:
		return _err("Node not found: " + node_path)
	var script_path = str(args.get("script_path", ""))
	if not FileAccess.file_exists(script_path):
		return _err("Script not found: " + script_path)
	node.set_script(load(script_path))
	_save_scene()
	return _ok("Attached %s to %s" % [script_path, node_path])

func _connect_signal(args: Dictionary) -> Dictionary:
	var source = _resolve_node(str(args.get("source_path", "")))
	var target = _resolve_node(str(args.get("target_path", "")))
	if source == null:
		return _err("Source node not found: " + str(args.get("source_path")))
	if target == null:
		return _err("Target node not found: " + str(args.get("target_path")))
	var signal_name = str(args.get("signal_name", ""))
	var method_name = str(args.get("method_name", ""))
	if not source.has_signal(signal_name):
		return _err("Node %s has no signal '%s'." % [args.get("source_path"), signal_name])
	if source.is_connected(signal_name, Callable(target, method_name)):
		return _ok("Already connected.")
	var err = source.connect(signal_name, Callable(target, method_name))
	if err != OK:
		return _err("Could not connect (error %d)" % err)
	_save_scene()
	return _ok("Connected %s.%s -> %s.%s" % [args.get("source_path"), signal_name, args.get("target_path"), method_name])

func _disconnect_signal(args: Dictionary) -> Dictionary:
	var source = _resolve_node(str(args.get("source_path", "")))
	var target = _resolve_node(str(args.get("target_path", "")))
	if source == null or target == null:
		return _err("Source or target node not found.")
	var signal_name = str(args.get("signal_name", ""))
	var method_name = str(args.get("method_name", ""))
	var callable = Callable(target, method_name)
	if not source.is_connected(signal_name, callable):
		return _err("Not connected.")
	source.disconnect(signal_name, callable)
	_save_scene()
	return _ok("Disconnected %s.%s -> %s.%s" % [args.get("source_path"), signal_name, args.get("target_path"), method_name])

func _create_resource(args: Dictionary) -> Dictionary:
	var path = str(args.get("path", ""))
	var rtype = str(args.get("type", ""))
	if not ClassDB.class_exists(rtype):
		return _err("Unknown resource class: " + rtype)
	var res = ClassDB.instantiate(rtype)
	if res == null:
		return _err("Could not instantiate resource class: " + rtype)
	var properties = args.get("properties", {})
	if properties is Dictionary:
		for k in properties.keys():
			res.set(k, _value_from_variant(properties[k]))
	var dir_path = path.get_base_dir()
	if dir_path != "" and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var err = ResourceSaver.save(res, path)
	if err != OK:
		return _err("Could not save resource (error %d)" % err)
	EditorInterface.get_resource_filesystem().scan()
	return _ok("Created resource: " + path)

func _get_scene_tree(args: Dictionary) -> Dictionary:
	var start = _resolve_node(str(args.get("node_path", ".")))
	if start == null:
		return _err("Node not found: " + str(args.get("node_path")))
	var max_depth = int(args.get("max_depth", 5))
	var lines: Array = []
	_dump_node(start, 0, max_depth, lines)
	return _ok("\n".join(lines))

func _dump_node(node: Node, depth: int, max_depth: int, lines: Array) -> void:
	if depth > max_depth:
		return
	var indent = "  ".repeat(depth)
	var script_note = ""
	if node.get_script() != null:
		script_note = " [script: %s]" % node.get_script().resource_path
	lines.append("%s%s (%s)%s" % [indent, node.name, node.get_class(), script_note])
	for child in node.get_children():
		_dump_node(child, depth + 1, max_depth, lines)

func _select_node(args: Dictionary) -> Dictionary:
	var node_path = str(args.get("node_path", ""))
	var node = _resolve_node(node_path)
	if node == null:
		return _err("Node not found: " + node_path)
	var sel = EditorInterface.get_selection()
	sel.clear()
	sel.add_node(node)
	return _ok("Selected: " + node_path)

func _get_editor_state() -> Dictionary:
	var root = _scene_root()
	var selected: Array = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if is_instance_valid(root) and root.is_ancestor_of(n):
			selected.append(str(root.get_path_to(n)))
		else:
			selected.append(str(n.get_path()))
	var data := {
		"open_scene": (root.scene_file_path if is_instance_valid(root) else ""),
		"is_playing": EditorInterface.is_playing_scene(),
		"selected_nodes": selected,
	}
	return _ok(JSON.stringify(data), data)

# ---------------------------------------------------------------------------
# Runtime tools
# ---------------------------------------------------------------------------

func _run_game(args: Dictionary) -> Dictionary:
	var scene_path = str(args.get("scene_path", ""))
	if scene_path != "":
		if not FileAccess.file_exists(scene_path):
			return _err("Scene not found: " + scene_path)
		EditorInterface.play_custom_scene(scene_path)
		return _ok("Running scene: " + scene_path)
	EditorInterface.play_main_scene()
	return _ok("Running main scene.")

func _stop_game() -> Dictionary:
	EditorInterface.stop_playing_scene()
	return _ok("Stopped.")

func _capture_editor_screenshot() -> Dictionary:
	var base_control = EditorInterface.get_base_control()
	if base_control == null:
		return _err("Editor base control not found.")
	var viewport = base_control.get_viewport()
	if viewport == null:
		return _err("Editor viewport not found.")
	var tex = viewport.get_texture()
	if tex == null:
		return _err("Viewport texture is empty.")
	var img = tex.get_image()
	if img == null or img.is_empty():
		return _err("Failed to capture screenshot: image is empty.")
	var out_path = "user://mcp_bridge_screenshot.png"
	var err = img.save_png(out_path)
	if err != OK:
		return _err("Failed to save screenshot (error %d)" % err)
	var r = _ok("Screenshot saved.")
	r["image_path"] = ProjectSettings.globalize_path(out_path)
	return r

# ---------------------------------------------------------------------------
# Project settings & Autoload tools
# ---------------------------------------------------------------------------

func _get_project_setting(args: Dictionary) -> Dictionary:
	var setting_name = str(args.get("name", ""))
	if setting_name == "":
		return _err("Setting name is required.")
	if not ProjectSettings.has_setting(setting_name):
		return _err("Setting '%s' does not exist." % setting_name)
	var val = ProjectSettings.get_setting(setting_name)
	return _ok("Setting %s = %s" % [setting_name, str(val)], val)

func _set_project_setting(args: Dictionary) -> Dictionary:
	var setting_name = str(args.get("name", ""))
	if setting_name == "":
		return _err("Setting name is required.")
	var val = args.get("value")
	ProjectSettings.set_setting(setting_name, val)
	var err = ProjectSettings.save()
	if err != OK:
		return _err("Failed to save project settings (error %d)" % err)
	return _ok("Set and saved %s = %s" % [setting_name, str(val)])

func _list_autoloads() -> Dictionary:
	var list: Array = []
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop.get("name", "")
		if pname.begins_with("autoload/"):
			var autoload_name = pname.trim_prefix("autoload/")
			var path_val = ProjectSettings.get_setting(pname)
			list.append({"name": autoload_name, "path": path_val})
	return _ok(JSON.stringify(list), list)

func _add_autoload(args: Dictionary) -> Dictionary:
	var name = str(args.get("name", "")).strip_edges()
	var path = str(args.get("path", "")).strip_edges()
	if name == "" or path == "":
		return _err("Both 'name' and 'path' are required.")
	if not FileAccess.file_exists(path):
		return _err("Autoload target file does not exist: %s" % path)
	ProjectSettings.set_setting("autoload/" + name, "*" + path)
	var err = ProjectSettings.save()
	if err != OK:
		return _err("Failed to save project settings (error %d)" % err)
	return _ok("Added autoload singleton: %s -> %s" % [name, path])

func _remove_autoload(args: Dictionary) -> Dictionary:
	var name = str(args.get("name", "")).strip_edges()
	if name == "":
		return _err("Autoload 'name' is required.")
	var key = "autoload/" + name
	if not ProjectSettings.has_setting(key):
		return _err("Autoload '%s' is not registered." % name)
	ProjectSettings.set_setting(key, null)
	var err = ProjectSettings.save()
	if err != OK:
		return _err("Failed to save project settings (error %d)" % err)
	return _ok("Removed autoload singleton: %s" % name)
