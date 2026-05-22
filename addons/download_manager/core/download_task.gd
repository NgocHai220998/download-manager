class_name DownloadTask
extends RefCounted

## Thread-safe data container for a single file download.
## All mutable fields are protected by a mutex.

enum Status { PENDING, DOWNLOADING, DONE, ERROR }

#region Properties

var url: String
var save_path: String
var expected_size: int = 0
var expected_hash: String = ""

#endregion

#region Private State

var _downloaded_bytes: int = 0
var _total_bytes: int = 0
var _status: Status = Status.PENDING
var _error_message: String = ""
var _mutex: SafeMutex = SafeMutex.new()

#endregion

#region Progress

## Increments downloaded bytes. If total >= 0, also updates total bytes.
func add_downloaded_bytes(amount: int, total: int = -1) -> void:
	_mutex.lock()
	_downloaded_bytes += amount
	if total >= 0:
		_total_bytes = total
	_mutex.unlock()

## Sets exact downloaded and total bytes (used for cache hits and group aggregation).
func sync_exact_bytes(downloaded: int, total: int) -> void:
	_mutex.lock()
	_downloaded_bytes = downloaded
	_total_bytes = total
	_mutex.unlock()

## Returns current progress as {"dl": int, "total": int}.
func get_progress() -> Dictionary:
	_mutex.lock()
	var result: Dictionary = {"dl": _downloaded_bytes, "total": _total_bytes}
	_mutex.unlock()
	return result

#endregion

#region Status

func set_status(status: Status, error_msg: String = "") -> void:
	_mutex.lock()
	_status = status
	if error_msg != "":
		_error_message = error_msg
	_mutex.unlock()

func get_status() -> Status:
	_mutex.lock()
	var s: Status = _status
	_mutex.unlock()
	return s

func get_error() -> String:
	_mutex.lock()
	var e: String = _error_message
	_mutex.unlock()
	return e

## Returns true if the task has reached a final state (DONE or ERROR).
func is_terminal() -> bool:
	var s: Status = get_status()
	return s == Status.DONE or s == Status.ERROR

#endregion
