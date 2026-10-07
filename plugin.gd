@tool
extends EditorPlugin

## 插件入口：把一个「像素碰撞」面板挂到右侧 Dock。
##
## 面板本身是 `pixel_collision_dock.gd`，纯自建控件，不依赖 TileSet 编辑器的内部 API，
## 因此在不同 4.x 版本上都能用。

const DockScript := preload("res://addons/pixel_collision/pixel_collision_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.name = "PixelCollision"
	# 面板只需要 EditorInterface（选中的节点、场景根、Undo/Redo 都在上面），
	# 这样面板本身不依赖 EditorPlugin 实例，也便于单独测试。
	if _dock.has_method("setup"):
		_dock.call("setup", get_editor_interface())
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
	# 让面板跟着编辑器里选中的节点刷新。
	var selection := get_editor_interface().get_selection()
	if selection != null and not selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.connect(_on_selection_changed)
	if not get_tree().node_added.is_connected(_on_tree_changed):
		get_tree().node_added.connect(_on_tree_changed)
	if not scene_changed.is_connected(_on_scene_changed):
		scene_changed.connect(_on_scene_changed)


func _exit_tree() -> void:
	var selection := get_editor_interface().get_selection()
	if selection != null and selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)
	if get_tree() != null:
		if get_tree().node_added.is_connected(_on_tree_changed):
			get_tree().node_added.disconnect(_on_tree_changed)
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _on_selection_changed() -> void:
	_refresh_dock()


func _on_scene_changed(_root: Node) -> void:
	_refresh_dock()


func _on_tree_changed(_node: Node) -> void:
	_refresh_dock()


func _refresh_dock() -> void:
	if _dock != null and _dock.has_method("refresh"):
		_dock.call("refresh")
