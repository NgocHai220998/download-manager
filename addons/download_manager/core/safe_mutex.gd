class_name SafeMutex
extends RefCounted

## A web-safe mutex wrapper that becomes a no-op on platforms without threading.
## On native platforms, it wraps a real Mutex. On web, it does nothing since
## web execution is single-threaded and doesn't support threading primitives.

var _mutex: Mutex = null

func _init() -> void:
	if DownloadPlatform.is_threading_supported():
		_mutex = Mutex.new()

func lock() -> void:
	if _mutex:
		_mutex.lock()

func unlock() -> void:
	if _mutex:
		_mutex.unlock()
