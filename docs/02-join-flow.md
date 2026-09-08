# Join, spawn, and leave — the full trace

## Server startup

`net/net.gd` is autoloaded as `Net`, so its `_ready()` runs before the main scene.

```gdscript
var args := OS.get_cmdline_user_args()
if "--server" in args or OS.has_feature("dedicated_server"):
    is_dedicated_server = true
    _server_port = _parse_port(args)
    _start_dedicated_server.call_deferred()
```

`OS.get_cmdline_user_args()` returns only the arguments after a bare `--`, which keeps our flags
from colliding with Godot's own (`--headless`, `--path`). The `dedicated_server` check is the
feature tag Godot adds to a dedicated-server export, so the Fly.io image needs no arguments at all
— though the `Dockerfile` passes them anyway for clarity.

Two things about the split between the flag and the deferred call:

- `is_dedicated_server` is set **synchronously**, because `car_select.gd:_ready()` reads it to hide
  itself. Autoload `_ready()` runs before main-scene `_ready()`, so the flag is there in time.
- `_start_dedicated_server()` is **deferred**, because it calls `get_tree().root.add_child()`.
  Adding to the root while the tree is still setting up its children triggers a "parent node is
  busy" error.

Then:

```gdscript
func _start_dedicated_server() -> void:
    _load_town()
    _peer = WebSocketMultiplayerPeer.new()
    var err := _peer.create_server(_server_port, "*")
    multiplayer.multiplayer_peer = _peer
```

The server loads the town too. It never renders, but it needs the node paths and the
`MultiplayerSpawner` to exist so it can spawn into them.

## A client joins

### 1. Pick a truck

`car_select.gd:_join(vehicle_index)` runs on a button press. It stores the local-only quality
setting, shows the loading panel, then resolves where to connect:

```gdscript
Net.local_sdfgi = button_sdfgi.button_pressed
loading_screen.visible = true
status_label.text = "Connecting..."
await RenderingServer.frame_post_draw
Net.join(Net.default_server_url(), "Player", vehicle_index)
```

The `await` is inherited from the original demo: instantiating the town stalls for a moment, so it
waits for the loading panel to actually reach the screen first.

### 2. Resolve the server address

`Net.default_server_url()` tries three sources in order, which is what lets one build work in
every deployment:

```gdscript
var override := _query_value(query, "server")   # ?server=wss://host  — highest priority
if protocol == "https:":
    return DEFAULT_PUBLIC_SERVER_URL            # page came from static hosting
return "ws://%s:%d" % [hostname, DEFAULT_PORT]  # page came from the game host itself
```

The middle case exists because an HTTPS page **cannot** open an insecure `ws://` connection — mixed
content is blocked — and a page served from Vercel has no way to guess where the relay lives. The
third case is the elegant one: when the page is served by the same machine running the relay, the
client reads `window.location.hostname` and connects back to whoever served it, so nobody types an
IP address. On desktop, `JavaScriptBridge` doesn't exist, so the whole block is skipped in favour of
`--url=` or localhost.

### 3. Load the town, *then* connect

```gdscript
func join(url: String, player_name: String, vehicle: int) -> void:
    ...
    _load_town()          # <- before the peer exists
    _peer = WebSocketMultiplayerPeer.new()
    _peer.create_client(url)
    multiplayer.multiplayer_peer = _peer
```

This ordering is deliberate and easy to get wrong. The server starts replicating trucks the moment
registration completes. If the client's `MultiplayerSpawner` doesn't exist yet, those spawn packets
arrive addressed to a node path that resolves to nothing. Loading the town first removes the race
entirely, rather than trying to synchronise "I am ready" separately.

### 4. Register

Once the transport is up, Godot fires `connected_to_server` on the client:

```gdscript
func _on_connected_to_server() -> void:
    _register.rpc_id(1, local_player_name, local_vehicle)
    joined.emit()
```

Only the client knows which truck the player picked, so the server can't act on
`peer_connected` alone — `Net._on_peer_connected()` deliberately does nothing and waits for this
call. `rpc_id(1, ...)` targets the server specifically (peer 1 is always the server).

`joined` is what makes `car_select.gd` hide itself, so the menu stays up with its loading panel for
the entire connection attempt and can come back if it fails.

### 5. Server accepts and spawns

```gdscript
@rpc("any_peer", "reliable")
func _register(player_name: String, vehicle: int) -> void:
    if not multiplayer.is_server():
        return
    var id := multiplayer.get_remote_sender_id()
    if players.size() >= MAX_PLAYERS:
        return
    players[id] = {
        "name": player_name.substr(0, 16),
        "vehicle": clampi(vehicle, 0, VEHICLE_SCENES.size() - 1),
    }
    _town.spawn_vehicle(id, players[id]["vehicle"])
    _town.apply_mood.rpc_id(id, _town.mood)
```

The guard rail pattern here is worth copying for any `any_peer` RPC: check `is_server()` first
(clients must ignore it), get the sender from `get_remote_sender_id()` rather than trusting a
parameter, and clamp/truncate every incoming value. `clampi` on the vehicle index stops a malformed
message indexing out of `VEHICLE_SCENES`.

`WebSocketMultiplayerPeer` has no built-in peer cap, so `MAX_PLAYERS` is enforced here.

The `apply_mood.rpc_id(id, ...)` line pushes the current time of day to just the newcomer. Without
it, a player joining an evening session would arrive in daylight.

### 6. Spawn slots

```gdscript
func spawn_vehicle(peer_id: int, vehicle_index: int) -> void:
    var slot := _next_free_slot()
    _slots[peer_id] = slot
    _spawner.spawn({"peer": peer_id, "vehicle": vehicle_index, "slot": slot})
```

The original demo had a single `%InstancePos` marker, which would drop every truck inside the last
one. Rather than adding markers to the scene by hand — and guessing at world coordinates that might
land on a building — slots are derived from the existing marker:

```gdscript
func _spawn_transform(slot: int) -> Transform3D:
    var across := (float(slot % 2) * 2.0 - 1.0) * SPAWN_SPACING_ACROSS_ROAD
    var along := float(slot / 2) * SPAWN_SPACING_ALONG_ROAD
    return (%InstancePos as Marker3D).transform.translated_local(Vector3(across, 0.0, along))
```

`translated_local` applies the offset in the marker's own frame, so the trucks queue up two abreast
along the road regardless of how the marker is rotated (it carries a 90° Y rotation). Slots are
recycled by `_next_free_slot()` when players leave, so a busy table doesn't push trucks off the map.

### 7. The truck wires itself up

The spawner adds the vehicle, so `vehicle.gd:_ready()` runs on every peer. Each peer takes a
different branch:

```gdscript
if not is_multiplayer_authority():
    _setup_remote()       # freeze kinematic, stop reading input
    return

var town := get_tree().get_first_node_in_group(&"town")
if town != null:
    town.bind_local_vehicle(self)
assert(turbometer)
assert(turbo_animator)
$AudioListener3D.make_current()
```

This inverts the original demo's flow. It used to be `town_scene.setup(car, ...)` pushing HUD
references into the one car that existed. Now the truck pulls them, and only if it belongs to this
player — because there is one speedometer and one turbometer on screen and they describe the local
truck. Remote trucks legitimately leave `turbometer` null, which is why the `assert()` calls sit
inside the authority branch rather than at the top of `_ready()`.

## Leaving

```gdscript
func _on_peer_disconnected(id: int) -> void:
    if not multiplayer.is_server():
        return
    players.erase(id)
    _town.despawn_vehicle(id)
```

`despawn_vehicle()` just calls `queue_free()` on the server's copy. `MultiplayerSpawner` notices a
node it spawned has gone and replicates the removal, so no explicit "despawn" message is needed.

A player pressing **Back** calls `Net.leave()`, which closes the peer, clears state, frees the town,
and emits `disconnected("")`. The empty string is the signal's convention for "you asked to leave"
as opposed to a real failure, which `car_select.gd:_on_disconnected()` uses to decide whether to
show an error:

```gdscript
if reason.is_empty():
    loading_screen.visible = false
else:
    loading_screen.visible = true
    status_label.text = reason
```
