class_name DownloadExecutorFactory
extends RefCounted

## Creates the appropriate executor for the current platform.

static func create(owner: Node, thread_count: int = 4) -> DownloadExecutorBase:
	if DownloadPlatform.is_web():
		return DownloadExecutorWeb.new(owner)
	else:
		return DownloadExecutorNative.new(thread_count)
