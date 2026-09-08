extends VBoxContainer

## On-screen buttons for the actions that are otherwise keyboard- or gamepad-only.
##
## The demo ships `TouchScreenButton` nodes for steering and reversing, which leaves a phone player
## unable to boost, honk, or change camera at all. Rather than special-casing touch in
## `vehicle.gd`, these buttons feed the same input actions the keyboard uses.

## Actions that are held down, polled via `Input.is_action_pressed()`.
const HELD_ACTIONS: Array[Array] = [["BOOST", &"boost"]]

## Actions that fire once, handled in `_input()` and therefore needing a real input event.
const TAP_ACTIONS: Array[Array] = [["HORN", &"honk"], ["CAM", &"cycle_camera"]]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 24.0
	offset_top = -236.0
	offset_right = 148.0
	offset_bottom = -24.0
	add_theme_constant_override(&"separation", 12)

	for entry in HELD_ACTIONS:
		add_child(_make_button(entry[0] as String, entry[1] as StringName, true))
	for entry in TAP_ACTIONS:
		add_child(_make_button(entry[0] as String, entry[1] as StringName, false))


func _make_button(label: String, action: StringName, is_held: bool) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(124, 62)
	# Touch buttons should never steal keyboard focus from the game.
	button.focus_mode = Control.FOCUS_NONE

	if is_held:
		button.button_down.connect(func() -> void: Input.action_press(action))
		button.button_up.connect(func() -> void: Input.action_release(action))
	else:
		button.pressed.connect(func() -> void: _send_action_event(action))

	return button


## `Input.action_press()` only updates the polled action state, which `_input()` never sees.
## Parsing a synthetic event instead makes the press reach `vehicle.gd` and `follow_camera.gd`.
func _send_action_event(action: StringName) -> void:
	for pressed in [true, false]:
		var event := InputEventAction.new()
		event.action = action
		event.pressed = pressed
		Input.parse_input_event(event)
