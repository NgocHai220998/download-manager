class_name DownloadExecutorBase
extends RefCounted

## Abstract base for download executors.
## Subclasses implement platform-specific download logic.

signal task_started(task: DownloadTask)
signal task_progress(task: DownloadTask)
signal task_completed(task: DownloadTask, success: bool)
signal manifest_resolved(tasks: Array[DownloadTask])

## Enqueue a task for download.
func enqueue(task: DownloadTask) -> void:
	push_error("DownloadExecutorBase.enqueue() must be overridden")

## Resolve a remote manifest URL to tasks.
func resolve_manifest(url: String, save_dir: String) -> void:
	push_error("DownloadExecutorBase.resolve_manifest() must be overridden")

## Shutdown the executor.
func shutdown() -> void:
	pass

## Check if executor is ready for more work (for sequential web execution).
func is_idle() -> bool:
	return true

## Poll progress (for web implementation).
func poll_progress() -> void:
	pass
