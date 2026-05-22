class_name DownloadExecutorWeb
extends DownloadExecutorBase

## Web executor using HTTPRequest for sequential async downloads.

var _owner_node: Node
var _http_async: HttpAsync
var _task_queue: Array[DownloadTask] = []
var _current_task: DownloadTask = null
var _is_resolving: bool = false
var _pending_save_dir: String = ""

func _init(owner: Node) -> void:
	_owner_node = owner
	_http_async = HttpAsync.new(owner)
	_http_async.download_completed.connect(_on_download_completed)
	_http_async.download_progress.connect(_on_download_progress)
	_http_async.fetch_completed.connect(_on_fetch_completed)

func enqueue(task: DownloadTask) -> void:
	_task_queue.append(task)
	_process_next()

func resolve_manifest(url: String, save_dir: String) -> void:
	_is_resolving = true
	_pending_save_dir = save_dir
	_http_async.fetch_url(url)

func is_idle() -> bool:
	return _current_task == null and not _is_resolving

func poll_progress() -> void:
	_http_async.poll_progress()

func shutdown() -> void:
	_task_queue.clear()
	_current_task = null

func _process_next() -> void:
	if _current_task != null:
		return  # Already processing
	if _task_queue.is_empty():
		return  # Nothing to do

	_current_task = _task_queue.pop_front()
	task_started.emit(_current_task)
	_http_async.download_file(_current_task)

func _on_download_completed(task: DownloadTask, success: bool) -> void:
	_current_task = null
	task_completed.emit(task, success)
	_process_next()

func _on_download_progress(task: DownloadTask) -> void:
	task_progress.emit(task)

func _on_fetch_completed(url: String, body: String, success: bool) -> void:
	_is_resolving = false
	var tasks: Array[DownloadTask] = []

	if success and body != "":
		var entries: Array = HttpUtil.parse_manifest_json(body)
		for item: Dictionary in entries:
			# Use web-url on web platform (mandatory to avoid CORS), url on native
			var task_url: String = item.get("web-url", "")
			if task_url == "":
				continue
			var task: DownloadTask = DownloadTask.new()
			task.url = task_url
			task.save_path = _pending_save_dir.path_join(item.get("path", task_url.get_file()))
			task.expected_size = item.get("size", 0)
			task.expected_hash = item.get("hash", "")
			tasks.append(task)

	manifest_resolved.emit(tasks)
