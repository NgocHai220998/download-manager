@tool
class_name DownloadGroup
extends Node

## Represents a batch of files to download from a JSON manifest.
## Add as a child of DownloadProgress and configure via the Inspector.

#region Exports

## Display name shown in UI. Falls back to the node name if empty.
@export var group_name: String = ""

## Subdirectory relative to DownloadProgress.base_folder.
## Supports nested paths like "audio/sfx" or "models/characters".
@export var subfolder: String = ""

## Path to the JSON manifest file. Accepts:
##   - Remote URL: "https://cdn.example.com/manifest.json"
##   - Local path: "res://manifests/core_assets.json"
@export var source: String = ""

#endregion

#region Internal State

var _tasks: Array[DownloadTask] = []
var _resolved: bool = false
var _mutex: SafeMutex = SafeMutex.new()

#endregion

#region Public API

func get_display_name() -> String:
	return group_name if group_name != "" else name

## Resolves the manifest from a local file path and creates DownloadTask entries.
func resolve_tasks(base_folder: String) -> Array[DownloadTask]:
	if is_resolved():
		return _get_tasks()
	var save_dir: String = _build_save_dir(base_folder)
	var entries: Array = _load_local_manifest()
	_create_tasks(entries, save_dir)
	_set_resolved(true)
	return _get_tasks()

## Resolves the manifest from a remote URL (blocking). Call from a background thread.
func resolve_tasks_from_url(base_folder: String) -> Array[DownloadTask]:
	if is_resolved():
		return _get_tasks()
	var save_dir: String = _build_save_dir(base_folder)
	var json_text: String = HttpUtil.fetch_url_blocking(source)
	var entries: Array = HttpUtil.parse_manifest_json(json_text) if json_text != "" else []
	_create_tasks(entries, save_dir)
	_set_resolved(true)
	return _get_tasks()

func is_remote_source() -> bool:
	return HttpUtil.is_remote(source)

## Returns true if manifest has been resolved (thread-safe).
func is_resolved() -> bool:
	_mutex.lock()
	var val: bool = _resolved
	_mutex.unlock()
	return val

## Returns aggregate progress for all tasks in this group.
func get_aggregate_progress() -> Dictionary:
	var dl: int = 0
	var total: int = 0
	var done_count: int = 0
	var error_count: int = 0

	for task: DownloadTask in _tasks:
		var p: Dictionary = task.get_progress()
		dl += p.dl
		total += p.total
		match task.get_status():
			DownloadTask.Status.DONE:
				done_count += 1
			DownloadTask.Status.ERROR:
				error_count += 1

	return {
		"dl": dl,
		"total": total,
		"done_count": done_count,
		"error_count": error_count,
		"total_count": _tasks.size()
	}

## Returns true when all tasks have reached a terminal state.
func is_finished() -> bool:
	if _tasks.is_empty():
		return is_resolved()
	for task: DownloadTask in _tasks:
		if not task.is_terminal():
			return false
	return true

func has_errors() -> bool:
	for task: DownloadTask in _tasks:
		if task.get_status() == DownloadTask.Status.ERROR:
			return true
	return false

## Returns filenames of tasks currently being downloaded.
func get_active_files() -> PackedStringArray:
	var result: PackedStringArray = []
	for task: DownloadTask in _tasks:
		if task.get_status() == DownloadTask.Status.DOWNLOADING:
			result.append(task.save_path.get_file())
	return result

## Returns a copy of tasks array (thread-safe).
func _get_tasks() -> Array[DownloadTask]:
	_mutex.lock()
	var copy: Array[DownloadTask] = _tasks.duplicate()
	_mutex.unlock()
	return copy

## Sets tasks externally (used by async manifest resolution).
func _set_tasks(tasks: Array[DownloadTask]) -> void:
	_mutex.lock()
	_tasks = tasks
	_mutex.unlock()

func reset() -> void:
	_mutex.lock()
	_tasks.clear()
	_resolved = false
	_mutex.unlock()

#endregion

#region Internal Helpers

func _set_resolved(value: bool) -> void:
	_mutex.lock()
	_resolved = value
	_mutex.unlock()

func _build_save_dir(base_folder: String) -> String:
	return base_folder.path_join(subfolder) if subfolder != "" else base_folder

func _create_tasks(entries: Array, save_dir: String) -> void:
	_mutex.lock()
	for item: Dictionary in entries:
		# Use web-url on web platform (mandatory to avoid CORS), url on native
		var url: String = item.get("web-url" if DownloadPlatform.is_web() else "url", "")
		if url == "":
			continue
		var task: DownloadTask = DownloadTask.new()
		task.url = url
		task.save_path = save_dir.path_join(item.get("path", url.get_file()))
		task.expected_size = item.get("size", 0)
		task.expected_hash = item.get("hash", "")
		_tasks.append(task)
	_mutex.unlock()

func _load_local_manifest() -> Array:
	if source == "" or is_remote_source():
		return []
	var file: FileAccess = FileAccess.open(source, FileAccess.READ)
	if not file:
		push_warning("DownloadGroup: Cannot read manifest: " + source)
		return []
	var text: String = file.get_as_text()
	file.close()
	return HttpUtil.parse_manifest_json(text)

#endregion

#region Editor Warnings

func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if source == "":
		warnings.append("Source is not configured. Set a URL or local path to a JSON manifest.")
	if not get_parent() is DownloadProgress:
		warnings.append("DownloadGroup must be a child of DownloadProgress.")
	return warnings

#endregion
