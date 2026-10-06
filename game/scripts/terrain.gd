extends RefCounted
## Ландшафт карты: высоты, вода, плато с водопадом и украшения.
## Правилам игры (sim.gd) отсюда нужно только одно: какие клетки непроходимы.

var SIZE := 96                  # сторона карты в клетках: 96, 192 или 272
const MARGIN := 14.0            # полоса земли за краем карты, чтобы не было пустоты
var STEP := 0.75                # размер одного «полигона» земли (на больших картах крупнее)
const WATER_Y := -0.3
const PLATEAU_H := 4.5
var CENTER := Vector2(48, 48)
var K := 1.0                    # во сколько раз сторона карты больше маленькой
var AREA := 1.0                 # во сколько раз больше площадь

var seed_value := 0
var noise := FastNoiseLite.new()
var tint := FastNoiseLite.new()
var bases: Array = []           # где стоят базы игроков
var plateau_corner := Vector2(96, 0)
var plateau_r := 23.0
var fall_dir := Vector2(-1, 1)  # куда падает водопад
var lakes: Array = []           # [центр, радиус]
var rivers: Array = []          # [точки, половина ширины]
var fords: Array = []           # броды: мелкие места, где реку можно перейти
var high_river: Array = []      # ручей на плато, который срывается водопадом
var high_w := 1.1
var props: Array = []           # кусты и камни: настоящие препятствия, юниты их обходят
var prop_cells: Dictionary = {}
## Местности: цвета земли, вода, кусты и камни, лес, погода. Выбираются перед игрой или случайно.
const BIOMES := {
	"meadow": {"name": "Луга", "grass": ["#34472c", "#566a3a"], "dry": "#77703f", "mud": "#4a3d2c", "sand": "#7d7256",
		"lakes": 1.0, "props": 1.0, "rocks": 0.38, "forest": 1.0, "bush": ["#2f6b3a", "#4f8f3a"], "water": "#21404a", "fog": "#6f777c", "foliage": "", "weather": ""},
	"steppe": {"name": "Степь", "grass": ["#6a6a34", "#8c8046"], "dry": "#a68e4c", "mud": "#6a5434", "sand": "#9a8a5a",
		"lakes": 0.35, "props": 0.7, "rocks": 0.62, "forest": 0.4, "bush": ["#6a6a34", "#8a7a3a"], "water": "#2a4a4a", "fog": "#8c8670", "foliage": "steppe", "weather": "dust"},
	"autumn": {"name": "Осень", "grass": ["#5a4a2a", "#7a5c2c"], "dry": "#9c6a2a", "mud": "#4a3424", "sand": "#7d6a4a",
		"lakes": 1.0, "props": 1.0, "rocks": 0.35, "forest": 1.15, "bush": ["#8a4a22", "#b8782a"], "water": "#24383e", "fog": "#7a6c5c", "foliage": "autumn", "weather": "leaves"},
	"winter": {"name": "Зима", "grass": ["#c4ccd4", "#e6ecf2"], "dry": "#b2bcc6", "mud": "#8c939c", "sand": "#a8b0b8",
		"lakes": 0.9, "props": 0.8, "rocks": 0.5, "forest": 1.0, "bush": ["#9aaab4", "#c8d4dc"], "water": "#6a8a9a", "fog": "#a6b2be", "foliage": "winter", "weather": "snow"},
	"lakes": {"name": "Озёрный край", "grass": ["#2e4a32", "#4e7044"], "dry": "#6a7444", "mud": "#3a3d2c", "sand": "#7d7256",
		"lakes": 3.0, "lakes_add": 3, "props": 0.9, "rocks": 0.3, "forest": 0.9, "bush": ["#2f6b3a", "#4f8f3a"], "water": "#1c3a48", "fog": "#6a7a82", "foliage": "", "weather": ""},
	"highlands": {"name": "Нагорье", "grass": ["#4a4a38", "#6a684a"], "dry": "#7a7454", "mud": "#4a4438", "sand": "#7a7462",
		"lakes": 0.6, "props": 2.3, "rocks": 0.85, "forest": 0.7, "bush": ["#3f5a3a", "#5a7044"], "water": "#24404a", "fog": "#7c7e80", "foliage": "steppe", "weather": ""},
}
var biome := "meadow"
var B: Dictionary = BIOMES["meadow"]


static func biome_for(key: String, map_seed: int) -> String:
	if BIOMES.has(key):
		return key
	var keys: Array = BIOMES.keys()      # «любая»: выбирает зерно карты
	return String(keys[absi(hash(map_seed * 7 + 3)) % keys.size()])


var _soft: Dictionary = {}      # клетка -> трава и цветы в ней (они приминаются под юнитами)
var _soft_all: Array = []
var _flat: Dictionary = {}
var _hidden: Dictionary = {}


## Вся карта определяется одним числом (зерном). Одинаковое зерно = одинаковая карта,
## это понадобится для сетевой игры: игрокам достаточно обменяться зерном.
func _init(map_seed: int = 0, map_size: int = 96, n_players: int = 2, biome_key: String = "meadow") -> void:
	seed_value = map_seed
	biome = biome_for(biome_key, map_seed)
	B = BIOMES[biome]
	SIZE = map_size
	CENTER = Vector2(SIZE, SIZE) * 0.5
	K = float(SIZE) / 96.0
	AREA = K * K
	STEP = 0.75 * sqrt(K)
	vol_out = 12.0 * sqrt(K)
	vol_rim = 7.0 * sqrt(K)
	vol_in = 4.8 * sqrt(K)
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed
	noise.seed = map_seed
	noise.frequency = rng.randf_range(0.035, 0.055)
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	tint.seed = map_seed + 99
	tint.frequency = 0.09

	if n_players <= 2:
		# базы в противоположных углах; плато и второе озеро — в двух оставшихся
		var corners := [Vector2(0, 0), Vector2(SIZE, SIZE), Vector2(SIZE, 0), Vector2(0, SIZE)]
		var base_corners: Array = corners.slice(0, 2)
		var free_corners: Array = corners.slice(2, 4)
		if rng.randf() < 0.5:
			base_corners = corners.slice(2, 4)
			free_corners = corners.slice(0, 2)
		if rng.randf() < 0.5:
			base_corners.reverse()
		if rng.randf() < 0.5:
			free_corners.reverse()
		for c in base_corners:
			bases.append(c + (CENTER - c).normalized() * (25.5 + 6.0 * (K - 1.0)))

		# плато с водопадом
		plateau_corner = free_corners[0]
		plateau_r = rng.randf_range(20.0, 25.0) * sqrt(K)
		fall_dir = (CENTER - plateau_corner).normalized()
		var side := Vector2(fall_dir.y, -fall_dir.x)
		var lake_r := rng.randf_range(4.8, 6.0)
		var lake_c := plateau_corner + fall_dir * (plateau_r + 2.0 + lake_r)
		lakes.append([lake_c, lake_r])
		high_river = [
			plateau_corner - fall_dir * 22.0,
			plateau_corner + fall_dir * 6.0 + side * rng.randf_range(-5, 5),
			plateau_corner + fall_dir * (plateau_r * 0.6) + side * rng.randf_range(-3.5, 3.5),
			plateau_corner + fall_dir * (plateau_r - 3.0),
			plateau_corner + fall_dir * (plateau_r + 2.5),
		]
		_add_river(rng, lake_c, plateau_corner, rng.randf_range(36, 50) * K, 1.5)

		# второе озеро с ручьём в противоположном свободном углу
		var c2: Vector2 = free_corners[1]
		var dir2 := (CENTER - c2).normalized()
		var lake2 := c2 + dir2 * rng.randf_range(21, 28) * K + Vector2(dir2.y, -dir2.x) * rng.randf_range(-6, 6)
		lakes.append([lake2, rng.randf_range(5.0, 7.5)])
		_add_river(rng, lake2, c2, rng.randf_range(10, 30) * K, 1.3)
	else:
		# 3–8 игроков: базы по кругу, между соседними базами — озёра; плато нет
		plateau_corner = Vector2(-9999, -9999)
		plateau_r = 0.0
		var start_a := rng.randf() * TAU
		var ring := SIZE * 0.5 * 0.72
		for i in n_players:
			bases.append(CENTER + Vector2(ring, 0).rotated(start_a + TAU * i / n_players))
		for i in n_players:
			var mid := start_a + TAU * (i + 0.5) / n_players
			lakes.append([CENTER + Vector2(ring * rng.randf_range(0.78, 0.95), 0).rotated(mid), rng.randf_range(3.0, 4.6) * sqrt(K)])
	for b in bases:      # к кратеру вулкана ведёт проход со стороны каждой базы
		ramps.append(((b as Vector2) - CENTER).angle())
	while ramps.size() < 4:
		ramps.append(float(ramps[ramps.size() - 1]) + PI / 2.0)

	_make_zones(rng)
	_make_mesas(rng)

	# иногда ещё один-два маленьких пруда
	var ponds := int(round(float(rng.randi_range(0, 2) + int((AREA - 1.0) * 1.6)) * float(B["lakes"]))) + int(float(B.get("lakes_add", 0)) * sqrt(AREA))
	for i in ponds:     # на больших картах и в озёрном краю больше озёр
		for attempt in 30:
			var p := Vector2(rng.randf_range(14, SIZE - 14), rng.randf_range(14, SIZE - 14))
			var ok := p.distance_to(CENTER) > vol_out + 8.0 and p.distance_to(plateau_corner) > plateau_r + 9.0
			for b in bases:
				ok = ok and p.distance_to(b) > 27.0
			for l in lakes:
				ok = ok and p.distance_to(l[0]) > float(l[1]) + 13.0
			for r in rivers:
				ok = ok and _line_dist(p, r[0]) > 9.0
			for ms in mesas:
				ok = ok and p.distance_to(ms["c"]) > float(ms["r"]) + 10.0
			if ok:
				lakes.append([p, rng.randf_range(2.6, 4.2) * (1.0 if K < 1.5 else rng.randf_range(1.0, 1.8))])
				break
	_make_props(rng)


# ---------- вулкан в центре карты: кратер с лавой, проходы со стороны каждой базы ----------

var vol_out := 12.0             # подножие
var vol_rim := 7.0              # гребень
var vol_in := 4.8               # дно кратера (здесь живёт дракон)
var ramps: Array = []           # углы проходов к кратеру
const VOL_H := 5.5
const RAMP_HALF := 2.4          # полуширина прохода в клетках


func in_ramp(p: Vector2) -> bool:
	var d := p - CENTER
	for a in ramps:
		var dir := Vector2.RIGHT.rotated(float(a))
		if d.dot(dir) > 0.0 and absf(d.dot(Vector2(-dir.y, dir.x))) < RAMP_HALF:
			return true
	return false


## Добавка высоты от вулкана: дно кратера, гребень, склоны (в проходах склоны ниже).
func volcano(p: Vector2) -> float:
	var r := p.distance_to(CENTER)
	if r >= vol_out:
		return 0.0
	var h: float
	if r <= vol_in:
		h = 0.9
	elif r <= vol_rim:
		h = lerpf(0.9, VOL_H, smoothstep(vol_in, vol_rim, r))
	else:
		h = VOL_H * (1.0 - smoothstep(vol_rim, vol_out, r))
	if in_ramp(p):
		h = minf(h, 0.9 + 0.4 * (1.0 - smoothstep(vol_in, vol_out, r)))
	return h


## Крутые склоны вулкана непроходимы; кратер и проходы — проходимы.
func volcano_wall(p: Vector2) -> bool:
	var r := p.distance_to(CENTER)
	return r > vol_in + 0.6 and r < vol_out - 1.6 and not in_ramp(p)


## Как далеко точка за краем карты (отрицательно — внутри). За краем — стена скал.
func outside(p: Vector2) -> float:
	return maxf(maxf(-p.x, p.x - SIZE), maxf(-p.y, p.y - SIZE))


# ---------- зоны местностей: на одной карте несколько биомов ----------
## Основная местность — фон; поверх неё 2–4 «пятна» других (снежное нагорье, осенний лес, степь…)
## с неровной мягкой границей. В зоне свои цвета земли и травы, кусты, листва и густота леса.

var zones: Array = []           # {c: центр, r: радиус, key: местность}
var _edge := FastNoiseLite.new()


func _make_zones(rng: RandomNumberGenerator) -> void:
	_edge.seed = seed_value + 313
	_edge.frequency = 0.06
	var pool: Array = []
	for k in BIOMES:
		if k != biome and k != "lakes":
			pool.append(k)
	var n := 2 + (1 if K > 1.5 else 0) + (1 if K > 2.5 else 0)
	for i in n:
		var key := String(pool[rng.randi() % pool.size()])
		pool.erase(key)      # зоны разные
		if pool.is_empty():
			pool = [key]
		var r := SIZE * rng.randf_range(0.17, 0.26)
		for attempt in 40:
			var c := Vector2(rng.randf_range(SIZE * 0.12, SIZE * 0.88), rng.randf_range(SIZE * 0.12, SIZE * 0.88))
			var ok := true
			for z in zones:
				ok = ok and c.distance_to(z["c"]) > (float(z["r"]) + r) * 0.75
			if ok:
				zones.append({"c": c, "r": r, "key": key})
				break


## Самая сильная зона в точке: [местность, сила 0…1] (сила 0 — основная местность карты).
func zone_at(p: Vector2) -> Array:
	var best := ""
	var bt := 0.0
	var wobble := _edge.get_noise_2d(p.x, p.y) * 7.0 * sqrt(K)
	for z in zones:
		var t := 1.0 - smoothstep(float(z["r"]) - 5.0, float(z["r"]) + 5.0, p.distance_to(z["c"]) + wobble)
		if t > bt:
			bt = t
			best = String(z["key"])
	return [best, bt]


## Свойство местности в точке, смешанное между основной и зоной (цвета).
func pal(p: Vector2, field: String, idx := -1) -> Color:
	var base_v = B[field]
	var base_c := Color(String(base_v[idx] if idx >= 0 else base_v))
	var z := zone_at(p)
	if float(z[1]) <= 0.001:
		return base_c
	var zv = BIOMES[z[0]][field]
	return base_c.lerp(Color(String(zv[idx] if idx >= 0 else zv)), float(z[1]))


## Число-свойство местности в точке (густота леса, доля камней…).
func num(p: Vector2, field: String) -> float:
	var z := zone_at(p)
	var a := float(B.get(field, 1.0))
	return a if float(z[1]) <= 0.001 else lerpf(a, float(BIOMES[z[0]].get(field, 1.0)), float(z[1]))


## Окраска листвы деревьев в точке ("", autumn, winter, steppe).
func foliage_at(p: Vector2) -> String:
	var z := zone_at(p)
	return String(BIOMES[z[0]]["foliage"]) if float(z[1]) > 0.5 else String(B["foliage"])


# ---------- возвышенности: плоские холмы с обрывами и пологими подъёмами ----------
## На вершину ведут 1–2 подъёма, обрывы непроходимы. Стрелки наверху бьют дальше,
## а с вершины видно дальше (см. sim.high_cells и fog).

var mesas: Array = []           # {c, r, h, ph: фаза неровного края, ramps: [углы]}
const MESA_RAMP := 2.3          # полуширина подъёма в клетках


func _make_mesas(rng: RandomNumberGenerator) -> void:
	var n := int(round(2.0 + 2.2 * (AREA - 1.0) / 3.0 + rng.randf()))      # 2–3 на маленькой карте, до 7–8 на огромной
	for i in n:
		for attempt in 60:
			var r := rng.randf_range(4.5, 8.0) * pow(K, 0.3)
			var c := Vector2(rng.randf_range(r + 6, SIZE - r - 6), rng.randf_range(r + 6, SIZE - r - 6))
			var ok := c.distance_to(CENTER) > vol_out + r + 7.0 and c.distance_to(plateau_corner) > plateau_r + r + 7.0
			for b in bases:
				ok = ok and c.distance_to(b) > r + 17.0
			for l in lakes:
				ok = ok and c.distance_to(l[0]) > float(l[1]) + r + 6.0
			for rv in rivers:
				ok = ok and _line_dist(c, rv[0]) > float(rv[1]) + r + 5.0
			for f in fords:
				ok = ok and c.distance_to(f) > r + 7.0
			for m in mesas:
				ok = ok and c.distance_to(m["c"]) > float(m["r"]) + r + 9.0
			if not ok:
				continue
			var a0 := rng.randf() * TAU
			var ramps_m: Array = [a0]
			if rng.randf() < 0.75 or r > 6.5:      # у больших — два подъёма с разных сторон
				ramps_m.append(a0 + PI + rng.randf_range(-0.6, 0.6))
			mesas.append({"c": c, "r": r, "h": rng.randf_range(2.4, 3.2), "ph": rng.randf() * TAU, "ramps": ramps_m})
			break


## Край возвышенности неровный: радиус зависит от направления.
func _mesa_edge(m: Dictionary, p: Vector2) -> float:
	var a := (p - (m["c"] as Vector2)).angle()
	return float(m["r"]) * (1.0 + 0.13 * sin(3.0 * a + float(m["ph"])) + 0.07 * sin(5.0 * a - float(m["ph"]) * 1.7))


func _mesa_ramp(m: Dictionary, p: Vector2) -> bool:
	var d := p - (m["c"] as Vector2)
	for a in m["ramps"]:
		var dir := Vector2.RIGHT.rotated(float(a))
		if d.dot(dir) > 0.0 and absf(d.dot(Vector2(-dir.y, dir.x))) < MESA_RAMP:
			return true
	return false


## Добавка высоты от возвышенностей (на подъёмах — пологий скат).
func mesa(p: Vector2) -> float:
	var h := 0.0
	for m in mesas:
		var d: float = p.distance_to(m["c"])
		if d > float(m["r"]) * 1.25 + 5.0:
			continue
		var e := _mesa_edge(m, p)
		var top := float(m["h"])
		var v: float = top * (1.0 - smoothstep(e - 0.45, e + 0.55, d))      # крутой обрыв
		if _mesa_ramp(m, p):
			v = maxf(v, top * (1.0 - smoothstep(e - 1.2, e + 4.5, d)))
		h = maxf(h, v)
	return h


## Точки у подножия и у верха каждого подъёма (здесь не сажать лес и не класть камни).
func ramp_spots() -> Array:
	var out: Array = []
	for m in mesas:
		for a in m["ramps"]:
			var dir := Vector2.RIGHT.rotated(float(a))
			for k in [-1.5, 1.0, 3.5]:
				out.append((m["c"] as Vector2) + dir * (float(m["r"]) + k))
	return out


## Полоса обрыва для раскраски: весь склон — камень (иначе край выходит «пилой»).
func _mesa_band(p: Vector2) -> bool:
	for m in mesas:
		var d: float = p.distance_to(m["c"])
		if d > float(m["r"]) * 1.25 + 2.0:
			continue
		var e := _mesa_edge(m, p)
		if d > e - 0.7 and d < e + 0.8 and not _mesa_ramp(m, p):
			return true
	return false


## Обрыв возвышенности: непроходим (подъёмы — проходимы).
func mesa_wall(p: Vector2) -> bool:
	for m in mesas:
		var d: float = p.distance_to(m["c"])
		if d > float(m["r"]) * 1.25 + 2.0:
			continue
		var e := _mesa_edge(m, p)
		if d > e - 0.75 and d < e + 0.85 and not _mesa_ramp(m, p):
			return true
	return false


## Клетка на вершине возвышенности (там стрелки бьют дальше и обзор больше).
func high_ground(cell: Vector2i) -> bool:
	var p := Vector2(cell) + Vector2(0.5, 0.5)
	for m in mesas:
		if p.distance_to(m["c"]) < _mesa_edge(m, p) - 0.75:
			return true
	return false


var _ramp_cache: Array = []


func _make_props(rng: RandomNumberGenerator) -> void:
	_ramp_cache = ramp_spots()
	for i in int(520 * AREA * 2.3):      # попыток с запасом; густоту решает местность в точке (num(p, "props"))
		var cell := Vector2i(rng.randi_range(1, SIZE - 2), rng.randi_range(1, SIZE - 2))
		var p := Vector2(cell) + Vector2(0.5, 0.5)
		var ok := _grass(p) and plateau(p) < 0.02 and not prop_cells.has(cell) and p.distance_to(CENTER) > vol_out + 2.0 and not mesa_wall(p)
		if ok and rng.randf() > num(p, "props") / 2.3:      # в нагорье камней и кустов больше, в степи меньше
			continue
		for rs in _ramp_cache:
			ok = ok and p.distance_to(rs) > 3.0
		ok = ok and p.distance_to(plateau_corner + fall_dir * (plateau_r + 3.0)) > 6.0
		for b in bases:
			ok = ok and p.distance_to(b) > 13.0
		for f in fords:
			ok = ok and p.distance_to(f) > 6.0
		if not ok:
			continue
		prop_cells[cell] = true
		var s := rng.randf_range(0.55, 0.95)
		if rng.randf() >= num(p, "rocks"):
			props.append({"kind": "bush", "pos": p, "scale": Vector3(s, s * 0.8, s), "rot": rng.randf() * 6.0,
				"color": pal(p, "bush", 0).lerp(pal(p, "bush", 1), rng.randf())})
		else:
			props.append({"kind": "rock", "pos": p, "scale": Vector3(s, s * 0.65, s * rng.randf_range(0.75, 1.1)), "rot": rng.randf() * 6.0,
				"color": Color("#8d867a").lerp(Color("#a59f92"), rng.randf())})
	_make_ruins(rng)


## Руины древних (каменные круги и обломки стен) и мёртвые деревья — тоже препятствия.
func _make_ruins(rng: RandomNumberGenerator) -> void:
	var n := int(round(2.0 + 1.6 * AREA))
	for i in n:
		for attempt in 40:
			var c := Vector2(rng.randf_range(10, SIZE - 10), rng.randf_range(10, SIZE - 10))
			var ok := _grass(c) and c.distance_to(CENTER) > vol_out + 6.0 and plateau(c) < 0.02 and mesa(c) < 0.1
			for b in bases:
				ok = ok and c.distance_to(b) > 22.0
			for f in fords:
				ok = ok and c.distance_to(f) > 8.0
			for m in mesas:
				ok = ok and c.distance_to(m["c"]) > float(m["r"]) + 6.0
			if not ok:
				continue
			var mossy := Color("#7d8a6a")
			var stone := Color("#9a958a").lerp(Color("#b2ab9c"), rng.randf())
			if rng.randf() < 0.55:      # каменный круг
				var k := rng.randi_range(5, 8)
				var rr := rng.randf_range(2.6, 3.6)
				for j in k:
					if rng.randf() < 0.18:
						continue      # выпавший камень
					var p := c + Vector2(rr, 0).rotated(TAU * j / k)
					_add_pillar(p, stone.lerp(mossy, rng.randf() * 0.5), rng.randf_range(0.9, 2.0), rng)
			else:      # обломок стены с колоннами
				var dir := Vector2.RIGHT.rotated(rng.randf() * TAU)
				for j in rng.randi_range(4, 7):
					var p := c + dir * (float(j) - 3.0) * 1.0
					_add_pillar(p, stone.lerp(mossy, rng.randf() * 0.4), (rng.randf_range(0.5, 1.0) if j % 3 != 0 else rng.randf_range(1.5, 2.4)), rng)
			break
	# мёртвые деревья: там, где сухо (степь, нагорье)
	for i in int(70 * AREA):
		var p := Vector2(rng.randf_range(4, SIZE - 4), rng.randf_range(4, SIZE - 4))
		var z := zone_at(p)
		var dry := float(z[1]) if String(z[0]) in ["steppe", "highlands"] else 0.0
		if biome in ["steppe", "highlands"]:
			dry = maxf(dry, 1.0 - float(z[1]))
		if rng.randf() > dry * 0.7:
			continue
		var cell := Vector2i(p)
		var q := Vector2(cell) + Vector2(0.5, 0.5)
		var ok := _grass(q) and not prop_cells.has(cell) and q.distance_to(CENTER) > vol_out + 2.0 and not mesa_wall(q) and plateau(q) < 0.02
		for rs in _ramp_cache:
			ok = ok and q.distance_to(rs) > 3.0
		for b in bases:
			ok = ok and q.distance_to(b) > 13.0
		for f in fords:
			ok = ok and q.distance_to(f) > 6.0
		if ok:
			prop_cells[cell] = true
			props.append({"kind": "deadtree", "pos": q, "scale": Vector3.ONE * rng.randf_range(0.8, 1.25), "rot": rng.randf() * 6.0, "color": Color("#6a5a48").lerp(Color("#8a7a66"), rng.randf())})


func _add_pillar(p: Vector2, color: Color, tall: float, rng: RandomNumberGenerator) -> void:
	var cell := Vector2i(p)
	var q := Vector2(cell) + Vector2(0.5, 0.5)
	if prop_cells.has(cell) or not _grass(q) or mesa_wall(q):
		return
	prop_cells[cell] = true
	props.append({"kind": "pillar", "pos": q, "scale": Vector3(rng.randf_range(0.55, 0.75), tall, rng.randf_range(0.55, 0.75)), "rot": rng.randf_range(-0.3, 0.3), "color": color})


## Река от озера к краю карты. corner — угол, рядом с которым она течёт;
## along — как далеко от этого угла вдоль края она уходит с карты.
func _add_river(rng: RandomNumberGenerator, from: Vector2, corner: Vector2, along: float, half_w: float) -> void:
	var ex := Vector2(1.0 if corner.x < 1.0 else -1.0, 0)
	var ey := Vector2(0, 1.0 if corner.y < 1.0 else -1.0)
	var exit := corner + ex * along
	var out := -ey
	if rng.randf() < 0.5:
		exit = corner + ey * along
		out = -ex
	var perp := (exit - from).normalized().rotated(PI / 2)
	var pts: Array = [from]
	for k in [0.33, 0.66]:
		pts.append(from.lerp(exit, k) + perp * rng.randf_range(-5.0, 5.0))
	pts.append(exit)
	pts.append(exit + out * 18.0)
	rivers.append([pts, half_w])
	fords.append(((pts[1] as Vector2) + (pts[2] as Vector2)) * 0.5)


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _line_dist(p: Vector2, pts: Array) -> float:
	var d := INF
	for i in pts.size() - 1:
		d = minf(d, _seg_dist(p, pts[i], pts[i + 1]))
	return d


## 1 на плато, 0 внизу, между ними — обрыв.
func plateau(p: Vector2) -> float:
	return 1.0 - smoothstep(plateau_r - 1.5, plateau_r + 1.5, p.distance_to(plateau_corner))


## Расстояние до ближайшей воды (отрицательное — внутри воды).
func water_dist(p: Vector2) -> float:
	var d := INF
	for l in lakes:
		d = minf(d, p.distance_to(l[0]) - float(l[1]))
	for r in rivers:
		d = minf(d, _line_dist(p, r[0]) - float(r[1]))
	if p.distance_to(plateau_corner) < plateau_r + 4.0:
		d = minf(d, _line_dist(p, high_river) - high_w)
	return d


## 1 в середине брода, 0 вдали от него.
func ford(p: Vector2) -> float:
	var d := INF
	for f in fords:
		d = minf(d, p.distance_to(f))
	return 1.0 - smoothstep(1.8, 3.4, d)


func height(p: Vector2) -> float:
	var z := zone_at(p)
	var rough := 1.0 + (0.9 * float(z[1]) if String(z[0]) == "highlands" else 0.0) + (0.9 if biome == "highlands" and float(z[1]) < 0.5 else 0.0)      # в нагорье холмы выше
	var hills := (noise.get_noise_2d(p.x, p.y) * 0.5 + 0.5) * 1.5 * rough
	var near_base := INF
	for b in bases:
		near_base = minf(near_base, p.distance_to(b))
	var h := lerpf(0.35, hills, smoothstep(9.0, 24.0, near_base))
	var level := PLATEAU_H * plateau(p)
	h += level + volcano(p) + mesa(p)
	var o := outside(p)
	if o > -1.0:      # за краем карты поднимается стена огромных скал
		h += 10.0 * smoothstep(-1.0, 6.0, o) + (noise.get_noise_2d(p.x * 3.1, p.y * 3.1) * 0.5 + 0.5) * 2.2 * smoothstep(0.0, 4.0, o)
	var carve := 1.0 - smoothstep(0.0, 1.8, water_dist(p))
	return lerpf(h, level - lerpf(1.0, 0.45, ford(p)), carve)


var _hs := PackedFloat32Array()
var _hn := 0


## Высота земли в точке по таблице, на тех же треугольниках, что нарисованы. Это в десятки раз
## быстрее height() (там шум, озёра, реки) — а её зовут для каждого юнита каждый кадр.
func h_at(p: Vector2) -> float:
	if _hs.is_empty():
		return height(p)
	var fx := (p.x + MARGIN) / STEP
	var fz := (p.y + MARGIN) / STEP
	var i := clampi(floori(fx), 0, _hn - 1)
	var j := clampi(floori(fz), 0, _hn - 1)
	var u := clampf(fx - i, 0.0, 1.0)
	var v := clampf(fz - j, 0.0, 1.0)
	var w := _hn + 1
	var ha := _hs[j * w + i]
	var hb := _hs[j * w + i + 1]
	var hc := _hs[(j + 1) * w + i]
	var hd := _hs[(j + 1) * w + i + 1]
	if u + v <= 1.0:
		return ha + (hb - ha) * u + (hc - ha) * v
	return hd + (hc - hd) * (1.0 - u) + (hb - hd) * (1.0 - v)


func water_level(p: Vector2) -> float:
	return PLATEAU_H * plateau(p) + WATER_Y


## Клетка непроходима только из-за воды (а не скал, плато или вулкана) — по ней плавают наги.
func swimmable(cell: Vector2i) -> bool:
	var p := Vector2(cell) + Vector2(0.5, 0.5)
	return water_dist(p) < 0.7 and ford(p) < 0.5 and plateau(p) <= 0.06 and not prop_cells.has(cell) and not volcano_wall(p)


func blocked(cell: Vector2i) -> bool:
	var p := Vector2(cell) + Vector2(0.5, 0.5)
	return (water_dist(p) < 0.7 and ford(p) < 0.5) or plateau(p) > 0.06 or prop_cells.has(cell) or volcano_wall(p) or mesa_wall(p)


# ---------- картинка ----------

func build(parent: Node3D, Models, occupied: Callable) -> void:
	parent.add_child(_ground_mesh())
	_water(parent)
	if plateau_r > 0.0:
		_waterfall(parent, Models)
	_volcano_fx(parent)
	_decor(parent, occupied)


## Лава в кратере, оранжевый свет и дым над вулканом.
func _volcano_fx(parent: Node3D) -> void:
	var lava := StandardMaterial3D.new()
	lava.albedo_color = Color("#d8380c")
	lava.emission_enabled = true
	lava.emission = Color("#ff3a08")
	lava.emission_energy_multiplier = 1.3
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 777
	for i in 7:      # озерца лавы по краю дна кратера
		var a := float(i) * TAU / 7.0 + rng.randf() * 0.4
		var c := CENTER + Vector2(vol_in * rng.randf_range(0.55, 0.85), 0).rotated(a)
		var disc := MeshInstance3D.new()
		var m := CylinderMesh.new()
		m.top_radius = rng.randf_range(0.7, 1.3) * sqrt(K)
		m.bottom_radius = m.top_radius
		m.height = 0.05
		m.radial_segments = 9
		disc.mesh = m
		disc.material_override = lava
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		disc.position = Vector3(c.x, height(c) + 0.06, c.y)
		parent.add_child(disc)
	var light := OmniLight3D.new()
	light.light_color = Color("#ff6a2a")
	light.light_energy = 2.5
	light.omni_range = vol_out * 1.2
	light.position = Vector3(CENTER.x, height(CENTER) + 3.0, CENTER.y)
	parent.add_child(light)
	var smoke := CPUParticles3D.new()
	smoke.amount = 40
	smoke.lifetime = 7.0
	smoke.position = Vector3(CENTER.x, VOL_H + 1.0, CENTER.y)
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	smoke.emission_sphere_radius = vol_in
	smoke.direction = Vector3.UP
	smoke.spread = 15.0
	smoke.gravity = Vector3(0.3, 0.6, 0.0)
	smoke.initial_velocity_min = 0.6
	smoke.initial_velocity_max = 1.4
	smoke.scale_amount_min = 1.2
	smoke.scale_amount_max = 2.6
	var puff := SphereMesh.new()
	puff.radius = 0.5
	puff.height = 1.0
	puff.radial_segments = 6
	puff.rings = 3
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.25, 0.23, 0.22, 0.35)
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff.material = sm
	smoke.mesh = puff
	parent.add_child(smoke)


func _ground_mesh() -> MeshInstance3D:
	var n := int((SIZE + MARGIN * 2.0) / STEP)
	var hs := PackedFloat32Array()
	hs.resize((n + 1) * (n + 1))
	for j in n + 1:
		for i in n + 1:
			hs[j * (n + 1) + i] = height(Vector2(i * STEP - MARGIN, j * STEP - MARGIN))
	_hs = hs      # дальше высота точки берётся из этой таблицы (h_at) — быстро и ровно по нарисованной земле
	_hn = n
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for j in n:
		for i in n:
			var x := i * STEP - MARGIN
			var z := j * STEP - MARGIN
			var a := Vector3(x, hs[j * (n + 1) + i], z)
			var b := Vector3(x + STEP, hs[j * (n + 1) + i + 1], z)
			var c := Vector3(x, hs[(j + 1) * (n + 1) + i], z + STEP)
			var d := Vector3(x + STEP, hs[(j + 1) * (n + 1) + i + 1], z + STEP)
			for tri in [[a, b, c], [b, d, c]]:
				var nrm: Vector3 = (tri[2] - tri[0]).cross(tri[1] - tri[0]).normalized()
				var mid: Vector3 = (tri[0] + tri[1] + tri[2]) / 3.0
				var col := _ground_color(mid, nrm)
				for v in tri:
					verts.append(v)
					normals.append(nrm)
					colors.append(col)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	return mi


func _ground_color(mid: Vector3, nrm: Vector3) -> Color:
	var p := Vector2(mid.x, mid.z)
	var wd := water_dist(p)
	var pl := plateau(p)
	var col: Color
	var vr := p.distance_to(CENTER)
	if outside(p) > -0.6:
		col = Color("#5a554c").lerp(Color("#3c3832"), randf() * 0.6 + clampf(outside(p) * 0.05, 0.0, 0.3))   # скалы за краем карты
	elif vr < vol_out - 0.5 and not (in_ramp(p) and vr > vol_in):
		col = Color("#3a302a").lerp(Color("#24201c"), randf() * 0.5)          # чёрный базальт вулкана
		if vr < vol_in:
			col = Color("#4a2a1a").lerp(Color("#2a1a12"), randf() * 0.5)     # раскалённое дно кратера
	elif nrm.y < 0.78 and (pl > 0.02 and pl < 0.98):
		col = Color("#5f5a52").lerp(Color("#44403a"), randf() * 0.7)          # скала обрыва
	elif _mesa_band(p) or (nrm.y < 0.62 and mesa(p) > 0.15):
		col = Color("#6a6458").lerp(Color("#4a463e"), randf() * 0.6)          # обрыв возвышенности: слоистый камень
		if fmod(mid.y * 2.2, 1.0) < 0.22:
			col = col.darkened(0.18)
	elif wd < 0.35:
		col = Color("#5f5a48").lerp(Color("#8a7f62"), ford(p))                                                 # дно
	elif wd < 1.7:
		col = pal(p, "sand").lerp(pal(p, "grass", 0), smoothstep(0.9, 1.7, wd)) # берег
	else:
		var t := tint.get_noise_2d(p.x, p.y) * 0.5 + 0.5
		col = pal(p, "grass", 0).lerp(pal(p, "grass", 1), t)
		if t > 0.68:
			col = col.lerp(pal(p, "dry"), (t - 0.68) * 2.2)          # сухая трава (зимой — наст)
		var mud := noise.get_noise_2d(p.x * 2.3 + 40.0, p.y * 2.3 - 17.0) * 0.5 + 0.5
		if mud > 0.6:
			col = col.lerp(pal(p, "mud"), minf(1.0, (mud - 0.6) * 3.5))        # пятна голой земли
		var mh := mesa(p)
		if mh > 1.2:
			col = col.lightened(0.06).lerp(pal(p, "dry"), 0.18)      # вершина возвышенности — суше и светлее
			for m in mesas:      # светлый гребень по самому краю вершины
				var dd: float = p.distance_to(m["c"])
				var ee := _mesa_edge(m, p)
				if dd > ee - 1.6 and dd < ee - 0.2 and not _mesa_ramp(m, p):
					col = col.lightened(0.14)
		if pl > 0.9:
			col = col.lerp(Color("#4a5a4a"), 0.5)                                # трава на плато
		col = col.darkened(randf() * 0.16)
	if p.x < 0.0 or p.y < 0.0 or p.x > SIZE or p.y > SIZE:
		col = col.darkened(0.45)                                               # за краем карты
	return col


func _water_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var wc := Color(String(B["water"]))
	m.albedo_color = Color(wc.r, wc.g, wc.b, 0.86 if biome != "winter" else 0.93)      # зимой — подо льдом
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.15
	m.metallic = 0.2
	return m


func _water(parent: Node3D) -> void:
	var mat := _water_material()
	# нижняя вода: одна плоскость, видна только там, где земля ниже неё
	var low := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(SIZE + MARGIN * 2.0, SIZE + MARGIN * 2.0)
	low.mesh = plane
	low.position = Vector3(SIZE * 0.5, WATER_Y, SIZE * 0.5)
	low.material_override = mat
	low.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(low)
	# ручей на плато: лента вдоль русла
	var y := PLATEAU_H + WATER_Y
	var half := high_w + 1.3
	for i in high_river.size() - 2:
		var a: Vector2 = high_river[i]
		var b: Vector2 = high_river[i + 1]
		var seg := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(half * 2.0, 0.02, a.distance_to(b))
		seg.mesh = box
		seg.material_override = mat
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mid := (a + b) * 0.5
		seg.position = Vector3(mid.x, y, mid.y)
		seg.rotation.y = atan2(b.x - a.x, b.y - a.y)
		parent.add_child(seg)
		var joint := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = half
		disc.bottom_radius = half
		disc.height = 0.02
		disc.radial_segments = 10
		joint.mesh = disc
		joint.material_override = mat
		joint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		joint.position = Vector3(b.x, y, b.y)
		parent.add_child(joint)


func _waterfall(parent: Node3D, Models) -> void:
	var dir := fall_dir
	var side := Vector2(dir.y, -dir.x)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var half := high_w + 0.5
	var pts: Array = []
	var r := plateau_r - 2.2
	while r <= plateau_r + 2.6:
		var c := plateau_corner + dir * r
		pts.append([c, maxf(water_level(c), height(c) + 0.25) + 0.06, (r - plateau_r + 2.2) / 4.8])
		r += 0.4
	for i in pts.size() - 1:
		var a0 := _wf(pts[i], side, -half)
		var a1 := _wf(pts[i], side, half)
		var b0 := _wf(pts[i + 1], side, -half)
		var b1 := _wf(pts[i + 1], side, half)
		for v in [a0, a1, b0, a1, b1, b0]:
			verts.append(v)
		for uv in [Vector2(0, pts[i][2]), Vector2(1, pts[i][2]), Vector2(0, pts[i + 1][2]), Vector2(1, pts[i][2]), Vector2(1, pts[i + 1][2]), Vector2(0, pts[i + 1][2])]:
			uvs.append(uv)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
void fragment() {
	float streak = fract(UV.y * 5.0 - TIME * 1.6 + sin(UV.x * 22.0) * 0.35);
	float foam = step(0.72, fract(UV.x * 6.0 + sin(UV.y * 8.0 - TIME * 4.0) * 0.4));
	vec3 water = mix(vec3(0.20, 0.32, 0.38), vec3(0.50, 0.62, 0.66), streak);
	ALBEDO = mix(water, vec3(0.82, 0.86, 0.84), foam * 0.7);
}
"""
	var sm := ShaderMaterial.new()
	sm.shader = sh
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	# пена у подножия и камни по бокам
	var foot := plateau_corner + dir * (plateau_r + 2.6)
	for i in 9:
		var off := side * (float(i % 5) - 2.0) * 0.55 + dir * (0.2 + float(i % 3) * 0.45)
		Models.ball(parent, 0.3 + float(i % 3) * 0.08, Vector3(foot.x + off.x, WATER_Y + 0.02, foot.y + off.y), Color("#f4fbff"), Vector3(1, 0.45, 1))
	for s in [-1.0, 1.0]:
		var top: Vector2 = plateau_corner + dir * (plateau_r - 1.0) + side * s * (half + 0.9)
		Models.ball(parent, 0.9, Vector3(top.x, height(top) + 0.2, top.y), Color("#7d776c"), Vector3(1, 0.8, 1.1))
		var low: Vector2 = plateau_corner + dir * (plateau_r + 2.4) + side * s * (half + 1.0)
		Models.ball(parent, 0.7, Vector3(low.x, height(low) + 0.1, low.y), Color("#8d867a"), Vector3(1.1, 0.7, 1))


func _wf(pt: Array, side: Vector2, off: float) -> Vector3:
	var c: Vector2 = pt[0] + side * off
	return Vector3(c.x, pt[1], c.y)


## Цветы, кусты, камни, камыш, кувшинки. Только украшения: на игру не влияют.
func _decor(parent: Node3D, occupied: Callable) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 4242
	var flower := SphereMesh.new()
	flower.radius = 0.1
	flower.height = 0.2
	flower.radial_segments = 5
	flower.rings = 2
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.13
	cone.height = 0.36
	cone.radial_segments = 4
	cone.rings = 1
	var blob := SphereMesh.new()
	blob.radius = 0.5
	blob.height = 1.0
	blob.radial_segments = 6
	blob.rings = 3
	var pad := CylinderMesh.new()
	pad.top_radius = 0.32
	pad.bottom_radius = 0.32
	pad.height = 0.03
	pad.radial_segments = 7

	var flowers: Array = []
	var palette := [Color("#ffffff"), Color("#ffd94a"), Color("#e8484f"), Color("#b06be0"), Color("#ff9ac4"), Color("#6fb6ff")]
	for patch in int(70 * AREA):
		var c := Vector2(rng.randf_range(2, SIZE - 2), rng.randf_range(2, SIZE - 2))
		var col: Color = palette[rng.randi() % palette.size()]
		for i in rng.randi_range(8, 22):
			var p := c + Vector2(rng.randfn(0.0, 1.6), rng.randfn(0.0, 1.6))
			if _grass(p) and not occupied.call(p) and not _snowy(p):      # в снегу цветы не растут
				flowers.append([p, 0.16, col.lightened(rng.randf() * 0.15), Vector3.ONE * rng.randf_range(0.7, 1.2), 0.0])
	_multi(parent, flower, flowers, true)

	var tufts: Array = []
	for i in int(1500 * AREA):
		var p := Vector2(rng.randf_range(-6, SIZE + 6), rng.randf_range(-6, SIZE + 6))
		if _grass(p) and not occupied.call(p):
			var tc := pal(p, "bush", 0).lerp(pal(p, "grass", 1), 0.35)      # трава в цвет местности: зелёная, рыжая, сухая, заснеженная
			tufts.append([p, 0.15, tc.lightened(0.08 + rng.randf() * 0.25), Vector3(1, rng.randf_range(0.7, 1.6), 1), rng.randf() * 6.0])
	_multi(parent, cone, tufts, true)

	var reeds: Array = []
	for i in int(2600 * AREA):
		var p := Vector2(rng.randf_range(0, SIZE), rng.randf_range(0, SIZE))
		var wd := water_dist(p)
		if wd > -0.3 and wd < 1.0 and plateau(p) < 0.02 and ford(p) < 0.05 and rng.randf() < 0.75:
			reeds.append([p, 0.3, Color("#6f8a3a").lerp(Color("#8a7a44"), rng.randf()), Vector3(0.5, rng.randf_range(2.0, 3.4), 0.5), 0.0])
	_multi(parent, cone, reeds, true)

	# кусты и камни внутри карты — препятствия из списка props; за краем карты — просто украшение
	var bushes: Array = []
	var rocks: Array = []
	var pillars: Array = []
	var dead: Array = []
	for pr in props:
		var item := [pr["pos"], 0.1 if pr["kind"] == "bush" else 0.0, pr["color"], pr["scale"], pr["rot"]]
		match String(pr["kind"]):
			"bush":
				bushes.append(item)
			"pillar":
				item[1] = (pr["scale"] as Vector3).y * 0.5 - 0.05
				pillars.append(item)
			"deadtree":
				dead.append(item)
			_:
				rocks.append(item)
	var pillar_mesh := BoxMesh.new()      # колонна руин: брусок; высота — из размера
	pillar_mesh.size = Vector3(1, 1, 1)
	_multi(parent, pillar_mesh, pillars)
	_multi(parent, _dead_tree_mesh(), dead)
	# грибы в лесах и на сырой земле (просто украшение)
	var shrooms: Array = []
	for i in int(260 * AREA):
		var c := Vector2(rng.randf_range(2, SIZE - 2), rng.randf_range(2, SIZE - 2))
		if not _grass(c) or occupied.call(c) or _snowy(c) or num(c, "forest") < 0.9:
			continue
		var col: Color = [Color("#c8402a"), Color("#d8b070"), Color("#e8e0d0")][rng.randi() % 3]
		for j in rng.randi_range(2, 5):
			var p := c + Vector2(rng.randfn(0.0, 0.5), rng.randfn(0.0, 0.5))
			if _grass(p) and not occupied.call(p):
				shrooms.append([p, 0.08, col.lightened(rng.randf() * 0.1), Vector3(1.0, 0.6, 1.0) * rng.randf_range(0.6, 1.1), 0.0])
	_multi(parent, flower, shrooms, true)
	for i in int(420 * K):
		var p := Vector2(rng.randf_range(-10, SIZE + 10), rng.randf_range(-10, SIZE + 10))
		var inside := p.x > 0.0 and p.y > 0.0 and p.x < SIZE and p.y < SIZE
		var pl := plateau(p)
		if water_dist(p) < 1.0 or (inside and pl < 0.95) or (pl > 0.02 and pl < 0.95):
			continue
		var s := rng.randf_range(0.4, 1.0) * (1.5 if pl > 0.95 else 1.0)
		if rng.randf() < 0.5 and pl < 0.95:
			bushes.append([p, 0.1, Color("#2f6b3a").lerp(Color("#4f8f3a"), rng.randf()), Vector3(s, s * 0.75, s), rng.randf() * 6.0])
		else:
			rocks.append([p, 0.0, Color("#8d867a").lerp(Color("#a59f92"), rng.randf()), Vector3(s, s * 0.6, s), rng.randf() * 6.0])
	_multi(parent, blob, bushes)
	_multi(parent, blob, rocks)

	# граница карты: гряда огромных валунов по всему краю
	var cliffs: Array = []
	var edge := 0.0
	while edge < SIZE * 4.0:
		var side_i := int(edge / SIZE)
		var t := fmod(edge, float(SIZE))
		var at: Vector2 = [Vector2(t, 0), Vector2(SIZE, t), Vector2(SIZE - t, SIZE), Vector2(0, SIZE - t)][side_i]
		var out: Vector2 = [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][side_i]
		for layer in 2:
			var p := at + out * rng.randf_range(1.2, 3.0) + out * float(layer) * 3.5 + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1))
			var s := rng.randf_range(1.8, 3.4) * (1.0 + float(layer) * 0.4)
			cliffs.append([p, -0.6, Color("#6f6a60").lerp(Color("#4a463f"), rng.randf()), Vector3(s, s * rng.randf_range(1.0, 1.9), s), rng.randf() * 6.0])
		edge += rng.randf_range(2.2, 3.2)
	_multi(parent, blob, cliffs)

	# валуны вдоль подножия обрывов возвышенностей (на непроходимой полосе — только вид)
	var scree: Array = []
	for m in mesas:
		var steps := int(float(m["r"]) * TAU / 0.9)
		for i in steps:
			var a := TAU * float(i) / float(steps) + rng.randf() * 0.1
			var probe: Vector2 = (m["c"] as Vector2) + Vector2.RIGHT.rotated(a) * float(m["r"])
			var e := _mesa_edge(m, probe)
			var p: Vector2 = (m["c"] as Vector2) + Vector2.RIGHT.rotated(a) * (e + rng.randf_range(0.3, 0.8))
			if _mesa_ramp(m, p) or rng.randf() < 0.25:
				continue
			var s := rng.randf_range(0.45, 1.05)
			scree.append([p, -0.1, Color("#7d776c").lerp(Color("#9a9488"), rng.randf()), Vector3(s, s * rng.randf_range(0.6, 1.0), s), rng.randf() * 6.0])
	_multi(parent, blob, scree)

	var pads: Array = []
	for l in lakes:
		for i in 14:
			var a := rng.randf() * TAU
			var p: Vector2 = l[0] + Vector2(cos(a), sin(a)) * rng.randf_range(0.5, float(l[1]) - 1.2)
			pads.append([p, -INF, Color("#3f8f4a").lightened(rng.randf() * 0.2), Vector3.ONE * rng.randf_range(0.7, 1.3), 0.0])
	_multi(parent, pad, pads)


## Снег в этой точке (зимняя зона или зимняя карта)?
func _snowy(p: Vector2) -> bool:
	var z := zone_at(p)
	return (String(z[0]) == "winter" and float(z[1]) > 0.5) or (biome == "winter" and float(z[1]) < 0.5)


## Мёртвое дерево: голый ствол и пара сухих сучьев (одна сетка на все).
func _dead_tree_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in [[0.07, 0.16, 1.7, Vector3(0, 0.85, 0), Vector3.ZERO], [0.02, 0.06, 0.8, Vector3(0.22, 1.25, 0), Vector3(0, 0, -0.9)],
			[0.02, 0.05, 0.6, Vector3(-0.18, 1.5, 0.05), Vector3(0.2, 0, 0.8)], [0.015, 0.04, 0.45, Vector3(0.05, 1.75, -0.12), Vector3(-0.7, 0, 0.1)]]:
		var cm := CylinderMesh.new()
		cm.top_radius = float(part[0])
		cm.bottom_radius = float(part[1])
		cm.height = float(part[2])
		cm.radial_segments = 5
		cm.rings = 1
		st.append_from(cm, 0, Transform3D(Basis.from_euler(part[4]), part[3]))
	return st.commit()


func _grass(p: Vector2) -> bool:
	var pl := plateau(p)
	return water_dist(p) > 1.2 and (pl < 0.02 or pl > 0.98) and not mesa_wall(p)


## Много одинаковых мелких предметов одним объектом (так быстрее для видеокарты).
## items: [место, подъём над землёй (-INF = на воде), цвет, размер, поворот]
const PROP_CHUNK := 24      # трава и камни — пачками по участкам: невидимые участки видеокарта не рисует
var prop_layers: Array = []  # [MultiMeshInstance3D, полное число травинок, трава ли] — для настройки качества


func _multi(parent: Node3D, mesh: Mesh, items: Array, soft: bool = false) -> void:
	if items.is_empty():
		return
	var chunks: Dictionary = {}
	for it in items:
		var p: Vector2 = it[0]
		var ck := Vector2i(floori(p.x / PROP_CHUNK), floori(p.y / PROP_CHUNK))
		if not chunks.has(ck):
			chunks[ck] = []
		(chunks[ck] as Array).append(it)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	for ck in chunks:
		var list: Array = chunks[ck]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = list.size()
		for i in list.size():
			var it: Array = list[i]
			var p: Vector2 = it[0]
			var y: float = WATER_Y + 0.02 if it[1] == -INF else height(p) + float(it[1])
			var basis := Basis(Vector3.UP, float(it[4])).scaled(it[3])
			var xform := Transform3D(basis, Vector3(p.x, y, p.y))
			mm.set_instance_transform(i, xform)
			if soft:
				var cell := Vector2i(floori(p.x), floori(p.y))
				if not _soft.has(cell):
					_soft[cell] = []
				_soft[cell].append(_soft_all.size())
				_soft_all.append([mm, i, xform, p])
			mm.set_instance_color(i, _dirty(it[2]))
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		prop_layers.append([mi, list.size(), soft])


## Качество графики: доля видимой травы и мелочи (1 — вся, 0.5 — половина, 0 — без неё).
func set_prop_density(k: float) -> void:
	for layer in prop_layers:
		var mi: MultiMeshInstance3D = layer[0]
		if not is_instance_valid(mi) or not layer[2]:
			continue      # камни и прочее, что видно в игре, не трогаем — только траву и цветы
		var n := int(layer[1])
		mi.multimesh.visible_instance_count = n if k >= 0.99 else int(n * k)
		mi.visible = k > 0.01


const _SQUASHED := Transform3D(Basis(), Vector3(0, -50, 0))


## Трава и цветы «приминаются» там, где стоят юниты, и поднимаются, когда те уходят.
func trample(points: Array, radius: float = 0.75) -> void:
	var now: Dictionary = {}
	for pt in points:
		var p: Vector2 = pt
		var c := Vector2i(floori(p.x), floori(p.y))
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for gid in _soft.get(c + Vector2i(dx, dy), []):
					if (_soft_all[gid][3] as Vector2).distance_to(p) < radius:
						now[gid] = true
	for gid in now:
		if not _flat.has(gid) and not _hidden.has(gid):
			(_soft_all[gid][0] as MultiMesh).set_instance_transform(_soft_all[gid][1], _SQUASHED)
	for gid in _flat:
		if not now.has(gid) and not _hidden.has(gid):
			(_soft_all[gid][0] as MultiMesh).set_instance_transform(_soft_all[gid][1], _soft_all[gid][2])
	_flat = now


## Под зданием трава убирается насовсем.
func clear_rect(rect: Rect2i) -> void:
	for x in range(rect.position.x - 1, rect.end.x + 1):
		for y in range(rect.position.y - 1, rect.end.y + 1):
			for gid in _soft.get(Vector2i(x, y), []):
				if Rect2(rect).grow(0.3).has_point(_soft_all[gid][3]):
					_hidden[gid] = true
					(_soft_all[gid][0] as MultiMesh).set_instance_transform(_soft_all[gid][1], _SQUASHED)


## Украшения красятся в ту же приглушённую гамму, что и модели.
static func _dirty(c: Color) -> Color:
	var out := Color.from_hsv(c.h, c.s * 0.6, c.v * 0.72, c.a)
	return out.lerp(Color(0.25, 0.22, 0.18, c.a), 0.14)
