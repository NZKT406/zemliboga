extends Node
## Туман войны — только картинка у этого игрока, на правила игры он не влияет.
## Карта разбита на клетки 1×1: 0 — ещё не разведано (почти чёрное), EXPLORED — разведано,
## но сейчас никто не смотрит (затемнено), 255 — видно прямо сейчас.
## Видят свои юниты и здания и юниты и здания союзников (общий обзор команды).
## Затемнение рисуется одним полноэкранным слоем: по глубине кадра восстанавливается точка
## мира под каждым пикселем, и по ней берётся значение из текстуры тумана.

const EXPLORED := 105
const UPDATE_EVERY := 0.12        # секунд между пересчётами обзора

var enabled := true
var size := 96
var light := PackedByteArray()    # то, что видно сейчас (с учётом разведанного)
var explored := PackedByteArray() # 0 / EXPLORED
var texture: ImageTexture
var _image: Image
var _quad: MeshInstance3D
var _timer := 0.0
var _discs: Dictionary = {}       # радиус -> полуширины строк круга


func setup(map_size: int, cam: Camera3D, on: bool) -> void:
	size = map_size
	enabled = on
	light.resize(size * size)
	explored.resize(size * size)
	light.fill(255 if not on else 0)
	explored.fill(0)
	_image = Image.create_from_data(size, size, false, Image.FORMAT_L8, light)
	texture = ImageTexture.create_from_image(_image)
	if not on:
		return
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D fog_tex : filter_linear, repeat_disable;
uniform float map_size = 96.0;
void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}
void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec2 uv = clamp(world.xz / map_size, vec2(0.5 / map_size), vec2(1.0 - 0.5 / map_size));
	float c = 1.1 / map_size;      // мягкий край: среднее по соседним клеткам
	float v = texture(fog_tex, uv).r * 0.28;
	v += (texture(fog_tex, uv + vec2(c, 0.0)).r + texture(fog_tex, uv - vec2(c, 0.0)).r
		+ texture(fog_tex, uv + vec2(0.0, c)).r + texture(fog_tex, uv - vec2(0.0, c)).r) * 0.12;
	v += (texture(fog_tex, uv + vec2(c, c)).r + texture(fog_tex, uv - vec2(c, c)).r
		+ texture(fog_tex, uv + vec2(c, -c)).r + texture(fog_tex, uv + vec2(-c, c)).r) * 0.06;
	ALBEDO = vec3(0.01, 0.015, 0.03);
	ALPHA = (1.0 - v) * 0.84;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("fog_tex", texture)
	m.set_shader_parameter("map_size", float(size))
	m.render_priority = 100
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	_quad = MeshInstance3D.new()
	_quad.mesh = q
	_quad.material_override = m
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.extra_cull_margin = 16384.0
	_quad.position = Vector3(0, 0, -1)
	cam.add_child(_quad)


## Пересчёт обзора; force — сразу, не дожидаясь таймера.
func update(sim, me: int, delta: float, force := false) -> void:
	if not enabled:
		return
	_timer -= delta
	if _timer > 0.0 and not force:
		return
	_timer = UPDATE_EVERY
	light = explored.duplicate()
	var night: bool = sim.is_night()
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		var p := int(u["player"])
		if p == me or sim.allies(p, me):
			var r := sight_of(u)
			if night and not u["hero"] and String(sim.players[p]["race"]) != "elves" and not u["def"].has("sight"):
				r *= 0.75      # ночью видно ближе (эльфы видят в темноте, глаза-наблюдатели — тоже)
			_stamp(u["pos"], r)
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		var p := int(b.get("owner", -1)) if String(b["def"].get("role", "")) == "capture" else int(b["player"])
		if p >= 0 and (p == me or sim.allies(p, me)):
			_stamp(b["pos"], sight_of(b))
	_image.set_data(size, size, false, Image.FORMAT_L8, light)
	texture.update(_image)


## Как далеко видит юнит или здание (в клетках).
static func sight_of(t: Dictionary) -> float:
	var d: Dictionary = t["def"]
	if d.has("sight"):
		return float(d["sight"])
	if t["is_building"]:
		if float(d.get("damage", 0)) > 0.0:
			return float(d.get("range", 7.0)) + float(t["size"]) * 0.5 + 2.0
		if String(d.get("role", "")) == "hall":
			return 12.0
		return 6.5 + float(t["size"]) * 0.5
	if t["hero"]:
		return 11.0
	if String(d.get("role", "")) == "worker":
		return 7.0
	return maxf(8.5, float(t["range"]) + 3.0)


func _stamp(center: Vector2, radius: float) -> void:
	var r := int(ceil(radius))
	if not _discs.has(r):
		var rows := PackedInt32Array()
		for dy in range(-r, r + 1):
			rows.append(int(sqrt(maxf(0.0, radius * radius - dy * dy))))
		_discs[r] = rows
	var rows: PackedInt32Array = _discs[r]
	var cx := int(center.x)
	var cy := int(center.y)
	for i in rows.size():
		var y := cy - r + i
		if y < 0 or y >= size:
			continue
		var w: int = rows[i]
		var x0 := maxi(0, cx - w)
		var x1 := mini(size - 1, cx + w)
		var row := y * size
		for x in range(x0, x1 + 1):
			light[row + x] = 255
			explored[row + x] = EXPLORED


func visible_at(p: Vector2) -> bool:
	if not enabled:
		return true
	var x := int(p.x)
	var y := int(p.y)
	if x < 0 or y < 0 or x >= size or y >= size:
		return false
	return light[y * size + x] == 255


func explored_at(p: Vector2) -> bool:
	if not enabled:
		return true
	var x := clampi(int(p.x), 0, size - 1)
	var y := clampi(int(p.y), 0, size - 1)
	return explored[y * size + x] > 0


## Разведано ли хоть что-то из прямоугольника (здание видно, если видели хоть его край).
func explored_rect(cell: Vector2i, n: int) -> bool:
	if not enabled:
		return true
	for y in range(cell.y, cell.y + n):
		for x in range(cell.x, cell.x + n):
			if x >= 0 and y >= 0 and x < size and y < size and explored[y * size + x] > 0:
				return true
	return false


func save() -> Dictionary:
	return {"explored": Marshalls.raw_to_base64(explored.compress(FileAccess.COMPRESSION_DEFLATE)), "size": size}


func restore(d: Dictionary) -> void:
	if int(d.get("size", -1)) != size or not d.has("explored"):
		return
	var raw := Marshalls.base64_to_raw(String(d["explored"])).decompress(size * size, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() == size * size:
		explored = raw
