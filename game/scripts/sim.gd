extends RefCounted
## Симуляция игры: ТОЛЬКО правила, никакой графики.
## Работает фиксированными шагами (тиками). Изменить состояние игры можно
## единственным способом: отправить команду через push_command().
## Так же потом будут приходить команды по сети от других игроков.

const TICK_RATE := 10
const TICK_DT := 1.0 / TICK_RATE
const MAP_SIZE := 96        # сторона маленькой карты; настоящий размер партии — map_size
const MAX_PLAYERS := 8
const NEUTRAL := 8          # номер «игрока», которому принадлежат нейтральные юниты (игроки — 0…7)
const START_GOLD := 500
const START_WOOD := 150
const GOLD_TIME := 1.0      # секунд на одну «ходку» в руднике
const WOOD_TIME := 4.0      # секунд на рубку одной охапки
const GOLD_IN_MINE := 12000
const WOOD_IN_TREE := 300  # одно дерево — около 30 ходок рабочего
const REACH := 0.9          # на каком расстоянии рабочий «достаёт» до цели
const ACQUIRE := 7.5        # на каком расстоянии войска сами замечают врага
const LEASH := 15.0         # как далеко нейтралы уходят от своего лагеря
const QUEUE_MAX := 5
const MAX_HERO_LEVEL := 10
const MAX_ITEMS := 6
const MAX_RANK := 3
const LEARN_LEVELS := [1, 2, 3, 4, 6]   # с какого уровня героя открывается 1-я…5-я способность
const RANK_STEP := 2        # каждый следующий ранг способности — ещё через 2 уровня героя
const CRIT_MUL := 2.0
const HOLY_VS_UNDEAD := 1.75      # во сколько раз святой урон сильнее против нежити
const DRAGON_MODS := {"damage_mul": 1.3, "armor_add": 4.0, "hp_regen": 6.0, "speed_mul": 1.1}
const PICKUP_RANGE := 1.0
const SHOP_RANGE := 7.0
const XP_RADIUS := 12.0     # герой получает опыт за врагов, погибших не дальше этого
const STAT_KEYS := ["damage", "attack_cooldown", "range", "armor", "speed"]

var map_size: int = MAP_SIZE
var biome := "meadow"             # местность карты (луга, степь, осень, зима, озёра, нагорье)
var tick: int = 0
var seed_value: int = 0
var units: Dictionary = {}        # id -> состояние юнита
var buildings: Dictionary = {}    # id -> состояние здания
var resources: Dictionary = {}    # id -> дерево или рудник
var projectiles: Dictionary = {}  # id -> летящая стрела или камень
var loot: Dictionary = {}         # id -> предмет, лежащий на земле {id, key, pos}
var players: Dictionary = {}      # номер игрока -> {race, data, gold, wood, supply_used, supply_cap}
var events: Array = []            # что произошло; читает и очищает графика
var combat: Dictionary = {}       # таблица множителей урона (data/combat.json)
var game_over := false

var _next_id: int = 1
var _pending: Array = []
var _grid := AStarGrid2D.new()
var _swim := AStarGrid2D.new()    # та же карта для пловцов (наги): вода для них проходима
var _water: Dictionary = {}       # клетки с водой (непроходимы для всех, кроме пловцов)
# те же непроходимые клетки простым массивом (1 — занята): спросить его дешевле, чем объект поиска пути,
# и так можно с нескольких ядер сразу (вызовы методов объектов ядра выстраивают в очередь)
var _solid := PackedByteArray()
var _solid_sw := PackedByteArray()
var _side := PackedInt32Array()   # сторона каждого игрока: у союзников одно и то же число
var corpses: Dictionary = {}      # id -> {id, pos, expires}: тела павших (ими кормятся гули, их поднимают некроманты)
var high_cells: Dictionary = {}   # клетки на вершинах возвышенностей (строятся из зерна карты, у всех одинаковые)
const HIGH_RANGE := 1.0           # стрелки на возвышенности бьют дальше
const HIGH_SIGHT := 2.5           # и видно с неё дальше (fog.gd)


func _init() -> void:
	set_map_size(MAP_SIZE)
	_update_sides()


## Команда игрока: 0 — сам за себя, 1…4 — номер команды (союзники не бьют друг друга,
## лечат и усиливают друг друга аурами и побеждают вместе).
func set_team(player: int, team: int) -> void:
	players[player]["team"] = team
	_update_sides()


func team_of(player: int) -> int:
	return int(players[player].get("team", 0)) if players.has(player) else 0


func _update_sides() -> void:
	_side.resize(MAX_PLAYERS + 1)
	for i in MAX_PLAYERS + 1:
		_side[i] = 1000 + i
	for p in players:
		if int(p) != NEUTRAL and team_of(int(p)) > 0:
			_side[int(p)] = team_of(int(p))


## Враги ли эти игроки (нейтралы враги всем).
func enemies(a: int, b: int) -> bool:
	return _side[a] != _side[b]


## Союзники — разные игроки одной команды.
func allies(a: int, b: int) -> bool:
	return a != b and _side[a] == _side[b]


## Задаёт сторону карты (96, 192 или 272). Вызывается до разметки непроходимых клеток.
func set_map_size(n: int) -> void:
	map_size = n
	for g in [_grid, _swim]:
		g.region = Rect2i(0, 0, n, n)
		g.cell_size = Vector2.ONE
		g.offset = Vector2(0.5, 0.5)
		g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		# восьминаправленная оценка точнее евклидовой для такой сетки: те же пути на ~15% быстрее
		# (поиск «прыжками» пробовали — на наших картах он медленнее)
		g.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
		g.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
		g.update()
	_solid = PackedByteArray()
	_solid.resize(n * n)
	_solid_sw = PackedByteArray()
	_solid_sw.resize(n * n)


# ---------- создание мира ----------

func add_player(player: int, race: Dictionary) -> void:
	players[player] = {
		"race": String(race["id"]), "data": race,
		"gold": START_GOLD, "wood": START_WOOD, "supply_used": 0, "supply_cap": 0, "heroes": {}, "upgrades": {}, "research_wip": {},
		"stats": {"killed": 0, "lost": 0, "razed": 0, "gold": 0, "wood": 0, "trained": 0, "built": 0},
	}


## water — клетка непроходима только из-за воды: пловцы (наги) по ней ходят.
func block_cell(cell: Vector2i, water := false) -> void:
	_grid.set_point_solid(cell, true)
	_solid[cell.y * map_size + cell.x] = 1
	if water:
		_water[cell] = true
	else:
		_swim.set_point_solid(cell, true)
		_solid_sw[cell.y * map_size + cell.x] = 1


func _set_solid(rect: Rect2i, solid: bool) -> void:
	for x in range(rect.position.x, rect.end.x):
		for y in range(rect.position.y, rect.end.y):
			if in_map(Vector2i(x, y)):
				_grid.set_point_solid(Vector2i(x, y), solid)
				_swim.set_point_solid(Vector2i(x, y), solid)
				_solid[y * map_size + x] = 1 if solid else 0
				_solid_sw[y * map_size + x] = 1 if solid else 0


func in_water(p: Vector2) -> bool:
	return _water.has(to_cell(p))


## ---------- особенности рас ----------
## Свойство юнита берётся из его таблицы (def) или из общих свойств расы (unit_traits —
## у всех бойцов расы, кроме рабочих). Так у каждой расы свои механики.

func has_trait(u: Dictionary, key: String) -> bool:
	if u["def"].has(key):
		return true
	var tr = u.get("_tr")      # расовые свойства юнита считаются один раз и запоминаются в нём
	if tr == null:
		tr = {}
		if not is_worker(u) and players.has(u["player"]):
			for k in players[u["player"]]["data"].get("unit_traits", {}):
				if not (u["def"].get("lacks", []) as Array).has(k):      # lacks: чего этот юнит расы не умеет
					tr[k] = true
		u["_tr"] = tr
	return (tr as Dictionary).has(key)


func race_trait(player: int, key: String) -> bool:
	return players.has(player) and (players[player]["data"].get("traits", {}) as Dictionary).has(key)


func swims(u: Dictionary) -> bool:
	if u["def"].has("amphibious"):      # без вызова has_trait со строкой: его зовут все ядра на каждом шаге
		return true
	var tr = u.get("_tr")
	return has_trait(u, "amphibious") if tr == null else (tr as Dictionary).has("amphibious")


const WATER_REGEN := 5.0          # наги: здоровья в секунду, пока в воде
const FEAST_HEAL := 0.12          # огры: доля здоровья, которую возвращает добивание
const RAGE_MAX := 5               # огры: сколько раз копится ярость
const ENTRENCH_TICKS := 20        # гномы: через сколько тиков на месте боец окапывается
const ENTRENCH_MODS := {"armor_add": 3.0, "damage_mul": 1.15}
const CORPSE_TIME := 450          # тела лежат 45 секунд
const MILITIA_RADIUS := 14.0
const MILITIA_MODS := {"damage_add": 12.0, "armor_add": 3.0, "speed_mul": 1.1}


func _has_buff(u: Dictionary, key: String) -> bool:
	for b in u["buffs"]:
		if String(b["key"]) == key and tick < int(b["until"]):
			return true
	return false


## Ярость огров: каждый удар — ещё одна ступень (до RAGE_MAX), и удары чаще и сильнее.
## Без новых ударов 4 секунды ярость спадает.
func _add_rage(u: Dictionary) -> void:
	var n := mini(RAGE_MAX, int(u.get("rage", 0)) + 1) if _has_buff(u, "rage") else 1
	u["rage"] = n
	_add_buff(u, "rage", 4.0, {"cooldown_mul": pow(0.93, n), "damage_mul": 1.0 + 0.04 * n})


## Человеческое ополчение кончилось: рабочие возвращаются к прежнему делу.
func _end_militia(u: Dictionary) -> void:
	var o: Dictionary = u["pre_militia"]
	u.erase("pre_militia")
	var kind := String(o.get("type", "idle"))
	if kind in ["gather", "return"] and resources.has(int(o.get("target", -1))):
		var r: Dictionary = resources[int(o["target"])]
		_start_gather(u, int(r["id"]), String(r["kind"]), r["pos"])
	elif String(u["order"].get("type")) != "attack":
		_idle(u)


## {"type": "action", "player": 0, "building": id, "action": "militia"} — особые действия зданий.
func _cmd_action(cmd: Dictionary) -> void:
	var player := int(cmd["player"])
	var b = buildings.get(cmd.get("building"))
	var key := String(cmd.get("action", ""))
	if b == null or int(b["player"]) != player or not b["done"]:
		return
	var act: Dictionary = {}
	for a in b["def"].get("actions", []):
		if String(a["key"]) == key:
			act = a
	if act.is_empty():
		return
	var cds: Dictionary = b.get("cds", {}) if b.get("cds") is Dictionary else {}
	if tick < int(cds.get(key, 0)):
		_msg(player, "%s ещё не готово: %d с" % [act["name"], ceili((int(cds[key]) - tick) * TICK_DT)])
		return
	cds[key] = tick + int(float(act.get("cooldown", 60)) * TICK_RATE)
	b["cds"] = cds
	match key:
		"militia":      # рабочие у ратуши берут оружие
			var n := 0
			for id in _units_near(b["pos"], MILITIA_RADIUS):
				var w: Dictionary = units[id]
				if int(w["player"]) != player or not is_worker(w):
					continue
				if not w.has("pre_militia"):
					w["pre_militia"] = (w["order"] as Dictionary).duplicate()
				_add_buff(w, "militia", float(act.get("duration", 45)), MILITIA_MODS)
				w["carry"] = 0
				_idle(w)
				n += 1
			events.append({"type": "blast", "pos": b["pos"], "radius": MILITIA_RADIUS, "color": "#ff9a3a"})
			events.append({"type": "horn", "player": player, "pos": b["pos"]})
			_msg(player, "К оружию! Рабочих в ополчении: %d (на %d с)" % [n, int(act.get("duration", 45))])


## Тела павших. Гули (нежить) подкрепляются ими, некроманты поднимают из них скелетов.
func _add_corpse(t: Dictionary) -> void:
	if int(t["expires"]) >= 0 or String(t["def"].get("role", "")) in ["ward", "summon"]:
		return
	corpses[t["id"]] = {"id": t["id"], "pos": t["pos"], "expires": tick + CORPSE_TIME}


func _remove_corpse(id: int, how: String) -> void:
	if corpses.has(id):
		events.append({"type": "corpse_removed", "id": id, "how": how, "pos": corpses[id]["pos"]})
		corpses.erase(id)


func nearest_corpse(pos: Vector2, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	var ids: Array = corpses.keys()
	ids.sort()
	for id in ids:
		var d: float = pos.distance_to(corpses[id]["pos"])
		if d < best_d:
			best_d = d
			best = int(id)
	return best


## Раненый гуль без дела ищет тело неподалёку, чтобы подкрепиться.
func _seek_corpse(u: Dictionary) -> void:
	if (tick + int(u["id"])) % 5 != 0 or float(u["hp"]) > float(u["max_hp"]) * 0.85:
		return
	var c := nearest_corpse(u["pos"], 7.0)
	if c < 0:
		return
	u["order"] = {"type": "eat", "target": c, "left": int(float(u["def"]["cannibal"].get("duration", 4.0)) * TICK_RATE)}
	_path_to(u, corpses[c]["pos"])


func _do_eat(u: Dictionary, o: Dictionary) -> void:
	var c = corpses.get(int(o["target"]))
	if c == null or _nearest_enemy(u["pos"], int(u["player"]), 5.0, false) >= 0:
		_idle(u)      # тело исчезло или рядом враг — не до еды
		return
	if (u["pos"] as Vector2).distance_to(c["pos"]) > float(u["radius"]) + 0.7:
		if not is_moving(u):
			_path_to(u, c["pos"])
		return
	_stop_path(u)
	u["busy"] = true
	u["facing"] = ((c["pos"] as Vector2) - (u["pos"] as Vector2)).normalized() if (c["pos"] as Vector2).distance_to(u["pos"]) > 0.05 else u["facing"]
	u["hp"] = minf(float(u["max_hp"]), float(u["hp"]) + float(u["def"]["cannibal"].get("heal", 20.0)) * TICK_DT)
	o["left"] = int(o["left"]) - 1
	if int(o["left"]) <= 0 or float(u["hp"]) >= float(u["max_hp"]):
		_remove_corpse(int(o["target"]), "eaten")
		_idle(u)


## {"type": "repair", "player": 0, "units": [рабочие], "target": id здания} — только у рас с ремонтом (люди).
func _cmd_repair(cmd: Dictionary) -> void:
	var player := int(cmd["player"])
	var b = buildings.get(cmd.get("target"))
	if b == null or not race_trait(player, "repair") or enemies(int(b["player"]), player) or int(b["player"]) == NEUTRAL or not b["done"]:
		return
	for id in _owned(cmd, true):
		units[id]["order"] = {"type": "repair", "target": int(b["id"])}
		units[id]["wait"] = 0
		_go_adjacent(units[id], _rect(b))


## Ремонт: прочность восстанавливается чуть медленнее стройки; полный ремонт стоит треть цены здания.
func _do_repair(u: Dictionary, o: Dictionary) -> void:
	var b = buildings.get(o["target"])
	if b == null or float(b["hp"]) >= float(b["max_hp"]):
		_idle(u)
		return
	if not _near(u, _rect(b)):
		_repath(u, _rect(b))
		return
	_stop_path(u)
	u["busy"] = true
	u["facing"] = ((b["pos"] as Vector2) - (u["pos"] as Vector2)).normalized()
	var bt := maxf(5.0, float(b["def"].get("build_time", 30)))
	var heal := float(b["max_hp"]) / (bt * 1.3) * TICK_DT
	var price := float(b["def"].get("cost", {}).get("gold", 0)) * 0.33 * heal / float(b["max_hp"])
	u["repair_debt"] = float(u.get("repair_debt", 0.0)) + price
	if float(u["repair_debt"]) >= 1.0:
		var pay := int(u["repair_debt"])
		if int(players[u["player"]]["gold"]) < pay:
			_msg(int(u["player"]), "Не хватает золота на ремонт")
			_idle(u)
			return
		players[u["player"]]["gold"] -= pay
		u["repair_debt"] = float(u["repair_debt"]) - pay
	b["hp"] = minf(float(b["max_hp"]), float(b["hp"]) + heal)
	if (tick + int(u["id"])) % 6 == 0:
		events.append({"type": "repair_spark", "id": b["id"], "pos": u["pos"]})


# ---------- рабочие убегают от нападения ----------

const FLEE_TICKS := 30            # сколько бежит рабочий, прежде чем вернуться к делу
const FLEE_DIST := 7.0
const LARGE_RADIUS := 0.62        # «крупные» цели (всадники, великаны, машины) — против них хороши копья


## По рабочему ударили: он бросает дело и отбегает от обидчика (в сторону своей базы,
## если это возможно). Прямой приказ игрока «иди туда» он не нарушает.
func _flee(u: Dictionary, src: Dictionary) -> void:
	var o: Dictionary = u["order"]
	var kind := String(o.get("type", "idle"))
	if kind == "attack" or (kind == "move" and o.get("manual", false)):
		return      # игрок сам велел драться или бежать в определённое место
	var resume: Dictionary = o.get("resume", {"type": "idle"}) if kind == "flee" else o
	if kind == "flee" and tick < int(o.get("repath", 0)):
		o["until"] = tick + FLEE_TICKS      # продолжают бить — бежит дальше
		return
	if kind in ["idle", "move", "home", "follow", "attack", "amove"]:
		resume = {"type": "idle"}
	var away: Vector2 = (u["pos"] as Vector2) - (src["pos"] as Vector2)
	away = away.normalized() if away.length() > 0.05 else (u["facing"] as Vector2) * -1.0
	var hall := nearest_hall(u)
	var home_dir := away
	if hall >= 0:
		var hd: Vector2 = (buildings[hall]["pos"] as Vector2) - (u["pos"] as Vector2)
		if hd.length() > 1.0 and hd.normalized().dot(away) > -0.2:
			home_dir = hd.normalized()      # к своей базе, если она не за спиной врага
	var best := Vector2(-1, -1)
	var best_score := INF
	for a in [0.0, 0.45, -0.45, 0.9, -0.9, 1.4, -1.4, 2.0, -2.0]:
		var spot: Vector2 = (u["pos"] as Vector2) + away.rotated(a) * FLEE_DIST
		var cell := to_cell(spot)
		if not in_map(cell) or is_blocked(cell):
			continue
		var score: float = absf(a) - away.rotated(a).dot(home_dir) * 0.6
		if score < best_score:
			best_score = score
			best = spot
	if best.x < 0.0:
		return
	u["order"] = {"type": "flee", "until": tick + FLEE_TICKS, "repath": tick + 10, "resume": resume}
	u["swing"] = -1.0
	_path_to(u, best)
	if kind != "flee":
		events.append({"type": "flee", "id": u["id"], "player": u["player"], "pos": u["pos"]})


## Рабочий отдышался: возвращается к тому, чем был занят.
func _resume_work(u: Dictionary, o: Dictionary) -> void:
	match String(o.get("type", "idle")):
		"gather":
			_start_gather(u, int(o["target"]), String(o["kind"]), o["pos"])
		"return":
			_start_return(u, int(o["target"]), String(o["kind"]), o["pos"])
		"build":
			if buildings.has(int(o["target"])) and not buildings[int(o["target"])]["done"]:
				_start_build(u, int(o["target"]))
			else:
				_idle(u)
		"repair":
			if buildings.has(int(o["target"])):
				u["order"] = {"type": "repair", "target": int(o["target"])}
				u["wait"] = 0
				_go_adjacent(u, _rect(buildings[int(o["target"])]))
			else:
				_idle(u)
		_:
			_idle(u)


# ---------- нейтралы стерегут своё ----------

const GUARD_BUILD_RADIUS := 7.5   # стройка ближе этого к лагерю будит его
const GUARD_MINE_RADIUS := 8.0    # кто добывает золото из охраняемого рудника, на того нападают


## Лагерь нейтралов, чей дом ближе radius к pos, нападает на target
## (рабочего у рудника или на стройку).
func _wake_guards(pos: Vector2, radius: float, target: int) -> bool:
	var woke := false
	for id in _units_near(pos, radius + LEASH * 0.5):
		var n: Dictionary = units[id]
		if int(n["player"]) != NEUTRAL or n.get("raider", false) or n.has("caravan") or int(n["camp"]) < 0 or int(n["camp"]) >= 300000:
			continue
		if float(n["damage"]) <= 0.0 or String(n["order"].get("type")) == "attack" or (n["home"] as Vector2).distance_to(pos) > radius:
			continue
		_order_attack(n, target, {})
		woke = true
	return woke


## Есть ли рядом живой лагерь нейтралов, который проснётся от стройки.
func guarded_spot(pos: Vector2, radius: float) -> bool:
	for id in _units_near(pos, radius + LEASH * 0.5):
		var n: Dictionary = units[id]
		if int(n["player"]) == NEUTRAL and int(n["camp"]) >= 0 and int(n["camp"]) < 300000 and not n.get("raider", false) \
				and float(n["damage"]) > 0.0 and (n["home"] as Vector2).distance_to(pos) <= radius:
			return true
	return false


## Стройка у лагеря: нейтралы бросаются на строителя (или на само здание).
func _guards_vs_site(b: Dictionary) -> void:
	if (tick + int(b["id"])) % 5 != 0:
		return
	var target := int(b["id"])
	var best := 4.5 + float(b["radius"])
	for id in _units_near(b["pos"], best):
		if int(units[id]["player"]) == int(b["player"]):
			var d: float = (units[id]["pos"] as Vector2).distance_to(b["pos"])
			if d < best:
				best = d
				target = int(id)
	if _wake_guards(b["pos"], GUARD_BUILD_RADIUS + float(b["radius"]), target) and not b.get("warned", false):
		b["warned"] = true
		_msg(int(b["player"]), "Нейтралы заметили стройку рядом со своим лагерем и нападают!")


# ---------- улучшения ----------

## Действует ли улучшение на этого юнита: «units» — только перечисленные, «army» — все, кроме рабочих.
func upgrade_applies(u: Dictionary, up: Dictionary) -> bool:
	if up.has("units"):
		return (up["units"] as Array).has(String(u["key"]))
	if up.get("army", false):
		return not is_worker(u)
	return true


## Прибавка к здоровью от изученных улучшений (новым юнитам — при появлении).
func _upgrade_hp(u: Dictionary) -> void:
	if not players.has(u["player"]) or int(u["player"]) == NEUTRAL:
		return
	var p: Dictionary = players[u["player"]]
	for key in p.get("upgrades", {}):
		var up: Dictionary = p["data"]["upgrades"][key]
		var add := float(up.get("mods", {}).get("hp_add", 0)) * int(p["upgrades"][key])
		if add > 0.0 and upgrade_applies(u, up):
			u["max_hp"] = float(u["max_hp"]) + add
			u["hp"] = float(u["hp"]) + add


## Сколько добавляют к ноше рабочего улучшения «кирок».
func carry_bonus(u: Dictionary) -> int:
	var p: Dictionary = players[u["player"]]
	var n := 0
	for key in p.get("upgrades", {}):
		var up: Dictionary = p["data"]["upgrades"][key]
		if up.get("mods", {}).has("carry_add") and upgrade_applies(u, up):
			n += int(up["mods"]["carry_add"]) * int(p["upgrades"][key])
	return n


# ---------- особые свойства бойцов ----------

## Взрыв: урон врагам вокруг (подрывник, поганище при смерти).
func _explode(u: Dictionary, spec: Dictionary, pos: Vector2) -> void:
	var r := float(spec.get("radius", 2.0))
	var player := int(u["player"])
	events.append({"type": "blast", "pos": pos, "radius": r, "color": String(spec.get("color", "#ff9a3a"))})
	events.append({"type": "explosion", "pos": pos, "color": String(spec.get("color", "#ff9a3a"))})
	for id in _units_near(pos, r):
		if units.has(id) and enemies(int(units[id]["player"]), player):
			_damage(units[id], float(spec.get("damage", 100)), String(spec.get("type", "siege")), int(u["id"]), player)
	var ids: Array = buildings.keys()
	ids.sort()
	for bid in ids:
		if not buildings.has(bid):
			continue
		var b: Dictionary = buildings[bid]
		if enemies(int(b["player"]), player) and int(b["player"]) != NEUTRAL and (b["pos"] as Vector2).distance_to(pos) <= r + float(b["radius"]):
			_damage(b, float(spec.get("damage", 100)), String(spec.get("type", "siege")), int(u["id"]), player)


## Яд: отравленный теряет здоровье каждую секунду (у отравителя — def.poison).
func _poison(t: Dictionary, spec: Dictionary, player: int) -> void:
	_add_buff(t, "poison", float(spec.get("duration", 4.0)), {"hp_regen": -float(spec.get("dps", 6.0))})
	t["poison_by"] = player


func _grid_for(swim: bool) -> AStarGrid2D:
	return _swim if swim else _grid


func add_resource(kind: String, cell: Vector2i, size: int = 1) -> int:
	var id := _new_id()
	_set_solid(Rect2i(cell, Vector2i(size, size)), true)
	resources[id] = {
		"id": id, "kind": kind, "cell": cell, "size": size,
		"pos": Vector2(cell) + Vector2(size, size) * 0.5,
		"amount": GOLD_IN_MINE if kind == "gold" else WOOD_IN_TREE,
		"max": GOLD_IN_MINE if kind == "gold" else WOOD_IN_TREE,
	}
	return id


func spawn_building(player: int, key: String, def: Dictionary, cell: Vector2i, done: bool = true) -> int:
	var size: int = int(def.get("size", 2))
	var id := _new_id()
	_set_solid(Rect2i(cell, Vector2i(size, size)), true)
	var max_hp := float(def.get("hp", 100))
	_bindex_dirty = true
	buildings[id] = {
		"id": id, "is_building": true, "player": player, "key": key, "def": def,
		"cell": cell, "size": size, "max_hp": max_hp,
		"hp": max_hp if done else max_hp * 0.1,
		"pos": Vector2(cell) + Vector2(size, size) * 0.5,
		"radius": size * 0.5,
		"armor": float(def.get("armor", 0)), "armor_type": String(def.get("armor_type", "fortified")),
		"done": done, "progress": 1.0 if done else 0.0,
		"queue": [], "cd": 0.0, "rally": null,
	}
	if done:
		players[player]["supply_cap"] += int(def.get("supply_given", 0))
	events.append({"type": "building_added", "id": id})
	return id


## Характеристики копируются из таблицы в самого юнита, поэтому позже их можно
## менять у отдельного юнита (улучшения, ауры, предметы), не трогая таблицу.
func spawn_unit(player: int, key: String, def: Dictionary, pos: Vector2, count_supply: bool = true) -> int:
	var id := _new_id()
	var swim := (race_trait(player, "amphibious") or (players.has(player) and (players[player]["data"].get("unit_traits", {}) as Dictionary).has("amphibious"))) and String(def.get("role", "")) != "worker"
	var p := cell_center(nearest_free_cell(to_cell(pos), {}, swim))
	var u := {
		"id": id, "is_building": false, "player": player, "key": key, "def": def,
		"pos": p, "prev_pos": p, "facing": Vector2(0, 1),
		"path": PackedVector2Array(), "path_i": 0,
		"radius": float(def.get("radius", 0.4)),
		"level": int(def.get("level", 1)),
		"hp": float(def.get("hp", 100)), "max_hp": float(def.get("hp", 100)),
		"mana": float(def.get("mana", 0)), "max_mana": float(def.get("mana", 0)),
		"mana_regen": float(def.get("mana_regen", 0)),
		"armor_type": String(def.get("armor_type", "medium")),
		"damage_type": String(def.get("damage_type", "normal")),
		"bounty": int(def.get("bounty", 0)),
		"order": {"type": "idle"}, "carry": 0, "carry_kind": "", "busy": false, "wait": 0,
		"cd": 0.0, "swing": -1.0, "swing_target": -1, "camp": -1, "home": p,
		"hero": bool(def.get("hero", false)), "buffs": [], "stun": 0, "expires": -1, "cds": {},
		"hp_regen": 0.0, "base": {}, "items": [],
		"crit": 0.0, "evasion": 0.0, "lifesteal": 0.0, "thorns": 0.0, "dmg_taken": 1.0,
	}
	for k in STAT_KEYS:
		u[k] = float(def.get(k, 0))
		u["base"][k] = u[k]
	u["base"]["mana_regen"] = u["mana_regen"]
	if u["hero"]:
		u["level"] = 1     # у героев свой уровень: растёт с опытом до MAX_HERO_LEVEL
		u["xp"] = 0
		u["skills"] = {}   # ключ способности -> изученный ранг (1…MAX_RANK)
	units[id] = u
	_upgrade_hp(u)
	if count_supply:
		players[player]["supply_used"] += int(def.get("supply", 0))
	events.append({"type": "unit_added", "id": id})
	return id


# ---------- команды ----------

## Команда — обычный словарь. Виды команд:
## {"type": "move",   "player": 0, "units": [ids], "target": Vector2}
## {"type": "amove",  ...то же...}                      идти и атаковать всех по дороге
## {"type": "attack", "player": 0, "units": [ids], "target": id юнита или здания}
## {"type": "stop",   "player": 0, "units": [ids]}
## {"type": "gather", "player": 0, "units": [ids], "target": id ресурса}
## {"type": "build",  "player": 0, "units": [ids], "building": "supply", "cell": Vector2i}
## {"type": "resume", "player": 0, "units": [ids], "target": id недостроенного здания}
## {"type": "train",  "player": 0, "building": id, "unit": "melee"}
## {"type": "learn",  "player": 0, "unit": id героя, "ability": "fireball"}
## {"type": "use_item" | "drop_item" | "destroy_item", "player": 0, "unit": id героя, "slot": 0…5}
## {"type": "pickup", "player": 0, "unit": id героя, "target": id предмета на земле}
func push_command(cmd: Dictionary) -> void:
	cmd["tick"] = tick + 1
	_pending.append(cmd)


func _execute(cmd: Dictionary) -> void:
	match String(cmd.get("type", "")):
		"move":
			_cmd_move(cmd, "move")
		"amove":
			_cmd_move(cmd, "amove")
		"attack":
			var t = entity(int(cmd.get("target", -1)))
			if t != null and enemies(int(t["player"]), int(cmd["player"])) and not t["def"].get("invulnerable", false) and not t.has("merc_idle"):
				for id in _owned(cmd):
					if float(units[id]["damage"]) > 0.0:
						_order_attack(units[id], int(t["id"]), {})
		"stop":
			for id in _owned(cmd):
				_idle(units[id])
		"gather":
			_cmd_gather(cmd)
		"build":
			_cmd_build(cmd)
		"resume":
			var b = buildings.get(cmd.get("target"))
			if b != null and int(b["player"]) == int(cmd["player"]) and not b["done"]:
				for id in _owned(cmd, true):
					_start_build(units[id], int(b["id"]))
		"train":
			_cmd_train(cmd)
		"cast":
			_cmd_cast(cmd)
		"research":
			_cmd_research(cmd)
		"buy":
			_cmd_buy(cmd)
		"cancel":
			_cmd_cancel(cmd)
		"learn":
			_cmd_learn(cmd)
		"hire":
			_cmd_hire(cmd)
		"use_item":
			_cmd_use_item(cmd)
		"drop_item", "destroy_item":
			_cmd_drop_item(cmd)
		"pickup":
			var hu = _my_hero(cmd)
			if hu != null and loot.has(cmd.get("target")):
				hu["order"] = {"type": "pickup", "target": int(cmd["target"])}
				hu["wait"] = 0
				hu["swing"] = -1.0
				_path_to(hu, loot[cmd["target"]]["pos"])
		"rally":      # точка сбора: место на земле или объект (рудник, дерево, юнит, здание)
			var rb = buildings.get(cmd.get("building"))
			if rb != null and int(rb["player"]) == int(cmd["player"]):
				rb["rally"] = cmd["pos"]
				rb["rally_target"] = int(cmd.get("target", -1))
		"gift":       # передать союзнику золото и дерево: {"to": игрок, "gold": n, "wood": n}
			_cmd_gift(cmd)
		"repair":     # люди: рабочие чинят повреждённое здание
			_cmd_repair(cmd)
		"action":     # особое действие здания (ополчение у людей)
			_cmd_action(cmd)
		"follow":     # идти следом за своим юнитом
			var leader = units.get(cmd.get("target"))
			if leader != null and not enemies(int(leader["player"]), int(cmd["player"])):
				for id in _owned(cmd):
					if id != int(leader["id"]):
						units[id]["order"] = {"type": "follow", "target": int(leader["id"])}
						units[id]["wait"] = 0
						units[id]["swing"] = -1.0


func _cmd_gift(cmd: Dictionary) -> void:
	var from := int(cmd["player"])
	var to := int(cmd.get("to", -1))
	if not players.has(to) or not allies(from, to) or players[to].get("defeated", false) or players[from].get("defeated", false):
		return
	var gold := clampi(int(cmd.get("gold", 0)), 0, int(players[from]["gold"]))
	var wood := clampi(int(cmd.get("wood", 0)), 0, int(players[from]["wood"]))
	if gold + wood <= 0:
		_msg(from, "Нечего передать")
		return
	players[from]["gold"] -= gold
	players[from]["wood"] -= wood
	players[to]["gold"] += gold
	players[to]["wood"] += wood
	events.append({"type": "gift", "from": from, "to": to, "gold": gold, "wood": wood})


## Юниты из команды, которые действительно принадлежат игроку (защита от читов).
func _owned(cmd: Dictionary, workers_only: bool = false) -> Array:
	var ids: Array = []
	for id in cmd.get("units", []):
		if units.has(id) and int(units[id]["player"]) == int(cmd.get("player", -1)):
			if not workers_only or is_worker(units[id]):
				ids.append(id)
	ids.sort()
	return ids


func is_worker(u: Dictionary) -> bool:
	return String(u["def"].get("role", "")) == "worker"


func entity(id: int):
	if units.has(id):
		return units[id]
	return buildings.get(id)


func _cmd_move(cmd: Dictionary, kind: String) -> void:
	var ids := _owned(cmd).filter(func(x) -> bool: return float(units[x]["base"]["speed"]) > 0.0)      # глаза стоят на месте
	if ids.is_empty():
		return
	var target: Vector2 = cmd["target"]
	# Отряд встаёт строем, развёрнутым лицом по ходу движения: ближний бой впереди,
	# стрелки за ними, целители и машины сзади. Места раздаются по тому, кто где стоит
	# (левый — на левое место), поэтому юниты не перебегают друг другу дорогу.
	var spacing := 0.0
	var center := Vector2.ZERO
	for id in ids:
		spacing = maxf(spacing, float(units[id]["radius"]) * 2.0 + 0.3)
		center += units[id]["pos"]
	center /= float(ids.size())
	var fwd := target - center
	fwd = fwd / fwd.length() if fwd.length() > 0.5 else Vector2(0, 1)
	var side := Vector2(-fwd.y, fwd.x)
	var cols: int = mini(ids.size(), int(ceil(sqrt(float(ids.size()) * 1.8))))
	var rows: int = int(ceil(float(ids.size()) / cols))
	var order: Array = ids.duplicate()
	order.sort_custom(func(a, b) -> bool:
		var ra := _rank_in_line(units[a])
		var rb := _rank_in_line(units[b])
		if ra != rb:
			return ra < rb
		var da: float = (units[a]["pos"] as Vector2).distance_squared_to(target)
		var db: float = (units[b]["pos"] as Vector2).distance_squared_to(target)
		return da < db if da != db else int(a) < int(b))
	var slots: Dictionary = {}      # id юнита -> смещение места от точки приказа
	for r in rows:
		var row: Array = order.slice(r * cols, mini(order.size(), (r + 1) * cols))
		row.sort_custom(func(a, b) -> bool:
			var pa: float = (units[a]["pos"] as Vector2).dot(side)
			var pb: float = (units[b]["pos"] as Vector2).dot(side)
			return pa < pb if pa != pb else int(a) < int(b))
		for k in row.size():
			slots[row[k]] = side * ((k - (row.size() - 1) * 0.5) * spacing) + fwd * (((rows - 1) * 0.5 - r) * spacing)
	var taken: Dictionary = {}
	for i in ids.size():
		var u: Dictionary = units[ids[i]]
		var off: Vector2 = slots[ids[i]] if ids.size() > 1 else Vector2.ZERO
		var dest := (target + off).clamp(Vector2(0.5, 0.5), Vector2(map_size - 0.5, map_size - 0.5))
		var dest_cell := to_cell(dest)
		if is_blocked(dest_cell, swims(u)) or taken.has(dest_cell):
			dest_cell = nearest_free_cell(dest_cell, taken, swims(u))
			dest = cell_center(dest_cell)
		taken[dest_cell] = true
		u["order"] = {"type": kind, "dest": dest, "manual": true}      # прямой приказ игрока: рабочий не убегает, а идёт куда сказано
		u["swing"] = -1.0
		_path_to(u, dest)


## Где юнит стоит в строю: 0 — впереди (ближний бой), 1 — стрелки и герои, 2 — тыл.
func _rank_in_line(u: Dictionary) -> int:
	var role := String(u["def"].get("role", ""))
	if role in ["healer", "siege", "summoner", "worker"] or float(u["damage"]) <= 0.0:
		return 2
	if u["hero"] or float(u["range"]) > 2.0:
		return 1
	return 0


func _cmd_gather(cmd: Dictionary) -> void:
	var r = resources.get(cmd.get("target"))
	if r == null:
		return
	for id in _owned(cmd, true):
		var u: Dictionary = units[id]
		if int(u["carry"]) > 0 and (String(u["carry_kind"]) == "gold") == (String(r["kind"]) == "gold"):
			_start_return(u, int(r["id"]), String(r["kind"]), r["pos"])
		else:
			_start_gather(u, int(r["id"]), String(r["kind"]), r["pos"])


func _cmd_build(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var workers := _owned(cmd, true)
	var key := String(cmd.get("building", ""))
	var defs: Dictionary = players[player]["data"]["buildings"]
	if workers.is_empty() or not defs.has(key):
		return
	var def: Dictionary = defs[key]
	var cell: Vector2i = cmd["cell"]
	var size: int = int(def.get("size", 2))
	if not can_place(size, cell):
		_msg(player, "Здесь строить нельзя")
		return
	if int(def.get("tier", 1)) > tier(player):
		_msg(player, "Сначала улучшите главное здание (%s) до %d уровня" % [String(defs["hall"]["name"]).to_lower(), int(def["tier"])])
		return
	if String(def.get("role", "")) == "hall" and not hall_spot_ok(cell, size):
		_msg(player, "Главное здание нельзя ставить вплотную к руднику: нужен отступ %d клетки" % HALL_MINE_GAP)
		return
	var cost := build_cost(player, key)
	if not can_afford(player, cost):
		_msg(player, "Не хватает ресурсов")
		return
	_pay(player, cost)
	var id := spawn_building(player, key, def, cell, false)
	buildings[id]["paid"] = cost
	players[player]["stats"]["built"] += 1
	var rect := Rect2i(cell, Vector2i(size, size))
	for uid in units:   # кто стоял на месте стройки — отходит в сторону
		var u: Dictionary = units[uid]
		if rect.has_point(to_cell(u["pos"])) and not workers.has(uid):
			_path_to(u, cell_center(nearest_free_cell(to_cell(u["pos"]))))
	for uid in workers:
		_start_build(units[uid], id)


## Цена здания для игрока. Башни и фермы (дома, шатры…) после десятой такой постройки дорожают:
## каждая следующая — на 10% от обычной цены больше (считаются и недостроенные).
func build_cost(player: int, key: String) -> Dictionary:
	var def: Dictionary = players[player]["data"]["buildings"].get(key, {})
	var base: Dictionary = def.get("cost", {})
	var role := String(def.get("role", ""))
	if role != "tower" and role != "supply":
		return base
	var n := 0
	for id in buildings:
		var b: Dictionary = buildings[id]
		if int(b["player"]) == player and String(b["key"]) == key:
			n += 1
	if n < 10:
		return base
	var k := 1.0 + 0.1 * float(n - 9)
	return {"gold": int(round(float(base.get("gold", 0)) * k)), "wood": int(round(float(base.get("wood", 0)) * k))}


func _cmd_train(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var b = buildings.get(cmd.get("building"))
	var key := String(cmd.get("unit", ""))
	if b == null or int(b["player"]) != player or not b["done"]:
		return
	if not (b["def"].get("trains", []) as Array).has(key):
		return
	var def: Dictionary = players[player]["data"]["units"][key]
	var cost: Dictionary = def.get("cost", {})
	var time: float = float(def.get("build_time", 20))
	var revive := false
	var hall_name := String(players[player]["data"]["buildings"]["hall"]["name"]).to_lower()
	if int(def.get("tier", 1)) > tier(player):
		_msg(player, "Сначала улучшите главное здание (%s)" % hall_name)
		return
	# герой каждого вида только один; павшего воскрешают там же, где наняли
	if def.get("hero", false):
		var h = players[player]["heroes"].get(key)
		if h == null and (players[player]["heroes"] as Dictionary).size() >= tier(player):
			_msg(player, "Для %s героя улучшите главное здание (%s)" % ["второго" if tier(player) == 1 else "третьего", hall_name])
			return
		if h != null:
			match String(h["state"]):
				"alive":
					_msg(player, "Этот герой уже в строю")
					return
				"training":
					_msg(player, "Этот герой уже нанимается")
					return
				"dead":
					if buildings.has(int(h["altar"])) and int(h["altar"]) != int(b["id"]):
						_msg(player, "Воскресить героя можно там, где он был нанят")
						return
					revive = true
					cost = {"gold": int(cost.get("gold", 0)) / 2, "wood": int(cost.get("wood", 0)) / 2}
					time *= 0.5
	if (b["queue"] as Array).size() >= QUEUE_MAX:
		_msg(player, "Очередь заполнена")
		return
	if not can_afford(player, cost):
		_msg(player, "Не хватает ресурсов")
		return
	if int(players[player]["supply_used"]) + int(def.get("supply", 0)) > supply_max(player):
		if int(players[player]["supply_cap"]) >= supply_limit(player):
			_msg(player, "Достигнут предел пищи (%d). Поднять его можно в главном здании" % supply_limit(player) if supply_limit(player) < SUPPLY_TOP else "Достигнут предел пищи (%d)" % SUPPLY_TOP)
		else:
			_msg(player, "Не хватает лимита: постройте %s" % String(players[player]["data"]["buildings"]["supply"]["name"]).to_lower())
		return
	_pay(player, cost)
	players[player]["supply_used"] += int(def.get("supply", 0))   # место в лимите занимаем сразу
	var item := {"key": key, "left": time, "total": time, "hero": bool(def.get("hero", false)), "revive": revive, "level": 1, "xp": 0}
	if def.get("hero", false):
		var old: Dictionary = players[player]["heroes"].get(key, {})
		item["level"] = int(old.get("level", 1))     # воскрешённый герой сохраняет уровень, способности и предметы
		item["items"] = old.get("items", [])
		item["skills"] = old.get("skills", {})
		item["xp"] = int(old.get("xp", 0))
		players[player]["heroes"][key] = {"state": "training", "altar": int(b["id"]), "level": item["level"], "xp": item["xp"], "items": item["items"], "skills": item["skills"]}
	(b["queue"] as Array).append(item)


func can_place(size: int, cell: Vector2i) -> bool:
	for x in range(cell.x, cell.x + size):
		for y in range(cell.y, cell.y + size):
			if is_blocked(Vector2i(x, y)):
				return false
	return true


const HALL_MINE_GAP := 4      # сколько клеток должно быть между главным зданием и рудником


## Главное здание стоит не ближе HALL_MINE_GAP клеток к любому руднику —
## иначе рабочие носили бы золото «из рук в руки» и выбирали рудник за пару минут.
func hall_spot_ok(cell: Vector2i, size: int) -> bool:
	var a := Rect2i(cell, Vector2i(size, size))
	for id in resources:
		var r: Dictionary = resources[id]
		if String(r["kind"]) != "gold":
			continue
		var b := _rect(r)
		var dx := maxi(0, maxi(a.position.x - b.end.x, b.position.x - a.end.x))
		var dy := maxi(0, maxi(a.position.y - b.end.y, b.position.y - a.end.y))
		if maxi(dx, dy) < HALL_MINE_GAP:
			return false
	return true


func can_afford(player: int, cost: Dictionary) -> bool:
	return int(players[player]["gold"]) >= int(cost.get("gold", 0)) and int(players[player]["wood"]) >= int(cost.get("wood", 0))


func _pay(player: int, cost: Dictionary) -> void:
	players[player]["gold"] -= int(cost.get("gold", 0))
	players[player]["wood"] -= int(cost.get("wood", 0))


func _msg(player: int, text: String) -> void:
	events.append({"type": "msg", "player": player, "text": text})


# ---------- шаг симуляции ----------

var prof_on := false               # замер частей тика (проверки скорости): часть -> сумма мкс
var prof: Dictionary = {}


func _pp(key: String, t0: int) -> int:
	if not prof_on:
		return 0
	var now := Time.get_ticks_usec()
	prof[key] = int(prof.get(key, 0)) + now - t0
	return now


func step() -> void:
	var pt := Time.get_ticks_usec() if prof_on else 0
	tick += 1
	var all_ids: Array = units.keys()
	all_ids.sort()
	_rebuild_buckets(all_ids)      # для команд этого тика (после загрузки сетка ещё пуста)
	var rest: Array = []
	for cmd in _pending:
		if int(cmd["tick"]) <= tick:
			_execute(cmd)
		else:
			rest.append(cmd)
	_pending = rest
	pt = _pp("commands", pt)

	var ids: Array = units.keys()
	ids.sort()
	_par_ids = ids
	_par(ids.size(), PAR_MOVE)
	pt = _pp("move*", pt)
	_rebuild_buckets(ids)
	_separate(ids)
	pt = _pp("separate*", pt)
	_collect_auras(ids)
	if _bindex_dirty:
		_rebuild_bindex()      # дальше указатель зданий только читается (в том числе с нескольких ядер)
	pt = _pp("auras", pt)
	_par(ids.size(), PAR_SENSE)      # каждый юнит обновляет только себя
	pt = _pp("sense*", pt)
	_res.clear()
	_res.resize(ids.size())
	_par(ids.size(), PAR_QUERY)      # каждый смотрит на соседей, ответ — в свою ячейку _res
	for i in ids.size():
		if _res[i] != null:
			units[ids[i]]["_q"] = _res[i]
	pt = _pp("query*", pt)
	for id in ids:
		if units.has(id):   # юнит мог погибнуть в этом же тике
			_think(units[id])
	pt = _pp("think", pt)
	var pids: Array = projectiles.keys()
	pids.sort()
	for id in pids:
		_fly(projectiles[id])
	var bids: Array = buildings.keys()
	bids.sort()
	for id in bids:
		if buildings.has(id):
			_update_building(buildings[id])
	pt = _pp("buildings", pt)
	_respawn_camps()
	_update_runes()
	_update_caravans()
	_update_world_events()
	if tick % 10 == 0 and not corpses.is_empty():      # тела истлевают
		var gone: Array = []
		for cid in corpses:
			if tick >= int(corpses[cid]["expires"]):
				gone.append(int(cid))
		gone.sort()
		for cid in gone:
			_remove_corpse(cid, "rot")
	_pp("world", pt)


## ---------- многоядерность ----------
## Части тика, где каждый юнит считается сам по себе, раздаются нескольким ядрам.
## Правила, без которых игры у разных компьютеров разошлись бы (или игра упала):
##  * в одной такой части юнит либо меняет только СЕБЯ и ни на кого не смотрит (_move_at, _sense_at),
##    либо смотрит на соседей, но ответ пишет только в свою ячейку _res (_separate, _query_at);
##  * ответ зависит лишь от состояния до начала части, а не от того, какое ядро успело раньше, —
##    поэтому результат одинаков при любом числе ядер (и при одном);
##  * всё, что задевает других (удары, смерти, деньги, события), делается по-прежнему по очереди.

var threads := 1                   # сколько ядер может занять тик (задаёт main; 1 — всё на одном)
const PAR_MIN := 40                # меньше юнитов — быстрее посчитать подряд, чем раздавать
var _par_ids: Array = []           # юниты текущей части (по возрастанию номеров)
var _par_kind := 0                 # какая часть считается: PAR_MOVE, PAR_PUSH, PAR_SENSE, PAR_QUERY
const PAR_MOVE := 0
const PAR_PUSH := 1
const PAR_SENSE := 2
const PAR_QUERY := 3
var _par_chunk := 1
var _res: Array = []               # ответы частей «смотрим на соседей»: ячейка i — для юнита _par_ids[i]


var _par_mx := Mutex.new()
var _par_next := 0                 # следующий не взятый кусок
var _par_chunks := 0


func _par(n: int, kind: int) -> void:
	_par_kind = kind
	if threads <= 1 or n < PAR_MIN:
		_par_range(0, n)
		return
	# кусков больше, чем ядер: кто освободился — берёт следующий. Считает и сам раздающий поток.
	_par_chunk = maxi(4, ceili(float(n) / float(threads * 4)))
	_par_chunks = ceili(float(n) / float(_par_chunk))
	_par_next = 0
	var gid := WorkerThreadPool.add_group_task(_par_worker, threads - 1, threads - 1, true, "sim part")
	_par_worker(0)
	WorkerThreadPool.wait_for_group_task_completion(gid)


func _par_worker(_w: int) -> void:
	while true:
		_par_mx.lock()
		var k := _par_next
		_par_next += 1
		_par_mx.unlock()
		if k >= _par_chunks:
			return
		_par_range(k * _par_chunk, mini(k * _par_chunk + _par_chunk, _par_ids.size()))


## Прямые вызовы, без Callable: вызов через Callable берёт общую блокировку движка,
## и ядра стояли бы в очереди друг за другом.
func _par_range(a: int, b: int) -> void:
	match _par_kind:
		PAR_MOVE:
			for i in range(a, b):
				_move_unit(units[_par_ids[i]])
		PAR_PUSH:
			for i in range(a, b):
				_push_at(i)
		PAR_SENSE:
			for i in range(a, b):
				_sense_at(i)
		PAR_QUERY:
			for i in range(a, b):
				_query_at(i)


## Подготовка к раздумьям: всё, что юнит узнаёт только о себе (стоит ли, укрылся ли, на холме ли,
## текущие характеристики). У дремлющих нейтралов и особых случаев это делает сам _think.
func _sense_at(i: int) -> void:
	var u: Dictionary = units[_par_ids[i]]
	if u.has("merc_idle") or u.has("pre_militia") or (int(u["expires"]) >= 0 and tick >= int(u["expires"])) or _napping(u):
		return
	_sense_self(u)
	_refresh_self(u)
	u["_pre"] = tick


## Взгляд на соседей до раздумий: ближайший враг (для тех, кто сам ищет цель) и свободное место
## у цели (для тех, кто её догоняет). Пишет только в _res[i]; _think берёт готовое, если оно ещё верно.
func _query_at(i: int) -> void:
	var u: Dictionary = units[_par_ids[i]]
	if int(u.get("_pre", -1)) != tick or float(u["swing"]) >= 0.0 or tick < int(u["stun"]):
		return
	var o: Dictionary = u["order"]
	var kind := String(o.get("type", "idle"))
	if kind == "idle" or kind == "amove":
		if _may_acquire(u):
			_res[i] = [tick, _nearest_enemy(u["pos"], int(u["player"]), ACQUIRE, true), -1, Vector2.ZERO]
	elif kind == "attack" and int(u["wait"]) <= 0:
		var t = entity(int(o["target"]))
		if t != null and not t["is_building"] and gap(u, t) > float(u["range"]):
			_res[i] = [tick, -2, int(t["id"]), _attack_spot(u, t)]


func _move_unit(u: Dictionary) -> void:
	u["prev_pos"] = u["pos"]
	if float(u["swing"]) >= 0.0 or tick < int(u["stun"]):
		return   # во время удара и в оглушении юнит стоит на месте
	var path: PackedVector2Array = u["path"]
	var i: int = u["path_i"]
	var budget: float = float(u["speed"]) * TICK_DT
	var pos: Vector2 = u["pos"]
	# Спрямление на ходу: путь по клеткам идёт «лесенкой»; если следующая точка пути уже
	# видна напрямую, текущую пропускаем. Так юнит идёт по прямой, огибая только препятствия.
	if (tick + int(u["id"])) % 2 == 0:
		for skip in 2:
			if i + 1 >= path.size():
				break
			var nxt: Vector2 = path[i + 1]
			if pos.distance_squared_to(nxt) > 64.0 or not _clear_line(pos, nxt, clampf(float(u["radius"]), 0.2, 0.42), swims(u)):
				break
			i += 1
	while budget > 0.0 and i < path.size():
		var to: Vector2 = path[i] - pos
		var d := to.length()
		if d <= budget:
			pos = path[i]
			budget -= d
			i += 1
		else:
			pos += to / d * budget
			budget = 0.0
	if pos.distance_squared_to(u["pos"]) > 0.0001:
		u["facing"] = (pos - (u["pos"] as Vector2)).normalized()
	u["pos"] = pos
	u["path_i"] = i


## ---------- пространственная сетка ----------
## Карта поделена на клетки BUCKET×BUCKET; в каждой — номера юнитов, стоящих там.
## Поиск соседей смотрит только ближайшие клетки, а не всех юнитов карты:
## так сотни юнитов не тормозят игру. Порядок обхода строго одинаковый на всех компьютерах.

const BUCKET := 4.0
const MAX_RADIUS := 2.2     # радиус самого крупного юнита (дракона): запас при поиске соседей
var _buckets: Dictionary = {}


func _bucket_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / BUCKET), floori(p.y / BUCKET))


func _rebuild_buckets(ids: Array) -> void:
	_buckets.clear()
	for id in ids:      # ids отсортированы, поэтому и списки в клетках отсортированы
		var c := _bucket_of(units[id]["pos"])
		if not _buckets.has(c):
			_buckets[c] = []
		(_buckets[c] as Array).append(id)


## Номера юнитов, чьи клетки могут попасть в круг (без точной проверки расстояния).
func _candidates(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	var lo := _bucket_of(pos - Vector2.ONE * (radius + MAX_RADIUS))
	var hi := _bucket_of(pos + Vector2.ONE * (radius + MAX_RADIUS))
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var list = _buckets.get(Vector2i(cx, cy))
			if list != null:
				out.append_array(list)
	return out


## Юниты мягко расталкивают друг друга, чтобы не стоять один в другом.
func _separate(ids: Array) -> void:
	# Сначала каждый юнит (на любом ядре) складывает толчки от всех соседей по положениям
	# на начало шага, потом толчки применяются по порядку. Соседей берём прямо из клеток сетки:
	# порядок обхода клеток и юнитов в них одинаков на всех компьютерах.
	_par_ids = ids
	_res.clear()
	_res.resize(ids.size())
	_par(ids.size(), PAR_PUSH)
	for i in ids.size():
		if _res[i] != null:
			_try_shift(units[ids[i]], _res[i])


func _push_at(i: int) -> void:
	var ida: int = _par_ids[i]
	var ua: Dictionary = units[ida]
	var ra: float = float(ua["radius"])
	var reach: float = ra + MAX_RADIUS
	var pa: Vector2 = ua["pos"]
	var lo := _bucket_of(pa - Vector2(reach, reach))
	var hi := _bucket_of(pa + Vector2(reach, reach))
	var total := Vector2.ZERO
	var any := false
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var list = _buckets.get(Vector2i(cx, cy))
			if list == null:
				continue
			for idb in list:
				if int(idb) == ida:
					continue
				var ub: Dictionary = units[idb]
				var delta: Vector2 = (ub["pos"] as Vector2) - pa
				var min_d: float = ra + float(ub["radius"])
				if absf(delta.x) >= min_d or absf(delta.y) >= min_d:
					continue
				var d := delta.length()
				if d >= min_d:
					continue
				var dir: Vector2
				if d < 0.001:      # стоят точка в точку: расходятся в стороны, заданные парой номеров
					var lo_id := mini(ida, int(idb))
					dir = Vector2(1, 0).rotated(float(lo_id * 7 + maxi(ida, int(idb)) * 13)) * (1.0 if ida == lo_id else -1.0)
				else:
					dir = delta / d
				total -= dir * (min_d - d) * 0.25
				any = true
	if any:
		_res[i] = total


func _try_shift(u: Dictionary, shift: Vector2) -> void:
	if u["busy"] or float(u["base"]["speed"]) <= 0.0:
		return   # работающих, бьющих и неподвижных (глаз-наблюдатель) не толкаем
	var p: Vector2 = u["pos"] + shift
	var c := to_cell(p)
	if in_map(c) and not is_blocked(c, swims(u)):
		u["pos"] = p


## Юнит идёт, но почти не сдвигается (упёрся в своих, его толкают):
## у самой цели — считаем, что пришёл; иначе — обходит помеху сбоку.
func _check_stuck(u: Dictionary) -> void:
	if not is_moving(u):
		u["stuck"] = 0
		return
	var moved: float = (u["pos"] as Vector2).distance_to(u["prev_pos"])
	if moved >= float(u["speed"]) * TICK_DT * 0.3:
		u["stuck"] = maxi(0, int(u.get("stuck", 0)) - 1)
		return
	u["stuck"] = int(u.get("stuck", 0)) + 1
	if int(u["stuck"]) < 6:
		return
	u["stuck"] = 0
	var path: PackedVector2Array = u["path"]
	var i: int = u["path_i"]
	var pos: Vector2 = u["pos"]
	var last: Vector2 = path[path.size() - 1]
	var kind := String(u["order"].get("type", ""))
	if kind in ["move", "amove", "home", "follow"] and pos.distance_to(last) < 1.4 + float(u["radius"]) * 3.0:
		_stop_path(u)      # место в строю занято, а мы уже рядом — стоим здесь
		return
	var to: Vector2 = path[i] - pos
	if to.length() < 0.01:
		return
	to = to.normalized()
	var tries := int(u.get("unstuck", 0)) + 1
	u["unstuck"] = tries
	var side := Vector2(-to.y, to.x) * (1.0 if tries % 2 == 1 else -1.0)
	for s in [1.0, -1.0]:
		var wp: Vector2 = pos + side * s * (float(u["radius"]) * 2.0 + 0.7) + to * 0.5
		if not is_blocked(to_cell(wp), swims(u)) and _clear_line(pos, wp, 0.2, swims(u)):
			path.insert(i, wp)
			u["path"] = path
			return


func is_moving(u: Dictionary) -> bool:
	return int(u["path_i"]) < (u["path"] as PackedVector2Array).size()


func _stop_path(u: Dictionary) -> void:
	u["path"] = PackedVector2Array()
	u["path_i"] = 0


func _think(u: Dictionary) -> void:
	if u.has("merc_idle"):      # свободный наёмник сидит у костра своего лагеря
		u["busy"] = true
		return
	u["busy"] = false
	u["cd"] = maxf(0.0, float(u["cd"]) - TICK_DT)
	if int(u["expires"]) >= 0 and tick >= int(u["expires"]):
		_kill(u, NEUTRAL)       # время призванного существа вышло
		return
	if _napping(u):
		return
	if int(u.get("_pre", -1)) != tick:      # не подготовлен заранее (см. _sense_at) — готовимся здесь
		_sense_self(u)
		if u.has("pre_militia") and not _has_buff(u, "militia"):
			_end_militia(u)
		_refresh_self(u)
	if swims(u) and in_water(u["pos"]):      # наги в воде залечивают раны
		u["hp"] = minf(float(u["max_hp"]), float(u["hp"]) + WATER_REGEN * TICK_DT)
	if float(u["max_mana"]) > 0.0:
		u["mana"] = minf(float(u["max_mana"]), float(u["mana"]) + float(u["mana_regen"]) * TICK_DT)
	if float(u["hp_regen"]) != 0.0:      # отрицательное — яд
		u["hp"] = minf(float(u["max_hp"]), float(u["hp"]) + float(u["hp_regen"]) * TICK_DT)
		if float(u["hp"]) <= 0.0:
			_kill(u, int(u.get("poison_by", NEUTRAL)))
			return
	# разбег для натиска: сколько тиков юнит бежит без удара
	if is_moving(u) and float(u["swing"]) < 0.0:
		u["run"] = int(u.get("run", 0)) + 1
	elif not is_moving(u) and String(u["order"].get("type", "idle")) == "idle":
		u["run"] = 0
	if tick < int(u["stun"]):   # оглушён: ничего не делает
		u["swing"] = -1.0
		u["busy"] = true
		return
	if float(u["swing"]) >= 0.0:      # замах уже идёт: ждём момент удара
		u["busy"] = true
		u["swing"] = float(u["swing"]) - TICK_DT
		if float(u["swing"]) <= 0.0:
			u["swing"] = -1.0
			_strike(u)
		return
	_check_stuck(u)
	if u["def"].has("autocast"):
		_autocast(u)
	var o: Dictionary = u["order"]
	match String(o.get("type", "idle")):
		"idle":
			if not _auto_acquire(u, o) and has_trait(u, "cannibal"):
				_seek_corpse(u)
		"amove":
			if not _auto_acquire(u, o) and not is_moving(u):
				_idle(u)
		"attack":
			_do_attack(u, o)
		"home":
			u["hp"] = minf(float(u["max_hp"]), float(u["hp"]) + float(u["max_hp"]) * 0.03)
			if not is_moving(u):
				_idle(u)
		"move":
			if not is_moving(u):
				u["order"] = {"type": "idle"}
		"gather":
			_do_gather(u, o)
		"return":
			_do_return(u, o)
		"build":
			_do_build(u, o)
		"cast":
			_do_cast(u, o)
		"pickup":
			_do_pickup(u, o)
		"repair":
			_do_repair(u, o)
		"eat":
			_do_eat(u, o)
		"flee":
			if tick >= int(o["until"]) or (not is_moving(u) and tick >= int(o["repath"])):
				_resume_work(u, o["resume"])
		"follow":
			var leader = units.get(o["target"])
			if leader == null:
				_idle(u)
			elif (u["pos"] as Vector2).distance_to(leader["pos"]) > float(u["radius"]) + float(leader["radius"]) + 1.2:
				if int(u["wait"]) > 0:
					u["wait"] = int(u["wait"]) - 1
				else:
					u["wait"] = 4
					_path_to(u, leader["pos"])
			else:
				_stop_path(u)


## Нейтралы, спокойно стоящие в лагере целыми и невредимыми, «дремлют»: думают раз в 4 тика
## (на большой карте их больше половины всех юнитов, а делать им нечего).
func _napping(u: Dictionary) -> bool:
	# строку (вид приказа) сравниваем последней: строки на нескольких ядрах сразу — дорогие
	return int(u["player"]) == NEUTRAL and (tick + int(u["id"])) % 4 != 0 \
			and float(u["swing"]) < 0.0 and float(u["hp"]) >= float(u["max_hp"]) and (u["buffs"] as Array).is_empty() \
			and int(u["path_i"]) >= (u["path"] as PackedVector2Array).size() and tick >= int(u["stun"]) \
			and String(u["order"].get("type", "idle")) == "idle"


func _sense_self(u: Dictionary) -> void:
	# сколько тиков юнит стоит на месте (для «окопа» гномов и укрытия эльфов)
	if (u["pos"] as Vector2).distance_squared_to(u["prev_pos"]) < 0.0004 and float(u["swing"]) < 0.0:
		u["still"] = int(u.get("still", 0)) + 1
	else:
		u["still"] = 0
	# эльфы ночью: кто стоит без дела 2 с, не бьёт и не ранен, становится невидим для врагов
	u["hidden"] = is_night() and int(u["still"]) >= 20 and tick - int(u.get("fought", -999)) > 30 \
		and has_trait(u, "shadowmeld") and String(u["order"].get("type", "idle")) in ["idle", "move", "home"]


func _refresh_self(u: Dictionary) -> void:
	u["high"] = high_cells.has(Vector2i(floori((u["pos"] as Vector2).x), floori((u["pos"] as Vector2).y)))      # стоит на возвышенности
	_refresh_stats(u)


## Готовый ответ _query_at этого тика (или null).
func _ready_q(u: Dictionary):
	var q = u.get("_q")
	return q if q != null and int(q[0]) == tick else null


## Целители сами лечат самого раненого союзника рядом, когда перезарядка готова
## и хватает маны (ac.mana за одно лечение).
func _autocast(u: Dictionary) -> void:
	var ac: Dictionary = u["def"]["autocast"]
	if tick < int(u["cds"].get("auto", 0)):
		return
	if String(ac.get("kind", "heal")) == "summon":
		_autocast_summon(u, ac)
		return
	if String(ac.get("kind", "heal")) == "buff":
		_autocast_buff(u, ac)
		return
	var cost := float(ac.get("mana", 0))
	if float(u["mana"]) < cost:
		return
	var amount := float(ac.get("amount", 40))
	var best := -1
	var worst := 1.0
	for id in _units_near(u["pos"], float(ac.get("range", 6.0))):
		var a: Dictionary = units[id]
		if enemies(int(a["player"]), int(u["player"])) or a["is_building"] or float(a["max_hp"]) - float(a["hp"]) < amount * 0.6:
			continue
		var ratio := float(a["hp"]) / float(a["max_hp"])
		if ratio < worst:
			worst = ratio
			best = id
	if best < 0:
		return
	u["cds"]["auto"] = tick + int(float(ac.get("cooldown", 3.0)) * TICK_RATE)
	u["mana"] = float(u["mana"]) - cost
	var t: Dictionary = units[best]
	t["hp"] = minf(float(t["max_hp"]), float(t["hp"]) + amount)
	events.append({"type": "cast", "id": u["id"], "key": "autocast"})
	events.append({"type": "beam", "from": u["pos"], "to": t["pos"], "color": String(ac.get("color", "#9fffa0"))})
	events.append({"type": "blast", "pos": t["pos"], "radius": 0.9, "color": String(ac.get("color", "#9fffa0"))})


## Огр-маг в бою сам накладывает «Жажду крови» на дерущегося союзника рядом, у которого её ещё нет.
func _autocast_buff(u: Dictionary, ac: Dictionary) -> void:
	var key := String(ac.get("buff", "bloodlust"))
	var best := -1
	var best_d := float(ac.get("range", 7.0)) + 0.01
	for id in _units_near(u["pos"], float(ac.get("range", 7.0))):
		var a: Dictionary = units[id]
		if int(a["player"]) != int(u["player"]) or is_worker(a) or float(a["damage"]) <= 0.0 or _has_buff(a, key):
			continue
		if tick - int(a.get("fought", -999)) > 30:
			continue      # только тем, кто сейчас в бою
		var d: float = (a["pos"] as Vector2).distance_to(u["pos"])
		if d < best_d:
			best_d = d
			best = int(id)
	if best < 0:
		return
	u["cds"]["auto"] = tick + int(float(ac.get("cooldown", 8.0)) * TICK_RATE)
	_add_buff(units[best], key, float(ac.get("duration", 15.0)), ac.get("mods", {}))
	events.append({"type": "cast", "id": u["id"], "key": "autocast"})
	events.append({"type": "beam", "from": u["pos"], "to": units[best]["pos"], "color": String(ac.get("color", "#ff5a3a"))})
	events.append({"type": "blast", "pos": units[best]["pos"], "radius": 0.9, "color": String(ac.get("color", "#ff5a3a"))})


## Некромант в бою поднимает скелетов (не больше ac.max одновременно; живут ac.duration секунд).
func _autocast_summon(u: Dictionary, ac: Dictionary) -> void:
	var player := int(u["player"])
	if player == NEUTRAL and String(u["order"].get("type")) != "attack":
		return
	var foe := _nearest_enemy(u["pos"], player, float(ac.get("range", 9.0)), false)
	if foe < 0 and player != NEUTRAL:
		return
	var alive: Array = []
	for rid in u.get("raised", []):
		if units.has(rid):
			alive.append(rid)
	if alive.size() >= int(ac.get("max", 2)):
		u["raised"] = alive
		return
	var key := String(ac["unit"])
	var def: Dictionary = players[player]["data"].get("summons", {}).get(key, players[NEUTRAL]["data"]["units"].get(key, {}))
	if def.is_empty():
		return
	var spot: Vector2 = (u["pos"] as Vector2) + (u["facing"] as Vector2).rotated(0.9 * (1 if alive.size() % 2 == 0 else -1)) * 1.4
	if ac.get("corpse", false):      # нежить поднимает скелетов только из тел павших
		var c := nearest_corpse(u["pos"], float(ac.get("range", 9.0)))
		if c < 0:
			return
		spot = corpses[c]["pos"]
		_remove_corpse(c, "raised")
	u["cds"]["auto"] = tick + int(float(ac.get("cooldown", 12.0)) * TICK_RATE)
	var target := int(u["order"].get("target", foe))
	var n := mini(int(ac.get("count", 1)), int(ac.get("max", 2)) - alive.size())      # дракон зовёт нескольких сразу
	for k in n:
		var at: Vector2 = spot if k == 0 else (u["pos"] as Vector2) + (u["facing"] as Vector2).rotated(0.9 * (k - 1) - 0.45 + PI * 0.25 * k) * (float(u["radius"]) + 1.2)
		if is_blocked(to_cell(at)):
			at = cell_center(nearest_free_cell(to_cell(at)))
		var id := spawn_unit(player, key, def, at, false)
		units[id]["expires"] = tick + int(float(ac.get("duration", 40.0)) * TICK_RATE)
		units[id]["camp"] = -1
		alive.append(id)
		events.append({"type": "blast", "pos": at, "radius": 1.2, "color": String(ac.get("color", "#6aff8a"))})
		if entity(target) != null and enemies(int(entity(target)["player"]), player):
			_order_attack(units[id], target, {})
	u["raised"] = alive
	events.append({"type": "cast", "id": u["id"], "key": "autocast"})


func _idle(u: Dictionary) -> void:
	u["order"] = {"type": "idle"}
	u["swing"] = -1.0
	_stop_path(u)


# ---------- бой ----------

func hostile(u: Dictionary, other: Dictionary) -> bool:
	return enemies(int(u["player"]), int(other["player"]))


## Расстояние «от края до края» между юнитом и целью (юнитом или зданием).
func gap(u: Dictionary, t: Dictionary) -> float:
	var p: Vector2 = u["pos"]
	if t["is_building"]:
		var rect := _rect(t)
		return p.distance_to(p.clamp(Vector2(rect.position), Vector2(rect.end))) - float(u["radius"])
	return p.distance_to(t["pos"]) - float(u["radius"]) - float(t["radius"])


## Войска сами нападают на врагов рядом. Рабочие и нейтралы — нет.
## Спокойных нейтралов никто сам не трогает.
func _auto_acquire(u: Dictionary, o: Dictionary) -> bool:
	if int(u["player"]) == NEUTRAL and not u.get("raider", false):      # набег (raider) ведёт себя как войско
		if (u["pos"] as Vector2).distance_to(u["home"]) > 1.5 and not is_moving(u):
			u["order"] = {"type": "home"}
			_path_to(u, u["home"])
		return false
	if not _may_acquire(u):
		return false
	var best := -1
	var q = _ready_q(u)
	if q != null and int(q[1]) >= -1 and (int(q[1]) < 0 or entity(int(q[1])) != null):
		best = int(q[1])      # ответ, найденный заранее на другом ядре, ещё верен
	else:
		best = _nearest_enemy(u["pos"], int(u["player"]), ACQUIRE, true)
	if best < 0:
		return false
	_order_attack(u, best, o if String(o.get("type")) == "amove" else {})
	return true


## Ищет ли боец сам цель в этот тик (раз в 3 тика; рабочие — только в ополчении; укрывшиеся — нет).
func _may_acquire(u: Dictionary) -> bool:
	if int(u["player"]) == NEUTRAL and not u.get("raider", false):
		return false
	if (is_worker(u) and not _has_buff(u, "militia")) or float(u["damage"]) <= 0.0 or (tick + int(u["id"])) % 3 != 0:
		return false
	return not u.get("hidden", false)      # укрывшийся эльф сам не нападает — сидит в засаде, ждёт приказа


func _nearest_enemy(pos: Vector2, player: int, max_dist: float, with_buildings: bool) -> int:
	var best := -1
	var best_d := max_dist
	for id in _candidates(pos, max_dist):
		if not units.has(id):
			continue
		var t: Dictionary = units[id]
		if not enemies(int(t["player"]), player) or t.get("hidden", false):
			continue      # союзников и укрывшихся в ночи эльфов не трогаем
		if int(t["player"]) == NEUTRAL and String(t["order"].get("type")) != "attack":
			continue
		var d: float = pos.distance_to(t["pos"])
		if d < best_d or (d == best_d and int(id) < best):
			best_d = d
			best = int(id)
	if best < 0 and with_buildings:
		for id in _buildings_near(pos, max_dist + MAX_BUILDING_RADIUS):      # только здания из ближних клеток сетки
			var b: Dictionary = buildings[id]
			if not enemies(int(b["player"]), player) or int(b["player"]) == NEUTRAL:
				continue
			var d: float = pos.distance_to(b["pos"]) - float(b["radius"])
			if d < best_d or (d == best_d and int(id) < best):
				best_d = d
				best = int(id)
	return best


# ---------- указатели на здания (чтобы не перебирать все здания карты) ----------
## Здания разложены по клеткам сетки, а ратуши — по игрокам. Пересобираются, только когда
## здания появляются, исчезают или достраиваются (_bindex_dirty).

const MAX_BUILDING_RADIUS := 2.5
var _bindex_dirty := true
var _bbuckets: Dictionary = {}       # клетка сетки -> [id зданий]
var _halls_of: Dictionary = {}       # игрок -> [id готовых главных зданий] в порядке словаря buildings


func _rebuild_bindex() -> void:
	_bindex_dirty = false
	_bbuckets.clear()
	_halls_of.clear()
	for id in buildings:
		var b: Dictionary = buildings[id]
		var c := _bucket_of(b["pos"])
		if not _bbuckets.has(c):
			_bbuckets[c] = []
		(_bbuckets[c] as Array).append(id)
		if b["done"] and String(b["def"].get("role", "")) == "hall":
			if not _halls_of.has(int(b["player"])):
				_halls_of[int(b["player"])] = []
			(_halls_of[int(b["player"])] as Array).append(id)


func _buildings_near(pos: Vector2, radius: float) -> Array:
	if _bindex_dirty:
		_rebuild_bindex()
	var out: Array = []
	var lo := _bucket_of(pos - Vector2.ONE * radius)
	var hi := _bucket_of(pos + Vector2.ONE * radius)
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var list = _bbuckets.get(Vector2i(cx, cy))
			if list != null:
				out.append_array(list)
	return out


func _order_attack(u: Dictionary, target: int, resume: Dictionary) -> void:
	u["order"] = {"type": "attack", "target": target, "resume": resume}
	u["wait"] = 0


func _do_attack(u: Dictionary, o: Dictionary) -> void:
	var t = entity(int(o["target"]))
	var neutral: bool = int(u["player"]) == NEUTRAL and not u.get("raider", false)
	if t == null or (neutral and (u["pos"] as Vector2).distance_to(u["home"]) > LEASH):
		var resume: Dictionary = o.get("resume", {})
		if neutral:
			u["order"] = {"type": "home"}
			_path_to(u, u["home"])
		elif String(resume.get("type", "")) == "amove":
			u["order"] = resume
			_path_to(u, resume["dest"])
		else:
			_idle(u)
		return
	if gap(u, t) <= float(u["range"]):
		_stop_path(u)
		var to: Vector2 = (t["pos"] as Vector2) - (u["pos"] as Vector2)
		if to.length() > 0.01:
			u["facing"] = to.normalized()
		if float(u["cd"]) <= 0.0:
			var cooldown: float = maxf(0.3, float(u["attack_cooldown"]))
			var windup: float = minf(0.45, cooldown * 0.35)
			u["cd"] = cooldown
			u["swing"] = windup
			u["fought"] = tick
			u["swing_target"] = int(t["id"])
			u["busy"] = true
			events.append({"type": "attack", "id": u["id"], "windup": windup})
		return
	# цель далеко: догоняем, время от времени прокладывая путь заново
	if int(u["wait"]) > 0:
		u["wait"] = int(u["wait"]) - 1
		return
	u["wait"] = 4
	# путь прокладываем заново, только если цель сменилась или заметно ушла от точки, куда мы бежим
	# (поиск пути — самое дорогое в игре, а бегущему за медленной целью он не нужен каждые 0,4 с)
	var same: bool = is_moving(u) and int(u.get("chase", -1)) == int(t["id"])
	if t["is_building"]:
		if same:
			return
		_go_adjacent(u, _rect(t))
		u["chase"] = int(t["id"])      # ставится после прокладки пути: любой другой путь (_path_to) его стирает
	else:
		var q = _ready_q(u)
		var spot: Vector2 = q[3] if q != null and int(q[2]) == int(t["id"]) else _attack_spot(u, t)
		if same and spot.distance_to(u.get("chase_at", Vector2(-99, -99))) < maxf(0.8, (u["pos"] as Vector2).distance_to(spot) * 0.15):
			return
		_path_to(u, spot)
		u["chase"] = int(t["id"])
		u["chase_at"] = spot


## Куда бежать, чтобы ударить юнита. Бойцы ближнего боя не лезут все в его центр,
## а выбирают свободное место вокруг (окружают), начиная со своей стороны.
func _attack_spot(u: Dictionary, t: Dictionary) -> Vector2:
	var tp: Vector2 = t["pos"]
	var up: Vector2 = u["pos"]
	if float(u["range"]) > 2.0 or up.distance_to(tp) > 7.0:
		return tp
	var dir := up - tp
	dir = dir / dir.length() if dir.length() > 0.01 else Vector2(1, 0)
	var ring := float(t["radius"]) + float(u["radius"]) + 0.1
	var best := tp
	var best_score := INF
	var rr := float(u["radius"]) + 0.15
	var near := _candidates(tp, ring + rr)      # один общий список соседей на все девять мест вокруг цели
	for a in [0.0, 0.55, -0.55, 1.1, -1.1, 1.65, -1.65, 2.3, -2.3]:
		var spot: Vector2 = tp + dir.rotated(a) * ring
		if is_blocked(to_cell(spot)):
			continue
		var crowd := 0
		for oid in near:
			if oid != int(u["id"]) and oid != int(t["id"]) and units.has(oid) and (units[oid]["pos"] as Vector2).distance_to(spot) <= rr + float(units[oid]["radius"]):
				crowd += 1
		var score := absf(a) + crowd * 2.5
		if score < best_score:
			best_score = score
			best = spot
	return best


## Момент удара: ближний бой наносит урон сразу, дальний выпускает снаряд.
func _strike(u: Dictionary) -> void:
	var t = entity(int(u["swing_target"]))
	if t == null:
		return
	if u["def"].has("kamikaze"):      # подрывник: удар — это взрыв, а сам он гибнет
		_explode(u, u["def"]["kamikaze"], u["pos"])
		if units.has(u["id"]):
			_kill(u, int(u["player"]))
		return
	var dmg := float(u["damage"])
	if float(u.get("crit", 0.0)) > 0.0 and _roll(int(u["id"]), int(t["id"]) + 7) < float(u["crit"]):
		dmg *= CRIT_MUL       # критический удар
		events.append({"type": "float", "player": u["player"], "pos": t["pos"], "text": "%d!" % roundi(dmg), "color": "#ff5a4a"})
	if u["def"].has("charge") and int(u.get("run", 0)) >= int(float(u["def"]["charge"].get("after", 1.5)) * TICK_RATE):
		var ch: Dictionary = u["def"]["charge"]      # натиск: первый удар с разбега сильнее и оглушает
		dmg *= float(ch.get("mul", 1.8))
		if not t["is_building"]:
			t["stun"] = maxi(int(t["stun"]), tick + int(float(ch.get("stun", 0.5)) * TICK_RATE))
		events.append({"type": "float", "player": u["player"], "pos": t["pos"], "text": "Натиск! %d" % roundi(dmg), "color": "#ffb03a"})
		events.append({"type": "charge", "id": u["id"], "pos": t["pos"]})
	u["run"] = 0
	var splash_r := float(u["def"].get("splash_radius", 0.0))
	if float(u["range"]) > 2.0:
		var pid := _shoot(u["pos"], t, dmg, String(u["damage_type"]), int(u["id"]), int(u["player"]),
			String(u["def"].get("projectile", "rock" if String(u["damage_type"]) == "siege" else "arrow")), 1.2 * float(u["def"]["model"].get("scale", 1.0)))
		if splash_r > 0.0:       # осадные машины бьют по площади
			projectiles[pid]["splash"] = float(u["def"].get("splash", 0.5))
			projectiles[pid]["splash_radius"] = splash_r
			projectiles[pid]["art"] = int(u["player"]) != NEUTRAL
	else:
		var tpos: Vector2 = t["pos"]
		_damage(t, dmg, String(u["damage_type"]), int(u["id"]), int(u["player"]), true)
		if splash_r > 0.0:
			var art: bool = int(u["player"]) != NEUTRAL
			for oid in _splash_hits(tpos, splash_r, int(u["player"]), int(t["id"]), art):
				if units.has(oid):      # мог погибнуть от взрыва соседа
					_damage(units[oid], dmg * float(u["def"].get("splash", 0.5)) * (SPLASH_MUL if art else 1.0), String(u["damage_type"]), int(u["id"]), int(u["player"]))


## attack = обычная атака (её можно уклониться, она даёт вампиризм); заклинания — нет.
func _shoot(from: Vector2, t: Dictionary, damage: float, dtype: String, attacker: int, player: int, kind: String, height: float, attack := true) -> int:
	var id := _new_id()
	projectiles[id] = {
		"id": id, "kind": kind, "pos": from, "prev_pos": from, "start": from, "height": height,
		"target": int(t["id"]), "tpos": t["pos"], "speed": {"arrow": 16.0, "bullet": 26.0, "rock": 11.0}.get(kind, 13.0),
		"splash": 0.0, "splash_radius": 0.0, "attack": attack,
		"damage": damage, "damage_type": dtype, "attacker": attacker, "player": player,
	}
	return id


## Одинаковое на обоих компьютерах «случайное» число 0…1: зависит только от тика и номеров.
func _roll(a: int, b: int) -> float:
	var h: int = (tick * 73856093) ^ (a * 19349663) ^ (b * 83492791) ^ (seed_value * 2654435761)
	h = (h * 1103515245 + 12345) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return float(h % 10000) / 10000.0


func _fly(p: Dictionary) -> void:
	var t = entity(int(p["target"]))
	if t != null:
		p["tpos"] = t["pos"]
	p["prev_pos"] = p["pos"]
	var to: Vector2 = (p["tpos"] as Vector2) - (p["pos"] as Vector2)
	var step_len: float = float(p["speed"]) * TICK_DT
	if to.length() <= step_len + 0.2:
		if t != null:
			_damage(t, float(p["damage"]), String(p["damage_type"]), int(p["attacker"]), int(p["player"]), bool(p.get("attack", false)))
		if float(p["splash_radius"]) > 0.0:   # взрыв задевает врагов рядом с целью
			var art: bool = p.get("art", false)      # выстрел осадного орудия игрока — по площади слабее и не по всем
			for oid in _splash_hits(p["tpos"], float(p["splash_radius"]), int(p["player"]), int(p["target"]), art):
				if units.has(oid):
					_damage(units[oid], float(p["damage"]) * float(p["splash"]) * (SPLASH_MUL if art else 1.0), String(p["damage_type"]), int(p["attacker"]), int(p["player"]))
			events.append({"type": "blast", "pos": p["tpos"], "radius": p["splash_radius"], "color": "#ff7a2a"})
		projectiles.erase(p["id"])
	else:
		p["pos"] = (p["pos"] as Vector2) + to.normalized() * step_len


## Урон по площади у войск игроков: слабее (SPLASH_MUL) и задевает не больше SPLASH_MAX ближайших врагов —
## иначе толпа катапульт сносит любое войско. Нейтралов (дракона, духов) это не касается.
const SPLASH_MUL := 0.6
const SPLASH_MAX := 4


func _splash_hits(center: Vector2, radius: float, player: int, skip: int, capped: bool) -> Array:
	var hits: Array = []
	for oid in _units_near(center, radius):
		if oid != skip and units.has(oid) and enemies(int(units[oid]["player"]), player):
			hits.append([(units[oid]["pos"] as Vector2).distance_squared_to(center), int(oid)])
	if capped and hits.size() > SPLASH_MAX:
		hits.sort_custom(func(a, b) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
		hits.resize(SPLASH_MAX)
	var out: Array = []
	for h in hits:
		out.append(h[1])
	return out


func _damage(t: Dictionary, amount: float, dtype: String, attacker: int, attacker_player: int, attack := false) -> void:
	if t["def"].get("invulnerable", false) or t.has("merc_idle"):
		return
	var src = entity(attacker)
	if attack and float(t.get("evasion", 0.0)) > 0.0 and _roll(attacker, int(t["id"])) < float(t["evasion"]):
		events.append({"type": "float", "pos": t["pos"], "text": "промах", "color": "#c9ced6"})
		return
	var mult: float = float(combat.get("multipliers", {}).get(dtype, {}).get(String(t["armor_type"]), 1.0))
	if dtype == "holy" and t["def"].get("undead", false):
		mult *= HOLY_VS_UNDEAD      # святой урон особенно опасен для нежити
	if attack and src != null and not src["is_building"] and src["def"].has("vs_large") and not t["is_building"] and float(t["radius"]) >= LARGE_RADIUS:
		mult *= float(src["def"]["vs_large"])      # алебарды и копья против крупных: всадников, великанов, машин
	var armor: float = maxf(0.0, float(t["armor"])) * float(combat.get("armor_k", 0.06))
	var dealt: float = amount * mult * (1.0 - armor / (1.0 + armor)) * float(t.get("dmg_taken", 1.0))
	var hp_before := float(t["hp"])
	t["hp"] = float(t["hp"]) - dealt
	t["last_hit_by"] = attacker
	t["fought"] = tick
	if attack and src != null and not src["is_building"] and has_trait(src, "rage"):
		_add_rage(src)      # огры: каждый удар разжигает ярость
	if t["def"].get("boss", false) and attacker_player != NEUTRAL and players.has(attacker_player):
		var by: Dictionary = t.get("dmg_by", {})      # кто сколько урона нанёс боссу (добивание — не больше оставшегося здоровья)
		by[attacker_player] = float(by.get(attacker_player, 0.0)) + minf(dealt, maxf(0.0, hp_before))
		t["dmg_by"] = by
	events.append({"type": "hit", "id": t["id"]})
	if attack and src != null and not src["is_building"]:
		if src["def"].has("chill") and not t["is_building"]:      # холод глубин (наги): цель замедляется
			var ch: Dictionary = src["def"]["chill"]
			_add_buff(t, "chill", float(ch.get("duration", 2.0)), {"speed_mul": float(ch.get("speed_mul", 0.7)), "cooldown_mul": float(ch.get("cooldown_mul", 1.15))})
		if src["def"].has("poison") and not t["is_building"]:      # ядовитые когти и плевки
			_poison(t, src["def"]["poison"], attacker_player)
		if src["def"].has("bash") and not t["is_building"] and _roll(attacker, int(t["id"]) + 13) < float(src["def"]["bash"].get("chance", 0.2)):
			t["stun"] = maxi(int(t["stun"]), tick + int(float(src["def"]["bash"].get("stun", 1.0)) * TICK_RATE))      # оглушающий удар
			events.append({"type": "float", "player": attacker_player, "pos": t["pos"], "text": "оглушён", "color": "#ffd24a"})
		if float(src.get("lifesteal", 0.0)) > 0.0:      # вампиризм лечит атакующего
			src["hp"] = minf(float(src["max_hp"]), float(src["hp"]) + dealt * float(src["lifesteal"]))
		if float(t.get("thorns", 0.0)) > 0.0 and float(src["range"]) <= 2.0 and src != t:
			_damage(src, dealt * float(t["thorns"]), "magic", int(t["id"]), int(t["player"]))   # шипы ранят того, кто бьёт вблизи
	if float(t["hp"]) <= 0.0:
		_kill(t, attacker_player)
		return
	if t["is_building"] or not entity(attacker):
		return
	# получивший удар отвечает; нейтралы — всем лагерем
	if int(t["player"]) == NEUTRAL:
		for id in units:
			var mate: Dictionary = units[id]
			if int(mate["player"]) == NEUTRAL and int(mate["camp"]) == int(t["camp"]) and String(mate["order"].get("type")) != "attack" and float(mate["damage"]) > 0.0:
				_order_attack(mate, attacker, {})
	elif not is_worker(t) and float(t["damage"]) > 0.0:
		var kind := String(t["order"].get("type"))
		if kind == "idle" or kind == "amove":
			_order_attack(t, attacker, t["order"] if kind == "amove" else {})
	elif is_worker(t) and not _has_buff(t, "militia"):
		_flee(t, entity(attacker))      # рабочий не дерётся, а убегает


func _kill(t: Dictionary, killer_player: int) -> void:
	var owner: int = int(t["player"])
	if t["is_building"]:
		_set_solid(_rect(t), false)
		if t["done"]:
			players[owner]["supply_cap"] -= int(t["def"].get("supply_given", 0))
		for q in t["queue"]:
			if q.get("research", false):
				players[owner]["research_wip"].erase(q["key"])
				continue
			players[owner]["supply_used"] -= int(players[owner]["data"]["units"][q["key"]].get("supply", 0))
			if q.get("hero", false):
				if q.get("revive", false):
					players[owner]["heroes"][q["key"]] = {"state": "dead", "altar": -1, "level": int(q.get("level", 1)), "xp": int(q.get("xp", 0)), "items": q.get("items", []), "skills": q.get("skills", {})}
				else:
					players[owner]["heroes"].erase(q["key"])
		buildings.erase(t["id"])
		_bindex_dirty = true
		events.append({"type": "building_removed", "id": t["id"]})
		if players.has(killer_player) and killer_player != owner:
			players[killer_player]["stats"]["razed"] += 1
		if owner != NEUTRAL and not game_over:
			var left := false
			for id in buildings:
				if int(buildings[id]["player"]) == owner:
					left = true
			if not left:
				_defeat(owner)
		return
	players[owner]["supply_used"] -= int(t["def"].get("supply", 0))
	players[owner]["stats"]["lost"] += 1
	if players.has(killer_player) and killer_player != owner and int(t["expires"]) < 0:
		players[killer_player]["stats"]["killed"] += 1
	if t["hero"]:
		var hrec: Dictionary = players[owner]["heroes"].get(t["key"], {})
		players[owner]["heroes"][t["key"]] = {"state": "dead", "altar": int(hrec.get("altar", -1)), "level": int(t["level"]), "xp": int(t["xp"]), "items": t["items"], "skills": t["skills"]}
		_msg(owner, "%s пал. Его можно воскресить там, где он был нанят" % String(t["def"]["name"]))
	units.erase(t["id"])
	events.append({"type": "death", "id": t["id"]})
	_add_corpse(t)
	var killer = entity(int(t.get("last_hit_by", -1)))
	if killer != null and not killer["is_building"] and int(killer["player"]) != owner and has_trait(killer, "feast"):
		var gain := float(killer["max_hp"]) * FEAST_HEAL      # огры: добивание возвращает силы
		killer["hp"] = minf(float(killer["max_hp"]), float(killer["hp"]) + gain)
		events.append({"type": "float", "player": killer["player"], "pos": killer["pos"], "text": "+%d" % int(gain), "color": "#ff7a5a"})
		events.append({"type": "feast", "id": killer["id"]})
	_award_xp(t, killer_player)
	if t["def"].has("death_blast"):      # поганище лопается, задевая врагов вокруг
		_explode(t, t["def"]["death_blast"], t["pos"])
	if t["def"].has("split"):      # слизень делится на маленьких, гидра — на детёнышей
		var sp: Dictionary = t["def"]["split"]
		var own_kids: Dictionary = players[owner]["data"].get("summons", {}) if owner != NEUTRAL else {}
		for i in int(sp.get("count", 2)):
			var kdef: Dictionary = own_kids[String(sp["unit"])] if own_kids.has(String(sp["unit"])) else _scaled_def(String(sp["unit"]), float(t.get("power", 1.0)))
			var kid := spawn_unit(owner, String(sp["unit"]), kdef, (t["pos"] as Vector2) + Vector2(0.6, 0).rotated(float(i) * PI + float(t["id"])), false)
			if float(sp.get("lifetime", 0)) > 0.0:
				units[kid]["expires"] = tick + int(float(sp["lifetime"]) * TICK_RATE)
			units[kid]["camp"] = t["camp"]
			units[kid]["power"] = t.get("power", 1.0)
			if t.has("camp_level"):
				units[kid]["camp_level"] = t["camp_level"]
			units[kid]["home"] = t["home"]
			if owner == NEUTRAL and killer_player != NEUTRAL and entity(int(t.get("last_hit_by", -1))) != null:
				_order_attack(units[kid], int(t["last_hit_by"]), {})
	if t["def"].get("boss", false):
		_boss_slain(t)
	if t.has("caravan"):
		_caravan_looted(t, killer_player)
	if owner == NEUTRAL and int(t["camp"]) >= 0 and killer_player != NEUTRAL and players.has(killer_player):
		var left := false
		for id in units:
			if int(units[id]["player"]) == NEUTRAL and int(units[id]["camp"]) == int(t["camp"]):
				left = true
				break
		if not left:
			_camp_cleared(int(t.get("camp_level", t["def"].get("level", 1))), t["pos"], killer_player, int(t["camp"]))
	if int(t["bounty"]) > 0 and killer_player != NEUTRAL and players.has(killer_player):
		var bounty := int(t["bounty"]) * (3 if owner == NEUTRAL and blood_moon() else 2) / 2      # кровавая луна: награда ×1,5
		players[killer_player]["gold"] += bounty
		players[killer_player]["stats"]["gold"] += bounty
		events.append({"type": "bounty", "player": killer_player, "amount": bounty, "pos": t["pos"]})


## ---------- усиления игрока (действуют на всех его юнитов; видны справа на экране) ----------
const PBUFFS := {
	"dragon_gold": {"name": "Драконье золото", "desc": "Победа над красным драконом: рабочие добывают на 15% больше золота и дерева.", "icon": "coin", "color": "#ffb03a", "gather": 0.15, "time": 480},
}


func add_pbuff(player: int, key: String) -> void:
	var list: Array = players[player].get("pbuffs", [])
	list = list.filter(func(b) -> bool: return String(b["key"]) != key)
	list.append({"key": key, "until": tick + int(float(PBUFFS[key]["time"]) * TICK_RATE)})
	players[player]["pbuffs"] = list


## Действующие усиления игрока: [{key, until}] (истёкшие отбрасываются).
func pbuffs(player: int) -> Array:
	var out: Array = []
	for b in players[player].get("pbuffs", []):
		if int(b["until"]) < 0 or tick < int(b["until"]):
			out.append(b)
	return out


## Во сколько раз больше приносят рабочие игрока.
func gather_mul(player: int) -> float:
	var m := 1.0
	for b in pbuffs(player):
		m += float(PBUFFS[String(b["key"])].get("gather", 0.0))
	return m


## Босс повержен: игрок, нанёсший ему больше всего урона, получает «Силу дракона»
## для всех своих героев — нынешних и будущих.
func _boss_slain(t: Dictionary) -> void:
	var by: Dictionary = t.get("dmg_by", {})
	var best := -1
	var top := 0.0
	var keys: Array = by.keys()
	keys.sort()
	for p in keys:
		if float(by[p]) > top:
			top = float(by[p])
			best = int(p)
	if best < 0:
		return
	players[best]["dragon_buff"] = true
	add_pbuff(best, "dragon_gold")      # и рабочие победителя какое-то время добывают больше
	events.append({"type": "boss_slain", "player": best, "name": t["def"]["name"], "pos": t["pos"]})
	for p in players:
		if int(p) != NEUTRAL:
			_msg(int(p), "%s повержен! Больше всего урона нанёс игрок %d — его герои получают «Силу дракона», а рабочие — «Драконье золото»" % [t["def"]["name"], best + 1])


## Таблица юнита-нейтрала, усиленная множителем (для поздних лагерей).
func _scaled_def(key: String, power: float) -> Dictionary:
	var src: Dictionary = players[NEUTRAL]["data"]["units"].get(key, {})
	if power <= 1.001:
		return src
	var def: Dictionary = src.duplicate(true)
	def["hp"] = float(src.get("hp", 100)) * power
	def["damage"] = float(src.get("damage", 10)) * power
	def["bounty"] = int(float(src.get("bounty", 0)) * (0.5 + power * 0.5))
	def["name"] = "%s (сильный)" % src.get("name", key) if power >= 1.4 else src.get("name", key)
	return def


## ---------- новые лагеря нейтралов по ходу игры ----------
## Раз в RESPAWN_EVERY на свободном месте вдали от баз появляется новый лагерь.
## Чем дольше идёт игра, тем выше его уровень и тем сильнее нейтралы в нём.

const RESPAWN_EVERY := 900          # 90 секунд
var neutral_cap := 0               # больше этого числа нейтралов на карте не бывает
var _next_camp := 100000


func _respawn_camps() -> void:
	if tick % RESPAWN_EVERY != 0 or tick == 0:
		return
	var count := 0
	for id in units:
		if int(units[id]["player"]) == NEUTRAL and int(units[id]["expires"]) < 0 and not units[id].has("merc_idle"):
			count += 1
	if count >= neutral_cap:
		return
	var minutes := float(tick) / (60.0 * TICK_RATE)
	var level := clampi(1 + int(minutes / 4.0), 1, 6)
	var power := 1.0 + 0.06 * minutes          # +6% здоровья и урона за каждую минуту игры
	var options: Array = []
	for c in players[NEUTRAL]["data"]["camps"]:
		if int(c["level"]) == level:
			options.append(c)
	if options.is_empty():
		return
	for attempt in 40:
		var cell := Vector2i(int(_roll(attempt, 11) * map_size), int(_roll(attempt, 23) * map_size))
		var p := cell_center(cell)
		if not can_place(3, cell - Vector2i(1, 1)):
			continue
		var ok := true
		for bid in buildings:
			if int(buildings[bid]["player"]) != NEUTRAL and (buildings[bid]["pos"] as Vector2).distance_to(p) < 18.0:
				ok = false
				break
		if ok:
			for id in _units_near(p, 9.0):
				ok = false
				break
		if not ok:
			continue
		var camp: Dictionary = options[int(_roll(attempt, 37) * options.size()) % options.size()]
		var keys: Array = camp["units"].keys()
		keys.sort()
		var n := 0
		for key in keys:
			for i in int(camp["units"][key]):
				var off := Vector2(1.5, 0).rotated(float(n) * 2.1)
				var id := spawn_unit(NEUTRAL, String(key), _scaled_def(String(key), power), p + off, false)
				units[id]["camp"] = _next_camp
				units[id]["camp_level"] = level
				units[id]["power"] = power
				units[id]["home"] = units[id]["pos"]
				n += 1
		_next_camp += 1
		events.append({"type": "camp_spawned", "pos": p, "level": level})
		return


## ---------- руны силы ----------
## На симметричных местах карты появляются руны. Первая — на 1-й минуте, дальше каждые 2 минуты
## (если место свободно). Руну берёт любой юнит, наступивший на неё; усиление получают он
## и свои юниты рядом (в радиусе RUNE_RADIUS).

const RUNE_FIRST := 600
const RUNE_EVERY := 1200
const RUNE_RADIUS := 4.5
const RUNE_INFO := {
	"haste": {"name": "Руна скорости", "color": "#ffd24a", "text": "бег +60% на 30 с", "duration": 30.0, "mods": {"speed_mul": 1.6}},
	"might": {"name": "Руна мощи", "color": "#ff5a3a", "text": "урон +50% на 30 с", "duration": 30.0, "mods": {"damage_mul": 1.5}},
	"regen": {"name": "Руна жизни", "color": "#6dff7a", "text": "+40 здоровья и +5 маны в секунду на 10 с", "duration": 10.0, "mods": {"hp_regen": 40.0, "mana_regen": 5.0}},
	"gold": {"name": "Руна богатства", "color": "#ffe9a0", "text": "+150 золота и +60 дерева", "duration": 0.0, "mods": {}},
}
var runes: Dictionary = {}        # id -> {id, kind, pos}
var rune_spots: Array = []        # где появляются руны


func _update_runes() -> void:
	if tick >= RUNE_FIRST and (tick - RUNE_FIRST) % RUNE_EVERY == 0:
		var kinds: Array = RUNE_INFO.keys()
		kinds.sort()
		for i in rune_spots.size():
			var spot: Vector2 = rune_spots[i]
			var busy := false
			for rid in runes:
				busy = busy or (runes[rid]["pos"] as Vector2).distance_to(spot) < 0.5
			if not busy:
				var id := _new_id()
				runes[id] = {"id": id, "kind": String(kinds[int(_roll(i + 1, 4111) * kinds.size()) % kinds.size()]), "pos": spot}
				events.append({"type": "rune_added", "id": id})
	if tick % 2 != 0 or runes.is_empty():
		return
	var ids: Array = runes.keys()
	ids.sort()
	for rid in ids:
		var r: Dictionary = runes[rid]
		for uid in _units_near(r["pos"], 0.5):
			var u: Dictionary = units[uid]
			if int(u["player"]) == NEUTRAL or String(u["def"].get("role", "")) == "ward":
				continue
			_take_rune(u, r)
			break


func _take_rune(u: Dictionary, r: Dictionary) -> void:
	var player := int(u["player"])
	var info: Dictionary = RUNE_INFO[r["kind"]]
	runes.erase(r["id"])
	events.append({"type": "rune_taken", "id": r["id"], "player": player, "kind": r["kind"], "pos": r["pos"]})
	events.append({"type": "blast", "pos": r["pos"], "radius": RUNE_RADIUS, "color": info["color"]})
	if String(r["kind"]) == "gold":
		players[player]["gold"] += 150
		players[player]["wood"] += 60
		players[player]["stats"]["gold"] += 150
		players[player]["stats"]["wood"] += 60
	else:
		for id in _units_near(r["pos"], RUNE_RADIUS):
			if int(units[id]["player"]) == player:
				_add_buff(units[id], "rune_" + String(r["kind"]), float(info["duration"]), info["mods"])
	_msg(player, "%s: %s" % [info["name"], info["text"]])


## ---------- караваны разбойников ----------
## Время от времени по карте проходит караван: повозка с награбленным и охрана.
## Он идёт по кругу через несколько дальних точек. Разбейте повозку — золото и артефакт ваши.
## Чем позже, тем богаче и сильнее караваны.

const CARAVAN_FIRST := 1500
const CARAVAN_EVERY := 2400
var caravans: Dictionary = {}      # id -> {id, route, leg, wagon, guards, camp, level, power}
var _next_caravan := 1


func _caravan_limit() -> int:
	return 1 + (1 if map_size >= 192 else 0) + (1 if map_size >= 272 else 0)


## Главные здания игроков — от них держатся подальше караваны, метеориты и торговцы.
func _halls() -> Array:
	var out: Array = []
	var ids: Array = buildings.keys()
	ids.sort()
	for id in ids:
		var b: Dictionary = buildings[id]
		if int(b["player"]) != NEUTRAL and String(b["def"].get("role", "")) == "hall":
			out.append(b["pos"])
	return out


## Случайное свободное место size×size, не ближе min_base к базам. salt — чтобы места отличались.
func _random_spot(size: int, min_base: float, salt: int) -> Vector2:
	var halls := _halls()
	for attempt in 80:
		var p := Vector2(8 + _roll(attempt, salt) * (map_size - 16), 8 + _roll(attempt, salt + 1) * (map_size - 16))
		var cell := to_cell(p) - Vector2i(size / 2, size / 2)
		if not can_place(size + 2, cell - Vector2i(1, 1)):
			continue
		var ok := true
		for h in halls:
			ok = ok and p.distance_to(h) >= min_base
		if ok:
			return cell_center(to_cell(p))
	return Vector2(-1, -1)


func _spawn_caravan() -> void:
	var route: Array = []
	for attempt in 40:
		if route.size() >= 3:
			break
		var p := _random_spot(1, 20.0, 7001 + tick + attempt * 13)
		if p.x < 0.0:
			continue
		var ok := true
		for q in route:
			ok = ok and p.distance_to(q) > map_size * 0.28
		if ok and (route.is_empty() or path_exists(route[0], p)):
			route.append(p)
	if route.size() < 2:
		return
	var minutes := float(tick) / (60.0 * TICK_RATE)
	var level := clampi(3 + int(minutes / 6.0), 3, 6)
	var power := 1.0 + 0.05 * minutes
	var cid := _next_caravan
	_next_caravan += 1
	var camp := 300000 + cid
	var wagon := spawn_unit(NEUTRAL, "caravan_wagon", _scaled_def("caravan_wagon", power), route[0], false)
	var crew: Array = [["bandit", 3]]
	if level >= 4:
		crew.append(["poacher", 1])
	if level >= 5:
		crew.append(["bandit_lord", 1])
	if level >= 6:
		crew = [["bandit", 4], ["poacher", 2], ["bandit_lord", 2]]
	var guards: Array = []
	for pair in crew:
		for i in int(pair[1]):
			var g := spawn_unit(NEUTRAL, String(pair[0]), _scaled_def(String(pair[0]), power), (route[0] as Vector2) + Vector2(1.6, 0).rotated(guards.size() * 1.3), false)
			guards.append(g)
	for id in [wagon] + guards:
		units[id]["camp"] = camp
		units[id]["camp_level"] = level
		units[id]["power"] = power
		units[id]["home"] = units[id]["pos"]
	units[wagon]["caravan"] = cid
	caravans[cid] = {"id": cid, "route": route, "leg": 1, "wagon": wagon, "guards": guards, "camp": camp, "level": level, "power": power}
	events.append({"type": "caravan_spawned", "pos": route[0], "level": level})


func _update_caravans() -> void:
	if tick >= CARAVAN_FIRST and (tick - CARAVAN_FIRST) % CARAVAN_EVERY == 0 and caravans.size() < _caravan_limit():
		_spawn_caravan()
	if tick % 5 != 0 or caravans.is_empty():
		return
	var cids: Array = caravans.keys()
	cids.sort()
	for cid in cids:
		var c: Dictionary = caravans[cid]
		if not units.has(int(c["wagon"])):
			caravans.erase(cid)      # повозку разбили — охрана остаётся простыми разбойниками
			continue
		var alive: Array = []
		var fighting := false
		for gid in c["guards"]:
			if units.has(gid):
				alive.append(gid)
				fighting = fighting or String(units[gid]["order"].get("type")) == "attack"
		c["guards"] = alive
		if fighting:
			continue      # охрана дерётся — повозка ждёт
		var w: Dictionary = units[int(c["wagon"])]
		var route: Array = c["route"]
		var target: Vector2 = route[int(c["leg"])]
		if (w["pos"] as Vector2).distance_to(target) < 2.5:
			c["leg"] = (int(c["leg"]) + 1) % route.size()
			target = route[int(c["leg"])]
		if String(w["order"].get("type")) != "move" or not is_moving(w):
			w["order"] = {"type": "move", "dest": target}
			_path_to(w, target)
		w["home"] = w["pos"]
		var side := Vector2(-(w["facing"] as Vector2).y, (w["facing"] as Vector2).x)
		for i in alive.size():
			var g: Dictionary = units[alive[i]]
			g["home"] = g["pos"]
			var slot: Vector2 = (w["pos"] as Vector2) - (w["facing"] as Vector2) * (0.6 + 1.1 * (i / 2)) + side * (1.3 if i % 2 == 0 else -1.3)
			if (g["pos"] as Vector2).distance_to(slot) > 1.6 and (not is_moving(g) or (tick + i) % 20 == 0):
				g["order"] = {"type": "move", "dest": slot}
				_path_to(g, slot)


## Повозка каравана разбита: золото и гарантированный артефакт.
func _caravan_looted(t: Dictionary, killer_player: int) -> void:
	var gold := int(150.0 * float(t.get("power", 1.0)))
	if players.has(killer_player) and killer_player != NEUTRAL:
		players[killer_player]["gold"] += gold
		players[killer_player]["stats"]["gold"] += gold
		events.append({"type": "float", "player": killer_player, "pos": t["pos"], "text": "Караван! +%d" % gold, "color": "#ffd940"})
	var pool: Array = players[NEUTRAL]["data"].get("camp_rewards", {}).get("6", {}).get("items", [])
	if not pool.is_empty():
		add_loot(String(pool[int(_roll(int(t["id"]), 4242) * pool.size()) % pool.size()]), t["pos"])
	events.append({"type": "caravan_looted", "player": killer_player, "pos": t["pos"]})


## ---------- случайные события мира ----------
## Раз в несколько минут в мире что-то происходит. Что именно и где — решает зерно партии,
## поэтому у всех игроков сетевой игры события одинаковые, но каждая партия — своя.

const WEV_FIRST := 2100
const WEV_EVERY := 2700
const WORLD_EVENTS := ["meteor", "invasion", "merchant", "gold_rush", "blood_moon", "storm"]
var world: Dictionary = {"last": "", "gold_rush": 0, "storm": 0, "blood_cycle": -1, "merchant": -1, "merchant_until": 0}


func _update_world_events() -> void:
	if tick >= WEV_FIRST and (tick - WEV_FIRST) % WEV_EVERY == 0:
		_world_event()
	if int(world["merchant"]) >= 0 and tick >= int(world["merchant_until"]):
		var mb = buildings.get(int(world["merchant"]))
		if mb != null:
			_set_solid(_rect(mb), false)
			buildings.erase(mb["id"])
			_bindex_dirty = true
			events.append({"type": "building_removed", "id": mb["id"]})
		world["merchant"] = -1
	if tick < int(world["storm"]) and tick % 35 == 0:      # гроза: молнии бьют в случайные места
		var p := Vector2(_roll(tick, 515) * map_size, _roll(tick, 616) * map_size)
		events.append({"type": "lightning", "pos": p})
		for id in _units_near(p, 1.6):
			_damage(units[id], 70.0, "magic", -1, NEUTRAL)


func _world_event(force: String = "") -> void:
	var k := String(WORLD_EVENTS[int(_roll(tick, 31337) * WORLD_EVENTS.size()) % WORLD_EVENTS.size()]) if force == "" else force
	if k == String(world["last"]) and force == "":
		k = String(WORLD_EVENTS[(WORLD_EVENTS.find(k) + 1) % WORLD_EVENTS.size()])
	world["last"] = k
	var minutes := float(tick) / (60.0 * TICK_RATE)
	var ev := {"type": "world_event", "kind": k, "pos": Vector2(-1, -1), "player": -1}
	match k:
		"meteor":      # падает метеорит: взрыв и новое богатое месторождение золота
			var p := _random_spot(3, 18.0, 9100 + tick)
			if p.x < 0.0:
				return
			for id in _units_near(p, 3.5):
				_damage(units[id], 200.0, "magic", -1, NEUTRAL)
			var rid := add_resource("gold", to_cell(p) - Vector2i(1, 1), 3)
			resources[rid]["amount"] = 2500
			resources[rid]["meteor"] = true
			events.append({"type": "resource_added", "id": rid})
			ev["pos"] = p
		"invasion":    # орда монстров идёт на базу случайного игрока
			var alive := active_players()
			if alive.is_empty():
				return
			var victim: int = alive[int(_roll(tick, 4040) * alive.size()) % alive.size()]
			var hall := Vector2(-1, -1)
			for id in buildings:
				if int(buildings[id]["player"]) == victim and String(buildings[id]["def"].get("role", "")) == "hall":
					hall = buildings[id]["pos"]
			if hall.x < 0.0:
				return
			var from := Vector2(-1, -1)
			for attempt in 60:
				var q := hall + Vector2(22.0 + 8.0 * _roll(attempt, 5151 + tick), 0).rotated(_roll(attempt, 5050 + tick) * TAU)
				var inside := q.x > 3.0 and q.y > 3.0 and q.x < map_size - 3.0 and q.y < map_size - 3.0
				if inside and not is_blocked(to_cell(q)) and path_exists(q, hall):
					from = q
					break
			if from.x < 0.0:
				return
			var level := clampi(2 + int(minutes / 5.0), 2, 6)
			var options: Array = []
			for c in players[NEUTRAL]["data"]["camps"]:
				if int(c["level"]) == level:
					options.append(c)
			if options.is_empty():
				return
			var camp: Dictionary = options[int(_roll(tick, 6060) * options.size()) % options.size()]
			var keys: Array = camp["units"].keys()
			keys.sort()
			var n := 0
			for key in keys:
				for i in int(camp["units"][key]) + 1:
					var id := spawn_unit(NEUTRAL, String(key), _scaled_def(String(key), 1.0 + 0.05 * minutes), from + Vector2(1.4, 0).rotated(n * 1.1), false)
					units[id]["camp"] = _next_camp
					units[id]["camp_level"] = level
					units[id]["raider"] = true
					units[id]["home"] = units[id]["pos"]
					units[id]["order"] = {"type": "amove", "dest": hall}
					_path_to(units[id], hall)
					n += 1
			_next_camp += 1
			ev["pos"] = from
			ev["player"] = victim
		"merchant":    # бродячий торговец с артефактами — 2,5 минуты
			var p := _random_spot(3, 22.0, 7300 + tick)
			var def: Dictionary = players[NEUTRAL]["data"]["buildings"].get("merchant", {})
			if p.x < 0.0 or def.is_empty():
				return
			var bid := spawn_building(NEUTRAL, "merchant", def, to_cell(p) - Vector2i(1, 1))
			world["merchant"] = bid
			world["merchant_until"] = tick + 1500
			ev["pos"] = p
		"gold_rush":   # золотая лихорадка: полторы минуты рудники дают в полтора раза больше
			world["gold_rush"] = tick + 900
		"blood_moon":  # кровавая луна: ближайшей ночью нейтралы злее и богаче
			world["blood_cycle"] = tick / DAY_CYCLE
		"storm":       # гроза: полторы минуты бьют молнии, видно хуже
			world["storm"] = tick + 900
	events.append(ev)


func blood_moon() -> bool:
	return is_night() and int(world.get("blood_cycle", -1)) == tick / DAY_CYCLE


func storm() -> bool:
	return tick < int(world.get("storm", 0))


## ---------- день и ночь ----------
## Сутки длятся 6 минут: 4 минуты день, 2 минуты ночь. Ночью обзор юнитов меньше
## (кроме эльфов), а нежить восстанавливает здоровье.

const DAY_CYCLE := 3600
const DAY_LEN := 2400
const NIGHT_UNDEAD_REGEN := 3.0


func is_night() -> bool:
	return tick % DAY_CYCLE >= DAY_LEN


## Сколько секунд до смены дня и ночи.
func phase_left() -> float:
	var t := tick % DAY_CYCLE
	return float((DAY_LEN - t) if t < DAY_LEN else (DAY_CYCLE - t)) * TICK_DT


## Игрок потерял все здания: он выбывает, его войско рассыпается.
## Когда остаётся один игрок — партия окончена, он победил.
func _defeat(player: int) -> void:
	if players[player].get("defeated", false):
		return
	players[player]["defeated"] = true
	events.append({"type": "defeated", "player": player})
	var ids: Array = units.keys()
	ids.sort()
	for id in ids:
		if units.has(id) and int(units[id]["player"]) == player:
			_kill(units[id], NEUTRAL)
	var alive: Array = active_players()
	var sides := {}
	for p in alive:
		sides[_side[p]] = true
	if sides.size() <= 1 and not game_over:      # остались только союзники — они победили вместе
		game_over = true
		var winners: Array = []
		if not alive.is_empty():
			for p in players:
				if int(p) != NEUTRAL and not enemies(int(p), int(alive[0])):
					winners.append(int(p))
			winners.sort()
		events.append({"type": "game_over", "winner": alive[0] if not alive.is_empty() else -1, "winners": winners})


## Игроки (не нейтралы), которые ещё в игре.
func active_players() -> Array:
	var out: Array = []
	for p in players:
		if int(p) != NEUTRAL and not players[p].get("defeated", false):
			out.append(int(p))
	out.sort()
	return out


func _update_building(b: Dictionary) -> void:
	if not b["done"]:
		if b.get("auto", false):      # нежить: призванное здание растёт само
			_advance_build(b)
		if int(b["player"]) != NEUTRAL:
			_guards_vs_site(b)      # стройка под носом у лагеря будит нейтралов
		return
	if b["def"].has("well"):
		_update_well(b)
	match String(b["def"].get("role", "")):
		"capture":
			_update_capture(b)
		"mercenary":
			_update_merc(b)
		"fountain":
			if (tick + int(b["id"])) % TICK_RATE == 0:      # раз в секунду лечит всех рядом
				for id in _units_near(b["pos"], float(b["def"].get("radius_heal", 5.0)) + float(b["radius"])):
					var u: Dictionary = units[id]
					u["hp"] = minf(float(u["max_hp"]), float(u["hp"]) + float(u["max_hp"]) * float(b["def"].get("heal_pct", 0.03)))
					u["mana"] = minf(float(u["max_mana"]), float(u["mana"]) + float(b["def"].get("mana_heal", 2.0)))
	var queue: Array = b["queue"]
	if not queue.is_empty():
		var q: Dictionary = queue[0]
		q["left"] = float(q["left"]) - TICK_DT
		if float(q["left"]) <= 0.0:
			queue.pop_front()
			if q.get("research", false):
				_finish_research(b, q)
			else:
				_finish_train(b, q)
	# башни стреляют сами
	if float(b["def"].get("damage", 0)) > 0.0:
		b["cd"] = maxf(0.0, float(b["cd"]) - TICK_DT)
		if float(b["cd"]) <= 0.0 and (tick + int(b["id"])) % 2 == 0:
			var target := _nearest_enemy(b["pos"], int(b["player"]), float(b["def"].get("range", 7.0)) + float(b["radius"]), false)
			if target >= 0:
				b["cd"] = float(b["def"].get("attack_cooldown", 1.5))
				var dtype := String(b["def"].get("damage_type", "pierce"))
				_shoot(b["pos"], units[target], float(b["def"]["damage"]), dtype, int(b["id"]), int(b["player"]), "rock" if dtype == "siege" else "arrow", 3.0)


## Заброшенная шахта гоблинов: её захватывает тот, чьи юниты стоят рядом одни,
## и хозяин получает немного золота раз в минуту.
func _update_capture(b: Dictionary) -> void:
	var owner := int(b.get("owner", -1))
	if owner >= 0 and int(b["def"].get("income", 40)) > 0 and tick >= int(b.get("next_income", 0)):     # доход раз в минуту
		b["next_income"] = tick + int(float(b["def"].get("income_every", 60)) * TICK_RATE)
		var gold := int(b["def"].get("income", 40))
		players[owner]["gold"] += gold
		players[owner]["stats"]["gold"] += gold
		events.append({"type": "float", "player": owner, "pos": b["pos"], "text": "+%d" % gold, "color": "#ffd940"})
	if (tick + int(b["id"])) % 5 != 0:
		return
	var here: Dictionary = {}      # кто стоит у шахты
	var reach: float = float(b["def"].get("capture_radius", 4.0)) + float(b["radius"])
	for id in _units_near(b["pos"], reach + 2.0):
		var u: Dictionary = units[id]
		if String(u["def"].get("role", "")) == "ward":
			continue      # глаз-наблюдатель ничего не захватывает
		if int(u["player"]) == NEUTRAL or (u["pos"] as Vector2).distance_to(b["pos"]) <= reach:
			here[int(u["player"])] = true
	b["guarded"] = here.has(NEUTRAL)
	var who := -1      # захватывает только тот, кто стоит у шахты один (или с союзниками) и уже разбил охрану
	if not here.is_empty() and not here.has(NEUTRAL):
		var ps: Array = here.keys()
		ps.sort()
		who = int(ps[0])
		for p in ps:
			if enemies(int(p), who):
				who = -1
				break
		if who >= 0 and owner >= 0 and not enemies(owner, who):
			who = owner      # союзник у шахты союзника её не отбирает
	if who >= 0 and who != owner:
		if int(b.get("cap_by", -1)) != who:
			b["cap"] = 0.0
		b["cap_by"] = who
		b["cap"] = float(b.get("cap", 0.0)) + 0.5
		if float(b["cap"]) >= float(b["def"].get("capture_time", 6)):
			b["owner"] = who
			b["cap"] = 0.0
			b["cap_by"] = -1
			b["next_income"] = tick + int(float(b["def"].get("income_every", 60)) * TICK_RATE)
			events.append({"type": "captured", "id": b["id"], "player": who})
			var bname := String(b["def"].get("name", "Строение"))
			if int(b["def"].get("income", 40)) > 0:
				_msg(who, "%s захвачена: +%d золота каждую минуту" % [bname, int(b["def"].get("income", 40))])
			else:
				_msg(who, "%s захвачена: ваша команда видит всё вокруг неё" % bname)
			if owner >= 0:
				_msg(owner, "Противник отбил у вас: %s!" % bname.to_lower())
	else:
		b["cap"] = maxf(0.0, float(b.get("cap", 0.0)) - 0.5)


# ---------- лагеря наёмников ----------
## У каждого лагеря свой вид (притон разбойников, логово троллей, стоянка огров, гоблинская
## мастерская, пристань мурлоков) и свой набор бойцов. У каждого бойца — запас на складе,
## который понемногу пополняется. Свободные наёмники сидят у костра (их видно), а нанятый
## сам идёт к тому, кто его нанял. С середины партии в одном лагере ждёт легендарный капитан.

const CAPTAIN_AT := 5400          # 9 минут: появляется легендарный наёмник


func merc_theme(b: Dictionary) -> Dictionary:
	return players[NEUTRAL]["data"].get("merc_camps", {}).get(String(b.get("merc", "")), {})


## Предложения лагеря: {ключ: {gold, wood, stock, restock}} (с капитаном, если он здесь).
func merc_offers(b: Dictionary) -> Dictionary:
	var offers: Dictionary = (merc_theme(b).get("offers", {}) as Dictionary).duplicate()
	if b.get("captain", false):
		offers["merc_captain"] = {"gold": 650, "stock": 1, "restock": 0}
	return offers


func merc_def(key: String) -> Dictionary:
	return players[NEUTRAL]["data"].get("mercs", {}).get(key, {})


func _merc_init(b: Dictionary) -> void:
	var themes: Array = (players[NEUTRAL]["data"].get("merc_camps", {}) as Dictionary).keys()
	if themes.is_empty():
		return
	themes.sort()
	b["merc"] = String(themes[absi(hash(seed_value * 31 + int(b["id"]) * 17)) % themes.size()])      # у всех игроков одинаково
	b["stock"] = {}
	b["restock_at"] = {}
	b["idle"] = {}      # ключ бойца -> id наёмника, сидящего у костра
	for key in merc_offers(b):
		b["stock"][key] = int(merc_offers(b)[key].get("stock", 1))


func _update_merc(b: Dictionary) -> void:
	if not b.has("merc"):
		_merc_init(b)
	if (tick + int(b["id"])) % 10 != 0:
		return
	if tick >= CAPTAIN_AT and not b.get("captain", false) and not world.get("captain_placed", false):
		var camps: Array = []
		for id in buildings:
			if String(buildings[id]["def"].get("role", "")) == "mercenary":
				camps.append(int(id))
		camps.sort()
		if not camps.is_empty() and camps[absi(hash(seed_value + 77)) % camps.size()] == int(b["id"]):
			world["captain_placed"] = true
			b["captain"] = true
			b["stock"]["merc_captain"] = 1
			events.append({"type": "world_event", "kind": "captain", "pos": b["pos"], "player": -1})
	var offers := merc_offers(b)
	for key in offers:      # пополнение склада: по одному бойцу раз в restock секунд
		var o: Dictionary = offers[key]
		var have := int(b["stock"].get(key, 0))
		if have < int(o.get("stock", 1)) and float(o.get("restock", 0)) > 0.0:
			if not b["restock_at"].has(key):
				b["restock_at"][key] = tick + int(float(o["restock"]) * TICK_RATE)
			elif tick >= int(b["restock_at"][key]):
				b["stock"][key] = have + 1
				b["restock_at"].erase(key)
		_merc_idle(b, key, int(b["stock"].get(key, 0)) > 0)


## Свободный наёмник у костра: стоит, пока есть кому стоять; его нельзя ни ударить, ни выбрать целью.
func _merc_idle(b: Dictionary, key: String, want: bool) -> void:
	var id := int(b["idle"].get(key, -1))
	var has := units.has(id)
	if want and not has:
		var keys: Array = merc_offers(b).keys()
		keys.sort()
		var a: float = TAU * float(keys.find(key)) / maxf(1.0, float(keys.size())) + float(b["id"])
		var spot: Vector2 = (b["pos"] as Vector2) + Vector2(float(b["radius"]) + 1.6, 0).rotated(a)
		var nid := spawn_unit(NEUTRAL, key, merc_def(key), spot, false)
		units[nid]["merc_idle"] = int(b["id"])
		units[nid]["facing"] = ((b["pos"] as Vector2) - (units[nid]["pos"] as Vector2)).normalized()
		b["idle"][key] = nid
	elif not want and has:
		units.erase(id)
		events.append({"type": "unit_removed", "id": id})
		b["idle"].erase(key)


## {"type": "hire", "player": 0, "building": id лагеря наёмников, "unit": "troll_berserk"}
func _cmd_hire(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var b = buildings.get(cmd.get("building"))
	var key := String(cmd.get("unit", ""))
	if b == null or String(b["def"].get("role", "")) != "mercenary":
		return
	if not b.has("merc"):
		_merc_init(b)
	var offers := merc_offers(b)
	if not offers.has(key) or merc_def(key).is_empty():
		return
	var offer: Dictionary = offers[key]
	var def: Dictionary = merc_def(key).duplicate()
	var buyer := -1      # кто нанимает: ближайший к лагерю свой юнит (герой — в первую очередь)
	var best := SHOP_RANGE + float(b["radius"]) + 0.01
	for id in units:
		var u: Dictionary = units[id]
		if int(u["player"]) != player:
			continue
		var d: float = (u["pos"] as Vector2).distance_to(b["pos"]) - (2.0 if u["hero"] else 0.0)
		if d < best or (d == best and int(id) < buyer):
			best = d
			buyer = int(id)
	if buyer < 0:
		_msg(player, "Подведите к лагерю наёмников любого своего юнита")
	elif int(b["stock"].get(key, 0)) <= 0:
		_msg(player, "%s закончились — ждите пополнения" % String(def["name"]))
	elif int(players[player]["supply_used"]) + int(def.get("supply", 2)) > supply_max(player):
		_msg(player, "Не хватает лимита")
	elif not can_afford(player, offer):
		_msg(player, "Не хватает золота")
	else:
		_pay(player, offer)
		b["stock"][key] = int(b["stock"][key]) - 1
		def["bounty"] = 0
		var spot: Vector2 = b["pos"]
		var idle_id := int(b["idle"].get(key, -1))
		if units.has(idle_id):      # нанятый — тот самый, что сидел у костра
			spot = units[idle_id]["pos"]
		if int(b["stock"][key]) <= 0:
			_merc_idle(b, key, false)
		var nid := spawn_unit(player, key, def, spot)
		units[nid]["order"] = {"type": "follow", "target": buyer}      # сам идёт к нанявшему
		if key == "merc_captain":
			b["captain"] = false
			b["stock"].erase(key)
		events.append({"type": "bought", "player": player, "id": nid, "item": "", "hired": def["name"]})
		events.append({"type": "blast", "pos": spot, "radius": 1.0, "color": "#ffd24a"})


# ---------- способности героев, усиления, ауры ----------

var _auras: Array = []
var _aura_self: Dictionary = {}    # у кого из юнитов есть личные бонусы (id -> true)
var _aura_area: Array = []          # ауры по площади: [центр, радиус, игрок]
var _up_ver: Dictionary = {}      # игрок -> сколько раз менялись его улучшения (для быстрого пути _refresh_stats)


func ability(u: Dictionary, key: String) -> Variant:
	for ab in u["def"].get("abilities", []):
		if String(ab["key"]) == key:
			return ab
	return null


func _units_near(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	for id in _candidates(pos, radius):
		if units.has(id) and (units[id]["pos"] as Vector2).distance_to(pos) <= radius + float(units[id]["radius"]):
			out.append(int(id))
	out.sort()
	return out


## Раз в тик собираем пассивные способности героев: ауры и личные бонусы.
func _collect_auras(ids: Array) -> void:
	_auras.clear()
	_aura_self.clear()
	_aura_area.clear()
	for id in ids:
		var u: Dictionary = units[id]
		if u["def"].has("aura") and not u.has("merc_idle"):      # аура обычного юнита (знаменосец)
			_auras.append({"player": u["player"], "pos": u["pos"], "radius": float(u["def"]["aura"]["radius"]), "mods": u["def"]["aura"]["mods"], "only": -1})
		if not u["hero"]:
			continue
		for ab in u["def"].get("abilities", []):
			var r := rank(u, String(ab["key"]))
			if String(ab["type"]) != "passive" or r <= 0:
				continue
			if ab.has("aura"):
				_auras.append({"player": u["player"], "pos": u["pos"], "radius": float(ab["aura"]["radius"]), "mods": scaled_mods(ab["aura"]["mods"], r), "only": -1})
			if ab.has("self_mods"):
				_auras.append({"player": u["player"], "pos": u["pos"], "radius": 0.0, "mods": scaled_mods(ab["self_mods"], r), "only": int(id)})
	for a in _auras:      # для быстрой проверки «действует ли на юнита хоть что-то»
		if int(a["only"]) >= 0:
			_aura_self[int(a["only"])] = true
		else:
			_aura_area.append([a["pos"], float(a["radius"]), int(a["player"])])


## Текущие характеристики = базовые + временные усиления + ауры + предметы.
## Виды изменений: armor_add, damage_add, damage_mul, cooldown_mul, speed_mul, hp_regen, mana_regen,
## crit_chance, evasion, lifesteal, thorns, damage_taken_mul (hp_add и mana_add — при получении предмета).
func _refresh_stats(u: Dictionary) -> void:
	var d: Dictionary = u["def"]      # врождённые свойства (у сильных нейтралов)
	# Быстрый путь: без усилений, предметов и аур характеристики зависят только от немногих
	# условий (ночь, кровавая луна, окоп, уровень, изученные улучшения). Если ни одно не
	# изменилось с прошлого раза — пересчитывать нечего. Так большинство юнитов в тик почти ничего не стоят.
	var dyn: bool = not (u["buffs"] as Array).is_empty() or not (u["items"] as Array).is_empty()
	if not dyn:
		dyn = _aura_self.has(int(u["id"]))
	if not dyn:
		var up: Vector2 = u["pos"]
		for a in _aura_area:
			if (a[0] as Vector2).distance_squared_to(up) <= float(a[1]) * float(a[1]) and not enemies(int(a[2]), int(u["player"])):
				dyn = true
				break
	var dug: bool = int(u.get("still", 0)) >= ENTRENCH_TICKS and has_trait(u, "entrench") and float(u["base"]["speed"]) > 0.0
	if dyn:
		u["_sk"] = -1
	else:
		var sig: int = (1 if dug else 0) | (2 if d.get("undead", false) and is_night() else 0) \
			| (4 if int(u["player"]) == NEUTRAL and blood_moon() else 0) | (8 if u["hero"] and players[u["player"]].get("dragon_buff", false) else 0) \
			| (16 if u.get("high", false) else 0) | (int(_up_ver.get(int(u["player"]), 0)) << 5) | (int(u["level"]) << 21)
		if int(u.get("_sk", -1)) == sig:
			return
		u["_sk"] = sig
	var m := {"armor_add": 0.0, "damage_mul": 1.0, "damage_add": 0.0, "cooldown_mul": 1.0, "speed_mul": 1.0, "hp_regen": float(d.get("hp_regen", 0)), "mana_regen": 0.0, "hp_add": 0.0,
		"crit_chance": float(d.get("crit_chance", 0)), "evasion": float(d.get("evasion", 0)), "lifesteal": float(d.get("lifesteal", 0)), "thorns": float(d.get("thorns", 0)), "damage_taken_mul": 1.0}
	for ik in u["items"]:      # предметы героя
		_mix(m, item_def(String(ik)).get("mods", {}))
	if d.get("undead", false) and is_night():
		m["hp_regen"] = float(m["hp_regen"]) + NIGHT_UNDEAD_REGEN      # нежить крепнет ночью
	if int(u["player"]) == NEUTRAL and blood_moon():
		_mix(m, {"damage_mul": 1.3, "speed_mul": 1.1})      # кровавая луна: нейтралы злее
	u["entrenched"] = dug
	if u["entrenched"]:
		_mix(m, ENTRENCH_MODS)      # гномы: постоял — окопался
	if u["hero"] and players[u["player"]].get("dragon_buff", false):
		_mix(m, DRAGON_MODS)      # «Сила дракона» за победу над боссом
	var buffs: Array = u["buffs"]
	var i := buffs.size() - 1
	while i >= 0:
		if tick >= int(buffs[i]["until"]):
			buffs.remove_at(i)
		else:
			_mix(m, buffs[i]["mods"])
		i -= 1
	for a in _auras:
		if enemies(int(a["player"]), int(u["player"])):      # ауры действуют и на союзников
			continue
		if int(a["only"]) >= 0:
			if int(a["only"]) == int(u["id"]):
				_mix(m, a["mods"])
		elif (a["pos"] as Vector2).distance_to(u["pos"]) <= float(a["radius"]):
			_mix(m, a["mods"])
	var ups: Dictionary = players[u["player"]].get("upgrades", {})
	for key in ups:     # изученные улучшения: на всех юнитов игрока или только на некоторых
		var up: Dictionary = players[u["player"]]["data"]["upgrades"][key]
		if not upgrade_applies(u, up):
			continue
		var umods: Dictionary = up["mods"]
		var lvl: float = float(ups[key])
		for mk in umods:
			if mk in ["hp_add", "carry_add"]:
				continue      # здоровье прибавляется один раз, ноша — при добыче
			if String(mk).ends_with("_mul"):
				m[mk] = float(m.get(mk, 1.0)) * pow(float(umods[mk]), lvl)
			else:
				m[mk] = float(m.get(mk, 0.0)) + float(umods[mk]) * lvl
	var base: Dictionary = u["base"]
	u["range"] = float(base["range"]) + float(m.get("range_add", 0.0)) + (HIGH_RANGE if u.get("high", false) and float(base["range"]) > 2.0 else 0.0)
	u["armor"] = float(base["armor"]) + float(m["armor_add"])
	u["damage"] = (float(base["damage"]) + float(m["damage_add"])) * float(m["damage_mul"])
	u["attack_cooldown"] = float(base["attack_cooldown"]) * float(m["cooldown_mul"])
	u["speed"] = float(base["speed"]) * float(m["speed_mul"])
	u["hp_regen"] = float(m["hp_regen"])
	u["mana_regen"] = float(base["mana_regen"]) + float(m["mana_regen"])
	u["crit"] = clampf(float(m["crit_chance"]), 0.0, 0.75)
	u["evasion"] = clampf(float(m["evasion"]), 0.0, 0.6)
	u["lifesteal"] = maxf(0.0, float(m["lifesteal"]))
	u["thorns"] = maxf(0.0, float(m["thorns"]))
	u["dmg_taken"] = maxf(0.0, float(m["damage_taken_mul"]))


func _mix(m: Dictionary, mods: Dictionary) -> void:
	for k in mods:
		if String(k).ends_with("_mul"):
			m[k] = float(m.get(k, 1.0)) * float(mods[k])
		else:
			m[k] = float(m.get(k, 0.0)) + float(mods[k])


func _add_buff(u: Dictionary, key: String, seconds: float, mods: Dictionary) -> void:
	var buffs: Array = u["buffs"]
	for b in buffs:
		if String(b["key"]) == key:
			b["until"] = tick + int(seconds * TICK_RATE)
			b["len"] = int(seconds * TICK_RATE)
			b["mods"] = mods
			return
	buffs.append({"key": key, "until": tick + int(seconds * TICK_RATE), "len": int(seconds * TICK_RATE), "mods": mods})


## {"type": "cast", "player": 0, "unit": id героя, "ability": "fireball", "target": id, "pos": Vector2}
func _cmd_cast(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var u = units.get(cmd.get("unit"))
	if u == null or int(u["player"]) != player:
		return
	var key := String(cmd.get("ability", ""))
	var ab = ability(u, key)
	if ab == null or String(ab["type"]) != "active":
		return
	if rank(u, key) <= 0:
		_msg(player, "Способность ещё не изучена")
		return
	if tick < int(u["cds"].get(key, 0)):
		_msg(player, "Способность ещё не готова")
		return
	if float(u["mana"]) < float(ab["mana"]):
		_msg(player, "Не хватает маны")
		return
	var target := int(cmd.get("target", -1))
	match String(ab["target"]):
		"unit_ally":
			if not units.has(target) or enemies(int(units[target]["player"]), player):
				_msg(player, "Нужно выбрать своего юнита или союзника")
				return
		"unit_enemy":
			var t = entity(target)
			if t == null or not enemies(int(t["player"]), player):
				_msg(player, "Нужно выбрать врага")
				return
	u["order"] = {"type": "cast", "key": key, "target": target, "pos": cmd.get("pos", u["pos"])}
	u["wait"] = 0
	u["swing"] = -1.0


func _do_cast(u: Dictionary, o: Dictionary) -> void:
	var ab = ability(u, String(o["key"]))
	var kind := String(ab["target"])
	var t: Variant = null
	var tpos: Vector2 = u["pos"]
	if kind == "unit_ally" or kind == "unit_enemy":
		t = entity(int(o["target"]))
		if t == null:
			_idle(u)
			return
		tpos = t["pos"]
	elif kind == "point":
		tpos = o["pos"]
	if kind != "none" and (u["pos"] as Vector2).distance_to(tpos) > float(ab["range"]) + float(u["radius"]):
		if int(u["wait"]) > 0:
			u["wait"] = int(u["wait"]) - 1
		else:
			u["wait"] = 4
			_path_to(u, tpos)
		return
	_stop_path(u)
	if tpos.distance_to(u["pos"]) > 0.01:
		u["facing"] = (tpos - (u["pos"] as Vector2)).normalized()
	if float(u["mana"]) >= float(ab["mana"]) and tick >= int(u["cds"].get(ab["key"], 0)):
		u["mana"] = float(u["mana"]) - float(ab["mana"])
		u["cds"][ab["key"]] = tick + int(cooldown_of(ab, rank(u, String(ab["key"]))) * TICK_RATE)
		_apply_effect(u, ab, t, tpos)
	_idle(u)


## r — ранг; по умолчанию берётся изученный ранг способности (предметы передают 1).
func _apply_effect(u: Dictionary, ab: Dictionary, t, tpos: Vector2, r: int = -1) -> void:
	if r < 0:
		r = maxi(1, rank(u, String(ab["key"])))
	var e: Dictionary = scaled_effect(ab["effect"], r)
	var player: int = int(u["player"])
	var color := String(ab.get("color", "#ffffff"))
	events.append({"type": "cast", "id": u["id"], "key": ab["key"]})
	match String(e["kind"]):
		"heal":
			t["hp"] = minf(float(t["max_hp"]), float(t["hp"]) + float(e["amount"]))
			events.append({"type": "blast", "pos": t["pos"], "radius": 1.2, "color": color})
			events.append({"type": "float", "player": player, "pos": t["pos"], "text": "+%d" % int(e["amount"]), "color": "#6dff7a"})
		"mana":
			t["mana"] = minf(float(t["max_mana"]), float(t["mana"]) + float(e["amount"]))
			events.append({"type": "blast", "pos": t["pos"], "radius": 1.2, "color": color})
			events.append({"type": "float", "player": player, "pos": t["pos"], "text": "+%d" % int(e["amount"]), "color": "#6aa8ff"})
		"xp":
			events.append({"type": "blast", "pos": u["pos"], "radius": 1.6, "color": color})
			events.append({"type": "float", "player": player, "pos": u["pos"], "text": "+%d опыта" % int(e["amount"]), "color": "#ffd24a"})
			_gain_xp(u, int(e["amount"]))
		"chain":       # молния перескакивает на ближайших врагов, слабея с каждым прыжком
			var hit: Array = []
			var cur = t
			var from: Vector2 = u["pos"]
			var amount := float(e["amount"])
			for j in int(e.get("jumps", 3)) + 1:
				if cur == null:
					break
				var cid := int(cur["id"])
				var cpos: Vector2 = cur["pos"]
				events.append({"type": "beam", "from": from, "to": cpos, "color": color})
				hit.append(cid)
				_damage(cur, amount, String(e.get("damage_type", "magic")), int(u["id"]), player)
				amount *= float(e.get("decay", 0.8))
				from = cpos
				cur = null
				var best_d := float(e.get("radius", 5.0))
				for id in _units_near(from, best_d):
					if hit.has(id) or not units.has(id) or not enemies(int(units[id]["player"]), player):
						continue
					var d: float = from.distance_to(units[id]["pos"])
					if d < best_d:
						best_d = d
						cur = units[id]
		"blink":       # мгновенный перенос героя в точку
			_teleport(u, tpos, color)
		"leap":        # прыжок в точку и удар по земле при приземлении
			_teleport(u, tpos, color)
			_area_damage(u, ab, e, u["pos"])
		"bolt":
			var pid := _shoot(u["pos"], t, float(e["amount"]), String(e.get("damage_type", "magic")), int(u["id"]), player, "fireball", 1.4 * float(u["def"]["model"].get("scale", 1.0)))
			projectiles[pid]["splash"] = float(e.get("splash", 0.0))
			projectiles[pid]["splash_radius"] = float(e.get("radius", 0.0))
		"area_damage":
			_area_damage(u, ab, e, u["pos"] if String(e.get("center", "self")) == "self" else tpos)
		"smite":       # мгновенный удар по одной цели с оглушением
			events.append({"type": "blast", "pos": t["pos"], "radius": 1.4, "color": color})
			var tid: int = int(t["id"])
			_damage(t, float(e["amount"]), String(e.get("damage_type", "magic")), int(u["id"]), player)
			if units.has(tid) and e.has("stun"):
				units[tid]["stun"] = tick + int(float(e["stun"]) * TICK_RATE)
				_stop_path(units[tid])
		"area_heal":
			events.append({"type": "blast", "pos": u["pos"], "radius": float(e["radius"]), "color": color})
			for id in _units_near(u["pos"], float(e["radius"])):
				if not enemies(int(units[id]["player"]), player):
					units[id]["hp"] = minf(float(units[id]["max_hp"]), float(units[id]["hp"]) + float(e["amount"]))
		"buff":
			var who: Array = []
			match String(e.get("who", "self")):
				"self":
					who = [int(u["id"])]
				"target":
					who = [int(t["id"])]
				"area_allies":
					events.append({"type": "blast", "pos": u["pos"], "radius": float(e["radius"]), "color": color})
					for id in _units_near(u["pos"], float(e["radius"])):
						if not enemies(int(units[id]["player"]), player):
							who.append(id)
				"area_enemies":      # проклятие: ослабляет врагов в области
					var c: Vector2 = tpos if String(e.get("center", "self")) == "point" else u["pos"]
					events.append({"type": "blast", "pos": c, "radius": float(e["radius"]), "color": color})
					for id in _units_near(c, float(e["radius"])):
						if enemies(int(units[id]["player"]), player):
							who.append(id)
			for id in who:
				_add_buff(units[id], String(ab["key"]), float(e["duration"]), e["mods"])
			if String(e.get("who")) == "target":
				events.append({"type": "blast", "pos": t["pos"], "radius": 1.2, "color": color})
		"ward":        # глаз-наблюдатель: неподвижный юнит, дающий обзор
			var wkey := String(e.get("unit", "ward"))
			var spot: Vector2 = (u["pos"] as Vector2) + (u["facing"] as Vector2) * (float(u["radius"]) + 0.6)
			var wid := spawn_unit(player, wkey, players[NEUTRAL]["data"]["units"][wkey], spot, false)
			units[wid]["expires"] = tick + int(float(e.get("duration", 180)) * TICK_RATE)
			events.append({"type": "blast", "pos": units[wid]["pos"], "radius": 1.0, "color": color})
		"summon":
			var def: Dictionary = players[player]["data"]["summons"][String(e["unit"])]
			events.append({"type": "blast", "pos": u["pos"], "radius": 2.5, "color": color})
			for i in int(e.get("count", 1)):
				var spot: Vector2 = (u["pos"] as Vector2) + (u["facing"] as Vector2).rotated(-0.8 + 1.6 * i) * 1.8
				var id := spawn_unit(player, String(e["unit"]), def, spot, false)
				units[id]["expires"] = tick + int(float(e.get("duration", 30)) * TICK_RATE)
				units[id]["facing"] = u["facing"]


func _teleport(u: Dictionary, dest: Vector2, color: String) -> void:
	events.append({"type": "blast", "pos": u["pos"], "radius": 1.3, "color": color})
	var cell := to_cell(dest)
	if is_blocked(cell):
		dest = cell_center(nearest_free_cell(cell))
	u["pos"] = dest
	u["prev_pos"] = dest       # без плавного перехода: герой исчезает и появляется
	_stop_path(u)
	events.append({"type": "blast", "pos": dest, "radius": 1.3, "color": color})


func _area_damage(u: Dictionary, ab: Dictionary, e: Dictionary, center: Vector2) -> void:
	var player: int = int(u["player"])
	events.append({"type": "blast", "pos": center, "radius": float(e["radius"]), "color": String(ab.get("color", "#ffffff"))})
	for id in _units_near(center, float(e["radius"])):
		if not units.has(id) or not enemies(int(units[id]["player"]), player):
			continue
		var victim: Dictionary = units[id]
		_damage(victim, float(e["amount"]), String(e.get("damage_type", "magic")), int(u["id"]), player)
		if units.has(id):
			if e.has("stun"):
				victim["stun"] = tick + int(float(e["stun"]) * TICK_RATE)
				_stop_path(victim)
			if e.has("slow"):
				_add_buff(victim, String(ab["key"]), float(e.get("duration", 4)), {"speed_mul": float(e["slow"])})


# ---------- опыт, рост героев и изучение способностей ----------

## Сколько опыта нужно, чтобы перейти с этого уровня на следующий.
func xp_needed(level: int) -> int:
	return 100 * level


## Изученный ранг способности (0 — не изучена).
func rank(u: Dictionary, key: String) -> int:
	return int(u.get("skills", {}).get(key, 0))


## Перезарядка способности: каждый следующий ранг на 12% быстрее.
func cooldown_of(ab: Dictionary, r: int) -> float:
	return float(ab.get("cooldown", 0)) * (1.0 - 0.12 * float(maxi(r, 1) - 1))


## Свободные очки навыков: одно за каждый уровень героя.
func skill_points(u: Dictionary) -> int:
	if not u["hero"]:
		return 0
	var used := 0
	for k in u.get("skills", {}):
		used += int(u["skills"][k])
	return int(u["level"]) - used


## С какого уровня героя доступен ранг r способности с этим номером (0…4).
func learn_level(index: int, r: int) -> int:
	return int(LEARN_LEVELS[mini(index, LEARN_LEVELS.size() - 1)]) + RANK_STEP * (r - 1)


## Можно ли прямо сейчас изучить следующий ранг способности. Пустая строка — можно, иначе причина.
func learn_block(u: Dictionary, key: String) -> String:
	var list: Array = u["def"].get("abilities", [])
	var index := -1
	for i in list.size():
		if String(list[i]["key"]) == key:
			index = i
	if index < 0:
		return "Нет такой способности"
	var next := rank(u, key) + 1
	if next > MAX_RANK:
		return "Изучена полностью"
	if int(u["level"]) < learn_level(index, next):
		return "Нужен %d уровень героя" % learn_level(index, next)
	if skill_points(u) <= 0:
		return "Нет свободных очков навыков"
	return ""


func _cmd_learn(cmd: Dictionary) -> void:
	var u = _my_hero(cmd)
	if u == null:
		return
	var key := String(cmd.get("ability", ""))
	var why := learn_block(u, key)
	if why != "":
		_msg(int(cmd["player"]), why)
		return
	u["skills"][key] = rank(u, key) + 1
	events.append({"type": "learned", "player": u["player"], "id": u["id"], "key": key, "rank": u["skills"][key]})


## Герой из команды, если он действительно принадлежит игроку.
func _my_hero(cmd: Dictionary):
	var u = units.get(cmd.get("unit"))
	if u == null or int(u["player"]) != int(cmd.get("player", -1)) or not u["hero"]:
		return null
	return u


## Чем выше ранг, тем сильнее изменения характеристик.
func scaled_mods(mods: Dictionary, r: int) -> Dictionary:
	var k := float(r - 1)
	var out: Dictionary = {}
	for key in mods:
		if String(key).ends_with("_mul"):
			out[key] = maxf(0.0, 1.0 + (float(mods[key]) - 1.0) * (1.0 + 0.25 * k))
		else:
			out[key] = float(mods[key]) * (1.0 + 0.35 * k)
	return out


func scaled_effect(effect: Dictionary, r: int) -> Dictionary:
	var k := float(r - 1)
	var e: Dictionary = effect.duplicate()
	if e.has("amount"):
		e["amount"] = float(e["amount"]) * (1.0 + 0.35 * k)
	if e.has("duration"):
		e["duration"] = float(e["duration"]) * (1.0 + 0.15 * k)
	if e.has("stun"):
		e["stun"] = float(e["stun"]) + 0.3 * k
	if e.has("slow"):
		e["slow"] = maxf(0.25, 1.0 - (1.0 - float(e["slow"])) * (1.0 + 0.15 * k))
	if e.has("count"):
		e["count"] = int(e["count"]) + r / 2
	if e.has("jumps"):
		e["jumps"] = int(e["jumps"]) + r - 1
	if e.has("mods"):
		e["mods"] = scaled_mods(e["mods"], r)
	return e


func _award_xp(victim: Dictionary, killer_player: int) -> void:
	if killer_player == NEUTRAL or killer_player == int(victim["player"]):
		return
	var value: int = 25 * int(victim["def"].get("level", 1))
	if victim["hero"]:
		value = 100 + 40 * int(victim["level"])
	elif int(victim["expires"]) >= 0:
		value = 10
	var heroes: Array = []
	for id in units:
		var h: Dictionary = units[id]
		if h["hero"] and int(h["player"]) == killer_player and (h["pos"] as Vector2).distance_to(victim["pos"]) <= XP_RADIUS:
			heroes.append(int(id))
	heroes.sort()
	for id in heroes:
		_gain_xp(units[id], value / heroes.size())


func _gain_xp(u: Dictionary, amount: int) -> void:
	if int(u["level"]) >= MAX_HERO_LEVEL:
		return
	u["xp"] = int(u["xp"]) + amount
	while int(u["level"]) < MAX_HERO_LEVEL and int(u["xp"]) >= xp_needed(int(u["level"])):
		u["xp"] = int(u["xp"]) - xp_needed(int(u["level"]))
		_level_up(u, false)
	if int(u["level"]) >= MAX_HERO_LEVEL:
		u["xp"] = 0


func _level_up(u: Dictionary, quiet: bool) -> void:
	u["level"] = int(u["level"]) + 1
	var g: Dictionary = u["def"].get("growth", {})
	u["max_hp"] = float(u["max_hp"]) + float(g.get("hp", 80))
	u["hp"] = float(u["hp"]) + float(g.get("hp", 80))
	u["max_mana"] = float(u["max_mana"]) + float(g.get("mana", 20))
	u["mana"] = float(u["mana"]) + float(g.get("mana", 20))
	u["base"]["damage"] = float(u["base"]["damage"]) + float(g.get("damage", 3))
	u["base"]["armor"] = float(u["base"]["armor"]) + float(g.get("armor", 0.3))
	u["base"]["mana_regen"] = float(u["base"]["mana_regen"]) + float(g.get("mana_regen", 0.05))
	if not quiet:
		events.append({"type": "levelup", "id": u["id"], "player": u["player"], "level": u["level"], "pos": u["pos"]})


# ---------- сохранение и загрузка ----------

func save_state() -> Dictionary:
	return {
		"tick": tick, "seed": seed_value, "units": units, "buildings": buildings, "resources": resources,
		"projectiles": projectiles, "players": players, "game_over": game_over, "next_id": _next_id, "pending": _pending,
		"loot": loot, "map_size": map_size, "neutral_cap": neutral_cap, "next_camp": _next_camp,
		"runes": runes, "rune_spots": rune_spots, "corpses": corpses,
		"caravans": caravans, "next_caravan": _next_caravan, "world": world, "biome": biome,
	}


## Вызывается на новой симуляции, в которой уже отмечены непроходимые клетки рельефа.
func load_state(d: Dictionary) -> void:
	tick = int(d["tick"])
	seed_value = int(d["seed"])
	units = d["units"]
	buildings = d["buildings"]
	_bindex_dirty = true
	for uid in units:      # сохранённые подсказки быстрого пересчёта после загрузки недействительны
		(units[uid] as Dictionary).erase("_sk")
	resources = d["resources"]
	projectiles = d["projectiles"]
	players = d["players"]
	game_over = bool(d["game_over"])
	_next_id = int(d["next_id"])
	_pending = d["pending"]
	loot = d.get("loot", {})
	neutral_cap = int(d.get("neutral_cap", 0))
	_next_camp = int(d.get("next_camp", 100000))
	runes = d.get("runes", {})
	rune_spots = d.get("rune_spots", [])
	corpses = d.get("corpses", {})
	caravans = d.get("caravans", {})
	_next_caravan = int(d.get("next_caravan", 1))
	world = d.get("world", world)
	biome = String(d.get("biome", "meadow"))
	for id in resources:
		_set_solid(_rect(resources[id]), true)
	for id in buildings:
		_set_solid(_rect(buildings[id]), true)
	_update_sides()


func _finish_train(b: Dictionary, q: Dictionary) -> void:
	var def: Dictionary = players[b["player"]]["data"]["units"][q["key"]]
	var ring := _ring(_rect(b))
	var spot: Vector2 = b["pos"]
	if not ring.is_empty():
		spot = cell_center(ring[(int(b["id"]) + tick) % ring.size()])
	var new_id := spawn_unit(int(b["player"]), String(q["key"]), def, spot, false)
	var nu: Dictionary = units[new_id]
	players[b["player"]]["stats"]["trained"] += 1
	if def.get("hero", false):
		players[b["player"]]["heroes"][q["key"]] = {"state": "alive", "altar": int(b["id"])}
		for i in int(q.get("level", 1)) - 1:
			_level_up(nu, true)
		nu["xp"] = int(q.get("xp", 0))
		nu["skills"] = (q.get("skills", {}) as Dictionary).duplicate()
		for ik in q.get("items", []):
			_give_item(nu, String(ik))
	if b["rally"] != null:     # новый юнит сам идёт к точке сбора
		var tid := int(b.get("rally_target", -1))
		var mine := int(b["player"])
		if resources.has(tid) and is_worker(nu):              # рудник или дерево: сразу за работу
			_start_gather(nu, tid, String(resources[tid]["kind"]), resources[tid]["pos"])
		elif units.has(tid) and not enemies(int(units[tid]["player"]), mine):   # свой или союзный юнит: идти следом
			nu["order"] = {"type": "follow", "target": tid}
		elif entity(tid) != null and enemies(int(entity(tid)["player"]), mine) and float(nu["damage"]) > 0.0 and not is_worker(nu):
			_order_attack(nu, tid, {})                           # враг: атаковать
		elif buildings.has(tid) and int(buildings[tid]["player"]) == mine and not buildings[tid]["done"] and is_worker(nu):
			_start_build(nu, tid)                                # своя стройка: достраивать
		else:
			var dest: Vector2 = entity(tid)["pos"] if entity(tid) != null else (resources[tid]["pos"] if resources.has(tid) else b["rally"])
			nu["order"] = {"type": "move" if is_worker(nu) else "amove", "dest": dest}
			_path_to(nu, dest)


# ---------- отмена стройки, найма и исследования ----------

## {"type": "cancel", "player": 0, "building": id, "index": номер заказа в очереди (необязательно)}
## Недостроенное здание сносится с возвратом 75% цены; у готового отменяется заказ (по умолчанию последний).
func _cmd_cancel(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var b = buildings.get(cmd.get("building"))
	if b == null or int(b["player"]) != player:
		return
	var p: Dictionary = players[player]
	if not b["done"]:
		var mine := 0
		for id in buildings:
			if int(buildings[id]["player"]) == player:
				mine += 1
		if mine <= 1:
			_msg(player, "Нельзя отменить единственное здание")
			return
		var paid: Dictionary = b.get("paid", b["def"]["cost"])
		p["gold"] += int(paid.get("gold", 0)) * 3 / 4
		p["wood"] += int(paid.get("wood", 0)) * 3 / 4
		_set_solid(_rect(b), false)
		buildings.erase(b["id"])
		_bindex_dirty = true
		events.append({"type": "building_removed", "id": b["id"]})
		return
	var queue: Array = b["queue"]
	if queue.is_empty():
		return
	var index := int(cmd.get("index", queue.size() - 1))     # без номера — последний заказ
	if index < 0 or index >= queue.size():
		return
	var q: Dictionary = queue[index]
	queue.remove_at(index)
	if q.get("research", false):
		p["research_wip"].erase(q["key"])
		var cost := upgrade_cost(player, String(q["key"]))
		p["gold"] += int(cost["gold"])
		p["wood"] += int(cost["wood"])
		return
	var def: Dictionary = p["data"]["units"][q["key"]]
	var div: int = 2 if q.get("revive", false) else 1
	p["gold"] += int(def["cost"].get("gold", 0)) / div
	p["wood"] += int(def["cost"].get("wood", 0)) / div
	p["supply_used"] -= int(def.get("supply", 0))
	if q.get("hero", false):
		if q.get("revive", false):
			p["heroes"][q["key"]] = {"state": "dead", "altar": int(b["id"]), "level": int(q.get("level", 1)), "xp": int(q.get("xp", 0)), "items": q.get("items", []), "skills": q.get("skills", {})}
		else:
			p["heroes"].erase(q["key"])


# ---------- предметы героев (продаются в лавке торговца) ----------

## {"type": "buy", "player": 0, "unit": id героя, "shop": id лавки, "item": "boots"}
func _cmd_buy(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var u = units.get(cmd.get("unit"))
	var shop = buildings.get(cmd.get("shop"))
	var key := String(cmd.get("item", ""))
	if u == null or shop == null or int(u["player"]) != player or not u["hero"]:
		return
	if not (shop["def"].get("sells", []) as Array).has(key):
		return
	var item: Dictionary = players[NEUTRAL]["data"]["items"][key]
	if (u["pos"] as Vector2).distance_to(shop["pos"]) > SHOP_RANGE:
		_msg(player, "Герой слишком далеко от лавки")
	elif (u["items"] as Array).has(key) and not item.has("use"):
		_msg(player, "У героя уже есть этот предмет")
	elif (u["items"] as Array).size() >= MAX_ITEMS:
		_msg(player, "Сумка героя заполнена")
	elif not can_afford(player, item["cost"]):
		_msg(player, "Не хватает золота")
	else:
		_pay(player, item["cost"])
		_give_item(u, key)
		events.append({"type": "bought", "player": player, "id": u["id"], "item": key})


func item_def(key: String) -> Dictionary:
	return players[NEUTRAL]["data"]["items"].get(key, {})


## Прибавки к здоровью и мане действуют, пока предмет в сумке.
func _give_item(u: Dictionary, key: String) -> void:
	(u["items"] as Array).append(key)
	var mods: Dictionary = item_def(key).get("mods", {})
	u["max_hp"] = float(u["max_hp"]) + float(mods.get("hp_add", 0))
	u["hp"] = float(u["hp"]) + float(mods.get("hp_add", 0))
	u["max_mana"] = float(u["max_mana"]) + float(mods.get("mana_add", 0))
	u["mana"] = float(u["mana"]) + float(mods.get("mana_add", 0))


func _take_item(u: Dictionary, slot: int) -> String:
	var key := String(u["items"][slot])
	(u["items"] as Array).remove_at(slot)
	var mods: Dictionary = item_def(key).get("mods", {})
	u["max_hp"] = float(u["max_hp"]) - float(mods.get("hp_add", 0))
	u["hp"] = clampf(float(u["hp"]), 1.0, float(u["max_hp"]))
	u["max_mana"] = maxf(0.0, float(u["max_mana"]) - float(mods.get("mana_add", 0)))
	u["mana"] = minf(float(u["mana"]), float(u["max_mana"]))
	return key


func _slot_of(cmd: Dictionary, u: Dictionary) -> int:
	var slot := int(cmd.get("slot", -1))
	return slot if slot >= 0 and slot < (u["items"] as Array).size() else -1


## Зелья и свитки: эффект срабатывает сразу, предмет исчезает.
func _cmd_use_item(cmd: Dictionary) -> void:
	var u = _my_hero(cmd)
	if u == null or _slot_of(cmd, u) < 0:
		return
	var slot := _slot_of(cmd, u)
	var it := item_def(String(u["items"][slot]))
	if not it.has("use"):
		_msg(int(u["player"]), "Этот предмет действует сам, пока лежит в сумке")
		return
	var e: Dictionary = it["use"]
	if String(e["kind"]) == "mana" and float(u["max_mana"]) <= 0.0:
		_msg(int(u["player"]), "У героя нет маны")
		return
	var key := _take_item(u, slot)
	_apply_effect(u, {"key": key, "effect": e, "color": it.get("color", "#ffffff")}, u, u["pos"], 1)


## Выбросить предмет на землю рядом с героем или уничтожить его навсегда.
func _cmd_drop_item(cmd: Dictionary) -> void:
	var u = _my_hero(cmd)
	if u == null or _slot_of(cmd, u) < 0:
		return
	var key := _take_item(u, _slot_of(cmd, u))
	if String(cmd["type"]) == "destroy_item":
		events.append({"type": "float", "player": u["player"], "pos": u["pos"], "text": "уничтожено", "color": "#ff8a5a"})
		return
	var spot: Vector2 = (u["pos"] as Vector2) + (u["facing"] as Vector2) * 0.9
	if is_blocked(to_cell(spot)):
		spot = u["pos"]
	add_loot(key, spot)


## Последний нейтрал лагеря погиб: золото победителю и предмет на землю (чем сильнее лагерь, тем ценнее).
func _camp_cleared(level: int, pos: Vector2, player: int, camp: int) -> void:
	var reward: Dictionary = players[NEUTRAL]["data"].get("camp_rewards", {}).get(str(level), {})
	if reward.is_empty():
		return
	var gold: int = int(reward.get("gold", 0))
	if gold > 0:
		players[player]["gold"] += gold
		players[player]["stats"]["gold"] += gold
		events.append({"type": "float", "player": player, "pos": pos, "text": "Лагерь зачищен! +%d" % gold, "color": "#ffd940"})
	var pool: Array = reward.get("items", [])
	if pool.is_empty() or _roll(camp, 991) >= float(reward.get("chance", 1.0)):
		return
	var taken: Array = []
	for i in int(reward.get("count", 1)):
		var k := int(_roll(camp + i * 31, 577) * pool.size()) % pool.size()
		while taken.has(k) and taken.size() < pool.size():      # два предмета из одного лагеря — разные
			k = (k + 1) % pool.size()
		taken.append(k)
		add_loot(String(pool[k]), pos + Vector2(0.8, 0).rotated(float(i) * 2.4 + float(camp)))
	_msg(player, "Из лагеря выпал предмет — подберите его героем (ПКМ)")


func add_loot(key: String, pos: Vector2) -> int:
	var id := _new_id()
	loot[id] = {"id": id, "key": key, "pos": pos}
	events.append({"type": "loot_added", "id": id})
	return id


func _do_pickup(u: Dictionary, o: Dictionary) -> void:
	var it = loot.get(o["target"])
	if it == null:
		_idle(u)
		return
	if (u["pos"] as Vector2).distance_to(it["pos"]) <= float(u["radius"]) + PICKUP_RANGE:
		_idle(u)
		if (u["items"] as Array).size() >= MAX_ITEMS:
			_msg(int(u["player"]), "Сумка героя заполнена")
			return
		loot.erase(it["id"])
		events.append({"type": "loot_removed", "id": it["id"]})
		_give_item(u, String(it["key"]))
		events.append({"type": "picked", "player": u["player"], "id": u["id"], "item": it["key"]})
	elif not is_moving(u):
		if int(u["wait"]) > 0:
			u["wait"] = int(u["wait"]) - 1
		else:
			u["wait"] = 5
			_path_to(u, it["pos"])


# ---------- сетевая игра: команды на точный тик и сверка состояния ----------

func push_command_at(cmd: Dictionary, at_tick: int) -> void:
	cmd["tick"] = at_tick
	_pending.append(cmd)


## Число, одинаковое у обоих игроков, пока их игры идут одинаково.
func checksum() -> int:
	var h := tick
	var ids: Array = units.keys()
	ids.sort()
	for id in ids:
		var u: Dictionary = units[id]
		h = (h * 31 + int(id) * 7 + int(round(float(u["pos"].x) * 100.0)) + int(round(float(u["pos"].y) * 100.0)) * 3 + int(round(float(u["hp"])))) % 2147483647
	for pl in active_players():
		h = (h * 31 + int(players[pl]["gold"]) + int(players[pl]["wood"]) * 5) % 2147483647
	return h


# ---------- улучшения (исследуются в кузнице) ----------

## {"type": "research", "player": 0, "building": id, "upgrade": "weapons"}
func _cmd_research(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var b = buildings.get(cmd.get("building"))
	var key := String(cmd.get("upgrade", ""))
	if b == null or int(b["player"]) != player or not b["done"]:
		return
	if not (b["def"].get("researches", []) as Array).has(key):
		return
	var p: Dictionary = players[player]
	var up: Dictionary = p["data"]["upgrades"][key]
	var level: int = int(p["upgrades"].get(key, 0))
	if level >= int(up.get("max", 3)):
		_msg(player, "Это улучшение уже изучено полностью")
		return
	if p["research_wip"].has(key):
		_msg(player, "Это улучшение уже исследуется")
		return
	if int(up.get("tier", 1)) > tier(player):
		_msg(player, "Сначала улучшите главное здание (%s) до %d уровня" % [String(p["data"]["buildings"]["hall"]["name"]).to_lower(), int(up["tier"])])
		return
	if key == "tier" and level >= 1 and not _has_tier3_base(player):
		var names: Array = []
		for k in tier3_missing(player):
			names.append(String(p["data"]["buildings"][k]["name"]).to_lower())
		_msg(player, "Для третьего уровня постройте: %s" % ", ".join(names))
		return
	var cost := upgrade_cost(player, key)
	if not can_afford(player, cost):
		_msg(player, "Не хватает ресурсов")
		return
	_pay(player, cost)
	p["research_wip"][key] = true
	var time: float = float(up.get("time", 40)) * (level + 1)
	if up.has("times"):      # своё время для каждого уровня (главное здание)
		time = float(up["times"][mini(level, (up["times"] as Array).size() - 1)])
	(b["queue"] as Array).append({"key": key, "research": true, "left": time, "total": time, "hero": false, "revive": false})


## Предел пищи: фермы дают сколько угодно, но больше SUPPLY_LIMIT не засчитывается;
## улучшение «granary» в главном здании поднимает предел до 200 и 300.
const SUPPLY_LIMIT := 100
const SUPPLY_TOP := 300


func supply_limit(player: int) -> int:
	return mini(SUPPLY_TOP, SUPPLY_LIMIT + 100 * int(players[player]["upgrades"].get("granary", 0)))


## Улучшение «Большие амбары» в главном здании любой расы (поднимает предел пищи).
static func add_granary(race: Dictionary) -> void:
	if not race.has("upgrades") or not race.get("buildings", {}).has("hall") or race["upgrades"].has("granary"):
		return
	race["upgrades"]["granary"] = {
		"name": "Большие амбары", "hotkey": "G", "icon": "house", "color": "#d8b46a", "max": 2,
		"cost": {"gold": 450, "wood": 300}, "costs": [{"gold": 450, "wood": 300}, {"gold": 900, "wood": 650}],
		"time": 60, "times": [60, 90], "mods": {},
		"description": "Предел пищи: 100 → 200 (1-й уровень) → 300 (2-й уровень). Сами фермы по-прежнему нужны — амбары лишь позволяют держать войско больше.",
	}
	var hall: Dictionary = race["buildings"]["hall"]
	var list: Array = (hall.get("researches", []) as Array).duplicate()
	list.append("granary")
	hall["researches"] = list


## Сколько пищи доступно игроку на деле (фермы, но не больше предела).
func supply_max(player: int) -> int:
	return mini(int(players[player]["supply_cap"]), supply_limit(player))


## Уровень главного здания игрока: 1 в начале, растёт улучшением «tier» в ратуше (до 3).
func tier(player: int) -> int:
	return 1 + int(players[player]["upgrades"].get("tier", 0))


## Что нужно построить для третьего уровня главного здания (ключи зданий, которых ещё нет).
const TIER3_NEEDS := ["altar", "temple", "elite"]


func tier3_missing(player: int) -> Array:
	var have := {}
	for id in buildings:
		var b: Dictionary = buildings[id]
		if int(b["player"]) == player and b["done"]:
			have[String(b["key"])] = true
	var out: Array = []
	for k in TIER3_NEEDS:
		if players[player]["data"]["buildings"].has(k) and not have.has(k):
			out.append(k)
	return out


func _has_tier3_base(player: int) -> bool:
	return tier3_missing(player).is_empty()


## Каждый следующий уровень улучшения дороже.
func upgrade_cost(player: int, key: String) -> Dictionary:
	var up: Dictionary = players[player]["data"]["upgrades"][key]
	var n: int = int(players[player]["upgrades"].get(key, 0)) + 1
	if up.has("costs"):      # своя цена для каждого уровня (главное здание)
		var c: Dictionary = up["costs"][mini(n - 1, (up["costs"] as Array).size() - 1)]
		return {"gold": int(c.get("gold", 0)), "wood": int(c.get("wood", 0))}
	return {"gold": int(up["cost"].get("gold", 0)) * n, "wood": int(up["cost"].get("wood", 0)) * n}


func _finish_research(b: Dictionary, q: Dictionary) -> void:
	var p: Dictionary = players[b["player"]]
	p["research_wip"].erase(q["key"])
	p["upgrades"][q["key"]] = int(p["upgrades"].get(q["key"], 0)) + 1
	_up_ver[int(b["player"])] = int(_up_ver.get(int(b["player"]), 0)) + 1      # характеристики юнитов игрока пересчитаются
	_msg(int(b["player"]), "Исследовано: %s, уровень %d" % [String(p["data"]["upgrades"][q["key"]]["name"]).to_lower(), int(p["upgrades"][q["key"]])])
	var done_up: Dictionary = p["data"]["upgrades"][q["key"]]
	var hp_add := float(done_up.get("mods", {}).get("hp_add", 0))
	if hp_add > 0.0:      # закалка: уже нанятые бойцы тоже становятся крепче
		for uid in units:
			var hu: Dictionary = units[uid]
			if int(hu["player"]) == int(b["player"]) and upgrade_applies(hu, done_up):
				hu["max_hp"] = float(hu["max_hp"]) + hp_add
				hu["hp"] = float(hu["hp"]) + hp_add
	var bonus: float = float(p["data"]["upgrades"][q["key"]].get("hall_hp", 0))
	if bonus > 0.0:     # улучшение главного здания укрепляет все ратуши игрока
		for hid in buildings:
			var hb: Dictionary = buildings[hid]
			if int(hb["player"]) == int(b["player"]) and String(hb["def"].get("role", "")) == "hall":
				hb["max_hp"] = float(hb["max_hp"]) + bonus
				hb["hp"] = float(hb["hp"]) + bonus
	events.append({"type": "research_done", "player": b["player"], "key": q["key"]})


# ---------- работа: добыча и стройка ----------

func _start_gather(u: Dictionary, id: int, kind: String, pos: Vector2) -> void:
	if not resources.has(id) or not _has_free_side(_rect(resources[id])):
		id = nearest_resource(kind, pos, 18.0)
		if id < 0:
			_idle(u)
			return
	var r: Dictionary = resources[id]
	u["order"] = {"type": "gather", "target": id, "kind": kind, "pos": r["pos"], "phase": "go", "timer": 0.0}
	u["wait"] = 0
	_go_adjacent(u, _rect(r))


func _start_return(u: Dictionary, res_id: int, kind: String, pos: Vector2) -> void:
	u["order"] = {"type": "return", "target": res_id, "kind": kind, "pos": pos}
	u["wait"] = 0
	var hall := nearest_hall(u)
	if hall >= 0:
		_go_adjacent(u, _rect(buildings[hall]))


func _start_build(u: Dictionary, building_id: int) -> void:
	u["order"] = {"type": "build", "target": building_id}
	u["wait"] = 0
	_go_adjacent(u, _rect(buildings[building_id]))


func _do_gather(u: Dictionary, o: Dictionary) -> void:
	var r = resources.get(o["target"])
	if r == null:
		_start_gather(u, -1, String(o["kind"]), o["pos"])
		return
	if String(o["phase"]) == "go":
		if _near(u, _rect(r)):
			_stop_path(u)
			u["facing"] = ((r["pos"] as Vector2) - (u["pos"] as Vector2)).normalized()
			o["phase"] = "work"
			o["timer"] = GOLD_TIME if String(r["kind"]) == "gold" else WOOD_TIME
			if String(r["kind"]) == "gold" and _wake_guards(r["pos"], GUARD_MINE_RADIUS, int(u["id"])) and tick - int(r.get("guard_msg", -9999)) > 150:
				r["guard_msg"] = tick      # стража рудника ещё жива — она не даст красть золото
				_msg(int(u["player"]), "Охрана рудника заметила вора и нападает!")
		else:
			_repath(u, _rect(r))
		return
	u["busy"] = true
	o["timer"] = float(o["timer"]) - TICK_DT
	if float(o["timer"]) > 0.0:
		return
	var carry_key := "carry_gold" if String(r["kind"]) == "gold" else "carry_wood"
	var amount: int = mini(int(u["def"].get(carry_key, 10)) + (carry_bonus(u) if String(r["kind"]) == "gold" else 0), int(r["amount"]))
	if not (String(r["kind"]) == "tree" and race_trait(int(u["player"]), "tree_friend")):
		r["amount"] = int(r["amount"]) - amount      # эльфы берут у леса, не вырубая деревья
	u["carry"] = amount
	u["carry_kind"] = "gold" if String(r["kind"]) == "gold" else "wood"
	if int(r["amount"]) <= 0:
		_set_solid(_rect(r), false)
		resources.erase(r["id"])
		events.append({"type": "resource_removed", "id": r["id"]})
	_start_return(u, int(o["target"]), String(o["kind"]), o["pos"])


func _do_return(u: Dictionary, o: Dictionary) -> void:
	var hall := nearest_hall(u)
	if hall < 0:
		return
	var rect := _rect(buildings[hall])
	if _near(u, rect):
		var rush := 1.5 if String(u["carry_kind"]) == "gold" and tick < int(world.get("gold_rush", 0)) else 1.0      # золотая лихорадка
		var kind := String(u["carry_kind"])
		var pl: Dictionary = players[u["player"]]
		# дробная часть не теряется: копится у игрока и добавляется к следующей ноше
		var exact: float = int(u["carry"]) * float(pl.get("income_mul", 1.0)) * rush * gather_mul(int(u["player"])) + float(pl.get("frac_" + kind, 0.0))
		var gained: int = int(floor(exact + 0.0001))
		pl["frac_" + kind] = maxf(0.0, exact - gained)
		players[u["player"]][String(u["carry_kind"])] += gained
		players[u["player"]]["stats"][String(u["carry_kind"])] += gained
		u["carry"] = 0
		_start_gather(u, int(o["target"]), String(o["kind"]), o["pos"])
	else:
		_repath(u, rect)


func _do_build(u: Dictionary, o: Dictionary) -> void:
	var b = buildings.get(o["target"])
	if b == null or b["done"]:
		_idle(u)
		return
	if not _near(u, _rect(b)):
		_repath(u, _rect(b))
		return
	u["facing"] = ((b["pos"] as Vector2) - (u["pos"] as Vector2)).normalized()
	_stop_path(u)
	if race_trait(int(b["player"]), "summon_build"):      # нежить: рабочий лишь призывает здание и уходит
		if not b.get("auto", false):
			b["auto"] = true
			events.append({"type": "summon_build", "id": b["id"], "pos": b["pos"]})
		_idle(u)
		return
	u["busy"] = true
	if _advance_build(b):
		_idle(u)


## Один тик стройки. Возвращает true, когда здание готово.
func _advance_build(b: Dictionary) -> bool:
	var bt := maxf(1.0, float(b["def"].get("build_time", 30)))
	b["progress"] = minf(1.0, float(b["progress"]) + TICK_DT / bt)
	b["hp"] = minf(float(b["max_hp"]), float(b["hp"]) + float(b["max_hp"]) * 0.9 * TICK_DT / bt)
	if float(b["progress"]) >= 1.0:
		b["done"] = true
		_bindex_dirty = true
		b.erase("auto")
		players[b["player"]]["supply_cap"] += int(b["def"].get("supply_given", 0))
		events.append({"type": "building_done", "id": b["id"]})
		return true
	return false


## Лунный колодец эльфов: копит силу (ночью вдвое быстрее) и тратит её, леча и восполняя ману
## своим и союзникам рядом.
func _update_well(b: Dictionary) -> void:
	var w: Dictionary = b["def"]["well"]
	if not b.has("energy"):
		b["energy"] = float(w.get("max", 250))
	if (tick + int(b["id"])) % TICK_RATE != 0:
		return
	b["energy"] = minf(float(w.get("max", 250)), float(b["energy"]) + float(w.get("regen", 1.0)) * (2.0 if is_night() else 1.0))
	for id in _units_near(b["pos"], float(w.get("radius", 5.0)) + float(b["radius"])):
		var u: Dictionary = units[id]
		if enemies(int(u["player"]), int(b["player"])):
			continue
		var hp := minf(float(w.get("heal", 10)), float(u["max_hp"]) - float(u["hp"]))
		var mana := minf(float(w.get("mana", 4)), float(u["max_mana"]) - float(u["mana"]))
		var cost := hp * 0.5 + mana
		if cost <= 0.05 or float(b["energy"]) < cost:
			continue
		u["hp"] = float(u["hp"]) + hp
		u["mana"] = float(u["mana"]) + mana
		b["energy"] = float(b["energy"]) - cost
		if hp >= 5.0 and (tick / TICK_RATE + int(id)) % 3 == 0:
			events.append({"type": "beam", "from": b["pos"], "to": u["pos"], "color": "#9fe8ff"})


## Если юнит стоит, но до цели не дошёл (его оттолкнули) — проложить путь заново.
func _repath(u: Dictionary, rect: Rect2i) -> void:
	if is_moving(u):
		return
	if int(u["wait"]) > 0:
		u["wait"] = int(u["wait"]) - 1
		return
	u["wait"] = 5
	_go_adjacent(u, rect)


func _rect(thing: Dictionary) -> Rect2i:
	return Rect2i(thing["cell"], Vector2i(int(thing["size"]), int(thing["size"])))


func _near(u: Dictionary, rect: Rect2i) -> bool:
	var p: Vector2 = u["pos"]
	var closest := p.clamp(Vector2(rect.position), Vector2(rect.end))
	return p.distance_to(closest) <= float(u["radius"]) + REACH


func _ring(rect: Rect2i) -> Array:
	var cells: Array = []
	for x in range(rect.position.x - 1, rect.end.x + 1):
		for y in range(rect.position.y - 1, rect.end.y + 1):
			var c := Vector2i(x, y)
			if not rect.has_point(c) and not is_blocked(c):
				cells.append(c)
	return cells


func _has_free_side(rect: Rect2i) -> bool:
	return not _ring(rect).is_empty()


## Идти к свободной клетке вплотную к объекту (зданию, дереву, руднику).
func _go_adjacent(u: Dictionary, rect: Rect2i) -> void:
	var best := Vector2i(-1, -1)
	var best_d := INF
	for c in _ring(rect):
		# небольшой разброс, чтобы юниты не лезли все в одну клетку
		var d: float = cell_center(c).distance_to(u["pos"]) + float((int(u["id"]) * 7 + c.x * 3 + c.y * 5) % 3) * 0.6
		if d < best_d:
			best_d = d
			best = c
	if best.x >= 0:
		_path_to(u, cell_center(best))


var path_calls := 0      # замеры скорости: сколько путей проложено, сколько из них к недостижимой цели и сколько это стоило
var path_us := 0
var path_miss := 0
var path_miss_us := 0


func _path_to(u: Dictionary, dest: Vector2) -> void:
	path_calls += 1
	u.erase("chase")      # новый путь — уже не «погоня по старому маршруту» (см. _do_attack)
	var swim := swims(u)
	var start_cell := nearest_free_cell(to_cell(u["pos"]), {}, swim)
	var goal := nearest_free_cell(to_cell(dest), {}, swim)
	var pt0 := Time.get_ticks_usec()
	var path: PackedVector2Array = _grid_for(swim).get_point_path(start_cell, goal, true)
	var spent := Time.get_ticks_usec() - pt0
	path_us += spent
	if path.is_empty() or to_cell(path[path.size() - 1]) != goal:
		path_miss += 1
		path_miss_us += spent
	# если цель недостижима (за обрывом, на острове), путь ведёт к ближайшей достижимой точке —
	# и тогда точную точку цели подставлять нельзя: юнит пошёл бы к ней напрямую сквозь скалы
	var reached := path.size() > 0 and to_cell(path[path.size() - 1]) == goal
	if path.size() > 0:
		path.remove_at(0)            # первая точка — клетка, где юнит уже стоит
	if reached and not is_blocked(to_cell(dest), swim):
		if path.size() > 0:
			path[path.size() - 1] = dest # последняя точка — точное место
		else:
			path.append(dest)
	u["path"] = path
	u["path_i"] = 0
	u["stuck"] = 0


## Свободна ли прямая между точками для юнита (проверяются клетки вдоль линии и по её бокам).
func _clear_line(a: Vector2, b: Vector2, r: float, swim := false) -> bool:
	var g: PackedByteArray = _solid_sw if swim else _solid
	var w := map_size
	var d := b - a
	var length := d.length()
	if length < 0.01:
		return true
	var n := int(ceil(length / 0.45))
	var side := Vector2(-d.y, d.x) / length * r
	for k in range(1, n + 1):
		var p := a + d * (float(k) / n)
		var c0 := to_cell(p)
		var c1 := to_cell(p + side)
		var c2 := to_cell(p - side)
		if g[c0.y * w + c0.x] != 0 or g[c1.y * w + c1.x] != 0 or g[c2.y * w + c2.x] != 0:
			return false
	return true


func path_exists(a: Vector2, b: Vector2) -> bool:
	return not _grid.get_id_path(nearest_free_cell(to_cell(a)), nearest_free_cell(to_cell(b))).is_empty()


func nearest_resource(kind: String, pos: Vector2, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for id in resources:
		var r: Dictionary = resources[id]
		if String(r["kind"]) != kind:
			continue
		var d: float = (r["pos"] as Vector2).distance_to(pos)
		if (d < best_d or (d == best_d and int(id) < best)) and _has_free_side(_rect(r)):
			best_d = d
			best = int(id)
	return best


func nearest_hall(u: Dictionary) -> int:
	var best := -1
	var best_d := INF
	if _bindex_dirty:
		_rebuild_bindex()
	for id in _halls_of.get(int(u["player"]), []):
		var b: Dictionary = buildings[id]
		var d: float = (b["pos"] as Vector2).distance_to(u["pos"])
		if d < best_d:
			best_d = d
			best = int(id)
	return best


# ---------- вспомогательное ----------

func _new_id() -> int:
	_next_id += 1
	return _next_id - 1


func in_map(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < map_size and c.y < map_size


func to_cell(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int(floor(p.x)), 0, map_size - 1), clampi(int(floor(p.y)), 0, map_size - 1))


func cell_center(c: Vector2i) -> Vector2:
	return Vector2(c) + Vector2(0.5, 0.5)


func is_blocked(c: Vector2i, swim := false) -> bool:
	if not in_map(c):
		return true
	if swim:
		return _solid_sw[c.y * map_size + c.x] != 0
	return _solid[c.y * map_size + c.x] != 0


func nearest_free_cell(c: Vector2i, taken: Dictionary = {}, swim := false) -> Vector2i:
	if not is_blocked(c, swim) and not taken.has(c):
		return c
	for r in range(1, map_size):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for x in range(c.x - r, c.x + r + 1):
			for y in range(c.y - r, c.y + r + 1):
				if maxi(absi(x - c.x), absi(y - c.y)) != r:
					continue
				var n := Vector2i(x, y)
				if is_blocked(n) or taken.has(n):
					continue
				var d := float((n - c).length_squared())
				if d < best_d:
					best_d = d
					best = n
		if best.x >= 0:
			return best
	return c
