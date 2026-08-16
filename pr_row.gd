@tool
extends PanelContainer

## 单条 PR 行：标题、分支链接、合并/关闭/切换。由面板 instantiate 后 configure。

signal merge_requested(pr: Dictionary)
signal close_requested(pr: Dictionary)
signal checkout_requested(pr: Dictionary)
signal link_opened(number: int)

@onready var _title_label: Label = %TitleLabel
@onready var _branch_row: HBoxContainer = %BranchRow
@onready var _branch_link: LinkButton = %BranchLink
@onready var _branch_label: Label = %BranchLabel
@onready var _merge_button: Button = %MergeButton
@onready var _close_button: Button = %CloseButton
@onready var _checkout_button: Button = %CheckoutButton

## 当前行绑定的 PR（configure 时 deep copy）。
var _pr: Dictionary = {}
## 草稿或冲突时，解锁 busy 后合并按钮仍保持禁用。
var _keep_disabled: bool = false
## 面板 busy 锁定（刷新中 / 确认框 / 操作进行中）。
var _busy: bool = false


func _ready() -> void:
	# configure 可能在 add_child 之前调用，@onready 此时才就绪，补一次刷新。
	if not _pr.is_empty():
		_apply_pr()
	_apply_busy()


func configure(pr: Dictionary) -> void:
	_pr = pr.duplicate(true)
	_apply_pr()
	_apply_busy()


func set_busy(busy: bool) -> void:
	_busy = busy
	_apply_busy()


func _apply_pr() -> void:
	if _title_label == null:
		return

	var number: int = int(_pr.get("number", 0))
	var title := str(_pr.get("title", ""))
	var branch := str(_pr.get("headRefName", ""))
	var url := str(_pr.get("url", ""))
	var is_draft := bool(_pr.get("isDraft", false))
	var mergeable := str(_pr.get("mergeable", ""))

	_title_label.text = "#" + str(number) + "  " + title

	if branch.is_empty():
		_branch_row.visible = false
	else:
		_branch_row.visible = true
		if url.is_empty():
			_branch_link.visible = false
			_branch_label.visible = true
			_branch_label.text = branch
			_branch_link.text = ""
			_branch_link.uri = ""
		else:
			_branch_link.visible = true
			_branch_label.visible = false
			_branch_link.text = branch
			_branch_link.uri = url
			_branch_label.text = ""

	_keep_disabled = false
	_merge_button.tooltip_text = ""
	if is_draft:
		_keep_disabled = true
		_merge_button.tooltip_text = "草稿 PR 不能合并"
	elif mergeable == "CONFLICTING":
		_keep_disabled = true
		_merge_button.tooltip_text = "此 PR 有合并冲突，无法合并"


func _apply_busy() -> void:
	if _merge_button == null:
		return
	_merge_button.disabled = _busy or _keep_disabled
	_close_button.disabled = _busy
	_checkout_button.disabled = _busy
	_branch_link.disabled = _busy


func _on_merge_pressed() -> void:
	if _pr.is_empty():
		return
	merge_requested.emit(_pr.duplicate(true))


func _on_close_pressed() -> void:
	if _pr.is_empty():
		return
	close_requested.emit(_pr.duplicate(true))


func _on_checkout_pressed() -> void:
	if _pr.is_empty():
		return
	checkout_requested.emit(_pr.duplicate(true))


func _on_link_pressed() -> void:
	if _pr.is_empty():
		return
	link_opened.emit(int(_pr.get("number", 0)))
