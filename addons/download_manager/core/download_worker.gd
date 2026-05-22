class_name DownloadWorker
extends RefCounted

## Executes a single file download in a worker thread.
## Supports retries, redirect following, and post-download hash verification.

const MAX_REDIRECTS: int = 5
const MAX_RETRIES: int = 3
const RETRY_BASE_DELAY_MS: int = 1000
const PROGRESS_INTERVAL_MS: int = 100

#region Public Entry Point

static func execute(task: DownloadTask, on_started: Callable, on_progress: Callable, on_completed: Callable) -> void:
	if _try_cache(task):
		task.set_status(DownloadTask.Status.DONE)
		on_completed.call_deferred(task, true)
		return

	task.set_status(DownloadTask.Status.DOWNLOADING)
	on_started.call_deferred(task)

	var last_error: String = ""
	for attempt: int in range(MAX_RETRIES):
		last_error = _download(task, on_progress)
		if last_error == "":
			print('Hash: ', FileAccess.get_sha256(task.save_path))
			if task.expected_hash != "" and FileAccess.get_sha256(task.save_path) != task.expected_hash:
				_cleanup_partial(task.save_path)
				_fail(task, on_progress, on_completed, "Hash mismatch after download")
				return
			task.set_status(DownloadTask.Status.DONE)
			on_progress.call_deferred(task)
			on_completed.call_deferred(task, true)
			return

		_cleanup_partial(task.save_path)

		if attempt < MAX_RETRIES - 1:
			task.sync_exact_bytes(0, task.expected_size if task.expected_size > 0 else 0)
			OS.delay_msec(RETRY_BASE_DELAY_MS * (attempt + 1))

	_fail(task, on_progress, on_completed, last_error + " (after %d retries)" % MAX_RETRIES)

#endregion

#region Cache Check

## Validates local cache before making any network request.
## Requires expected_size > 0. Optionally checks expected_hash (SHA-256).
static func _try_cache(task: DownloadTask) -> bool:
	if task.expected_size <= 0:
		return false
	if not FileAccess.file_exists(task.save_path):
		return false

	var file: FileAccess = FileAccess.open(task.save_path, FileAccess.READ)
	if not file:
		return false

	var disk_size: int = file.get_length()
	file.close()

	if disk_size != task.expected_size:
		return false
	if task.expected_hash != "" and FileAccess.get_sha256(task.save_path) != task.expected_hash:
		return false

	task.sync_exact_bytes(task.expected_size, task.expected_size)
	return true

#endregion

#region HTTP Download

## Performs the HTTP download. Returns "" on success, error message on failure.
static func _download(task: DownloadTask, on_progress: Callable) -> String:
	var url: String = task.url

	for _redirect: int in range(MAX_REDIRECTS + 1):
		var parsed: HttpUtil.ParsedUrl = HttpUtil.parse_url(url)
		var http: HTTPClient = HTTPClient.new()
		var tls: TLSOptions = TLSOptions.client() if parsed.use_tls else null

		# Connect
		var err: Error = http.connect_to_host(parsed.host, parsed.port, tls)
		if err != OK:
			return "Connection error: " + str(err)

		var start_tick: int = Time.get_ticks_msec()
		while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
			http.poll()
			OS.delay_msec(10)
			if Time.get_ticks_msec() - start_tick > HttpUtil.CONNECT_TIMEOUT_MS:
				return "Connection timeout"

		if http.get_status() != HTTPClient.STATUS_CONNECTED:
			return "Connection failed with status: " + str(http.get_status())

		# Request
		err = http.request(HTTPClient.METHOD_GET, parsed.path, ["User-Agent: " + HttpUtil.USER_AGENT])
		if err != OK:
			return "Request error: " + str(err)

		var req_start: int = Time.get_ticks_msec()
		while http.get_status() == HTTPClient.STATUS_REQUESTING:
			http.poll()
			OS.delay_msec(10)
			if Time.get_ticks_msec() - req_start > HttpUtil.REQUEST_TIMEOUT_MS:
				return "Request timeout"

		if not http.has_response():
			return "No server response"

		var code: int = http.get_response_code()

		# Handle redirects
		if code in [301, 302, 307, 308]:
			var location: String = _get_header_insensitive(http, "location")
			if location == "":
				return "Redirect %d without Location header" % code
			if location.begins_with("/"):
				var scheme: String = "https://" if parsed.use_tls else "http://"
				var port_suffix: String = ""
				if (parsed.use_tls and parsed.port != 443) or (not parsed.use_tls and parsed.port != 80):
					port_suffix = ":" + str(parsed.port)
				url = scheme + parsed.host + port_suffix + location
			else:
				url = location
			continue

		if code != 200:
			return "HTTP %d" % code

		# Read headers
		var server_total: int = _get_content_length(http)
		var check_size: int = task.expected_size if task.expected_size > 0 else server_total
		task.add_downloaded_bytes(0, check_size)

		# Write body to file
		DirAccess.make_dir_recursive_absolute(task.save_path.get_base_dir())
		var file: FileAccess = FileAccess.open(task.save_path, FileAccess.WRITE)
		if not file:
			return "Cannot create file: " + task.save_path

		var last_emit: int = Time.get_ticks_msec()
		var last_data: int = Time.get_ticks_msec()

		while http.get_status() == HTTPClient.STATUS_BODY:
			http.poll()
			var chunk: PackedByteArray = http.read_response_body_chunk()

			if chunk.size() > 0:
				file.store_buffer(chunk)
				task.add_downloaded_bytes(chunk.size(), -1)
				last_data = Time.get_ticks_msec()

				if Time.get_ticks_msec() - last_emit > PROGRESS_INTERVAL_MS:
					on_progress.call_deferred(task)
					last_emit = Time.get_ticks_msec()
			else:
				OS.delay_msec(10)
				if Time.get_ticks_msec() - last_data > HttpUtil.DATA_TIMEOUT_MS:
					file.close()
					return "Data timeout (no data for %ds)" % [HttpUtil.DATA_TIMEOUT_MS / 1000]

		file.close()
		return ""

	return "Too many redirects (%d)" % MAX_REDIRECTS

#endregion

#region Helpers

static func _get_content_length(http: HTTPClient) -> int:
	var value: String = _get_header_insensitive(http, "content-length")
	return value.to_int() if value != "" else 0

static func _get_header_insensitive(http: HTTPClient, header_name: String) -> String:
	var headers: Dictionary = http.get_response_headers_as_dictionary()
	var lower_name: String = header_name.to_lower()
	for key: String in headers:
		if key.to_lower() == lower_name:
			return str(headers[key])
	return ""

static func _cleanup_partial(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

static func _fail(task: DownloadTask, on_progress: Callable, on_completed: Callable, msg: String) -> void:
	task.set_status(DownloadTask.Status.ERROR, msg)
	on_progress.call_deferred(task)
	on_completed.call_deferred(task, false)

#endregion
