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


func _init() -> void:
	add_child(_native)
	_native.request_completed.connect(request_completed.emit)


func request(
	url: String, headers := PackedStringArray(), method := HTTPClient.METHOD_GET, body := ""
) -> int:
	if not use_fetch or not OS.has_feature("web"):
		return _native.request(url, headers, method, body)
	if _busy:
		return ERR_BUSY
	if method not in [HTTPClient.METHOD_GET, HTTPClient.METHOD_POST]:
		return ERR_INVALID_PARAMETER
	if _bridge == null:
		JavaScriptBridge.eval(WEB_SOURCE, true)
		_bridge = JavaScriptBridge.create_object("SFDrillHttpRequest")
		_callback = JavaScriptBridge.create_callback(_on_web_completed)
	_busy = true
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
	_busy = false
	if _bridge != null:
		_bridge.call("cancel")
	_native.cancel_request()


func _on_web_completed(args: Array) -> void:
	_busy = false
	var status: float = args[1]
	request_completed.emit(
		HTTPRequest.RESULT_SUCCESS if args[0] else HTTPRequest.RESULT_CANT_CONNECT,
		int(status),
		PackedStringArray(),
		str(args[2]).to_utf8_buffer()
	)


func _exit_tree() -> void:
	cancel_request()
