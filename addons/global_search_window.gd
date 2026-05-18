@tool
extends Window

const GlobalSearchIndex := preload("res://addons/doubleshiftglobalsearch/global_search_index.gd")
const SEARCH_WINDOW_SIZE := Vector2i(900, 560)

var editor_interface: EditorInterface
var search_index := GlobalSearchIndex.new()
var current_results: Array[Dictionary] = []

var search_box: LineEdit
var results_list: ItemList
var status_label: Label
var refresh_button: Button
var ignore_button: Button
var open_button: Button
var file_icon: Texture2D
var folder_icon: Texture2D
var scene_icon: Texture2D
var script_icon: Texture2D
var text_icon: Texture2D


func configure(next_editor_interface: EditorInterface) -> void:
	editor_interface = next_editor_interface


func popup_search() -> void:
	if search_box == null:
		_build_ui()

	if (
		search_index.entries.is_empty()
		|| search_index.should_rebuild_for_ignore_changes()
		|| search_index.should_rebuild_for_project_changes()
	):
		_rebuild_index()

	var was_visible := visible
	if was_visible:
		_update_results(search_box.text)
	else:
		search_box.text = ""
		_update_results("")

	if visible:
		hide()

	_popup_centered_on_editor_window(SEARCH_WINDOW_SIZE)
	search_box.grab_focus()


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	if search_box != null:
		return

	title = "Double Shift Global Search"
	min_size = Vector2i(720, 420)
	transient = true
	exclusive = false
	hide()
	close_requested.connect(_on_close_requested)
	_load_result_icons()

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.add_theme_constant_override("margin_left", 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(root)

	search_box = LineEdit.new()
	search_box.placeholder_text = "Search files, folders, scenes, scripts, and text"
	search_box.text_changed.connect(_on_search_text_changed)
	search_box.text_submitted.connect(_on_search_text_submitted)
	search_box.gui_input.connect(_on_search_box_gui_input)
	root.add_child(search_box)

	results_list = ItemList.new()
	results_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results_list.custom_minimum_size = Vector2(0, 280)
	results_list.allow_reselect = true
	results_list.item_activated.connect(_on_result_activated)
	results_list.item_selected.connect(_on_result_selected)
	results_list.gui_input.connect(_on_results_list_gui_input)
	root.add_child(results_list)

	var footer := HBoxContainer.new()
	root.add_child(footer)

	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(status_label)

	refresh_button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(_on_refresh_pressed)
	footer.add_child(refresh_button)

	ignore_button = Button.new()
	ignore_button.text = "Ignore"
	ignore_button.disabled = true
	ignore_button.pressed.connect(_on_ignore_pressed)
	footer.add_child(ignore_button)

	open_button = Button.new()
	open_button.text = "Open"
	open_button.disabled = true
	open_button.pressed.connect(_open_selected_result)
	footer.add_child(open_button)


func _on_close_requested() -> void:
	hide()


func _popup_centered_on_editor_window(popup_size: Vector2i) -> void:
	var editor_window := _get_editor_window()
	if editor_window == null:
		popup_centered(popup_size)
		return

	var centered_position := editor_window.position + ((editor_window.size - popup_size) / 2)
	popup(Rect2i(centered_position, popup_size))


func _get_editor_window() -> Window:
	if editor_interface == null:
		return null

	var base_control := editor_interface.get_base_control()
	if base_control == null:
		return null

	return base_control.get_window()


func _on_search_text_changed(query: String) -> void:
	_update_results(query)


func _on_search_text_submitted(_query: String) -> void:
	_open_selected_result()


func _on_result_activated(_index: int) -> void:
	_open_selected_result()


func _on_result_selected(_index: int) -> void:
	open_button.disabled = current_results.is_empty()
	ignore_button.disabled = current_results.is_empty()


func _on_refresh_pressed() -> void:
	_rebuild_index()
	_update_results(search_box.text)
	search_box.grab_focus()


func _on_ignore_pressed() -> void:
	var selected := results_list.get_selected_items()
	if selected.is_empty() || current_results.is_empty():
		return

	var result := current_results[selected[0]]
	var path := str(result.get("path", ""))
	if path.is_empty():
		return

	var open_ignore_content := _get_open_ignore_text_buffer_content()
	if search_index.ignore_path(path, open_ignore_content):
		_sync_open_ignore_text_buffers(search_index.last_ignored_pattern)
		_refresh_editor_filesystem()
		_rebuild_index()
		_update_results(search_box.text)
		status_label.text = search_index.last_ignore_message
		search_box.grab_focus()
		return

	status_label.text = search_index.last_ignore_message


func _on_search_box_gui_input(event: InputEvent) -> void:
	if !(event is InputEventKey):
		return

	var key_event := event as InputEventKey
	if !key_event.pressed || key_event.echo:
		return

	match key_event.keycode:
		KEY_DOWN:
			_move_selection(1)
			get_viewport().set_input_as_handled()
		KEY_UP:
			_move_selection(-1)
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			hide()
			get_viewport().set_input_as_handled()


func _on_results_list_gui_input(event: InputEvent) -> void:
	if !(event is InputEventKey):
		return

	var key_event := event as InputEventKey
	if !key_event.pressed || key_event.echo:
		return

	match key_event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			_open_selected_result()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			hide()
			get_viewport().set_input_as_handled()


func _rebuild_index() -> void:
	status_label.text = "Indexing project..."
	refresh_button.disabled = true
	ignore_button.disabled = true
	open_button.disabled = true

	var entry_count := search_index.rebuild()
	if search_index.ignore_file_created_on_last_rebuild:
		_refresh_editor_filesystem()

	refresh_button.disabled = false
	status_label.text = "%d searchable entries indexed" % entry_count


func _update_results(query: String) -> void:
	current_results = search_index.search(query)
	results_list.clear()

	for result in current_results:
		var row := _format_result_row(result)
		results_list.add_item(row, _get_result_icon(result))
		var item_index := results_list.get_item_count() - 1
		results_list.set_item_custom_fg_color(item_index, _get_result_color(result))
		results_list.set_item_tooltip(item_index, str(result.get("detail", "")))

	if current_results.is_empty():
		status_label.text = "No matches"
		open_button.disabled = true
		ignore_button.disabled = true
		return

	results_list.select(0)
	open_button.disabled = false
	ignore_button.disabled = false
	status_label.text = "%d matches" % current_results.size()


func _format_result_row(result: Dictionary) -> String:
	var kind := str(result.get("kind", "Item"))
	var title_text := str(result.get("title", ""))
	var detail := str(result.get("detail", ""))
	var badge := _get_result_badge(kind)

	return "%s  %s  -  %s" % [badge, title_text, detail]


func _load_result_icons() -> void:
	file_icon = _get_editor_icon("File")
	folder_icon = _get_editor_icon("Folder")
	scene_icon = _get_editor_icon("PackedScene")
	script_icon = _get_editor_icon("GDScript")
	text_icon = _get_editor_icon("TextFile")


func _get_editor_icon(icon_name: String) -> Texture2D:
	var base_control := editor_interface.get_base_control() if editor_interface != null else null
	if base_control == null:
		return null

	if !base_control.has_theme_icon(icon_name, "EditorIcons"):
		return null

	return base_control.get_theme_icon(icon_name, "EditorIcons")


func _get_result_icon(result: Dictionary) -> Texture2D:
	match str(result.get("kind", "")):
		"Folder":
			return folder_icon
		"Scene":
			return scene_icon if scene_icon != null else file_icon
		"Script":
			return script_icon if script_icon != null else file_icon
		"Text":
			return text_icon if text_icon != null else file_icon
		_:
			return file_icon


func _get_result_badge(kind: String) -> String:
	match kind:
		"Folder":
			return "[Folder]"
		"Scene":
			return "[Scene]"
		"Script":
			return "[Script]"
		"Text":
			return "[Text]"
		_:
			return "[File]"


func _get_result_color(result: Dictionary) -> Color:
	match str(result.get("kind", "")):
		"Folder":
			return Color(0.56, 0.78, 1.0)
		"Scene":
			return Color(0.74, 0.88, 1.0)
		"Script":
			return Color(0.72, 1.0, 0.82)
		"Text":
			return Color(0.82, 0.82, 0.82)
		_:
			return Color(1.0, 0.93, 0.72)


func _move_selection(delta: int) -> void:
	if current_results.is_empty():
		return

	var selected := results_list.get_selected_items()
	var next_index := 0
	if !selected.is_empty():
		next_index = clampi(selected[0] + delta, 0, current_results.size() - 1)

	results_list.select(next_index)
	results_list.ensure_current_is_visible()


func _open_selected_result() -> void:
	var selected := results_list.get_selected_items()
	if selected.is_empty() || current_results.is_empty():
		return

	var result := current_results[selected[0]]
	_open_result(result)
	hide()


func _open_result(result: Dictionary) -> void:
	if editor_interface == null:
		return

	var path := str(result.get("path", ""))
	if path.is_empty():
		return

	if str(result.get("kind", "")) == "Folder":
		_select_in_file_system(path)
		return

	var extension := path.get_extension().to_lower()
	if extension == "tscn" || extension == "scn":
		editor_interface.open_scene_from_path(path)
		_select_in_file_system_deferred(path)
		var scene_main_screen := _detect_scene_main_screen(path)
		if !scene_main_screen.is_empty():
			_switch_main_screen(scene_main_screen)
		return

	if ResourceLoader.exists(path):
		var resource := ResourceLoader.load(path)
		if resource is Script:
			var zero_based_line := maxi(0, int(result.get("line", 1)) - 1)
			if editor_interface.has_method("edit_script"):
				editor_interface.call("edit_script", resource, zero_based_line, 0, true)
				_select_in_file_system_deferred(path)
				_switch_main_screen("Script")
				return

		if resource != null:
			editor_interface.edit_resource(resource)
			_select_in_file_system_deferred(path)
			return

	_select_in_file_system(path)


func _select_in_file_system(path: String) -> void:
	if editor_interface != null && editor_interface.has_method("select_file"):
		editor_interface.call("select_file", path)


func _select_in_file_system_deferred(path: String) -> void:
	call_deferred("_select_in_file_system", path)


func _detect_scene_main_screen(path: String) -> String:
	if path.get_extension().to_lower() != "tscn":
		return ""

	var root_type := _read_scene_root_node_type(path)
	if root_type.is_empty() || !ClassDB.class_exists(root_type):
		return ""

	if root_type == "Node3D" || ClassDB.is_parent_class(root_type, "Node3D"):
		return "3D"

	if (
		root_type == "CanvasItem"
		|| root_type == "CanvasLayer"
		|| root_type == "Control"
		|| root_type == "Node2D"
		|| ClassDB.is_parent_class(root_type, "CanvasItem")
		|| ClassDB.is_parent_class(root_type, "CanvasLayer")
	):
		return "2D"

	return ""


func _read_scene_root_node_type(path: String) -> String:
	var scene_file := FileAccess.open(path, FileAccess.READ)
	if scene_file == null:
		return ""

	while !scene_file.eof_reached():
		var line := scene_file.get_line().strip_edges()
		if !line.begins_with("[node "):
			continue

		return _extract_quoted_attribute(line, "type")

	return ""


func _extract_quoted_attribute(line: String, attribute_name: String) -> String:
	var marker := "%s=\"" % attribute_name
	var start_index := line.find(marker)
	if start_index < 0:
		return ""

	start_index += marker.length()
	var end_index := line.find("\"", start_index)
	if end_index < 0:
		return ""

	return line.substr(start_index, end_index - start_index)


func _switch_main_screen(main_screen: String) -> void:
	if editor_interface == null || !editor_interface.has_method("set_main_screen_editor"):
		return

	call_deferred("_switch_main_screen_now", main_screen)


func _switch_main_screen_now(main_screen: String) -> void:
	if editor_interface == null || !editor_interface.has_method("set_main_screen_editor"):
		return

	editor_interface.call("set_main_screen_editor", main_screen)


func _refresh_editor_filesystem() -> void:
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


func _sync_open_ignore_text_buffers(appended_pattern: String) -> void:
	if appended_pattern.is_empty():
		return

	if editor_interface == null:
		return

	var base_control := editor_interface.get_base_control()
	if base_control == null:
		return

	var disk_content := _read_ignore_file_content()
	if disk_content.is_empty():
		return

	_sync_open_ignore_text_buffers_recursive(base_control, disk_content, appended_pattern)


func _sync_open_ignore_text_buffers_recursive(node: Node, disk_content: String, appended_pattern: String) -> void:
	if node is TextEdit:
		var text_edit := node as TextEdit
		var current_text := text_edit.text
		if current_text.begins_with("# DoubleShiftGlobalSearch ignore patterns."):
			text_edit.text = _merge_ignore_editor_text(current_text, disk_content, appended_pattern)

	for child in node.get_children():
		_sync_open_ignore_text_buffers_recursive(child, disk_content, appended_pattern)


func _merge_ignore_editor_text(current_text: String, disk_content: String, appended_pattern: String) -> String:
	if appended_pattern.is_empty():
		return disk_content

	if _text_has_line(current_text, appended_pattern):
		return current_text

	return current_text.rstrip("\n") + "\n" + appended_pattern + "\n"


func _text_has_line(text: String, expected_line: String) -> bool:
	for line in text.split("\n"):
		if line.strip_edges() == expected_line:
			return true

	return false


func _read_ignore_file_content() -> String:
	if !FileAccess.file_exists(GlobalSearchIndex.PROJECT_IGNORE_FILE):
		return ""

	var ignore_file := FileAccess.open(GlobalSearchIndex.PROJECT_IGNORE_FILE, FileAccess.READ)
	if ignore_file == null:
		return ""

	return ignore_file.get_as_text()


func _get_open_ignore_text_buffer_content() -> String:
	if editor_interface == null:
		return ""

	var base_control := editor_interface.get_base_control()
	if base_control == null:
		return ""

	return _find_open_ignore_text_buffer_content(base_control)


func _find_open_ignore_text_buffer_content(node: Node) -> String:
	if node is TextEdit:
		var text_edit := node as TextEdit
		if text_edit.text.begins_with("# DoubleShiftGlobalSearch ignore patterns."):
			return text_edit.text

	for child in node.get_children():
		var found_content := _find_open_ignore_text_buffer_content(child)
		if !found_content.is_empty():
			return found_content

	return ""
