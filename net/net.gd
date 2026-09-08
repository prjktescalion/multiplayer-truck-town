extends Node

## Multiplayer session management, autoloaded as `Net`.
##
## The server is always dedicated: it holds no local player and simulates no physics, it only
## relays truck state between clients. Each client fully simulates its own truck and replicates
## the resulting transform, so controls stay responsive even over the internet.
##
## Run a server with:
##     godot --headless --path . -- --server [--port=8910]

## Default game server port. Can be any number between 1024 and 49151.
const DEFAULT_PORT := 8910

## The maximum number of simultaneous players.
const MAX_PLAYERS := 8

## Used when the page is served over HTTPS (where the game server can't be the page's host).
## Set this to the deployed server after `fly deploy`, e.g. "wss://truck-town.fly.dev".
const DEFAULT_PUBLIC_SERVER_URL := ""

## Selectable trucks, in the same order as the buttons in `car_select.tscn`.
const VEHICLE_SCENES: Array[PackedScene] = [
	preload("res://vehicles/car_base.tscn"),
	preload("res://vehicles/trailer_truck.tscn"),
	preload("res://vehicles/tow_truck.tscn"),
]

const TOWN_SCENE: PackedScene = preload("res://town/town_scene.tscn")

## Emitted on the server whenever a player joins or leaves.
signal players_changed()

## Emitted on a client once its truck can be spawned.
signal joined()

## Emitted on a client when connecting fails or the server drops us.
signal disconnected(reason: String)

## Peer id -> {name: String, vehicle: int}. Only populated on the server.
var players: Dictionary[int, Dictionary] = {}

## True when this process was started with `--server`, or is a dedicated server export.
var is_dedicated_server := false

var local_player_name := "Player"
var local_vehicle := 0

## Per-client visual quality preference, not replicated.
var local_sdfgi := false

var _peer: WebSocketMultiplayerPeer = null
var _town: Node3D = null
var _server_port := DEFAULT_PORT


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	var args := OS.get_cmdline_user_args()
	if "--server" in args or OS.has_feature("dedicated_server"):
		# Set the flag synchronously so `car_select.gd` can hide itself, but defer the actual
		# listen call: we can't add the town to the root while the scene tree is still setting up.
		is_dedicated_server = true
		_server_port = _parse_port(args)
		_start_dedicated_server.call_deferred()
	elif "--client" in args:
		# Skip the menu and join straight away. Handy for testing, and for launching a second
		# window on the same machine.
		_autojoin.call_deferred(_parse_int_arg(args, "--truck=", 0))


func _autojoin(vehicle: int) -> void:
	join(default_server_url(), local_player_name, vehicle)


## Resolves the address a client should connect to, in priority order:
## an explicit `?server=` query parameter, then the host that served the page (the local LAN
## case), then the baked-in public server.
func default_server_url() -> String:
	if not OS.has_feature("web"):
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--url="):
				return arg.trim_prefix("--url=")
		return "ws://127.0.0.1:%d" % DEFAULT_PORT

	var query := str(JavaScriptBridge.eval("window.location.search", true))
	var override := _query_value(query, "server")
	if not override.is_empty():
		return override

	var protocol := str(JavaScriptBridge.eval("window.location.protocol", true))
	if protocol == "https:":
		# The page came from static hosting, so the game server lives somewhere else entirely.
		return DEFAULT_PUBLIC_SERVER_URL

	var hostname := str(JavaScriptBridge.eval("window.location.hostname", true))
	return "ws://%s:%d" % [hostname, DEFAULT_PORT]


func join(url: String, player_name: String, vehicle: int) -> void:
	local_player_name = player_name
	local_vehicle = vehicle

	if url.is_empty():
		disconnected.emit("No server address configured.")
		return

	# Load the town before connecting. The MultiplayerSpawner it creates must already exist by the
	# time the server starts replicating trucks to us, otherwise the spawn packets have nowhere to go.
	_load_town()

	_peer = WebSocketMultiplayerPeer.new()
	var err := _peer.create_client(url)
	if err != OK:
		_peer = null
		disconnected.emit("Could not reach %s (%s)." % [url, error_string(err)])
		return

	multiplayer.multiplayer_peer = _peer


func leave() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null
	players.clear()
	_unload_town()
	# An empty reason means "you asked to leave", not "something broke".
	disconnected.emit("")


func _start_dedicated_server() -> void:
	_load_town()

	_peer = WebSocketMultiplayerPeer.new()
	# WebSocketMultiplayerPeer takes no peer limit; MAX_PLAYERS is enforced in `_register()`.
	var err := _peer.create_server(_server_port, "*")
	if err != OK:
		push_error("Failed to listen on port %d: %s" % [_server_port, error_string(err)])
		return

	multiplayer.multiplayer_peer = _peer
	print("Truck Town server listening on port %d (max %d players)" % [_server_port, MAX_PLAYERS])


func _load_town() -> void:
	if _town != null:
		return
	_town = TOWN_SCENE.instantiate()
	# The node path must be identical on every peer for replication to resolve.
	_town.name = "TownScene"
	get_tree().root.add_child(_town)


func _unload_town() -> void:
	if _town != null:
		_town.queue_free()
		_town = null


func _on_peer_connected(_id: int) -> void:
	# Wait for the client's own `_register` call: only it knows which truck it picked.
	pass


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	players.erase(id)
	if _town != null:
		_town.despawn_vehicle(id)
	print("Peer %d left. Players: %d" % [id, players.size()])
	players_changed.emit()


func _on_connected_to_server() -> void:
	_register.rpc_id(1, local_player_name, local_vehicle)
	joined.emit()


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_peer = null
	_unload_town()
	disconnected.emit("Connection failed.")


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	_peer = null
	_unload_town()
	disconnected.emit("Server closed the connection.")


@rpc("any_peer", "reliable")
func _register(player_name: String, vehicle: int) -> void:
	if not multiplayer.is_server():
		return

	var id := multiplayer.get_remote_sender_id()
	if players.size() >= MAX_PLAYERS:
		push_warning("Rejecting peer %d: server is full." % id)
		return

	players[id] = {
		"name": player_name.substr(0, 16),
		"vehicle": clampi(vehicle, 0, VEHICLE_SCENES.size() - 1),
	}
	if _town != null:
		_town.spawn_vehicle(id, players[id]["vehicle"])
		# Bring the newcomer's sky in line with everyone else's.
		_town.apply_mood.rpc_id(id, _town.mood)

	print("Peer %d joined as %s (truck %d). Players: %d" % [
		id, players[id]["name"], players[id]["vehicle"], players.size(),
	])
	players_changed.emit()


func _parse_port(args: PackedStringArray) -> int:
	return _parse_int_arg(args, "--port=", DEFAULT_PORT)


func _parse_int_arg(args: PackedStringArray, prefix: String, fallback: int) -> int:
	for arg in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).to_int()
	return fallback


func _query_value(query: String, key: String) -> String:
	for pair in query.trim_prefix("?").split("&", false):
		var halves := pair.split("=", true, 1)
		if halves.size() == 2 and halves[0] == key:
			return halves[1].uri_decode()
	return ""
