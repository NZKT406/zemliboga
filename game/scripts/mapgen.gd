extends RefCounted
## Генератор случайной карты: базы, рудники, леса, лагеря нейтралов, нейтральные строения,
## вулкан с драконом в центре. Всё определяется зерном (одно число), поэтому карту можно повторить.
## Карта бывает трёх размеров: 96 (маленькая), 192 (×4 по площади) и 272 (×8),
## игроков — от 2 до 8. Всё, что важно для честной игры, ставится с поворотной симметрией:
## у каждого игрока одинаковые рудники, шахты и строения на одинаковом расстоянии.

const Sim = preload("res://scripts/sim.gd")
const Terrain = preload("res://scripts/terrain.gd")
const SIZES := {96: "Маленькая", 192: "Большая (×4)", 272: "Огромная (×8)"}
const MAX_PLAYERS_ON := {96: 4, 192: 8, 272: 8}     # на маленькой карте больше 4 баз не помещается
const OWN_MINES := {96: 2, 192: 3, 272: 4}          # своих рудников у каждого игрока (вместе с рудником у базы)
static var walls_on := true                         # кольца леса вокруг баз (выключает только проверка)
const EXTRA_GOLD := 20000                           # золота в рудниках вдали от баз (у базы — Sim.GOLD_IN_MINE)


## race_list — расы игроков по порядку (2…8). Возвращает {"sim": ..., "terrain": ...}.
## Если между базами нет прохода, пробует следующее зерно.
static func generate(race_list: Array, neutral: Dictionary, combat: Dictionary, map_seed: int, map_size: int = 96, biome_key: String = "any") -> Dictionary:
	var n := race_list.size()
	var sim: Sim
	var terrain: Terrain
	var biome := Terrain.biome_for(biome_key, map_seed)      # местность не меняется от повторных попыток
	for attempt in 40:
		var s := map_seed + attempt * 7919
		terrain = Terrain.new(s, map_size, n, biome)
		sim = Sim.new()
		sim.set_map_size(map_size)
		sim.seed_value = s
		sim.biome = biome
		sim.combat = combat
		for x in map_size:
			for y in map_size:
				if terrain.blocked(Vector2i(x, y)):
					sim.block_cell(Vector2i(x, y), terrain.swimmable(Vector2i(x, y)))
				elif terrain.high_ground(Vector2i(x, y)):
					sim.high_cells[Vector2i(x, y)] = true      # вершины возвышенностей
		var ok := true
		for i in n:
			ok = ok and sim.can_place(8, Vector2i(terrain.bases[i]) - Vector2i(4, 4))
			if i > 0:
				ok = ok and sim.path_exists(terrain.bases[0], terrain.bases[i])
		ok = ok and sim.path_exists(terrain.bases[0], terrain.CENTER)
		if ok:
			break
	_fill(sim, terrain, race_list, neutral)
	return {"sim": sim, "terrain": terrain}


static func _fill(sim: Sim, terrain: Terrain, race_list: Array, neutral: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = sim.seed_value + 1
	var n := race_list.size()
	var center: Vector2 = terrain.CENTER
	var k: float = terrain.K           # во сколько раз сторона больше маленькой карты
	var groups := 1 if k < 1.5 else (2 if k < 2.5 else 3)
	if n > 2:
		groups = maxi(1, groups - 1)    # при многих игроках каждая группа — это n строений
	for p in n:
		sim.add_player(p, race_list[p])
	sim.add_player(Sim.NEUTRAL, neutral)
	var keep: Array = []      # [точка, радиус]: здесь лес не сажаем
	var mines: Array = []     # [точка, уровень лагеря-охраны]
	var spots: Array = []     # уже занятые места нейтральных строений и рудников
	for f in terrain.fords:
		keep.append([f, 5.0])
	keep.append([center, terrain.vol_out + 3.0])
	for rp in terrain.ramp_spots():      # подъёмы на возвышенности не зарастают лесом
		keep.append([rp, 3.5])
	if terrain.plateau_r > 0.0:
		keep.append([terrain.plateau_corner + terrain.fall_dir * (terrain.plateau_r + 3.0), 6.0])

	# --- базы ---
	# Каждая база — поляна в кольце густого леса с двумя выходами: к центру карты и вбок.
	# Ратуша стоит в глубине поляны, рудник — ближе к выходу. Так напасть можно только
	# через выходы (пока лес не вырублен), и понятно, откуда ждать врага.
	# Форма кольца и угол бокового выхода у всех игроков одинаковые — всё честно.
	var wall_r := 14.0 + 2.5 * (k - 1.0)
	var side_exit := (1.0 if rng.randf() < 0.5 else -1.0) * rng.randf_range(1.5, 2.0)
	var wall_phase := rng.randf() * TAU
	var exits: Array = [0.0, side_exit]
	var hard_keep: Array = keep.duplicate()      # что нельзя засадить и стеной (броды, подъёмы, вулкан)
	var corridors: Array = []      # точки у выходов: туда не ставим строения и лес
	for player in n:
		var base: Vector2 = terrain.bases[player]
		var to_center := (center - base).normalized()
		var race: Dictionary = race_list[player]
		var start: Dictionary = race["start"]
		var hall: Dictionary = race["buildings"][String(start["hall"])]
		sim.spawn_building(player, String(start["hall"]), hall, Vector2i(base) - Vector2i(2, 2))
		keep.append([base, 12.0])
		var glade := base + to_center * 4.0      # середина поляны: ратуша в её глубине
		# рудник — между ратушей и выходом
		var mine_keep: Array = []
		for attempt in 60:
			var mine_angle := (1.0 if attempt % 2 == 0 else -1.0) * rng.randf_range(0.6, 0.95)
			var p := base + to_center.rotated(mine_angle) * rng.randf_range(9.0, 10.5)
			if _place_mine(sim, p):
				keep.append([p, 4.5])
				mine_keep.append([p, 4.0])
				spots.append(p)
				break
		for ex in exits:
			var dir := to_center.rotated(float(ex))
			for dist in [wall_r - 1.0, wall_r + 2.5, wall_r + 6.5]:
				corridors.append(glade + dir * dist)
		if walls_on:
			_wall(sim, terrain, glade, to_center, wall_r, exits, wall_phase, hard_keep + mine_keep)
		keep.append([glade, wall_r - 0.5])      # внутри поляны случайный лес не растёт
		# стартовые рабочие перед базой
		var front := base + to_center * 5.5
		var side := to_center.rotated(PI / 2)
		var cnt := 0
		for key in start["units"]:
			for i in int(start["units"][key]):
				var id := sim.spawn_unit(player, String(key), race["units"][key], front + side * ((cnt % 4) - 1.5) * 1.5 + to_center * (cnt / 4) * 1.6)
				sim.units[id]["facing"] = to_center
				cnt += 1

	for c in corridors:      # проходы у выходов не зарастают и не застраиваются
		keep.append([c, 4.5])
		spots.append(c)

	# --- рудники на карте ---
	# «свои» рудники у каждого игрока: всего 2 на маленькой карте, 3 на большой, 4 на огромной
	# (один у базы и остальные дальше — под новую ратушу; чем дальше, тем сильнее охрана).
	# Ближние ставятся снаружи напротив выходов с поляны. В них вдвое больше золота.
	var own: int = int(OWN_MINES.get(sim.map_size, 2)) - 1
	for i in own:
		var dmin := maxf(17.0, wall_r + 9.0) + 8.0 * i * sqrt(k)
		var aims: Array = exits if i == 0 else []
		var placed: Array = _ring(sim, rng, terrain, spots, 7, dmin, dmin + 12.0 * sqrt(k), 8.0, true, true, aims)
		if placed.is_empty():
			placed = _ring(sim, rng, terrain, spots, 5, dmin - 3.0, dmin + 22.0 * sqrt(k), 6.0, true)
		for m in placed:
			_place_mine(sim, m, EXTRA_GOLD)
			mines.append([m, mini(5, 2 + i)])
			keep.append([m, 6.0])
	for i in groups:
		for m in _ring(sim, rng, terrain, spots, 5, 26.0, 999.0, 14.0):
			_place_mine(sim, m, EXTRA_GOLD)
			mines.append([m, 4])
			keep.append([m, 6.0])

	# --- нейтральные строения: шахты гоблинов, источники жизни, лагеря наёмников ---
	var structures: Array = []      # [точка, ключ, уровень охраны]
	for i in groups:
		for m in _ring(sim, rng, terrain, spots, 5, 20.0, 999.0, 10.0):
			structures.append([m, "goblin_mine", 2 if i == 0 else 3])
	for i in groups:
		for m in _ring(sim, rng, terrain, spots, 4, 22.0, 999.0, 9.0):
			structures.append([m, "fountain", 0])
	for i in maxi(1, groups - 1):
		for m in _ring(sim, rng, terrain, spots, 5, 24.0, 999.0, 10.0):
			structures.append([m, "mercenary", 0])
	if neutral["buildings"].has("lookout"):      # сторожевые башни: обзор сквозь туман войны
		for i in groups:
			for m in _ring(sim, rng, terrain, spots, 5, 19.0, 999.0, 12.0):
				structures.append([m, "lookout", 2])
	for m in _ring(sim, rng, terrain, spots, 2, 20.0, 999.0, 8.0):      # места рун силы
		sim.rune_spots.append(m)
		keep.append([m, 3.0])
	for st in structures:
		var def: Dictionary = neutral["buildings"][st[1]]
		var sz := int(def["size"])
		var bid := sim.spawn_building(Sim.NEUTRAL, String(st[1]), def, Vector2i(st[0]) - Vector2i(sz / 2, sz / 2))
		sim.buildings[bid]["owner"] = -1
		if String(def.get("role", "")) == "mercenary":
			sim._merc_init(sim.buildings[bid])      # вид лагеря известен сразу (и для модели)
		keep.append([st[0], 5.0])

	# --- лагеря нейтралов: охрана рудников и шахт гоблинов, плюс случайные ---
	var camps: Array = []
	var guarded: Array = mines.duplicate()
	for st in structures:
		if int(st[2]) > 0:
			guarded.append([st[0], st[2]])
	for m in guarded:
		var pos: Vector2 = m[0]
		for attempt in 30:
			var c := pos + Vector2.RIGHT.rotated(rng.randf() * TAU) * 4.4
			if sim.can_place(3, Vector2i(c) - Vector2i(1, 1)):
				camps.append([c, int(m[1])])
				break
	var extra := int(round(7.0 * k * k * 0.85)) if k > 1.5 else 7
	extra += (n - 2) * 2
	for attempt in 400 * int(ceil(k * k)):
		if camps.size() >= guarded.size() + extra:
			break
		var p := Vector2(rng.randf_range(6, sim.map_size - 6), rng.randf_range(6, sim.map_size - 6))
		var near_base := _near_base(terrain, p)
		var ok := near_base > 23.0 and sim.can_place(3, Vector2i(p) - Vector2i(1, 1)) and p.distance_to(center) > terrain.vol_out + 4.0
		for c in camps:
			ok = ok and p.distance_to(c[0]) > 13.0
		for s in spots:
			ok = ok and p.distance_to(s) > 7.0
		for f in terrain.fords:
			ok = ok and p.distance_to(f) > 7.0
		if ok:
			var lvl := 1 if near_base < 33.0 else (2 if near_base < 44.0 * sqrt(k) or rng.randf() < 0.6 else 3)
			if lvl == 3 and near_base > 50.0 * sqrt(k) and rng.randf() < 0.45:
				lvl = 4
			camps.append([p, lvl])
	# логова боссов 6-го уровня: места, как можно более одинаково далёкие от всех баз
	for lair_i in groups:
		var lair := Vector2(-1, -1)
		var lair_score := 10.0 * k
		for attempt in 600:
			var p := Vector2(rng.randf_range(8, sim.map_size - 8), rng.randf_range(8, sim.map_size - 8))
			var dmin := INF
			var dmax := 0.0
			for b in terrain.bases:
				dmin = minf(dmin, p.distance_to(b))
				dmax = maxf(dmax, p.distance_to(b))
			var ok := dmin > 26.0 and p.distance_to(center) > terrain.vol_out + 5.0 and sim.can_place(3, Vector2i(p) - Vector2i(1, 1))
			for c in camps:
				ok = ok and p.distance_to(c[0]) > 9.0 * (1.0 if int(c[1]) < 6 else 3.0)
			for s in spots:
				ok = ok and p.distance_to(s) > 7.0
			for f in terrain.fords:
				ok = ok and p.distance_to(f) > 5.0
			if ok and dmax - dmin < lair_score:
				lair_score = dmax - dmin
				lair = p
		if lair.x >= 0.0:
			camps.append([lair, 6])
	for i in camps.size():
		_camp(sim, rng, neutral, i, camps[i][0], int(camps[i][1]))
		keep.append([camps[i][0], 4.5])

	# --- красный дракон в кратере вулкана ---
	if neutral["units"].has("red_dragon"):
		var did := sim.spawn_unit(Sim.NEUTRAL, "red_dragon", neutral["units"]["red_dragon"], center, false)
		sim.units[did]["camp"] = 99999
		sim.units[did]["camp_level"] = 7
		sim.units[did]["home"] = sim.units[did]["pos"]
	var count := 0
	for id in sim.units:
		if int(sim.units[id]["player"]) == Sim.NEUTRAL:
			count += 1
	sim.neutral_cap = int(count * 1.35) + 6     # больше этого новые лагеря не появляются

	# --- лавки торговцев: по одной на пути от каждой базы к центру (на больших картах больше) ---
	var shop_def: Dictionary = neutral["buildings"]["shop"]
	for player in n:
		var base: Vector2 = terrain.bases[player]
		var dir := (center - base).normalized()
		for attempt in 60:
			var p := base + dir.rotated(rng.randf_range(-0.9, 0.9)) * rng.randf_range(wall_r + 9.0, wall_r + 16.0)
			var cell := Vector2i(p) - Vector2i(1, 1)
			var ok := sim.can_place(5, cell - Vector2i(1, 1))
			for cp in corridors:
				ok = ok and p.distance_to(cp) > 5.0
			for c in camps:
				ok = ok and p.distance_to(c[0]) > 9.0
			if ok:
				sim.spawn_building(Sim.NEUTRAL, "shop", shop_def, cell)
				keep.append([p, 5.0])
				break
	for i in groups - 1:
		for p in _ring(sim, rng, terrain, spots, 5, 30.0, 999.0, 9.0):
			sim.spawn_building(Sim.NEUTRAL, "shop", shop_def, Vector2i(p) - Vector2i(1, 1))
			keep.append([p, 5.0])

	# --- леса ---
	for patch in int(30 * k * k * 1.2):      # густота леса — по местности в точке: в степи мало, осенью больше
		var c := Vector2(rng.randf_range(3, sim.map_size - 3), rng.randf_range(3, sim.map_size - 3))
		var size := rng.randi_range(10, 28)
		var spread := rng.randf_range(2.0, 3.6)
		if rng.randf() > terrain.num(c, "forest") / 1.2:
			continue
		_forest(sim, rng, c, size, spread, keep)

	# выход с поляны должен вести наружу: если за ним вода или скалы — прорубаем лес вдоль выходов
	for player in n:
		var base: Vector2 = terrain.bases[player]
		var fwd := (center - base).normalized()
		var glade := base + fwd * 4.0
		for ex in exits:
			if sim.path_exists(base + fwd * 6.0, center):
				break
			_carve(sim, glade, glade + fwd.rotated(float(ex)) * (wall_r + 12.0), 2.6)


## Убирает деревья вдоль отрезка a–b (полоса шириной 2·half).
static func _carve(sim: Sim, a: Vector2, b: Vector2, half: float) -> void:
	var gone: Array = []
	for id in sim.resources:
		var r: Dictionary = sim.resources[id]
		if String(r["kind"]) != "tree":
			continue
		var q: Vector2 = r["pos"]
		var t := clampf((q - a).dot(b - a) / maxf(0.001, (b - a).length_squared()), 0.0, 1.0)
		if q.distance_to(a.lerp(b, t)) < half:
			gone.append(id)
	for id in gone:
		sim._set_solid(Rect2i(sim.resources[id]["cell"], Vector2i.ONE), false)
		sim.resources.erase(id)


static func _near_base(terrain: Terrain, p: Vector2) -> float:
	var d := INF
	for b in terrain.bases:
		d = minf(d, p.distance_to(b))
	return d


## Группа симметричных мест: точка и её копии, повёрнутые вокруг центра на 360°/n
## (для двух игроков — отражение через центр). Так у всех игроков всё одинаково.
## size — сколько клеток должно быть свободно; dmin/dmax — расстояние от ближайшей базы;
## sep — отступ от уже занятых мест и друг от друга.
static func _ring(sim: Sim, rng: RandomNumberGenerator, terrain: Terrain, spots: Array, size: int, dmin: float, dmax: float, sep: float, near_base := false, clear := true, aims: Array = []) -> Array:
	var center: Vector2 = terrain.CENTER
	var n: int = terrain.bases.size()
	for attempt in (500 if near_base else 400):
		var p := Vector2(rng.randf_range(8, sim.map_size - 8), rng.randf_range(8, sim.map_size - 8))
		if near_base:      # ищем вокруг первой базы — копии для остальных получаются поворотом
			var ang := rng.randf() * TAU
			if not aims.is_empty() and attempt < 300:      # напротив выходов с поляны (углы — от направления на центр)
				ang = (center - (terrain.bases[0] as Vector2)).angle() + float(aims[attempt % aims.size()]) + rng.randf_range(-0.6, 0.6)
			p = (terrain.bases[0] as Vector2) + Vector2(rng.randf_range(dmin, dmax), 0).rotated(ang)
			if p.x < 8.0 or p.y < 8.0 or p.x > sim.map_size - 8.0 or p.y > sim.map_size - 8.0:
				continue
		var d := _near_base(terrain, p)
		if d < dmin or d > dmax or p.distance_to(center) < terrain.vol_out + 5.0:
			continue
		var copies: Array = []
		for i in n:
			copies.append(center + (p - center).rotated(TAU * i / n))
		var ok := true
		for a in copies.size():
			var q: Vector2 = copies[a]
			if clear:      # под рудники и строения кусты и камни можно расчистить, а воду, скалы и лес — нет
				ok = ok and _free_except_props(sim, terrain, q, size)
			else:
				ok = ok and sim.can_place(size, Vector2i(q) - Vector2i(size / 2, size / 2))
			for b in range(a + 1, copies.size()):
				ok = ok and q.distance_to(copies[b]) > sep * 2.0
			for s in spots:
				ok = ok and q.distance_to(s) > sep
			for f in terrain.fords:
				ok = ok and q.distance_to(f) > 6.0
			if not ok:
				break
		if ok:
			if clear:
				for q in copies:
					_clear_props(sim, terrain, q, size)
			spots.append_array(copies)
			return copies
	return []


static func _free_except_props(sim: Sim, terrain: Terrain, q: Vector2, size: int) -> bool:
	var c0 := Vector2i(q) - Vector2i(size / 2, size / 2)
	for x in size:
		for y in size:
			var c := c0 + Vector2i(x, y)
			if not sim.in_map(c) or (sim.is_blocked(c) and not terrain.prop_cells.has(c)):
				return false
	return true


## Убирает кусты и камни с участка (и из картинки, и из правил).
static func _clear_props(sim: Sim, terrain: Terrain, q: Vector2, size: int) -> void:
	var c0 := Vector2i(q) - Vector2i(size / 2, size / 2)
	var gone: Dictionary = {}
	for x in size:
		for y in size:
			var c := c0 + Vector2i(x, y)
			if terrain.prop_cells.has(c):
				terrain.prop_cells.erase(c)
				gone[c] = true
				sim._set_solid(Rect2i(c, Vector2i.ONE), false)
	if not gone.is_empty():
		terrain.props = terrain.props.filter(func(pr) -> bool: return not gone.has(Vector2i(floori(pr["pos"].x), floori(pr["pos"].y))))


static func _place_mine(sim: Sim, p: Vector2, gold: int = 0) -> bool:
	var cell := Vector2i(p) - Vector2i(1, 1)
	if not sim.can_place(5, cell - Vector2i(1, 1)):
		return false
	var id := sim.add_resource("gold", cell, 3)
	if gold > 0:
		sim.resources[id]["amount"] = gold
		sim.resources[id]["max"] = gold
	return true


## Кольцо леса вокруг поляны базы: от r до r+3 клеток от её середины, края неровные.
## exits — углы выходов (от направления fwd), там кольцо разорвано на ~6 клеток.
static func _wall(sim: Sim, terrain: Terrain, glade: Vector2, fwd: Vector2, r: float, exits: Array, phase: float, keep: Array) -> void:
	var thick := 3.4
	var reach := r + thick + 2.5
	for x in range(floori(glade.x - reach), ceili(glade.x + reach) + 1):
		for y in range(floori(glade.y - reach), ceili(glade.y + reach) + 1):
			var c := Vector2i(x, y)
			if not sim.in_map(c) or sim.is_blocked(c):
				continue
			var q := Vector2(c) + Vector2(0.5, 0.5)
			var a := fwd.angle_to(q - glade)
			var inner := r + 1.3 * sin(a * 3.0 + phase) + 0.7 * sin(a * 7.0 + phase * 1.7)
			var d := q.distance_to(glade)
			if d < inner or d > inner + thick:
				continue
			var gap := false
			for ex in exits:
				if absf(angle_difference(a, float(ex))) * d < 3.2:      # ширина выхода ~6 клеток
					gap = true
			if gap:
				continue
			for kp in keep:
				if q.distance_to(kp[0]) < float(kp[1]):
					gap = true
			if not gap:
				sim.add_resource("tree", c, 1)


static func _forest(sim: Sim, rng: RandomNumberGenerator, center: Vector2, count: int, spread: float, keep: Array) -> void:
	for i in count:
		var t := Vector2i(center + Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread * 0.8)))
		var ok := sim.in_map(t) and not sim.is_blocked(t)
		for k in keep:
			if Vector2(t).distance_to(k[0]) < float(k[1]):
				ok = false
		if ok:
			sim.add_resource("tree", t, 1)


static func _camp(sim: Sim, rng: RandomNumberGenerator, neutral: Dictionary, camp_id: int, pos: Vector2, level: int) -> void:
	var options: Array = []
	for c in neutral["camps"]:
		if int(c["level"]) == level:
			options.append(c)
	if options.is_empty():
		return
	var camp: Dictionary = options[rng.randi() % options.size()]
	var keys: Array = []
	for key in camp["units"]:
		for i in int(camp["units"][key]):
			keys.append(key)
	var face := Vector2.RIGHT.rotated(rng.randf() * TAU)
	for i in keys.size():
		var off := Vector2.ZERO if keys.size() == 1 else face.rotated(TAU * i / keys.size()) * 1.5
		var id := sim.spawn_unit(Sim.NEUTRAL, String(keys[i]), neutral["units"][keys[i]], pos + off, false)
		var u: Dictionary = sim.units[id]
		u["camp"] = camp_id
		u["camp_level"] = level      # от уровня лагеря зависит награда за его зачистку
		u["home"] = u["pos"]
		u["facing"] = off.normalized() if off != Vector2.ZERO else face
