@tool
extends VBoxContainer

## Pull Requests 面板：列出 open PR，分支名可在浏览器打开，支持合并/关闭，以及分支下拉切换与对齐 PR head。

const _GH_LIST_SUBARGS: PackedStringArray = [
	"pr", "list",
	"--state", "open",
	"--json", "number,title,url,headRefName,baseRefName,state,mergeable,isDraft",
	"--limit", "100",
]

const _ACTION_CHECKOUT := "checkout"
const _ACTION_MERGE := "merge"
const _ACTION_CLOSE := "close"
const _MERGE_FLAG_MERGE := "--merge"
const _MERGE_FLAG_SQUASH := "--squash"
const _MERGE_FLAG_REBASE := "--rebase"

const _CHECKOUT_KIND_PR := "pr"
const _CHECKOUT_KIND_BRANCH := "branch"
## UI 源标识；用中文避免与名为 local 的 remote 混组。
const _SOURCE_LOCAL := "本地"

const _PrRow := preload("pr_row.gd")
const _PR_ROW_SCENE := preload("pr_row.tscn")

@onready var _branch_option: OptionButton = %BranchOptionButton
@onready var _status_label: Label = %StatusLabel
@onready var _refresh_button: Button = %RefreshButton
@onready var _list_container: VBoxContainer = %ListContainer
@onready var _empty_label: Label = %EmptyLabel
@onready var _confirm_dialog: ConfirmationDialog = %ConfirmDialog

## 交互锁定：刷新中 / 确认框打开 / 切换、合并、关闭进行中。
var _busy: bool = false
## 插件卸载或面板退出时置位，阻止 await 后继续执行破坏性 git。
var _cancelled: bool = false
## 待执行的统一操作（切换 / 合并 / 关闭），确认框确认后使用。
var _pending_action: Dictionary = {}
## 缓存从 origin 解析出的 GitHub owner/repo，供 gh -R 使用。
var _cached_github_repo: String = ""
## 缓存仓库允许的非交互合并策略（--merge / --squash / --rebase）。
var _cached_merge_flag: String = ""
## 重建 OptionButton 项时置位，避免 item_selected 误触发切换（select 本身不 emit，热重载/版本兜底）。
var _suppress_branch_selected: bool = false


func _ready() -> void:
	_cancelled = false
	# PopupMenu 由 OptionButton 内部创建，不便放进 tscn；打开时再 rebuild，保证 refs 最新（不 fetch --all）。
	var branch_popup := _branch_option.get_popup()
	if not branch_popup.about_to_popup.is_connected(_on_branch_option_about_to_popup):
		branch_popup.about_to_popup.connect(_on_branch_option_about_to_popup)
	_rebuild_branch_options()
	# 等进入场景树后再拉列表，避免 Dock 尚未挂载时发起外部进程。
	call_deferred("_refresh_prs")


func _exit_tree() -> void:
	cancel_operations()


## 插件卸载或面板退出时调用：阻止后续破坏性 git，并断开确认框信号。
func cancel_operations() -> void:
	_cancelled = true
	_pending_action.clear()
	if _confirm_dialog != null and is_instance_valid(_confirm_dialog):
		if _confirm_dialog.confirmed.is_connected(_on_action_confirmed):
			_confirm_dialog.confirmed.disconnect(_on_action_confirmed)
		if _confirm_dialog.canceled.is_connected(_on_action_canceled):
			_confirm_dialog.canceled.disconnect(_on_action_canceled)
		if _confirm_dialog.visible:
			_confirm_dialog.hide()


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
	if is_instance_valid(_branch_option):
		if busy:
			_branch_option.disabled = true
		else:
			# 取消确认 / checkout 失败后，选中项可能停在用户点过的分支，需回到真实当前分支。
			_rebuild_branch_options()
			if is_instance_valid(_branch_option):
				_branch_option.disabled = false
	if not is_instance_valid(_list_container):
		return
	for child in _list_container.get_children():
		if child == _empty_label:
			continue
		var row := child as _PrRow
		if row != null:
			row.set_busy(busy)
		elif child.has_method("set_busy"):
			# @tool 热重载后脚本身份可能对不上 as _PrRow，退回按方法调用。
			child.call("set_busy", busy)


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


## 执行一步 gh；失败时写状态并解锁。面板已卸载时返回 false。
func _run_gh_step(arguments: PackedStringArray, failure_prefix: String) -> bool:
	var result := _run_gh(arguments)
	if not _still_alive():
		return false
	if not result["ok"]:
		_set_status(failure_prefix + " 失败：" + str(result["error"]), true)
		_set_busy(false)
		return false
	return true


## 查询并缓存仓库允许的合并策略；优先 merge > squash > rebase。失败则默认 --merge。
func _resolve_merge_flag() -> String:
	if not _cached_merge_flag.is_empty():
		return _cached_merge_flag

	var result := _run_gh(PackedStringArray([
		"repo", "view",
		"--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed",
	]))
	if not result["ok"]:
		return _MERGE_FLAG_MERGE

	var parsed: Variant = JSON.parse_string(str(result["output"]))
	if typeof(parsed) != TYPE_DICTIONARY:
		return _MERGE_FLAG_MERGE

	var info: Dictionary = parsed
	var flag := _MERGE_FLAG_MERGE
	if bool(info.get("mergeCommitAllowed", false)):
		flag = _MERGE_FLAG_MERGE
	elif bool(info.get("squashMergeAllowed", false)):
		flag = _MERGE_FLAG_SQUASH
	elif bool(info.get("rebaseMergeAllowed", false)):
		flag = _MERGE_FLAG_REBASE
	_cached_merge_flag = flag
	return flag


func _merge_flag_label(flag: String) -> String:
	match flag:
		_MERGE_FLAG_SQUASH:
			return "squash（压缩）"
		_MERGE_FLAG_REBASE:
			return "rebase（变基）"
		_:
			return "merge（合并提交）"


func _clear_list_rows() -> void:
	for child in _list_container.get_children():
		if child == _empty_label:
			continue
		_list_container.remove_child(child)
		child.queue_free()


## 当前已检出的本地分支名；游离 HEAD 或失败时返回空串。
func _read_current_local_branch() -> String:
	var current := _run_git(PackedStringArray(["branch", "--show-current"]))
	if current["ok"]:
		var name := str(current["output"]).strip_edges()
		if not name.is_empty() and not _has_newline(name):
			return name
	return ""


func _read_current_branch_label() -> String:
	var name := _read_current_local_branch()
	if not name.is_empty():
		return name

	var short_sha := _run_git(PackedStringArray(["rev-parse", "--short", "HEAD"]))
	if short_sha["ok"]:
		var sha := str(short_sha["output"]).strip_edges()
		if not sha.is_empty() and not _has_newline(sha):
			return "游离 HEAD（%s）" % sha
	return "游离 HEAD"


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


func _sorted_source_names(grouped: Dictionary) -> Array:
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
	return source_names


func _on_branch_option_about_to_popup() -> void:
	if _busy or _cancelled:
		return
	_rebuild_branch_options()


## 扁平列出全部本地/远程分支，并选中当前本地分支（对不上则在最前加禁用的当前标签）。
func _rebuild_branch_options() -> void:
	if not is_instance_valid(_branch_option):
		return
	_suppress_branch_selected = true
	_fill_branch_options()
	_suppress_branch_selected = false


func _fill_branch_options() -> void:
	_branch_option.clear()

	var collection := _collect_branches_by_source()
	if not collection["ok"]:
		var error_message := str(collection["error"])
		if error_message.is_empty():
			error_message = "git for-each-ref 失败"
		_set_status("枚举分支失败：" + error_message, true)
		_add_disabled_branch_item("枚举失败：" + error_message)
		_branch_option.select(0)
		return

	var grouped: Dictionary = collection["sources"]
	var source_names := _sorted_source_names(grouped)
	if source_names.is_empty():
		_add_disabled_branch_item("（无可用分支）")
		_branch_option.select(0)
		return

	var current_local := _read_current_local_branch()
	var has_local_match := false
	if not current_local.is_empty() and grouped.has(_SOURCE_LOCAL):
		var local_branches: Array = grouped[_SOURCE_LOCAL]
		has_local_match = local_branches.has(current_local)

	# 游离 HEAD 或当前名对不上本地项：最前加禁用标签，供 OptionButton 显示（禁止手写 text）。
	if not has_local_match:
		_add_disabled_branch_item(_read_current_branch_label())

	var select_index := 0 if not has_local_match else -1
	for source_name in source_names:
		var branches: Array = grouped[source_name].duplicate()
		if branches.is_empty():
			continue
		branches.sort()
		var source := str(source_name)
		for branch_name in branches:
			var branch := str(branch_name)
			if branch.is_empty():
				continue
			var label := branch if source == _SOURCE_LOCAL else "%s/%s" % [source, branch]
			_branch_option.add_item(label)
			var idx := _branch_option.item_count - 1
			_branch_option.set_item_metadata(idx, {
				"kind": _CHECKOUT_KIND_BRANCH,
				"source": source,
				"branch": branch,
			})
			_branch_option.set_item_auto_translate_mode(idx, Node.AUTO_TRANSLATE_MODE_DISABLED)
			if has_local_match and source == _SOURCE_LOCAL and branch == current_local:
				select_index = idx

	if _branch_option.item_count <= 0:
		_add_disabled_branch_item("（无可用分支）")
		_branch_option.select(0)
		return
	if select_index >= 0:
		_branch_option.select(select_index)


func _add_disabled_branch_item(label: String) -> void:
	_branch_option.add_item(label)
	var idx := _branch_option.item_count - 1
	_branch_option.set_item_disabled(idx, true)
	_branch_option.set_item_auto_translate_mode(idx, Node.AUTO_TRANSLATE_MODE_DISABLED)


func _on_branch_item_selected(index: int) -> void:
	if _suppress_branch_selected or _busy or _cancelled:
		return
	if not is_instance_valid(_branch_option):
		return
	if index < 0 or index >= _branch_option.item_count:
		_rebuild_branch_options()
		return
	if _branch_option.is_item_disabled(index) or _branch_option.is_item_separator(index):
		_rebuild_branch_options()
		return
	var metadata: Variant = _branch_option.get_item_metadata(index)
	if typeof(metadata) != TYPE_DICTIONARY:
		_rebuild_branch_options()
		return
	var checkout: Dictionary = metadata
	# 已在该本地分支上则不弹确认。
	if (
			str(checkout.get("source", "")) == _SOURCE_LOCAL
			and str(checkout.get("branch", "")) == _read_current_local_branch()
			and not str(checkout.get("branch", "")).is_empty()
	):
		return
	_request_checkout(checkout)


func _refresh_prs() -> void:
	if _busy or _cancelled:
		return

	_set_busy(true)
	_rebuild_branch_options()
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

	if _cached_merge_flag.is_empty():
		_resolve_merge_flag()

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
		_make_pr_row(pr)

	_set_status("共 %d 个打开的 Pull Request" % open_prs.size())
	_set_busy(false)


func _make_pr_row(pr: Dictionary) -> void:
	var row := _PR_ROW_SCENE.instantiate() as _PrRow
	if row == null:
		push_error("无法实例化 PR 行场景 pr_row.tscn")
		return
	row.merge_requested.connect(_on_merge_pr_pressed)
	row.close_requested.connect(_on_close_pr_pressed)
	row.checkout_requested.connect(_on_checkout_pr_pressed)
	row.link_opened.connect(_on_pr_link_pressed)
	_list_container.add_child(row)
	row.configure(pr)


func _on_pr_link_pressed(number: int) -> void:
	if _busy or _cancelled:
		return
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


func _on_merge_pr_pressed(pr: Dictionary) -> void:
	if _busy or _cancelled:
		return

	var number: int = int(pr.get("number", 0))
	var title := str(pr.get("title", ""))
	if number <= 0:
		_set_status("无效的 PR 编号，无法合并", true)
		return
	if bool(pr.get("isDraft", false)):
		_set_status("草稿 PR 不能合并", true)
		return
	if str(pr.get("mergeable", "")) == "CONFLICTING":
		_set_status("此 PR 有合并冲突，无法合并", true)
		return

	var merge_flag := _resolve_merge_flag()
	if merge_flag != _MERGE_FLAG_MERGE and merge_flag != _MERGE_FLAG_SQUASH and merge_flag != _MERGE_FLAG_REBASE:
		merge_flag = _MERGE_FLAG_MERGE

	_popup_pending_action({
		"type": _ACTION_MERGE,
		"number": number,
		"title": title,
		"merge_flag": merge_flag,
		"base": str(pr.get("baseRefName", "")),
	})


func _on_close_pr_pressed(pr: Dictionary) -> void:
	if _busy or _cancelled:
		return

	var number: int = int(pr.get("number", 0))
	var title := str(pr.get("title", ""))
	if number <= 0:
		_set_status("无效的 PR 编号，无法关闭", true)
		return

	_popup_pending_action({
		"type": _ACTION_CLOSE,
		"number": number,
		"title": title,
	})


func _request_checkout(checkout: Dictionary) -> void:
	if _busy or _cancelled:
		return

	var action := checkout.duplicate(true)
	action["type"] = _ACTION_CHECKOUT
	_popup_pending_action(action)


## 按操作类型配置确认框并弹出；确认/取消走统一 handler。
func _popup_pending_action(action: Dictionary) -> void:
	if _busy or _cancelled:
		return

	var action_type := str(action.get("type", ""))
	if action_type == _ACTION_CHECKOUT:
		var kind := str(action.get("kind", ""))
		if kind == _CHECKOUT_KIND_PR:
			var number: int = int(action.get("number", 0))
			var title := str(action.get("title", ""))
			var branch := str(action.get("branch", ""))
			_confirm_dialog.title = "确认切换分支"
			_confirm_dialog.ok_button_text = "丢弃并切换"
			_confirm_dialog.dialog_text = (
				"即将切换到 PR #" + str(number) + "「" + title + "」的分支：\n"
				+ branch
				+ "\n\n将通过 pull/" + str(number) + "/head 对齐该 PR 的最新 head"
				+ "（兼容 fork / 跨仓 PR）。\n\n"
				+ "警告：此操作会丢弃本地所有未提交的改动（含未跟踪文件），"
				+ "并覆盖本地同名分支。\n\n"
				+ "确定继续吗？"
			)
		elif kind == _CHECKOUT_KIND_BRANCH:
			var source := str(action.get("source", ""))
			var branch := str(action.get("branch", ""))
			if source.is_empty() or branch.is_empty():
				_set_status("分支信息不完整，无法切换", true)
				return
			if _has_newline(source) or _has_newline(branch):
				_set_status("分支名或远程名含换行，已拒绝切换", true)
				return
			_confirm_dialog.title = "确认切换分支"
			_confirm_dialog.ok_button_text = "丢弃并切换"
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
		else:
			_set_status("未知的切换类型，已忽略", true)
			return
	elif action_type == _ACTION_MERGE:
		var number: int = int(action.get("number", 0))
		var title := str(action.get("title", ""))
		var merge_flag := str(action.get("merge_flag", _MERGE_FLAG_MERGE))
		var base := str(action.get("base", ""))
		_confirm_dialog.title = "确认合并"
		_confirm_dialog.ok_button_text = "合并"
		var target_line := ""
		if not base.is_empty():
			target_line = "到分支 " + base
		_confirm_dialog.dialog_text = (
			"即将合并 PR #" + str(number) + "「" + title + "」" + target_line + "。\n"
			+ "将使用 " + _merge_flag_label(merge_flag) + " 方式（" + merge_flag + "）。\n\n"
			+ "确定继续吗？"
		)
	elif action_type == _ACTION_CLOSE:
		var number: int = int(action.get("number", 0))
		var title := str(action.get("title", ""))
		_confirm_dialog.title = "确认关闭"
		_confirm_dialog.ok_button_text = "关闭"
		_confirm_dialog.dialog_text = (
			"即将关闭 PR #" + str(number) + "「" + title + "」。\n\n"
			+ "确定继续吗？"
		)
	else:
		_set_status("未知的操作类型，已忽略", true)
		return

	_pending_action = action.duplicate(true)
	_set_busy(true)
	_confirm_dialog.popup_centered()


func _on_action_canceled() -> void:
	# 仅在仍停留在确认阶段时解锁；执行流程中途不应由此路径误解锁。
	if _pending_action.is_empty():
		return
	var action_type := str(_pending_action.get("type", ""))
	_pending_action.clear()
	if not _still_alive():
		return
	_set_busy(false)
	if action_type == _ACTION_MERGE:
		_set_status("已取消合并")
	elif action_type == _ACTION_CLOSE:
		_set_status("已取消关闭")
	else:
		_set_status("已取消切换分支")


func _on_action_confirmed() -> void:
	if _cancelled:
		return
	if _pending_action.is_empty():
		return

	var action := _pending_action.duplicate(true)
	_pending_action.clear()

	var action_type := str(action.get("type", ""))
	if action_type == _ACTION_CHECKOUT:
		var kind := str(action.get("kind", ""))
		if kind == _CHECKOUT_KIND_PR:
			await _execute_pr_checkout(action)
		elif kind == _CHECKOUT_KIND_BRANCH:
			await _execute_branch_checkout(action)
		else:
			_set_status("未知的切换类型，已取消切换", true)
			_set_busy(false)
	elif action_type == _ACTION_MERGE:
		await _execute_pr_merge(action)
	elif action_type == _ACTION_CLOSE:
		await _execute_pr_close(action)
	else:
		_set_status("未知的操作类型，已取消", true)
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


func _execute_pr_merge(action: Dictionary) -> void:
	var number: int = int(action.get("number", 0))
	var merge_flag := str(action.get("merge_flag", _MERGE_FLAG_MERGE))
	if number <= 0:
		_set_status("无效的 PR 编号，已取消合并", true)
		_set_busy(false)
		return
	if merge_flag != _MERGE_FLAG_MERGE and merge_flag != _MERGE_FLAG_SQUASH and merge_flag != _MERGE_FLAG_REBASE:
		merge_flag = _MERGE_FLAG_MERGE

	_set_status("正在合并 PR #" + str(number) + "…")
	if not await _yield_ui():
		return

	if not await _run_gh_step(
			PackedStringArray(["pr", "merge", str(number), merge_flag]),
			"gh pr merge",
	):
		return

	_set_status("已合并 PR #" + str(number))
	_set_busy(false)
	_refresh_prs()


func _execute_pr_close(action: Dictionary) -> void:
	var number: int = int(action.get("number", 0))
	if number <= 0:
		_set_status("无效的 PR 编号，已取消关闭", true)
		_set_busy(false)
		return

	_set_status("正在关闭 PR #" + str(number) + "…")
	if not await _yield_ui():
		return

	if not await _run_gh_step(
			PackedStringArray(["pr", "close", str(number)]),
			"gh pr close",
	):
		return

	_set_status("已关闭 PR #" + str(number))
	_set_busy(false)
	_refresh_prs()


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

	_rebuild_branch_options()
	_set_status(message)
	_set_busy(false)
	_refresh_prs()
