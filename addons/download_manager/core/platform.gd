class_name DownloadPlatform
extends RefCounted

## Platform detection utilities for the download manager.
## Used to determine which executor implementation to use.

## Returns true if running on web platform.
static func is_web() -> bool:
	return OS.has_feature("web")

## Returns true if threading is supported on the current platform.
static func is_threading_supported() -> bool:
	return not is_web()
