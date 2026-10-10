@tool
extends VBoxContainer

## 单条 PR：先显示列表摘要，再自行异步补详情；合并/关闭/切换为图标，说明在 tooltip。

signal merge_requested(pr: Dictionary)
signal close_requested(pr: Dictionary)
signal checkout_requested(pr: Dictionary)
signal link_opened(number: int)

const _DETAIL_FIELDS := "isDraft,mergeable,mergeStateStatus,reviewDecision,additions,deletions,changedFiles,author,body,statusCheckRollup"

var pull_request: Dictionary = {}:
	set(value):
		pull_request = value.duplicate(true)
		if not is_node_ready():
			await ready
		_begin_detail_fetch()

var github_repository: String = ""
var current_branch: String = ""

var _busy := false
var _merge_blocked := false
var _details_pending := false
var _detail_token := 0
var _detail_mutex := Mutex.new()
var _detail_ready := false
var _detail_payload: Dictionary = {}


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if %Refreshing.visible:
		%Refreshing.pivot_offset = %Refreshing.size * 0.5
		%Refreshing.rotation -= delta * TAU
	var ready := false
	var payload: Dictionary = {}
	_detail_mutex.lock()
	if _detail_ready:
		ready = true
		_detail_ready = false
		payload = _detail_payload
	_detail_mutex.unlock()
	if not ready:
		if not %Refreshing.visible:
			set_process(false)
		return
	if int(payload.get("token", -1)) != _detail_token:
		return
	_details_pending = false
	if bool(payload.get("ok", false)):
		var parsed: Variant = JSON.parse_string(str(payload.get("output", "")))
		if typeof(parsed) == TYPE_DICTIONARY:
			for key in (parsed as Dictionary).keys():
				pull_request[key] = (parsed as Dictionary)[key]
		else:
			pull_request["detail_error"] = "无法解析 PR 详情"
	else:
		pull_request["detail_error"] = str(payload.get("error", "详情加载失败"))
	_apply_summary()
	_detail_mutex.lock()
	var still_pending := _detail_ready
	_detail_mutex.unlock()
	if not still_pending:
		set_process(false)


func set_busy(busy: bool) -> void:
	_busy = busy
	if not is_node_ready():
		await ready
	_apply_buttons()


func show_pull_request(summary: Dictionary, repository: String, checked_out_branch: String = "") -> void:
	github_repository = repository
	current_branch = checked_out_branch
	pull_request = summary


func request_merge() -> void:
	if pull_request.is_empty() or _merge_blocked or _details_pending:
		return
	merge_requested.emit(pull_request.duplicate(true))


func request_close() -> void:
	if pull_request.is_empty():
		return
	close_requested.emit(pull_request.duplicate(true))


func request_checkout() -> void:
	if pull_request.is_empty():
		return
	checkout_requested.emit(pull_request.duplicate(true))


func open_link() -> void:
	if pull_request.is_empty():
		return
	link_opened.emit(int(pull_request.get("number", 0)))


func _apply_summary() -> void:
	var number := int(pull_request.get("number", 0))
	var title := str(pull_request.get("title", ""))
	var branch := str(pull_request.get("headRefName", ""))
	var url := str(pull_request.get("url", ""))
	var checked_out := not branch.is_empty() and branch == current_branch
	if branch.is_empty():
		%TitleLink.text = "#%d  %s" % [number, title]
	elif checked_out:
		%TitleLink.text = "▶ " + branch
	else:
		%TitleLink.text = branch
	%TitleLink.uri = url
	if checked_out:
		var current_color := Color(0.45, 0.95, 0.5)
		%TitleLink.add_theme_color_override("font_color", current_color)
		%TitleLink.add_theme_color_override("font_hover_color", current_color)
		%TitleLink.add_theme_color_override("font_pressed_color", current_color)
	else:
		%TitleLink.remove_theme_color_override("font_color")
		%TitleLink.remove_theme_color_override("font_hover_color")
		%TitleLink.remove_theme_color_override("font_pressed_color")
	%TitleLink.disabled = url.is_empty() or _busy
	_merge_blocked = bool(pull_request.get("isDraft", false)) or _has_conflict()
	_apply_indicators()
	_apply_buttons()
	_apply_tooltips()


func _apply_indicators() -> void:
	%Refreshing.visible = _details_pending
	%Conflict.visible = not _details_pending and _has_conflict()
	%CIFailed.visible = not _details_pending and _has_ci_failure()
	if _details_pending:
		set_process(true)


func _has_conflict() -> bool:
	if str(pull_request.get("mergeable", "")) == "CONFLICTING":
		return true
	return str(pull_request.get("mergeStateStatus", "")) == "DIRTY"


func _has_ci_failure() -> bool:
	var rollup: Variant = pull_request.get("statusCheckRollup", [])
	if typeof(rollup) != TYPE_ARRAY:
		return false
	for check in rollup:
		if typeof(check) != TYPE_DICTIONARY:
			continue
		var conclusion := str(check.get("conclusion", check.get("state", ""))).to_upper()
		if conclusion in ["FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ERROR"]:
			return true
	return false


func _apply_buttons() -> void:
	%MergeButton.disabled = _busy or _merge_blocked or _details_pending
	%CloseButton.disabled = _busy
	var branch := str(pull_request.get("headRefName", ""))
	%CheckoutButton.disabled = _busy or branch.is_empty()
	%TitleLink.disabled = _busy or str(pull_request.get("url", "")).is_empty()


func _apply_tooltips() -> void:
	%TitleLink.tooltip_text = _detail_text()
	%MergeButton.tooltip_text = "合并"
	%CloseButton.tooltip_text = "关闭"
	%CheckoutButton.tooltip_text = "切换到此分支"


func _detail_text() -> String:
	var number := int(pull_request.get("number", 0))
	var title := str(pull_request.get("title", ""))
	var head := str(pull_request.get("headRefName", ""))
	var base := str(pull_request.get("baseRefName", ""))
	var lines: PackedStringArray = ["#%d  %s" % [number, title]]
	if not head.is_empty():
		lines.append("%s → %s" % [head, base])
	if _details_pending:
		lines.append("正在读取详情…")
		return "\n".join(lines)
	var detail_error := str(pull_request.get("detail_error", ""))
	if not detail_error.is_empty():
		lines.append(detail_error)
		return "\n".join(lines)
	if not pull_request.has("mergeable") and not pull_request.has("isDraft"):
		return "\n".join(lines)
	lines.append(_merge_status_text())
	var review := str(pull_request.get("reviewDecision", ""))
	if not review.is_empty():
		lines.append("审查：%s" % _review_text(review))
	if pull_request.has("additions"):
		lines.append("变更：+%d  −%d，%d 个文件" % [
			int(pull_request.get("additions", 0)),
			int(pull_request.get("deletions", 0)),
			int(pull_request.get("changedFiles", 0)),
		])
	var author: Variant = pull_request.get("author", {})
	if typeof(author) == TYPE_DICTIONARY:
		var login := str((author as Dictionary).get("login", ""))
		if not login.is_empty():
			lines.append("作者：%s" % login)
	var body := str(pull_request.get("body", "")).strip_edges()
	if not body.is_empty():
		var excerpt := body.replace("\r", "")
		if excerpt.length() > 160:
			excerpt = excerpt.substr(0, 160) + "…"
		lines.append(excerpt)
	return "\n".join(lines)


func _merge_status_text() -> String:
	if bool(pull_request.get("isDraft", false)):
		return "草稿，不能合并"
	var mergeable := str(pull_request.get("mergeable", ""))
	if mergeable == "CONFLICTING":
		return "有合并冲突，不能合并"
	if mergeable == "MERGEABLE":
		return "可以合并"
	var state := str(pull_request.get("mergeStateStatus", ""))
	if state.is_empty():
		return "合并状态未知"
	return "合并状态：%s" % state


func _review_text(review: String) -> String:
	match review:
		"APPROVED":
			return "已通过"
		"CHANGES_REQUESTED":
			return "需要修改"
		"REVIEW_REQUIRED":
			return "等待审查"
		_:
			return review


func _begin_detail_fetch() -> void:
	_detail_token += 1
	var token := _detail_token
	var number := int(pull_request.get("number", 0))
	var repository := github_repository
	pull_request.erase("detail_error")
	_details_pending = number > 0 and not repository.is_empty()
	_apply_summary()
	if not _details_pending:
		return
	set_process(true)
	WorkerThreadPool.add_task(func() -> void:
		var output: Array = []
		var exit_code := OS.execute("gh", PackedStringArray([
			"-R", repository,
			"pr", "view", str(number),
			"--json", _DETAIL_FIELDS,
		]), output, true)
		if not is_instance_valid(self):
			return
		var joined := "\n".join(output).strip_edges()
		var payload := {
			"token": token,
			"ok": exit_code == 0,
			"output": joined,
			"error": joined if not joined.is_empty() else "gh pr view 失败",
		}
		_detail_mutex.lock()
		if token == _detail_token:
			_detail_payload = payload
			_detail_ready = true
		_detail_mutex.unlock()
	)
