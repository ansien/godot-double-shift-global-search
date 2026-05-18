@tool
extends RefCounted

const MAX_TEXT_FILE_BYTES := 500000
const MAX_LINE_CHARS := 220
const PROJECT_IGNORE_FILE := "res://doubleshiftignore.txt"
const LEGACY_PROJECT_IGNORE_FILE := "res://.doubleshiftignore"
const BASE_IGNORE_FILE_CONTENT := "# DoubleShiftGlobalSearch ignore patterns.\n# Add one file, folder, or glob per line.\n# Examples:\n# res://game/_generated/\n# res://addons/vendor/\n# *.tmp\n\n*.import\n*.uid\n*.tmp\n.github/\n.gitattributes\n.gitignore\n"
const RESULT_KIND_FILE := "File"
const RESULT_KIND_FOLDER := "Folder"
const RESULT_KIND_SCENE := "Scene"
const RESULT_KIND_SCRIPT := "Script"
const RESULT_KIND_TEXT := "Text"

const TEXT_EXTENSIONS := {
	"cfg": true,
	"csv": true,
	"gd": true,
	"godot": true,
	"import": true,
	"json": true,
	"md": true,
	"shader": true,
	"tres": true,
	"tscn": true,
	"txt": true,
	"uid": true,
	"xml": true,
	"yaml": true,
	"yml": true,
}

const IGNORED_DIRECTORIES := {
	".git": true,
	".godot": true,
	".import": true,
	"node_modules": true,
}

const DEFAULT_IGNORE_PATTERNS: Array[String] = [
	PROJECT_IGNORE_FILE,
	LEGACY_PROJECT_IGNORE_FILE,
	"res://addons/doubleshiftglobalsearch/",
	"*.import",
	"*.uid",
	".github/",
	".gitattributes",
	".gitignore",
]

var entries: Array[Dictionary] = []
var indexed_at_msec := 0
var ignore_files_signature := ""
var ignore_file_created_on_last_rebuild := false
var ignore_patterns: Array[String] = []
var last_ignored_pattern := ""
var last_ignore_message := ""


func rebuild() -> int:
	entries.clear()
	ignore_file_created_on_last_rebuild = ensure_project_ignore_file_exists()
	ignore_patterns = _load_ignore_patterns()
	ignore_files_signature = get_ignore_files_signature()
	_walk_directory("res://")
	indexed_at_msec = Time.get_ticks_msec()
	return entries.size()


func search(query: String, limit: int = 80) -> Array[Dictionary]:
	var normalized_query := query.strip_edges().to_lower()
	var results: Array[Dictionary] = []

	if normalized_query.is_empty():
		for entry in entries:
			results.append(entry)
			if results.size() >= limit:
				return results
		return results

	var tokens := normalized_query.split(" ", false)
	for entry in entries:
		var score := _score_entry(entry, tokens, normalized_query)
		if score <= 0:
			continue

		var result := entry.duplicate()
		result["score"] = score
		results.append(result)

	results.sort_custom(_sort_by_score_descending)

	var limited_results: Array[Dictionary] = []
	for result in results:
		limited_results.append(result)
		if limited_results.size() >= limit:
			return limited_results

	return limited_results


func ignore_path(path: String, existing_ignore_content: String = "") -> bool:
	ensure_project_ignore_file_exists()
	last_ignored_pattern = ""
	last_ignore_message = ""

	var pattern := _build_ignore_pattern(path)
	if pattern.is_empty():
		last_ignore_message = "Nothing to ignore."
		return false

	var normalized_pattern := _normalize_pattern(pattern)
	if _is_ignored_by_default(normalized_pattern):
		last_ignore_message = "%s is already ignored by default." % pattern
		return true

	var next_content := existing_ignore_content
	if next_content.is_empty():
		next_content = _read_project_ignore_file_content()

	if _ignore_content_has_pattern(next_content, normalized_pattern):
		last_ignore_message = "%s is already listed in %s." % [pattern, PROJECT_IGNORE_FILE]
		return true

	var ignore_file := FileAccess.open(PROJECT_IGNORE_FILE, FileAccess.WRITE)
	if ignore_file == null:
		last_ignore_message = "Could not write %s." % PROJECT_IGNORE_FILE
		return false

	if !next_content.is_empty():
		ignore_file.store_string(next_content.rstrip("\n") + "\n")
	ignore_file.store_line(pattern)
	last_ignored_pattern = pattern
	last_ignore_message = "Ignored %s in %s." % [pattern, PROJECT_IGNORE_FILE]

	return true


static func ensure_project_ignore_file_exists() -> bool:
	if FileAccess.file_exists(PROJECT_IGNORE_FILE):
		return false

	var ignore_file := FileAccess.open(PROJECT_IGNORE_FILE, FileAccess.WRITE)
	if ignore_file == null:
		return false

	ignore_file.store_string(BASE_IGNORE_FILE_CONTENT)
	return true


func should_rebuild_for_ignore_changes() -> bool:
	ensure_project_ignore_file_exists()
	return ignore_files_signature != get_ignore_files_signature()


func get_ignore_files_signature() -> String:
	return "%s:%s|%s:%s" % [
		PROJECT_IGNORE_FILE,
		_get_file_signature(PROJECT_IGNORE_FILE),
		LEGACY_PROJECT_IGNORE_FILE,
		_get_file_signature(LEGACY_PROJECT_IGNORE_FILE),
	]


func _get_file_signature(path: String) -> String:
	if !FileAccess.file_exists(path):
		return "missing"

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "unreadable"

	var content := file.get_as_text()
	return "%d:%d:%d" % [FileAccess.get_modified_time(path), content.length(), content.hash()]


func _walk_directory(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return

	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while !entry_name.is_empty():
		var entry_path := _join_path(path, entry_name)
		if _is_ignored_path(entry_path):
			entry_name = directory.get_next()
			continue

		if directory.current_is_dir():
			if !_should_ignore_directory(entry_name):
				_add_directory_entry(entry_name, entry_path)
				_walk_directory(entry_path)
		else:
			_add_file_entry(entry_name, entry_path)

		entry_name = directory.get_next()

	directory.list_dir_end()


func _add_directory_entry(directory_name: String, path: String) -> void:
	entries.append({
		"kind": RESULT_KIND_FOLDER,
		"title": directory_name,
		"path": path,
		"detail": path,
		"line": 0,
		"search_text": "%s %s" % [directory_name, path],
	})


func _add_file_entry(file_name: String, path: String) -> void:
	entries.append({
		"kind": _get_file_result_kind(path),
		"title": file_name,
		"path": path,
		"detail": path,
		"line": 0,
		"search_text": "%s %s" % [file_name, path],
	})

	if _should_index_file_content(path):
		_add_text_line_entries(file_name, path)


func _get_file_result_kind(path: String) -> String:
	match path.get_extension().to_lower():
		"gd":
			return RESULT_KIND_SCRIPT
		"scn", "tscn":
			return RESULT_KIND_SCENE
		_:
			return RESULT_KIND_FILE


func _add_text_line_entries(file_name: String, path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return

	var line_number := 1
	while !file.eof_reached():
		var line := file.get_line().strip_edges()
		if !line.is_empty():
			var snippet := line.left(MAX_LINE_CHARS)
			entries.append({
				"kind": RESULT_KIND_TEXT,
				"title": file_name,
				"path": path,
				"detail": "%s:%d  %s" % [path, line_number, snippet],
				"line": line_number,
				"search_text": line,
			})
		line_number += 1


func _should_index_file_content(path: String) -> bool:
	var extension := path.get_extension().to_lower()
	if !TEXT_EXTENSIONS.has(extension):
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false

	return file.get_length() <= MAX_TEXT_FILE_BYTES


func _should_ignore_directory(directory_name: String) -> bool:
	return IGNORED_DIRECTORIES.has(directory_name)


func _score_entry(entry: Dictionary, tokens: PackedStringArray, normalized_query: String) -> int:
	if str(entry.get("kind", "")) == RESULT_KIND_TEXT:
		return _score_text_entry(entry, tokens, normalized_query)

	var title := str(entry.get("title", "")).to_lower()
	var path := str(entry.get("path", "")).to_lower()
	var detail := str(entry.get("detail", "")).to_lower()
	var search_text := str(entry.get("search_text", "")).to_lower()
	var score := 0

	for token in tokens:
		if token.is_empty():
			continue

		if title == token:
			score += 700
		elif title.begins_with(token):
			score += 500
		elif title.contains(token):
			score += 350
		elif path.contains(token):
			score += 180
		elif detail.contains(token):
			score += 120
		elif search_text.contains(token):
			score += 80
		elif _is_subsequence(token, title) || _is_subsequence(token, path):
			score += 35
		else:
			return 0

	if title == normalized_query:
		score += 1000
	elif title.begins_with(normalized_query):
		score += 600
	elif path.contains(normalized_query):
		score += 220

	var line := int(entry.get("line", 0))
	if line == 0:
		score += 30

	return score


func _score_text_entry(entry: Dictionary, tokens: PackedStringArray, normalized_query: String) -> int:
	if normalized_query.length() < 3:
		return 0

	var search_text := str(entry.get("search_text", "")).to_lower()
	var score := 0

	for token in tokens:
		if token.is_empty():
			continue

		if search_text.contains(token):
			score += 70
		else:
			return 0

	if search_text.contains(normalized_query):
		score += 120

	return score


func _load_ignore_patterns() -> Array[String]:
	var patterns: Array[String] = []
	for pattern in DEFAULT_IGNORE_PATTERNS:
		patterns.append(_normalize_pattern(pattern))

	_append_ignore_file_patterns(PROJECT_IGNORE_FILE, patterns)
	_append_ignore_file_patterns(LEGACY_PROJECT_IGNORE_FILE, patterns)

	return patterns


func _append_ignore_file_patterns(path: String, patterns: Array[String]) -> void:
	if !FileAccess.file_exists(path):
		return

	var ignore_file := FileAccess.open(path, FileAccess.READ)
	if ignore_file == null:
		return

	while !ignore_file.eof_reached():
		var line := ignore_file.get_line().strip_edges()
		if line.is_empty() || line.begins_with("#"):
			continue

		patterns.append(_normalize_pattern(line))


func _build_ignore_pattern(path: String) -> String:
	var normalized_path := _normalize_path(path)
	if normalized_path.is_empty():
		return ""

	if DirAccess.dir_exists_absolute(normalized_path) && !normalized_path.ends_with("/"):
		return normalized_path + "/"

	return normalized_path


func _is_ignored_by_default(pattern: String) -> bool:
	for default_pattern in DEFAULT_IGNORE_PATTERNS:
		if _matches_ignore_pattern(pattern.to_lower(), _normalize_pattern(default_pattern).to_lower()):
			return true

	return false


func _ignore_content_has_pattern(content: String, pattern: String) -> bool:
	for line in content.split("\n"):
		var normalized_line := _normalize_pattern(line.strip_edges())
		if normalized_line.is_empty() || normalized_line.begins_with("#"):
			continue

		if normalized_line == pattern:
			return true

	return false


func _read_project_ignore_file_content() -> String:
	if !FileAccess.file_exists(PROJECT_IGNORE_FILE):
		return ""

	var existing_file := FileAccess.open(PROJECT_IGNORE_FILE, FileAccess.READ)
	if existing_file == null:
		return ""

	return existing_file.get_as_text()


func _is_ignored_path(path: String) -> bool:
	var normalized_path := _normalize_path(path).to_lower()
	for pattern in ignore_patterns:
		if pattern.is_empty():
			continue

		var normalized_pattern := pattern.to_lower()
		if _matches_ignore_pattern(normalized_path, normalized_pattern):
			return true

	return false


func _matches_ignore_pattern(path: String, pattern: String) -> bool:
	if pattern.contains("*") && (path.match(pattern) || path.get_file().match(pattern)):
		return true

	if pattern.ends_with("/") && (path == pattern.trim_suffix("/") || path.begins_with(pattern)):
		return true

	if path == pattern || path.begins_with(pattern + "/"):
		return true

	if !pattern.contains("/"):
		return path.get_file() == pattern || path.contains("/%s/" % pattern)

	return false


func _normalize_pattern(pattern: String) -> String:
	var normalized_pattern := pattern.strip_edges().replace("\\", "/")
	if normalized_pattern.begins_with("/"):
		normalized_pattern = normalized_pattern.substr(1)

	if !normalized_pattern.begins_with("res://") && normalized_pattern.contains("/"):
		normalized_pattern = "res://" + normalized_pattern

	return normalized_pattern


func _normalize_path(path: String) -> String:
	return path.strip_edges().replace("\\", "/")


func _is_subsequence(needle: String, haystack: String) -> bool:
	if needle.is_empty():
		return true

	var needle_index := 0
	for haystack_index in haystack.length():
		if haystack[haystack_index] == needle[needle_index]:
			needle_index += 1
			if needle_index >= needle.length():
				return true

	return false


func _join_path(base_path: String, child_name: String) -> String:
	if base_path.ends_with("/"):
		return "%s%s" % [base_path, child_name]

	return "%s/%s" % [base_path, child_name]


static func _sort_by_score_descending(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("score", 0)) > int(right.get("score", 0))
