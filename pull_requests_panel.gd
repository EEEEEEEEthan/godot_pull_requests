@tool
extends VBoxContainer

## Pull Requests 面板：列出 open PR，支持浏览器打开与对齐 PR head 切换分支。

const _GH_LIST_SUBARGS: PackedStringArray = [
	"pr", "list",
	"--state", "open",
	"--json", "number,title,url,headRefName,state",
	"--limit", "100",
]

var _status_label: Label
var _refresh_button: Button
var _list_container: VBoxContainer
var _empty_label: Label
var _confirm_dialog: ConfirmationDialog

## 交互锁定：刷新中 / 确认框打开 / 切换分支进行中。
var _busy: bool = false
## 插件卸载或面板退出时置位，阻止 await 后继续执行破坏性 git。
var _cancelled: bool = false
## 待切换的 PR 元数据（确认框确认后使用）。
var _pending_pr: Dictionary = {}
## 缓存从 origin 解析出的 GitHub owner/repo，供 gh -R 使用。
var _cached_github_repo: String = ""


func _ready() -> void:
	_cancelled = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	_build_ui()
	# 等进入场景树后再拉列表，避免 Dock 尚未挂载时发起外部进程。
	call_deferred("_refresh_prs")


func _exit_tree() -> void:
	cancel_operations()


## 插件卸载或面板退出时调用：阻止后续破坏性 git，并断开确认框信号。
func cancel_operations() -> void:
	_cancelled = true
	_pending_pr.clear()
	if _confirm_dialog != null and is_instance_valid(_confirm_dialog):
		if _confirm_dialog.confirmed.is_connected(_on_checkout_confirmed):
			_confirm_dialog.confirmed.disconnect(_on_checkout_confirmed)
		if _confirm_dialog.canceled.is_connected(_on_checkout_canceled):
			_confirm_dialog.canceled.disconnect(_on_checkout_canceled)
		if _confirm_dialog.visible:
			_confirm_dialog.hide()


func _build_ui() -> void:
	var toolbar := HBoxContainer.new()
	toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_theme_constant_override("separation", 8)
	add_child(toolbar)

	_refresh_button = Button.new()
	_refresh_button.text = "刷新"
	_refresh_button.tooltip_text = "重新拉取打开的 Pull Request 列表"
	_refresh_button.pressed.connect(_refresh_prs)
	toolbar.add_child(_refresh_button)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "准备就绪"
	toolbar.add_child(_status_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_list_container = VBoxContainer.new()
	_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_container.add_theme_constant_override("separation", 8)
	scroll.add_child(_list_container)

	_empty_label = Label.new()
	_empty_label.text = "暂无打开的 Pull Request"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.visible = false
	_list_container.add_child(_empty_label)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "确认切换分支"
	_confirm_dialog.ok_button_text = "丢弃并切换"
	_confirm_dialog.cancel_button_text = "取消"
	_confirm_dialog.dialog_autowrap = true
	_confirm_dialog.min_size = Vector2(420, 0)
	_confirm_dialog.confirmed.connect(_on_checkout_confirmed)
	_confirm_dialog.canceled.connect(_on_checkout_canceled)
	add_child(_confirm_dialog)


func _still_alive() -> bool:
	return (not _cancelled) and is_instance_valid(self) and is_inside_tree()


## await 一帧以刷新 UI；若面板已卸载则返回 false。
func _yield_ui() -> bool:
	if not _still_alive():
		return false
	await get_tree().process_frame
	return _still_alive()


func _set_status(message: String, is_error: bool = false) -> void:
	if not is_instance_valid(_status_label):
		return
	_status_label.text = message
	if is_error:
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	else:
		_status_label.remove_theme_color_override("font_color")


func _set_busy(busy: bool) -> void:
	_busy = busy
	if is_instance_valid(_refresh_button):
		_refresh_button.disabled = busy
	if not is_instance_valid(_list_container):
		return
	for child in _list_container.get_children():
		if child == _empty_label:
			continue
		_set_row_disabled(child, busy)


func _set_row_disabled(row: Node, disabled: bool) -> void:
	for child in row.get_children():
		if child is Button:
			(child as Button).disabled = disabled
		elif child is Container:
			_set_row_disabled(child, disabled)


func _project_dir() -> String:
	return ProjectSettings.globalize_path("res://").rstrip("/").rstrip("\\")


func _has_newline(value: String) -> bool:
	return value.contains("\n") or value.contains("\r")


## 直接 OS.execute，不经 shell。
func _execute(executable: String, arguments: PackedStringArray) -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute(executable, arguments, output, true)
	var joined := "\n".join(output).strip_edges()
	var result := {
		"ok": exit_code == 0,
		"exit_code": exit_code,
		"output": joined,
		"error": "",
	}
	if exit_code == -1:
		result["error"] = "无法启动进程：%s（请确认已安装并在 PATH 中）" % executable
	elif exit_code != 0:
		result["error"] = joined if not joined.is_empty() else (
			"%s 失败（退出码 %d）" % [executable, exit_code]
		)
	return result


## git -C <project_dir> ...
func _run_git(arguments: PackedStringArray) -> Dictionary:
	var args := PackedStringArray(["-C", _project_dir()])
	args.append_array(arguments)
	return _execute("git", args)


## 从 origin URL 解析 owner/repo（支持 https / ssh / 带 token 的 URL）。
func _parse_github_repo(remote_url: String) -> String:
	var url := remote_url.strip_edges()
	if url.is_empty():
		return ""

	# 去掉可选的 .git 后缀
	if url.ends_with(".git"):
		url = url.substr(0, url.length() - 4)

	var marker := "github.com"
	var idx := url.find(marker)
	if idx < 0:
		return ""

	# https://...github.com/owner/repo、git@github.com:owner/repo、ssh://git@github.com/owner/repo
	var after := url.substr(idx + marker.length())
	after = after.lstrip("/:")
	return _normalize_owner_repo(after)


func _normalize_owner_repo(path: String) -> String:
	var cleaned := path.strip_edges().trim_prefix("/").trim_suffix("/")
	# 去掉查询串 / fragment
	var cut := cleaned.find("?")
	if cut >= 0:
		cleaned = cleaned.substr(0, cut)
	cut = cleaned.find("#")
	if cut >= 0:
		cleaned = cleaned.substr(0, cut)
	var parts := cleaned.split("/")
	if parts.size() < 2:
		return ""
	var owner := str(parts[0]).strip_edges()
	var repo := str(parts[1]).strip_edges()
	if owner.is_empty() or repo.is_empty():
		return ""
	if _has_newline(owner) or _has_newline(repo):
		return ""
	return owner + "/" + repo


func _resolve_github_repo() -> String:
	if not _cached_github_repo.is_empty():
		return _cached_github_repo
	var remote_result := _run_git(PackedStringArray(["remote", "get-url", "origin"]))
	if not remote_result["ok"]:
		return ""
	_cached_github_repo = _parse_github_repo(str(remote_result["output"]))
	return _cached_github_repo


## gh ...；必须带 -R owner/repo，避免依赖进程 cwd。
func _run_gh(arguments: PackedStringArray) -> Dictionary:
	var repo := _resolve_github_repo()
	if repo.is_empty():
		return {
			"ok": false,
			"exit_code": -1,
			"output": "",
			"error": "无法从 origin 解析 GitHub 仓库（owner/repo），请确认远程为 GitHub",
		}
	var args := PackedStringArray(["-R", repo])
	args.append_array(arguments)
	return _execute("gh", args)


func _clear_list_rows() -> void:
	for child in _list_container.get_children():
		if child == _empty_label:
			continue
		_list_container.remove_child(child)
		child.queue_free()


func _refresh_prs() -> void:
	if _busy or _cancelled:
		return

	_set_busy(true)
	_set_status("正在加载 Pull Request…")
	_clear_list_rows()
	_empty_label.visible = false

	if not await _yield_ui():
		return

	var result := _run_gh(_GH_LIST_SUBARGS)
	if not _still_alive():
		return
	if not result["ok"]:
		_empty_label.text = "加载失败"
		_empty_label.visible = true
		_set_status("加载失败：" + str(result["error"]), true)
		_set_busy(false)
		return

	var parsed: Variant = JSON.parse_string(str(result["output"]))
	if typeof(parsed) != TYPE_ARRAY:
		_empty_label.text = "解析失败"
		_empty_label.visible = true
		_set_status("无法解析 gh 输出为 JSON 数组", true)
		_set_busy(false)
		return

	var open_prs: Array = []
	for item in parsed:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var pr: Dictionary = item
		var state := str(pr.get("state", "")).to_upper()
		# 仅展示 open；gh 已按 state 过滤，这里再保险一次。
		if state != "OPEN":
			continue
		open_prs.append(pr)

	if open_prs.is_empty():
		_empty_label.text = "暂无打开的 Pull Request"
		_empty_label.visible = true
		_set_status("共 0 个打开的 Pull Request")
		_set_busy(false)
		return

	_empty_label.visible = false
	for pr in open_prs:
		_list_container.add_child(_make_pr_row(pr))

	_set_status("共 %d 个打开的 Pull Request" % open_prs.size())
	_set_busy(false)


func _make_pr_row(pr: Dictionary) -> Control:
	var number: int = int(pr.get("number", 0))
	var title := str(pr.get("title", ""))
	var branch := str(pr.get("headRefName", ""))
	var url := str(pr.get("url", ""))

	var row := PanelContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	row.add_child(margin)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 4)
	margin.add_child(column)

	var title_label := Label.new()
	title_label.text = "#" + str(number) + "  " + title
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(title_label)

	if not branch.is_empty():
		var branch_label := Label.new()
		branch_label.text = "分支：" + branch
		branch_label.modulate = Color(0.75, 0.78, 0.85)
		branch_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(branch_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	column.add_child(buttons)

	var open_button := Button.new()
	open_button.text = "在浏览器中打开"
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_button.pressed.connect(_on_open_pr_pressed.bind(url, number))
	buttons.add_child(open_button)

	var checkout_button := Button.new()
	checkout_button.text = "切换到此分支"
	checkout_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checkout_button.pressed.connect(_on_checkout_pressed.bind(pr.duplicate(true)))
	buttons.add_child(checkout_button)

	return row


func _on_open_pr_pressed(url: String, number: int) -> void:
	if _busy or _cancelled:
		return
	if url.is_empty():
		_set_status("PR #%d 缺少 URL" % number, true)
		return
	var err := OS.shell_open(url)
	if err != OK:
		_set_status("无法打开浏览器（错误码 %d）" % err, true)
	else:
		_set_status("已在浏览器中打开 PR #%d" % number)


func _on_checkout_pressed(pr: Dictionary) -> void:
	if _busy or _cancelled:
		return

	var number: int = int(pr.get("number", 0))
	var title := str(pr.get("title", ""))
	var branch := str(pr.get("headRefName", ""))
	if number <= 0:
		_set_status("无效的 PR 编号，无法切换", true)
		return
	if branch.is_empty():
		_set_status("PR #%d 缺少分支名，无法切换" % number, true)
		return
	if _has_newline(branch):
		_set_status("PR #%d 的分支名含换行，已拒绝切换" % number, true)
		return

	_pending_pr = pr
	# 确认框打开期间锁定 UI，避免并发刷新 / 重复切换。
	_set_busy(true)
	_confirm_dialog.dialog_text = (
		"即将切换到 PR #" + str(number) + "「" + title + "」的分支：\n"
		+ branch
		+ "\n\n将通过 pull/" + str(number) + "/head 对齐该 PR 的最新 head"
		+ "（兼容 fork / 跨仓 PR）。\n\n"
		+ "警告：此操作会丢弃本地所有未提交的改动（含未跟踪文件），"
		+ "并覆盖本地同名分支。\n\n"
		+ "确定继续吗？"
	)
	_confirm_dialog.popup_centered()


func _on_checkout_canceled() -> void:
	# 仅在仍停留在确认阶段时解锁；切换流程中途不应由此路径误解锁。
	if _pending_pr.is_empty():
		return
	_pending_pr.clear()
	if _still_alive():
		_set_busy(false)
		_set_status("已取消切换分支")


func _on_checkout_confirmed() -> void:
	if _cancelled:
		return
	if _pending_pr.is_empty():
		return

	var pr := _pending_pr.duplicate(true)
	_pending_pr.clear()

	var number: int = int(pr.get("number", 0))
	var branch := str(pr.get("headRefName", ""))
	if number <= 0:
		_set_status("无效的 PR 编号，已取消切换", true)
		_set_busy(false)
		return
	if branch.is_empty() or _has_newline(branch):
		_set_status("分支名无效，已取消切换", true)
		_set_busy(false)
		return

	# _busy 在打开确认框时已置位；此处只刷新一次 UI，随后同步执行全部 git。
	_set_status("正在对齐 PR #" + str(number) + " 的 head…")
	if not await _yield_ui():
		return

	var pull_ref := "pull/%d/head" % number

	# 1) 拉取 PR 官方 head ref（对 fork / 跨仓同样有效）
	var fetch_result := _run_git(PackedStringArray(["fetch", "origin", pull_ref]))
	if not _still_alive():
		return
	if not fetch_result["ok"]:
		_set_status("git fetch " + pull_ref + " 失败：" + str(fetch_result["error"]), true)
		_set_busy(false)
		return

	# 2) 丢弃当前工作区已跟踪文件的本地修改
	var reset_result := _run_git(PackedStringArray(["reset", "--hard"]))
	if not _still_alive():
		return
	if not reset_result["ok"]:
		_set_status("git reset --hard 失败：" + str(reset_result["error"]), true)
		_set_busy(false)
		return

	# 3) 清理未跟踪文件与目录
	var clean_result := _run_git(PackedStringArray(["clean", "-fd"]))
	if not _still_alive():
		return
	if not clean_result["ok"]:
		_set_status("git clean -fd 失败：" + str(clean_result["error"]), true)
		_set_busy(false)
		return

	# 4) 用 FETCH_HEAD（PR head）创建/覆盖本地分支
	var checkout_result := _run_git(
		PackedStringArray(["checkout", "-B", branch, "FETCH_HEAD"]),
	)
	if not _still_alive():
		return
	if not checkout_result["ok"]:
		_set_status("git checkout 失败：" + str(checkout_result["error"]), true)
		_set_busy(false)
		return

	# 通知编辑器扫描文件系统（切换分支后资源可能变化）
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.scan()

	_set_status(
		"已切换到 PR #" + str(number) + " 分支：" + branch + "（已对齐 pull/" + str(number) + "/head）"
	)
	_set_busy(false)
	# 切换后刷新列表
	_refresh_prs()
