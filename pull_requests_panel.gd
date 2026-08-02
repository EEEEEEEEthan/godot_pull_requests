@tool
extends VBoxContainer

## Pull Requests 面板：列出 open PR，支持浏览器打开、分支下拉切换，以及对齐 PR head。

const _GH_LIST_SUBARGS: PackedStringArray = [
	"pr", "list",
	"--state", "open",
	"--json", "number,title,url,headRefName,state",
	"--limit", "100",
]

const _CHECKOUT_KIND_PR := "pr"
const _CHECKOUT_KIND_BRANCH := "branch"
## UI 源标识；用中文避免与名为 local 的 remote 混组。
const _SOURCE_LOCAL := "本地"

var _branch_menu_button: MenuButton
var _status_label: Label
var _refresh_button: Button
var _list_container: VBoxContainer
var _empty_label: Label
var _confirm_dialog: ConfirmationDialog

## 交互锁定：刷新中 / 确认框打开 / 切换分支进行中。
var _busy: bool = false
## 插件卸载或面板退出时置位，阻止 await 后继续执行破坏性 git。
var _cancelled: bool = false
## 待执行的统一切换请求（PR 或普通分支），确认框确认后使用。
var _pending_checkout: Dictionary = {}
## 缓存从 origin 解析出的 GitHub owner/repo，供 gh -R 使用。
var _cached_github_repo: String = ""


func _ready() -> void:
	_cancelled = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	_build_ui()
	_update_current_branch_label()
	# 等进入场景树后再拉列表，避免 Dock 尚未挂载时发起外部进程。
	call_deferred("_refresh_prs")


func _exit_tree() -> void:
	cancel_operations()


## 插件卸载或面板退出时调用：阻止后续破坏性 git，并断开确认框信号。
func cancel_operations() -> void:
	_cancelled = true
	_pending_checkout.clear()
	if _confirm_dialog != null and is_instance_valid(_confirm_dialog):
		if _confirm_dialog.confirmed.is_connected(_on_checkout_confirmed):
			_confirm_dialog.confirmed.disconnect(_on_checkout_confirmed)
		if _confirm_dialog.canceled.is_connected(_on_checkout_canceled):
			_confirm_dialog.canceled.disconnect(_on_checkout_canceled)
		if _confirm_dialog.visible:
			_confirm_dialog.hide()


func _build_ui() -> void:
	_branch_menu_button = MenuButton.new()
	_branch_menu_button.flat = false
	_branch_menu_button.text = "…"
	_branch_menu_button.tooltip_text = "切换到本地或远程分支（会丢弃未提交改动）"
	_branch_menu_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_branch_menu_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_branch_menu_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_branch_menu_button.get_popup().about_to_popup.connect(_on_branch_menu_about_to_popup)
	add_child(_branch_menu_button)

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
	if is_instance_valid(_branch_menu_button):
		_branch_menu_button.disabled = busy
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


func _read_current_branch_label() -> String:
	var current := _run_git(PackedStringArray(["branch", "--show-current"]))
	if current["ok"]:
		var name := str(current["output"]).strip_edges()
		if not name.is_empty() and not _has_newline(name):
			return name

	var short_sha := _run_git(PackedStringArray(["rev-parse", "--short", "HEAD"]))
	if short_sha["ok"]:
		var sha := str(short_sha["output"]).strip_edges()
		if not sha.is_empty() and not _has_newline(sha):
			return "游离 HEAD（%s）" % sha
	return "游离 HEAD"


func _update_current_branch_label() -> void:
	if not is_instance_valid(_branch_menu_button):
		return
	_branch_menu_button.text = _read_current_branch_label()


## 枚举 refs/heads 与 refs/remotes，按 source 分组；跳过 */HEAD。
## 返回 { "ok": bool, "error": String, "sources": Dictionary }。
func _collect_branches_by_source() -> Dictionary:
	var result := _run_git(PackedStringArray([
		"for-each-ref",
		"--format=%(refname)",
		"refs/heads/",
		"refs/remotes/",
	]))
	if not result["ok"]:
		return {
			"ok": false,
			"error": str(result["error"]),
			"sources": {},
		}

	var grouped: Dictionary = {}
	for line in str(result["output"]).split("\n", false):
		var refname := line.strip_edges()
		if refname.is_empty() or _has_newline(refname):
			continue
		if refname.begins_with("refs/heads/"):
			var local_branch := refname.substr("refs/heads/".length())
			if local_branch.is_empty() or local_branch.ends_with("/HEAD"):
				continue
			_append_branch_for_source(grouped, _SOURCE_LOCAL, local_branch)
		elif refname.begins_with("refs/remotes/"):
			var remote_path := refname.substr("refs/remotes/".length())
			if remote_path.is_empty() or remote_path.ends_with("/HEAD"):
				continue
			var slash := remote_path.find("/")
			if slash <= 0 or slash >= remote_path.length() - 1:
				continue
			var remote_name := remote_path.substr(0, slash)
			var remote_branch := remote_path.substr(slash + 1)
			if remote_name.is_empty() or remote_branch.is_empty():
				continue
			if _has_newline(remote_name) or _has_newline(remote_branch):
				continue
			_append_branch_for_source(grouped, remote_name, remote_branch)
	return {
		"ok": true,
		"error": "",
		"sources": grouped,
	}


func _append_branch_for_source(grouped: Dictionary, source: String, branch: String) -> void:
	if not grouped.has(source):
		grouped[source] = []
	var branches: Array = grouped[source]
	if not branches.has(branch):
		branches.append(branch)


## 按分支名 `/` 分段建树。节点：{ "leaf": String, "children": Dictionary }
func _build_branch_tree(branch_names: Array) -> Dictionary:
	var root := {"leaf": "", "children": {}}
	var sorted_names := branch_names.duplicate()
	sorted_names.sort()
	for branch_name in sorted_names:
		var name := str(branch_name)
		if name.is_empty():
			continue
		var node: Dictionary = root
		var segments := name.split("/")
		for segment_index in segments.size():
			var segment := str(segments[segment_index])
			if segment.is_empty():
				continue
			var children: Dictionary = node["children"]
			if not children.has(segment):
				children[segment] = {"leaf": "", "children": {}}
			node = children[segment]
		node["leaf"] = name
	return root


func _on_branch_menu_about_to_popup() -> void:
	if _busy or _cancelled:
		return
	_rebuild_branch_menu()


func _rebuild_branch_menu() -> void:
	var popup := _branch_menu_button.get_popup()
	# free_submenus=true，避免反复打开造成 PopupMenu 泄漏。
	popup.clear(true)

	var collection := _collect_branches_by_source()
	if not collection["ok"]:
		var error_message := str(collection["error"])
		if error_message.is_empty():
			error_message = "git for-each-ref 失败"
		_set_status("枚举分支失败：" + error_message, true)
		popup.add_item("枚举失败：" + error_message)
		popup.set_item_disabled(0, true)
		return

	var grouped: Dictionary = collection["sources"]
	var source_names: Array = grouped.keys()
	source_names.sort_custom(func(a: Variant, b: Variant) -> bool:
		var left := str(a)
		var right := str(b)
		if left == _SOURCE_LOCAL:
			return true
		if right == _SOURCE_LOCAL:
			return false
		return left < right
	)

	if source_names.is_empty():
		popup.add_item("（无可用分支）")
		popup.set_item_disabled(0, true)
		return

	for source_name in source_names:
		var branches: Array = grouped[source_name]
		if branches.is_empty():
			continue
		var source_menu := PopupMenu.new()
		_populate_branch_tree_menu(source_menu, _build_branch_tree(branches), str(source_name))
		popup.add_submenu_node_item(str(source_name), source_menu)


func _populate_branch_tree_menu(menu: PopupMenu, tree_node: Dictionary, source: String) -> void:
	menu.index_pressed.connect(_on_branch_menu_index_pressed.bind(menu))

	var children: Dictionary = tree_node.get("children", {})
	var segment_names: Array = children.keys()
	segment_names.sort()
	for segment_name in segment_names:
		var child_node: Dictionary = children[segment_name]
		var leaf_branch := str(child_node.get("leaf", ""))
		var grand_children: Dictionary = child_node.get("children", {})
		var has_leaf := not leaf_branch.is_empty()
		var has_children := not grand_children.is_empty()

		if has_leaf:
			var leaf_label := str(segment_name)
			# 与同名子菜单并存时，叶子标明「分支」以便区分。
			if has_children:
				leaf_label = "%s（分支）" % segment_name
			menu.add_item(leaf_label)
			var leaf_index := menu.item_count - 1
			menu.set_item_metadata(leaf_index, {
				"kind": _CHECKOUT_KIND_BRANCH,
				"source": source,
				"branch": leaf_branch,
			})

		if has_children:
			var child_menu := PopupMenu.new()
			_populate_branch_tree_menu(child_menu, child_node, source)
			var submenu_label := str(segment_name)
			if has_leaf:
				submenu_label = "%s/" % segment_name
			menu.add_submenu_node_item(submenu_label, child_menu)


func _on_branch_menu_index_pressed(index: int, menu: PopupMenu) -> void:
	if _busy or _cancelled:
		return
	if not is_instance_valid(menu):
		return
	if index < 0 or index >= menu.item_count:
		return
	var metadata: Variant = menu.get_item_metadata(index)
	if typeof(metadata) != TYPE_DICTIONARY:
		return
	var checkout: Dictionary = metadata
	if checkout.is_empty():
		return
	_request_checkout(checkout)


func _refresh_prs() -> void:
	if _busy or _cancelled:
		return

	_set_busy(true)
	_update_current_branch_label()
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
	checkout_button.pressed.connect(_on_checkout_pr_pressed.bind(pr.duplicate(true)))
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


func _on_checkout_pr_pressed(pr: Dictionary) -> void:
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

	_request_checkout({
		"kind": _CHECKOUT_KIND_PR,
		"number": number,
		"title": title,
		"branch": branch,
	})


func _request_checkout(checkout: Dictionary) -> void:
	if _busy or _cancelled:
		return

	var kind := str(checkout.get("kind", ""))
	if kind == _CHECKOUT_KIND_PR:
		var number: int = int(checkout.get("number", 0))
		var title := str(checkout.get("title", ""))
		var branch := str(checkout.get("branch", ""))
		_pending_checkout = checkout.duplicate(true)
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
		return

	if kind == _CHECKOUT_KIND_BRANCH:
		var source := str(checkout.get("source", ""))
		var branch := str(checkout.get("branch", ""))
		if source.is_empty() or branch.is_empty():
			_set_status("分支信息不完整，无法切换", true)
			return
		if _has_newline(source) or _has_newline(branch):
			_set_status("分支名或远程名含换行，已拒绝切换", true)
			return

		_pending_checkout = checkout.duplicate(true)
		_set_busy(true)
		var source_line := "%s / %s" % [source, branch]
		var fetch_hint := ""
		if source != _SOURCE_LOCAL:
			fetch_hint = (
				"\n将先 fetch %s %s，再清理工作区并以该远程分支创建/覆盖本地同名分支。\n"
				% [source, branch]
			)
		_confirm_dialog.dialog_text = (
			"即将切换到分支：\n"
			+ source_line
			+ "\n"
			+ fetch_hint
			+ "\n警告：此操作会丢弃本地所有未提交的改动（含未跟踪文件）。\n\n"
			+ "确定继续吗？"
		)
		_confirm_dialog.popup_centered()
		return

	_set_status("未知的切换类型，已忽略", true)


func _on_checkout_canceled() -> void:
	# 仅在仍停留在确认阶段时解锁；切换流程中途不应由此路径误解锁。
	if _pending_checkout.is_empty():
		return
	_pending_checkout.clear()
	if _still_alive():
		_set_busy(false)
		_set_status("已取消切换分支")


func _on_checkout_confirmed() -> void:
	if _cancelled:
		return
	if _pending_checkout.is_empty():
		return

	var checkout := _pending_checkout.duplicate(true)
	_pending_checkout.clear()

	var kind := str(checkout.get("kind", ""))
	if kind == _CHECKOUT_KIND_PR:
		await _execute_pr_checkout(checkout)
	elif kind == _CHECKOUT_KIND_BRANCH:
		await _execute_branch_checkout(checkout)
	else:
		_set_status("未知的切换类型，已取消切换", true)
		_set_busy(false)


func _execute_pr_checkout(checkout: Dictionary) -> void:
	var number: int = int(checkout.get("number", 0))
	var branch := str(checkout.get("branch", ""))
	if number <= 0:
		_set_status("无效的 PR 编号，已取消切换", true)
		_set_busy(false)
		return
	if branch.is_empty() or _has_newline(branch):
		_set_status("分支名无效，已取消切换", true)
		_set_busy(false)
		return

	_set_status("正在对齐 PR #" + str(number) + " 的 head…")
	if not await _yield_ui():
		return

	var pull_ref := "pull/%d/head" % number
	if not await _run_git_step(
			PackedStringArray(["fetch", "origin", pull_ref]),
			"git fetch " + pull_ref,
	):
		return
	if not await _run_destructive_workspace_clean():
		return

	if not await _run_git_step(
			PackedStringArray(["checkout", "-B", branch, "FETCH_HEAD"]),
			"git checkout",
	):
		return

	_finish_checkout_success(
		"已切换到 PR #" + str(number) + " 分支：" + branch
		+ "（已对齐 pull/" + str(number) + "/head）"
	)


func _execute_branch_checkout(checkout: Dictionary) -> void:
	var source := str(checkout.get("source", ""))
	var branch := str(checkout.get("branch", ""))
	if source.is_empty() or branch.is_empty():
		_set_status("分支信息不完整，已取消切换", true)
		_set_busy(false)
		return
	if _has_newline(source) or _has_newline(branch):
		_set_status("分支名或远程名含换行，已取消切换", true)
		_set_busy(false)
		return

	_set_status("正在切换到 %s / %s…" % [source, branch])
	if not await _yield_ui():
		return

	if source == _SOURCE_LOCAL:
		if not await _run_destructive_workspace_clean():
			return
		if not await _run_git_step(
				PackedStringArray(["checkout", branch]),
				"git checkout",
		):
			return
	else:
		# 与 PR 路径一致：对齐刚 fetch 的 FETCH_HEAD，避免非默认 refspec 下读到过期 remote-tracking。
		if not await _run_git_step(
				PackedStringArray(["fetch", source, branch]),
				"git fetch %s %s" % [source, branch],
		):
			return
		if not await _run_destructive_workspace_clean():
			return
		if not await _run_git_step(
				PackedStringArray(["checkout", "-B", branch, "FETCH_HEAD"]),
				"git checkout",
		):
			return

	_finish_checkout_success("已切换到分支：%s / %s" % [source, branch])


## reset --hard + clean -fd；任一步失败则解锁并返回 false。
func _run_destructive_workspace_clean() -> bool:
	if not await _run_git_step(
			PackedStringArray(["reset", "--hard"]),
			"git reset --hard",
	):
		return false
	return await _run_git_step(
			PackedStringArray(["clean", "-fd"]),
			"git clean -fd",
	)


## 执行一步 git；失败时写状态并解锁。面板已卸载时返回 false。
func _run_git_step(arguments: PackedStringArray, failure_prefix: String) -> bool:
	var result := _run_git(arguments)
	if not _still_alive():
		return false
	if not result["ok"]:
		_set_status(failure_prefix + " 失败：" + str(result["error"]), true)
		_set_busy(false)
		return false
	return true


func _finish_checkout_success(message: String) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.scan()

	_update_current_branch_label()
	_set_status(message)
	_set_busy(false)
	_refresh_prs()
