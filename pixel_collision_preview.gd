@tool
extends Control

## 预览控件：把图块贴图、识别出的像素掩码、以及生成的碰撞多边形画在一起。

## 要显示的图块贴图（可选，不做翻转）。
var tile_texture: Texture2D:
	set(value):
		tile_texture = value
		queue_redraw()

## 生成器实例（调用 get_grid()/get_grid_size() 取掩码，可选）。
var generator: RefCounted:
	set(value):
		generator = value
		queue_redraw()

## 要叠加显示的多边形（Godot 图块本地坐标：原点在图块中心，y 向下为正）。
var polygons: Array = []:
	set(value):
		polygons = value
		queue_redraw()

## 图块尺寸（像素），用于换算本地坐标。
var tile_size := Vector2(1, 1):
	set(value):
		tile_size = value
		queue_redraw()

## 是否显示识别到的像素掩码。
var show_mask := true:
	set(value):
		show_mask = value
		queue_redraw()

## 是否显示多边形轮廓。
var show_polygons := true:
	set(value):
		show_polygons = value
		queue_redraw()

var mask_color := Color(0.25, 1.0, 0.45, 0.22)
var polygon_color := Color(1.0, 0.85, 0.2, 1.0)
var polygon_color_length_portions := 3.0
var outline_color := Color(0.15, 0.95, 0.45, 0.9)
var empty_text := "在左侧选择一张图块以查看预览"


func clear() -> void:
	tile_texture = null
	generator = null
	polygons = []
	queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(120, 120)


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	draw_rect(area, Color(0.11, 0.11, 0.13, 1.0), true)
	_draw_checkerboard(area)

	var content := _content_rect()
	if tile_texture != null:
		# 图块本地坐标（原点中心、y 向下）-> 控件屏幕坐标（原点左上、y 向下）
		var scale_x := content.size.x / maxf(tile_size.x, 1.0)
		var scale_y := content.size.y / maxf(tile_size.y, 1.0)
		var half := Vector2(tile_size.x, tile_size.y) * 0.5
		var to_screen := func(p: Vector2) -> Vector2:
			return content.position + Vector2((p.x + half.x) * scale_x, (p.y + half.y) * scale_y)
		draw_texture_rect(tile_texture, content, false)
		if show_mask and generator != null and generator.has_method("get_grid"):
			_draw_mask(content, scale_x, scale_y)
		if show_polygons:
			for poly in polygons:
				if poly.size() < 3:
					continue
				var pts := PackedVector2Array()
				for p in poly:
					pts.append(to_screen.call(p))
				pts.append(pts[0])
				draw_colored_polygon(pts, mask_color)
				draw_polyline(pts, polygon_color, 1.5, true)
		draw_rect(content, outline_color, false, 1.0)
	else:
		var font := ThemeDB.fallback_font
		var font_size := 12
		var text_size := font.get_string_size(empty_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_string(font, (size - text_size) * 0.5 + Vector2(0, text_size.y * 0.35), \
				empty_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.65, 0.65, 0.7))
	_draw_grid_overlay(content)


## 保持图块宽高比，居中显示。
func _content_rect() -> Rect2:
	var margin := 8.0
	var avail := size - Vector2(margin, margin) * 2.0
	if avail.x <= 4.0 or avail.y <= 4.0:
		return Rect2(Vector2(margin, margin), Vector2(1, 1))
	var aspect := tile_size.x / maxf(tile_size.y, 1.0)
	var w := avail.x
	var h := w / aspect
	if h > avail.y:
		h = avail.y
		w = h * aspect
	var pos := (size - Vector2(w, h)) * 0.5
	return Rect2(pos, Vector2(w, h))


func _draw_checkerboard(area: Rect2) -> void:
	var cell := 8.0
	var col_a := Color(0.16, 0.16, 0.18, 1.0)
	var col_b := Color(0.21, 0.21, 0.24, 1.0)
	var x0 := int(floor(area.position.x / cell))
	var y0 := int(floor(area.position.y / cell))
	var x1 := int(ceil(area.end.x / cell))
	var y1 := int(ceil(area.end.y / cell))
	for cy in range(y0, y1):
		for cx in range(x0, x1):
			var r := Rect2(Vector2(cx, cy) * cell, Vector2(cell, cell))
			r = r.intersection(area)
			if r.size.x <= 0.0 or r.size.y <= 0.0:
				continue
			draw_rect(r, col_a if (cx + cy) % 2 == 0 else col_b, true)


func _draw_mask(content: Rect2, scale_x: float, scale_y: float) -> void:
	var grid: PackedByteArray = generator.get_grid()
	var gsize: Vector2i = generator.get_grid_size()
	if gsize.x <= 0 or gsize.y <= 0:
		return
	var px := content.size.x / float(tile_size.x)
	var py := content.size.y / float(tile_size.y)
	for gy in gsize.y:
		for gx in gsize.x:
			if grid[gy * gsize.x + gx] == 0:
				continue
			# 网格坐标带 1 像素外边框：像素 (px, py) 位于网格 [gx-1, gx] x [gy-1, gy]
			var left := content.position.x + float(gx - 1) * px
			var top := content.position.y + float(gy - 1) * py
			draw_rect(Rect2(left, top, px, py), mask_color, true)


func _draw_grid_overlay(content: Rect2) -> void:
	if tile_size.x <= 0.0 or tile_size.y <= 0.0:
		return
	var step := content.size.x / maxf(tile_size.x, 1.0)
	if step < 6.0:
		return
	var col := Color(1, 1, 1, 0.06)
	var n := int(tile_size.x)
	for i in range(1, n):
		var x := content.position.x + float(i) * step
		draw_line(Vector2(x, content.position.y), Vector2(x, content.end.y), col, 1.0)
	var m := int(tile_size.y)
	var stepy := content.size.y / maxf(tile_size.y, 1.0)
	for i in range(1, m):
		var y := content.position.y + float(i) * stepy
		draw_line(Vector2(content.position.x, y), Vector2(content.end.x, y), col, 1.0)
