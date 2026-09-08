# Gotchas and how this was verified

## Errors hit during implementation

### `create_server()` argument 3 is `TLSOptions`, not a player cap

```
Parse Error: Invalid argument for "create_server()" function:
argument 3 should be "TLSOptions" but is "int".
```

`ENetMultiplayerPeer.create_server(port, max_clients)` takes a peer limit.
`WebSocketMultiplayerPeer.create_server(port, bind_address, tls_options)` does **not** — it has no
built-in peer cap at all. This is an easy transcription error when porting from the ENet-based demos
in `godot-demo-projects`, which is where the lobby pattern here came from.

Consequence: `MAX_PLAYERS` has to be enforced in application code, in `Net._register()`.

### `%UniqueName` only works on nodes that opted in

`%GameUI` and `%CarUI` failed because those nodes don't have `unique_name_in_owner = true` set in
`town_scene.tscn`. Only some do (`%Turbometer`, `%Speedometer`, `%Back`, `%InstancePos`,
`%WorldEnvironment`, `%Controls`, `%TurboAnimator`). For the rest, use `$GameUI`. Worth checking the
scene file rather than assuming, since the two syntaxes look interchangeable but aren't.

### `speedometer.gd` crashing every frame on the server

The dedicated server loads the entire town scene, HUD included, and no truck ever binds to it. So
`car_body` stays null and `_process` threw once per frame forever. Same thing happens on a client in
the window between loading the town and its truck spawning.

This is the general shape of the most common bug in this port: **code that assumed a truck always
exists.** The town used to be created *with* a car; now it exists before, after, and independently
of any car.

### Adding to the scene root during `_ready()`

`Net._start_dedicated_server()` has to be `call_deferred()`, because `get_tree().root.add_child()`
fails while the tree is still setting up children. But `is_dedicated_server` must be set
*synchronously* in the same `_ready()`, because `car_select.gd` reads it in its own `_ready()` to
hide itself — and autoload `_ready()` runs before main-scene `_ready()`. Splitting the flag from the
action is what makes both work.

## Traps that would have been silent

These would not have produced an error message, just wrong behaviour.

### Authority assignment order

`set_multiplayer_authority()` is recursive, but recursion only reaches children that already exist.
Attaching the `MultiplayerSynchronizer` *after* assigning authority leaves it owned by the server:
the owning client never sends updates, and every remote truck sits motionless at its spawn point
with no error anywhere. See `town_scene.gd:_spawn_vehicle()` — the comment on those two lines is
there for a reason.

### Global groups do not mean "mine"

`headlight` and `car` are global groups declared in `project.godot`. With one vehicle,
`get_tree().get_nodes_in_group(&"headlight")` means "my headlights". With four vehicles it means
"everyone's headlights", and pressing <kbd>L</kbd> flips the whole table's lights. The original
demo had two of these, in `vehicle.gd:toggle_headlights()` and `town_scene.gd:set_mood()`.

Any `get_nodes_in_group` or `call_group` in code inherited from a single-player demo deserves
suspicion.

### Last camera added wins

Every vehicle scene has its own `Camera3D` and `AudioListener3D`. Godot makes the most recent one
current, so without explicit handling the last player to join silently steals everyone else's
viewport. Fixed in `follow_camera.gd:_ready()` and by calling `make_current()` on the local truck's
listener.

### Writing physics transforms in `_process`

`_follow_net_transform()` runs in `_physics_process`. Putting it in `_process` seems appealing
(smoother, runs per rendered frame) but fights the physics engine on a frozen body and conflicts
with `common/physics_interpolation=true`, which already interpolates physics state for rendering.
Easing at the 120 Hz physics rate and letting interpolation handle render frames is both simpler
and smoother.

### `Basis.slerp` on a non-orthonormal basis

Repeated interpolation accumulates scale and skew. `slerp` on such a basis makes the truck slowly
shear. Both bases are `orthonormalized()` before slerping.

### `Input.action_press()` does not reach `_input()`

It updates the polled action state only; no `InputEvent` is generated. So a touch button built with
`action_press` works for boost (`Input.is_action_pressed`) but silently does nothing for horn or
camera cycling, which are handled in `_input()`. Those need a synthetic `InputEventAction` pushed
through `Input.parse_input_event()`. See `touch_extra_controls.gd`.

## How replication was actually proven

"No errors in the log" does not demonstrate that clients can see each other. Both clients could be
happily rendering their own truck alone and nothing would complain.

So a temporary probe was added to `town_scene.gd` — printing every two seconds, gated behind a
`--probe` flag — dumping each vehicle's authority, whether it is local, its actual position, its
replicated target, and its freeze state. Then a server and two staggered clients were run headless.

Client 1's view (it joined first):

```
[probe me=620806333] 1 vehicles | Vehicle_620806333 auth=620806333 mine=true  pos=(34.2, 8.9, 12.0) net=(34.2, 8.9, 12.0) frozen=false
[probe me=620806333] 2 vehicles | Vehicle_620806333 auth=620806333 mine=true  pos=(33.4, 8.9, 12.2) net=(33.4, 8.9, 12.2) frozen=false
                                || Vehicle_1616897746 auth=1616897746 mine=false pos=(35.4, 8.9, 16.8) net=(35.4, 8.9, 16.8) frozen=true
```

Client 2's view (joined second, then client 1 quit):

```
[probe me=1616897746] 2 vehicles | Vehicle_620806333 auth=620806333 mine=false pos=(32.5, 8.8, 12.4) net=(32.4, 8.8, 12.4) frozen=true
                                 || Vehicle_1616897746 auth=1616897746 mine=true frozen=false
[probe me=1616897746] 1 vehicles | Vehicle_1616897746 auth=1616897746 mine=true frozen=false
```

What each line proves:

| Observation | Proves |
|---|---|
| `2 vehicles` on both clients | Spawn replication works in both directions |
| `mine=true` exactly once per client | Authority is assigned correctly and consistently |
| `frozen=true` only on the other player's truck | The remote-setup branch runs on the right trucks |
| Client 2 sees `pos=(32.5…)` vs client 1's actual `(32.7…)` | Transforms are genuinely replicating, with the expected small lag |
| Client 2 saw client 1's truck immediately on joining | Late join works — `MultiplayerSpawner` syncs pre-existing nodes |
| Client 2 drops to `1 vehicles` after client 1 quits | Despawn replication works |
| `z≈12` vs `z≈16.8` | Spawn slots are distinct, so trucks don't land inside each other |

The probe was then reverted with `git checkout town/town_scene.gd`, since it was committed
beforehand. That is the useful pattern: commit the working state first, then add throwaway
diagnostics freely, knowing a single command removes them.

## Testing recipe

```bash
# Terminal 1 — relay
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --server

# Terminal 2 — two headless clients, staggered, to test late join
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 900 -- --client --truck=0
sleep 4
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 600 -- --client --truck=1
```

The server prints joins and leaves with peer ids and player counts, which is usually enough to
diagnose a connection problem without any client output at all.

For browser testing, build and serve, then open **two tabs** at `http://localhost:8000`. Do not use
a LAN IP — see [04-web-export-and-hosting.md](04-web-export-and-hosting.md).

`ObjectDB instances were leaked at exit` and `resources still in use at exit` warnings appear when
`--quit-after` terminates a client mid-frame with an open peer and active tweens. They are an
artefact of the abrupt shutdown, not a real leak.

## Still unverified

The one thing these notes cannot claim: **nobody has confirmed the game is playable on a real
iPhone.** The web build exports and the multiplayer logic is proven, but Godot 4 web builds are
heavy and iOS Safari has tight memory limits. That test needs real HTTPS, so it requires either a
deployment or a tunnel.

If it turns out too slow, the highest-impact lever is `physics_ticks_per_second=120` in
`project.godot`, which is very heavy for a phone — 60 would halve that work.
`scaling_3d/scale.mobile` is already `0.67` and can go lower. Enabling thread support is also worth
trying, since HTTPS is required either way.
