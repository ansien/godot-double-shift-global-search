@tool
extends EditorPlugin

const GlobalSearchIndex := preload("res://addons/doubleshiftglobalsearch/global_search_index.gd")
const GlobalSearchWindow := preload("res://addons/doubleshiftglobalsearch/global_search_window.gd")
const DOUBLE_SHIFT_THRESHOLD_MSEC := 650
const DUPLICATE_SHIFT_EVENT_MSEC := 60
const OPEN_DEBOUNCE_MSEC := 200

var search_window: Window
var last_shift_pressed_msec := -10000
var last_opened_msec := -10000


func _enter_tree() -> void:
	var created_ignore_file := GlobalSearchIndex.ensure_project_ignore_file_exists()

	search_window = GlobalSearchWindow.new()
	search_window.name = "DoubleShiftGlobalSearchWindow"
	search_window.visible = false
	search_window.configure(get_editor_interface())
	get_editor_interface().get_base_control().add_child(search_window)
	search_window.hide()

	add_tool_menu_item("Global Search (Double Shift)", Callable(self, "_open_global_search"))
	set_process_input(true)
	set_process_shortcut_input(true)

	if created_ignore_file:
		call_deferred("_refresh_editor_filesystem")


func _exit_tree() -> void:
	remove_tool_menu_item("Global Search (Double Shift)")

	if is_instance_valid(search_window):
		search_window.queue_free()
	search_window = null


func _input(event: InputEvent) -> void:
	_handle_double_shift_event(event)


func _shortcut_input(event: InputEvent) -> void:
	_handle_double_shift_event(event)


func _handle_double_shift_event(event: InputEvent) -> void:
	if !(event is InputEventKey):
		return

	var key_event := event as InputEventKey
	if !key_event.pressed || key_event.echo:
		return

	if key_event.keycode != KEY_SHIFT && key_event.physical_keycode != KEY_SHIFT:
		return

	var now := Time.get_ticks_msec()
	if now - last_shift_pressed_msec <= DUPLICATE_SHIFT_EVENT_MSEC:
		return

	if now - last_opened_msec < OPEN_DEBOUNCE_MSEC:
		return

	if now - last_shift_pressed_msec <= DOUBLE_SHIFT_THRESHOLD_MSEC:
		last_shift_pressed_msec = -10000
		last_opened_msec = now
		_open_global_search()
		get_viewport().set_input_as_handled()
		return

	last_shift_pressed_msec = now


func _open_global_search() -> void:
	if !is_instance_valid(search_window):
		return

	search_window.popup_search()


func _refresh_editor_filesystem() -> void:
	var editor_interface := get_editor_interface()
	if editor_interface == null || !editor_interface.has_method("get_resource_filesystem"):
		return

	var resource_filesystem := editor_interface.call("get_resource_filesystem")
	if resource_filesystem == null:
		return

	if resource_filesystem.has_method("update_file"):
		resource_filesystem.call("update_file", GlobalSearchIndex.PROJECT_IGNORE_FILE)

	if resource_filesystem.has_method("scan_sources"):
		resource_filesystem.call_deferred("scan_sources")

	if resource_filesystem.has_method("scan"):
		resource_filesystem.call_deferred("scan")
