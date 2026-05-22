class_name HttpAsync
extends RefCounted

## Async HTTP utilities using HTTPRequest nodes for web compatibility.
## All operations return immediately and use signals for completion.

signal fetch_completed(url: String, body: String, success: bool)
signal download_completed(task: DownloadTask, success: bool)
signal download_progress(task: DownloadTask)

var _http_request: HTTPRequest
var _current_task: DownloadTask = null
var _current_url: String = ""
var _redirect_count: int = 0
var _owner_node: Node

const MAX_REDIRECTS: int = 5

func _init(owner: Node) -> void:
	_owner_node = owner

## Fetches a URL asynchronously. Emits fetch_completed when done.
func fetch_url(url: String) -> void:
	_current_url = url
	_redirect_count = 0
	_create_http_request()
	var resolved_url: String = _resolve_url(url)
	_http_request.request(resolved_url, ["User-Agent: " + HttpUtil.USER_AGENT])

## Downloads a file asynchronously. Emits download_completed when done.
func download_file(task: DownloadTask) -> void:
	_current_task = task
	_redirect_count = 0

	# Check cache first (synchronous - file I/O is OK on web)
	if DownloadWorker._try_cache(task):
		task.set_status(DownloadTask.Status.DONE)
		download_completed.emit(task, true)
		return

	task.set_status(DownloadTask.Status.DOWNLOADING)
	DirAccess.make_dir_recursive_absolute(task.save_path.get_base_dir())
	_create_http_request()
	_http_request.download_file = task.save_path
	var resolved_url: String = _resolve_url(task.url)
	print("HttpAsync: Starting download - URL: '%s' -> '%s', Save path: %s" % [task.url, resolved_url, task.save_path])
	_http_request.request(resolved_url, ["User-Agent: " + HttpUtil.USER_AGENT])

## Polls download progress. Call this from _process() while a download is active.
func poll_progress() -> void:
	if _current_task and _http_request:
		var downloaded: int = _http_request.get_downloaded_bytes()
		var total: int = _http_request.get_body_size()
		if total <= 0:
			total = _current_task.expected_size
		if total > 0:
			_current_task.sync_exact_bytes(downloaded, total)
			download_progress.emit(_current_task)

func _create_http_request() -> void:
	if _http_request:
		_http_request.queue_free()
	_http_request = HTTPRequest.new()
	_owner_node.add_child(_http_request)
	_http_request.request_completed.connect(_on_request_completed)
	_http_request.timeout = 0  # No timeout for downloads (large files can take time)
	_http_request.accept_gzip = false  # Disable automatic gzip decompression

func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	print("HttpAsync: Request completed - Result: %d, HTTP Code: %d, Body size: %d" % [result, code, body.size()])
	# Handle redirects
	if code in [301, 302, 307, 308] and _redirect_count < MAX_REDIRECTS:
		var location: String = _get_header(headers, "location")
		if location != "":
			_redirect_count += 1
			if _current_task:
				_http_request.download_file = _current_task.save_path
			var resolved_location: String = _resolve_url(location)
			_http_request.request(resolved_location, ["User-Agent: " + HttpUtil.USER_AGENT])
			return

	if _current_task:
		_handle_download_result(result, code, body)
	else:
		_handle_fetch_result(result, code, body)

func _handle_fetch_result(result: int, code: int, body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		fetch_completed.emit(_current_url, body.get_string_from_utf8(), true)
	else:
		fetch_completed.emit(_current_url, "", false)
	_cleanup()

func _handle_download_result(result: int, code: int, _body: PackedByteArray) -> void:
	var task: DownloadTask = _current_task
	_current_task = null

	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		# Verify hash if expected
		if task.expected_hash != "" and FileAccess.get_sha256(task.save_path) != task.expected_hash:
			DirAccess.remove_absolute(task.save_path)
			task.set_status(DownloadTask.Status.ERROR, "Hash mismatch")
			download_completed.emit(task, false)
			_cleanup()
			return

		# Set final progress
		var file: FileAccess = FileAccess.open(task.save_path, FileAccess.READ)
		if file:
			var size: int = file.get_length()
			file.close()
			task.sync_exact_bytes(size, size)
		else:
			task.sync_exact_bytes(task.expected_size, task.expected_size)

		task.set_status(DownloadTask.Status.DONE)
		download_completed.emit(task, true)
	else:
		task.set_status(DownloadTask.Status.ERROR, "HTTP error: %d (result: %d)" % [code, result])
		download_completed.emit(task, false)
	_cleanup()

func _resolve_url(url: String) -> String:
	# If already absolute, return as-is
	if url.begins_with("http://") or url.begins_with("https://"):
		return url

	# On web, resolve relative URLs using JavaScript's URL API
	if DownloadPlatform.is_web():
		var js_code: String = "new URL('%s', window.location.href).href" % url
		var resolved: Variant = JavaScriptBridge.eval(js_code)
		if resolved is String:
			return resolved

	return url

func _cleanup() -> void:
	if _http_request:
		_http_request.queue_free()
		_http_request = null

func _get_header(headers: PackedStringArray, name: String) -> String:
	var lower_name: String = name.to_lower()
	for header: String in headers:
		var parts: PackedStringArray = header.split(":", true, 1)
		if parts.size() == 2 and parts[0].strip_edges().to_lower() == lower_name:
			return parts[1].strip_edges()
	return ""
