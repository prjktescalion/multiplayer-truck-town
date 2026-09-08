extends Node3D

## Spacing between spawn slots, in metres. Trucks queue up along the road behind `%InstancePos`
## rather than sharing one spawn point, which would drop them inside each other.
const SPAWN_SPACING_ALONG_ROAD = 10.0
const SPAWN_SPACING_ACROSS_ROAD = 2.5

const TOUCH_EXTRA_CONTROLS = preload("res://town/touch_extra_controls.gd")

enum Mood {
	SUNRISE,
	DAY,
	SUNSET,
	NIGHT,
}

@onready var controls_sheet: Control = %Controls

var mood := Mood.DAY: set = set_mood

var turn_on_lights: bool = false
var ambient_sound: Array = [
	preload("res://town/sound/mood_sunrise.ogg"),
	preload("res://town/sound/mood_day.ogg"),
	preload("res://town/sound/mood_sunset.ogg"),
	preload("res://town/sound/mood_night.ogg"),
]

# Only assigned when using the Compatibility rendering method.
# This is used to darken the sunlight to compensate for sRGB blending (without affecting sky rendering).
var compatibility_light: DirectionalLight3D

## The truck this player drives. Null on the dedicated server, and until our truck is spawned.
var local_vehicle: VehicleBody3D = null

var _vehicles: Node3D
var _spawner: MultiplayerSpawner

## Peer id -> spawn slot, so a rejoining player doesn't land on top of someone else.
var _slots: Dictionary[int, int] = {}


func _ready() -> void:
	# `vehicle.gd` finds us through this group when it needs to attach itself to the HUD.
	add_to_group(&"town")
	_build_multiplayer_nodes()

	%Back.pressed.connect(Net.leave)
	%WorldEnvironment.environment.sdfgi_enabled = Net.local_sdfgi

	# Ensure headlights are toggled on automatically according to the initial mood.
	# The scene tree is not available at first, so we have to set the mood a second time
	# in deferred mode, which will call the setter again.
	set_deferred(&"mood", mood)
	controls_sheet.hide()

	if Net.is_dedicated_server:
		# Nothing is rendered and nobody is driving; the server only relays truck state.
		$GameUI.hide()
		$CarUI.hide()
		return

	_build_touch_controls()

	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		# Use PCF13 shadow filtering to improve quality (Medium maps to PCF5 instead).
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)

		# Darken the light's energy to compensate for sRGB blending (without affecting sky rendering).
		$DirectionalLight3D.sky_mode = DirectionalLight3D.SKY_MODE_SKY_ONLY
		compatibility_light = $DirectionalLight3D.duplicate()
		compatibility_light.light_energy = $DirectionalLight3D.light_energy * 0.2
		compatibility_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		add_child(compatibility_light)


## Creates the replication plumbing. Every peer runs this identically so that the spawner and its
## target resolve to the same node paths on all of them.
func _build_multiplayer_nodes() -> void:
	_vehicles = Node3D.new()
	_vehicles.name = "Vehicles"
	add_child(_vehicles)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = "VehicleSpawner"
	add_child(_spawner)
	_spawner.spawn_path = ^"../Vehicles"
	_spawner.spawn_function = _spawn_vehicle


## Server-side. Called once a client has told us which truck it picked.
func spawn_vehicle(peer_id: int, vehicle_index: int) -> void:
	var slot := _next_free_slot()
	_slots[peer_id] = slot
	_spawner.spawn({"peer": peer_id, "vehicle": vehicle_index, "slot": slot})


## Server-side. Freeing the node on the server replicates the removal to everyone else.
func despawn_vehicle(peer_id: int) -> void:
	var node := _vehicles.get_node_or_null(NodePath("Vehicle_%d" % peer_id))
	if node != null:
		node.queue_free()
	_slots.erase(peer_id)


## Runs on every peer, with identical data, so authority ends up the same everywhere.
func _spawn_vehicle(data: Dictionary) -> Node:
	var peer_id: int = data["peer"]
	var car: Node3D = Net.VEHICLE_SCENES[data["vehicle"] as int].instantiate()
	car.name = "Vehicle_%d" % peer_id
	car.transform = _spawn_transform(data["slot"] as int)

	# Attach the synchronizer before assigning authority so it inherits it too.
	_attach_synchronizer(car.get_child(0))
	car.set_multiplayer_authority(peer_id)
	return car


func _attach_synchronizer(body: Node) -> void:
	var config := SceneReplicationConfig.new()
	for property: NodePath in [^".:net_transform", ^".:net_headlights"]:
		config.add_property(property)
		config.property_set_replication_mode(property, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

	var synchronizer := MultiplayerSynchronizer.new()
	synchronizer.name = "Sync"
	synchronizer.replication_config = config
	# 30 Hz is plenty: `vehicle.gd` eases between updates at the 120 Hz physics rate.
	synchronizer.replication_interval = 1.0 / 30.0
	body.add_child(synchronizer)


func _spawn_transform(slot: int) -> Transform3D:
	var across := (float(slot % 2) * 2.0 - 1.0) * SPAWN_SPACING_ACROSS_ROAD
	var along := float(slot / 2) * SPAWN_SPACING_ALONG_ROAD
	return (%InstancePos as Marker3D).transform.translated_local(Vector3(across, 0.0, along))


func _next_free_slot() -> int:
	var used := _slots.values()
	for slot in Net.MAX_PLAYERS:
		if slot not in used:
			return slot
	return 0


## Called by `vehicle.gd` from its `_ready()` when it is the truck we control.
func bind_local_vehicle(body: VehicleBody3D) -> void:
	local_vehicle = body
	body.turbometer = %Turbometer
	body.turbo_animator = %TurboAnimator
	%Speedometer.car_body = body
	# The mood may have been decided before we spawned, so apply its headlight state now.
	_match_headlights_to_mood()


## Adds on-screen buttons for boost, horn and camera, which have no touch equivalent otherwise.
func _build_touch_controls() -> void:
	if not DisplayServer.is_touchscreen_available():
		return

	var controls: VBoxContainer = TOUCH_EXTRA_CONTROLS.new()
	controls.name = "TouchExtraControls"
	add_child(controls)


func _input(input_event: InputEvent) -> void:
	if input_event.is_action_pressed(&"cycle_mood"):
		request_next_mood()
	elif input_event.is_action_pressed(&"toggle_controls"):
		controls_sheet.visible = not controls_sheet.visible


## Time of day is shared, so that two screens side by side never disagree about it.
func request_next_mood() -> void:
	if multiplayer.multiplayer_peer == null:
		# Not in a session (e.g. running a scene straight from the editor).
		apply_mood(wrapi(mood + 1, 0, Mood.size()))
	else:
		_request_next_mood.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_next_mood() -> void:
	if not multiplayer.is_server():
		return
	apply_mood.rpc(wrapi(mood + 1, 0, Mood.size()))


@rpc("authority", "call_local", "reliable")
func apply_mood(new_mood: int) -> void:
	mood = new_mood as Mood
	$AmbientSound.play()
	for lamp: Node3D in $Lamps.get_children():
		lamp.get_node("Light").visible = turn_on_lights


func set_mood(p_mood: Mood) -> void:
	mood = p_mood
	turn_on_lights = false

	match p_mood:
		Mood.SUNRISE:
			$DirectionalLight3D.rotation_degrees = Vector3(-20, -150, -137)
			$DirectionalLight3D.light_color = Color(0.414, 0.377, 0.25)
			$DirectionalLight3D.light_energy = 4.0
			$WorldEnvironment.environment.sky.sky_material = preload("res://town/sky_morning.tres")
			$WorldEnvironment.environment.fog_light_color = Color(0.686, 0.6, 0.467)
		Mood.DAY:
			$DirectionalLight3D.rotation_degrees = Vector3(-55, -120, -31)
			$DirectionalLight3D.light_color = Color.WHITE
			$DirectionalLight3D.light_energy = 1.45
			$WorldEnvironment.environment.sky.sky_material = preload("res://town/sky_day.tres")
			$WorldEnvironment.environment.fog_light_color = Color(0.725, 0.918, 1.0)
		Mood.SUNSET:
			$DirectionalLight3D.rotation_degrees = Vector3(-19, -31, 62)
			$DirectionalLight3D.light_color = Color(0.488, 0.3, 0.1)
			$DirectionalLight3D.light_energy = 4.0
			$WorldEnvironment.environment.sky.sky_material = preload("res://town/sky_sunset.tres")
			$WorldEnvironment.environment.fog_light_color = Color(0.776, 0.549, 0.502)
			turn_on_lights = true
		Mood.NIGHT:
			$DirectionalLight3D.rotation_degrees = Vector3(-49, 116, -46)
			$DirectionalLight3D.light_color = Color(0.232, 0.415, 0.413)
			$DirectionalLight3D.light_energy = 0.7
			$WorldEnvironment.environment.sky.sky_material = preload("res://town/sky_night.tres")
			$WorldEnvironment.environment.fog_light_color = Color(0.2, 0.149, 0.125)
			turn_on_lights = true

	$AmbientSound.stream = ambient_sound[p_mood]

	if compatibility_light:
		# Darken the light's energy to compensate for sRGB blending (without affecting sky rendering).
		compatibility_light.rotation_degrees = $DirectionalLight3D.rotation_degrees
		compatibility_light.light_color = $DirectionalLight3D.light_color
		compatibility_light.light_energy = $DirectionalLight3D.light_energy * 0.2

	_match_headlights_to_mood()


## Only ever touches our own truck. The other players' headlights arrive over the network, and
## `get_tree().call_group("car", ...)` would switch theirs too.
func _match_headlights_to_mood() -> void:
	if local_vehicle == null:
		return
	if turn_on_lights != local_vehicle.headlights_active:
		local_vehicle.toggle_headlights()
