@tool
extends EditorPlugin

## Pull Requests 编辑器插件：在左侧底部 Dock 槽位展示打开的 PR。

var _dock: EditorDock
var _panel: Control


func _enter_tree() -> void:
	_dock = EditorDock.new()
	_dock.title = "Pull Requests"
	_dock.layout_key = "PullRequestsDock"
	_dock.default_slot = EditorDock.DOCK_SLOT_LEFT_BR
	_dock.icon_name = &"ExternalLink"
	_dock.global = true

	_panel = preload("pull_requests_panel.gd").new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dock.add_child(_panel)

	add_dock(_dock)


func _exit_tree() -> void:
	# 先取消面板中可能挂起的切换流程，再移除 Dock。
	if _panel != null and is_instance_valid(_panel) and _panel.has_method("cancel_operations"):
		_panel.call("cancel_operations")
	if _dock != null:
		remove_dock(_dock)
		_dock.queue_free()
		_dock = null
	_panel = null
