class_name DownloadExecutorNative
extends DownloadExecutorBase

## Native executor using thread pool for parallel downloads.

var _pool: DownloadThreadPool
var _manifest_thread: Thread = null
var _manifest_mutex: Mutex = Mutex.new()
var _manifest_result: Array[DownloadTask] = []
var _manifest_done: bool = false

func _init(thread_count: int = 4) -> void:
	_pool = DownloadThreadPool.new()
	_pool.start(thread_count)

func enqueue(task: DownloadTask) -> void:
	_pool.enqueue(task, _on_started, _on_progress, _on_completed)

func resolve_manifest(url: String, save_dir: String) -> void:
	_manifest_mutex.lock()
	_manifest_done = false
	_manifest_result.clear()
	_manifest_mutex.unlock()

	_manifest_thread = Thread.new()
	_manifest_thread.start(_do_resolve.bind(url, save_dir))

func _do_resolve(url: String, save_dir: String) -> void:
	var json_text: String = HttpUtil.fetch_url_blocking(url)
	var tasks: Array[DownloadTask] = []

	if json_text != "":
		var entries: Array = HttpUtil.parse_manifest_json(json_text)
		for item: Dictionary in entries:
			var task_url: String = item.get("url", "")
			if task_url == "":
				continue
			var task: DownloadTask = DownloadTask.new()
			task.url = task_url
			task.save_path = save_dir.path_join(item.get("path", task_url.get_file()))
			task.expected_size = item.get("size", 0)
			task.expected_hash = item.get("hash", "")
			tasks.append(task)

	_manifest_mutex.lock()
	_manifest_result = tasks
	_manifest_done = true
	_manifest_mutex.unlock()

## Call this from _process() to check if manifest is ready.
func check_manifest() -> bool:
	_manifest_mutex.lock()
	var done: bool = _manifest_done
	_manifest_mutex.unlock()

	if not done:
		return false

	if _manifest_thread:
		_manifest_thread.wait_to_finish()
		_manifest_thread = null

	_manifest_mutex.lock()
	var tasks: Array[DownloadTask] = _manifest_result.duplicate()
	_manifest_mutex.unlock()

	manifest_resolved.emit(tasks)
	return true

func shutdown() -> void:
	if _manifest_thread and _manifest_thread.is_alive():
		_manifest_thread.wait_to_finish()
	_pool.shutdown()

func _on_started(task: DownloadTask) -> void:
	task_started.emit(task)

func _on_progress(task: DownloadTask) -> void:
	task_progress.emit(task)

func _on_completed(task: DownloadTask, success: bool) -> void:
	task_completed.emit(task, success)
