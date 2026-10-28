extends Node

signal request_completed(
	result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray
)

const WEB_SOURCE := """
window.SFDrillHttpRequest = function () {
  let active = null;
  return {
    request(url, method, body, headers, callback) {
      const controller = new AbortController();
      active = controller;
      Promise.resolve().then(async () => {
        const response = await fetch(url, {
          method, signal: controller.signal,
          headers: JSON.parse(headers).map((header) => {
            const colon = header.indexOf(":");
            return [header.slice(0, colon), header.slice(colon + 1).trim()];
          }),
          ...(method === "POST" ? {body} : {}),
        });
        const text = await response.text();
        if (active !== controller) return;
        active = null;
        callback(true, response.status, text);
      }).catch(() => {
        if (active !== controller) return;
        active = null;
        callback(false, 0, "");
      });
    },
    cancel() {
      const controller = active;
      active = null;
      controller?.abort();
    },
  };
};
"""

var use_fetch := false
var _native := HTTPRequest.new()
var _bridge: JavaScriptObject
var _callback: JavaScriptObject
var _busy := false
var _active: Dictionary = {}
var _recent: Array[Dictionary] = []
var _markers: Array[Dictionary] = []
var _marker_overflow := 0
var _completed := 0
var _last_status := -1


func _init() -> void:
	add_child(_native)
	_native.request_completed.connect(_on_native_completed)


func request(
	url: String, headers := PackedStringArray(), method := HTTPClient.METHOD_GET, body := ""
) -> int:
	if _busy:
		return ERR_BUSY
	var fetch_backend := use_fetch and OS.has_feature("web")
	if fetch_backend and method not in [HTTPClient.METHOD_GET, HTTPClient.METHOD_POST]:
		return ERR_INVALID_PARAMETER
	_active = {
		"method": method,
		"seat": url.get_file(),
		"started": _stamp(),
		"states": [],
		"states_omitted": 0,
		"markers": [],
		"backend": "fetch" if fetch_backend else "http_request",
	}
	_busy = true
	_last_status = -1
	if method == HTTPClient.METHOD_POST:
		_record_markers(body)
	if not fetch_backend:
		var error := _native.request(url, headers, method, body)
		if error != OK:
			_active.clear()
			_busy = false
		else:
			_record_state()
		return error
	if _bridge == null:
		JavaScriptBridge.eval(WEB_SOURCE, true)
		_bridge = JavaScriptBridge.create_object("SFDrillHttpRequest")
		_callback = JavaScriptBridge.create_callback(_on_web_completed)
	_bridge.call(
		"request",
		url,
		"POST" if method == HTTPClient.METHOD_POST else "GET",
		body,
		JSON.stringify(Array(headers)),
		_callback
	)
	return OK


func cancel_request() -> void:
	if _busy:
		_active["cancelled"] = _stamp()
		_retain_request()
	_busy = false
	if _bridge != null:
		_bridge.call("cancel")
	_native.cancel_request()


func _on_web_completed(args: Array) -> void:
	var status: float = args[1]
	_on_native_completed(
		HTTPRequest.RESULT_SUCCESS if args[0] else HTTPRequest.RESULT_CANT_CONNECT,
		int(status),
		PackedStringArray(),
		str(args[2]).to_utf8_buffer()
	)


func evidence(include_history := true) -> Dictionary:
	return {
		"active": _active.duplicate(true),
		"completed": _completed,
		"recent": _recent.duplicate(true) if include_history else [],
		"marker_requests": _markers.duplicate(true) if include_history else [],
		"history_included": include_history,
		"marker_count": _markers.size(),
		"marker_overflow": _marker_overflow,
	}


func _stamp() -> Dictionary:
	return {
		"tick_ms": Time.get_ticks_msec(),
		"frame": Engine.get_process_frames(),
		"browser_ms": JavaScriptBridge.eval("performance.now()") if OS.has_feature("web") else null,
	}


func _process(_delta: float) -> void:
	if _busy and _active.get("backend") == "http_request":
		_record_state()


func _record_state() -> void:
	var status := _native.get_http_client_status()
	var states: Array = _active["states"]
	if status != _last_status:
		_last_status = status
		var sample := _stamp()
		sample["status"] = status
		if states.size() < 32:
			states.append(sample)
		else:
			_active["states_omitted"] += 1


func _record_markers(body: String) -> void:
	var payload: Variant = JSON.parse_string(body)
	var messages: Array = payload if payload is Array else [payload]
	var markers: Array = _active["markers"]
	for message: Variant in messages:
		if message is Dictionary:
			var item: Dictionary = message
			if item.get("marker") is String:
				markers.append(item["marker"])


func _retain_request() -> void:
	_recent.append(_active)
	if _recent.size() > 16:
		_recent.pop_front()
	var markers: Array = _active["markers"]
	if not markers.is_empty():
		if _markers.size() < 256:
			_markers.append(_active)
		else:
			_marker_overflow += 1
	_active = {}


func _on_native_completed(
	result: int, code: int, headers: PackedStringArray, body: PackedByteArray
) -> void:
	if not _busy:
		return
	if _active["method"] == HTTPClient.METHOD_GET and result == HTTPRequest.RESULT_SUCCESS:
		_record_markers(body.get_string_from_utf8())
	_active["completed"] = _stamp()
	_active["result"] = result
	_active["http_code"] = code
	_completed += 1
	_retain_request()
	_busy = false
	request_completed.emit(result, code, headers, body)


func _exit_tree() -> void:
	cancel_request()
