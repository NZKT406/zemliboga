extends RefCounted
## Low poly модели, собранные кодом из простых фигур.
## Вид юнита задаётся блоком "model" в таблице расы; вид здания — его "shape".
## У юнитов руки, ноги, голова и туловище — отдельные подвижные части:
## ими управляет анимация (scripts/anim.gd).

const STEEL := Color("#c3c9d1")
const IRON := Color("#6e737a")
const WOOD := Color("#7a5a2a")
const DARKWOOD := Color("#4f3a22")
const LEATHER := Color("#5a4630")
const IVORY := Color("#ebe4cf")
const STONE := Color("#9a958a")
const GOLD := Color("#f0c63a")
const STRAW := Color("#d2b04a")

static var _mats: Dictionary = {}


## Общая «грязная» гамма игры: цвета приглушаются, темнеют и слегка уходят в бурый.
## Меняя три числа здесь, можно перекрасить всю игру разом.
static func grade(c: Color) -> Color:
	var out := Color.from_hsv(c.h, c.s * 0.58, c.v * 0.74, c.a)
	return out.lerp(Color(0.25, 0.22, 0.18, c.a), 0.14)


## Небольшой разнобой в тоне соседних деталей, чтобы поверхности не были одноцветными.
static func _jitter(pos: Vector3) -> float:
	var n := sin(pos.x * 12.9898 + pos.y * 78.233 + pos.z * 37.719) * 43758.5453
	return floorf((n - floorf(n)) * 4.0) * 0.045


static func mat(color: Color, glow: bool = false) -> StandardMaterial3D:
	color = grade(color) if not glow else Color.from_hsv(color.h, color.s * 0.85, color.v * 0.92, color.a)
	var key := color.to_html() + ("g" if glow else "")
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 1.0
		if glow:
			m.emission_enabled = true
			m.emission = color
			m.emission_energy_multiplier = 1.4
		_mats[key] = m
	return _mats[key]


static func _add(parent: Node3D, mesh: Mesh, pos: Vector3, color: Color, rot := Vector3.ZERO, glow := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat(color if glow else color.darkened(_jitter(pos)), glow)
	parent.add_child(mi)
	return mi


static func box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, rot := Vector3.ZERO, glow := false) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	return _add(parent, m, pos, color, rot, glow)


static func cyl(parent: Node3D, r_top: float, r_bottom: float, h: float, pos: Vector3, color: Color, sides := 6, rot := Vector3.ZERO, glow := false) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = r_top
	m.bottom_radius = r_bottom
	m.height = h
	m.radial_segments = sides
	m.rings = 1
	return _add(parent, m, pos, color, rot, glow)


static func ball(parent: Node3D, r: float, pos: Vector3, color: Color, scale := Vector3.ONE, glow := false) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 7
	m.rings = 4
	var mi := _add(parent, m, pos, color, Vector3.ZERO, glow)
	mi.scale = scale
	return mi


## Двускатная крыша: конёк идёт вдоль оси Z.
static func roof(parent: Node3D, size: Vector3, pos: Vector3, color: Color, rot := Vector3.ZERO) -> MeshInstance3D:
	var m := PrismMesh.new()
	m.size = size
	return _add(parent, m, pos, color, rot)


static func pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


static func col(spec: Dictionary, key: String, fallback: String) -> Color:
	return Color(String(spec.get(key, fallback)))


static func _flag(parent: Node3D, base: Vector3, team: Color, h: float, size := 0.5) -> void:
	box(parent, Vector3(0.05, h, 0.05), base + Vector3(0, h * 0.5, 0), DARKWOOD)
	box(parent, Vector3(size, size * 0.6, 0.03), base + Vector3(size * 0.5 + 0.03, h - size * 0.35, 0), team)
	ball(parent, 0.05, base + Vector3(0, h + 0.03, 0), GOLD)


# =====================================================================
#  ЮНИТЫ
# =====================================================================

static func unit(spec: Dictionary, team: Color) -> Node3D:
	var root: Node3D
	if String(spec.get("shape", "humanoid")) == "wolf":
		root = _wolf(spec)
	elif String(spec.get("shape", "")) == "engine":
		root = _engine(spec, team)
	elif String(spec.get("shape", "")) == "slime":
		root = _slime(spec)
	elif String(spec.get("shape", "")) == "dragon":
		root = _dragon(spec)
	elif String(spec.get("shape", "")) == "ward":
		root = _ward(spec, team)
	elif String(spec.get("shape", "")) == "spider":
		root = _spider(spec)
	else:
		root = _humanoid(spec, team)
	if spec.get("glow", false):
		_ghostly(root)
	var keep: Array = []
	for v in (root.get_meta("parts") as Dictionary).values():      # то, что игра прячет и показывает, не сливаем
		if v is MeshInstance3D:
			keep.append(v)
	merge(root, keep)
	return root


## Призрачный вид для призванных духов: полупрозрачные и светятся.
static func _ghostly(node: Node) -> void:
	for c in node.get_children():
		if c is MeshInstance3D:
			var old: StandardMaterial3D = (c as MeshInstance3D).material_override
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(old.albedo_color.r, old.albedo_color.g, old.albedo_color.b, 0.72)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.emission_enabled = true
			m.emission = old.albedo_color
			m.emission_energy_multiplier = 0.9
			(c as MeshInstance3D).material_override = m
			(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ghostly(c)


static func _humanoid(spec: Dictionary, team: Color) -> Node3D:
	var root := Node3D.new()
	var body := pivot(root, Vector3.ZERO)
	body.name = "Body"
	var s: float = float(spec.get("scale", 1.0))
	var bulk: float = float(spec.get("bulk", 1.0))
	var mounted := String(spec.get("shape", "")) == "mounted"
	var ogre: bool = spec.get("ogre", false)
	var rocky: bool = spec.get("rocky", false)
	var armored: bool = spec.get("armored", false)
	var head_kind := String(spec.get("head", "bald"))
	var weapon := String(spec.get("weapon", ""))
	var skin := col(spec, "skin", "#e2b68e")
	var cloth := col(spec, "cloth", "#888888")
	var pants := col(spec, "pants", "#5a4630")
	var bare := ogre or rocky
	var w := 0.36 * bulk
	var dp := 0.2 * pow(bulk, 0.8)
	var hip := 0.38 if ogre else 0.46
	var torso_h := 0.52 if ogre else 0.46
	var legs: Array = []
	var seat := 0.0

	if mounted:
		seat = 1.02
		hip = 0.0
		_horse(body, legs, team, col(spec, "horse", "#7a5636"))

	var fig := pivot(body, Vector3(0, seat, 0))
	fig.scale = Vector3.ONE * s

	# ----- ноги -----
	if mounted:
		for sx in [-1.0, 1.0]:
			var x: float = sx
			box(fig, Vector3(w * 0.32, 0.15, 0.36), Vector3(x * w * 0.5, 0.02, 0.12), pants)
			box(fig, Vector3(w * 0.28, 0.34, 0.13), Vector3(x * w * 0.62, -0.2, 0.24), pants.darkened(0.3))
	elif spec.get("naga", false):      # наг: вместо ног — змеиный хвост из двух колышущихся частей
		var scales := col(spec, "tail", "#2a8a7a")
		var upper := pivot(fig, Vector3(0, hip, 0))
		cyl(upper, w * 0.48, w * 0.42, hip * 1.05, Vector3(0, -hip * 0.5, -0.05), scales, 8, Vector3(0.35, 0, 0))
		box(upper, Vector3(w * 0.5, hip * 0.8, 0.04), Vector3(0, -hip * 0.45, w * 0.2), scales.lightened(0.25), Vector3(0.35, 0, 0))
		var lower := pivot(upper, Vector3(0, -hip * 0.95, -hip * 0.4))
		cyl(lower, w * 0.4, 0.04, hip * 1.6, Vector3(0, -0.02, -hip * 0.8), scales.darkened(0.12), 8, Vector3(PI / 2 - 0.15, 0, 0))
		cyl(lower, 0.0, 0.1, 0.25, Vector3(0, 0.0, -hip * 1.65), scales.lightened(0.3), 4, Vector3(PI / 2, 0, 0))
		legs.append(upper)
		legs.append(lower)
	else:
		var boots := skin.darkened(0.12) if bare else pants.darkened(0.4)
		for sx in [-1.0, 1.0]:
			var x: float = sx
			var leg := pivot(fig, Vector3(x * w * 0.25, hip, 0))
			box(leg, Vector3(w * 0.38, hip * 0.72, dp * 0.9), Vector3(0, -hip * 0.36, 0), skin if rocky else pants)
			box(leg, Vector3(w * 0.42, hip * 0.3, dp * 1.35), Vector3(0, -hip * 0.85, dp * 0.14), boots)
			legs.append(leg)

	# ----- туловище -----
	var torso := pivot(fig, Vector3(0, hip, 0))
	box(torso, Vector3(w, torso_h, dp), Vector3(0, torso_h * 0.5, 0), skin if bare else cloth)
	if rocky:
		for i in 5:
			var a := float(i) * 1.9
			ball(torso, 0.1 + 0.03 * (i % 3), Vector3(cos(a) * w * 0.45, torso_h * (0.35 + 0.15 * (i % 3)), sin(a) * dp * 0.55), skin.lightened(0.12 * (i % 2)).darkened(0.1 * ((i + 1) % 2)), Vector3(1.2, 0.9, 1.1))
		box(torso, Vector3(w * 0.5, 0.05, dp * 0.7), Vector3(-w * 0.2, torso_h + 0.02, 0), Color("#5f8a3f"))
		box(torso, Vector3(w * 0.3, 0.12, 0.03), Vector3(0, torso_h * 0.55, dp * 0.52), team)
	elif ogre:
		ball(torso, w * 0.5, Vector3(0, torso_h * 0.36, dp * 0.3), skin.lightened(0.07), Vector3(1.05, 0.9, 0.95))
		box(torso, Vector3(w * 0.96, 0.2, dp * 1.15), Vector3(0, 0.04, 0), cloth)
		box(torso, Vector3(w * 0.42, 0.3, 0.03), Vector3(0, -0.1, dp * 0.6), team)
		box(torso, Vector3(w * 1.25, 0.08, dp * 1.1), Vector3(0, torso_h * 0.62, 0), cloth.darkened(0.25), Vector3(0, 0, 0.7))
		ball(torso, 0.05, Vector3(-w * 0.2, torso_h * 0.5, dp * 0.56), GOLD)
	else:
		box(torso, Vector3(w * 1.04, 0.07, dp * 1.08), Vector3(0, 0.05, 0), LEATHER)
		box(torso, Vector3(0.06, 0.06, 0.02), Vector3(0, 0.05, dp * 0.56), GOLD)
		box(torso, Vector3(w * 0.46, torso_h * 0.78, 0.025), Vector3(0, torso_h * 0.52, dp * 0.5 + 0.013), team)
		if armored:
			box(torso, Vector3(w * 0.8, 0.07, dp * 1.1), Vector3(0, torso_h - 0.03, 0), cloth.lightened(0.15))
	if spec.get("robe", false):
		box(torso, Vector3(w * 1.08, hip * 0.98, dp * 1.25), Vector3(0, -hip * 0.47, 0), cloth)
		box(torso, Vector3(w * 1.12, 0.06, dp * 1.3), Vector3(0, -hip * 0.93, 0), GOLD)
		box(torso, Vector3(w * 0.3, torso_h + hip * 0.9, 0.03), Vector3(0, (torso_h - hip * 0.9) * 0.5, dp * 0.64), team)
	if spec.get("hero", false):
		box(torso, Vector3(w * 1.06, 0.05, dp * 1.1), Vector3(0, torso_h * 0.3, 0), GOLD)
		ball(torso, 0.07, Vector3(0, torso_h * 0.72, dp * 0.55), GOLD, Vector3.ONE, true)
	if spec.get("quiver", false):
		box(torso, Vector3(0.1, 0.4, 0.09), Vector3(-w * 0.15, torso_h * 0.6, -dp * 0.5 - 0.06), LEATHER, Vector3(0, 0, 0.3))
		for i in 3:
			box(torso, Vector3(0.02, 0.1, 0.02), Vector3(-w * 0.26 + i * 0.03, torso_h * 0.6 + 0.24, -dp * 0.5 - 0.06), IVORY)
	if spec.get("cape", false):
		box(torso, Vector3(w * 0.92, 0.62, 0.03), Vector3(0, torso_h * 0.42, -dp * 0.5 - 0.04), team.darkened(0.1), Vector3(-0.14, 0, 0))

	# ноша рабочего за спиной (показывается, когда он что-то несёт)
	var gold_node: Node3D = null
	var wood_node: Node3D = null
	if weapon == "pick":
		gold_node = pivot(torso, Vector3(0, torso_h * 0.62, -dp * 0.5 - 0.15))
		ball(gold_node, 0.17, Vector3.ZERO, Color("#b8935a"), Vector3(1, 1.1, 0.9))
		ball(gold_node, 0.07, Vector3(0.05, 0.16, 0), GOLD)
		ball(gold_node, 0.06, Vector3(-0.05, 0.15, 0.04), GOLD)
		wood_node = pivot(torso, Vector3(0, torso_h * 0.66, -dp * 0.5 - 0.13))
		cyl(wood_node, 0.085, 0.085, 0.7, Vector3.ZERO, WOOD, 6, Vector3(0, 0, PI / 2))
		cyl(wood_node, 0.07, 0.07, 0.6, Vector3(0, 0.13, 0.02), WOOD.lightened(0.1), 6, Vector3(0, 0, PI / 2))
		gold_node.visible = false
		wood_node.visible = false

	# ----- голова -----
	var hr := 0.13 if ogre else 0.15
	var head := pivot(torso, Vector3(0, torso_h + 0.02, 0))
	if rocky:
		box(head, Vector3(hr * 2.1, hr * 1.7, hr * 1.9), Vector3(0, hr * 0.85, 0), skin.lightened(0.08))
		box(head, Vector3(hr * 1.2, hr * 0.5, hr * 1.2), Vector3(0, hr * 1.9, -0.02), Color("#5f8a3f"))
	else:
		ball(head, hr, Vector3(0, hr, 0), skin)
	var eye := Color("#56e6ff") if rocky else Color("#22201e")
	for sx in [-1.0, 1.0]:
		var x: float = sx
		box(head, Vector3(0.035, 0.04, 0.03), Vector3(x * hr * 0.42, hr * 1.12, hr * 0.92), eye, Vector3.ZERO, rocky)
	if ogre:
		box(head, Vector3(hr * 1.6, hr * 0.62, hr * 1.35), Vector3(0, hr * 0.5, hr * 0.22), skin.darkened(0.1))
		box(head, Vector3(hr * 1.5, hr * 0.2, hr * 0.4), Vector3(0, hr * 1.4, hr * 0.8), skin.darkened(0.22))
		for sx in [-1.0, 1.0]:
			var x: float = sx
			cyl(head, 0.0, 0.035, 0.16, Vector3(x * hr * 0.55, hr * 0.92, hr * 0.85), IVORY, 4)
			box(head, Vector3(0.05, 0.1, 0.07), Vector3(x * hr * 1.02, hr * 1.1, 0), skin.darkened(0.08), Vector3(0, 0, -x * 0.5))
		if spec.has("hair"):
			for i in 4:
				cyl(head, 0.0, 0.05, 0.2, Vector3(0, hr * 2.05, hr * (0.5 - i * 0.4)), col(spec, "hair", "#c94a3a"), 4, Vector3(-0.3, 0, 0))
	if spec.get("ears", false):     # острые эльфийские уши
		for sx in [-1.0, 1.0]:
			var x: float = sx
			cyl(head, 0.0, 0.035, 0.2, Vector3(x * hr * 1.1, hr * 1.25, -0.02), skin, 4, Vector3(0.3, 0, -x * 1.0))
	if spec.has("beard"):      # борода гнома: широкая, до пояса, с усами
		var beard := col(spec, "beard", "#8a5a2a")
		box(head, Vector3(hr * 1.55, hr * 0.9, hr * 0.7), Vector3(0, hr * 0.45, hr * 0.62), beard)
		cyl(head, hr * 0.8, 0.03, hr * 1.9, Vector3(0, -hr * 0.6, hr * 0.72), beard.darkened(0.08), 5)
		for sx in [-1.0, 1.0]:
			box(head, Vector3(hr * 0.6, 0.05, 0.06), Vector3(float(sx) * hr * 0.4, hr * 0.85, hr * 1.0), beard.lightened(0.1), Vector3(0, 0, -float(sx) * 0.35))
	if spec.has("hair") and not ogre:
		var hair := col(spec, "hair", "#7a5230")
		ball(head, hr * 1.06, Vector3(0, hr * 1.12, -hr * 0.12), hair, Vector3(1, 0.95, 1))
		box(head, Vector3(hr * 1.7, hr * 2.1, hr * 0.5), Vector3(0, hr * 0.35, -hr * 0.85), hair)
	match head_kind:
		"circlet":
			box(head, Vector3(hr * 2.15, 0.035, hr * 2.15), Vector3(0, hr * 1.5, 0), GOLD)
			ball(head, 0.04, Vector3(0, hr * 1.55, hr * 1.05), team, Vector3.ONE, true)
		"antlers":
			cyl(head, hr * 1.15, hr * 1.3, 0.1, Vector3(0, hr * 0.15, 0), cloth.darkened(0.2), 6)
			ball(head, hr * 1.1, Vector3(0, hr * 1.2, -hr * 0.15), cloth.darkened(0.2), Vector3(1, 0.9, 1))
			for sx in [-1.0, 1.0]:
				var x: float = sx
				box(head, Vector3(0.035, 0.34, 0.035), Vector3(x * hr * 0.75, hr * 2.3, 0), IVORY, Vector3(0, 0, -x * 0.45))
				box(head, Vector3(0.03, 0.18, 0.03), Vector3(x * hr * 1.25, hr * 2.6, 0), IVORY, Vector3(0, 0, -x * 1.1))
				box(head, Vector3(0.03, 0.16, 0.03), Vector3(x * hr * 0.7, hr * 2.85, 0.03), IVORY, Vector3(0.4, 0, x * 0.2))
			box(head, Vector3(hr * 1.1, hr * 1.1, hr * 0.45), Vector3(0, hr * 0.2, hr * 0.75), col(spec, "hair", "#8a8a8a"))
		"leaves":
			for i in 5:
				var a := float(i) * 1.3
				ball(head, hr * (1.1 + 0.25 * (i % 2)), Vector3(cos(a) * hr * 0.9, hr * (1.9 + 0.35 * (i % 3)), sin(a) * hr * 0.9), Color("#4f9a3f").lightened(0.07 * (i % 3)))
			for sx in [-1.0, 1.0]:
				ball(torso, 0.16, Vector3(float(sx) * w * 0.55, torso_h + 0.05, -0.02), Color("#3f8a3a"))
		"hat":
			cyl(head, hr * 1.75, hr * 1.75, 0.03, Vector3(0, hr * 1.72, 0), STRAW, 8)
			cyl(head, hr * 0.7, hr * 0.95, 0.13, Vector3(0, hr * 1.72 + 0.07, 0), STRAW.darkened(0.08), 8)
		"helmet":
			ball(head, hr * 1.13, Vector3(0, hr * 1.22, -0.01), STEEL, Vector3(1, 0.82, 1))
			box(head, Vector3(0.035, hr * 0.9, 0.03), Vector3(0, hr * 0.95, hr * 1.02), STEEL.darkened(0.15))
			box(head, Vector3(hr * 2.3, 0.04, hr * 2.3), Vector3(0, hr * 1.05, 0), STEEL.darkened(0.2))
			box(head, Vector3(0.045, 0.13, 0.22), Vector3(0, hr * 2.2, -0.03), team)
		"knight":
			cyl(head, hr * 1.12, hr * 1.18, hr * 2.2, Vector3(0, hr * 1.02, 0), STEEL, 8)
			box(head, Vector3(hr * 1.5, 0.04, 0.04), Vector3(0, hr * 1.15, hr * 1.1), Color("#1c1a18"))
			box(head, Vector3(0.03, hr * 0.9, 0.04), Vector3(0, hr * 0.75, hr * 1.12), STEEL.darkened(0.2))
			cyl(head, hr * 0.5, hr * 1.12, 0.07, Vector3(0, hr * 2.15, 0), STEEL.darkened(0.1), 8)
			box(head, Vector3(0.05, 0.3, 0.24), Vector3(0, hr * 2.2 + 0.14, -0.08), team, Vector3(-0.25, 0, 0))
		"crown":
			ball(head, hr * 1.13, Vector3(0, hr * 1.22, -0.01), STEEL.lightened(0.1), Vector3(1, 0.82, 1))
			box(head, Vector3(hr * 2.3, 0.05, hr * 2.3), Vector3(0, hr * 1.05, 0), GOLD)
			for i in 6:
				var a := float(i) * TAU / 6.0
				cyl(head, 0.0, 0.035, 0.12, Vector3(sin(a) * hr * 0.95, hr * 1.85, cos(a) * hr * 0.95), GOLD, 4)
			box(head, Vector3(0.05, 0.2, 0.26), Vector3(0, hr * 2.3, -0.06), team)
		"wizard":
			cyl(head, hr * 1.9, hr * 1.9, 0.03, Vector3(0, hr * 1.7, 0), cloth.darkened(0.15), 8)
			cyl(head, 0.0, hr * 1.05, 0.5, Vector3(0, hr * 1.7 + 0.25, -0.03), cloth, 6, Vector3(-0.2, 0, 0))
			box(head, Vector3(hr * 2.0, 0.05, hr * 2.0), Vector3(0, hr * 1.8, 0), GOLD)
			box(head, Vector3(hr * 1.2, hr * 1.3, hr * 0.5), Vector3(0, hr * 0.25, hr * 0.75), Color("#f1eee6"))
			box(head, Vector3(hr * 0.7, hr * 0.8, hr * 0.4), Vector3(0, -hr * 0.6, hr * 0.8), Color("#f1eee6"))
		"horned":
			ball(head, hr * 1.2, Vector3(0, hr * 1.35, -0.01), IRON, Vector3(1, 0.75, 1))
			box(head, Vector3(hr * 2.5, 0.05, hr * 2.4), Vector3(0, hr * 1.2, 0), IRON.darkened(0.2))
			for sx in [-1.0, 1.0]:
				var x: float = sx
				cyl(head, 0.0, 0.07, 0.42, Vector3(x * hr * 1.5, hr * 1.9, 0), IVORY, 5, Vector3(0, 0, -x * 0.9))
			ball(head, 0.05, Vector3(0, hr * 1.6, hr * 1.1), GOLD, Vector3.ONE, true)
		"feathers":
			box(head, Vector3(hr * 2.2, 0.07, hr * 2.2), Vector3(0, hr * 1.55, 0), LEATHER)
			var fc := [Color("#e0443a"), Color("#f0c63a"), team, Color("#f0c63a"), Color("#e0443a")]
			for i in 5:
				var lean := (float(i) - 2.0) * 0.32
				box(head, Vector3(0.07, 0.44, 0.03), Vector3(sin(lean) * 0.2, hr * 1.6 + 0.24, -hr * 0.6), fc[i], Vector3(-0.2, 0, -lean))
			box(head, Vector3(hr * 1.4, 0.04, 0.03), Vector3(0, hr * 0.85, hr * 0.98), Color("#f1eee6"))
		"fins":     # наги: гребень-плавник на голове и плавники вместо ушей
			var fin := col(spec, "fin", "#e0705a")
			box(head, Vector3(0.03, hr * 0.9, hr * 2.0), Vector3(0, hr * 2.0, -hr * 0.1), fin, Vector3(0.15, 0, 0))
			for sx in [-1.0, 1.0]:
				box(head, Vector3(0.03, hr * 0.8, hr * 0.7), Vector3(float(sx) * hr * 1.05, hr * 1.1, -hr * 0.2), fin, Vector3(0, float(sx) * 0.5, float(sx) * 0.4))
		"coral":    # корона из кораллов (королева, герои)
			box(head, Vector3(hr * 2.1, 0.04, hr * 2.1), Vector3(0, hr * 1.55, 0), GOLD)
			for i in 5:
				var a := float(i) * TAU / 5.0
				cyl(head, 0.01, 0.045, 0.28, Vector3(sin(a) * hr * 0.9, hr * 1.85, cos(a) * hr * 0.9), Color("#ff7a8a"), 4, Vector3(cos(a) * 0.3, 0, -sin(a) * 0.3))
			ball(head, 0.05, Vector3(0, hr * 1.7, hr * 1.0), Color("#9fe8ff"), Vector3.ONE, true)
		"hood", "mask":
			var hood := cloth.darkened(0.2)
			cyl(head, 0.0, hr * 1.3, 0.34, Vector3(0, hr * 1.85, -0.04), hood, 6, Vector3(-0.25, 0, 0))
			cyl(head, hr * 1.2, hr * 1.35, 0.1, Vector3(0, hr * 0.15, 0), hood, 6)
			box(head, Vector3(hr * 2.1, hr * 0.9, hr * 0.5), Vector3(0, hr * 1.5, -hr * 0.75), hood)
			if head_kind == "mask":
				box(head, Vector3(hr * 1.75, hr * 0.7, hr * 0.6), Vector3(0, hr * 0.62, hr * 0.72), Color("#7a2b2b"))

	# ----- руки -----
	var aw := 0.11 * pow(bulk, 0.9) * (1.2 if ogre else 1.0)
	var arm_len := 0.56 if ogre else 0.46
	var arms: Array = []
	for sx in [1.0, -1.0]:
		var x: float = sx
		var arm := pivot(torso, Vector3(x * (w * 0.5 + aw * 0.45), torso_h - 0.05, 0))
		box(arm, Vector3(aw, arm_len * 0.5, aw), Vector3(0, -arm_len * 0.25, 0), skin if bare else cloth)
		box(arm, Vector3(aw * 0.9, arm_len * 0.46, aw * 0.9), Vector3(0, -arm_len * 0.72, 0), STEEL.darkened(0.1) if (armored and not ogre) else skin)
		ball(arm, aw * (1.0 if weapon == "fists" else 0.62), Vector3(0, -arm_len, 0), skin)
		if armored and not ogre:
			box(arm, Vector3(aw * 1.6, 0.11, aw * 1.7), Vector3(x * 0.02, 0.02, 0), team)
			box(arm, Vector3(aw * 1.3, 0.05, aw * 1.4), Vector3(x * 0.03, 0.09, 0), STEEL)
		elif armored and x > 0.0:
			ball(arm, aw * 1.15, Vector3(x * 0.02, 0.04, 0), IRON, Vector3(1.1, 0.8, 1.1))
			for i in 3:
				cyl(arm, 0.0, 0.035, 0.16, Vector3(x * 0.04 + (i - 1) * 0.07, 0.15, (i - 1) * 0.02), IVORY, 4)
			box(arm, Vector3(aw * 1.18, 0.07, aw * 1.18), Vector3(0, -arm_len * 0.3, 0), team)
		else:
			box(arm, Vector3(aw * 1.18, 0.07, aw * 1.18), Vector3(0, -arm_len * 0.3, 0), team)
		arms.append(arm)
	var arm_l: Node3D = arms[0]
	var arm_r: Node3D = arms[1]

	# ----- оружие (правая рука, модель смотрит в +Z) -----
	var ammo: Node3D = null
	var attack := "swing"
	var wp := pivot(arm_r, Vector3(0, -arm_len, 0))
	wp.rotation.x = -0.45
	match weapon:
		"sword":
			box(wp, Vector3(0.035, 0.1, 0.62), Vector3(0, 0, 0.42), STEEL)
			box(wp, Vector3(0.012, 0.03, 0.56), Vector3(0, 0, 0.42), STEEL.darkened(0.2))
			box(wp, Vector3(0.24, 0.05, 0.05), Vector3(0, 0, 0.09), GOLD)
			box(wp, Vector3(0.04, 0.04, 0.16), Vector3(0, 0, 0), LEATHER)
			ball(wp, 0.04, Vector3(0, 0, -0.09), GOLD)
		"pick":
			box(wp, Vector3(0.045, 0.045, 0.66), Vector3(0, 0, 0.26), WOOD)
			box(wp, Vector3(0.05, 0.3, 0.07), Vector3(0, 0, 0.57), IRON)
			cyl(wp, 0.0, 0.04, 0.14, Vector3(0, 0.22, 0.57), IRON, 4)
			cyl(wp, 0.0, 0.04, 0.14, Vector3(0, -0.22, 0.57), IRON, 4, Vector3(PI, 0, 0))
		"club":
			cyl(wp, 0.13, 0.05, 0.8, Vector3(0, 0, 0.36), WOOD, 6, Vector3(PI / 2, 0, 0))
			cyl(wp, 0.135, 0.135, 0.07, Vector3(0, 0, 0.6), IRON, 6, Vector3(PI / 2, 0, 0))
			for i in 4:
				var a := float(i) * PI / 2
				cyl(wp, 0.0, 0.035, 0.12, Vector3(cos(a) * 0.16, sin(a) * 0.16, 0.66), IVORY, 4, Vector3(0, 0, a - PI / 2))
		"tree":
			cyl(wp, 0.15, 0.07, 1.0, Vector3(0, 0, 0.45), DARKWOOD, 6, Vector3(PI / 2, 0, 0))
			cyl(wp, 0.05, 0.06, 0.26, Vector3(0.14, 0.05, 0.6), DARKWOOD, 5, Vector3(PI / 2, 0, -0.7))
			cyl(wp, 0.04, 0.05, 0.22, Vector3(-0.12, -0.04, 0.78), DARKWOOD, 5, Vector3(PI / 2, 0, 0.8))
			cyl(wp, 0.16, 0.16, 0.08, Vector3(0, 0, 0.8), IRON, 6, Vector3(PI / 2, 0, 0))
			ball(wp, 0.14, Vector3(0, 0, 1.0), STONE, Vector3(1.2, 1.2, 1))
		"hammer":
			box(wp, Vector3(0.05, 0.05, 0.8), Vector3(0, 0, 0.3), DARKWOOD)
			box(wp, Vector3(0.36, 0.22, 0.22), Vector3(0, 0, 0.72), STEEL)
			box(wp, Vector3(0.4, 0.07, 0.25), Vector3(0, 0, 0.72), GOLD)
			box(wp, Vector3(0.07, 0.25, 0.25), Vector3(0.19, 0, 0.72), GOLD)
			box(wp, Vector3(0.07, 0.25, 0.25), Vector3(-0.19, 0, 0.72), GOLD)
			ball(wp, 0.045, Vector3(0, 0, -0.12), GOLD)
		"staff":
			attack = "cast"
			wp.rotation.x = -1.35
			box(wp, Vector3(0.045, 0.045, 1.5), Vector3(0, 0, 0.3), DARKWOOD)
			cyl(wp, 0.09, 0.03, 0.14, Vector3(0, 0, 1.02), GOLD, 5, Vector3(PI / 2, 0, 0))
			ball(wp, 0.12, Vector3(0, 0, 1.18), col(spec, "orb", "#6ad0ff"), Vector3.ONE, true)
			if spec.get("skull", false):
				ball(wp, 0.1, Vector3(0, 0.02, 0.92), IVORY, Vector3(1, 1, 1.1))
				box(wp, Vector3(0.03, 0.2, 0.03), Vector3(0.08, -0.1, 0.9), Color("#e0443a"))
				box(wp, Vector3(0.03, 0.24, 0.03), Vector3(-0.08, -0.12, 0.88), team)
		"spear", "lance", "trident":
			attack = "thrust"
			var long := 1.9 if weapon == "lance" else 1.4
			box(wp, Vector3(0.04, 0.04, long), Vector3(0, 0, long * 0.5 - 0.35), WOOD if weapon != "trident" else Color("#3a6a6a"))
			if weapon == "trident":      # трезубец: перекладина и три зубца
				box(wp, Vector3(0.3, 0.04, 0.04), Vector3(0, 0, long - 0.38), GOLD)
				for k in 3:
					cyl(wp, 0.0, 0.035, 0.3, Vector3((k - 1) * 0.13, 0, long - 0.22), GOLD, 4, Vector3(PI / 2, 0, 0))
			else:
				cyl(wp, 0.0, 0.055, 0.24, Vector3(0, 0, long - 0.25), STEEL, 4, Vector3(PI / 2, 0, 0))
			if weapon == "lance":
				cyl(wp, 0.04, 0.1, 0.14, Vector3(0, 0, 0.14), STEEL, 6, Vector3(PI / 2, 0, 0))
				box(wp, Vector3(0.02, 0.16, 0.26), Vector3(0, 0.1, long - 0.55), team)
			elif weapon == "spear":
				box(wp, Vector3(0.02, 0.1, 0.1), Vector3(0, -0.05, long - 0.45), Color("#c94a3a"))
		"rock":
			attack = "throw"
			ammo = ball(wp, 0.2, Vector3(0, -0.08, 0.1), STONE, Vector3(1, 0.85, 0.95))
		"fists":
			attack = "smash"
		"gun":      # гномье ружьё: приклад, длинный ствол, латунные кольца
			attack = "thrust"
			wp.rotation.x = -1.5
			box(wp, Vector3(0.07, 0.12, 0.3), Vector3(0, -0.02, -0.05), WOOD)
			cyl(wp, 0.04, 0.045, 0.85, Vector3(0, 0.02, 0.48), IRON.darkened(0.2), 6, Vector3(PI / 2, 0, 0))
			for z in [0.25, 0.6]:
				cyl(wp, 0.055, 0.055, 0.04, Vector3(0, 0.02, z), GOLD, 6, Vector3(PI / 2, 0, 0))
			cyl(wp, 0.06, 0.04, 0.08, Vector3(0, 0.02, 0.92), IRON, 6, Vector3(PI / 2, 0, 0))
		"axe":      # боевой топор гнома
			box(wp, Vector3(0.05, 0.05, 0.75), Vector3(0, 0, 0.3), DARKWOOD)
			box(wp, Vector3(0.04, 0.34, 0.22), Vector3(0, 0.12, 0.62), STEEL)
			box(wp, Vector3(0.04, 0.2, 0.14), Vector3(0, -0.1, 0.62), STEEL.darkened(0.1))
			ball(wp, 0.045, Vector3(0, 0, 0.7), GOLD)
		"bow":
			attack = "bow"
			# лук в левой руке: вдоль руки, чтобы при поднятой руке он встал вертикально
			var bow := pivot(arm_l, Vector3(0, -arm_len, 0))
			box(bow, Vector3(0.045, 0.05, 0.14), Vector3(0, -0.03, 0), LEATHER)
			box(bow, Vector3(0.035, 0.035, 0.36), Vector3(0, 0.03, 0.22), WOOD, Vector3(-0.38, 0, 0))
			box(bow, Vector3(0.035, 0.035, 0.36), Vector3(0, 0.03, -0.22), WOOD, Vector3(0.38, 0, 0))
			box(bow, Vector3(0.012, 0.012, 0.74), Vector3(0, 0.1, 0), IVORY)
	if spec.get("shield", false):
		var sh := pivot(arm_l, Vector3(aw * 0.85, -arm_len * 0.62, 0.04))
		box(sh, Vector3(0.05, 0.48, 0.38), Vector3.ZERO, team)
		box(sh, Vector3(0.06, 0.4, 0.06), Vector3(0.01, 0, 0), STEEL)
		box(sh, Vector3(0.06, 0.06, 0.32), Vector3(0.01, 0.04, 0), STEEL)
		ball(sh, 0.06, Vector3(0.04, 0.04, 0), GOLD)

	root.set_meta("parts", {
		"kind": "mounted" if mounted else "humanoid", "body": body, "torso": torso, "head": head,
		"arm_l": arm_l, "arm_r": arm_r, "legs": legs, "ammo": ammo, "attack": attack,
		"gold": gold_node, "wood": wood_node, "scale": s,
		"height": seat + (hip + torso_h + hr * 2.0 + 0.2) * s,
	})
	return root


static func _horse(body: Node3D, legs: Array, team: Color, coat: Color) -> void:
	var dark := coat.darkened(0.35)
	box(body, Vector3(0.44, 0.46, 1.25), Vector3(0, 0.84, 0), coat)
	box(body, Vector3(0.4, 0.44, 0.3), Vector3(0, 0.9, 0.6), coat.lightened(0.05))
	box(body, Vector3(0.24, 0.6, 0.3), Vector3(0, 1.24, 0.74), coat, Vector3(0.5, 0, 0))
	box(body, Vector3(0.06, 0.5, 0.12), Vector3(0, 1.32, 0.6), dark, Vector3(0.5, 0, 0))
	box(body, Vector3(0.2, 0.22, 0.44), Vector3(0, 1.52, 1.04), coat, Vector3(0.3, 0, 0))
	box(body, Vector3(0.16, 0.14, 0.16), Vector3(0, 1.44, 1.26), dark)
	for sx in [-1.0, 1.0]:
		var x: float = sx
		cyl(body, 0.0, 0.04, 0.13, Vector3(x * 0.07, 1.7, 0.9), coat, 4)
		box(body, Vector3(0.03, 0.04, 0.04), Vector3(x * 0.1, 1.57, 1.12), Color("#1c1a18"))
	box(body, Vector3(0.1, 0.55, 0.1), Vector3(0, 0.74, -0.7), dark, Vector3(-0.35, 0, 0))
	# попона в цвете команды, седло
	box(body, Vector3(0.5, 0.36, 1.0), Vector3(0, 0.76, -0.04), team)
	box(body, Vector3(0.52, 0.06, 1.02), Vector3(0, 0.6, -0.04), GOLD)
	box(body, Vector3(0.46, 0.2, 0.34), Vector3(0, 0.92, 0.6), team.darkened(0.12))
	box(body, Vector3(0.34, 0.09, 0.44), Vector3(0, 1.1, -0.06), LEATHER)
	for sz in [0.46, -0.46]:
		for sx in [-1.0, 1.0]:
			var leg := pivot(body, Vector3(float(sx) * 0.15, 0.64, float(sz)))
			box(leg, Vector3(0.12, 0.56, 0.12), Vector3(0, -0.28, 0), coat.darkened(0.12))
			box(leg, Vector3(0.14, 0.1, 0.15), Vector3(0, -0.59, 0.01), Color("#2a2420"))
			legs.append(leg)


static func _wolf(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	var body := pivot(root, Vector3.ZERO)
	body.name = "Body"
	var s: float = float(spec.get("scale", 1.0))
	body.scale = Vector3.ONE * s
	var fur := col(spec, "fur", "#7d7f86")
	var dark := fur.darkened(0.35)
	var torso := pivot(body, Vector3(0, 0.5, 0))
	box(torso, Vector3(0.32, 0.32, 0.85), Vector3.ZERO, fur)
	box(torso, Vector3(0.4, 0.42, 0.38), Vector3(0, 0.04, 0.3), fur.lightened(0.12))
	box(torso, Vector3(0.14, 0.08, 0.7), Vector3(0, 0.19, -0.05), dark)
	box(torso, Vector3(0.24, 0.12, 0.5), Vector3(0, -0.15, 0), fur.lightened(0.25))
	var head := pivot(torso, Vector3(0, 0.12, 0.5))
	box(head, Vector3(0.26, 0.24, 0.28), Vector3(0, 0, 0.12), fur)
	box(head, Vector3(0.14, 0.12, 0.22), Vector3(0, -0.05, 0.34), fur.lightened(0.2))
	box(head, Vector3(0.06, 0.05, 0.05), Vector3(0, -0.01, 0.46), Color("#1c1a18"))
	box(head, Vector3(0.12, 0.03, 0.18), Vector3(0, -0.13, 0.32), dark)
	for sx in [-1.0, 1.0]:
		var x: float = sx
		cyl(head, 0.0, 0.05, 0.14, Vector3(x * 0.09, 0.18, 0.06), dark, 4)
		box(head, Vector3(0.035, 0.035, 0.03), Vector3(x * 0.08, 0.04, 0.27), Color("#ffd94a"), Vector3.ZERO, true)
		cyl(head, 0.0, 0.015, 0.05, Vector3(x * 0.04, -0.13, 0.4), IVORY, 4, Vector3(PI, 0, 0))
	var tail := pivot(torso, Vector3(0, 0.08, -0.42))
	box(tail, Vector3(0.1, 0.1, 0.42), Vector3(0, -0.06, -0.18), fur, Vector3(0.5, 0, 0))
	box(tail, Vector3(0.08, 0.08, 0.14), Vector3(0, -0.18, -0.38), fur.lightened(0.3), Vector3(0.5, 0, 0))
	var legs: Array = []
	for sz in [0.3, -0.3]:
		for sx in [-1.0, 1.0]:
			var leg := pivot(body, Vector3(float(sx) * 0.12, 0.38, float(sz)))
			box(leg, Vector3(0.1, 0.36, 0.1), Vector3(0, -0.18, 0), fur.darkened(0.1))
			box(leg, Vector3(0.11, 0.06, 0.14), Vector3(0, -0.35, 0.02), dark)
			legs.append(leg)
	root.set_meta("parts", {
		"kind": "quad", "body": body, "torso": torso, "head": head, "arm_l": null, "arm_r": null,
		"legs": legs, "ammo": null, "attack": "bite", "gold": null, "wood": null, "scale": s, "height": 0.95 * s,
	})
	return root


## Слизень: полупрозрачная капля с глазами; при ходьбе подпрыгивает и сплющивается.
static func _slime(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	var body := pivot(root, Vector3.ZERO)
	body.name = "Body"
	var s: float = float(spec.get("scale", 1.0))
	body.scale = Vector3.ONE * s
	var c := col(spec, "color", "#6fd65a")
	var torso := pivot(body, Vector3(0, 0.0, 0))
	var blob := ball(torso, 0.55, Vector3(0, 0.42, 0), c, Vector3(1.1, 0.8, 1.1))
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, 0.78)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.emission_enabled = true
	m.emission = c.darkened(0.5)
	blob.material_override = m
	ball(torso, 0.22, Vector3(0.1, 0.32, -0.05), c.darkened(0.35), Vector3(1, 0.8, 1))
	var head := pivot(torso, Vector3(0, 0.55, 0.32))
	for sx in [-1.0, 1.0]:
		ball(head, 0.09, Vector3(float(sx) * 0.15, 0.05, 0.12), Color.WHITE)
		ball(head, 0.045, Vector3(float(sx) * 0.15, 0.05, 0.19), Color("#1c1a18"))
	root.set_meta("parts", {
		"kind": "slime", "body": body, "torso": torso, "head": head, "arm_l": null, "arm_r": null,
		"legs": [], "ammo": null, "attack": "bite", "gold": null, "wood": null, "scale": s, "height": 0.85 * s,
	})
	return root


## Паук: брюшко, головогрудь, восемь коленчатых лап, ряд красных глаз.
static func _spider(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	var body := pivot(root, Vector3.ZERO)
	body.name = "Body"
	var s: float = float(spec.get("scale", 1.0))
	body.scale = Vector3.ONE * s
	var c := col(spec, "color", "#3a2e2a")
	var torso := pivot(body, Vector3(0, 0.42, 0))
	ball(torso, 0.36, Vector3(0, 0.08, -0.38), c, Vector3(1, 0.85, 1.25))
	box(torso, Vector3(0.14, 0.04, 0.3), Vector3(0, 0.36, -0.38), c.lightened(0.35))
	ball(torso, 0.22, Vector3(0, 0.0, 0.08), c.darkened(0.15), Vector3(1, 0.8, 1.1))
	var head := pivot(torso, Vector3(0, 0.0, 0.28))
	for i in 4:
		box(head, Vector3(0.04, 0.04, 0.03), Vector3((i - 1.5) * 0.06, 0.08, 0.06), Color("#ff3a2a"), Vector3.ZERO, true)
	for sx in [-1.0, 1.0]:
		cyl(head, 0.0, 0.03, 0.14, Vector3(float(sx) * 0.05, -0.08, 0.1), IVORY, 4, Vector3(PI * 0.8, 0, 0))
	var legs: Array = []
	for k in 4:
		for sx in [-1.0, 1.0]:
			var x: float = sx
			var leg := pivot(body, Vector3(x * 0.16, 0.45, 0.2 - k * 0.14))
			var spread := (float(k) - 1.5) * 0.35
			leg.rotation.y = spread * x * 0.6      # передние лапы смотрят вперёд, задние — назад
			box(leg, Vector3(0.45, 0.05, 0.05), Vector3(x * 0.22, 0.12, (1.5 - k) * 0.12), c.darkened(0.1), Vector3(0, 0, -x * 0.5))
			box(leg, Vector3(0.05, 0.5, 0.05), Vector3(x * 0.46, -0.1, (1.5 - k) * 0.22), c.darkened(0.25), Vector3(0, 0, x * 0.25))
			legs.append(leg)
	root.set_meta("parts", {
		"kind": "quad", "body": body, "torso": torso, "head": head, "arm_l": null, "arm_r": null,
		"legs": legs, "ammo": null, "attack": "bite", "gold": null, "wood": null, "scale": s, "height": 0.8 * s,
	})
	return root


## Глаз-наблюдатель: резной кол с висящим над ним светящимся глазом.
static func _ward(spec: Dictionary, team: Color) -> Node3D:
	var root := Node3D.new()
	var body := pivot(root, Vector3.ZERO)
	body.name = "Body"
	var torso := pivot(body, Vector3.ZERO)
	cyl(torso, 0.05, 0.11, 0.9, Vector3(0, 0.45, 0), DARKWOOD, 6)
	box(torso, Vector3(0.3, 0.05, 0.05), Vector3(0, 0.75, 0), DARKWOOD)
	box(torso, Vector3(0.18, 0.12, 0.03), Vector3(0, 0.6, 0.06), team)
	var head := pivot(torso, Vector3(0, 1.1, 0))
	ball(head, 0.16, Vector3.ZERO, Color("#f2f0e0"), Vector3.ONE, true)
	ball(head, 0.08, Vector3(0, 0, 0.12), Color("#3ac8ff"), Vector3.ONE, true)
	ball(head, 0.04, Vector3(0, 0, 0.17), Color("#0a1420"))
	root.set_meta("parts", {
		"kind": "slime", "body": body, "torso": torso, "head": head, "arm_l": null, "arm_r": null,
		"legs": [], "ammo": null, "attack": "bite", "gold": null, "wood": null, "scale": 1.0, "height": 1.3,
	})
	return root


## Красный дракон: тело, длинная шея, рогатая голова, крылья, хвост, четыре лапы.
static func _dragon(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	var body := pivot(root, Vector3.ZERO)
	body.name = "Body"
	var s: float = float(spec.get("scale", 1.0))
	body.scale = Vector3.ONE * s
	var c := col(spec, "color", "#a8281a")
	var belly := Color("#e0a050")
	var dark := c.darkened(0.4)
	var torso := pivot(body, Vector3(0, 1.6, 0))
	ball(torso, 1.1, Vector3.ZERO, c, Vector3(1.0, 0.85, 1.6))
	ball(torso, 0.8, Vector3(0, -0.35, 0.2), belly, Vector3(1.0, 0.7, 1.5))
	for i in 6:      # гребень вдоль спины
		cyl(torso, 0.0, 0.16, 0.5, Vector3(0, 0.95 - absf(float(i) - 2.5) * 0.06, 1.1 - i * 0.45), dark, 4)
	# шея и голова
	var neck := pivot(torso, Vector3(0, 0.5, 1.4))
	for i in 4:
		ball(neck, 0.42 - i * 0.04, Vector3(0, i * 0.38, i * 0.32), c, Vector3(1, 1, 1.1))
	var head := pivot(neck, Vector3(0, 1.55, 1.25))
	box(head, Vector3(0.7, 0.55, 1.1), Vector3(0, 0, 0.3), c)
	box(head, Vector3(0.6, 0.25, 0.7), Vector3(0, -0.25, 0.65), dark)
	for sx in [-1.0, 1.0]:
		cyl(head, 0.0, 0.1, 0.8, Vector3(float(sx) * 0.25, 0.4, -0.25), IVORY, 4, Vector3(-0.9, 0, float(sx) * 0.3))
		box(head, Vector3(0.1, 0.08, 0.06), Vector3(float(sx) * 0.22, 0.12, 0.72), Color("#ffd24a"), Vector3.ZERO, true)
	var flame := pivot(head, Vector3(0, -0.2, 0.95))      # огонь из пасти (виден при атаке)
	cyl(flame, 0.45, 0.05, 1.6, Vector3(0, 0, 0.8), Color("#ff7a1a"), 6, Vector3(PI / 2, 0, 0), true)
	cyl(flame, 0.25, 0.03, 1.1, Vector3(0, 0, 0.55), Color("#ffe07a"), 5, Vector3(PI / 2, 0, 0), true)
	flame.visible = false
	# крылья
	var wings: Array = []
	for sx in [-1.0, 1.0]:
		var w := pivot(torso, Vector3(float(sx) * 0.7, 0.7, 0.3))
		box(w, Vector3(2.4, 0.08, 0.12), Vector3(float(sx) * 1.2, 0.3, 0), dark, Vector3(0, 0, float(sx) * 0.25))
		var memb := box(w, Vector3(2.3, 0.04, 1.6), Vector3(float(sx) * 1.15, 0.2, -0.75), c.lightened(0.05), Vector3(0, 0, float(sx) * 0.25))
		memb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		wings.append(w)
	# хвост
	var tail := pivot(torso, Vector3(0, 0, -1.6))
	for i in 5:
		ball(tail, 0.45 - i * 0.07, Vector3(0, -0.15 * i, -0.45 * i), c, Vector3(1, 0.9, 1.2))
	cyl(tail, 0.0, 0.3, 0.6, Vector3(0, -0.7, -2.4), dark, 4, Vector3(-PI / 2, 0, 0))
	# лапы
	var legs: Array = []
	for sz in [0.8, -0.8]:
		for sx in [-1.0, 1.0]:
			var leg := pivot(body, Vector3(float(sx) * 0.75, 1.3, float(sz)))
			box(leg, Vector3(0.38, 1.2, 0.42), Vector3(0, -0.6, 0), c.darkened(0.15))
			box(leg, Vector3(0.45, 0.18, 0.6), Vector3(0, -1.22, 0.12), dark)
			legs.append(leg)
	root.set_meta("parts", {
		"kind": "dragon", "body": body, "torso": torso, "head": neck, "arm_l": null, "arm_r": null,
		"legs": legs, "ammo": null, "attack": "breath", "gold": null, "wood": null, "scale": s, "height": 4.4 * s,
		"wings": wings, "flame": flame, "tail": tail,
	})
	return root


## Осадные машины на колёсах: катапульта, баллиста, стенобой.
## «Голова» здесь — подвижная часть (рычаг катапульты, ложе баллисты, бревно тарана).
static func _engine(spec: Dictionary, team: Color) -> Node3D:
	var root := Node3D.new()
	var body := pivot(root, Vector3.ZERO)
	body.name = "Body"
	var s: float = float(spec.get("scale", 1.0))
	body.scale = Vector3.ONE * s
	var kind := String(spec.get("engine", "catapult"))
	var frame := col(spec, "wood", "#7a5a2a")
	var torso := pivot(body, Vector3(0, 0.42, 0))
	box(torso, Vector3(0.86, 0.14, 1.5), Vector3.ZERO, frame)
	for sz in [0.62, -0.62]:
		box(torso, Vector3(0.9, 0.07, 0.14), Vector3(0, 0.09, float(sz)), team)
	var legs: Array = []
	for sz in [0.5, -0.5]:
		for sx in [-1.0, 1.0]:
			var wh := pivot(body, Vector3(float(sx) * 0.5, 0.28, float(sz)))
			cyl(wh, 0.28, 0.28, 0.09, Vector3.ZERO, DARKWOOD, 8, Vector3(0, 0, PI / 2))
			cyl(wh, 0.09, 0.09, 0.13, Vector3.ZERO, IRON, 6, Vector3(0, 0, PI / 2))
			box(wh, Vector3(0.11, 0.5, 0.06), Vector3.ZERO, frame.lightened(0.1))
			box(wh, Vector3(0.11, 0.06, 0.5), Vector3.ZERO, frame.lightened(0.1))
			legs.append(wh)
	var head: Node3D
	var ammo: Node3D = null
	var attack := "fling"
	match kind:
		"catapult":
			for sx in [-1.0, 1.0]:
				box(torso, Vector3(0.08, 0.72, 0.08), Vector3(float(sx) * 0.3, 0.38, 0.12), frame, Vector3(0.22, 0, 0))
			box(torso, Vector3(0.7, 0.09, 0.09), Vector3(0, 0.72, 0.2), DARKWOOD)
			box(torso, Vector3(0.5, 0.3, 0.3), Vector3(0, 0.22, 0.5), STONE.darkened(0.1))
			head = pivot(torso, Vector3(0, 0.2, 0.0))
			box(head, Vector3(0.09, 0.09, 1.25), Vector3(0, 0.02, -0.55), WOOD)
			cyl(head, 0.2, 0.14, 0.14, Vector3(0, 0.1, -1.15), DARKWOOD, 6)
			ammo = ball(head, 0.17, Vector3(0, 0.24, -1.15), STONE, Vector3(1, 0.85, 0.95))
		"ballista":
			attack = "recoil"
			box(torso, Vector3(0.16, 0.4, 0.16), Vector3(0, 0.27, 0), frame)
			head = pivot(torso, Vector3(0, 0.5, 0))
			box(head, Vector3(0.16, 0.12, 1.3), Vector3(0, 0, 0.1), DARKWOOD)
			for sx in [-1.0, 1.0]:
				box(head, Vector3(0.75, 0.07, 0.07), Vector3(float(sx) * 0.38, 0.03, 0.55), WOOD, Vector3(0, float(sx) * 0.35, 0))
			box(head, Vector3(0.012, 0.012, 1.3), Vector3(0, 0.07, 0.25), IVORY, Vector3(0, PI / 2, 0))
			ammo = pivot(head, Vector3(0, 0.11, 0.25))
			box(ammo, Vector3(0.04, 0.04, 1.0), Vector3.ZERO, WOOD.lightened(0.15))
			cyl(ammo, 0.0, 0.07, 0.18, Vector3(0, 0, 0.56), STEEL, 4, Vector3(PI / 2, 0, 0))
		_:      # стенобой: навес и тяжёлое бревно с железной головой
			attack = "ram"
			roof(torso, Vector3(1.05, 0.6, 1.6), Vector3(0, 0.62, 0), col(spec, "roof", "#8a6e50"))
			for sz in [0.65, -0.65]:
				for sx in [-1.0, 1.0]:
					box(torso, Vector3(0.08, 0.5, 0.08), Vector3(float(sx) * 0.42, 0.3, float(sz)), DARKWOOD)
			head = pivot(torso, Vector3(0, 0.35, 0))
			cyl(head, 0.16, 0.16, 1.9, Vector3(0, 0, 0.2), WOOD, 7, Vector3(PI / 2, 0, 0))
			cyl(head, 0.22, 0.17, 0.3, Vector3(0, 0, 1.2), IRON, 7, Vector3(PI / 2, 0, 0))
			for sx in [-1.0, 1.0]:
				cyl(head, 0.0, 0.05, 0.2, Vector3(float(sx) * 0.14, 0.12, 1.3), IVORY, 4, Vector3(PI / 2, 0, 0))
	root.set_meta("parts", {
		"kind": "engine", "body": body, "torso": torso, "head": head, "arm_l": null, "arm_r": null,
		"legs": legs, "ammo": ammo, "attack": attack, "gold": null, "wood": null, "scale": s, "height": 1.35 * s,
	})
	return root


# =====================================================================
#  ЗДАНИЯ
# =====================================================================

static func building(spec: Dictionary, size: float, team: Color) -> Node3D:
	var root := Node3D.new()
	match String(spec.get("shape", "farm")):
		"townhall":
			_townhall(root, team)
		"barracks":
			_barracks(root, team)
		"farm":
			_farm(root, team)
		"watchtower":
			_watchtower(root, team)
		"ogre_lair":
			_ogre_lair(root, team)
		"ogre_pit":
			_ogre_pit(root, team)
		"ogre_tent":
			_ogre_tent(root, team)
		"ogre_tower":
			_ogre_tower(root, team)
		"forge":
			_forge(root, team)
		"ogre_forge":
			_ogre_forge(root, team)
		"shop":
			_shop(root)
		"altar":
			_altar(root, team)
		"elf_tree":
			_elf_tree(root, team)
		"elf_well":
			_elf_well(root, team)
		"elf_lodge":
			_elf_lodge(root, team)
		"elf_watch":
			_elf_watch(root, team)
		"elf_circle":
			_elf_circle(root, team)
		"elf_forge":
			_elf_forge(root, team)
		"ogre_totem":
			_ogre_totem(root, team)
		"temple":
			_temple(root, team)
		"workshop":
			_workshop(root, team)
		"ogre_hut":
			_ogre_hut(root, team)
		"ogre_yard":
			_ogre_yard(root, team)
		"elf_shrine":
			_elf_shrine(root, team)
		"elf_works":
			_elf_works(root, team)
		"undead_hall", "undead_crypt", "undead_barracks", "undead_tower", "undead_altar", "undead_forge", "undead_temple", "undead_works":
			_undead(root, team, String(spec["shape"]))
		"dwarf_hall", "dwarf_house", "dwarf_barracks", "dwarf_tower", "dwarf_altar", "dwarf_forge", "dwarf_shrine", "dwarf_works":
			_dwarf(root, team, String(spec["shape"]))
		"naga_hall", "naga_pool", "naga_barracks", "naga_tower", "naga_altar", "naga_forge", "naga_temple", "naga_works":
			_naga(root, team, String(spec["shape"]))
		"goblin_mine":
			_goblin_mine(root, team)
		"fountain":
			_fountain(root)
		"merc_camp":
			_merc_camp(root, team)
		"lookout":
			_lookout(root, team)
		_:
			box(root, Vector3(size * 0.8, 1.0, size * 0.8), Vector3(0, 0.5, 0), STONE)
			_flag(root, Vector3(0, 1.0, 0), team, 1.0)
	merge(root)
	return root


static func _window(root: Node3D, pos: Vector3, facing_x := false) -> void:
	var sz := Vector3(0.06, 0.4, 0.32) if facing_x else Vector3(0.32, 0.4, 0.06)
	box(root, sz, pos, Color("#f4d67a"))
	box(root, (Vector3(0.07, 0.42, 0.04) if facing_x else Vector3(0.04, 0.42, 0.07)), pos, DARKWOOD)
	box(root, (Vector3(0.07, 0.04, 0.34) if facing_x else Vector3(0.34, 0.04, 0.07)), pos, DARKWOOD)


static func _townhall(root: Node3D, team: Color) -> void:
	var wall := Color("#e6dabd")
	box(root, Vector3(3.3, 0.36, 2.9), Vector3(0, 0.18, 0), STONE)
	box(root, Vector3(3.0, 1.5, 2.5), Vector3(0, 1.1, 0), wall)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			box(root, Vector3(0.14, 1.5, 0.14), Vector3(float(sx) * 1.47, 1.1, float(sz) * 1.22), DARKWOOD)
	box(root, Vector3(3.06, 0.1, 2.56), Vector3(0, 1.2, 0), DARKWOOD)
	box(root, Vector3(3.06, 0.1, 2.56), Vector3(0, 1.82, 0), DARKWOOD)
	for sx in [-0.5, 0.5]:
		box(root, Vector3(0.09, 0.6, 0.06), Vector3(float(sx), 1.52, 1.26), DARKWOOD, Vector3(0, 0, float(sx)))
	roof(root, Vector3(3.5, 1.25, 2.9), Vector3(0, 2.48, 0), team.darkened(0.08))
	box(root, Vector3(0.12, 0.1, 3.0), Vector3(0, 3.1, 0), team.darkened(0.3))
	box(root, Vector3(0.34, 0.8, 0.34), Vector3(-0.95, 2.7, -0.55), STONE.darkened(0.12))
	box(root, Vector3(0.42, 0.08, 0.42), Vector3(-0.95, 3.12, -0.55), STONE)
	# вход
	box(root, Vector3(0.78, 1.02, 0.08), Vector3(0, 0.85, 1.27), DARKWOOD)
	box(root, Vector3(0.62, 0.9, 0.1), Vector3(0, 0.8, 1.28), WOOD)
	box(root, Vector3(0.04, 0.9, 0.11), Vector3(0, 0.8, 1.29), DARKWOOD)
	ball(root, 0.04, Vector3(0.1, 0.8, 1.35), GOLD)
	box(root, Vector3(1.1, 0.16, 0.5), Vector3(0, 0.08, 1.62), STONE.lightened(0.08))
	box(root, Vector3(0.9, 0.3, 0.3), Vector3(0, 0.15, 1.45), STONE.lightened(0.08))
	_window(root, Vector3(-0.95, 1.5, 1.26))
	_window(root, Vector3(0.95, 1.5, 1.26))
	_window(root, Vector3(-1.51, 1.5, 0.0), true)
	box(root, Vector3(0.5, 0.7, 0.03), Vector3(0, 2.3, 1.47), team)
	ball(root, 0.09, Vector3(0, 2.3, 1.5), GOLD)
	# башня
	var t := Vector3(1.2, 0, -0.75)
	box(root, Vector3(1.0, 3.4, 1.0), t + Vector3(0, 1.7, 0), STONE.lightened(0.06))
	box(root, Vector3(1.2, 0.22, 1.2), t + Vector3(0, 3.42, 0), STONE)
	for sx in [-1.0, 0.0, 1.0]:
		for sz in [-1.0, 0.0, 1.0]:
			if sx != 0.0 or sz != 0.0:
				box(root, Vector3(0.24, 0.26, 0.24), t + Vector3(float(sx) * 0.48, 3.66, float(sz) * 0.48), STONE.lightened(0.1))
	cyl(root, 0.0, 0.72, 1.0, t + Vector3(0, 4.25, 0), team.darkened(0.08), 4, Vector3(0, PI / 4, 0))
	box(root, Vector3(0.14, 0.42, 0.04), t + Vector3(0, 2.5, 0.51), Color("#1c1a18"))
	box(root, Vector3(0.14, 0.42, 0.04), t + Vector3(0, 1.3, 0.51), Color("#1c1a18"))
	_flag(root, t + Vector3(0, 4.7, 0), team, 0.9, 0.6)
	# двор
	cyl(root, 0.17, 0.17, 0.4, Vector3(-1.2, 0.56, 1.6), WOOD, 8)
	cyl(root, 0.18, 0.18, 0.05, Vector3(-1.2, 0.6, 1.6), IRON, 8)
	box(root, Vector3(0.34, 0.34, 0.34), Vector3(-0.72, 0.53, 1.62), WOOD.lightened(0.1), Vector3(0, 0.3, 0))


static func _barracks(root: Node3D, team: Color) -> void:
	var wall := Color("#b9ad97")
	box(root, Vector3(2.6, 0.26, 2.3), Vector3(0, 0.13, 0), STONE.darkened(0.1))
	box(root, Vector3(2.4, 1.05, 2.0), Vector3(0, 0.78, -0.1), wall)
	for i in 4:
		box(root, Vector3(2.42, 0.03, 2.02), Vector3(0, 0.5 + i * 0.24, -0.1), wall.darkened(0.18))
	roof(root, Vector3(2.8, 0.9, 2.3), Vector3(0, 1.75, -0.1), Color("#7a3b2e"))
	box(root, Vector3(0.1, 0.1, 2.4), Vector3(0, 2.2, -0.1), DARKWOOD)
	box(root, Vector3(0.8, 0.9, 0.08), Vector3(0, 0.72, 0.92), DARKWOOD)
	box(root, Vector3(0.9, 0.1, 0.12), Vector3(0, 1.2, 0.92), WOOD)
	for sx in [-1.0, 1.0]:
		var x: float = sx
		cyl(root, 0.22, 0.22, 0.05, Vector3(x * 0.82, 0.95, 0.92), team, 8, Vector3(PI / 2, 0, 0))
		ball(root, 0.06, Vector3(x * 0.82, 0.95, 0.96), STEEL)
		box(root, Vector3(0.4, 0.7, 0.03), Vector3(x * 1.0, 1.6, 1.07), team)
	# стойка с копьями
	box(root, Vector3(0.06, 0.7, 0.06), Vector3(0.75, 0.48, 1.3), WOOD)
	box(root, Vector3(0.06, 0.7, 0.06), Vector3(1.2, 0.48, 1.3), WOOD)
	box(root, Vector3(0.55, 0.05, 0.05), Vector3(0.98, 0.75, 1.3), WOOD)
	for i in 3:
		box(root, Vector3(0.03, 0.95, 0.03), Vector3(0.82 + i * 0.15, 0.6, 1.36), WOOD.lightened(0.1), Vector3(0.14, 0, 0))
		cyl(root, 0.0, 0.035, 0.12, Vector3(0.82 + i * 0.15, 1.12, 1.43), STEEL, 4, Vector3(0.14, 0, 0))
	# чучело для тренировок
	box(root, Vector3(0.07, 0.85, 0.07), Vector3(-0.98, 0.55, 1.3), WOOD)
	box(root, Vector3(0.6, 0.07, 0.07), Vector3(-0.98, 0.78, 1.3), WOOD)
	ball(root, 0.15, Vector3(-0.98, 1.08, 1.3), STRAW)
	box(root, Vector3(0.3, 0.36, 0.2), Vector3(-0.98, 0.68, 1.3), STRAW.darkened(0.1))
	_flag(root, Vector3(-1.1, 1.3, -0.9), team, 1.5, 0.55)


static func _farm(root: Node3D, team: Color) -> void:
	var h := Vector3(-0.38, 0, -0.3)
	box(root, Vector3(1.0, 0.12, 0.85), h + Vector3(0, 0.06, 0), STONE)
	box(root, Vector3(0.92, 0.6, 0.78), h + Vector3(0, 0.42, 0), Color("#e6dabd"))
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.07, 0.6, 0.07), h + Vector3(float(sx) * 0.44, 0.42, 0.37), DARKWOOD)
	roof(root, Vector3(1.2, 0.55, 1.0), h + Vector3(0, 0.98, 0), STRAW)
	box(root, Vector3(0.08, 0.06, 1.05), h + Vector3(0, 1.24, 0), STRAW.darkened(0.2))
	box(root, Vector3(0.26, 0.42, 0.05), h + Vector3(-0.15, 0.33, 0.4), DARKWOOD)
	box(root, Vector3(0.2, 0.2, 0.05), h + Vector3(0.22, 0.46, 0.4), Color("#f4d67a"))
	box(root, Vector3(0.14, 0.3, 0.14), h + Vector3(0.28, 1.1, -0.2), STONE.darkened(0.1))
	# грядки
	box(root, Vector3(0.85, 0.05, 1.6), Vector3(0.48, 0.03, 0.05), Color("#6a4a30"))
	for i in 4:
		box(root, Vector3(0.1, 0.18, 1.45), Vector3(0.18 + i * 0.2, 0.13, 0.05), Color("#8fb84a") if i % 2 == 0 else Color("#d8c04a"))
	# стог сена и изгородь
	ball(root, 0.3, Vector3(-0.5, 0.2, 0.62), STRAW, Vector3(1, 0.85, 1))
	ball(root, 0.16, Vector3(-0.5, 0.48, 0.62), STRAW.lightened(0.08))
	for i in 5:
		box(root, Vector3(0.05, 0.3, 0.05), Vector3(0.95, 0.15, -0.7 + i * 0.38), WOOD)
	box(root, Vector3(0.03, 0.04, 1.6), Vector3(0.95, 0.22, 0.05), WOOD)
	_flag(root, h + Vector3(-0.3, 1.0, -0.2), team, 0.7, 0.36)


static func _watchtower(root: Node3D, team: Color) -> void:
	cyl(root, 0.7, 0.76, 0.2, Vector3(0, 0.1, 0), STONE.darkened(0.15), 8)
	cyl(root, 0.54, 0.64, 2.2, Vector3(0, 1.2, 0), STONE, 8)
	for i in 3:
		cyl(root, 0.57 - i * 0.025, 0.58 - i * 0.025, 0.05, Vector3(0, 0.7 + i * 0.6, 0), STONE.darkened(0.2), 8)
	cyl(root, 0.74, 0.6, 0.2, Vector3(0, 2.4, 0), STONE.lightened(0.06), 8)
	for i in 8:
		var a := float(i) * TAU / 8.0
		if i % 2 == 0:
			box(root, Vector3(0.24, 0.24, 0.16), Vector3(sin(a) * 0.66, 2.62, cos(a) * 0.66), STONE.lightened(0.1), Vector3(0, a, 0))
	for i in 4:
		var a := float(i) * TAU / 4.0 + PI / 4
		box(root, Vector3(0.07, 0.6, 0.07), Vector3(sin(a) * 0.5, 2.8, cos(a) * 0.5), DARKWOOD)
	cyl(root, 0.0, 0.86, 0.7, Vector3(0, 3.45, 0), team.darkened(0.08), 8)
	box(root, Vector3(0.3, 0.5, 0.06), Vector3(0, 0.45, 0.62), DARKWOOD)
	box(root, Vector3(0.08, 0.32, 0.05), Vector3(0, 1.6, 0.56), Color("#1c1a18"))
	box(root, Vector3(0.05, 0.32, 0.08), Vector3(0.56, 1.3, 0), Color("#1c1a18"))
	_flag(root, Vector3(0, 3.75, 0), team, 0.6, 0.4)


static func _bone(root: Node3D, pos: Vector3, h: float, lean: Vector3) -> void:
	cyl(root, 0.0, h * 0.11, h, pos, IVORY, 5, lean)


static func _skull_pole(root: Node3D, base: Vector3, h: float) -> void:
	box(root, Vector3(0.07, h, 0.07), base + Vector3(0, h * 0.5, 0), DARKWOOD)
	ball(root, 0.13, base + Vector3(0, h + 0.1, 0), IVORY, Vector3(1, 0.95, 1.1))
	box(root, Vector3(0.14, 0.08, 0.12), base + Vector3(0, h, 0.06), IVORY.darkened(0.08))
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.04, 0.04, 0.03), base + Vector3(float(sx) * 0.05, h + 0.12, 0.12), Color("#1c1a18"))


static func _fire(root: Node3D, pos: Vector3, r: float) -> void:
	for i in 6:
		var a := float(i) * TAU / 6.0
		ball(root, r * 0.3, pos + Vector3(cos(a) * r, 0.06, sin(a) * r), STONE.darkened(0.1 * (i % 2)), Vector3(1, 0.7, 1))
	box(root, Vector3(r * 1.5, 0.08, 0.1), pos + Vector3(0, 0.1, 0), DARKWOOD, Vector3(0, 0.6, 0))
	box(root, Vector3(r * 1.5, 0.08, 0.1), pos + Vector3(0, 0.12, 0), DARKWOOD, Vector3(0, -0.7, 0))
	cyl(root, 0.0, r * 0.55, r * 1.6, pos + Vector3(0, r * 0.9, 0), Color("#ff8a2a"), 5, Vector3.ZERO, true)
	cyl(root, 0.0, r * 0.3, r * 1.1, pos + Vector3(0.03, r * 0.8, 0.02), Color("#ffd94a"), 4, Vector3.ZERO, true)


static func _ogre_lair(root: Node3D, team: Color) -> void:
	var hide := Color("#8a6e50")
	ball(root, 1.65, Vector3(0, 0, -0.15), hide, Vector3(1, 0.92, 1))
	ball(root, 1.0, Vector3(-0.9, 0, 0.5), hide.darkened(0.12), Vector3(1, 0.8, 1))
	ball(root, 0.9, Vector3(1.0, 0, 0.35), hide.lightened(0.06), Vector3(1, 0.85, 1))
	# заплатки и швы на шкурах
	box(root, Vector3(0.7, 0.04, 0.5), Vector3(-0.5, 1.38, 0.1), hide.darkened(0.25), Vector3(0.2, 0.3, 0.3))
	box(root, Vector3(0.6, 0.04, 0.6), Vector3(0.6, 1.3, -0.5), hide.lightened(0.15), Vector3(-0.3, 0.2, -0.35))
	# рёбра-бивни вдоль купола
	for i in 4:
		var z := -1.0 + i * 0.6
		for sx in [-1.0, 1.0]:
			var x: float = sx
			_bone(root, Vector3(x * 1.42, 0.95, z), 1.5, Vector3(0, 0, x * 0.75))
	cyl(root, 0.3, 0.36, 0.2, Vector3(0, 1.52, -0.15), Color("#2a2420"), 6)
	# вход с большими бивнями
	box(root, Vector3(0.9, 1.0, 0.5), Vector3(0, 0.5, 1.4), Color("#14110f"))
	box(root, Vector3(1.2, 0.18, 0.5), Vector3(0, 1.08, 1.45), DARKWOOD)
	for sx in [-1.0, 1.0]:
		var x: float = sx
		_bone(root, Vector3(x * 0.68, 0.95, 1.6), 1.9, Vector3(0, 0, x * 0.28))
		box(root, Vector3(0.16, 1.0, 0.16), Vector3(x * 0.55, 0.5, 1.5), DARKWOOD)
	_skull_pole(root, Vector3(-1.45, 0, 1.4), 1.2)
	_fire(root, Vector3(1.4, 0, 1.45), 0.26)
	# тотем с полотнищем команды
	box(root, Vector3(0.16, 2.6, 0.16), Vector3(-1.5, 1.3, -1.3), DARKWOOD)
	box(root, Vector3(0.6, 0.1, 0.1), Vector3(-1.5, 2.4, -1.3), DARKWOOD)
	box(root, Vector3(0.5, 0.9, 0.03), Vector3(-1.5, 1.9, -1.24), team)
	ball(root, 0.14, Vector3(-1.5, 2.72, -1.3), IVORY)


static func _ogre_pit(root: Node3D, team: Color) -> void:
	cyl(root, 1.2, 1.25, 0.08, Vector3(0, 0.04, 0), Color("#c9b27a"), 12)
	cyl(root, 0.5, 0.5, 0.02, Vector3(0, 0.09, 0), Color("#a8905c"), 10)
	for i in 16:
		var a := float(i) * TAU / 16.0
		if absf(wrapf(a, -PI, PI)) < 0.45:
			continue   # проход спереди
		var h := 1.0 + 0.25 * ((i * 7) % 3)
		var p := Vector3(sin(a) * 1.22, 0, cos(a) * 1.22)
		cyl(root, 0.12, 0.14, h, p + Vector3(0, h * 0.5, 0), WOOD if i % 2 == 0 else DARKWOOD, 6)
		cyl(root, 0.0, 0.12, 0.26, p + Vector3(0, h + 0.13, 0), WOOD.lightened(0.1), 6)
	cyl(root, 1.27, 1.27, 0.06, Vector3(0, 0.62, 0), LEATHER, 16)
	for sx in [-1.0, 1.0]:
		_skull_pole(root, Vector3(float(sx) * 0.58, 0, 1.2), 1.3)
	# плита и воткнутая дубина
	box(root, Vector3(0.6, 0.2, 0.5), Vector3(-0.3, 0.14, -0.2), STONE)
	cyl(root, 0.13, 0.05, 0.9, Vector3(0.4, 0.5, 0.1), WOOD, 6, Vector3(0.3, 0, 0.25))
	cyl(root, 0.14, 0.14, 0.08, Vector3(0.46, 0.76, 0.18), IRON, 6, Vector3(0.3, 0, 0.25))
	ball(root, 0.2, Vector3(-0.5, 0.2, 0.45), STONE.darkened(0.1), Vector3(1, 0.8, 1))
	box(root, Vector3(0.12, 2.4, 0.12), Vector3(0, 1.2, -1.25), DARKWOOD)
	box(root, Vector3(0.6, 1.0, 0.03), Vector3(0.36, 1.8, -1.25), team)
	_bone(root, Vector3(0, 2.55, -1.25), 0.4, Vector3.ZERO)


static func _ogre_tent(root: Node3D, team: Color) -> void:
	var hide := Color("#9a7448")
	cyl(root, 0.08, 0.82, 1.5, Vector3(0, 0.75, 0), hide, 7)
	cyl(root, 0.4, 0.84, 0.5, Vector3(0, 0.25, 0), hide.darkened(0.15), 7)
	for i in 3:
		var a := float(i) * TAU / 3.0
		box(root, Vector3(0.05, 0.7, 0.05), Vector3(sin(a) * 0.08, 1.7, cos(a) * 0.08), DARKWOOD, Vector3(cos(a) * 0.35, 0, -sin(a) * 0.35))
	roof(root, Vector3(0.6, 0.8, 0.3), Vector3(0, 0.4, 0.62), Color("#14110f"))
	box(root, Vector3(0.3, 0.3, 0.03), Vector3(0.38, 0.9, 0.42), hide.lightened(0.2), Vector3(-0.5, 0.6, 0))
	box(root, Vector3(0.26, 0.5, 0.03), Vector3(-0.32, 0.95, 0.46), team, Vector3(-0.5, -0.5, 0))
	_bone(root, Vector3(0.62, 0.3, 0.6), 0.6, Vector3(0, 0, 0.3))
	for i in 5:
		var a := float(i) * 1.26 + 0.4
		ball(root, 0.14, Vector3(sin(a) * 0.86, 0.06, cos(a) * 0.86), STONE.darkened(0.1 * (i % 2)), Vector3(1, 0.7, 1))


static func _ogre_tower(root: Node3D, team: Color) -> void:
	ball(root, 0.85, Vector3(0, 0.25, 0), STONE.darkened(0.12), Vector3(1.05, 0.95, 1))
	ball(root, 0.5, Vector3(-0.6, 0.2, 0.4), STONE, Vector3(1, 0.8, 1))
	ball(root, 0.46, Vector3(0.6, 0.15, -0.35), STONE.lightened(0.06), Vector3(1, 0.8, 1))
	ball(root, 0.66, Vector3(0.05, 1.1, 0), STONE.lightened(0.04), Vector3(1, 0.95, 1.05))
	ball(root, 0.5, Vector3(-0.05, 1.7, 0.02), STONE.darkened(0.06))
	box(root, Vector3(0.5, 0.05, 0.4), Vector3(0.2, 1.0, 0.55), Color("#5f8a3f"), Vector3(0.6, 0, 0))
	cyl(root, 0.78, 0.7, 0.12, Vector3(0, 2.15, 0), WOOD, 8)
	for i in 8:
		var a := float(i) * TAU / 8.0
		cyl(root, 0.0, 0.07, 0.42, Vector3(sin(a) * 0.72, 2.4, cos(a) * 0.72), DARKWOOD, 5, Vector3(cos(a) * 0.3, 0, -sin(a) * 0.3))
	for i in 3:
		ball(root, 0.17, Vector3(-0.2 + i * 0.2, 2.34 + (0.2 if i == 1 else 0.0), -0.1), STONE.lightened(0.1))
	_fire(root, Vector3(0.3, 2.2, 0.3), 0.12)
	box(root, Vector3(0.08, 1.2, 0.08), Vector3(-0.45, 2.8, -0.3), DARKWOOD)
	box(root, Vector3(0.45, 0.6, 0.03), Vector3(-0.2, 3.05, -0.3), team)


const BARK := Color("#6a4a2e")
const LEAF := Color("#4f9a3f")
const MOON := Color("#9fe8ff")


static func _lantern(root: Node3D, pos: Vector3) -> void:
	box(root, Vector3(0.02, 0.2, 0.02), pos + Vector3(0, 0.16, 0), DARKWOOD)
	ball(root, 0.09, pos, Color("#ffe07a"), Vector3.ONE, true)


static func _elf_tree(root: Node3D, team: Color) -> void:
	cyl(root, 0.85, 1.25, 2.8, Vector3(0, 1.4, 0), BARK, 8)
	cyl(root, 0.6, 0.85, 1.2, Vector3(0, 3.3, 0), BARK.lightened(0.05), 8)
	for i in 6:      # корни
		var a := float(i) * TAU / 6.0 + 0.3
		cyl(root, 0.1, 0.34, 1.3, Vector3(sin(a) * 1.35, 0.25, cos(a) * 1.35), BARK.darkened(0.12), 5, Vector3(cos(a) * 1.2, 0, -sin(a) * 1.2))
	# крона
	var crown := [Vector3(0, 4.4, 0), Vector3(1.2, 3.7, 0.3), Vector3(-1.1, 3.8, -0.4), Vector3(0.2, 3.9, -1.2), Vector3(-0.3, 3.6, 1.2), Vector3(0.9, 4.6, -0.8)]
	for i in crown.size():
		ball(root, 1.25 - 0.1 * (i % 3), crown[i], LEAF.lightened(0.06 * (i % 3)).darkened(0.05 * ((i + 1) % 2)), Vector3(1, 0.85, 1))
	# дверь, окна, площадка
	box(root, Vector3(0.62, 1.0, 0.2), Vector3(0, 0.55, 1.14), DARKWOOD)
	cyl(root, 0.31, 0.31, 0.2, Vector3(0, 1.05, 1.14), DARKWOOD, 8, Vector3(PI / 2, 0, 0))
	box(root, Vector3(0.9, 0.12, 0.5), Vector3(0, 0.06, 1.5), STONE)
	for i in 3:
		var a := -0.9 + i * 0.9
		box(root, Vector3(0.24, 0.3, 0.1), Vector3(sin(a) * 0.98, 2.0, cos(a) * 0.98), Color("#ffe07a"), Vector3(0, a, 0), true)
	cyl(root, 1.45, 1.35, 0.1, Vector3(0, 2.75, 0), WOOD, 10)
	for i in 10:
		var a := float(i) * TAU / 10.0
		box(root, Vector3(0.05, 0.3, 0.05), Vector3(sin(a) * 1.4, 2.95, cos(a) * 1.4), WOOD.lightened(0.1))
	_lantern(root, Vector3(1.3, 2.4, 0.6))
	_lantern(root, Vector3(-1.3, 2.4, 0.5))
	_lantern(root, Vector3(0.5, 3.0, 1.5))
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.36, 0.9, 0.03), Vector3(float(sx) * 0.62, 1.6, 1.08), team, Vector3(0, float(sx) * 0.35, 0))
	_flag(root, Vector3(0, 5.3, 0), team, 0.8, 0.5)


static func _elf_well(root: Node3D, team: Color) -> void:
	cyl(root, 0.78, 0.84, 0.36, Vector3(0, 0.18, 0), STONE.lightened(0.08), 10)
	cyl(root, 0.62, 0.62, 0.38, Vector3(0, 0.19, 0), MOON, 10, Vector3.ZERO, true)
	for i in 3:
		var a := float(i) * TAU / 3.0
		cyl(root, 0.03, 0.09, 1.5, Vector3(sin(a) * 0.72, 0.9, cos(a) * 0.72), STONE.lightened(0.15), 5, Vector3(-cos(a) * 0.3, 0, sin(a) * 0.3))
	ball(root, 0.2, Vector3(0, 1.7, 0), MOON, Vector3.ONE, true)
	cyl(root, 0.05, 0.08, 0.5, Vector3(-0.7, 0.25, -0.6), BARK, 5)
	ball(root, 0.36, Vector3(-0.7, 0.7, -0.6), LEAF, Vector3(1, 0.85, 1))
	box(root, Vector3(0.3, 0.4, 0.03), Vector3(0.6, 0.5, 0.62), team, Vector3(0, 0.7, 0))


static func _elf_lodge(root: Node3D, team: Color) -> void:
	box(root, Vector3(2.5, 0.2, 2.2), Vector3(0, 0.1, 0), STONE.darkened(0.05))
	box(root, Vector3(2.2, 0.95, 1.8), Vector3(0, 0.67, -0.15), WOOD.lightened(0.12))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			cyl(root, 0.1, 0.12, 1.1, Vector3(float(sx) * 1.1, 0.75, -0.15 + float(sz) * 0.9), BARK, 6)
	roof(root, Vector3(2.8, 1.1, 2.3), Vector3(0, 1.7, -0.15), LEAF.darkened(0.15))
	roof(root, Vector3(2.2, 0.7, 2.5), Vector3(0, 1.75, -0.15), LEAF.lightened(0.05))
	box(root, Vector3(0.7, 0.85, 0.08), Vector3(0, 0.62, 0.76), DARKWOOD)
	for sx in [-1.0, 1.0]:       # рога над входом
		var x: float = sx
		box(root, Vector3(0.04, 0.4, 0.04), Vector3(x * 0.2, 1.65, 1.02), IVORY, Vector3(0, 0, -x * 0.6))
		box(root, Vector3(0.03, 0.2, 0.03), Vector3(x * 0.38, 1.82, 1.02), IVORY, Vector3(0, 0, -x * 1.2))
		box(root, Vector3(0.34, 0.75, 0.03), Vector3(x * 0.8, 0.9, 0.77), team)
	# мишень и стойка с луками
	box(root, Vector3(0.06, 0.8, 0.06), Vector3(-1.0, 0.5, 1.2), WOOD)
	cyl(root, 0.3, 0.3, 0.07, Vector3(-1.0, 0.95, 1.22), STRAW, 10, Vector3(PI / 2, 0, 0))
	cyl(root, 0.18, 0.18, 0.08, Vector3(-1.0, 0.95, 1.23), Color("#e0443a"), 10, Vector3(PI / 2, 0, 0))
	cyl(root, 0.07, 0.07, 0.09, Vector3(-1.0, 0.95, 1.24), Color("#f1eee6"), 8, Vector3(PI / 2, 0, 0))
	box(root, Vector3(0.6, 0.05, 0.05), Vector3(0.95, 0.75, 1.2), WOOD)
	for i in 3:
		box(root, Vector3(0.03, 0.7, 0.03), Vector3(0.75 + i * 0.2, 0.55, 1.24), WOOD.lightened(0.15), Vector3(0.15, 0, 0))
	_lantern(root, Vector3(1.2, 1.25, 0.8))
	_flag(root, Vector3(-1.1, 1.3, -0.9), team, 1.4, 0.5)


static func _elf_watch(root: Node3D, team: Color) -> void:
	cyl(root, 0.22, 0.4, 2.6, Vector3(0, 1.3, 0), BARK, 7)
	for i in 4:
		var a := float(i) * TAU / 4.0
		cyl(root, 0.05, 0.16, 0.8, Vector3(sin(a) * 0.45, 0.2, cos(a) * 0.45), BARK.darkened(0.1), 5, Vector3(cos(a) * 1.1, 0, -sin(a) * 1.1))
	cyl(root, 0.8, 0.6, 0.12, Vector3(0, 2.4, 0), WOOD, 8)
	for i in 8:
		var a := float(i) * TAU / 8.0
		box(root, Vector3(0.05, 0.34, 0.05), Vector3(sin(a) * 0.74, 2.62, cos(a) * 0.74), WOOD.lightened(0.1))
	cyl(root, 0.76, 0.76, 0.04, Vector3(0, 2.8, 0), WOOD.lightened(0.1), 8)
	ball(root, 0.75, Vector3(0, 3.6, 0), LEAF, Vector3(1.1, 0.75, 1.1))
	ball(root, 0.5, Vector3(0.3, 4.0, -0.1), LEAF.lightened(0.1), Vector3(1, 0.8, 1))
	_lantern(root, Vector3(0.6, 2.2, 0.5))
	box(root, Vector3(0.3, 0.6, 0.03), Vector3(0, 1.6, 0.36), team)


static func _elf_circle(root: Node3D, team: Color) -> void:
	cyl(root, 1.3, 1.36, 0.12, Vector3(0, 0.06, 0), Color("#6f8a5a"), 12)
	cyl(root, 0.7, 0.7, 0.14, Vector3(0, 0.08, 0), STONE.lightened(0.1), 10)
	for i in 6:
		var a := float(i) * TAU / 6.0
		var p := Vector3(sin(a) * 1.1, 0, cos(a) * 1.1)
		var hh := 1.3 + 0.3 * (i % 2)
		box(root, Vector3(0.36, hh, 0.26), p + Vector3(0, hh * 0.5, 0), STONE.darkened(0.05 * (i % 3)), Vector3(0, a, 0.06 * (i % 3 - 1)))
		box(root, Vector3(0.12, 0.3, 0.03), p * 0.87 + Vector3(0, hh * 0.6, 0), Color("#8cff7a"), Vector3(0, a, 0), true)
		if i % 2 == 0:
			box(root, Vector3(0.5, 0.16, 0.3), p + Vector3(0, hh + 0.08, 0), STONE, Vector3(0, a, 0))
	cyl(root, 0.0, 0.2, 0.7, Vector3(0, 0.75, 0), Color("#8cff7a"), 5, Vector3.ZERO, true)
	cyl(root, 0.2, 0.0, 0.3, Vector3(0, 0.25, 0), Color("#8cff7a"), 5, Vector3.ZERO, true)
	ball(root, 0.3, Vector3(-0.9, 0.2, -0.95), LEAF, Vector3(1, 0.8, 1))
	box(root, Vector3(0.08, 2.0, 0.08), Vector3(0.95, 1.0, -0.95), BARK)
	box(root, Vector3(0.45, 0.8, 0.03), Vector3(0.7, 1.5, -0.95), team)


static func _elf_forge(root: Node3D, team: Color) -> void:
	box(root, Vector3(2.4, 0.16, 2.2), Vector3(0, 0.08, 0), WOOD.lightened(0.15))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			cyl(root, 0.09, 0.12, 1.5, Vector3(float(sx) * 1.0, 0.9, float(sz) * 0.9), BARK, 6)
	roof(root, Vector3(2.7, 0.9, 2.4), Vector3(0, 2.05, 0), LEAF.darkened(0.12))
	box(root, Vector3(2.3, 0.08, 2.1), Vector3(0, 1.65, 0), WOOD)
	# верстак с луками, колчаны, зелёный горн
	box(root, Vector3(1.3, 0.1, 0.5), Vector3(-0.2, 0.75, -0.5), WOOD)
	for sx in [-0.75, 0.35]:
		box(root, Vector3(0.08, 0.6, 0.08), Vector3(float(sx), 0.45, -0.5), DARKWOOD)
	box(root, Vector3(0.03, 0.03, 0.8), Vector3(-0.3, 0.83, -0.5), WOOD.lightened(0.2), Vector3(0, 0.6, 0))
	box(root, Vector3(0.03, 0.03, 0.8), Vector3(0.0, 0.83, -0.45), WOOD.lightened(0.2), Vector3(0, -0.4, 0))
	cyl(root, 0.09, 0.09, 0.4, Vector3(0.75, 0.36, -0.6), LEATHER, 6)
	cyl(root, 0.28, 0.34, 0.5, Vector3(0.55, 0.4, 0.45), STONE.darkened(0.1), 7)
	cyl(root, 0.0, 0.2, 0.5, Vector3(0.55, 0.85, 0.45), Color("#8cff7a"), 5, Vector3.ZERO, true)
	_anvil(root, Vector3(-0.5, 0.16, 0.5))
	_lantern(root, Vector3(-1.0, 1.4, 0.95))
	box(root, Vector3(0.4, 0.7, 0.03), Vector3(0, 1.25, 1.0), team)


## Лавка странствующего торговца: повозка под полосатым навесом, сундуки, фонари.
static func _shop(root: Node3D) -> void:
	var cloth_a := Color("#c94a3a")
	var cloth_b := Color("#f1eee6")
	box(root, Vector3(2.4, 0.1, 2.2), Vector3(0, 0.05, 0), Color("#8a7a5c"))
	box(root, Vector3(1.6, 0.5, 1.0), Vector3(-0.2, 0.6, -0.4), WOOD)
	box(root, Vector3(1.7, 0.08, 1.1), Vector3(-0.2, 0.87, -0.4), DARKWOOD)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			cyl(root, 0.26, 0.26, 0.08, Vector3(-0.2 + float(sx) * 0.6, 0.3, -0.4 + float(sz) * 0.56), DARKWOOD, 8, Vector3(PI / 2, 0, 0))
			box(root, Vector3(0.08, 1.5, 0.08), Vector3(-0.2 + float(sx) * 0.95, 1.2, -0.4 + float(sz) * 0.7), DARKWOOD)
	for i in 6:
		box(root, Vector3(0.36, 0.06, 1.7), Vector3(-1.1 + i * 0.36, 1.98 + 0.06 * absf(float(i) - 2.5), -0.4), cloth_a if i % 2 == 0 else cloth_b, Vector3(0, 0, (float(i) - 2.5) * 0.09))
	for i in 6:
		box(root, Vector3(0.36, 0.22, 0.04), Vector3(-1.1 + i * 0.36, 1.82, 0.45), cloth_b if i % 2 == 0 else cloth_a)
	# товары на прилавке
	ball(root, 0.12, Vector3(-0.7, 1.02, -0.3), Color("#e0443a"), Vector3(1, 1.2, 1), true)
	ball(root, 0.12, Vector3(-0.4, 1.02, -0.5), Color("#4a8cff"), Vector3(1, 1.2, 1), true)
	box(root, Vector3(0.05, 0.05, 0.55), Vector3(0.0, 0.94, -0.35), STEEL, Vector3(0, 0.5, 0))
	cyl(root, 0.16, 0.16, 0.04, Vector3(0.35, 0.93, -0.4), GOLD, 8)
	# сундук с золотом, бочки, фонарь
	box(root, Vector3(0.6, 0.36, 0.4), Vector3(0.8, 0.28, 0.6), WOOD.lightened(0.1))
	box(root, Vector3(0.64, 0.08, 0.44), Vector3(0.8, 0.5, 0.6), IRON)
	for i in 4:
		ball(root, 0.07, Vector3(0.65 + i * 0.1, 0.57, 0.6 + 0.05 * (i % 2)), GOLD, Vector3.ONE, true)
	cyl(root, 0.2, 0.2, 0.46, Vector3(-0.9, 0.33, 0.7), WOOD, 8)
	cyl(root, 0.18, 0.18, 0.4, Vector3(-0.5, 0.3, 0.85), WOOD.darkened(0.1), 8)
	_lantern(root, Vector3(0.85, 1.7, 0.35))
	_lantern(root, Vector3(-1.2, 1.7, 0.35))
	box(root, Vector3(0.08, 2.4, 0.08), Vector3(1.0, 1.2, -1.0), DARKWOOD)
	box(root, Vector3(0.6, 0.4, 0.04), Vector3(0.68, 2.1, -1.0), GOLD)


static func _anvil(root: Node3D, pos: Vector3) -> void:
	box(root, Vector3(0.3, 0.3, 0.3), pos + Vector3(0, 0.15, 0), DARKWOOD)
	box(root, Vector3(0.5, 0.14, 0.22), pos + Vector3(0, 0.37, 0), IRON)
	cyl(root, 0.0, 0.08, 0.2, pos + Vector3(0.33, 0.37, 0), IRON, 4, Vector3(0, 0, -PI / 2))


static func _forge(root: Node3D, team: Color) -> void:
	box(root, Vector3(2.5, 0.24, 2.3), Vector3(0, 0.12, 0), STONE.darkened(0.12))
	box(root, Vector3(1.7, 1.2, 1.6), Vector3(-0.35, 0.84, -0.3), Color("#a59f92"))
	for i in 4:
		box(root, Vector3(1.72, 0.03, 1.62), Vector3(-0.35, 0.5 + i * 0.28, -0.3), Color("#7d766e"))
	roof(root, Vector3(2.0, 0.8, 1.9), Vector3(-0.35, 1.84, -0.3), Color("#5a3a26"))
	# горн с огнём и труба
	box(root, Vector3(0.7, 2.6, 0.7), Vector3(0.75, 1.3, -0.75), STONE.darkened(0.2))
	box(root, Vector3(0.85, 0.12, 0.85), Vector3(0.75, 2.62, -0.75), STONE)
	box(root, Vector3(0.5, 0.5, 0.1), Vector3(0.75, 0.7, -0.38), Color("#ff8a2a"), Vector3.ZERO, true)
	ball(root, 0.2, Vector3(0.75, 2.85, -0.75), Color("#6e737a"), Vector3(1, 0.8, 1))
	ball(root, 0.28, Vector3(0.85, 3.15, -0.7), Color("#8a8f96"), Vector3(1, 0.8, 1))
	# навес с наковальней
	for sx in [0.2, 1.1]:
		box(root, Vector3(0.1, 1.2, 0.1), Vector3(float(sx), 0.84, 0.95), DARKWOOD)
	box(root, Vector3(1.2, 0.08, 0.9), Vector3(0.65, 1.46, 0.6), Color("#7a3b2e"), Vector3(0.2, 0, 0))
	_anvil(root, Vector3(0.65, 0.24, 0.6))
	box(root, Vector3(0.04, 0.5, 0.04), Vector3(0.3, 0.62, 0.5), WOOD, Vector3(0, 0, 0.5))
	box(root, Vector3(0.16, 0.12, 0.12), Vector3(0.42, 0.84, 0.5), IRON)
	box(root, Vector3(0.6, 0.8, 0.08), Vector3(-0.6, 0.64, 0.52), DARKWOOD)
	cyl(root, 0.2, 0.2, 0.05, Vector3(-1.0, 1.1, 0.52), team, 8, Vector3(PI / 2, 0, 0))
	box(root, Vector3(0.03, 0.5, 0.06), Vector3(-0.1, 1.1, 0.53), STEEL, Vector3(0, 0, 0.6))
	box(root, Vector3(0.03, 0.5, 0.06), Vector3(-0.1, 1.1, 0.53), STEEL, Vector3(0, 0, -0.6))
	_flag(root, Vector3(-1.05, 1.3, -0.9), team, 1.3, 0.5)


static func _ogre_forge(root: Node3D, team: Color) -> void:
	cyl(root, 1.25, 1.3, 0.12, Vector3(0, 0.06, 0), Color("#8a7a5c"), 10)
	ball(root, 0.9, Vector3(-0.3, 0, -0.4), STONE.darkened(0.15), Vector3(1.1, 1.3, 1))
	ball(root, 0.55, Vector3(0.5, 0, -0.6), STONE, Vector3(1, 1.5, 1))
	box(root, Vector3(0.6, 0.6, 0.3), Vector3(-0.3, 0.45, 0.42), Color("#ff8a2a"), Vector3.ZERO, true)
	box(root, Vector3(0.9, 0.16, 0.4), Vector3(-0.3, 0.85, 0.45), STONE.darkened(0.3))
	for sx in [-1.0, 1.0]:
		_bone(root, Vector3(-0.3 + float(sx) * 0.55, 0.7, 0.5), 1.4, Vector3(0, 0, float(sx) * 0.3))
	# каменная наковальня и молот
	ball(root, 0.36, Vector3(0.7, 0.2, 0.6), STONE.lightened(0.08), Vector3(1.2, 0.8, 1))
	box(root, Vector3(0.07, 0.07, 0.8), Vector3(0.7, 0.62, 0.6), DARKWOOD, Vector3(0.9, 0.5, 0))
	box(root, Vector3(0.3, 0.26, 0.26), Vector3(0.82, 0.86, 0.38), IRON)
	# стойка с дубинами и шкура
	box(root, Vector3(0.08, 1.3, 0.08), Vector3(-1.0, 0.65, 0.7), DARKWOOD)
	box(root, Vector3(0.08, 1.3, 0.08), Vector3(-1.0, 0.65, -0.1), DARKWOOD)
	box(root, Vector3(0.06, 0.06, 0.9), Vector3(-1.0, 1.2, 0.3), DARKWOOD)
	for i in 3:
		cyl(root, 0.1, 0.04, 0.8, Vector3(-1.0, 0.75, 0.05 + i * 0.25), WOOD, 5)
	_skull_pole(root, Vector3(0.95, 0, -0.75), 1.5)
	box(root, Vector3(0.1, 2.0, 0.1), Vector3(-0.3, 1.9, -0.4), DARKWOOD)
	box(root, Vector3(0.5, 0.8, 0.03), Vector3(0.0, 2.4, -0.4), team)


static func _altar(root: Node3D, team: Color) -> void:
	var marble := Color("#d9d5cb")
	cyl(root, 1.35, 1.42, 0.2, Vector3(0, 0.1, 0), STONE, 8)
	cyl(root, 1.1, 1.18, 0.2, Vector3(0, 0.3, 0), marble, 8)
	cyl(root, 0.85, 0.9, 0.16, Vector3(0, 0.48, 0), marble.lightened(0.06), 8)
	box(root, Vector3(0.7, 0.14, 0.5), Vector3(0, 0.07, 1.4), STONE.lightened(0.08))
	box(root, Vector3(0.6, 0.14, 0.4), Vector3(0, 0.25, 1.25), marble)
	for i in 4:
		var a := float(i) * TAU / 4.0 + PI / 4
		var p := Vector3(sin(a) * 0.95, 0, cos(a) * 0.95)
		cyl(root, 0.11, 0.13, 1.5, p + Vector3(0, 1.15, 0), marble, 6)
		box(root, Vector3(0.34, 0.1, 0.34), p + Vector3(0, 0.45, 0), marble.darkened(0.1))
		box(root, Vector3(0.34, 0.1, 0.34), p + Vector3(0, 1.93, 0), marble.darkened(0.1))
		ball(root, 0.09, p + Vector3(0, 2.07, 0), GOLD, Vector3.ONE, true)
	cyl(root, 1.12, 1.12, 0.1, Vector3(0, 2.02, 0), marble.darkened(0.06), 8)
	cyl(root, 0.0, 1.0, 0.5, Vector3(0, 2.32, 0), team.darkened(0.08), 8)
	# меч в камне и сияющий кристалл
	box(root, Vector3(0.5, 0.3, 0.5), Vector3(0, 0.7, 0), STONE.darkened(0.1), Vector3(0, 0.4, 0))
	box(root, Vector3(0.07, 0.8, 0.03), Vector3(0, 1.2, 0), STEEL)
	box(root, Vector3(0.3, 0.05, 0.05), Vector3(0, 1.56, 0), GOLD)
	box(root, Vector3(0.05, 0.16, 0.05), Vector3(0, 1.66, 0), LEATHER)
	cyl(root, 0.0, 0.16, 0.3, Vector3(0, 1.0, 0), Color("#7fd6ff"), 4, Vector3.ZERO, true)
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.36, 0.9, 0.03), Vector3(float(sx) * 0.62, 1.4, 1.02), team)
		box(root, Vector3(0.4, 0.05, 0.05), Vector3(float(sx) * 0.62, 1.86, 1.02), GOLD)
	_flag(root, Vector3(0, 2.55, 0), team, 0.7, 0.4)


static func _ogre_totem(root: Node3D, team: Color) -> void:
	cyl(root, 1.3, 1.36, 0.14, Vector3(0, 0.07, 0), Color("#8a7a5c"), 10)
	for i in 8:
		var a := float(i) * TAU / 8.0
		var h := 0.5 + 0.25 * (i % 3)
		ball(root, 0.28, Vector3(sin(a) * 1.2, h * 0.5, cos(a) * 1.2), STONE.darkened(0.08 * (i % 3)), Vector3(0.9, h / 0.28 * 0.55, 0.9))
	# тотемный столб из трёх резных голов
	var faces := [Color("#7a4a2e"), Color("#9a3a2e"), Color("#5a6a3a")]
	for i in 3:
		var y := 0.55 + i * 0.85
		box(root, Vector3(0.75 - i * 0.08, 0.8, 0.7 - i * 0.08), Vector3(0, y, 0), faces[i])
		box(root, Vector3(0.8 - i * 0.08, 0.1, 0.74 - i * 0.08), Vector3(0, y + 0.4, 0), DARKWOOD)
		for sx in [-1.0, 1.0]:
			var x: float = sx
			box(root, Vector3(0.14, 0.12, 0.05), Vector3(x * 0.17, y + 0.14, 0.36 - i * 0.04), Color("#ffd94a"), Vector3.ZERO, true)
			cyl(root, 0.0, 0.05, 0.22, Vector3(x * 0.15, y - 0.2, 0.4 - i * 0.04), IVORY, 4)
		box(root, Vector3(0.3, 0.07, 0.06), Vector3(0, y - 0.1, 0.36 - i * 0.04), Color("#1c1a18"))
	for sx in [-1.0, 1.0]:
		var x: float = sx
		box(root, Vector3(0.9, 0.12, 0.3), Vector3(x * 0.7, 2.35, 0), faces[1], Vector3(0, 0, x * 0.35))
		cyl(root, 0.0, 0.08, 0.5, Vector3(x * 1.15, 2.75, 0), IVORY, 5, Vector3(0, 0, -x * 0.3))
	ball(root, 0.2, Vector3(0, 3.1, 0), IVORY, Vector3(1, 0.95, 1.1))
	_skull_pole(root, Vector3(-0.95, 0, 0.85), 1.1)
	_fire(root, Vector3(0.9, 0.14, 0.9), 0.24)
	box(root, Vector3(0.1, 2.2, 0.1), Vector3(-0.9, 1.1, -0.8), DARKWOOD)
	box(root, Vector3(0.5, 0.9, 0.03), Vector3(-0.6, 1.7, -0.8), team)


# =====================================================================
#  ПРИРОДА
# =====================================================================

## Храм света (люди): каменный зал с куполом и шпилем.
static func _temple(root: Node3D, team: Color) -> void:
	var wall := Color("#e6dabd")
	box(root, Vector3(2.7, 0.3, 2.7), Vector3(0, 0.15, 0), STONE)
	box(root, Vector3(2.2, 1.3, 2.0), Vector3(0, 0.95, 0), wall)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			cyl(root, 0.16, 0.18, 1.6, Vector3(float(sx) * 1.1, 1.1, float(sz) * 1.0), STONE.lightened(0.1), 6)
			cyl(root, 0.0, 0.2, 0.4, Vector3(float(sx) * 1.1, 2.1, float(sz) * 1.0), team, 6)
	cyl(root, 1.0, 1.05, 0.2, Vector3(0, 1.7, 0), STONE.lightened(0.05), 10)
	ball(root, 0.95, Vector3(0, 1.8, 0), Color("#d8d2c4"), Vector3(1, 0.8, 1))
	cyl(root, 0.06, 0.06, 0.8, Vector3(0, 2.9, 0), GOLD, 5)
	box(root, Vector3(0.5, 0.08, 0.08), Vector3(0, 3.05, 0), GOLD)
	ball(root, 0.1, Vector3(0, 3.35, 0), Color("#fff3b0"), Vector3.ONE, true)
	box(root, Vector3(0.7, 1.0, 0.1), Vector3(0, 0.75, 1.02), DARKWOOD)
	cyl(root, 0.35, 0.35, 0.1, Vector3(0, 1.25, 1.02), DARKWOOD, 8, Vector3(PI / 2, 0, 0))
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.3, 0.9, 0.03), Vector3(float(sx) * 0.62, 1.1, 1.02), team)
		box(root, Vector3(0.22, 0.4, 0.05), Vector3(float(sx) * 1.11, 1.0, 0.0), Color("#f4d67a"), Vector3(0, PI / 2, 0), true)


## Мастерская (люди): деревянный навес, кран и большое колесо.
static func _workshop(root: Node3D, team: Color) -> void:
	box(root, Vector3(2.6, 0.12, 2.4), Vector3(0, 0.06, 0), STONE.darkened(0.1))
	box(root, Vector3(1.6, 1.1, 1.6), Vector3(-0.4, 0.66, -0.3), Color("#c9b48a"))
	roof(root, Vector3(1.8, 0.7, 1.8), Vector3(-0.4, 1.56, -0.3), Color("#8a4a3a"))
	for sz in [-1.0, 1.0]:
		box(root, Vector3(0.1, 1.5, 0.1), Vector3(0.95, 0.75, float(sz) * 0.8), DARKWOOD)
	box(root, Vector3(0.12, 0.1, 1.8), Vector3(0.95, 1.5, 0), DARKWOOD)
	box(root, Vector3(0.1, 0.1, 1.4), Vector3(1.0, 1.9, 0.5), WOOD, Vector3(0.6, 0, 0))
	box(root, Vector3(0.02, 0.8, 0.02), Vector3(1.0, 1.7, 1.05), IVORY)
	box(root, Vector3(0.25, 0.25, 0.25), Vector3(1.0, 1.2, 1.05), STONE)
	cyl(root, 0.55, 0.55, 0.1, Vector3(0.5, 0.6, 0.95), DARKWOOD, 10, Vector3(0, 0, PI / 2))
	cyl(root, 0.15, 0.15, 0.14, Vector3(0.5, 0.6, 0.95), IRON, 6, Vector3(0, 0, PI / 2))
	for i in 3:
		cyl(root, 0.12, 0.12, 1.3, Vector3(-0.6 + i * 0.05, 0.12 + i * 0.2, 0.95), WOOD.darkened(0.05 * i), 6, Vector3(0, 0, PI / 2))
	box(root, Vector3(0.5, 0.6, 0.03), Vector3(-0.4, 0.8, 0.52), team)


## Хижина знахаря (огры): круглая хижина с черепами и костром.
static func _ogre_hut(root: Node3D, team: Color) -> void:
	var hide := Color("#8a6a48")
	cyl(root, 1.0, 1.1, 1.0, Vector3(0, 0.5, 0), Color("#6a5236"), 9)
	cyl(root, 0.1, 1.35, 1.3, Vector3(0, 1.6, 0), hide, 9)
	cyl(root, 0.0, 0.12, 0.6, Vector3(0, 2.5, 0), DARKWOOD, 5)
	ball(root, 0.15, Vector3(0, 2.85, 0), IVORY)
	box(root, Vector3(0.6, 0.8, 0.2), Vector3(0, 0.4, 1.02), Color("#14110f"))
	for i in 5:
		var a := float(i) * TAU / 5.0 + 0.3
		_bone(root, Vector3(sin(a) * 1.15, 1.2, cos(a) * 1.15), 0.7, Vector3(cos(a) * 0.5, 0, -sin(a) * 0.5))
	_skull_pole(root, Vector3(-1.2, 0, 1.0), 1.1)
	_skull_pole(root, Vector3(1.2, 0, 1.0), 1.3)
	_fire(root, Vector3(0.9, 0, -1.0), 0.22)
	box(root, Vector3(0.4, 0.6, 0.03), Vector3(0, 1.35, 1.0), team, Vector3(-0.4, 0, 0))
	ball(root, 0.16, Vector3(-0.3, 1.1, 1.05), Color("#8cff7a"), Vector3.ONE, true)


## Двор разрушителей (огры): частокол, брёвна и колёса будущих таранов.
static func _ogre_yard(root: Node3D, team: Color) -> void:
	cyl(root, 1.3, 1.35, 0.06, Vector3(0, 0.03, 0), Color("#a8905c"), 12)
	for i in 14:
		var a := float(i) * TAU / 14.0
		if absf(wrapf(a, -PI, PI)) < 0.5:
			continue
		var h := 0.9 + 0.2 * (i % 3)
		cyl(root, 0.1, 0.12, h, Vector3(sin(a) * 1.3, h * 0.5, cos(a) * 1.3), WOOD if i % 2 == 0 else DARKWOOD, 6)
	for i in 3:
		cyl(root, 0.17, 0.17, 1.6, Vector3(-0.2, 0.17 + i * 0.3, -0.4 + i * 0.05), WOOD.darkened(0.06 * i), 7, Vector3(0, 0, PI / 2))
	for sx in [-1.0, 1.0]:
		cyl(root, 0.35, 0.35, 0.1, Vector3(float(sx) * 0.75, 0.35, 0.45), DARKWOOD, 8, Vector3(0, 0, PI / 2))
	box(root, Vector3(0.12, 2.2, 0.12), Vector3(0.9, 1.1, -0.9), DARKWOOD)
	box(root, Vector3(0.55, 0.9, 0.03), Vector3(0.9, 1.7, -0.83), team)
	_skull_pole(root, Vector3(-0.6, 0, 1.25), 1.2)


## Святилище луны (эльфы): кольцо белых колонн и светящаяся луна над алтарём.
static func _elf_shrine(root: Node3D, team: Color) -> void:
	cyl(root, 1.3, 1.35, 0.2, Vector3(0, 0.1, 0), STONE.lightened(0.15), 12)
	cyl(root, 0.9, 0.9, 0.04, Vector3(0, 0.22, 0), MOON, 12, Vector3.ZERO, true)
	for i in 6:
		var a := float(i) * TAU / 6.0
		cyl(root, 0.1, 0.13, 1.8, Vector3(sin(a) * 1.1, 1.1, cos(a) * 1.1), STONE.lightened(0.2), 6)
		ball(root, 0.16, Vector3(sin(a) * 1.1, 2.05, cos(a) * 1.1), LEAF, Vector3(1, 0.8, 1))
	cyl(root, 1.2, 1.2, 0.08, Vector3(0, 2.0, 0), WOOD.lightened(0.1), 12)
	cyl(root, 0.25, 0.35, 0.6, Vector3(0, 0.5, 0), STONE.lightened(0.1), 6)
	ball(root, 0.32, Vector3(0, 1.35, 0), MOON, Vector3.ONE, true)
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.3, 0.7, 0.03), Vector3(float(sx) * 0.5, 1.5, 1.05), team, Vector3(0, float(sx) * 0.3, 0))


## Мастерская древних (эльфы): живой навес из ветвей и сложенные стволы.
static func _elf_works(root: Node3D, team: Color) -> void:
	box(root, Vector3(2.4, 0.1, 2.2), Vector3(0, 0.05, 0), Color("#6a5a3a"))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			cyl(root, 0.12, 0.2, 1.7, Vector3(float(sx) * 0.95, 0.85, float(sz) * 0.85), BARK, 6, Vector3(float(sz) * 0.12, 0, -float(sx) * 0.12))
	for i in 5:
		var p := Vector3(-0.8 + i * 0.4, 1.85 + 0.1 * (i % 2), -0.2 + 0.3 * ((i * 3) % 3) * 0.5)
		ball(root, 0.62, p, LEAF.darkened(0.05 * (i % 2)), Vector3(1, 0.6, 1))
	for i in 3:
		cyl(root, 0.16, 0.16, 1.5, Vector3(0.1, 0.17 + i * 0.3, 0.2 + i * 0.04), BARK.lightened(0.05 * i), 7, Vector3(0, 0, PI / 2))
	box(root, Vector3(0.6, 0.06, 0.9), Vector3(-0.5, 0.5, -0.5), WOOD)
	_lantern(root, Vector3(0.95, 1.3, 0.85))
	_lantern(root, Vector3(-0.95, 1.3, 0.85))
	box(root, Vector3(0.4, 0.6, 0.03), Vector3(0, 1.2, 0.95), team)


const DSTONE := Color("#8c8478")      # тёсаный камень гномов
const BRASS := Color("#c9a24a")
const RUNE := Color("#ffb03a")        # светящиеся руны


## Постройки гномов: тёсаный камень, латунь, трубы и светящиеся руны.
static func _dwarf(root: Node3D, team: Color, kind: String) -> void:
	match kind:
		"dwarf_hall":       # горный чертог: каменный массив с «горой» над ним, трубы и большие ворота
			box(root, Vector3(3.7, 0.4, 3.7), Vector3(0, 0.2, 0), DSTONE.darkened(0.2))
			box(root, Vector3(3.1, 1.5, 2.8), Vector3(0, 1.05, -0.1), DSTONE)
			cyl(root, 0.0, 2.1, 1.7, Vector3(0, 2.65, -0.1), DSTONE.darkened(0.1), 4, Vector3(0, PI / 4, 0))
			cyl(root, 0.0, 0.7, 0.6, Vector3(0, 3.35, -0.1), Color("#e8e8ec"), 4, Vector3(0, PI / 4, 0))
			box(root, Vector3(1.1, 1.1, 0.25), Vector3(0, 0.75, 1.32), Color("#1c1814"))
			box(root, Vector3(1.4, 0.16, 0.3), Vector3(0, 1.35, 1.34), BRASS)
			for sx in [-1.0, 1.0]:
				box(root, Vector3(0.16, 1.2, 0.3), Vector3(float(sx) * 0.62, 0.8, 1.34), BRASS.darkened(0.15))
				cyl(root, 0.16, 0.2, 1.6, Vector3(float(sx) * 1.2, 2.4, -0.9), BRASS, 6)
				_fire(root, Vector3(float(sx) * 1.2, 3.2, -0.9), 0.12)
				box(root, Vector3(0.45, 0.9, 0.04), Vector3(float(sx) * 1.1, 1.2, 1.32), team)
				ball(root, 0.22, Vector3(float(sx) * 1.6, 0.6, 1.6), DSTONE.lightened(0.1), Vector3(1, 1.4, 1))
			box(root, Vector3(0.5, 0.08, 0.04), Vector3(0, 1.62, 1.36), RUNE, Vector3.ZERO, true)
		"dwarf_house":      # дом гнома: приземистый, с дерновой крышей и круглой дверью
			cyl(root, 0.75, 0.8, 0.7, Vector3(0, 0.35, 0), DSTONE, 8)
			ball(root, 0.82, Vector3(0, 0.7, 0), Color("#6a7a3a"), Vector3(1, 0.6, 1))
			cyl(root, 0.24, 0.24, 0.06, Vector3(0, 0.3, 0.76), Color("#5a3a1a"), 8, Vector3(PI / 2, 0, 0))
			ball(root, 0.03, Vector3(0.1, 0.3, 0.8), BRASS)
			cyl(root, 0.1, 0.12, 0.6, Vector3(0.4, 1.1, -0.3), DSTONE.darkened(0.2), 6)
			box(root, Vector3(0.3, 0.3, 0.03), Vector3(-0.45, 0.45, 0.65), team)
		"dwarf_barracks":   # казарма клана: длинный каменный дом, скрещённые топоры, чучело
			box(root, Vector3(2.5, 1.1, 1.8), Vector3(0, 0.55, -0.1), DSTONE)
			roof(root, Vector3(2.7, 0.8, 2.0), Vector3(0, 1.5, -0.1), Color("#6a3a2a"))
			box(root, Vector3(0.7, 0.8, 0.1), Vector3(0, 0.4, 0.82), Color("#2a1e14"))
			for sx in [-1.0, 1.0]:
				box(root, Vector3(0.06, 0.9, 0.06), Vector3(0, 1.35, 0.85), DARKWOOD, Vector3(0, 0, float(sx) * 0.7))
				box(root, Vector3(0.05, 0.22, 0.16), Vector3(float(sx) * 0.28, 1.65, 0.86), STEEL)
			box(root, Vector3(0.5, 0.6, 0.03), Vector3(0.8, 0.75, 0.82), team)
			box(root, Vector3(0.08, 0.9, 0.08), Vector3(-1.0, 0.45, 1.1), WOOD)
			ball(root, 0.2, Vector3(-1.0, 0.95, 1.1), STRAW, Vector3(1, 1.2, 1))
		"dwarf_tower":      # пушечная башня: круглая каменная башня с латунной пушкой
			cyl(root, 0.62, 0.78, 1.8, Vector3(0, 0.9, 0), DSTONE, 8)
			cyl(root, 0.78, 0.78, 0.2, Vector3(0, 1.9, 0), DSTONE.darkened(0.15), 8)
			for i in 8:
				var a := float(i) * TAU / 8.0
				box(root, Vector3(0.2, 0.25, 0.2), Vector3(sin(a) * 0.7, 2.1, cos(a) * 0.7), DSTONE.darkened(0.15))
			cyl(root, 0.12, 0.17, 1.1, Vector3(0, 2.25, 0.35), BRASS, 8, Vector3(PI / 2 - 0.25, 0, 0))
			cyl(root, 0.25, 0.25, 0.2, Vector3(0, 2.1, -0.1), IRON, 8, Vector3(0, 0, PI / 2))
			box(root, Vector3(0.35, 0.45, 0.03), Vector3(0.3, 1.0, 0.75), team)
		"dwarf_altar":      # зал предков: круг стоячих камней и статуя с рунным молотом
			cyl(root, 1.25, 1.3, 0.2, Vector3(0, 0.1, 0), DSTONE.darkened(0.15), 10)
			for i in 6:
				var a := float(i) * TAU / 6.0 + 0.3
				box(root, Vector3(0.3, 1.2, 0.25), Vector3(sin(a) * 1.0, 0.75, cos(a) * 1.0), DSTONE, Vector3(0, a, 0))
				box(root, Vector3(0.06, 0.4, 0.02), Vector3(sin(a) * 1.0, 0.85, cos(a) * 1.0 + 0.13), RUNE, Vector3(0, a, 0), true)
			box(root, Vector3(0.45, 0.9, 0.35), Vector3(0, 0.65, 0), DSTONE.lightened(0.1))
			ball(root, 0.2, Vector3(0, 1.3, 0), DSTONE.lightened(0.1))
			box(root, Vector3(0.45, 0.25, 0.25), Vector3(0.25, 1.6, 0), BRASS)
			box(root, Vector3(0.5, 0.5, 0.03), Vector3(0, 0.6, 0.19), team)
		"dwarf_forge":      # рунная кузня: широкий горн, огромная труба, наковальня
			box(root, Vector3(2.1, 1.0, 1.6), Vector3(0, 0.5, -0.1), DSTONE)
			roof(root, Vector3(2.3, 0.5, 1.8), Vector3(0, 1.25, -0.1), DSTONE.darkened(0.25))
			cyl(root, 0.3, 0.42, 2.2, Vector3(-0.6, 1.6, -0.4), DSTONE.darkened(0.1), 6)
			_fire(root, Vector3(-0.6, 2.75, -0.4), 0.18)
			box(root, Vector3(0.8, 0.5, 0.2), Vector3(0.3, 0.4, 0.72), Color("#ff6a1a"), Vector3.ZERO, true)
			_anvil(root, Vector3(0.6, 0, 1.15))
			box(root, Vector3(0.45, 0.55, 0.03), Vector3(-0.6, 0.6, 0.72), team)
		"dwarf_shrine":     # святилище рун: купол на каменном основании, светящиеся руны вокруг
			cyl(root, 1.1, 1.2, 0.8, Vector3(0, 0.4, 0), DSTONE, 10)
			ball(root, 1.0, Vector3(0, 0.85, 0), BRASS.darkened(0.15), Vector3(1, 0.8, 1))
			cyl(root, 0.0, 0.12, 0.5, Vector3(0, 1.85, 0), BRASS, 6)
			ball(root, 0.14, Vector3(0, 2.15, 0), RUNE, Vector3.ONE, true)
			for i in 8:
				var a := float(i) * TAU / 8.0
				box(root, Vector3(0.12, 0.3, 0.02), Vector3(sin(a) * 1.13, 0.45, cos(a) * 1.13), RUNE, Vector3(0, a, 0), true)
			box(root, Vector3(0.5, 0.6, 0.12), Vector3(0, 0.3, 1.1), Color("#1c1814"))
			box(root, Vector3(0.6, 0.4, 0.03), Vector3(0, 0.85, 1.05), team)
		"dwarf_works":      # паровая мастерская: цех с латунным котлом, трубами и шестернёй
			box(root, Vector3(2.0, 1.0, 1.6), Vector3(-0.2, 0.5, -0.1), DSTONE)
			roof(root, Vector3(2.2, 0.5, 1.8), Vector3(-0.2, 1.25, -0.1), Color("#5a4a3a"))
			cyl(root, 0.45, 0.45, 1.3, Vector3(0.95, 0.55, 0.2), BRASS, 10, Vector3(PI / 2, 0, 0))
			cyl(root, 0.1, 0.1, 1.4, Vector3(0.95, 1.4, -0.2), IRON, 6)
			ball(root, 0.2, Vector3(0.95, 2.2, -0.2), Color("#d8d8dc"), Vector3(1.2, 0.8, 1.2))
			cyl(root, 0.42, 0.42, 0.08, Vector3(-0.6, 0.7, 0.73), IRON, 10, Vector3(PI / 2, 0, 0))
			for i in 8:
				var a := float(i) * TAU / 8.0
				box(root, Vector3(0.1, 0.1, 0.08), Vector3(-0.6 + sin(a) * 0.46, 0.7 + cos(a) * 0.46, 0.73), IRON)
			box(root, Vector3(0.4, 0.5, 0.03), Vector3(0.15, 0.7, 0.71), team)


const SEASTONE := Color("#4f8a86")    # морской камень нагов
const CORAL := Color("#ff7a8a")
const SHELL := Color("#f0e2c8")
const SEA := Color("#3aa8d0")         # светящаяся вода


static func _coral(root: Node3D, pos: Vector3, h: float, c: Color) -> void:
	cyl(root, 0.03, 0.07, h, pos + Vector3(0, h * 0.5, 0), c, 5)
	cyl(root, 0.02, 0.05, h * 0.6, pos + Vector3(0.1, h * 0.65, 0), c.lightened(0.1), 5, Vector3(0, 0, -0.6))
	cyl(root, 0.02, 0.05, h * 0.5, pos + Vector3(-0.08, h * 0.55, 0.05), c.darkened(0.1), 5, Vector3(0.3, 0, 0.6))


## Постройки нагов: морской камень, кораллы, раковины и светящаяся вода.
static func _naga(root: Node3D, team: Color, kind: String) -> void:
	match kind:
		"naga_hall":        # дворец прилива: бассейн, спиральная башня с раковиной, кораллы
			cyl(root, 1.85, 1.9, 0.3, Vector3(0, 0.15, 0), SEASTONE.darkened(0.2), 12)
			cyl(root, 1.5, 1.5, 0.05, Vector3(0, 0.32, 0), SEA, 12, Vector3.ZERO, true)
			for i in 4:
				var r := 1.1 - i * 0.22
				cyl(root, r * 0.85, r, 0.75, Vector3(0, 0.6 + i * 0.7, 0), SEASTONE.lightened(0.04 * i), 8, Vector3(0, i * 0.4, 0))
			ball(root, 0.42, Vector3(0, 3.6, 0), SHELL, Vector3(0.8, 1.3, 0.8))
			cyl(root, 0.0, 0.2, 0.5, Vector3(0, 4.25, 0), SHELL.darkened(0.1), 6)
			ball(root, 0.16, Vector3(0, 1.6, 0.92), SEA, Vector3.ONE, true)
			for i in 6:
				var a := float(i) * TAU / 6.0
				_coral(root, Vector3(sin(a) * 1.6, 0.3, cos(a) * 1.6), 0.8, CORAL if i % 2 == 0 else Color("#ff9a5a"))
			box(root, Vector3(0.7, 0.9, 0.12), Vector3(0, 0.75, 1.0), Color("#102830"))
			for sx in [-1.0, 1.0]:
				box(root, Vector3(0.4, 1.0, 0.03), Vector3(float(sx) * 0.7, 1.4, 0.8), team, Vector3(0, float(sx) * 0.4, 0))
		"naga_pool":        # коралловый садок: светящийся пруд в кольце кораллов
			cyl(root, 0.85, 0.9, 0.3, Vector3(0, 0.15, 0), SEASTONE, 10)
			cyl(root, 0.7, 0.7, 0.05, Vector3(0, 0.31, 0), SEA, 10, Vector3.ZERO, true)
			for i in 5:
				var a := float(i) * TAU / 5.0 + 0.3
				_coral(root, Vector3(sin(a) * 0.75, 0.25, cos(a) * 0.75), 0.6, CORAL.darkened(0.1 * (i % 2)))
			box(root, Vector3(0.05, 0.9, 0.05), Vector3(-0.6, 0.6, 0.6), SEASTONE.darkened(0.2))
			box(root, Vector3(0.3, 0.25, 0.03), Vector3(-0.45, 0.95, 0.6), team)
		"naga_barracks":    # казармы прилива: огромная раковина с тёмным входом
			cyl(root, 1.25, 1.3, 0.2, Vector3(0, 0.1, 0), SEASTONE.darkened(0.15), 10)
			ball(root, 1.15, Vector3(0, 0.5, -0.1), SHELL, Vector3(1.05, 0.95, 1.2))
			for i in 5:
				box(root, Vector3(0.06, 1.1, 2.4), Vector3((i - 2) * 0.4, 0.95, -0.1), SHELL.darkened(0.12), Vector3(0, 0, (i - 2) * 0.28))
			box(root, Vector3(0.8, 0.9, 0.3), Vector3(0, 0.55, 1.15), Color("#102830"))
			_coral(root, Vector3(1.1, 0.2, 0.9), 0.7, CORAL)
			box(root, Vector3(0.5, 0.6, 0.03), Vector3(-0.9, 0.9, 1.0), team)
		"naga_tower":       # коралловый шпиль: витая башня со светящейся сферой
			cyl(root, 0.6, 0.75, 0.4, Vector3(0, 0.2, 0), SEASTONE.darkened(0.15), 8)
			for i in 5:
				cyl(root, 0.42 - i * 0.06, 0.48 - i * 0.06, 0.5, Vector3(sin(i * 0.9) * 0.06, 0.65 + i * 0.48, cos(i * 0.9) * 0.06), SEASTONE.lightened(0.05 * i), 6, Vector3(0, i * 0.6, 0))
			_coral(root, Vector3(0.35, 0.4, 0.3), 0.9, CORAL)
			ball(root, 0.24, Vector3(0, 3.2, 0), SEA, Vector3.ONE, true)
			box(root, Vector3(0.3, 0.4, 0.03), Vector3(0, 1.0, 0.52), team)
		"naga_altar":       # алтарь глубин: кольцо арок и парящая сфера воды
			cyl(root, 1.25, 1.3, 0.25, Vector3(0, 0.12, 0), SEASTONE.darkened(0.1), 12)
			for i in 6:
				var a := float(i) * TAU / 6.0
				box(root, Vector3(0.2, 1.4, 0.2), Vector3(sin(a) * 1.0, 0.9, cos(a) * 1.0), SEASTONE.lightened(0.08))
				ball(root, 0.12, Vector3(sin(a) * 1.0, 1.7, cos(a) * 1.0), SHELL)
			ball(root, 0.4, Vector3(0, 1.4, 0), SEA, Vector3.ONE, true)
			cyl(root, 0.5, 0.6, 0.3, Vector3(0, 0.4, 0), SEASTONE, 8)
			box(root, Vector3(0.5, 0.5, 0.03), Vector3(0, 0.6, 0.62), team)
		"naga_forge":       # кузня прилива: каменный горн, крыша-раковина, пар из жерла
			box(root, Vector3(2.0, 0.9, 1.6), Vector3(0, 0.45, -0.1), SEASTONE)
			ball(root, 1.05, Vector3(0, 0.95, -0.1), SHELL.darkened(0.08), Vector3(1.05, 0.45, 0.85))
			cyl(root, 0.22, 0.3, 1.2, Vector3(0.6, 1.4, -0.5), SEASTONE.darkened(0.2), 6)
			ball(root, 0.25, Vector3(0.6, 2.15, -0.5), Color("#e8f4f8"), Vector3(1.3, 0.8, 1.3))
			_anvil(root, Vector3(-0.5, 0, 1.1))
			box(root, Vector3(0.6, 0.35, 0.15), Vector3(0.35, 0.35, 0.72), SEA, Vector3.ZERO, true)
			box(root, Vector3(0.45, 0.5, 0.03), Vector3(-0.55, 0.6, 0.72), team)
		"naga_temple":      # святилище сирен: ступени и огромная раскрытая раковина с жемчужиной
			box(root, Vector3(2.4, 0.3, 2.4), Vector3(0, 0.15, 0), SEASTONE.darkened(0.1))
			box(root, Vector3(1.8, 0.3, 1.8), Vector3(0, 0.45, 0), SEASTONE)
			ball(root, 0.9, Vector3(0, 0.75, -0.2), SHELL, Vector3(1.2, 0.35, 1.0))
			ball(root, 0.9, Vector3(0, 1.35, -0.55), SHELL.lightened(0.05), Vector3(1.2, 0.3, 1.0))
			ball(root, 0.28, Vector3(0, 1.0, -0.1), Color("#f8f4ff"), Vector3.ONE, true)
			for sx in [-1.0, 1.0]:
				_coral(root, Vector3(float(sx) * 1.0, 0.6, 0.8), 0.7, CORAL)
			box(root, Vector3(0.6, 0.4, 0.03), Vector3(0, 0.45, 0.91), team)
		"naga_works":       # гарпунная верфь: деревянный помост, кран и связки гарпунов
			box(root, Vector3(2.4, 0.2, 2.2), Vector3(0, 0.1, 0), DARKWOOD)
			for i in 6:
				box(root, Vector3(0.36, 0.04, 2.2), Vector3(-1.0 + i * 0.4, 0.22, 0), WOOD.darkened(0.05 * (i % 2)))
			box(root, Vector3(0.16, 2.2, 0.16), Vector3(-0.8, 1.2, -0.7), DARKWOOD)
			box(root, Vector3(1.6, 0.12, 0.12), Vector3(-0.1, 2.25, -0.7), DARKWOOD)
			box(root, Vector3(0.02, 0.8, 0.02), Vector3(0.6, 1.8, -0.7), IVORY)
			for i in 3:
				box(root, Vector3(0.05, 0.05, 1.3), Vector3(0.5 + i * 0.12, 0.5, 0.3), WOOD, Vector3(0.3, 0, 0))
				cyl(root, 0.0, 0.06, 0.2, Vector3(0.5 + i * 0.12, 0.85, 0.9), STEEL, 4, Vector3(PI / 2 - 0.3, 0, 0))
			cyl(root, 0.4, 0.4, 0.5, Vector3(-0.6, 0.45, 0.6), SEASTONE, 8)
			box(root, Vector3(0.45, 0.5, 0.03), Vector3(-0.8, 1.6, -0.6), team)


const GRAVE := Color("#4a4a52")       # тёмный камень нежити
const BONE := Color("#ddd6c2")
const GHOST := Color("#6aff8a")       # мертвенно-зелёный свет


static func _tomb(root: Node3D, pos: Vector3, rot: float) -> void:
	box(root, Vector3(0.32, 0.5, 0.1), pos + Vector3(0, 0.25, 0), GRAVE.lightened(0.15), Vector3(0, rot, 0.08))


static func _spikes(root: Node3D, center: Vector3, r: float, n: int, h: float) -> void:
	for i in n:
		var a := float(i) * TAU / float(n)
		cyl(root, 0.0, 0.09, h, center + Vector3(sin(a) * r, h * 0.5, cos(a) * r), BONE, 4, Vector3(cos(a) * 0.3, 0, -sin(a) * 0.3))


## Постройки нежити: тёмный камень, кости, могилы и зелёные огни.
static func _undead(root: Node3D, team: Color, kind: String) -> void:
	match kind:
		"undead_hall":      # некрополь: ступенчатый зиккурат с шипами и зелёным огнём
			box(root, Vector3(3.6, 0.5, 3.6), Vector3(0, 0.25, 0), GRAVE)
			box(root, Vector3(2.8, 0.7, 2.8), Vector3(0, 0.85, 0), GRAVE.lightened(0.05))
			box(root, Vector3(2.0, 0.8, 2.0), Vector3(0, 1.6, 0), GRAVE.lightened(0.1))
			cyl(root, 0.0, 0.7, 1.6, Vector3(0, 2.8, 0), GRAVE.darkened(0.1), 4)
			ball(root, 0.3, Vector3(0, 3.7, 0), GHOST, Vector3.ONE, true)
			_spikes(root, Vector3(0, 0.5, 0), 1.7, 10, 0.9)
			box(root, Vector3(0.8, 1.0, 0.2), Vector3(0, 0.6, 1.45), Color("#14110f"))
			for sx in [-1.0, 1.0]:
				box(root, Vector3(0.4, 1.2, 0.04), Vector3(float(sx) * 0.9, 1.6, 1.01), team)
				ball(root, 0.12, Vector3(float(sx) * 1.3, 1.3, 1.3), GHOST, Vector3.ONE, true)
		"undead_crypt":     # склеп: каменный склеп с ангелом-черепом и надгробиями
			box(root, Vector3(1.5, 0.9, 1.3), Vector3(0, 0.45, 0), GRAVE)
			roof(root, Vector3(1.6, 0.6, 1.4), Vector3(0, 1.2, 0), GRAVE.darkened(0.15))
			box(root, Vector3(0.5, 0.7, 0.08), Vector3(0, 0.35, 0.66), Color("#14110f"))
			ball(root, 0.16, Vector3(0, 1.6, 0.4), BONE)
			_tomb(root, Vector3(-0.7, 0, 0.9), 0.2)
			_tomb(root, Vector3(0.7, 0, 0.85), -0.15)
			box(root, Vector3(0.3, 0.4, 0.03), Vector3(0.5, 0.6, 0.67), team)
		"undead_barracks":  # костяная яма: кольцо рёбер вокруг тёмной ямы
			cyl(root, 1.2, 1.25, 0.1, Vector3(0, 0.05, 0), Color("#2a2420"), 12)
			cyl(root, 0.8, 0.8, 0.02, Vector3(0, 0.11, 0), Color("#14110f"), 12)
			for i in 12:
				var a := float(i) * TAU / 12.0
				if absf(wrapf(a, -PI, PI)) < 0.4:
					continue
				_bone(root, Vector3(sin(a) * 1.15, 0.7, cos(a) * 1.15), 1.6, Vector3(-cos(a) * 0.35, 0, sin(a) * 0.35))
			ball(root, 0.35, Vector3(0, 0.4, 0), BONE, Vector3(1.2, 1, 1.4))
			box(root, Vector3(0.1, 2.2, 0.1), Vector3(-1.2, 1.1, -0.9), GRAVE)
			box(root, Vector3(0.5, 0.8, 0.03), Vector3(-0.95, 1.7, -0.9), team)
		"undead_tower":     # башня духов: костяной шпиль с парящим черепом
			cyl(root, 0.5, 0.8, 0.5, Vector3(0, 0.25, 0), GRAVE, 6)
			cyl(root, 0.2, 0.45, 2.4, Vector3(0, 1.7, 0), GRAVE.lightened(0.08), 6)
			_spikes(root, Vector3(0, 1.0, 0), 0.5, 6, 0.8)
			ball(root, 0.3, Vector3(0, 3.2, 0), BONE)
			ball(root, 0.14, Vector3(0, 3.2, 0.2), GHOST, Vector3.ONE, true)
			box(root, Vector3(0.35, 0.5, 0.03), Vector3(0.25, 2.2, 0.32), team)
		"undead_altar":     # алтарь тьмы: плита на ступенях, черепа и зелёное пламя
			box(root, Vector3(2.4, 0.3, 2.4), Vector3(0, 0.15, 0), GRAVE)
			box(root, Vector3(1.6, 0.3, 1.6), Vector3(0, 0.45, 0), GRAVE.lightened(0.06))
			box(root, Vector3(1.0, 0.5, 0.6), Vector3(0, 0.85, 0), GRAVE.darkened(0.1))
			cyl(root, 0.0, 0.3, 0.9, Vector3(0, 1.55, 0), GHOST, 5, Vector3.ZERO, true)
			for i in 4:
				var a := float(i) * TAU / 4.0 + PI / 4.0
				_skull_pole(root, Vector3(sin(a) * 1.1, 0.3, cos(a) * 1.1), 1.0)
			box(root, Vector3(0.6, 0.7, 0.03), Vector3(0, 1.0, 0.32), team)
		"undead_forge":     # кладбищенская кузня: тёмная кузня с костяной трубой
			box(root, Vector3(2.0, 1.1, 1.6), Vector3(0, 0.55, 0), GRAVE)
			roof(root, Vector3(2.2, 0.7, 1.8), Vector3(0, 1.45, 0), GRAVE.darkened(0.2))
			cyl(root, 0.2, 0.25, 1.4, Vector3(0.7, 1.9, -0.4), BONE, 6)
			_fire(root, Vector3(0, 0, 1.1), 0.2)
			_anvil(root, Vector3(-0.6, 0, 1.1))
			_tomb(root, Vector3(1.1, 0, 1.0), 0.3)
			box(root, Vector3(0.5, 0.6, 0.03), Vector3(-0.3, 0.8, 0.81), team)
		"undead_temple":    # храм проклятых: тёмный собор с острыми шпилями
			box(root, Vector3(2.2, 1.4, 2.0), Vector3(0, 0.7, 0), GRAVE)
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					cyl(root, 0.0, 0.22, 1.6, Vector3(float(sx) * 0.95, 2.1, float(sz) * 0.85), GRAVE.darkened(0.15), 4)
			cyl(root, 0.0, 0.5, 2.2, Vector3(0, 2.5, 0), GRAVE.darkened(0.1), 4)
			ball(root, 0.2, Vector3(0, 3.7, 0), GHOST, Vector3.ONE, true)
			box(root, Vector3(0.6, 1.0, 0.1), Vector3(0, 0.5, 1.0), Color("#14110f"))
			box(root, Vector3(0.18, 0.5, 0.05), Vector3(0, 1.1, 1.02), GHOST, Vector3.ZERO, true)
			box(root, Vector3(0.4, 0.8, 0.03), Vector3(0.75, 0.9, 1.01), team)
		_:                  # бойня: деревянный загон с крюками и чаном
			box(root, Vector3(2.4, 0.1, 2.2), Vector3(0, 0.05, 0), Color("#3a2a20"))
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					box(root, Vector3(0.14, 1.8, 0.14), Vector3(float(sx) * 1.0, 0.9, float(sz) * 0.9), DARKWOOD)
			roof(root, Vector3(2.3, 0.6, 2.1), Vector3(0, 2.0, 0), Color("#4a3a2e"))
			for i in 3:
				box(root, Vector3(0.03, 0.6, 0.03), Vector3(-0.5 + i * 0.5, 1.4, 0), IRON)
				cyl(root, 0.0, 0.06, 0.15, Vector3(-0.5 + i * 0.5, 1.05, 0), IRON, 4, Vector3(PI, 0, 0))
			cyl(root, 0.45, 0.4, 0.6, Vector3(0.5, 0.3, 0.5), IRON.darkened(0.2), 8)
			cyl(root, 0.4, 0.4, 0.05, Vector3(0.5, 0.58, 0.5), GHOST, 8, Vector3.ZERO, true)
			box(root, Vector3(0.5, 0.6, 0.03), Vector3(-0.5, 1.2, 0.92), team)


## Заброшенная шахта гоблинов: каменный холм, крепь у входа, рельсы, вагонетка с золотом.
## Флаг на шесте — цвета хозяина (серый, пока шахта ничья).
static func _goblin_mine(root: Node3D, team: Color) -> void:
	ball(root, 1.4, Vector3(0, 0.1, -0.35), STONE.darkened(0.15), Vector3(1.1, 0.75, 0.9))
	ball(root, 0.8, Vector3(-0.9, 0.0, 0.2), STONE.darkened(0.05), Vector3(1, 0.7, 1))
	ball(root, 0.7, Vector3(0.95, 0.0, 0.1), STONE.darkened(0.22), Vector3(1, 0.75, 1))
	box(root, Vector3(0.8, 0.85, 0.3), Vector3(0, 0.42, 0.75), Color("#14110f"))
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.14, 1.0, 0.14), Vector3(float(sx) * 0.48, 0.5, 0.85), DARKWOOD)
	box(root, Vector3(1.2, 0.14, 0.18), Vector3(0, 1.02, 0.85), DARKWOOD, Vector3(0, 0, 0.06))
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.05, 0.04, 1.4), Vector3(float(sx) * 0.22, 0.03, 1.5), IRON)
	for i in 4:
		box(root, Vector3(0.6, 0.04, 0.08), Vector3(0, 0.02, 1.0 + i * 0.32), DARKWOOD)
	box(root, Vector3(0.5, 0.3, 0.6), Vector3(0, 0.25, 1.7), IRON.darkened(0.2))
	for i in 4:
		ball(root, 0.1, Vector3(-0.12 + (i % 2) * 0.24, 0.45, 1.55 + (i / 2) * 0.25), GOLD)
	ball(root, 0.09, Vector3(0.5, 1.2, 0.95), Color("#9fff6a"), Vector3.ONE, true)
	box(root, Vector3(0.08, 2.0, 0.08), Vector3(-1.1, 1.0, 0.9), DARKWOOD)
	box(root, Vector3(0.6, 0.4, 0.03), Vector3(-0.78, 1.75, 0.9), team)


## Источник жизни: каменная чаша со светящейся водой.
static func _fountain(root: Node3D) -> void:
	cyl(root, 0.95, 1.05, 0.4, Vector3(0, 0.2, 0), STONE.lightened(0.1), 10)
	cyl(root, 0.8, 0.8, 0.42, Vector3(0, 0.22, 0), Color("#6ad8b0"), 10, Vector3.ZERO, true)
	cyl(root, 0.14, 0.2, 1.0, Vector3(0, 0.7, 0), STONE.lightened(0.15), 6)
	cyl(root, 0.42, 0.2, 0.15, Vector3(0, 1.22, 0), STONE.lightened(0.1), 8)
	ball(root, 0.2, Vector3(0, 1.45, 0), Color("#9fffd0"), Vector3.ONE, true)
	for i in 4:
		var a := float(i) * TAU / 4.0 + 0.4
		ball(root, 0.06, Vector3(sin(a) * 0.35, 1.0, cos(a) * 0.35), Color("#9fffd0"), Vector3(1, 2.0, 1), true)


## Сторожевая башня: каменное основание, деревянные опоры, площадка с крышей,
## сигнальная жаровня и знамя хозяина (серое, пока башня ничья).
static func _lookout(root: Node3D, team: Color) -> void:
	cyl(root, 1.05, 1.2, 0.7, Vector3(0, 0.35, 0), STONE.darkened(0.05), 8)
	for i in 6:
		var a := float(i) * TAU / 6.0
		ball(root, 0.22, Vector3(sin(a) * 1.15, 0.12, cos(a) * 1.15), STONE.darkened(0.2), Vector3(1, 0.7, 1))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			box(root, Vector3(0.16, 2.6, 0.16), Vector3(float(sx) * 0.62, 2.0, float(sz) * 0.62), DARKWOOD, Vector3(float(sz) * 0.05, 0, -float(sx) * 0.05))
	for y in [1.4, 2.3]:
		box(root, Vector3(1.4, 0.08, 0.08), Vector3(0, y, 0.62), WOOD, Vector3(0, 0, 0.5))
		box(root, Vector3(0.08, 0.08, 1.4), Vector3(0.62, y, 0), WOOD, Vector3(0.5, 0, 0))
	box(root, Vector3(1.8, 0.14, 1.8), Vector3(0, 3.3, 0), WOOD)
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.08, 0.5, 1.8), Vector3(float(sx) * 0.86, 3.6, 0), DARKWOOD)
		box(root, Vector3(1.8, 0.5, 0.08), Vector3(0, 3.6, float(sx) * 0.86), DARKWOOD)
	roof(root, Vector3(1.2, 0.9, 1.2), Vector3(0, 4.55, 0), Color("#5a3a2a"))
	cyl(root, 0.22, 0.14, 0.25, Vector3(0.45, 3.5, 0.45), IRON, 6)
	_fire(root, Vector3(0.45, 3.6, 0.45), 0.13)
	box(root, Vector3(0.06, 1.4, 0.06), Vector3(-0.7, 4.9, -0.7), DARKWOOD)
	box(root, Vector3(0.5, 0.35, 0.03), Vector3(-0.44, 5.35, -0.7), team)


## Лагерь наёмников: два шатра, костёр, стойка с оружием, знамя.
static func _merc_camp(root: Node3D, team: Color) -> void:
	var cloth := Color("#8a3a2a")
	for t in [[Vector3(-0.7, 0, -0.5), 0.75], [Vector3(0.75, 0, -0.35), 0.6]]:
		var p: Vector3 = t[0]
		var r: float = t[1]
		cyl(root, 0.05, r, r * 1.6, p + Vector3(0, r * 0.8, 0), cloth.darkened(0.1 * (1 if r < 0.7 else 0)), 6)
		roof(root, Vector3(r * 0.6, r * 0.7, 0.2), p + Vector3(0, r * 0.35, r * 0.75), Color("#14110f"))
	_fire(root, Vector3(0, 0, 0.6), 0.22)
	box(root, Vector3(0.9, 0.08, 0.08), Vector3(0.6, 0.75, 0.75), DARKWOOD)
	for i in 3:
		var x := 0.32 + i * 0.28
		box(root, Vector3(0.04, 0.9, 0.04), Vector3(x, 0.45, 0.78), WOOD, Vector3(0.15, 0, 0))
		box(root, Vector3(0.12, 0.25, 0.03), Vector3(x, 0.95, 0.8), STEEL)
	box(root, Vector3(0.08, 2.2, 0.08), Vector3(-1.2, 1.1, 0.6), DARKWOOD)
	box(root, Vector3(0.5, 0.7, 0.03), Vector3(-0.92, 1.8, 0.6), Color("#c9a23a"))
	ball(root, 0.12, Vector3(-1.2, 2.25, 0.6), GOLD)


## Деревьев на карте тысячи, а видов всего шесть. Каждый вид один раз сливается в одну сетку
## (детали + их цвета в вершинах), и дерево рисуется одним вызовом вместо пяти-шести.
static var _tree_meshes: Dictionary = {}
static var _vc_material: StandardMaterial3D


static func tree(seed_value: int) -> Node3D:
	var key := ("leaf%d" % (seed_value % 4)) if seed_value % 3 == 0 else ("pine%d" % (seed_value % 3))
	if not _tree_meshes.has(key):
		var parts := _tree_parts(seed_value)
		_tree_meshes[key] = bake(parts)
		parts.free()
	if _vc_material == null:
		_vc_material = StandardMaterial3D.new()
		_vc_material.vertex_color_use_as_albedo = true
		_vc_material.roughness = 1.0
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _tree_meshes[key]
	mi.material_override = _vc_material
	root.add_child(mi)
	root.scale = Vector3.ONE * (0.85 + float(seed_value % 5) * 0.09)
	root.rotation.y = float(seed_value % 7)
	return root


## Сливает все детали модели (простые фигуры) в одну сетку; цвет детали уходит в цвет вершин.
static func bake(parts: Node3D) -> ArrayMesh:
	var list: Array = []
	for child in parts.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh is PrimitiveMesh:
			list.append(child)
	return _bake_list(list)


## Можно ли деталь слить с соседями: простая фигура с обычным непрозрачным цветом без свечения.
static func _mergeable(mi: MeshInstance3D) -> bool:
	if not (mi.mesh is PrimitiveMesh) or mi.get_child_count() > 0 or not (mi.material_override is StandardMaterial3D):
		return false
	var m: StandardMaterial3D = mi.material_override
	return not m.emission_enabled and m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED


## Внутри каждого сустава модели неподвижные друг относительно друга детали сливаются в одну сетку:
## вызовов отрисовки становится в разы меньше, а анимация (повороты суставов) работает как прежде.
## keep — детали, которые игра прячет и показывает отдельно (их не трогаем).
static func merge(node: Node, keep: Array = []) -> void:
	var group: Array = []
	for c in node.get_children():
		if c is MeshInstance3D and not keep.has(c) and _mergeable(c):
			group.append(c)
	for c in node.get_children():
		if c is Node3D and not group.has(c):
			merge(c, keep)
	if group.size() < 2:
		return
	if _vc_material == null:
		_vc_material = StandardMaterial3D.new()
		_vc_material.vertex_color_use_as_albedo = true
		_vc_material.roughness = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = _bake_list(group)
	mi.material_override = _vc_material
	node.add_child(mi)
	for c in group:
		node.remove_child(c)
		c.free()


static func _bake_list(list: Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for child in list:
		var mi: MeshInstance3D = child
		var arrays: Array = (mi.mesh as PrimitiveMesh).get_mesh_arrays()
		var xf: Transform3D = mi.transform
		var color: Color = (mi.material_override as StandardMaterial3D).albedo_color if mi.material_override is StandardMaterial3D else Color.WHITE
		var base := verts.size()
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in v.size():
			verts.append(xf * v[i])
			normals.append((xf.basis * n[i]).normalized())
			colors.append(color)
		var idx = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			for i in idx:
				indices.append(base + int(i))
		else:
			for i in v.size():
				indices.append(base + i)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_COLOR] = colors
	out[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	return mesh


static func _tree_parts(seed_value: int) -> Node3D:
	var root := Node3D.new()
	if seed_value % 3 == 0:
		# лиственное дерево
		cyl(root, 0.1, 0.16, 0.9, Vector3(0, 0.45, 0), Color("#6a4a2e"), 5)
		var g := Color("#4f9a3f").lightened(float(seed_value % 4) * 0.05)
		ball(root, 0.62, Vector3(0, 1.3, 0), g, Vector3(1, 0.9, 1))
		ball(root, 0.42, Vector3(0.38, 1.05, 0.15), g.darkened(0.1))
		ball(root, 0.4, Vector3(-0.32, 1.12, -0.2), g.lightened(0.08))
		ball(root, 0.34, Vector3(0.05, 1.75, 0.05), g.lightened(0.12))
	else:
		# ель в три яруса
		cyl(root, 0.09, 0.14, 0.6, Vector3(0, 0.3, 0), Color("#5a4630"), 5)
		var g := Color("#2f6b3a").lightened(float(seed_value % 3) * 0.06)
		cyl(root, 0.0, 0.68, 0.9, Vector3(0, 0.85, 0), g, 6)
		cyl(root, 0.0, 0.52, 0.8, Vector3(0, 1.35, 0), g.lightened(0.07), 6, Vector3(0, 0.5, 0))
		cyl(root, 0.0, 0.36, 0.7, Vector3(0, 1.8, 0), g.lightened(0.14), 6)
	return root


static func gold_mine(size: float) -> Node3D:
	var root := Node3D.new()
	var k := size / 3.0
	var rock := Color("#7d766e")
	ball(root, 1.25, Vector3(0, 0, -0.15), rock, Vector3(1.1, 0.85, 1))
	ball(root, 0.85, Vector3(-0.75, 0.2, -0.5), rock.darkened(0.12), Vector3(1, 0.9, 1))
	ball(root, 0.75, Vector3(0.85, 0.1, -0.35), rock.lightened(0.07), Vector3(1, 0.85, 1))
	ball(root, 0.55, Vector3(0.15, 0.95, -0.4), rock.lightened(0.12))
	ball(root, 0.45, Vector3(-0.95, 0.05, 0.55), rock.darkened(0.05), Vector3(1, 0.7, 1))
	ball(root, 0.36, Vector3(1.05, 0.05, 0.6), rock, Vector3(1, 0.7, 1))
	# вход в шахту: деревянная рама и тёмный проём
	box(root, Vector3(0.78, 0.86, 0.5), Vector3(0, 0.43, 0.82), Color("#14110f"))
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.15, 0.95, 0.16), Vector3(float(sx) * 0.46, 0.47, 1.06), WOOD)
	box(root, Vector3(1.15, 0.15, 0.18), Vector3(0, 1.0, 1.06), DARKWOOD)
	box(root, Vector3(0.9, 0.1, 0.14), Vector3(0, 1.14, 1.0), WOOD.lightened(0.08), Vector3(0, 0, 0.06))
	# рельсы и вагонетка с золотом
	for sx in [-1.0, 1.0]:
		box(root, Vector3(0.04, 0.04, 0.9), Vector3(float(sx) * 0.17, 0.05, 1.3), IRON)
	for i in 4:
		box(root, Vector3(0.5, 0.03, 0.07), Vector3(0, 0.03, 0.95 + i * 0.22), DARKWOOD)
	box(root, Vector3(0.4, 0.24, 0.52), Vector3(0, 0.28, 1.42), DARKWOOD)
	box(root, Vector3(0.44, 0.04, 0.56), Vector3(0, 0.4, 1.42), IRON)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			cyl(root, 0.08, 0.08, 0.04, Vector3(float(sx) * 0.2, 0.1, 1.42 + float(sz) * 0.16), IRON, 8, Vector3(0, 0, PI / 2))
	for i in 5:
		ball(root, 0.09, Vector3(-0.1 + (i % 3) * 0.1, 0.44 + 0.05 * (i % 2), 1.3 + (i % 4) * 0.08), GOLD, Vector3.ONE, true)
	# самородки и кристаллы на камнях
	var spots := [Vector3(-0.8, 0.95, 0.0), Vector3(0.9, 0.72, 0.1), Vector3(0.3, 1.42, -0.3), Vector3(-0.3, 0.98, 0.5), Vector3(1.2, 0.25, 0.75), Vector3(-1.2, 0.3, 0.7)]
	for i in spots.size():
		ball(root, 0.13, spots[i], GOLD, Vector3(1.2, 0.8, 1))
		cyl(root, 0.0, 0.07, 0.3, spots[i] + Vector3(0.1, 0.14, 0.02), GOLD.lightened(0.2), 4, Vector3(0.2, 0, -0.3 + 0.2 * i), true)
	# фонарь
	box(root, Vector3(0.06, 1.3, 0.06), Vector3(0.75, 0.65, 1.2), DARKWOOD)
	box(root, Vector3(0.3, 0.05, 0.05), Vector3(0.62, 1.28, 1.2), DARKWOOD)
	box(root, Vector3(0.12, 0.16, 0.12), Vector3(0.5, 1.16, 1.2), Color("#ffd94a"), Vector3.ZERO, true)
	root.scale = Vector3.ONE * k
	return root
