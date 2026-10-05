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
var _side := PackedInt32Array()   # сторона каждого игрока: у союзников одно и то же число


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
	_grid.region = Rect2i(0, 0, n, n)
	_grid.cell_size = Vector2.ONE
	_grid.offset = Vector2(0.5, 0.5)
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.update()


# ---------- создание мира ----------

func add_player(player: int, race: Dictionary) -> void:
	players[player] = {
		"race": String(race["id"]), "data": race,
		"gold": START_GOLD, "wood": START_WOOD, "supply_used": 0, "supply_cap": 0, "heroes": {}, "upgrades": {}, "research_wip": {},
		"stats": {"killed": 0, "lost": 0, "razed": 0, "gold": 0, "wood": 0, "trained": 0, "built": 0},
	}


func block_cell(cell: Vector2i) -> void:
	_grid.set_point_solid(cell, true)


func _set_solid(rect: Rect2i, solid: bool) -> void:
	for x in range(rect.position.x, rect.end.x):
		for y in range(rect.position.y, rect.end.y):
			if in_map(Vector2i(x, y)):
				_grid.set_point_solid(Vector2i(x, y), solid)


func add_resource(kind: String, cell: Vector2i, size: int = 1) -> int:
	var id := _new_id()
	_set_solid(Rect2i(cell, Vector2i(size, size)), true)
	resources[id] = {
		"id": id, "kind": kind, "cell": cell, "size": size,
		"pos": Vector2(cell) + Vector2(size, size) * 0.5,
		"amount": GOLD_IN_MINE if kind == "gold" else WOOD_IN_TREE,
	}
	return id


func spawn_building(player: int, key: String, def: Dictionary, cell: Vector2i, done: bool = true) -> int:
	var size: int = int(def.get("size", 2))
	var id := _new_id()
	_set_solid(Rect2i(cell, Vector2i(size, size)), true)
	var max_hp := float(def.get("hp", 100))
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
	var p := cell_center(nearest_free_cell(to_cell(pos)))
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
			if t != null and enemies(int(t["player"]), int(cmd["player"])) and not t["def"].get("invulnerable", false):
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
		if _grid.is_point_solid(dest_cell) or taken.has(dest_cell):
			dest_cell = nearest_free_cell(dest_cell, taken)
			dest = cell_center(dest_cell)
		taken[dest_cell] = true
		u["order"] = {"type": kind, "dest": dest}
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
	if not can_afford(player, def.get("cost", {})):
		_msg(player, "Не хватает ресурсов")
		return
	_pay(player, def["cost"])
	var id := spawn_building(player, key, def, cell, false)
	players[player]["stats"]["built"] += 1
	var rect := Rect2i(cell, Vector2i(size, size))
	for uid in units:   # кто стоял на месте стройки — отходит в сторону
		var u: Dictionary = units[uid]
		if rect.has_point(to_cell(u["pos"])) and not workers.has(uid):
			_path_to(u, cell_center(nearest_free_cell(to_cell(u["pos"]))))
	for uid in workers:
		_start_build(units[uid], id)


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
			_msg(player, "Для второго героя улучшите главное здание (%s)" % hall_name)
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
	if int(players[player]["supply_used"]) + int(def.get("supply", 0)) > int(players[player]["supply_cap"]):
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


func can_afford(player: int, cost: Dictionary) -> bool:
	return int(players[player]["gold"]) >= int(cost.get("gold", 0)) and int(players[player]["wood"]) >= int(cost.get("wood", 0))


func _pay(player: int, cost: Dictionary) -> void:
	players[player]["gold"] -= int(cost.get("gold", 0))
	players[player]["wood"] -= int(cost.get("wood", 0))


func _msg(player: int, text: String) -> void:
	events.append({"type": "msg", "player": player, "text": text})


# ---------- шаг симуляции ----------

func step() -> void:
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

	var ids: Array = units.keys()
	ids.sort()
	for id in ids:
		_move_unit(units[id])
	_rebuild_buckets(ids)
	_separate(ids)
	_collect_auras(ids)
	for id in ids:
		if units.has(id):   # юнит мог погибнуть в этом же тике
			_think(units[id])
	var pids: Array = projectiles.keys()
	pids.sort()
	for id in pids:
		_fly(projectiles[id])
	var bids: Array = buildings.keys()
	bids.sort()
	for id in bids:
		if buildings.has(id):
			_update_building(buildings[id])
	_respawn_camps()
	_update_runes()


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
			if pos.distance_squared_to(nxt) > 64.0 or not _clear_line(pos, nxt, clampf(float(u["radius"]), 0.2, 0.42)):
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
	for ida in ids:
		var ua: Dictionary = units[ida]
		var near: Array = _candidates(ua["pos"], float(ua["radius"]) + MAX_RADIUS)
		near.sort()
		for idb in near:
			if int(idb) <= int(ida) or not units.has(idb):
				continue
			var ub: Dictionary = units[idb]
			var delta: Vector2 = ub["pos"] - ua["pos"]
			var min_d: float = float(ua["radius"]) + float(ub["radius"])
			if absf(delta.x) >= min_d or absf(delta.y) >= min_d:
				continue
			var d := delta.length()
			if d >= min_d:
				continue
			var dir := Vector2(1, 0).rotated(float(int(ida) * 7 + int(idb) * 13)) if d < 0.001 else delta / d
			var push := dir * (min_d - d) * 0.25
			_try_shift(ua, -push)
			_try_shift(ub, push)


func _try_shift(u: Dictionary, shift: Vector2) -> void:
	if u["busy"] or float(u["base"]["speed"]) <= 0.0:
		return   # работающих, бьющих и неподвижных (глаз-наблюдатель) не толкаем
	var p: Vector2 = u["pos"] + shift
	var c := to_cell(p)
	if in_map(c) and not _grid.is_point_solid(c):
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
		if not is_blocked(to_cell(wp)) and _clear_line(pos, wp, 0.2):
			path.insert(i, wp)
			u["path"] = path
			return


func is_moving(u: Dictionary) -> bool:
	return int(u["path_i"]) < (u["path"] as PackedVector2Array).size()


func _stop_path(u: Dictionary) -> void:
	u["path"] = PackedVector2Array()
	u["path_i"] = 0


func _think(u: Dictionary) -> void:
	u["busy"] = false
	u["cd"] = maxf(0.0, float(u["cd"]) - TICK_DT)
	if int(u["expires"]) >= 0 and tick >= int(u["expires"]):
		_kill(u, NEUTRAL)       # время призванного существа вышло
		return
	_refresh_stats(u)
	if float(u["max_mana"]) > 0.0:
		u["mana"] = minf(float(u["max_mana"]), float(u["mana"]) + float(u["mana_regen"]) * TICK_DT)
	if float(u["hp_regen"]) > 0.0:
		u["hp"] = minf(float(u["max_hp"]), float(u["hp"]) + float(u["hp_regen"]) * TICK_DT)
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
			_auto_acquire(u, o)
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


## Целители сами лечат самого раненого союзника рядом, когда перезарядка готова
## и хватает маны (ac.mana за одно лечение).
func _autocast(u: Dictionary) -> void:
	var ac: Dictionary = u["def"]["autocast"]
	if tick < int(u["cds"].get("auto", 0)):
		return
	if String(ac.get("kind", "heal")) == "summon":
		_autocast_summon(u, ac)
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
	u["cds"]["auto"] = tick + int(float(ac.get("cooldown", 12.0)) * TICK_RATE)
	var spot: Vector2 = (u["pos"] as Vector2) + (u["facing"] as Vector2).rotated(0.9 * (1 if alive.size() % 2 == 0 else -1)) * 1.4
	var id := spawn_unit(player, key, def, spot, false)
	units[id]["expires"] = tick + int(float(ac.get("duration", 40.0)) * TICK_RATE)
	units[id]["camp"] = -1
	alive.append(id)
	u["raised"] = alive
	events.append({"type": "cast", "id": u["id"], "key": "autocast"})
	events.append({"type": "blast", "pos": spot, "radius": 1.2, "color": String(ac.get("color", "#6aff8a"))})
	var target := int(u["order"].get("target", foe))
	if entity(target) != null and enemies(int(entity(target)["player"]), player):
		_order_attack(units[id], target, {})


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
	if int(u["player"]) == NEUTRAL:
		if (u["pos"] as Vector2).distance_to(u["home"]) > 1.5 and not is_moving(u):
			u["order"] = {"type": "home"}
			_path_to(u, u["home"])
		return false
	if is_worker(u) or float(u["damage"]) <= 0.0 or (tick + int(u["id"])) % 3 != 0:
		return false
	var best := _nearest_enemy(u["pos"], int(u["player"]), ACQUIRE, true)
	if best < 0:
		return false
	_order_attack(u, best, o if String(o.get("type")) == "amove" else {})
	return true


func _nearest_enemy(pos: Vector2, player: int, max_dist: float, with_buildings: bool) -> int:
	var best := -1
	var best_d := max_dist
	for id in _candidates(pos, max_dist):
		if not units.has(id):
			continue
		var t: Dictionary = units[id]
		if not enemies(int(t["player"]), player):
			continue
		if int(t["player"]) == NEUTRAL and String(t["order"].get("type")) != "attack":
			continue
		var d: float = pos.distance_to(t["pos"])
		if d < best_d or (d == best_d and int(id) < best):
			best_d = d
			best = int(id)
	if best < 0 and with_buildings:
		for id in buildings:
			var b: Dictionary = buildings[id]
			if not enemies(int(b["player"]), player) or int(b["player"]) == NEUTRAL:
				continue
			var d: float = pos.distance_to(b["pos"]) - float(b["radius"])
			if d < best_d or (d == best_d and int(id) < best):
				best_d = d
				best = int(id)
	return best


func _order_attack(u: Dictionary, target: int, resume: Dictionary) -> void:
	u["order"] = {"type": "attack", "target": target, "resume": resume}
	u["wait"] = 0


func _do_attack(u: Dictionary, o: Dictionary) -> void:
	var t = entity(int(o["target"]))
	var neutral := int(u["player"]) == NEUTRAL
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
			u["swing_target"] = int(t["id"])
			u["busy"] = true
			events.append({"type": "attack", "id": u["id"], "windup": windup})
		return
	# цель далеко: догоняем, время от времени прокладывая путь заново
	if int(u["wait"]) > 0:
		u["wait"] = int(u["wait"]) - 1
		return
	u["wait"] = 4
	if t["is_building"]:
		_go_adjacent(u, _rect(t))
	else:
		_path_to(u, _attack_spot(u, t))


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
	for a in [0.0, 0.55, -0.55, 1.1, -1.1, 1.65, -1.65, 2.3, -2.3]:
		var spot: Vector2 = tp + dir.rotated(a) * ring
		if is_blocked(to_cell(spot)):
			continue
		var crowd := 0
		for oid in _units_near(spot, float(u["radius"]) + 0.15):
			if oid != int(u["id"]) and oid != int(t["id"]):
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
	var dmg := float(u["damage"])
	if float(u.get("crit", 0.0)) > 0.0 and _roll(int(u["id"]), int(t["id"]) + 7) < float(u["crit"]):
		dmg *= CRIT_MUL       # критический удар
		events.append({"type": "float", "player": u["player"], "pos": t["pos"], "text": "%d!" % roundi(dmg), "color": "#ff5a4a"})
	var splash_r := float(u["def"].get("splash_radius", 0.0))
	if float(u["range"]) > 2.0:
		var pid := _shoot(u["pos"], t, dmg, String(u["damage_type"]), int(u["id"]), int(u["player"]),
			String(u["def"].get("projectile", "rock" if String(u["damage_type"]) == "siege" else "arrow")), 1.2 * float(u["def"]["model"].get("scale", 1.0)))
		if splash_r > 0.0:       # осадные машины бьют по площади
			projectiles[pid]["splash"] = float(u["def"].get("splash", 0.5))
			projectiles[pid]["splash_radius"] = splash_r
	else:
		var tpos: Vector2 = t["pos"]
		_damage(t, dmg, String(u["damage_type"]), int(u["id"]), int(u["player"]), true)
		if splash_r > 0.0:
			for oid in _units_near(tpos, splash_r):
				if units.has(oid) and oid != int(t["id"]) and enemies(int(units[oid]["player"]), int(u["player"])):
					_damage(units[oid], dmg * float(u["def"].get("splash", 0.5)), String(u["damage_type"]), int(u["id"]), int(u["player"]))


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
			for oid in _units_near(p["tpos"], float(p["splash_radius"])):
				if oid != int(p["target"]) and units.has(oid) and enemies(int(units[oid]["player"]), int(p["player"])):
					_damage(units[oid], float(p["damage"]) * float(p["splash"]), String(p["damage_type"]), int(p["attacker"]), int(p["player"]))
			events.append({"type": "blast", "pos": p["tpos"], "radius": p["splash_radius"], "color": "#ff7a2a"})
		projectiles.erase(p["id"])
	else:
		p["pos"] = (p["pos"] as Vector2) + to.normalized() * step_len


func _damage(t: Dictionary, amount: float, dtype: String, attacker: int, attacker_player: int, attack := false) -> void:
	if t["def"].get("invulnerable", false):
		return
	var src = entity(attacker)
	if attack and float(t.get("evasion", 0.0)) > 0.0 and _roll(attacker, int(t["id"])) < float(t["evasion"]):
		events.append({"type": "float", "pos": t["pos"], "text": "промах", "color": "#c9ced6"})
		return
	var mult: float = float(combat.get("multipliers", {}).get(dtype, {}).get(String(t["armor_type"]), 1.0))
	if dtype == "holy" and t["def"].get("undead", false):
		mult *= HOLY_VS_UNDEAD      # святой урон особенно опасен для нежити
	var armor: float = maxf(0.0, float(t["armor"])) * float(combat.get("armor_k", 0.06))
	var dealt: float = amount * mult * (1.0 - armor / (1.0 + armor)) * float(t.get("dmg_taken", 1.0))
	var hp_before := float(t["hp"])
	t["hp"] = float(t["hp"]) - dealt
	t["last_hit_by"] = attacker
	if t["def"].get("boss", false) and attacker_player != NEUTRAL and players.has(attacker_player):
		var by: Dictionary = t.get("dmg_by", {})      # кто сколько урона нанёс боссу (добивание — не больше оставшегося здоровья)
		by[attacker_player] = float(by.get(attacker_player, 0.0)) + minf(dealt, maxf(0.0, hp_before))
		t["dmg_by"] = by
	events.append({"type": "hit", "id": t["id"]})
	if attack and src != null and not src["is_building"]:
		if src["def"].has("chill") and not t["is_building"]:      # холод глубин (наги): цель замедляется
			var ch: Dictionary = src["def"]["chill"]
			_add_buff(t, "chill", float(ch.get("duration", 2.0)), {"speed_mul": float(ch.get("speed_mul", 0.7)), "cooldown_mul": float(ch.get("cooldown_mul", 1.15))})
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
			if int(mate["player"]) == NEUTRAL and int(mate["camp"]) == int(t["camp"]) and String(mate["order"].get("type")) != "attack":
				_order_attack(mate, attacker, {})
	elif not is_worker(t) and float(t["damage"]) > 0.0:
		var kind := String(t["order"].get("type"))
		if kind == "idle" or kind == "amove":
			_order_attack(t, attacker, t["order"] if kind == "amove" else {})


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
	_award_xp(t, killer_player)
	if t["def"].has("split"):      # слизень делится на маленьких
		var sp: Dictionary = t["def"]["split"]
		for i in int(sp.get("count", 2)):
			var kid := spawn_unit(owner, String(sp["unit"]), _scaled_def(String(sp["unit"]), float(t.get("power", 1.0))), (t["pos"] as Vector2) + Vector2(0.6, 0).rotated(float(i) * PI + float(t["id"])), false)
			units[kid]["camp"] = t["camp"]
			units[kid]["power"] = t.get("power", 1.0)
			if t.has("camp_level"):
				units[kid]["camp_level"] = t["camp_level"]
			units[kid]["home"] = t["home"]
			if owner == NEUTRAL and killer_player != NEUTRAL and entity(int(t.get("last_hit_by", -1))) != null:
				_order_attack(units[kid], int(t["last_hit_by"]), {})
	if t["def"].get("boss", false):
		_boss_slain(t)
	if owner == NEUTRAL and int(t["camp"]) >= 0 and killer_player != NEUTRAL and players.has(killer_player):
		var left := false
		for id in units:
			if int(units[id]["player"]) == NEUTRAL and int(units[id]["camp"]) == int(t["camp"]):
				left = true
				break
		if not left:
			_camp_cleared(int(t.get("camp_level", t["def"].get("level", 1))), t["pos"], killer_player, int(t["camp"]))
	if int(t["bounty"]) > 0 and killer_player != NEUTRAL and players.has(killer_player):
		players[killer_player]["gold"] += int(t["bounty"])
		players[killer_player]["stats"]["gold"] += int(t["bounty"])
		events.append({"type": "bounty", "player": killer_player, "amount": int(t["bounty"]), "pos": t["pos"]})


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
	events.append({"type": "boss_slain", "player": best, "name": t["def"]["name"], "pos": t["pos"]})
	for p in players:
		if int(p) != NEUTRAL:
			_msg(int(p), "%s повержен! Больше всего урона нанёс игрок %d — его герои получают «Силу дракона»" % [t["def"]["name"], best + 1])


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
		if int(units[id]["player"]) == NEUTRAL and int(units[id]["expires"]) < 0:
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
		return
	match String(b["def"].get("role", "")):
		"capture":
			_update_capture(b)
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


## {"type": "hire", "player": 0, "building": id лагеря наёмников, "unit": "troll"}
func _cmd_hire(cmd: Dictionary) -> void:
	var player: int = int(cmd["player"])
	var b = buildings.get(cmd.get("building"))
	var key := String(cmd.get("unit", ""))
	if b == null or String(b["def"].get("role", "")) != "mercenary" or not b["def"].get("hires", {}).has(key):
		return
	var offer: Dictionary = b["def"]["hires"][key]
	var near := false
	for id in units:
		if int(units[id]["player"]) == player and (units[id]["pos"] as Vector2).distance_to(b["pos"]) <= SHOP_RANGE:
			near = true
			break
	if not near:
		_msg(player, "Подведите к лагерю наёмников любого своего юнита")
	elif tick < int(b.get("hire_cd", 0)):
		_msg(player, "Наёмники ещё не готовы: %d с" % ceili((int(b["hire_cd"]) - tick) * TICK_DT))
	elif int(players[player]["supply_used"]) + int(offer.get("supply", 2)) > int(players[player]["supply_cap"]):
		_msg(player, "Не хватает лимита")
	elif not can_afford(player, offer):
		_msg(player, "Не хватает золота")
	else:
		_pay(player, offer)
		var def: Dictionary = players[NEUTRAL]["data"]["units"][key].duplicate()
		def["supply"] = int(offer.get("supply", 2))
		def["bounty"] = 0
		def["role"] = "merc"
		var ring := _ring(_rect(b))
		var spot: Vector2 = cell_center(ring[(int(b["id"]) + tick) % ring.size()]) if not ring.is_empty() else b["pos"]
		spawn_unit(player, key, def, spot)
		b["hire_cd"] = tick + int(float(b["def"].get("hire_cooldown", 20)) * TICK_RATE)
		events.append({"type": "bought", "player": player, "id": -1, "item": "", "hired": def["name"]})


# ---------- способности героев, усиления, ауры ----------

var _auras: Array = []


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
	for id in ids:
		var u: Dictionary = units[id]
		if u["def"].has("aura"):      # аура обычного юнита (знаменосец)
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


## Текущие характеристики = базовые + временные усиления + ауры + предметы.
## Виды изменений: armor_add, damage_add, damage_mul, cooldown_mul, speed_mul, hp_regen, mana_regen,
## crit_chance, evasion, lifesteal, thorns, damage_taken_mul (hp_add и mana_add — при получении предмета).
func _refresh_stats(u: Dictionary) -> void:
	var d: Dictionary = u["def"]      # врождённые свойства (у сильных нейтралов)
	var m := {"armor_add": 0.0, "damage_mul": 1.0, "damage_add": 0.0, "cooldown_mul": 1.0, "speed_mul": 1.0, "hp_regen": float(d.get("hp_regen", 0)), "mana_regen": 0.0, "hp_add": 0.0,
		"crit_chance": float(d.get("crit_chance", 0)), "evasion": float(d.get("evasion", 0)), "lifesteal": float(d.get("lifesteal", 0)), "thorns": float(d.get("thorns", 0)), "damage_taken_mul": 1.0}
	for ik in u["items"]:      # предметы героя
		_mix(m, item_def(String(ik)).get("mods", {}))
	if d.get("undead", false) and is_night():
		m["hp_regen"] = float(m["hp_regen"]) + NIGHT_UNDEAD_REGEN      # нежить крепнет ночью
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
	for key in ups:     # изученные улучшения действуют на всех юнитов игрока
		var umods: Dictionary = players[u["player"]]["data"]["upgrades"][key]["mods"]
		var lvl: float = float(ups[key])
		for mk in umods:
			if String(mk).ends_with("_mul"):
				m[mk] = float(m[mk]) * pow(float(umods[mk]), lvl)
			else:
				m[mk] = float(m[mk]) + float(umods[mk]) * lvl
	var base: Dictionary = u["base"]
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
		"runes": runes, "rune_spots": rune_spots,
	}


## Вызывается на новой симуляции, в которой уже отмечены непроходимые клетки рельефа.
func load_state(d: Dictionary) -> void:
	tick = int(d["tick"])
	seed_value = int(d["seed"])
	units = d["units"]
	buildings = d["buildings"]
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
		p["gold"] += int(b["def"]["cost"].get("gold", 0)) * 3 / 4
		p["wood"] += int(b["def"]["cost"].get("wood", 0)) * 3 / 4
		_set_solid(_rect(b), false)
		buildings.erase(b["id"])
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
	var cost := upgrade_cost(player, key)
	if not can_afford(player, cost):
		_msg(player, "Не хватает ресурсов")
		return
	_pay(player, cost)
	p["research_wip"][key] = true
	var time: float = float(up.get("time", 40)) * (level + 1)
	(b["queue"] as Array).append({"key": key, "research": true, "left": time, "total": time, "hero": false, "revive": false})


## Уровень главного здания игрока: 1 в начале, растёт улучшением «tier» в ратуше.
func tier(player: int) -> int:
	return 1 + int(players[player]["upgrades"].get("tier", 0))


## Каждый следующий уровень улучшения дороже.
func upgrade_cost(player: int, key: String) -> Dictionary:
	var up: Dictionary = players[player]["data"]["upgrades"][key]
	var n: int = int(players[player]["upgrades"].get(key, 0)) + 1
	return {"gold": int(up["cost"].get("gold", 0)) * n, "wood": int(up["cost"].get("wood", 0)) * n}


func _finish_research(b: Dictionary, q: Dictionary) -> void:
	var p: Dictionary = players[b["player"]]
	p["research_wip"].erase(q["key"])
	p["upgrades"][q["key"]] = int(p["upgrades"].get(q["key"], 0)) + 1
	_msg(int(b["player"]), "Исследовано: %s, уровень %d" % [String(p["data"]["upgrades"][q["key"]]["name"]).to_lower(), int(p["upgrades"][q["key"]])])
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
		else:
			_repath(u, _rect(r))
		return
	u["busy"] = true
	o["timer"] = float(o["timer"]) - TICK_DT
	if float(o["timer"]) > 0.0:
		return
	var carry_key := "carry_gold" if String(r["kind"]) == "gold" else "carry_wood"
	var amount: int = mini(int(u["def"].get(carry_key, 10)), int(r["amount"]))
	r["amount"] = int(r["amount"]) - amount
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
		var gained: int = int(round(int(u["carry"]) * float(players[u["player"]].get("income_mul", 1.0))))
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
	u["busy"] = true
	u["facing"] = ((b["pos"] as Vector2) - (u["pos"] as Vector2)).normalized()
	_stop_path(u)
	b["progress"] = minf(1.0, float(b["progress"]) + TICK_DT / maxf(1.0, float(b["def"].get("build_time", 30))))
	b["hp"] = minf(float(b["max_hp"]), float(b["hp"]) + float(b["max_hp"]) * 0.9 * TICK_DT / maxf(1.0, float(b["def"].get("build_time", 30))))
	if float(b["progress"]) >= 1.0:
		b["done"] = true
		players[b["player"]]["supply_cap"] += int(b["def"].get("supply_given", 0))
		events.append({"type": "building_done", "id": b["id"]})
		_idle(u)


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


func _path_to(u: Dictionary, dest: Vector2) -> void:
	var start_cell := nearest_free_cell(to_cell(u["pos"]))
	var goal := nearest_free_cell(to_cell(dest))
	var path: PackedVector2Array = _grid.get_point_path(start_cell, goal, true)
	# если цель недостижима (за обрывом, на острове), путь ведёт к ближайшей достижимой точке —
	# и тогда точную точку цели подставлять нельзя: юнит пошёл бы к ней напрямую сквозь скалы
	var reached := path.size() > 0 and to_cell(path[path.size() - 1]) == goal
	if path.size() > 0:
		path.remove_at(0)            # первая точка — клетка, где юнит уже стоит
	if reached and not is_blocked(to_cell(dest)):
		if path.size() > 0:
			path[path.size() - 1] = dest # последняя точка — точное место
		else:
			path.append(dest)
	u["path"] = path
	u["path_i"] = 0
	u["stuck"] = 0


## Свободна ли прямая между точками для юнита (проверяются клетки вдоль линии и по её бокам).
func _clear_line(a: Vector2, b: Vector2, r: float) -> bool:
	var d := b - a
	var length := d.length()
	if length < 0.01:
		return true
	var n := int(ceil(length / 0.45))
	var side := Vector2(-d.y, d.x) / length * r
	for k in range(1, n + 1):
		var p := a + d * (float(k) / n)
		if _grid.is_point_solid(to_cell(p)) or _grid.is_point_solid(to_cell(p + side)) or _grid.is_point_solid(to_cell(p - side)):
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
	for id in buildings:
		var b: Dictionary = buildings[id]
		if int(b["player"]) != int(u["player"]) or not b["done"] or String(b["def"].get("role", "")) != "hall":
			continue
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


func is_blocked(c: Vector2i) -> bool:
	return not in_map(c) or _grid.is_point_solid(c)


func nearest_free_cell(c: Vector2i, taken: Dictionary = {}) -> Vector2i:
	if not is_blocked(c) and not taken.has(c):
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
