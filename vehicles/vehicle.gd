extends VehicleBody3D

const STEER_SPEED = 1.5
const STEER_LIMIT = 0.4
const BRAKE_STRENGTH = 2.0

## How fast a remote truck catches up to its replicated transform. Higher is more accurate but
## less smooth; this runs at the physics tick rate, not the ~30 Hz network rate.
const REMOTE_FOLLOW_SPEED = 18.0

@export var engine_force_value := 40.0

## Replicated by the MultiplayerSynchronizer that `town_scene.gd` attaches at spawn time.
## The authoritative peer writes these; everyone else reads them.
@export var net_transform := Transform3D.IDENTITY
@export var net_headlights := false

var turbometer: Range
var turbo_animator: AnimationPlayer

var previous_speed := linear_velocity.length()
var turbo_active := false
var headlights_active := false
var _steer_target := 0.0
var is_compatibility := RenderingServer.get_current_rendering_method() == "gl_compatibility"

## Only used on remote trucks, to drive engine pitch from observed motion.
var _remote_previous_position := Vector3.ZERO

@onready var desired_engine_pitch: float = $EngineSound.pitch_scale


func _ready() -> void:
	if is_compatibility:
		for headlight in own_headlights():
			# Enable Reverse Cull Face to fix shadow biasing in Compatibility.
			headlight.shadow_reverse_cull_face = true

	if not is_multiplayer_authority():
		_setup_remote()
		return

	# Attach ourselves to the town's HUD. Remote trucks deliberately skip this: there is only one
	# speedometer and turbometer on screen and they belong to the local player.
	var town := get_tree().get_first_node_in_group(&"town")
	if town != null:
		town.bind_local_vehicle(self)

	assert(turbometer)
	assert(turbo_animator)

	$AudioListener3D.make_current()
	net_transform = global_transform


## A remote truck is not simulated here. Freezing it in kinematic mode means the physics engine
## still lets it shove the local player's truck around on contact, instead of it being a ghost.
func _setup_remote() -> void:
	freeze_mode = FREEZE_MODE_KINEMATIC
	freeze = true
	set_process_input(false)
	_remote_previous_position = global_position
	net_transform = global_transform


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		_follow_net_transform(delta)
		return

	_steer_target = Input.get_axis(&"turn_right", &"turn_left")
	_steer_target *= STEER_LIMIT

	# Engine sound simulation (not realistic, as this car script has no notion of gear or engine RPM).
	desired_engine_pitch = 0.05 + linear_velocity.length() / (engine_force_value * 0.5)
	# Change pitch smoothly to avoid abrupt change on collision.
	$EngineSound.pitch_scale = lerpf($EngineSound.pitch_scale, desired_engine_pitch, 0.2)

	if absf(linear_velocity.length() - previous_speed) > 1.0:
		# Sudden velocity change, likely due to a collision. Play an impact sound to give audible feedback,
		# and vibrate for haptic feedback.
		$ImpactSound.play()
		Input.vibrate_handheld(100)
		for joypad in Input.get_connected_joypads():
			Input.start_joy_vibration(joypad, 0.0, 0.5, 0.1)

	var turbo_pressed := Input.is_action_pressed(&"boost")
	var new_turbo_active := turbo_pressed and turbometer.value > 0
	if new_turbo_active != turbo_active:
		turbo_animator.play(&"TURBO" if new_turbo_active else &"Idle")

	turbo_active = new_turbo_active
	if turbo_active:
		turbometer.value -= delta * 3.0
	elif not turbo_pressed:
		turbometer.value += delta

	if turbo_active:
		constant_force = global_transform.basis.z * 400.0
	else:
		constant_force = Vector3()

	# Automatically accelerate when using touch controls (reversing overrides acceleration).
	if DisplayServer.is_touchscreen_available() or Input.is_action_pressed(&"accelerate"):
		# Increase engine force at low speeds to make the initial acceleration faster.
		var speed := linear_velocity.length()
		if speed < 5.0 and not is_zero_approx(speed):
			engine_force = clampf(engine_force_value * 5.0 / speed, 0.0, 100.0)
		else:
			engine_force = engine_force_value

		if not DisplayServer.is_touchscreen_available():
			# Apply analog throttle factor for more subtle acceleration if not fully holding down the trigger.
			engine_force *= Input.get_action_strength(&"accelerate")
	else:
		engine_force = 0.0

	if Input.is_action_pressed(&"reverse"):
		# Increase engine force at low speeds to make the initial reversing faster.
		var speed := linear_velocity.length()
		if speed < 5.0 and not is_zero_approx(speed):
			engine_force = -clampf(engine_force_value * 5.0 / speed, 0.0, 100.0)
		else:
			engine_force = -engine_force_value

		# Apply analog brake factor for more subtle braking if not fully holding down the trigger.
		engine_force *= Input.get_action_strength(&"reverse")

	steering = move_toward(steering, _steer_target, STEER_SPEED * delta)

	previous_speed = linear_velocity.length()

	# Publish our state for the other players.
	net_transform = global_transform


## Eases a remote truck toward the last transform we received. Done in `_physics_process` rather
## than `_process` so the frozen body stays consistent with the physics engine, and so the
## project-wide physics interpolation smooths the result for rendering.
func _follow_net_transform(delta: float) -> void:
	var weight := clampf(delta * REMOTE_FOLLOW_SPEED, 0.0, 1.0)
	var current := global_transform
	global_position = current.origin.lerp(net_transform.origin, weight)
	global_basis = current.basis.orthonormalized().slerp(net_transform.basis.orthonormalized(), weight)

	# Drive engine pitch from observed motion, since we never simulate this truck.
	var observed_speed := global_position.distance_to(_remote_previous_position) / maxf(delta, 0.0001)
	_remote_previous_position = global_position
	$EngineSound.pitch_scale = lerpf(
			$EngineSound.pitch_scale,
			0.05 + observed_speed / (engine_force_value * 0.5),
			0.2
		)

	if net_headlights != headlights_active:
		toggle_headlights()


func _input(p_input_event: InputEvent) -> void:
	if p_input_event.is_action_pressed(&"toggle_headlights"):
		toggle_headlights()

	if p_input_event.is_action_pressed(&"honk"):
		honk.rpc()


## The horn is worth hearing from other players' trucks, so it goes over the wire.
@rpc("any_peer", "call_local", "unreliable")
func honk() -> void:
	$HonkSound.play()


## Our own headlights, rather than every headlight in the level. `get_nodes_in_group()` would also
## return the other players' trucks now that more than one truck exists at a time.
func own_headlights() -> Array[Node]:
	var result: Array[Node] = []
	for child in get_children():
		if child is Light3D and child.is_in_group(&"headlight"):
			result.append(child)
	return result


func toggle_headlights() -> void:
	for node: Light3D in own_headlights():
		# Consider headlights as being inactive up to this point if their energy was previously 0.
		headlights_active = is_zero_approx(node.light_energy)
		var t := get_tree().create_tween()

		if headlights_active:
			node.visible = true

		var target_energy := 2.0 if headlights_active else 0.0
		if is_compatibility:
			# Decrease light brightness to compensate for sRGB blending in Compatibility
			# (since headlights cast shadows).
			target_energy *= 0.5
		t.tween_property(
				node,
				^"light_energy",
				target_energy,
				0.2
			).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

		# Hide light node at the end to avoid performance impact when headlights are off
		# (Godot still renders lights with `light_energy == 0.0` otherwise).
		if not headlights_active:
			t.finished.connect(func() -> void:
				node.visible = false
			)

	if is_multiplayer_authority():
		net_headlights = headlights_active
