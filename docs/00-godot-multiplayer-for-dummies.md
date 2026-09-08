# Godot multiplayer for dummies

Start here. This is the general guide — what Godot hands you, what you have to build yourself, and
which decisions actually matter. The other documents in this folder apply it all to Truck Town.

No prior networking knowledge assumed.

---

## 1. The single most useful thing to understand

**There is no such thing as a "server build" or a "server script" in Godot.**

A newcomer expects a project to have a client entry point and a server entry point, like two
programs. It doesn't work that way. You ship **one project**. It boots identically everywhere, and
then asks itself, at runtime, *"am I supposed to be the server?"*

That's it. That's the whole shape. In Truck Town, the question gets asked in `net/net.gd:64`:

```gdscript
var args := OS.get_cmdline_user_args()
if "--server" in args or OS.has_feature("dedicated_server"):
    is_dedicated_server = true
    _start_dedicated_server.call_deferred()
```

Godot has **no idea** what `--server` means. It's not an engine flag. We invented the name, and we
wrote the `if`. Godot's only contribution is `OS.get_cmdline_user_args()`, which hands you whatever
followed a bare `--` on the command line.

```bash
godot --headless --path . -- --server
#     └── engine args ──┘ ↑  └─ your args ─┘
#                        bare separator
```

Everything left of `--` is consumed by the engine. Everything right of it is invisible to the engine
and only reachable through `OS.get_cmdline_user_args()`. Forget the `--` and Godot swallows
`--server` as an unrecognised engine option, your `if` never fires, and the game silently starts as
a normal client. That's a very confusing ten minutes if you don't know it.

---

## 2. What's free, and what you write

This is the honest split, and it's the thing most tutorials blur.

### Free — works in any Godot project, zero setup

| Thing | What it does |
|---|---|
| `OS.get_cmdline_user_args()` | Reads your own flags, after `--` |
| `--headless` | Runs with no window or renderer |
| Autoloads | A singleton whose `_ready()` runs before the main scene |
| `dedicated_server` export option | A checkbox; adds a feature tag your code can detect |
| `MultiplayerAPI` (`multiplayer`) | Peer IDs, connection signals, who-is-server |
| `@rpc` | Call a function on other machines |
| `MultiplayerSpawner` | Replicate node creation and deletion |
| `MultiplayerSynchronizer` | Replicate property values continuously |
| `ENetMultiplayerPeer` / `WebSocketMultiplayerPeer` | The actual transports |

### Not free — you write all of this

| Thing | Why it's on you |
|---|---|
| Flag names and role dispatch | Godot defines no convention |
| Whether the server plays or just relays | A design decision |
| **Who owns what** (the authority model) | The big one. See §5 |
| What to replicate, and how often | Engine can't guess |
| Spawn points, spawn slots, respawns | Game logic |
| Smoothing between network updates | Not automatic |
| Handling joins and leaves gracefully | Game logic |
| Auditing single-player assumptions | See §8 — this is where the time goes |

**So "make any project and deploy it as a server" does not give you multiplayer.** It gives you a
headless process running your single-player game to an audience of nobody. Nothing networks itself.

The reusable part isn't code, it's the pattern in §1 — maybe 30 lines in any project. The expensive
part is §5 and §8, and both are entirely game-specific.

---

## 3. The five concepts you actually need

### Peer IDs

Every machine in a session gets an integer ID. **The server is always `1`.** Clients get large
random numbers (in our testing: `620806333`, `1616897746`).

```gdscript
multiplayer.get_unique_id()      # my own ID
multiplayer.is_server()          # am I peer 1?
multiplayer.get_remote_sender_id()  # who sent the RPC I'm currently handling
```

### The offline peer (why single-player still works)

If you never set a `multiplayer_peer`, Godot quietly installs an `OfflineMultiplayerPeer`. Verified
on Godot 4.7.1:

```
multiplayer_peer      = <OfflineMultiplayerPeer#...>
get_unique_id()       = 1
is_server()           = true
default authority     = 1
is_multiplayer_authority() = true
```

This is genuinely useful: **you are the server when you're alone.** So code guarded by
`if is_multiplayer_authority():` still runs normally when you hit F5 in the editor with no
networking at all. You don't need separate single-player paths.

### Authority

Every node has an authority — a peer ID that "owns" it. Default is `1` (the server).

```gdscript
node.set_multiplayer_authority(peer_id)   # recursive by default!
node.is_multiplayer_authority()           # do I own this?
```

Two traps, both of which have bitten this project:

- **It's recursive**, but only over children that *already exist*. Add a child afterwards and that
  child keeps the old authority. This causes completely silent bugs.
- **It returns `false` if the node isn't inside the tree yet** (with an
  `is_inside_tree()` error in the log). Safe in `_ready()`; not safe in `_init()`.

### Connection signals

```gdscript
multiplayer.peer_connected.connect(_on_peer_connected)        # server & clients
multiplayer.peer_disconnected.connect(_on_peer_disconnected)
multiplayer.connected_to_server.connect(_on_connected)        # clients only
multiplayer.connection_failed.connect(_on_failed)             # clients only
multiplayer.server_disconnected.connect(_on_server_gone)      # clients only
```

`peer_connected` fires when a transport connection opens — but the new peer hasn't told you anything
about itself yet. In Truck Town, `_on_peer_connected()` deliberately does nothing; the server waits
for the client to send its own `_register` RPC with its name and chosen truck.

### Node paths are addresses

Replication says *"the node at `/root/TownScene/Vehicles/Vehicle_123`"*. If that path resolves to
something different on another machine, replication breaks — usually silently.

This is why `net.gd` explicitly names the town:

```gdscript
_town.name = "TownScene"
get_tree().root.add_child(_town)
```

Left alone, Godot may append a suffix (`TownScene2`) on a name collision, and you'd get a bug with
no error message anywhere.

**Corollary: every peer must run the same build.** Mismatched scripts mean mismatched RPC and
property identification, which fails in baffling ways.

---

## 4. The three replication tools

Almost everything is one of these. Picking the wrong one is the second most common beginner mistake.

### `@rpc` — for events

"This happened." Discrete, one-off things: a horn, a chat message, a request.

```gdscript
@rpc("any_peer", "call_local", "unreliable")
func honk() -> void:
    $HonkSound.play()

honk.rpc()            # everyone
honk.rpc_id(1)        # just the server
```

The annotation arguments, all optional:

| Argument | Options | Meaning |
|---|---|---|
| mode | `"authority"` (default) / `"any_peer"` | Who is allowed to call it on others |
| local | `"call_remote"` (default) / `"call_local"` | Does the caller also run it? |
| transfer | `"unreliable"` (default) / `"reliable"` / `"unreliable_ordered"` | Retransmit on loss? |

Rules of thumb: `"reliable"` for anything that changes state permanently (registration, mode
changes); `"unreliable"` for cosmetic or frequent things (a horn — a dropped honk isn't worth
resending). Use `"call_local"` when the sender should experience the same effect.

**`"any_peer"` means "clients may call this on the server". Always validate inside:**

```gdscript
@rpc("any_peer", "reliable")
func _register(player_name: String, vehicle: int) -> void:
    if not multiplayer.is_server():
        return                                   # clients ignore it
    var id := multiplayer.get_remote_sender_id() # trust this, not a parameter
    var v := clampi(vehicle, 0, VEHICLE_SCENES.size() - 1)  # clamp everything
```

Without the `clampi`, a malformed message indexes out of an array and crashes your server.

### `MultiplayerSpawner` — for existence

"This node now exists / no longer exists." One per group of things that come and go.

Set `spawn_path` to the parent that spawned nodes go under. Then either register scenes with
`add_spawnable_scene()`, or — when you need custom data, as we do — provide a `spawn_function`:

```gdscript
_spawner.spawn_path = ^"../Vehicles"
_spawner.spawn_function = _spawn_vehicle
```

Only the spawner's authority (normally the server) may call `spawn(data)`. Your spawn function then
runs **on every peer with the same data**, and must be deterministic:

```gdscript
func _spawn_vehicle(data: Dictionary) -> Node:
    var car: Node3D = VEHICLE_SCENES[data["vehicle"] as int].instantiate()
    car.name = "Vehicle_%d" % data["peer"]
    _attach_synchronizer(car.get_child(0))   # BEFORE authority — see §3
    car.set_multiplayer_authority(data["peer"] as int)
    return car
```

Two free gifts worth knowing:

- **Late join works automatically.** A peer connecting later receives all already-spawned nodes.
- **Despawn is implicit.** `queue_free()` the node on the server; the spawner replicates the
  removal. There's no "despawn" message to write.

### `MultiplayerSynchronizer` — for continuous state

"This value is now X." Positions, health, animation states — things that change constantly.

```gdscript
var config := SceneReplicationConfig.new()
config.add_property(^".:net_transform")
config.property_set_replication_mode(^".:net_transform", SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

var sync := MultiplayerSynchronizer.new()
sync.replication_config = config
sync.replication_interval = 1.0 / 30.0    # 30 Hz
body.add_child(sync)
```

Property paths are relative to `root_path`, which defaults to `^".."` — the synchronizer's parent.
So `^".:net_transform"` means "the `net_transform` property on my parent".

Replication modes: `ALWAYS` (send every interval, for things always changing, uses
`replication_interval`), `ON_CHANGE` (only when it differs, uses `delta_interval`), `NEVER` (set
once at spawn).

**The synchronizer's authority is the source of truth.** Whoever owns it sends; everyone else
receives. That single fact is what makes client-authoritative movement possible.

**It does not interpolate.** See §6.

---

## 5. Authority: the decision that shapes everything

This is the one you must make consciously, before writing code. Everything else follows from it.

### Server-authoritative

The server simulates everything. Clients send input, receive state.

- Every screen agrees exactly
- Cheating is hard — the server can reject anything
- Your input doesn't take effect until a round trip finishes. In a driving game over WiFi, you
  **feel** this
- Your server now runs full physics for everyone, so it needs real CPU
- Making it feel good requires client-side prediction and rollback, which is genuinely hard

Use it for: competitive games, anything with stakes, anything where desync is unacceptable.

### Client-authoritative

Each client simulates the things it owns and publishes results.

- Controls are instant — input never leaves the device
- Server is nearly free (Truck Town's relay does *no physics at all* and runs in 512 MB)
- Each client resolves interactions against its own copy, so screens disagree slightly
- A modified client can teleport. No defence

Use it for: co-op, sandboxes, demos, anything friendly.

**Truck Town picks client-authoritative**, because at a club table nobody is competing and nobody is
cheating, "the controls feel immediate" beats "both screens agree to the centimetre", and a phone
only ever has to simulate one vehicle — which matters a lot in Safari.

### The hybrid most real games use

Authority per node, not per game. Players own their own characters; the server owns pickups, doors,
score, and anything contested. Godot supports this naturally, since authority is a per-node
property.

---

## 6. Interpolation: the thing that surprises everyone

Your physics runs at 60 or 120 Hz. Your network runs at 20–30 Hz. `MultiplayerSynchronizer` gives
you a new value roughly every 2–6 physics frames and **does not smooth between them**. Assign it
directly and remote objects visibly stutter.

The fix: replicate into a *separate variable*, then ease your real transform toward it.

```gdscript
@export var net_transform := Transform3D.IDENTITY   # replicated

func _physics_process(delta: float) -> void:
    if is_multiplayer_authority():
        net_transform = global_transform            # I own it: publish
        return
    # I don't own it: follow
    var weight := clampf(delta * REMOTE_FOLLOW_SPEED, 0.0, 1.0)
    global_position = global_position.lerp(net_transform.origin, weight)
    global_basis = global_basis.orthonormalized().slerp(net_transform.basis.orthonormalized(), weight)
```

Three details that cost real debugging time:

- **Do this in `_physics_process`, not `_process`,** for physics bodies. Writing a body's transform
  outside the physics step fights the engine. If your project has
  `physics_interpolation=true`, it already smooths physics state for rendering — so ease at the
  physics rate and let interpolation handle frames.
- **Orthonormalize before `slerp`.** Repeated interpolation accumulates scale and skew, and `slerp`
  on a skewed basis makes objects slowly shear.
- **Prefer `Transform3D` over position + Euler angles.** Euler is lossy and behaves strangely when
  things flip upside down — which vehicles do constantly.

### Remote physics bodies: freeze, but pick the mode

```gdscript
freeze_mode = FREEZE_MODE_KINEMATIC   # not the default!
freeze = true
```

`freeze` stops local physics fighting incoming transforms. But the default `FREEZE_MODE_STATIC`
makes the object an immovable wall. `FREEZE_MODE_KINEMATIC` tells the engine it's being moved
externally and to derive contact velocities from that motion — so another player ramming you
actually shoves you, in the direction they were going. This one line is the difference between
"players can crash into each other" and "players are ghosts".

---

## 7. A complete minimal example

Everything above, in the smallest thing that works. One autoload, one scene.

```gdscript
# net.gd — autoload as "Net"
extends Node

const PORT := 8910

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if "--server" in OS.get_cmdline_user_args():
		var peer := ENetMultiplayerPeer.new()
		peer.create_server(PORT, 8)
		multiplayer.multiplayer_peer = peer
		print("listening on ", PORT)
	else:
		var peer := ENetMultiplayerPeer.new()
		peer.create_client("127.0.0.1", PORT)
		multiplayer.multiplayer_peer = peer

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := preload("res://player.tscn").instantiate()
	player.name = "Player_%d" % id
	player.set_multiplayer_authority(id)
	get_node(^"/root/Main/Players").add_child(player)

func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := get_node_or_null(^"/root/Main/Players/Player_%d" % id)
	if player != null:
		player.queue_free()
```

Add a `MultiplayerSpawner` under `Main` with `spawn_path` pointing at `Players` and `player.tscn`
registered via `add_spawnable_scene()`, plus a `MultiplayerSynchronizer` inside `player.tscn`
replicating `position`. Then:

```bash
godot --path . -- --server     # terminal 1
godot --path .                 # terminal 2
godot --path .                 # terminal 3
```

That's a working multiplayer game. Everything else is refinement.

---

## 8. The mistakes everyone makes

Ranked by how much time they waste. The first four produce **no error message at all**.

### 1. Authority assigned before children exist

```gdscript
car.set_multiplayer_authority(peer_id)
_attach_synchronizer(body)          # WRONG — too late, missed the recursion
```

The synchronizer stays owned by the server, the owning client never sends, every remote object sits
frozen at spawn. No error. Attach children *first*.

### 2. Group calls that used to mean "me"

The killer when converting a single-player project. This was in the original Truck Town:

```gdscript
for node in get_tree().get_nodes_in_group(&"headlight"):
```

With one vehicle that means "my headlights". With four it means **everyone's** headlights, and
pressing a key flips the whole table's lights. Same for `call_group()`.

**Audit every `get_nodes_in_group` and `call_group` in single-player code.** Scope them to your own
children:

```gdscript
for child in get_children():
    if child is Light3D and child.is_in_group(&"headlight"):
```

### 3. "Only one of me" assumptions

Every scene with a `Camera3D` or `AudioListener3D` becomes a problem when instantiated four times —
Godot makes the most recent one current, so the last player to join silently steals everyone's
viewport. Explicitly set `current = false` on the ones you don't own.

Same class of bug: anything that assumed a singleton. Truck Town's speedometer assumed a car always
existed, and crashed every frame on the dedicated server (which loads the HUD but has no player)
until a null guard was added.

### 4. Node paths that differ between peers

Auto-generated names, conditionally-created nodes, different creation order. Name things explicitly.
If you create replication nodes in code, make *every* peer run the same function in the same order.

### 5. Spawn packets arriving before the spawner exists

If a client connects and the server immediately spawns, but the client hasn't built its
`MultiplayerSpawner` yet, those packets address a path that resolves to nothing. Truck Town avoids
this by loading the world **before** creating the peer:

```gdscript
_load_town()                     # spawner now exists
_peer.create_client(url)         # only now can anything arrive
```

Removing the race entirely beats synchronising a "ready" handshake.

### 6. Adding to the scene root during `_ready()`

`get_tree().root.add_child()` fails while the tree is still setting up children. Use
`call_deferred()`. But note: if another script reads a *flag* you set in the same `_ready()`, set the
flag synchronously and defer only the action.

### 7. Trusting RPC parameters

Use `get_remote_sender_id()` for identity, never a parameter. Clamp and truncate everything else.

### 8. Copying the wrong transport's API

`ENetMultiplayerPeer.create_server(port, max_clients)` takes a peer cap.
`WebSocketMultiplayerPeer.create_server(port, bind_address, tls_options)` **does not** — its third
argument is `TLSOptions`, and it has no cap at all. Porting between the two produces:

```
Invalid argument for "create_server()": argument 3 should be "TLSOptions" but is "int".
```

Enforce your own player limit in application code.

---

## 9. Picking a transport

| Transport | Use when | Notes |
|---|---|---|
| `ENetMultiplayerPeer` | Desktop only | UDP, lowest latency. The default choice. **Browsers cannot use it** |
| `WebSocketMultiplayerPeer` | Anything in a browser | TCP, slightly higher latency. One code path for desktop + web |
| `WebRTCMultiplayerPeer` | Peer-to-peer, no relay | Lowest latency but needs a signalling server; most complex |

Truck Town uses WebSocket, because phones join from Safari and browsers can't open raw UDP sockets.
It works fine for desktop too, so there's one code path everywhere.

**If you target browsers, read [04-web-export-and-hosting.md](04-web-export-and-hosting.md) before
building anything.** There's a hard HTTPS requirement that catches everyone.

---

## 10. How much work is this, really?

Effort scales almost entirely with **what you replicate**, not with player count.

| Game type | Difficulty | Why |
|---|---|---|
| Turn-based, cards, board games | Easy | Discrete events. A handful of RPCs and you're done |
| Lobbies, chat, scoreboards | Easy | Pure RPC |
| Non-physics movement (top-down, platformer) | Moderate | Sync position, add interpolation |
| **Physics vehicles / ragdolls** | **Hard** | Continuous state, mutual collisions, high physics rate vs low network rate |
| Competitive shooters | Very hard | Needs server authority plus prediction, rollback, lag compensation |

Physics is near the hard end, and that's where this project's effort went — the freeze-mode choice,
interpolation, orthonormalization, and the single-player audit in §8. Not the transport, which was
straightforward.

One genuinely free win: Truck Town already had `gl_compatibility` fallback branches, `.mobile`
setting overrides, and partial touch controls. A project written Forward+-only would have needed far
more work to reach phones.

---

## 11. Cheat sheet

```gdscript
# Who am I
multiplayer.get_unique_id()              # 1 if server or offline
multiplayer.is_server()
multiplayer.get_remote_sender_id()       # inside an RPC only

# Ownership
node.set_multiplayer_authority(id)       # recursive; children must exist first
node.is_multiplayer_authority()          # false if not inside_tree!

# Calling
my_func.rpc()                            # everyone
my_func.rpc_id(1)                        # server only
my_func.rpc_id(peer_id)                  # one peer

# Signals
multiplayer.peer_connected               # both sides
multiplayer.connected_to_server          # client only
multiplayer.server_disconnected          # client only

# Your own flags (after a bare `--` on the command line)
OS.get_cmdline_user_args()
OS.has_feature("dedicated_server")
```

Next: [01-architecture.md](01-architecture.md) for how these choices played out in Truck Town, and
[05-gotchas-and-verification.md](05-gotchas-and-verification.md) for how to prove replication
actually works rather than assuming it does.
