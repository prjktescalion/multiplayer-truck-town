# Architecture

## Why client-authoritative

Physics-based vehicle multiplayer has two viable shapes.

**Server-authoritative** — the host simulates every truck, clients send input and receive state.
Collisions are identical on every screen. The cost is that the client's own steering doesn't take
effect until a round trip completes, which over WiFi to a phone means input lag you can feel in a
driving game. It also means the server must run the full physics simulation for everyone, so a free
cloud machine won't do.

**Client-authoritative** — each client simulates its own truck and publishes the result. Steering is
instant because it never leaves the device. The server does no physics. The cost is that when two
trucks collide, each client resolves that collision against its own copy of the other truck, so the
two screens disagree slightly about exactly what happened.

This project picks client-authoritative. At a demo table nobody is competing, nobody is cheating,
and "the controls feel immediate" matters far more than "both screens agree to the centimetre."
It also means a phone only ever simulates one vehicle, which matters a lot for a 3D scene running
in Safari.

A useful side effect: `is_multiplayer_authority()` returns `true` when no multiplayer peer is set,
so every code path guarded by it also works when you run a scene directly from the editor with no
networking at all.

## Node topology

Identical on every peer — server, laptop, and phone:

```
/root
├── Net                        (autoload, net/net.gd)
├── CarSelect                  (main scene: join screen; hidden on the server)
└── TownScene                  (added at runtime by Net; name is load-bearing)
    ├── WorldEnvironment, DirectionalLight3D, Lamps, TownModel, ...
    ├── GameUI, CarUI          (HUD; hidden on the server)
    ├── Vehicles               (created in code — spawn target)
    ├── VehicleSpawner         (created in code — MultiplayerSpawner)
    └── TouchExtraControls     (only when a touchscreen is present)
```

Under `Vehicles`, one subtree per player:

```
Vehicles
└── Vehicle_641973461          (peer id in the name; authority = that peer, recursive)
    └── Body                   (VehicleBody3D, vehicle.gd)
        ├── Sync               (MultiplayerSynchronizer, created in code)
        ├── Wheel1..4, CameraBase/Camera3D, HeadlightL/R, EngineSound, ...
```

### Why the paths matter

Godot's replication addresses nodes **by path**. A spawn or sync packet says "the node at
`/root/TownScene/Vehicles/Vehicle_123`", so that path must resolve to the same thing on every peer.
Two consequences:

- `Net._load_town()` explicitly sets `_town.name = "TownScene"` before adding it to the root. Left
  to Godot, an added node can get a suffixed name (`TownScene2`) if anything collides, and
  replication would break in a way that is very hard to read.
- `Vehicles` and `VehicleSpawner` are created in `_build_multiplayer_nodes()` in code rather than
  placed in the `.tscn`. That is fine *because every peer runs the same function in the same order*,
  so the paths agree. It also avoids hand-editing `SceneReplicationConfig` sub-resources into three
  vehicle scenes.

## What actually goes over the wire

Two replicated properties per truck, both declared on `vehicle.gd`:

```gdscript
@export var net_transform := Transform3D.IDENTITY
@export var net_headlights := false
```

`town_scene.gd:_attach_synchronizer()` builds the config for them in code:

```gdscript
var config := SceneReplicationConfig.new()
for property: NodePath in [^".:net_transform", ^".:net_headlights"]:
    config.add_property(property)
    config.property_set_replication_mode(property, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

var synchronizer := MultiplayerSynchronizer.new()
synchronizer.replication_config = config
synchronizer.replication_interval = 1.0 / 30.0
body.add_child(synchronizer)
```

`^".:net_transform"` reads as "the property `net_transform` on the synchronizer's root node".
`MultiplayerSynchronizer.root_path` defaults to `^".."`, and the synchronizer is added as a child of
`Body`, so the root is `Body`.

A full `Transform3D` (12 floats) is sent rather than position plus Euler angles. It is heavier, but
Euler angles are lossy and get strange when a truck flips onto its roof — which happens constantly
in this game. At 30 Hz and 8 players that is a few KB/s, which is irrelevant.

Everything else is an RPC: the horn (`vehicle.gd:honk`), the shared time of day
(`town_scene.gd:apply_mood`), and registration (`net.gd:_register`).

## Authority, and the one ordering rule

The spawn function runs on **every** peer with identical data, so every peer independently arrives
at the same authority assignment:

```gdscript
func _spawn_vehicle(data: Dictionary) -> Node:
    var peer_id: int = data["peer"]
    var car: Node3D = Net.VEHICLE_SCENES[data["vehicle"] as int].instantiate()
    car.name = "Vehicle_%d" % peer_id
    car.transform = _spawn_transform(data["slot"] as int)

    # Attach the synchronizer before assigning authority so it inherits it too.
    _attach_synchronizer(car.get_child(0))
    car.set_multiplayer_authority(peer_id)
    return car
```

`set_multiplayer_authority()` is **recursive by default**, which is the whole trick: one call on the
vehicle root gives `Body`, the `Sync` node, and the camera the same owner. But recursion only
reaches children that already exist, so the synchronizer must be attached first. Reverse those two
lines and the synchronizer silently stays owned by the server, the owning client never sends
updates, and every remote truck sits frozen at its spawn point.

Note that `MultiplayerSpawner.spawn()` may only be called by the spawner's own authority (the
server), while each `Sync` node is owned by a *client*. That mix is exactly what
client-authoritative replication looks like in Godot: the server decides who exists, and each
client decides where its own truck is.

## Interpolation

The physics tick is 120 Hz (`physics_ticks_per_second=120`) and the network rate is 30 Hz, so a
remote truck receives a new transform roughly every 4 physics frames. Snapping to it looks visibly
steppy, so `vehicle.gd` eases instead:

```gdscript
func _follow_net_transform(delta: float) -> void:
    var weight := clampf(delta * REMOTE_FOLLOW_SPEED, 0.0, 1.0)
    var current := global_transform
    global_position = current.origin.lerp(net_transform.origin, weight)
    global_basis = current.basis.orthonormalized().slerp(net_transform.basis.orthonormalized(), weight)
```

Two details worth keeping:

- This runs in **`_physics_process`, not `_process`.** The body is a physics object; writing its
  transform outside the physics step fights the engine, and the project has
  `common/physics_interpolation=true`, which already smooths physics state for rendering. Easing at
  120 Hz and letting interpolation handle the render frames gives smooth motion for free.
- The bases are **orthonormalized** before `slerp`. A `Basis` that has picked up any scale or skew
  from repeated interpolation will make `slerp` misbehave, and the truck slowly shears.

`REMOTE_FOLLOW_SPEED = 18.0` is a tuning knob: higher tracks the true position more tightly but
reintroduces stepping, lower is smoother but laggier.

## Why remote trucks are frozen kinematic, not static

```gdscript
freeze_mode = FREEZE_MODE_KINEMATIC
freeze = true
```

`freeze = true` stops the local physics engine from simulating a truck it doesn't own — otherwise
local physics and incoming transforms would fight each other.

The `freeze_mode` choice is what makes bumping fun. The default `FREEZE_MODE_STATIC` would make the
truck an immovable wall. `FREEZE_MODE_KINEMATIC` tells the engine the body is being moved
externally and to compute contact velocities from that motion, so another player's truck ramming
you actually shoves you, in the direction they were travelling. Since each client applies this to
every truck but its own, both players feel the hit — each computed locally, which is why the two
screens disagree slightly.
