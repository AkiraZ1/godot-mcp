@tool
extends RefCounted
class_name GodotMcpBridge
## TCP bridge exposing ToolExecutor to an external MCP server (see
## server/server.mjs in this repo). Protocol: newline-delimited JSON on
## 127.0.0.1:<port>. One JSON object per line in, one JSON object per line out.
##
## Request:  {"id": 1, "cmd": "list_tools"}
##           {"id": 2, "cmd": "call_tool", "name": "read_file", "args": {...}}
## Response: {"id": 1, "result": [...]}
##           {"id": 2, "result": {"ok": true, "output": "...", "data": ...}}
##           {"id": 2, "error": "message"}

var port: int = 8756

var _server: TCPServer
var _peer: StreamPeerTCP
var _buffer := PackedByteArray()
var _executor: RefCounted

func setup(executor: RefCounted, listen_port: int = 8756) -> void:
	_executor = executor
	port = listen_port

	_server = TCPServer.new()
	var err = _server.listen(port, "127.0.0.1")
	if err != OK:
		push_warning("[Godot MCP Bridge] failed to listen on 127.0.0.1:%d (error %d). Is another instance already running?" % [port, err])
		_server = null

func poll() -> void:
	if _server == null:
		return

	if _server.is_connection_available() and (_peer == null or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED):
		_peer = _server.take_connection()
		_buffer = PackedByteArray()

	if _peer == null:
		return

	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer = null
		return

	var avail = _peer.get_available_bytes()
	if avail > 0:
		var chunk = _peer.get_data(avail)
		if chunk[0] == OK:
			_buffer.append_array(chunk[1])
			_process_buffer()

func shutdown() -> void:
	if _peer:
		_peer.disconnect_from_host()
		_peer = null
	if _server:
		_server.stop()
		_server = null

func _process_buffer() -> void:
	while true:
		var nl_idx = _buffer.find(10) # \n
		if nl_idx == -1:
			break
		var line_bytes = _buffer.slice(0, nl_idx)
		_buffer = _buffer.slice(nl_idx + 1)
		var line = line_bytes.get_string_from_utf8().strip_edges()
		if line != "":
			_handle_request(line)

func _handle_request(line: String) -> void:
	var json := JSON.new()
	var parse_err = json.parse(line)
	if parse_err != OK:
		_send({"error": "invalid json: " + line})
		return

	var req = json.data
	if typeof(req) != TYPE_DICTIONARY:
		_send({"error": "request must be a JSON object"})
		return

	var id = req.get("id")
	var cmd = str(req.get("cmd", ""))
	var resp := {"id": id}

	match cmd:
		"ping":
			resp["result"] = "pong"
		"list_tools":
			resp["result"] = _executor.get_tool_definitions()
		"call_tool":
			var name = str(req.get("name", ""))
			var args = req.get("args", {})
			if typeof(args) != TYPE_DICTIONARY:
				args = {}
			resp["result"] = _executor.execute_tool(name, args)
		_:
			resp["error"] = "unknown cmd: " + cmd

	_send(resp)

func _send(obj: Dictionary) -> void:
	if _peer == null or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var s = JSON.stringify(obj) + "\n"
	_peer.put_data(s.to_utf8_buffer())
