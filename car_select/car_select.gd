extends Control

var audio_master: int = AudioServer.get_bus_index("Master")

@onready var car_container: HBoxContainer = %CarContainer

@onready var button_sdfgi: CheckBox = %SDFGI
@onready var button_mute: TextureButton = %Mute
@onready var slider_volume: HSlider = %Volume

@onready var loading_screen: PanelContainer = %LoadingPanel
@onready var status_label: Label = %LoadingPanel/CenterContainer/Label


func _ready() -> void:
	if Net.is_dedicated_server:
		# No menu, no player: this process only relays truck state.
		hide()
		return

	Net.joined.connect(_on_joined)
	Net.disconnected.connect(_on_disconnected)

	# Time of day is shared between all players now, so it can't be chosen before joining.
	# Players cycle it in-game instead, which changes it for everyone.
	$MoodPanel.hide()

	# Automatically focus the first item for gamepad accessibility.
	focus_first_car()

	# Initialize audio slider.
	slider_volume.value = AudioServer.get_bus_volume_linear(audio_master)

	# Hide SDFGI button if this is using a renderer that doesn't support it
	button_sdfgi.visible = RenderingServer.get_current_rendering_method() == "forward_plus"


func _process(_delta: float) -> void:
	if visible and Input.is_action_just_pressed(&"back"):
		get_tree().quit()


func focus_first_car() -> void:
	car_container.get_child(0).grab_focus.call_deferred()


func _join(vehicle_index: int) -> void:
	Net.local_sdfgi = button_sdfgi.button_pressed

	# Show loading screen and wait for it to be rendered
	loading_screen.visible = true
	status_label.text = "Connecting..."
	await RenderingServer.frame_post_draw

	var url := Net.default_server_url()
	if url.is_empty():
		status_label.text = "No server configured.\nAdd ?server=wss://... to the URL."
		return

	Net.join(url, "Player", vehicle_index)


func _on_joined() -> void:
	hide()


func _on_disconnected(reason: String) -> void:
	show()
	focus_first_car()
	if reason.is_empty():
		# We asked to leave, rather than something going wrong.
		loading_screen.visible = false
	else:
		loading_screen.visible = true
		status_label.text = reason


func _on_mini_van_pressed() -> void:
	_join(0)


func _on_trailer_truck_pressed() -> void:
	_join(1)


func _on_tow_truck_pressed() -> void:
	_join(2)


func _on_mute_toggled(muted: bool) -> void:
	AudioServer.set_bus_mute(audio_master, muted)


func _on_volume_value_changed(value: float) -> void:
	AudioServer.set_bus_volume_linear(audio_master, value)
