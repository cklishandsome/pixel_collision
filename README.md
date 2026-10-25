# 像素碰撞 / Pixel Collision

Godot 4 编辑器插件。在 TileMapLayer 的 TileSet 里编辑**碰撞物理层**或**遮挡层**时，一键根据
图块贴图的**不透明像素区域**自动生成碰撞 / 遮挡多边形 —— 不用再手动一个点一个点地描。

- 支持 Godot 4.3 ~ 4.7（在 **4.7.2** 上实测）
- 目标层一键切换：**物理碰撞层** / **遮挡层（2D 光照遮挡）**
- 四种生成方式：精确轮廓 / 凸包 / 逐行矩形 / 少量矩形
- 当前图块、或整个图集一键批量处理
- 完全走编辑器 **撤销/重做**（Ctrl+Z 可回退）
- 实时预览：图块贴图 + 识别到的像素 + 生成的多边形叠在一起看

---

## 安装

1. 把 `addons/pixel_collision/` 整个文件夹拷进你的 Godot 工程（和你的 `project.godot` 同级）。
2. 菜单 **项目 → 项目设置 → 插件**（Project → Project Settings → Plugins），勾选启用 **像素碰撞 / Pixel Collision**。
3. 编辑器右侧 Dock 会出现 **像素碰撞** 面板（`DOCK_SLOT_RIGHT_UL`）。

> 只处理 `TileSetAtlasSource`（图集型图块来源）；场景集合型来源（Scenes Collection）会被跳过并提示。

## 用法

1. 在场景里选中一个 **TileMapLayer**（老工程的 `TileMap` 也认）。
2. 面板下方的**图块选择器**显示整张图集的缩略图，点一下要处理的图块；也可以直接填「来源 ID / 图集坐标 / 替代图块」，
   或点 **从选中单元格刷新** 取当前 TileMapLayer 上已经摆好的那格。
3. **目标层**里先选类型（**物理碰撞层** / **遮挡层**），再选具体要写入的层索引
   （TileSet 里得先加过对应类型的层，否则会提示）。
4. 调「识别设置」（下面有逐项说明），预览会跟着变。
5. 点 **应用到当前图块** 或 **应用到整个图集**。

## 遮挡层（2D 光照遮挡）

TileMapLayer 的 TileSet 面板里有「遮挡」区（Occlusion Layers），它决定图块如何挡住
`PointLight2D` / `DirectionalLight2D` 的光。插件把「目标层」切到 **遮挡层** 后，和物理层
完全一样的流程：

1. 在 TileSet 面板的「遮挡」区点 **添加遮挡层**（Add element），加一个遮挡层。
2. 在插件面板「目标层」里选 **遮挡层（2D 光照遮挡）**，再选层索引。
3. 想单向挡光就调「闭合」和剔除方向；默认 **闭合 + 双向遮挡**，整块图块挡光。
4. 点 **应用到当前图块** / **应用到整个图集**，生成的每条多边形会包成一个独立的
   `OccluderPolygon2D` 写进 TileData 的遮挡层。

| 遮挡选项 | 说明 |
| --- | --- |
| **闭合** | 勾选 = 闭合多边形，整块区域挡光（推荐）；不勾 = 只沿轮廓拉一条挡光线段，适合薄边。 |
| **剔除方向** | 双向遮挡（不剔除）= 两面都挡光；顺时针剔除 / 逆时针剔除 = 剔除某一面的挡光，适合单向光照的薄墙。 |

> 遮挡层写的是 `TileData.set_occluder_polygon()`，和碰撞层是两套独立数据，互不影响；
> 同一次生成不会动另一种层。

## 生成方式怎么选

| 方式 | 什么时候用 |
| --- | --- |
| **精确轮廓**（默认，推荐） | 沿不透明像素外描一圈，最贴合像素。顶点多，但碰撞体最准。带洞的形状会额外生成朝向相反的洞轮廓。 |
| **凸包（顶点最少）** | 把所有像素合成一个凸多边形。顶点最少、最省性能，但凹进去的地方会被填平（例如 L 形会变成矩形）。 |
| **逐行矩形** | 每行连续像素先变成矩形，x 范围完全相同的上下相邻矩形再纵向合并。形状简单、纯方块，适合平台跳跃游戏。 |
| **少量矩形** | 用少量矩形粗略覆盖整体形状，最省形状，允许少量溢出。适合只需要「大致挡住」的场景。 |

## 参数

| 参数 | 说明 |
| --- | --- |
| **Alpha 阈值** | alpha ≥ 该值的像素算「有像素」。默认 0.5。 |
| **最小面积 (px²)** | 小于该面积的多边形会被丢掉（去噪点）。默认 2。 |
| **简化容差 (px)** | Ramer–Douglas–Peucker 简化容差。0 = 保留每个像素的直角（顶点极多）；0.5~1 通常能在几乎不失真的前提下明显减少顶点。仅「精确轮廓」用。 |
| **缝隙桥接** | 把只被实体像素包围的空洞填实。抗锯齿描边常留 1 像素缝，填上可避免碰撞体开裂。0 = 关闭，常用 7。 |
| **膨胀 (px)** | 仅「逐行矩形」：正数向外膨胀，负数向内收缩。普通图块想要「稍微大一点点的碰撞体」时用 1。 |
| **少量矩形粒度** | 仅「少量矩形」：每次覆盖的方格边长（像素）。越大越省形状。 |
| **允许溢出** | 仅「少量矩形」：一格内非实体像素占比低于该值时也算被覆盖。 |
| **追加到已有形状** | 不勾选 = 替换该物理层上已有的形状；勾选 = 追加。 |
| **同时应用到该图块的所有替代图块** | 替代图块（alternative tile）一起处理。 |

### 位置微调

**正常情况下完全不用动。** 插件的坐标约定已经和 Godot 对齐：

- 原点在 **图块中心**（不是左上角）
- **y 轴向下**为正

所以一块铺满 390×390 图块的碰撞矩形会是 `(-195,-195) ~ (+195,+195)`，这正是 Godot
图块碰撞多边形要的形式（390 / 2 = 195）。

只有在你确实遇到整体偏移时才用这一组：

| 参数 | 说明 |
| --- | --- |
| **整体偏移 X (px)** | 正数右移、负数左移。 |
| **整体偏移 Y (px)** | 正数**下**移、负数**上**移（与本地 y 轴同向）。 |
| **左右翻转 / 上下翻转** | 形状整体镜像了（不是单纯平移）时才勾；镜像就是以图块中心把该轴取反。 |

记忆口诀：**图形偏右填负 X、偏下填负 Y。** 这三项作用范围覆盖「精确轮廓 / 凸包 /
逐行矩形 / 少量矩形」全部四种模式，预览和最终写进 TileData 的顶点完全一致。

> 改完微调后要再点一次 **应用到当前图块** / **应用到整个图集** —— 微调不会自动重刷已经写好的形状。

## 实现说明

- **坐标**：生成的顶点是 **Godot 图块本地坐标 —— 原点在图块中心、x 向右为正、y 向下为正**。
  一块铺满 390×390 图块的碰撞矩形就是 `(-195,-195) ~ (+195,+195)`，可以直接和文件里
  TileData 的顶点对照。**遮挡多边形用的是同一套坐标**，碰撞和遮挡可以放心共用同一份检测结果。
- **贴图取样**：优先用 `TileSetAtlasSource.get_runtime_texture()` + `get_runtime_tile_texture_region()`
  （带 padding 的运行时贴图），取不到时回退到原始贴图 + `get_tile_texture_region()`，
  两种情况下都只采样「这块图块自己的像素区域」。
- **描边算法**：把掩码网格的边界边按「实体在左侧」的有向边收集起来，再始终选**最右转**的
  下一条边串成闭合轮廓。这样外轮廓天然是逆时针、洞天然是顺时针，不需要额外判断。
- **撤销**：`TileData` 只能「先定多边形数量、再逐条 set points」，所以撤销时把
  **所有同类层**的旧数量与旧内容逐条记录下来（碰撞层存顶点，遮挡层存整个
  `OccluderPolygon2D`），重做时再逐条写回。恢复时先还原数量、再还原内容，避免
  新形状比旧形状少时索引越界。
- **性能**：像素采样是逐像素 `Image.get_pixel()`，纯 GDScript。「应用到整个图集」在超大图集上
  可能要几秒；先用小图集试一下。

## 已知限制

- 只支持图集来源（`TileSetAtlasSource`），不支持场景集合来源。
- 动画图块只用**第 0 帧**生成形状。
- 物理层 / 遮挡层必须先在 TileSet 面板里添加好；插件不会替你创建层，只会向已有层写入。
- 图块若开了「纹理内边距（使用纹理 padding）」，取样会自动走运行时贴图；极旧版本 Godot 上
  该接口行为不同的话，会回退到原始贴图区域，可能把 padding 也算进像素里。

## 目录结构

```
addons/pixel_collision/
  plugin.cfg                          插件声明
  plugin.gd                           EditorPlugin 入口（挂 Dock、跟着选择刷新）
  pixel_collision_generator.gd        纯算法：像素掩码 -> 碰撞 / 遮挡多边形（可脱离编辑器单用）
  pixel_collision_dock.gd             主面板 UI
  pixel_collision_preview.gd          预览控件（贴图 + 像素 + 多边形叠加）
```

想单独用算法（比如在运行时或工具脚本里批量生成）：

```gdscript
var gen := PixelCollisionGenerator.new()
gen.alpha_threshold = 0.5
gen.mode = PixelCollisionGenerator.Mode.CONTOUR
var result := gen.detect(tile_set, source_id, atlas_coords, alternative_id, physics_layer)
if result.ok:
    var td := (tile_set.get_source(source_id) as TileSetAtlasSource).get_tile_data(atlas_coords, alternative_id)
    gen.push_to_tile_data(td, physics_layer, result.polygons, false)
```

写遮挡层时把目标类型换成 `TargetKind.OCCLUSION`，再用 `push_occluders_to_tile_data()`：

```gdscript
var result := gen.detect(tile_set, source_id, atlas_coords, alternative_id,
        occlusion_layer, PixelCollisionGenerator.TargetKind.OCCLUSION)
if result.ok:
    var td := (tile_set.get_source(source_id) as TileSetAtlasSource).get_tile_data(atlas_coords, alternative_id)
    gen.push_occluders_to_tile_data(td, occlusion_layer, result.polygons,
            false, true, OccluderPolygon2D.CULL_DISABLED)
```

## 示例：
<img width="3840" height="2088" alt="image" src="https://github.com/user-attachments/assets/d3096dfc-998f-4250-b898-4bf7f2a98b3c" />
