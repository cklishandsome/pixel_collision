@tool
class_name PixelCollisionGenerator
extends RefCounted

## 从图块贴图的 alpha 通道自动生成碰撞多边形。
##
## 纯算法模块：不依赖编辑器，可单独在运行时使用。
## 用法：
##     var gen := PixelCollisionGenerator.new()
##     gen.alpha_threshold = 0.5
##     var result := gen.detect(tile_set, source_id, atlas_coords, alternative_id, physics_layer)
##     gen.push_to_tile_data(tile_data, physics_layer, result.polygons)

enum Mode {
	## 精确轮廓：沿不透明像素外描出一圈多边形（最贴合像素）。
	CONTOUR,
	## 凸包：把所有像素合并成一个凸多边形（顶点最少，凹面会被填平）。
	CONVEX_HULL,
	## 逐行矩形：每行连续像素合并成一个矩形（形状简单，纯方形方块）。
	MERGED_RECTS,
	## 少量矩形：用小矩形覆盖大体形状的贪婪算法（最省形状，允许少量溢出）。
	FEW_RECTS,
}

const EPSILON := 0.0001
## 四方向（右/下/左/上）排列顺序：以“最右转优先”为准则，
## 保证描边时始终把填充区域留在左侧（屏幕 Y 轴向下 => 外轮廓为逆时针）。
const DIR_RIGHT := 0
const DIR_DOWN := 1
const DIR_LEFT := 2
const DIR_UP := 3
const DIR_VECTORS := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
## 每个入方向对应的出方向优先级表（越靠前越“右转”）。
const DIR_PRIORITY := [
	[DIR_DOWN, DIR_RIGHT, DIR_UP, DIR_LEFT], # 入方向 右
	[DIR_LEFT, DIR_DOWN, DIR_RIGHT, DIR_UP], # 入方向 下
	[DIR_UP, DIR_LEFT, DIR_DOWN, DIR_RIGHT], # 入方向 左
	[DIR_RIGHT, DIR_UP, DIR_LEFT, DIR_DOWN], # 入方向 上
]

## 像素被视为“实体”的 alpha 下限（0~1）。
var alpha_threshold := 0.5
## 检测模式。
var mode: Mode = Mode.CONTOUR
## 丢弃面积（像素²）小于该值的多边形。
var min_area := 2.0
## 轮廓简化容差（像素）。0 表示保留每个像素的直角。
var simplify_tolerance := 0.75
## 缝隙桥接：填补只被实体像素包围的空洞（3x3 内实体数 >= 该值）。0 = 关闭，常用 7。
var gap_bridge := 0
## 逐行矩形模式的向外扩张/向内收缩像素数，可用于“膨胀碰撞体”。
var rect_grow := 0
## 少量矩形模式的覆盖粒度（像素）。越大矩形越少。
var few_rect_cell := 4
## 少量矩形模式允许的溢出比例（0~1）。
var few_rect_overlap := 0.35

# --- 生成结果微调 ---------------------------------------------------------
## 最终顶点在本地坐标上再平移这么多像素（右为正、上为正）。
## 正常情况留 (0,0)；若某些 Godot 版本 / 贴图 padding 下形状整体偏移，用它校正。
var fix_offset := Vector2.ZERO
## 整体绕图块宽度中心左右翻转。
var fix_flip_x := false
## 整体绕图块高度中心上下翻转。
var fix_flip_y := false
## 用于翻转的图块像素尺寸；detect() 会自动填好，一般不用手动设。
var fix_tile_size := Vector2.ZERO

# --- 内部状态（预览时可复用，避免重复解码贴图） ---
var _grid: PackedByteArray = PackedByteArray()
var _w := 0
var _h := 0
var _pixel_count := 0


# === 公开 API ============================================================

## 检测一张图块的碰撞区域。
## 返回 { ok: bool, error: String, size: Vector2i, polygons: Array,
##        pixel_count: int, source_id: int, atlas_coords: Vector2i, alternative_id: int,
##        physics_layer: int }
func detect(p_tile_set: TileSet, source_id: int, atlas_coords: Vector2i, \
		alternative_id: int, physics_layer: int) -> Dictionary:
	var result := {
		"ok": false,
		"error": "",
		"size": Vector2i.ZERO,
		"polygons": [],
		"pixel_count": 0,
		"source_id": source_id,
		"atlas_coords": atlas_coords,
		"alternative_id": alternative_id,
		"physics_layer": physics_layer,
	}
	if p_tile_set == null:
		result.error = "没有 TileSet。"
		return result
	if physics_layer < 0 or physics_layer >= p_tile_set.get_physics_layers_count():
		result.error = "物理层索引无效（TileSet 中只有 %d 个物理层）。" % p_tile_set.get_physics_layers_count()
		return result
	var source := p_tile_set.get_source(source_id)
	if source == null:
		result.error = "找不到 source_id=%d 的图集来源。" % source_id
		return result
	if not (source is TileSetAtlasSource):
		result.error = "该来源不是图集（TileSetAtlasSource），暂不支持。"
		return result
	var atlas: TileSetAtlasSource = source
	if not atlas.has_tile(atlas_coords):
		result.error = "图集坐标 %s 上没有图块。" % str(atlas_coords)
		return result
	var loaded := _load_grid(atlas, atlas_coords, alternative_id)
	if not loaded.ok:
		result.error = loaded.error
		return result
	result.size = Vector2i(_w, _h)
	result.pixel_count = _pixel_count
	# 翻转微调需要知道图块像素尺寸
	fix_tile_size = Vector2(float(_w), float(_h))
	result.polygons = _build_polygons()
	result.ok = true
	return result


## 把多边形写入 TileData 的指定物理层。mult 用于支持「加到已有形状」。
## 返回写入的多边形数量。
func push_to_tile_data(tile_data: TileData, physics_layer: int, \
		polygons: Array, append: bool = false) -> int:
	if tile_data == null or physics_layer < 0:
		return 0
	var polygon_count := 0
	if append:
		polygon_count = tile_data.get_collision_polygons_count(physics_layer)
		tile_data.set_collision_polygons_count(physics_layer, polygon_count + polygons.size())
	else:
		tile_data.set_collision_polygons_count(physics_layer, polygons.size())
	for i in polygons.size():
		tile_data.set_collision_polygon_points(physics_layer, polygon_count + i, polygons[i])
	return polygons.size()


## 生成的掩码网格（每字节 0/1），行优先，尺寸为 (w+1)x(h+1)，含 1 像素外边界。
func get_grid() -> PackedByteArray:
	return _grid


func get_grid_size() -> Vector2i:
	return Vector2i(_w + 2, _h + 2)


## 网格坐标 (gx,gy) -> 图块本地像素坐标。用于预览叠加。
func local_point(gx: int, gy: int) -> Vector2:
	return _grid_to_local(gx, gy)


# === 贴图取样 ============================================================

func _load_grid(atlas: TileSetAtlasSource, atlas_coords: Vector2i, alternative_id: int) -> Dictionary:
	var frames := atlas.get_tile_animation_frames_count(atlas_coords)
	if frames <= 0:
		return {"ok": false, "error": "图块 %s 没有可用的纹理帧。" % str(atlas_coords)}
	# 第一优先：运行时（带 padding）贴图区域——它和图块本地坐标完全对齐。
	var source: Dictionary = _fetch_image(atlas.get_runtime_texture(), \
			atlas.get_runtime_tile_texture_region(atlas_coords, 0))
	# 回退：原始贴图区域——把图块纹理区域的左上角当作本地原点。
	if not source.ok:
		source = _fetch_image(atlas.texture, atlas.get_tile_texture_region(atlas_coords, 0), true)
	if not source.ok:
		return {"ok": false, "error": source.error}
	var image: Image = source.image
	_w = image.get_width()
	_h = image.get_height()
	if _w <= 0 or _h <= 0:
		return {"ok": false, "error": "图块像素区域无效（%s）。" % str(source.region)}

	# 逐像素采样 alpha，写入带 1 像素外边框的掩码网格。
	var gwidth := _w + 2
	_grid = PackedByteArray()
	_grid.resize(gwidth * (_h + 2))
	_pixel_count = 0
	for y in _h:
		var row := (y + 1) * gwidth + 1
		for x in _w:
			if image.get_pixel(x, y).a >= alpha_threshold:
				_grid[row + x] = 1
				_pixel_count += 1
	if _pixel_count == 0:
		return {"ok": false, "error": "该图块在 alpha 阈值 %.2f 下没有任何不透明像素。" % alpha_threshold}
	if gap_bridge > 0:
		_fill_gaps()
	return {"ok": true, "error": ""}


## 从贴图里裁出图块自己的像素区域。crop_to_region=false 表示贴图本身就是单图块。
func _fetch_image(tex: Texture2D, region: Rect2i, crop_to_region: bool = false) -> Dictionary:
	if tex == null:
		return {"ok": false, "error": "图集没有贴图。", "image": null, "region": region}
	if region.size.x <= 0 or region.size.y <= 0:
		return {"ok": false, "error": "图块纹理区域为空（%s）。" % str(region), "image": null, "region": region}
	var image := tex.get_image()
	if image == null:
		return {"ok": false, "error": "无法从贴图读取图像。", "image": null, "region": region}
	var needs_crop := crop_to_region \
			or region.position.x != 0 or region.position.y != 0 \
			or region.size.x != image.get_width() or region.size.y != image.get_height()
	if needs_crop:
		if region.position.x < 0 or region.position.y < 0 \
				or region.position.x + region.size.x > image.get_width() \
				or region.position.y + region.size.y > image.get_height():
			return {"ok": false, "error": "图块纹理区域 %s 超出贴图 %s。" % [str(region), str(image.get_size())], \
					"image": null, "region": region}
		image = image.get_region(region)
	return {"ok": true, "error": "", "image": image, "region": region}


## 缝隙桥接：把被实体包围的空洞填实（常用于描边抗锯齿留下的 1px 缝）。
func _fill_gaps() -> void:
	var gwidth := _w + 2
	var adds := PackedVector2Array()
	for y in range(1, _h + 1):
		for x in range(1, _w + 1):
			var idx := y * gwidth + x
			if _grid[idx] != 0:
				continue
			var filled := 0
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx == 0 and dy == 0:
						continue
					if _grid[(y + dy) * gwidth + (x + dx)] != 0:
						filled += 1
			if filled >= gap_bridge:
				adds.append(Vector2(x, y))
	for p in adds:
		_grid[int(p.y) * gwidth + int(p.x)] = 1
		_pixel_count += 1


func _is_grid(x: int, y: int) -> bool:
	if x < 0 or y < 0:
		return false
	var gwidth := _w + 2
	return _grid[y * gwidth + x] != 0


# === 多边形构建 ==========================================================

func _build_polygons() -> Array:
	var out: Array = []
	match mode:
		Mode.CONTOUR:
			out = _contours_to_polygons(_trace_contours())
		Mode.CONVEX_HULL:
			out = _convex_hull_polygon()
		Mode.MERGED_RECTS:
			out = _merged_rect_polygons()
		Mode.FEW_RECTS:
			out = _few_rect_polygons()
	var filtered: Array = []
	for poly in out:
		if absf(polygon_area(poly)) >= min_area:
			filtered.append(poly)
	return filtered


func _contours_to_polygons(contours: Array) -> Array:
	var out: Array = []
	for contour in contours:
		var pts := simplify(contour, simplify_tolerance)
		if pts.size() < 3:
			continue
		if polygon_area(pts) < 0.0:
			pts.reverse() # 统一为逆时针
		out.append(pts)
	return out


func _trace_contours() -> Array:
	var gwidth := _w + 2
	var gheight := _h + 2
	# 有向边界边：起点 -> 终点列表。方向约定：实体在左侧。
	var edges := {}
	for y in _h:
		for x in _w:
			if _grid[(y + 1) * gwidth + (x + 1)] == 0:
				continue
			var bx := x + 1
			var by := y + 1
			if not _is_grid(bx, by - 1):
				_add_edge(edges, bx, by, bx + 1, by, DIR_RIGHT)
			if not _is_grid(bx + 1, by):
				_add_edge(edges, bx + 1, by, bx + 1, by + 1, DIR_DOWN)
			if not _is_grid(bx, by + 1):
				_add_edge(edges, bx + 1, by + 1, bx, by + 1, DIR_LEFT)
			if not _is_grid(bx - 1, by):
				_add_edge(edges, bx, by + 1, bx, by, DIR_UP)
	var contours := []
	while not edges.is_empty():
		var start_key: int = edges.keys()[0]
		var ends: Array = edges[start_key]
		var current := start_key
		var dir: int = ends[0].dir
		var chain := PackedVector2Array([_grid_to_local(current % gwidth, current / gwidth)])
		var guard := (gwidth * gheight) * 4 + 16
		while guard > 0:
			guard -= 1
			if not edges.has(current):
				break
			var candidates: Array = edges[current]
			var pick := -1
			for d in DIR_PRIORITY[dir]:
				for i in candidates.size():
					if candidates[i].dir == d:
						pick = i
						break
				if pick >= 0:
					break
			if pick < 0:
				break
			var step: Dictionary = candidates[pick]
			candidates.remove_at(pick)
			if candidates.is_empty():
				edges.erase(current)
			current = step.next
			dir = step.dir
			chain.append(_grid_to_local(current % gwidth, current / gwidth))
			if current == start_key:
				break
		if chain.size() > 3:
			chain.remove_at(chain.size() - 1) # 去掉与起点重复的收尾点
		if chain.size() >= 3:
			contours.append(chain)
	return contours


func _add_edge(edges: Dictionary, ax: int, ay: int, bx: int, by: int, dir: int) -> void:
	var a := ay * (_w + 2) + ax
	var b := by * (_w + 2) + bx
	if not edges.has(a):
		edges[a] = []
	edges[a].append({"next": b, "dir": dir})


## 网格坐标 (gx,gy) -> Godot 图块碰撞多边形的本地坐标。
##
## Godot 的约定是：**原点在图块中心，x 向右为正，y 向下为正**。
## 一块铺满整个图块的碰撞矩形应当是 (-w/2,-h/2) ~ (+w/2,+h/2)。
## 网格坐标 gx/gy 是「像素角点」编号（含 1 像素外边框），于是：
##   x = (gx-1) - w/2      （向右为正）
##   y = (gy-1) - h/2      （向下为正）
func _grid_to_local(gx: int, gy: int) -> Vector2:
	var half_w := float(_w) * 0.5
	var half_h := float(_h) * 0.5
	return _fix_point(Vector2(float(gx - 1) - half_w, float(gy - 1) - half_h))


## 所有顶点出口的唯一收口：在这里应用「微调偏移」与左右/上下翻转，
## 保证检测、预览、写入 TileData 用的是同一套坐标。
## 默认约定已经和 Godot 对齐，所以 fix_offset 默认 (0,0)、两个翻转默认关闭。
func _fix_point(p: Vector2) -> Vector2:
	if fix_flip_x:
		p.x = -p.x
	if fix_flip_y:
		p.y = -p.y
	return p + fix_offset


## 提取每个连通块的角点集合（凸包模式用：先分块，再各自求凸包）。
func _component_outlines() -> Array:
	var gwidth := _w + 2
	var visited := {}
	var outlines := []
	for y in _h:
		for x in _w:
			var start := Vector2i(x + 1, y + 1)
			if _grid[start.y * gwidth + start.x] == 0 or visited.has(start):
				continue
			var stack := [start]
			visited[start] = true
			var cells := []
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				cells.append(c)
				for d in DIR_VECTORS:
					var n: Vector2i = c + d
					if n.x < 0 or n.y < 0 or n.x >= gwidth or n.y >= _h + 2:
						continue
					if _grid[n.y * gwidth + n.x] == 0 or visited.has(n):
						continue
					visited[n] = true
					stack.append(n)
			var pts := PackedVector2Array()
			var seen := {}
			for c in cells:
				# 四个角在网格坐标里是 (c.x-1, c.y-1) ~ (c.x, c.y)。
				for corner in [Vector2i(c.x - 1, c.y - 1), Vector2i(c.x, c.y - 1), \
						Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y)]:
					if seen.has(corner):
						continue
					seen[corner] = true
					pts.append(_grid_to_local(corner.x, corner.y))
			outlines.append(pts)
	return outlines


func _convex_hull_polygon() -> Array:
	var out: Array = []
	for pts in _component_outlines():
		if pts.size() < 3:
			continue
		# 图块本地坐标 y 向上、且已含微调；几何谓词按数学方向输入最稳妥，
		# 算完再把 y 翻转回来，避免某些版本上凸包整体被转 180°。
		var flipped := PackedVector2Array()
		for p in pts:
			flipped.append(Vector2(p.x, -p.y))
		var hull := Geometry2D.convex_hull(flipped)
		if hull.size() >= 3:
			hull.remove_at(hull.size() - 1) # convex_hull 会重复首点收尾
			var restored := PackedVector2Array()
			for p in hull:
				restored.append(Vector2(p.x, -p.y))
			if polygon_area(restored) < 0.0:
				restored.reverse()
			out.append(restored)
	return out


## 逐行矩形分解：每行连续实体像素段先变成矩形，再把 x 范围完全相同的上下相邻矩形纵向合并。
## rect_grow 可整体膨胀（>0）或收缩（<0）。
func _merged_rect_polygons() -> Array:
	var out: Array = []
	var width := _w + rect_grow * 2
	var height := _h + rect_grow * 2
	if width <= 0 or height <= 0:
		return out
	# active: 上一行仍在继续的矩形，键为 "x0:x1"，值为 [高度, 起始行]
	var active := {}
	for y in height:
		var current := {}
		var x := 0
		while x < width:
			if _grow_sample(x - rect_grow, y - rect_grow) == 0:
				x += 1
				continue
			var start := x
			while x < width and _grow_sample(x - rect_grow, y - rect_grow) != 0:
				x += 1
			var key := "%d:%d" % [start, x]
			if active.has(key):
				var entry: Array = active[key]
				current[key] = [int(entry[0]) + 1, int(entry[1])]
			else:
				current[key] = [1, y]
		# 本行已经结束的矩形（上一行有、本行没有）在此定稿。
		for key in active.keys():
			if not current.has(key):
				var parts := (key as String).split(":")
				var entry: Array = active[key]
				var run_start := int(parts[0])
				var run_end := int(parts[1])
				var top_row := int(entry[1])
				var span := int(entry[0])
				var x0 := run_start - rect_grow
				var x1 := run_end - rect_grow
				var y1 := _h - (top_row - rect_grow)
				var y0 := _h - (top_row + span - rect_grow)
				out.append(_rect_poly(x0, y0, x1, y1))
		active = current
	# 收尾：最后一行还没结束的矩形。
	for key in active.keys():
		var parts := (key as String).split(":")
		var entry: Array = active[key]
		var run_start := int(parts[0])
		var run_end := int(parts[1])
		var top_row := int(entry[1])
		var span := int(entry[0])
		var x0 := run_start - rect_grow
		var x1 := run_end - rect_grow
		var y1 := _h - (top_row - rect_grow)
		var y0 := _h - (top_row + span - rect_grow)
		out.append(_rect_poly(x0, y0, x1, y1))
	return out


## 统一构造「矩形」多边形。传入的 x/y 是「图块左上角为原点、y 向上」的旧坐标，
## 这里先换算成 Godot 的「中心原点」坐标，再统一走 _fix_point。
func _rect_poly(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	var half_w := float(_w) * 0.5
	var half_h := float(_h) * 0.5
	return PackedVector2Array([
		_fix_point(Vector2(x0 - half_w, y0 - half_h)), _fix_point(Vector2(x1 - half_w, y0 - half_h)),
		_fix_point(Vector2(x1 - half_w, y1 - half_h)), _fix_point(Vector2(x0 - half_w, y1 - half_h))])


## 带膨胀/收缩的取样：
## rect_grow > 0 -> 膨胀：3x3 邻域内只要有一个实体像素就算实体（形状向外长 rect_grow 像素）。
## rect_grow < 0 -> 收缩：3x3 邻域内必须全部是实体像素才算实体。
func _grow_sample(gx: int, gy: int) -> int:
	if rect_grow == 0:
		return _grid_sample(gx, gy)
	var r := absi(rect_grow)
	var dilate := rect_grow > 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var solid := _grid_sample(gx + dx, gy + dy) != 0
			if dilate and solid:
				return 1
			if not dilate and not solid:
				return 0
	return 0 if dilate else 1


func _few_rect_polygons() -> Array:
	var out: Array = []
	var cell := maxi(1, few_rect_cell)
	var cols := int(ceil(float(_w) / cell))
	var rows := int(ceil(float(_h) / cell))
	var mask := PackedByteArray()
	mask.resize(cols * rows)
	for r in rows:
		for c in cols:
			var total := 0
			var filled := 0
			for y in range(r * cell, mini((r + 1) * cell, _h)):
				for x in range(c * cell, mini((c + 1) * cell, _w)):
					total += 1
					if _grid[(y + 1) * (_w + 2) + (x + 1)] != 0:
						filled += 1
			if total > 0 and float(filled) / float(total) >= 1.0 - few_rect_overlap:
				mask[r * cols + c] = 1
	# 先用贪心算法把掩码格合并成矩形：能向下延伸就向下，否则向右延伸。
	var used := PackedByteArray()
	used.resize(cols * rows)
	for r in rows:
		for c in cols:
			if mask[r * cols + c] == 0 or used[r * cols + c] != 0:
				continue
			var h := 1
			while r + h < rows and mask[(r + h) * cols + c] != 0 and used[(r + h) * cols + c] == 0:
				h += 1
			var w := 1
			while c + w < cols:
				var ok := true
				for rr in range(r, r + h):
					if mask[rr * cols + (c + w)] == 0 or used[rr * cols + (c + w)] != 0:
						ok = false
						break
				if not ok:
					break
				w += 1
			for rr in range(r, r + h):
				for cc in range(c, c + w):
					used[rr * cols + cc] = 1
			out.append(_cell_rect(c, r, w, h, cell))
	return out


func _cell_rect(cx: int, cy: int, cw: int, ch: int, cell: int) -> PackedVector2Array:
	var x0 := cx * cell
	var x1 := mini((cx + cw) * cell, _w)
	var y1 := mini((cy + ch) * cell, _h)
	var y0 := cy * cell
	return _rect_poly(x0, _h - y1, x1, _h - y0)


func _grid_sample(gx: int, gy: int) -> int:
	if gx < 0 or gy < 0 or gx >= _w or gy >= _h:
		return 0
	return _grid[(gy + 1) * (_w + 2) + (gx + 1)]


# === 几何工具 ============================================================

## 多边形有向面积（正 = 逆时针）。
static func polygon_area(poly: PackedVector2Array) -> float:
	var n := poly.size()
	if n < 3:
		return 0.0
	var area := 0.0
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	return area * 0.5


## Ramer-Douglas-Peucker 简化（闭合折线按最长弦拆分）。
static func simplify(poly: PackedVector2Array, tolerance: float) -> PackedVector2Array:
	var n := poly.size()
	if tolerance <= 0.0 or n < 4:
		return _drop_collinear(poly)
	# 找到离首点最远的点，作为拆分为两条开放折线的锚点。
	var far := 0
	var best := -1.0
	for i in range(1, n):
		var d := poly[0].distance_squared_to(poly[i])
		if d > best:
			best = d
			far = i
	var first := PackedVector2Array()
	for i in range(0, far + 1):
		first.append(poly[i])
	var second := PackedVector2Array()
	for i in range(far, n):
		second.append(poly[i])
	second.append(poly[0])
	var a := _rdp(first, tolerance)
	var b := _rdp(second, tolerance)
	var out := PackedVector2Array()
	for i in range(0, a.size() - 1):
		out.append(a[i])
	for i in range(0, b.size() - 1):
		out.append(b[i])
	return _drop_collinear(out)


static func _rdp(pts: PackedVector2Array, tolerance: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	var stack := [[0, n - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var i0: int = seg[0]
		var i1: int = seg[1]
		var max_d := -1.0
		var max_i := -1
		for i in range(i0 + 1, i1):
			var d := _point_segment_distance(pts[i], pts[i0], pts[i1])
			if d > max_d:
				max_d = d
				max_i = i
		if max_i >= 0 and max_d > tolerance:
			keep[max_i] = 1
			stack.append([i0, max_i])
			stack.append([max_i, i1])
	var out := PackedVector2Array()
	for i in n:
		if keep[i] != 0:
			out.append(pts[i])
	return out


static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	if denom < EPSILON:
		return p.distance_to(a)
	return absf(ab.cross(p - a)) / sqrt(denom)


static func _drop_collinear(poly: PackedVector2Array) -> PackedVector2Array:
	var n := poly.size()
	if n < 3:
		return poly
	var out := PackedVector2Array()
	for i in n:
		var prev := poly[(i - 1 + n) % n]
		var cur := poly[i]
		var next := poly[(i + 1) % n]
		if absf((cur - prev).cross(next - cur)) > EPSILON:
			out.append(cur)
	if out.size() < 3:
		return poly
	return out
