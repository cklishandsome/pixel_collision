@tool
extends VBoxContainer

## 「像素碰撞」插件的主面板（Dock）。
##
## 用法：在场景里选中一个 TileMapLayer（或 TileMap），在下方拖拽/点击选择图块，
## 选好物理层，点「应用到当前图块」或「应用到整个图集」。

const PixelCollisionGeneratorScript := preload("res://addons/pixel_collision/pixel_collision_generator.gd")
const PixelCollisionPreviewScript := preload("res://addons/pixel_collision/pixel_collision_preview.gd")

const MODE_NAMES := ["精确轮廓", "凸包（顶点最少）", "逐行矩形", "少量矩形"]
const MODE_HINTS := [
	"沿不透明像素外描一圈，最贴合像素，顶点较多（推荐）。",
	"把所有像素合成一个凸多边形，顶点最少，但凹进去的地方会被填平。",
	"每一行的连续像素合并成矩形；相邻同宽的矩形会纵向合并，形状简单。",
	"用小矩形粗略覆盖整体形状，最省形状，允许少量溢出。",
]


## 图块选择器里的小按钮：自己把该图块的像素贴图画出来，保证按比例缩放。
class TileButton:
	extends Button

	var tile_texture: Texture2D

	func _init(tex: Texture2D, coords: Vector2i, cell: Vector2) -> void:
		tile_texture = tex
		text = ""
		toggle_mode = true
		focus_mode = Control.FOCUS_CLICK
		custom_minimum_size = cell
		size = cell
		icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tooltip_text = "图集坐标 %s" % str(coords)

	func _draw() -> void:
		if tile_texture == null:
			return
		var area := Rect2(Vector2.ZERO, size)
		draw_texture_rect(tile_texture, area, false)
		draw_rect(area, Color(1, 1, 1, 0.16), false, 1.0)


var _editor: Variant
var _last_node: Node

# 当前图集 / 图块选择
var _tile_set: TileSet
var _source_id := -1
var _atlas_coords := Vector2i.ZERO
var _alternative_id := 0
var _tile_size := Vector2i(16, 16)

# 最近一次检测结果
var _result: Dictionary = {}
var _generator: RefCounted
var _polygons: Array = []

# --- 界面节点 ---
var _node_label: Label
var _source_spin: SpinBox
var _coords_x: SpinBox
var _coords_y: SpinBox
var _alt_spin: SpinBox
var _grid_scroll: ScrollContainer
var _grid: GridContainer
var _physics_layers: OptionButton
var _threshold_slider: HSlider
var _threshold_spin: SpinBox
var _mode_button: OptionButton
var _mode_hint: Label
var _min_area_spin: SpinBox
var _simplify_slider: HSlider
var _simplify_spin: SpinBox
var _gap_slider: HSlider
var _gap_spin: SpinBox
var _grow_spin: SpinBox
var _few_cell_spin: SpinBox
var _few_overlap_spin: SpinBox
var _fix_x_spin: SpinBox
var _fix_y_spin: SpinBox
var _fix_flip_x_check: CheckBox
var _fix_flip_y_check: CheckBox
var _append_check: CheckBox
var _alt_check: CheckBox
var _mask_check: CheckBox
var _poly_check: CheckBox
var _preview: Control
var _stats_label: Label
var _status_label: Label
var _apply_current_button: Button
var _apply_all_button: Button


## 注入编辑器接口。参数刻意用 Object：EditorInterface 是引擎单例，
## 用它的类型做形参时，动态 `call("setup", singleton)` 会做子类校验而失败。
## 这里用 Variant 存下来，方法调用交给运行时。
func setup(editor: Object) -> void:
	_editor = editor


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_build_ui()
	refresh()


# === 界面构建 ============================================================

func _build_ui() -> void:
	var title := Label.new()
	title.text = "像素碰撞 — 按像素自动生成碰撞形状"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 13)
	add_child(title)

	# --- 当前编辑对象 ---
	_node_label = Label.new()
	_node_label.text = "未选中 TileMapLayer"
	_node_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_node_label)

	# --- 图集与图块 ---
	add_child(_make_header("图集 / 图块"))
	var form := GridContainer.new()
	form.columns = 4
	add_child(form)
	form.add_child(_make_key_label("来源 ID"))
	_source_spin = _make_spin(0, 0, 4096, 1)
	_source_spin.value_changed.connect(_on_source_id_changed)
	form.add_child(_source_spin)
	form.add_child(_make_key_label("图集坐标"))
	var coord_row := HBoxContainer.new()
	_coords_x = _make_spin(0, 0, 4096, 1)
	_coords_x.value_changed.connect(_on_coords_changed)
	var comma := Label.new()
	comma.text = "，"
	coord_row.add_child(_coords_x)
	coord_row.add_child(comma)
	_coords_y = _make_spin(0, 0, 4096, 1)
	_coords_y.value_changed.connect(_on_coords_changed)
	coord_row.add_child(_coords_y)
	form.add_child(coord_row)
	form.add_child(_make_key_label("替代图块"))
	_alt_spin = _make_spin(0, 0, 4096, 1)
	_alt_spin.value_changed.connect(_on_alt_changed)
	form.add_child(_alt_spin)

	_grid_scroll = ScrollContainer.new()
	_grid_scroll.custom_minimum_size = Vector2(0, 110)
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(_grid_scroll)
	_grid = GridContainer.new()
	_grid.columns = 1
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_grid_scroll.add_child(_grid)

	var grid_row := HBoxContainer.new()
	add_child(grid_row)
	var reload_button := Button.new()
	reload_button.text = "从选中单元格刷新"
	reload_button.tooltip_text = "读取场景中选中/编辑中的 TileMapLayer，取它当前选中的单元格作为要处理的图块。"
	reload_button.pressed.connect(_on_reload_pressed)
	grid_row.add_child(reload_button)
	var atlas_button := Button.new()
	atlas_button.text = "重读图集"
	atlas_button.tooltip_text = "重新扫描当前 TileSet，重建下方图块选择器。"
	atlas_button.pressed.connect(_on_reload_atlas_pressed)
	grid_row.add_child(atlas_button)

	# --- 目标物理层 ---
	add_child(_make_header("目标物理层"))
	_physics_layers = OptionButton.new()
	_physics_layers.tooltip_text = "生成的碰撞多边形要写入的物理层（对应 TileSet 的物理层索引）。"
	_physics_layers.item_selected.connect(_on_physics_layer_changed)
	add_child(_physics_layers)

	# --- 识别设置 ---
	add_child(_make_header("识别设置"))
	var thresh_row := HBoxContainer.new()
	add_child(thresh_row)
	thresh_row.add_child(_make_key_label("Alpha 阈值"))
	_threshold_slider = HSlider.new()
	_threshold_slider.min_value = 0.0
	_threshold_slider.max_value = 1.0
	_threshold_slider.step = 0.01
	_threshold_slider.value = 0.5
	_threshold_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_threshold_slider.value_changed.connect(_on_threshold_slider)
	thresh_row.add_child(_threshold_slider)
	_threshold_spin = _make_spin(0.5, 0.0, 1.0, 0.01)
	_threshold_spin.value_changed.connect(_on_threshold_spin)
	thresh_row.add_child(_threshold_spin)

	var mode_row := HBoxContainer.new()
	add_child(mode_row)
	mode_row.add_child(_make_key_label("生成方式"))
	_mode_button = OptionButton.new()
	for i in MODE_NAMES.size():
		_mode_button.add_item(MODE_NAMES[i], i)
	_mode_button.selected = 0
	_mode_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_button.item_selected.connect(_on_mode_changed)
	mode_row.add_child(_mode_button)
	_mode_hint = Label.new()
	_mode_hint.text = MODE_HINTS[0]
	_mode_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_hint.add_theme_font_size_override("font_size", 11)
	add_child(_mode_hint)

	var area_row := HBoxContainer.new()
	add_child(area_row)
	area_row.add_child(_make_key_label("最小面积(px²)"))
	_min_area_spin = _make_spin(2.0, 0.0, 100000.0, 1.0)
	_min_area_spin.value_changed.connect(_on_param_changed)
	area_row.add_child(_min_area_spin)
	area_row.add_child(_make_key_label("简化容差(px)"))
	_simplify_slider = HSlider.new()
	_simplify_slider.min_value = 0.0
	_simplify_slider.max_value = 8.0
	_simplify_slider.step = 0.25
	_simplify_slider.value = 0.75
	_simplify_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_simplify_slider.value_changed.connect(_on_simplify_slider)
	area_row.add_child(_simplify_slider)
	_simplify_spin = _make_spin(0.75, 0.0, 8.0, 0.25)
	_simplify_spin.value_changed.connect(_on_simplify_spin)
	area_row.add_child(_simplify_spin)

	var gap_row := HBoxContainer.new()
	add_child(gap_row)
	gap_row.add_child(_make_key_label("缝隙桥接"))
	_gap_slider = HSlider.new()
	_gap_slider.min_value = 0.0
	_gap_slider.max_value = 8.0
	_gap_slider.step = 1.0
	_gap_slider.value = 0.0
	_gap_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gap_slider.tooltip_text = "把只被实体像素包围的空洞填实；抗锯齿描边常常留下 1 像素缝，填上可避免碰撞体开裂。0 = 关闭，常用 7。"
	_gap_slider.value_changed.connect(_on_gap_slider)
	gap_row.add_child(_gap_slider)
	_gap_spin = _make_spin(0.0, 0.0, 8.0, 1.0)
	_gap_spin.value_changed.connect(_on_gap_spin)
	gap_row.add_child(_gap_spin)

	var rect_row := HBoxContainer.new()
	add_child(rect_row)
	rect_row.add_child(_make_key_label("膨胀(px)"))
	_grow_spin = _make_spin(0.0, -32.0, 32.0, 1.0)
	_grow_spin.tooltip_text = "仅「逐行矩形」模式有效：正整数向外膨胀，负整数向内收缩。"
	_grow_spin.value_changed.connect(_on_param_changed)
	rect_row.add_child(_grow_spin)
	rect_row.add_child(_make_key_label("少量矩形粒度"))
	_few_cell_spin = _make_spin(4.0, 1.0, 256.0, 1.0)
	_few_cell_spin.tooltip_text = "仅「少量矩形」模式有效：每次覆盖的方格边长（像素）。越大越省形状。"
	_few_cell_spin.value_changed.connect(_on_param_changed)
	rect_row.add_child(_few_cell_spin)
	rect_row.add_child(_make_key_label("允许溢出"))
	_few_overlap_spin = _make_spin(0.35, 0.0, 1.0, 0.05)
	_few_overlap_spin.tooltip_text = "仅「少量矩形」模式有效：一格内非实体像素占比低于该值时也算被覆盖。"
	_few_overlap_spin.value_changed.connect(_on_param_changed)
	rect_row.add_child(_few_overlap_spin)

	# --- 位置微调（生成的形状整体偏移时用） ---
	add_child(_make_header("位置微调"))
	var fix_row := HBoxContainer.new()
	add_child(fix_row)
	fix_row.add_child(_make_key_label("整体偏移(px)"))
	_fix_x_spin = _make_spin(0.0, -256.0, 256.0, 1.0)
	_fix_x_spin.tooltip_text = "把生成的所有形状整体右移(+)/左移(-)这么多像素。"
	_fix_x_spin.value_changed.connect(_on_param_changed)
	fix_row.add_child(_fix_x_spin)
	_fix_y_spin = _make_spin(0.0, -256.0, 256.0, 1.0)
	_fix_y_spin.tooltip_text = "把生成的所有形状整体上移(+)/下移(-)这么多像素。"
	_fix_y_spin.value_changed.connect(_on_param_changed)
	fix_row.add_child(_fix_y_spin)
	_fix_flip_x_check = CheckBox.new()
	_fix_flip_x_check.text = "左右翻转"
	_fix_flip_x_check.tooltip_text = "沿图块垂直中线镜像。若形状整体左右反了（而不是单纯偏移）再勾。"
	_fix_flip_x_check.toggled.connect(_on_fix_flip_toggled)
	fix_row.add_child(_fix_flip_x_check)
	_fix_flip_y_check = CheckBox.new()
	_fix_flip_y_check.text = "上下翻转"
	_fix_flip_y_check.tooltip_text = "沿图块水平中线镜像。若形状整体上下反了（而不是单纯偏移）再勾。"
	_fix_flip_y_check.toggled.connect(_on_fix_flip_toggled)
	fix_row.add_child(_fix_flip_y_check)
	var fix_hint := Label.new()
	fix_hint.text = "默认已按 Godot 的中心原点/y 向下对齐，一般填 0 即可。仍偏了才用这里：往右偏填负数、往上偏填负数。"
	fix_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fix_hint.add_theme_font_size_override("font_size", 11)
	add_child(fix_hint)

	# --- 写入选项 ---
	add_child(_make_header("写入选项"))
	_append_check = CheckBox.new()
	_append_check.text = "追加到已有形状（不勾选则替换）"
	add_child(_append_check)
	_alt_check = CheckBox.new()
	_alt_check.text = "同时应用到该图块的所有替代图块"
	add_child(_alt_check)

	# --- 预览 ---
	add_child(_make_header("预览"))
	var view_row := HBoxContainer.new()
	add_child(view_row)
	_mask_check = CheckBox.new()
	_mask_check.text = "显示像素掩码"
	_mask_check.button_pressed = false
	_mask_check.toggled.connect(_on_view_toggled)
	view_row.add_child(_mask_check)
	_poly_check = CheckBox.new()
	_poly_check.text = "显示多边形"
	_poly_check.button_pressed = true
	_poly_check.toggled.connect(_on_view_toggled)
	view_row.add_child(_poly_check)

	_preview = PixelCollisionPreviewScript.new()
	_preview.custom_minimum_size = Vector2(0, 170)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview["show_mask"] = false
	_preview["show_polygons"] = true
	add_child(_preview)

	_stats_label = Label.new()
	_stats_label.text = "—"
	add_child(_stats_label)

	# --- 操作 ---
	var action_row := HBoxContainer.new()
	add_child(action_row)
	_apply_current_button = Button.new()
	_apply_current_button.text = "应用到当前图块"
	_apply_current_button.pressed.connect(_on_apply_current)
	action_row.add_child(_apply_current_button)
	_apply_all_button = Button.new()
	_apply_all_button.text = "应用到整个图集"
	_apply_all_button.pressed.connect(_on_apply_all)
	action_row.add_child(_apply_all_button)

	_status_label = Label.new()
	_status_label.text = "准备就绪。"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)


func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.95))
	return label


func _make_key_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(96, 0)
	return label


func _make_spin(value: float, minimum: float, maximum: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = Vector2(72, 0)
	spin.allow_greater = false
	spin.allow_lesser = false
	return spin


# === 编辑器状态同步 ======================================================

## 由 EditorPlugin 在 selection_changed / 场景树变化时调用。
func refresh() -> void:
	var node := _find_edited_tile_map_node()
	var tile_set: TileSet = null
	if node != null:
		tile_set = node.get("tile_set")
	_node_label.text = "当前对象：%s" % (node.name if node != null else "（未找到 TileMapLayer / TileMap，请在场景里选中一个）")
	if node == _last_node and tile_set == _tile_set:
		return # 选中的还是同一个图块层，不必重建界面（避免每次节点变化都重扫图集）
	_last_node = node
	if tile_set == _tile_set:
		_rebuild_grid()
		_queue_all()
		return
	_tile_set = tile_set
	_source_id = -1
	_atlas_coords = Vector2i.ZERO
	_alternative_id = 0
	_rebuild_atlas_ui()


func _find_edited_tile_map_node() -> Node:
	if _editor == null:
		return null
	var selection: Variant = _editor.get_selection()
	if selection != null:
		for node in selection.get_selected_nodes():
			if _is_tile_map_node(node):
				return node
	var root: Variant = _editor.get_edited_scene_root()
	if root != null:
		var found := _find_tile_map_in(root)
		if found != null:
			return found
	var open_roots: Variant = _editor.get_open_scene_roots()
	for open_root in open_roots:
		var found := _find_tile_map_in(open_root)
		if found != null:
			return found
	return null


func _is_tile_map_node(node: Node) -> bool:
	if node == null:
		return false
	if node is TileMapLayer:
		return true
	# TileMap 在 4.3 起被弃用，但老工程仍然可能用到；用鸭子类型判断。
	return node.get_class() == "TileMap" and node.get("tile_set") != null


func _find_tile_map_in(root: Node) -> Node:
	if _is_tile_map_node(root):
		return root
	for child in root.get_children():
		var found := _find_tile_map_in(child)
		if found != null:
			return found
	return null


func _on_reload_pressed() -> void:
	var node := _find_edited_tile_map_node()
	_last_node = node
	if node == null:
		_set_status("场景里没有选中 TileMapLayer / TileMap。", true)
		return
	var picked := false
	if node is TileMapLayer:
		var cells: Array[Vector2i] = node.get_used_cells()
		if not cells.is_empty():
			var cell: Vector2i = cells[0]
			_source_id = node.get_cell_source_id(cell)
			_atlas_coords = node.get_cell_atlas_coords(cell)
			_alternative_id = node.get_cell_alternative_tile(cell)
			picked = true
	if not picked:
		_set_status("没能取到选中单元格（图块层上好像还没有单元格）。", true)
		return
	var tile_set: TileSet = node.get("tile_set")
	if tile_set != _tile_set:
		_tile_set = tile_set
		_rebuild_atlas_ui()
	_source_spin.set_value_no_signal(_source_id)
	_coords_x.set_value_no_signal(_atlas_coords.x)
	_coords_y.set_value_no_signal(_atlas_coords.y)
	_alt_spin.set_value_no_signal(_alternative_id)
	_set_status("已取到图块：来源 %d，坐标 %s。" % [_source_id, str(_atlas_coords)])
	_ensure_current_tile_selected()
	_queue_all()


func _on_reload_atlas_pressed() -> void:
	_rebuild_atlas_ui()


# === 图集与物理层界面 ====================================================

func _rebuild_atlas_ui() -> void:
	if _tile_set == null:
		_physics_layers.clear()
		_clear_grid()
		_source_spin.editable = false
		_apply_current_button.disabled = true
		_apply_all_button.disabled = true
		_preview.clear()
		_stats_label.text = "—"
		return
	var is_atlas := _get_atlas_source(_source_id) != null
	_source_spin.editable = true
	if not is_atlas:
		# 自动挑选图集里的第一张图块，降低「还没选任何图块」的空白感。
		var first := _find_first_atlas_source_id()
		if first >= 0 and _source_id != first:
			_source_id = first
			_atlas_coords = Vector2i.ZERO
			_alternative_id = 0
			_source_spin.set_value_no_signal(_source_id)
			_coords_x.set_value_no_signal(0)
			_coords_y.set_value_no_signal(0)
			_alt_spin.set_value_no_signal(0)
	_rebuild_physics_layers()
	_rebuild_grid()
	_apply_current_button.disabled = false
	_apply_all_button.disabled = false
	_queue_all()


func _rebuild_physics_layers() -> void:
	_physics_layers.clear()
	if _tile_set == null:
		return
	for i in _tile_set.get_physics_layers_count():
		var layer_bits := _tile_set.get_physics_layer_collision_layer(i)
		_physics_layers.add_item("物理层 %d（碰撞层 %d）" % [i, layer_bits])
	if _physics_layers.item_count == 0:
		_physics_layers.add_item("（TileSet 里还没有物理层）")
		_physics_layers.disabled = true
	else:
		_physics_layers.disabled = false
		_physics_layers.selected = 0


func _find_first_atlas_source_id() -> int:
	if _tile_set == null:
		return -1
	for i in _tile_set.get_source_count():
		var id := _tile_set.get_source_id(i)
		if _tile_set.get_source(id) is TileSetAtlasSource:
			return id
	return -1


func _get_atlas_source(source_id: int) -> TileSetAtlasSource:
	if _tile_set == null or source_id < 0 or not _tile_set.has_source(source_id):
		return null
	var source := _tile_set.get_source(source_id)
	if source is TileSetAtlasSource:
		return source
	return null


func _get_physics_layer_index() -> int:
	if _physics_layers.disabled or _physics_layers.item_count == 0:
		return -1
	return _physics_layers.selected


# === 图块选择器（把整张图集按真实比例铺成按钮阵列） ======================

func _clear_grid() -> void:
	# queue_free() 会立刻把节点移出场景树（真正的释放推迟到帧末），所以这里不能
	# 再手动 remove_child()：那样 Container 会在断开 size_flags/minimum_size 信号时
	# 报「Attempt to disconnect a nonexistent connection」。
	for child in _grid.get_children():
		child.queue_free()


func _rebuild_grid() -> void:
	_clear_grid()
	if _tile_set == null:
		return
	var atlas := _get_atlas_source(_source_id)
	if atlas == null:
		return
	var base := atlas.texture
	if base == null:
		base = atlas.get_runtime_texture()
	if base == null:
		return
	var atlas_image := base.get_image()
	if atlas_image == null:
		return
	var grid_size := atlas.get_atlas_grid_size()
	if grid_size.x <= 0 or grid_size.y <= 0:
		return
	_grid.columns = grid_size.x
	# 单元格边长：按图块原尺寸等比缩放，保证像素是方的。
	var factor := minf(1.0, 26.0 / maxf(float(_tile_size.x), float(_tile_size.y)))
	factor = maxf(factor, 0.02)
	var tiles: Array[Vector2i] = []
	var cell_of := {}
	for i in atlas.get_tiles_count():
		var coords := atlas.get_tile_id(i)
		tiles.append(coords)
		cell_of[coords] = i
	var covered := {}
	for row in grid_size.y:
		for col in grid_size.x:
			var key := Vector2i(col, row)
			if covered.has(key):
				continue
			if not cell_of.has(key):
				var spacer := Control.new()
				spacer.custom_minimum_size = Vector2(2, 2)
				_grid.add_child(spacer)
				continue
			var coords: Vector2i = key
			var span := atlas.get_tile_size_in_atlas(coords)
			var tex := ImageTexture.create_from_image(_crop_tile(atlas, atlas_image, coords))
			var button := TileButton.new(tex, coords, Vector2(_tile_size * span) * factor)
			button.button_pressed = (coords == _atlas_coords)
			if span.x > 1 or span.y > 1:
				button.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_SHRINK_CENTER
				button.size_flags_vertical = Control.SIZE_EXPAND | Control.SIZE_SHRINK_CENTER
			button.pressed.connect(_on_grid_tile_pressed.bind(coords))
			_grid.add_child(button)
			for iy in span.y:
				for ix in span.x:
					covered[Vector2i(col + ix, row + iy)] = true
	_update_grid_highlight()


## 按图块纹理区域裁出子图；区域不合法时退回整张贴图。
func _crop_tile(atlas: TileSetAtlasSource, atlas_image: Image, coords: Vector2i) -> Image:
	var region := atlas.get_tile_texture_region(coords, 0)
	if region.size.x > 0 and region.size.y > 0 \
			and region.position.x >= 0 and region.position.y >= 0 \
			and region.position.x + region.size.x <= atlas_image.get_width() \
			and region.position.y + region.size.y <= atlas_image.get_height():
		return atlas_image.get_region(region)
	return atlas_image


func _update_grid_highlight() -> void:
	var atlas := _get_atlas_source(_source_id)
	var tiles: Array[Vector2i] = []
	if atlas != null:
		for i in atlas.get_tiles_count():
			tiles.append(atlas.get_tile_id(i))
	# 按钮与 tiles 不一定一一对应（跨格图块会占掉多个单元格），用 tooltip 里的坐标回查。
	for child in _grid.get_children():
		var button := child as Button
		if button == null or button.tooltip_text == "":
			continue
		var coords := _coords_from_tooltip(button.tooltip_text)
		button.button_pressed = (coords == _atlas_coords)


func _coords_from_tooltip(text: String) -> Vector2i:
	var inner := text.get_slice("(", 1).get_slice(")", 0)
	var parts := inner.split(",")
	if parts.size() != 2:
		return Vector2i(-1, -1)
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


# === 参数联动 ============================================================

func _on_source_id_changed(value: float) -> void:
	_source_id = int(value)
	_atlas_coords = Vector2i.ZERO
	_alternative_id = 0
	_coords_x.set_value_no_signal(0)
	_coords_y.set_value_no_signal(0)
	_alt_spin.set_value_no_signal(0)
	_rebuild_grid()
	_queue_all()


func _on_coords_changed(_value: float) -> void:
	_atlas_coords = Vector2i(int(_coords_x.value), int(_coords_y.value))
	_update_grid_highlight()
	_queue_all()


func _on_alt_changed(value: float) -> void:
	_alternative_id = int(value)
	_queue_all()


func _on_physics_layer_changed(_index: int) -> void:
	_queue_all()


func _on_threshold_slider(value: float) -> void:
	_threshold_spin.set_value_no_signal(value)
	_queue_all()


func _on_threshold_spin(value: float) -> void:
	_threshold_slider.set_value_no_signal(value)
	_queue_all()


func _on_simplify_slider(value: float) -> void:
	_simplify_spin.set_value_no_signal(value)
	_queue_all()


func _on_simplify_spin(value: float) -> void:
	_simplify_slider.set_value_no_signal(value)
	_queue_all()


func _on_gap_slider(value: float) -> void:
	_gap_spin.set_value_no_signal(value)
	_queue_all()


func _on_gap_spin(value: float) -> void:
	_gap_slider.set_value_no_signal(value)
	_queue_all()


func _on_param_changed(_value: float) -> void:
	_queue_all()


func _on_mode_changed(index: int) -> void:
	if index >= 0 and index < MODE_HINTS.size():
		_mode_hint.text = MODE_HINTS[index]
	_queue_all()


func _on_view_toggled(_pressed: bool) -> void:
	_preview["show_mask"] = _mask_check.button_pressed
	_preview["show_polygons"] = _poly_check.button_pressed
	_queue_preview()


func _on_fix_flip_toggled(_pressed: bool) -> void:
	_apply_offset_fix()


## 把「位置微调」应用到一个已经存在的生成器上（供预览用，避免再走一次全量重建）。
func _apply_offset_fix(gen: RefCounted = null) -> void:
	var target: RefCounted = gen if gen != null else _generator
	if target == null:
		return
	target["fix_offset"] = Vector2(_fix_x_spin.value, _fix_y_spin.value)
	target["fix_flip_x"] = _fix_flip_x_check.button_pressed
	target["fix_flip_y"] = _fix_flip_y_check.button_pressed
	target["fix_tile_size"] = Vector2(float(_tile_size.x), float(_tile_size.y))


func _on_grid_tile_pressed(coords: Vector2i) -> void:
	_atlas_coords = coords
	_coords_x.set_value_no_signal(coords.x)
	_coords_y.set_value_no_signal(coords.y)
	_alternative_id = 0
	_alt_spin.set_value_no_signal(0)
	_update_grid_highlight()
	_queue_all()


# === 检测与预览 ==========================================================

func _queue_all() -> void:
	_queue_redraw_all.call_deferred()


func _queue_preview() -> void:
	_queue_redraw_preview.call_deferred()


func _queue_redraw_all() -> void:
	_run_detection()
	_queue_redraw_preview()


func _queue_redraw_preview() -> void:
	_preview["polygons"] = _polygons
	_preview.queue_redraw()


func _selected_atlas_coords() -> Vector2i:
	return Vector2i(int(_coords_x.value), int(_coords_y.value))


func _make_generator() -> RefCounted:
	var gen: RefCounted = PixelCollisionGeneratorScript.new()
	gen["alpha_threshold"] = _threshold_spin.value
	gen["mode"] = _mode_button.selected
	gen["min_area"] = _min_area_spin.value
	gen["simplify_tolerance"] = _simplify_spin.value
	gen["gap_bridge"] = int(_gap_spin.value)
	gen["rect_grow"] = int(_grow_spin.value)
	gen["few_rect_cell"] = int(_few_cell_spin.value)
	gen["few_rect_overlap"] = _few_overlap_spin.value
	gen["fix_offset"] = Vector2(_fix_x_spin.value, _fix_y_spin.value)
	gen["fix_flip_x"] = _fix_flip_x_check.button_pressed
	gen["fix_flip_y"] = _fix_flip_y_check.button_pressed
	return gen


func _run_detection() -> void:
	_polygons = []
	var layer := _get_physics_layer_index()
	if _tile_set == null or layer < 0:
		_result = {}
		_preview.clear()
		_stats_label.text = "—"
		return
	var coords := _selected_atlas_coords()
	# 图块像素尺寸：优先用图集的纹理区域尺寸，保证预览的坐标换算和写入用的是同一套。
	var atlas_for_size := _get_atlas_source(_source_id)
	if atlas_for_size != null and atlas_for_size.texture_region_size.x > 0:
		_tile_size = atlas_for_size.texture_region_size
	_generator = _make_generator()
	_result = _generator.call("detect", _tile_set, _source_id, coords, _alternative_id, layer)
	if not bool(_result.get("ok", false)):
		_polygons = []
		_preview.clear()
		_stats_label.text = "未识别到像素"
		_set_status(String(_result.get("error", "")), true)
		return
	_polygons = _result.get("polygons", [])
	_update_preview_content(coords)
	# 微调偏移/翻转与图块像素尺寸有关，等尺寸确定后再套一遍，保证预览与写入一致。
	_apply_offset_fix(_generator)
	_polygons = _build_fixed_polygons()
	var points := 0
	for poly in _polygons:
		points += poly.size()
	_stats_label.text = "识别到 %d 个不透明像素 → %d 个多边形，共 %d 个顶点。" \
			% [int(_result.get("pixel_count", 0)), _polygons.size(), points]


## 微调偏移/翻转的二次套用（预览用；写入时由生成器内部统一处理）。
func _build_fixed_polygons() -> Array:
	if _generator == null:
		return []
	var raw: Array = _result.get("polygons", [])
	var off := Vector2(_fix_x_spin.value, _fix_y_spin.value)
	var fx := _fix_flip_x_check.button_pressed
	var fy := _fix_flip_y_check.button_pressed
	if off == Vector2.ZERO and not fx and not fy:
		return raw
	var out: Array = []
	for poly in raw:
		var pts := PackedVector2Array()
		for p in poly:
			var q: Vector2 = p
			# 坐标原点在图块中心，所以镜像就是把该轴取反
			if fx:
				q.x = -q.x
			if fy:
				q.y = -q.y
			pts.append(q + off)
		out.append(pts)
	return out


func _update_preview_content(coords: Vector2i) -> void:
	var atlas := _get_atlas_source(_source_id)
	var tex: Texture2D = null
	if atlas != null:
		var base := atlas.texture
		if base != null:
			var atlas_image := base.get_image()
			var region := atlas.get_tile_texture_region(coords, 0)
			if atlas_image != null and region.size.x > 0 and region.size.y > 0 \
					and region.position.x >= 0 and region.position.y >= 0 \
					and region.position.x + region.size.x <= atlas_image.get_width() \
					and region.position.y + region.size.y <= atlas_image.get_height():
				tex = ImageTexture.create_from_image(atlas_image.get_region(region))
				_tile_size = region.size
			elif atlas_image != null:
				tex = ImageTexture.create_from_image(atlas_image)
				_tile_size = Vector2i(atlas_image.get_width(), atlas_image.get_height())
	_preview["tile_texture"] = tex
	_preview["generator"] = _generator
	_preview["tile_size"] = Vector2(float(_tile_size.x), float(_tile_size.y))
	_preview["show_mask"] = _mask_check.button_pressed
	_preview["show_polygons"] = _poly_check.button_pressed


func _ensure_current_tile_selected() -> void:
	var atlas := _get_atlas_source(_source_id)
	if atlas == null:
		_rebuild_grid()
		return
	if atlas.get_tiles_count() > 0 and not atlas.has_tile(_atlas_coords):
		_atlas_coords = atlas.get_tile_id(0)
		_coords_x.set_value_no_signal(_atlas_coords.x)
		_coords_y.set_value_no_signal(_atlas_coords.y)
	_update_grid_highlight()


# === 写入 ================================================================

func _on_apply_current() -> void:
	var layer := _get_physics_layer_index()
	if _tile_set == null or layer < 0:
		_set_status("先选中一个 TileMapLayer 并确认物理层。", true)
		return
	var atlas := _get_atlas_source(_source_id)
	var coords := _selected_atlas_coords()
	if atlas == null or not atlas.has_tile(coords):
		_set_status("图块不存在：来源 %d，坐标 %s。" % [_source_id, str(coords)], true)
		return
	var alternatives := [ _alternative_id ]
	if _alt_check.button_pressed:
		alternatives = []
		for i in atlas.get_alternative_tiles_count(coords):
			alternatives.append(atlas.get_alternative_tile_id(coords, i))
	var undo: Variant = _editor.get_editor_undo_redo()
	undo.create_action("自动生成图块碰撞形状")
	undo.add_do_reference(_tile_set)
	var applied := 0
	var polygons_total := 0
	for alt in alternatives:
		if not atlas.has_alternative_tile(coords, alt):
			continue
		var tile_data := atlas.get_tile_data(coords, alt)
		if tile_data == null:
			continue
		var layer_count := _tile_set.get_physics_layers_count()
		for i in layer_count:
			undo.add_undo_method(tile_data, "set_collision_polygons_count", i, \
					tile_data.get_collision_polygons_count(i))
			var old_points := tile_data.get_collision_polygons_count(i)
			for j in old_points:
				undo.add_undo_method(tile_data, "set_collision_polygon_points", i, j, \
						tile_data.get_collision_polygon_points(i, j))
		var gen := _make_generator()
		var result: Dictionary = gen.call("detect", _tile_set, _source_id, coords, alt, layer)
		if not bool(result.get("ok", false)):
			continue
		var polygons: Array = result.get("polygons", [])
		var append := _append_check.button_pressed
		var base_count := tile_data.get_collision_polygons_count(layer) if append else 0
		undo.add_do_method(tile_data, "set_collision_polygons_count", layer, \
				base_count + polygons.size())
		for i in polygons.size():
			undo.add_do_method(tile_data, "set_collision_polygon_points", layer, \
					base_count + i, polygons[i])
		applied += 1
		polygons_total += polygons.size()
	undo.commit_action()
	if applied == 0:
		_set_status("没有写入任何形状（可能该图块没有不透明像素）。", true)
		return
	atlas.emit_changed()
	_tile_set.emit_changed()
	_set_status("已写入：%d 个替代图块，共 %d 个碰撞多边形（物理层 %d）。" \
			% [applied, polygons_total, layer])
	_queue_all()


func _on_apply_all() -> void:
	var layer := _get_physics_layer_index()
	if _tile_set == null or layer < 0:
		_set_status("先选中一个 TileMapLayer 并确认物理层。", true)
		return
	var atlas := _get_atlas_source(_source_id)
	if atlas == null:
		_set_status("当前来源不是图集，无法批量处理。", true)
		return
	var gen := _make_generator()
	var undo: Variant = _editor.get_editor_undo_redo()
	undo.create_action("批量自动生成图块碰撞形状")
	undo.add_do_reference(_tile_set)
	var tiles := 0
	var polygons_total := 0
	var skipped := 0
	for i in atlas.get_tiles_count():
		var coords := atlas.get_tile_id(i)
		var tile_data := atlas.get_tile_data(coords, _alternative_id)
		if tile_data == null:
			continue
		var result: Dictionary = gen.call("detect", _tile_set, _source_id, coords, _alternative_id, layer)
		if not bool(result.get("ok", false)):
			skipped += 1
			continue
		var polygons: Array = result.get("polygons", [])
		for li in _tile_set.get_physics_layers_count():
			undo.add_undo_method(tile_data, "set_collision_polygons_count", li, \
					tile_data.get_collision_polygons_count(li))
			for j in tile_data.get_collision_polygons_count(li):
				undo.add_undo_method(tile_data, "set_collision_polygon_points", li, j, \
						tile_data.get_collision_polygon_points(li, j))
		var append := _append_check.button_pressed
		var base_count := tile_data.get_collision_polygons_count(layer) if append else 0
		undo.add_do_method(tile_data, "set_collision_polygons_count", layer, \
				base_count + polygons.size())
		for k in polygons.size():
			undo.add_do_method(tile_data, "set_collision_polygon_points", layer, \
					base_count + k, polygons[k])
		tiles += 1
		polygons_total += polygons.size()
	undo.commit_action()
	atlas.emit_changed()
	_tile_set.emit_changed()
	_apply_current_button.disabled = false
	_set_status("批量完成：%d 张图块、共 %d 个碰撞多边形；%d 张图块无有效像素被跳过。" \
			% [tiles, polygons_total, skipped])
	_queue_all()


func _set_status(text: String, is_warning: bool = false) -> void:
	_status_label.text = text
	var color := Color(0.55, 0.55, 0.6)
	if is_warning:
		color = Color(0.95, 0.7, 0.35)
	_status_label.add_theme_color_override("font_color", color)
