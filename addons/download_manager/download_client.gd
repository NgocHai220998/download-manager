class_name DownloadClient
extends Node

## Global singleton for on-demand downloads during gameplay.
## Registered as the "DLClient" autoload when the plugin is enabled.
##
## Usage:
##   var id = DLClient.download_file("https://cdn.com/map.bin", "user://maps/map.bin")
##   DLClient.download_completed.connect(func(did, ok): if did == id: print("Done!"))
##
##   var id2 = DLClient.download_json("https://cdn.com/manifest.json", "user://assets/")

#region Signals

## Emitted every frame for each active download.
signal download_progress(id: int, downloaded: int, total: int)

## Emitted when a download (single file or JSON group) completes.
signal download_completed(id: int, success: bool)

#endregion

#region Internal State

## Number of concurrent download threads. Set before the first download call.
var max_threads: int = 4

var _executor: DownloadExecutorBase
var _active: Dictionary = {} # id -> Array[DownloadTask]
var _pending_json: Dictionary = {} # id -> {"resolved": bool, "tasks": Array}
var _pending_mutex: SafeMutex = SafeMutex.new()
var _pending_manifest_urls: Dictionary = {} # url -> id mapping for manifest resolution
var _next_id: int = 1

#endregion

#region Lifecycle

func _ready() -> void:
	set_process(false)

func _process(_delta: float) -> void:
	_poll_pending_json()
	_poll_active()
	if _active.is_empty() and _pending_json.is_empty():
		set_process(false)

func _exit_tree() -> void:
	if _executor:
		_executor.shutdown()

#endregion

#region Public API

## Downloads a single file. Returns an ID to track progress and completion.
func download_file(url: String, save_path: String, expected_size: int = 0, expected_hash: String = "") -> int:
	_ensure_executor()
	var id: int = _next_id
	_next_id += 1

	var task: DownloadTask = DownloadTask.new()
	task.url = url
	task.save_path = save_path
	task.expected_size = expected_size
	task.expected_hash = expected_hash

	_active[id] = [task]
	_executor.enqueue(task)
	set_process(true)
	return id

## Downloads files from a JSON manifest (URL or local path). Returns an ID.
func download_json(source: String, save_dir: String) -> int:
	_ensure_executor()
	var id: int = _next_id
	_next_id += 1

	if HttpUtil.is_remote(source):
		var info: Dictionary = {"resolved": false, "tasks": []}
		_pending_json[id] = info
		_pending_manifest_urls[source] = id
		if not _executor.manifest_resolved.is_connected(_on_manifest_resolved):
			_executor.manifest_resolved.connect(_on_manifest_resolved)
			_executor.task_started.connect(_on_task_started)
			_executor.task_progress.connect(_on_task_progress)
			_executor.task_completed.connect(_on_task_completed)
		_executor.resolve_manifest(source, save_dir)
	else:
		var tasks: Array[DownloadTask] = _resolve_local_manifest(source, save_dir)
		if tasks.is_empty():
			(func() -> void: download_completed.emit(id, true)).call_deferred()
			return id
		_active[id] = tasks
		for task: DownloadTask in tasks:
			_executor.enqueue(task)

	set_process(true)
	return id

## Returns the current progress for a given download ID.
## Result: {"dl": int, "total": int, "done": bool}
func get_progress(id: int) -> Dictionary:
	var tasks: Array = _active.get(id, []) as Array
	if tasks.is_empty():
		if _pending_json.has(id):
			return {"dl": 0, "total": 0, "done": false}
		return {"dl": 0, "total": 0, "done": true}

	var dl: int = 0
	var total: int = 0
	var all_done: bool = true
	for task: Variant in tasks:
		var p: Dictionary = (task as DownloadTask).get_progress()
		dl += p.dl
		total += p.total
		if not (task as DownloadTask).is_terminal():
			all_done = false
	return {"dl": dl, "total": total, "done": all_done}

## Returns true if the file already exists at the given path.
func is_file_downloaded(save_path: String) -> bool:
	return FileAccess.file_exists(save_path)

## Returns true if the file exists, matches expected size, and optionally matches expected SHA-256 hash.
func is_file_valid(save_path: String, expected_size: int, expected_hash: String = "") -> bool:
	var task: DownloadTask = DownloadTask.new()
	task.save_path = save_path
	task.expected_size = expected_size
	task.expected_hash = expected_hash
	return DownloadWorker._try_cache(task)

#endregion

#region Internal: Executor

func _ensure_executor() -> void:
	if not _executor:
		_executor = DownloadExecutorFactory.create(self, max_threads)

#endregion

#region Internal: Polling

func _poll_pending_json() -> void:
	var done_ids: Array[int] = []

	_pending_mutex.lock()
	for id: int in _pending_json:
		var info: Dictionary = _pending_json[id]
		if not info["resolved"]:
			continue
		done_ids.append(id)
	_pending_mutex.unlock()

	for id: int in done_ids:
		_pending_mutex.lock()
		var info: Dictionary = _pending_json[id]
		_pending_mutex.unlock()

		var tasks: Array = info["tasks"] as Array

		if tasks.is_empty():
			download_completed.emit(id, true)
		else:
			_active[id] = tasks
			for task: Variant in tasks:
				_executor.enqueue(task as DownloadTask)

	for id: int in done_ids:
		_pending_mutex.lock()
		_pending_json.erase(id)
		_pending_mutex.unlock()

func _poll_active() -> void:
	var done_ids: Array[int] = []
	for id: int in _active:
		var tasks: Array = _active[id] as Array
		var dl: int = 0
		var total: int = 0
		var all_done: bool = true
		var has_error: bool = false

		for task: Variant in tasks:
			var t: DownloadTask = task as DownloadTask
			var p: Dictionary = t.get_progress()
			dl += p.dl
			total += p.total
			if not t.is_terminal():
				all_done = false
			elif t.get_status() == DownloadTask.Status.ERROR:
				has_error = true

		download_progress.emit(id, dl, total)

		if all_done:
			download_completed.emit(id, not has_error)
			done_ids.append(id)

	for id: int in done_ids:
		_active.erase(id)

#endregion

#region Internal: Manifest Resolution

func _on_manifest_resolved(tasks: Array[DownloadTask]) -> void:
	# Note: We can't easily map back from tasks to URL, so we'll use a different approach
	# Store the tasks and mark as resolved
	_pending_mutex.lock()
	for id: int in _pending_json:
		var info: Dictionary = _pending_json[id]
		if not info["resolved"]:
			# This is the pending manifest
			info["tasks"] = tasks
			info["resolved"] = true
			break
	_pending_mutex.unlock()

func _resolve_local_manifest(source: String, save_dir: String) -> Array[DownloadTask]:
	var file: FileAccess = FileAccess.open(source, FileAccess.READ)
	if not file:
		push_warning("DownloadClient: Cannot read manifest: " + source)
		return []
	var text: String = file.get_as_text()
	file.close()

	var entries: Array = HttpUtil.parse_manifest_json(text)
	var tasks: Array[DownloadTask] = []
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
		tasks.append(task)
	return tasks

#endregion

#region Executor Callbacks

func _on_task_started(_task: DownloadTask) -> void:
	pass

func _on_task_progress(_task: DownloadTask) -> void:
	pass

func _on_task_completed(_task: DownloadTask, _success: bool) -> void:
	pass

#endregion
