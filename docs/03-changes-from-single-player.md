# Changes from the original demo

Roughly half of this work was not "add networking" but "stop code that assumed exactly one truck
from acting on all of them." The original demo used tree-wide group calls and global singleton-ish
assumptions that are perfectly correct with one vehicle and quietly wrong with four.

## New files

| File | Purpose |
|---|---|
| `net/net.gd` | Autoloaded as `Net`. Owns the peer, the player registry, the town's lifetime, and server-address resolution. |
| `town/touch_extra_controls.gd` | On-screen BOOST / HORN / CAM buttons, which had no touch equivalent. |

## `vehicles/vehicle.gd`

### Input gating

`_physics_process()` read `Input` directly. With several trucks in the scene, every truck on the
machine would respond to your keyboard at once. Now the first thing it does is branch:

```gdscript
func _physics_process(delta: float) -> void:
    if not is_multiplayer_authority():
        _follow_net_transform(delta)
        return
    ...
```

`_input()` is disabled outright for remote trucks via `set_process_input(false)` in
`_setup_remote()`.

### Headlights were the subtlest bug

Original:

```gdscript
for node: Light3D in get_tree().get_nodes_in_group(&"headlight"):
```

`headlight` is a **global group** declared in `project.godot`, and every vehicle scene puts its two
`SpotLight3D`s in it. With one truck that loop means "my headlights". With four trucks it means
"everyone's headlights" — pressing <kbd>L</kbd> would flip the entire table's lights. Replaced with:

```gdscript
func own_headlights() -> Array[Node]:
    var result: Array[Node] = []
    for child in get_children():
        if child is Light3D and child.is_in_group(&"headlight"):
            result.append(child)
    return result
```

Still respects the group (so it won't pick up unrelated lights added later) but scoped to this
truck's own children, which is where `HeadlightL` and `HeadlightR` live.

The Compatibility-renderer fix for headlight shadows (`shadow_reverse_cull_face = true`) also moved
here from `town_scene.gd`. In the original it ran in the town's `_ready()`, which worked because the
car already existed. Trucks now spawn *after* the town, so that loop would have found nothing.

### Replication surface

Two new exported properties and one RPC:

```gdscript
@export var net_transform := Transform3D.IDENTITY
@export var net_headlights := false

@rpc("any_peer", "call_local", "unreliable")
func honk() -> void:
    $HonkSound.play()
```

`call_local` means the presser hears their own horn through the same path as everyone else.
`unreliable` is right for a horn — a dropped honk is not worth a retransmit.

`toggle_headlights()` ends by publishing state, but only if it owns the truck:

```gdscript
if is_multiplayer_authority():
    net_headlights = headlights_active
```

Remote trucks reach `toggle_headlights()` from `_follow_net_transform()` when the replicated bool
disagrees with local state, so they animate their lights exactly like the owner's did.

### Engine sound for other players' trucks

A remote truck never runs the engine-pitch code, so it would be silent. Since we have its position
every frame, pitch is derived from observed motion instead:

```gdscript
var observed_speed := global_position.distance_to(_remote_previous_position) / maxf(delta, 0.0001)
```

The `maxf` guards against a zero `delta`. This is pure polish, but a table full of silent trucks
feels dead.

## `vehicles/follow_camera.gd`

Every vehicle scene contains its own `Camera3D`. In Godot the most recently added current camera
wins, so without intervention the last player to join would steal everyone's viewport:

```gdscript
if not is_multiplayer_authority():
    current = false
    set_process_input(false)
    set_physics_process(false)
    return
current = true
update_camera()
```

`AudioListener3D` has the same last-one-wins behaviour, handled by calling `make_current()`
explicitly on the local truck in `vehicle.gd`.

## `town/town_scene.gd`

### `setup()` became `bind_local_vehicle()`

The old contract took the car, the back-button callback, and the SDFGI flag in one call:

```gdscript
func setup(car: Node3D, back_callback: Callable, sdfgi: bool) -> void:
    var car_body: VehicleBody3D = car.get_child(0)
    car_body.turbometer = %Turbometer
    ...
    %InstancePos.add_child(car)
```

That can't survive: the town now exists before any truck, trucks are added by the spawner rather
than by the town, and the back button and SDFGI setting have nothing to do with vehicles. It split
into three:

- `bind_local_vehicle(body)` — HUD wiring, called by the truck that owns itself.
- `%Back.pressed.connect(Net.leave)` in `_ready()` — no callback plumbing needed.
- `%WorldEnvironment.environment.sdfgi_enabled = Net.local_sdfgi` in `_ready()`.

### Time of day became shared state

`mood` used to be picked in the menu and applied locally. Two laptops side by side showing different
times of day reads as a bug to anyone watching, so it is now server-owned:

```gdscript
func request_next_mood() -> void:
    if multiplayer.multiplayer_peer == null:
        apply_mood(wrapi(mood + 1, 0, Mood.size()))   # editor / no session
    else:
        _request_next_mood.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_next_mood() -> void:
    if not multiplayer.is_server():
        return
    apply_mood.rpc(wrapi(mood + 1, 0, Mood.size()))

@rpc("authority", "call_local", "reliable")
func apply_mood(new_mood: int) -> void:
    ...
```

Any client may *request*; only the server may *apply*. The `"authority"` annotation on `apply_mood`
enforces that at the framework level — a client calling it on others would be rejected.

The knock-on effect: the menu's mood panel is now hidden, since choosing a time of day before
joining is meaningless when the session already has one. Players cycle it in-game with <kbd>M</kbd>.

### Headlights following the mood

Original:

```gdscript
get_tree().call_group(&"car", &"toggle_headlights")
```

Same global-group problem as before — this would flip every player's headlights when anyone changed
the time of day. Now:

```gdscript
func _match_headlights_to_mood() -> void:
    if local_vehicle == null:
        return
    if turn_on_lights != local_vehicle.headlights_active:
        local_vehicle.toggle_headlights()
```

Each client adjusts only its own truck; the change then propagates through `net_headlights` like any
other headlight toggle. The null check matters because the mood is applied before any truck exists.

## `speedometer.gd`

One guard, but a load-bearing one:

```gdscript
if car_body == null:
    return
```

`_process` now runs in two situations that never existed before: on a client between loading the
town and its truck spawning, and forever on the dedicated server, which loads the whole town
including the HUD. Without this the server logs a `linear_velocity on a base object of type 'Nil'`
error every single frame.

## `car_select/car_select.gd`

Went from "instantiate the world" to "join a session". It no longer creates the town at all — `Net`
does — and it reacts to two signals instead of driving the flow itself:

```gdscript
Net.joined.connect(_on_joined)          # hide the menu
Net.disconnected.connect(_on_disconnected)  # show it again, with an error if there was one
```

It also hides itself entirely when `Net.is_dedicated_server` is true.

## `town/touch_extra_controls.gd`

The demo shipped three `TouchScreenButton` nodes: steer left, steer right, reverse, plus
auto-acceleration when `DisplayServer.is_touchscreen_available()`. That leaves a phone player unable
to boost, honk, or change camera — actions that only had keyboard and gamepad bindings. On the
target device, half the game was unreachable.

Rather than special-casing touch inside `vehicle.gd`, the buttons feed the same input actions the
keyboard uses. That requires two different mechanisms, and they are **not** interchangeable:

```gdscript
# Held (boost) — consumed by Input.is_action_pressed()
button.button_down.connect(func() -> void: Input.action_press(action))
button.button_up.connect(func() -> void: Input.action_release(action))

# Tapped (horn, camera) — consumed by _input()
func _send_action_event(action: StringName) -> void:
    for pressed in [true, false]:
        var event := InputEventAction.new()
        event.action = action
        event.pressed = pressed
        Input.parse_input_event(event)
```

`Input.action_press()` updates only the polled action state; it never generates an `InputEvent`, so
an `_input()` handler checking `event.is_action_pressed(&"honk")` would never fire. Conversely a
synthetic `InputEventAction` reaches `_input()`. Boost is polled, horn and camera are event-driven,
so each needs its own approach.

The whole control is only created when `DisplayServer.is_touchscreen_available()`, keeping laptops
clean.

## `project.godot`

One addition:

```ini
[autoload]

Net="*res://net/net.gd"
```

The `*` makes it a singleton available everywhere. Nothing else changed — notably
`physics_ticks_per_second=120`, `3d/physics_engine="Jolt Physics"` and
`common/physics_interpolation=true` were all left alone, because the vehicle tuning constants are
calibrated against them.
