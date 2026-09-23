extends SceneTree

## Rasterizes the brand vector mark (docs/assets/logo.svg) into the square
## PNGs the Godot Asset Library expects (>= 128 px, 1:1). Run from the repo
## root after editing the SVG:
##
##   godot --headless --script scripts/generate_icons.gd
##
## Godot's SVG module rasterizes vector sources at any scale, so no image
## editor or Python dependency is needed. Output is byte-stable for a given
## engine build; GitHub renders the committed PNGs.

const SOURCE := "res://docs/assets/logo.svg"
const BASE_SIZE := 64.0
const OUTPUTS := [
	[128, "res://docs/assets/icon-128.png"],
	[256, "res://docs/assets/icon-256.png"],
]


func _init() -> void:
	var svg := FileAccess.get_file_as_string(SOURCE)
	if svg.is_empty():
		push_error("missing %s" % SOURCE)
		quit(1)
		return
	var failed := false
	for output: Array in OUTPUTS:
		var size: int = output[0]
		var path: String = output[1]
		var image := Image.new()
		var err := image.load_svg_from_string(svg, float(size) / BASE_SIZE)
		if err != OK or image.is_empty():
			push_error("%s: SVG rasterization failed (%d)" % [path, err])
			failed = true
			continue
		if image.save_png(path) != OK:
			push_error("%s: save failed" % path)
			failed = true
			continue
		print("%s: %dx%d" % [path, image.get_width(), image.get_height()])
	quit(1 if failed else 0)
