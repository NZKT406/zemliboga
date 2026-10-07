extends RefCounted
## Компьютерный противник. Он не жульничает с правилами: управляет своей стороной
## теми же командами, что и игрок (sim.push_command). Думает раз в секунду.

const Sim = preload("res://scripts/sim.gd")

var sim: Sim
var terrain
var me := 1
## Всё, что ИИ помнит между «мыслями» (сохраняется вместе с игрой).
var s := {"state": "gather", "wave": 0, "next_build": 0, "next_order": 0, "next_creep": 900}

var _workers: Array = []
var _army: Array = []
var _built: Dictionary = {}     # ключ здания -> {"done": [...], "wip": [...]}
var _base := Vector2.ZERO
var _saving := {"gold": 0, "wood": 0}
var _p: Dictionary = {}

## Уровни сложности. first_attack — в тиках (10 тиков = 1 секунда).
const LEVELS := {
	"easy": {"first_attack": 4200, "wave_base": 5, "wave_step": 1, "wave_max": 10, "workers": 8, "creep": false, "towers": 0, "barracks": 1, "spells": false, "slow": true},
	"normal": {"first_attack": 2400, "wave_base": 8, "wave_step": 2, "wave_max": 18, "workers": 12, "creep": true, "towers": 2, "barracks": 2, "spells": true, "slow": false},
	"hard": {"first_attack": 1800, "wave_base": 10, "wave_step": 3, "wave_max": 26, "workers": 14, "creep": true, "towers": 2, "barracks": 3, "spells": true, "slow": false},
}


func _init(sim_ref: Sim, terrain_ref, player: int) -> void:
	sim = sim_ref
	terrain = terrain_ref
	me = player


func think() -> void:
	if sim.game_over:
		return
	_p = LEVELS.get(String(s.get("difficulty", "normal")), LEVELS["normal"])
	s["n"] = int(s.get("n", 0)) + 1
	if _p["slow"] and int(s["n"]) % 2 == 0:
		return     # лёгкий противник думает вдвое реже
	_collect()
	if not _built.has("hall") or _built["hall"]["done"].is_empty():
		_military()      # без главного здания остаётся только драться
		return
	_base = sim.buildings[_built["hall"]["done"][0]]["pos"]
	_economy()
	_construction()
	_production()
	_hire_mercs()
	_military()
	_learn_skills()
	_help_allies()
	if _p["spells"]:
		_spells()
		_shopping()


## Союзнику, у которого совсем пусто в казне, богатый компьютер отдаёт часть своего.
func _help_allies() -> void:
	if int(s["n"]) % 30 != 0:      # примерно раз в полминуты
		return
	var mine: Dictionary = sim.players[me]
	for p in sim.active_players():
		if not sim.allies(me, p):
			continue
		var other: Dictionary = sim.players[p]
		var gold := 200 if int(mine["gold"]) > 1000 and int(other["gold"]) < 150 else 0
		var wood := 100 if int(mine["wood"]) > 600 and int(other["wood"]) < 60 else 0
		if gold + wood > 0:
			_cmd({"type": "gift", "to": p, "gold": gold, "wood": wood})
			return


## Очки навыков: сначала сильнейшая способность, иначе та, что изучена меньше всего.
func _learn_skills() -> void:
	for hid in _army:
		var h: Dictionary = sim.units[hid]
		if not h["hero"] or sim.skill_points(h) <= 0:
			continue
		var pick := ""
		var low := 99
		var list: Array = h["def"].get("abilities", [])
		for i in list.size():
			var key := String(list[i]["key"])
			if sim.learn_block(h, key) != "":
				continue
			if list[i].get("ultimate", false):
				pick = key
				break
			if sim.rank(h, key) < low:
				low = sim.rank(h, key)
				pick = key
		if pick != "":
			_cmd({"type": "learn", "unit": hid, "ability": pick})


func _collect() -> void:
	_workers.clear()
	_army.clear()
	_built.clear()
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if int(u["player"]) != me:
			continue
		if sim.is_worker(u):
			_workers.append(int(id))
		else:
			_army.append(int(id))
	_workers.sort()
	_army.sort()
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		if int(b["player"]) != me:
			continue
		var key := String(b["key"])
		if not _built.has(key):
			_built[key] = {"done": [], "wip": []}
		_built[key]["done" if b["done"] else "wip"].append(int(id))
	for key in _built:
		_built[key]["done"].sort()
		_built[key]["wip"].sort()


func _count(key: String) -> int:
	if not _built.has(key):
		return 0
	return _built[key]["done"].size() + _built[key]["wip"].size()


func _done(key: String) -> Array:
	return _built[key]["done"] if _built.has(key) else []


func _afford(cost: Dictionary, with_saving: bool = true) -> bool:
	var p: Dictionary = sim.players[me]
	var g: int = int(cost.get("gold", 0)) + (int(_saving["gold"]) if with_saving else 0)
	var w: int = int(cost.get("wood", 0)) + (int(_saving["wood"]) if with_saving else 0)
	return int(p["gold"]) >= g and int(p["wood"]) >= w


func _cmd(cmd: Dictionary) -> void:
	cmd["player"] = me
	sim.push_command(cmd)


# ---------- хозяйство ----------

func _economy() -> void:
	var gold: Array = []
	var wood: Array = []
	var idle: Array = []
	for id in _workers:
		if sim._has_buff(sim.units[id], "militia"):
			continue      # ополченцы сейчас воюют
		var o: Dictionary = sim.units[id]["order"]
		var kind := String(o.get("type", "idle"))
		if kind == "gather" or kind == "return":
			if String(o.get("kind", "")) == "gold":
				gold.append(id)
			else:
				wood.append(id)
		elif kind != "build" and kind != "repair" and kind != "flee":      # убегающего не трогаем — сам вернётся к делу
			idle.append(id)
	_repair_base(idle)
	var p: Dictionary = sim.players[me]
	var need_wood: bool = int(p["wood"]) < 160
	var need_gold: bool = int(p["gold"]) < 160
	# перебрасываем рабочих туда, где ресурса не хватает
	if (wood.is_empty() or (need_wood and not need_gold and wood.size() < 5)) and gold.size() > 3:
		idle.append(gold.pop_back())
	elif need_gold and not need_wood and wood.size() > 2:
		idle.append(wood.pop_back())
	for id in idle:
		var want_gold := gold.size() < 5 or wood.size() >= (5 if need_wood else 3)
		if need_gold and not need_wood:
			want_gold = true
		var target := sim.nearest_resource("gold" if want_gold else "tree", _base, 45.0)
		if target < 0:
			target = sim.nearest_resource("tree" if want_gold else "gold", _base, 60.0)
		if target >= 0:
			_cmd({"type": "gather", "units": [id], "target": target})
			if want_gold:
				gold.append(id)
			else:
				wood.append(id)
	var data: Dictionary = sim.players[me]["data"]
	var hall: Dictionary = sim.buildings[_done("hall")[0]]
	if _workers.size() < int(_p["workers"]) and (hall["queue"] as Array).is_empty() and _afford(data["units"]["worker"]["cost"], false) and _has_supply(data["units"]["worker"]):
		_cmd({"type": "train", "building": hall["id"], "unit": "worker"})


## Готовые здания, где исследуют оружие и доспехи.
func _research_buildings() -> Array:
	var out: Array = []
	for key in _built:
		for bid in _built[key]["done"]:
			for r in sim.buildings[bid]["def"].get("researches", []):
				if String(r) != "tier" and not out.has(bid):
					out.append(bid)
	out.sort()
	return out


## Люди: свободный рабочий чинит самое повреждённое здание базы.
func _repair_base(idle: Array) -> void:
	if idle.is_empty() or not sim.race_trait(me, "repair") or int(sim.players[me]["gold"]) < 60:
		return
	var worst := -1
	var ratio := 0.7
	for key in _built:
		for bid in _built[key]["done"]:
			var b: Dictionary = sim.buildings[bid]
			var r: float = float(b["hp"]) / float(b["max_hp"])
			if r < ratio:
				ratio = r
				worst = int(bid)
	if worst < 0:
		return
	for id in idle:
		if String(sim.units[id]["order"].get("type")) == "repair":
			return
	_cmd({"type": "repair", "units": [idle.pop_back()], "target": worst})


func _has_supply(def: Dictionary) -> bool:
	var p: Dictionary = sim.players[me]
	return int(p["supply_used"]) + int(def.get("supply", 0)) <= sim.supply_max(me)


# ---------- строительство ----------

func _construction() -> void:
	var p: Dictionary = sim.players[me]
	var defs: Dictionary = p["data"]["buildings"]
	_saving = {"gold": 0, "wood": 0}
	# стройка, оставшаяся без строителя
	for key in _built:
		for bid in _built[key]["wip"]:
			if sim.buildings[bid].get("auto", false):
				continue      # нежить: здание растёт само, строитель не нужен
			var tended := false
			for id in _workers:
				var o: Dictionary = sim.units[id]["order"]
				if String(o.get("type")) == "build" and int(o.get("target", -1)) == int(bid):
					tended = true
			if not tended and not _workers.is_empty():
				_cmd({"type": "resume", "units": [_workers[int(bid) % _workers.size()]], "target": bid})
	if sim.tick < int(s["next_build"]) or _workers.is_empty():
		return
	var want := ""
	var free: int = sim.supply_max(me) - int(p["supply_used"])
	if free < 8 and _wip("supply") < (2 if int(p["supply_cap"]) > 30 else 1) and int(p["supply_cap"]) < sim.supply_limit(me) + 4:
		want = "supply"
	elif _count("barracks") == 0:
		want = "barracks"
	elif _count("altar") == 0 and not _done("barracks").is_empty() and sim.tick > 700:
		want = "altar"
	elif _count("forge") == 0 and _count("altar") > 0 and defs.has("forge") and not _p["slow"] and sim.tick > 1500:
		want = "forge"
	elif _count("tower") < mini(1, int(_p["towers"])) and sim.tick > 1800:
		want = "tower"
	elif _count("temple") == 0 and defs.has("temple") and not _p["slow"] and _count("altar") > 0 and sim.tick > 2100:
		want = "temple"
	elif _count("workshop") == 0 and defs.has("workshop") and not _p["slow"] and sim.tier(me) >= 2:
		want = "workshop"
	elif _count("elite") == 0 and defs.has("elite") and not _p["slow"] and sim.tier(me) >= 2 and _count("temple") > 0:
		want = "elite"
	elif _count("barracks") < int(_p["barracks"]) and sim.tick > 2400 and int(p["gold"]) > 500:
		want = "barracks"
	elif _count("tower") < int(_p["towers"]) and sim.tick > 4200:
		want = "tower"
	if want == "" or not defs.has(want):
		return
	var def: Dictionary = defs[want]
	var bcost: Dictionary = sim.build_cost(me, want)
	if not _afford(bcost, false):
		_saving = {"gold": int(bcost.get("gold", 0)), "wood": int(bcost.get("wood", 0))}   # копим на здание
		return
	var cell := _find_spot(int(def["size"]), want == "tower")
	if cell.x < 0:
		return
	_cmd({"type": "build", "units": [_pick_builder()], "building": want, "cell": cell})
	s["next_build"] = sim.tick + 50


func _wip(key: String) -> int:
	return _built[key]["wip"].size() if _built.has(key) else 0


func _pick_builder() -> int:
	for id in _workers:     # лучше оторвать лесоруба, чем золотодобытчика
		var o: Dictionary = sim.units[id]["order"]
		if String(o.get("type")) != "build" and String(o.get("kind", "")) != "gold":
			return id
	return _workers[_workers.size() - 1]


## Свободное место у базы. Башни ставятся спереди, остальное — по бокам и сзади.
func _find_spot(size: int, front: bool) -> Vector2i:
	var to_center := (_center() - _base).normalized()
	for ring in range(6, 18):
		for step in 12:
			var a := (PI if not front else 0.0) + (float((step + 1) / 2) * (PI / 7.0)) * (1.0 if step % 2 == 0 else -1.0)
			var c := _base + to_center.rotated(a) * float(ring)
			var cell := Vector2i(c) - Vector2i(size / 2, size / 2)
			if sim.can_place(size + 2, cell - Vector2i(1, 1)) and not sim.guarded_spot(c, Sim.GUARD_BUILD_RADIUS + size * 0.5 + 1.0):
				return cell
	return Vector2i(-1, -1)


# ---------- найм ----------

func _production() -> void:
	var p: Dictionary = sim.players[me]
	var units: Dictionary = p["data"]["units"]
	var melee := 0
	var ranged := 0
	for id in _army:
		var role := String(sim.units[id]["def"].get("role", ""))
		if role == "melee" or role == "heavy":
			melee += 1
		elif role == "ranged":
			ranged += 1
	for bid in _done("altar"):
		var b: Dictionary = sim.buildings[bid]
		if not (b["queue"] as Array).is_empty():
			continue
		for key in b["def"].get("trains", []):
			var h = p["heroes"].get(key)
			var state := "" if h == null else String(h["state"])
			if state == "alive" or state == "training":
				continue
			if h == null and (p["heroes"] as Dictionary).size() >= sim.tier(me):
				continue
			if state == "dead" and sim.buildings.has(int(h["altar"])) and int(h["altar"]) != int(bid):
				continue
			var cost: Dictionary = units[key]["cost"]
			if state == "dead":
				cost = {"gold": int(cost.get("gold", 0)) / 2, "wood": int(cost.get("wood", 0)) / 2}
			if _afford(cost) and _has_supply(units[key]):
				_cmd({"type": "train", "building": bid, "unit": key})
				return
	# улучшение главного здания: открывает тяжёлых юнитов и второго героя
	var want_tier := sim.tier(me) < 2 and _army.size() >= 4 and sim.tick > 1200
	if sim.tier(me) == 2 and not _p["slow"] and _army.size() >= 10 and sim.tick > 6000 and sim.tier3_missing(me).is_empty():
		want_tier = true      # третий уровень: когда войско большое и построены алтарь, храм и элитные казармы
	if (p["data"]["upgrades"] as Dictionary).has("tier") and want_tier and not p["research_wip"].has("tier"):
		for bid in _done("hall"):
			if (sim.buildings[bid]["queue"] as Array).is_empty() and _afford(sim.upgrade_cost(me, "tier")):
				_cmd({"type": "research", "building": bid, "upgrade": "tier"})
				break
	# амбары: войско упёрлось в предел пищи — поднимаем его
	if (p["data"]["upgrades"] as Dictionary).has("granary") and sim.supply_limit(me) < sim.SUPPLY_TOP and int(p["supply_used"]) >= sim.supply_limit(me) - 12 \
			and not p["research_wip"].has("granary"):
		for bid in _done("hall"):
			if (sim.buildings[bid]["queue"] as Array).is_empty() and _afford(sim.upgrade_cost(me, "granary")):
				_cmd({"type": "research", "building": bid, "upgrade": "granary"})
				break
	for bid in _research_buildings():      # кузница, а у огров и нагов — логово и казармы
		var fb: Dictionary = sim.buildings[bid]
		if not (fb["queue"] as Array).is_empty() or _army.size() < 6:
			continue
		for key in fb["def"].get("researches", []):
			if String(key) == "tier" or String(key) == "granary":      # амбары — отдельно, когда упрёмся в предел пищи
				continue
			var up: Dictionary = p["data"]["upgrades"][key]
			if int(up.get("tier", 1)) > sim.tier(me):
				continue
			if int(p["upgrades"].get(key, 0)) < int(up.get("max", 3)) and not p["research_wip"].has(key) and _afford(sim.upgrade_cost(me, String(key))):
				_cmd({"type": "research", "building": bid, "upgrade": key})
				break
	for bid in _done("barracks"):
		var b: Dictionary = sim.buildings[bid]
		if (b["queue"] as Array).size() >= 2:
			continue
		var key := "melee" if melee <= ranged else "ranged"
		if units.has("heavy") and int(units["heavy"].get("tier", 1)) <= sim.tier(me) and (melee + ranged) % 3 == 2 and _afford(units["heavy"]["cost"]) and _has_supply(units["heavy"]):
			key = "heavy"
		elif (melee + ranged) % 4 == 3:      # иногда — особый боец казармы (алебардщик, вепрь, паук...)
			for extra in b["def"].get("trains", []):
				if not String(extra) in ["melee", "ranged", "heavy"] and int(units[extra].get("tier", 1)) <= sim.tier(me) and _afford(units[extra]["cost"]) and _has_supply(units[extra]):
					key = String(extra)
					break
		if _afford(units[key]["cost"]) and _has_supply(units[key]):
			_cmd({"type": "train", "building": bid, "unit": key})
			if key == "ranged":
				ranged += 1
			else:
				melee += 1
	# храм и мастерская: немного целителей, особых бойцов и осадных машин
	var roles: Dictionary = {}
	for id in _army:
		var r := String(sim.units[id]["def"].get("role", ""))
		roles[r] = int(roles.get(r, 0)) + 1
	var limits := {"healer": 2, "elite": 3, "support": 1, "siege": 2 if String(s.get("difficulty", "normal")) != "hard" else 3}
	var have: Dictionary = {}      # элитные казармы: каждого вида не больше 4
	for id in _army:
		var uk := String(sim.units[id]["key"])
		have[uk] = int(have.get(uk, 0)) + 1
	for bid in _done("elite"):
		var eb: Dictionary = sim.buildings[bid]
		if not (eb["queue"] as Array).is_empty():
			continue
		var opts: Array = eb["def"].get("trains", []).duplicate()
		opts.reverse()      # сначала самый сильный (3 уровня), если он уже открыт
		for key in opts:
			var def: Dictionary = units[key]
			if int(def.get("tier", 1)) > sim.tier(me) or int(have.get(key, 0)) >= 4:
				continue
			if _afford(def["cost"]) and _has_supply(def):
				_cmd({"type": "train", "building": bid, "unit": key})
				break
	for bkey in ["temple", "workshop"]:
		for bid in _done(bkey):
			var b: Dictionary = sim.buildings[bid]
			if not (b["queue"] as Array).is_empty():
				continue
			for key in b["def"].get("trains", []):
				var def: Dictionary = units[key]
				var role := String(def.get("role", ""))
				if int(roles.get(role, 0)) >= int(limits.get(role, 1)) or int(def.get("tier", 1)) > sim.tier(me):
					continue
				if _afford(def["cost"]) and _has_supply(def):
					_cmd({"type": "train", "building": bid, "unit": key})
					roles[role] = int(roles.get(role, 0)) + 1
					break


## Наёмники: войско проходит мимо лагеря, а золота в избытке — нанимаем лучшего доступного.
func _hire_mercs() -> void:
	var p: Dictionary = sim.players[me]
	if int(p["gold"]) < 420 or sim.tick < int(s.get("next_hire", 0)):
		return
	var ids: Array = sim.buildings.keys()
	ids.sort()
	for bid in ids:
		var b: Dictionary = sim.buildings[bid]
		if String(b["def"].get("role", "")) != "mercenary" or not b.has("merc"):
			continue
		var near := false
		for uid in sim._units_near(b["pos"], sim.SHOP_RANGE):
			if int(sim.units[uid]["player"]) == me:
				near = true
				break
		if not near:
			continue
		var best := ""
		var best_gold := 0
		var offers: Dictionary = sim.merc_offers(b)
		var keys: Array = offers.keys()
		keys.sort()
		for k in keys:
			var o: Dictionary = offers[k]
			var def: Dictionary = sim.merc_def(String(k))
			if int(b["stock"].get(k, 0)) <= 0 or def.is_empty() or not _has_supply(def):
				continue
			if int(o.get("gold", 0)) + 250 > int(p["gold"]) or int(o.get("wood", 0)) > int(p["wood"]):
				continue
			if int(o.get("gold", 0)) > best_gold:
				best_gold = int(o.get("gold", 0))
				best = String(k)
		if best != "":
			_cmd({"type": "hire", "building": int(bid), "unit": best})
			s["next_hire"] = sim.tick + 200
			return


# ---------- армия ----------

func _foes_near(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if not sim.enemies(int(u["player"]), me) or u.get("hidden", false):      # свои, союзники и укрывшиеся эльфы
			continue
		if int(u["player"]) == Sim.NEUTRAL and String(u["order"].get("type")) != "attack":
			continue
		if (u["pos"] as Vector2).distance_to(pos) <= radius:
			out.append(int(id))
	out.sort()
	return out


func _center() -> Vector2:
	return Vector2(sim.map_size, sim.map_size) * 0.5


## Захват ближайшей чужой или ничьей шахты гоблинов. Возвращает true, если пошли.
func _capture() -> bool:
	s["next_capture"] = sim.tick + 400
	var pick := Vector2(-1, -1)
	var best := 40.0 * float(sim.map_size) / 96.0
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		var owner := int(b.get("owner", -1))
		if String(b["def"].get("role", "")) == "capture" and (owner < 0 or sim.enemies(owner, me)) and (b["pos"] as Vector2).distance_to(_base) < best:
			best = (b["pos"] as Vector2).distance_to(_base)
			pick = b["pos"]
	var free := _free_units()
	if pick.x < 0.0 or free.size() < 4:
		return false
	var guard := -1      # охрану шахты сначала надо разбить: нейтралы сами не нападают
	for id in sim.units:
		if int(sim.units[id]["player"]) == Sim.NEUTRAL and (sim.units[id]["pos"] as Vector2).distance_to(pick) < 8.0:
			guard = int(id)
			break
	if guard >= 0:
		_cmd({"type": "attack", "units": free, "target": guard})
	else:
		_cmd({"type": "amove", "units": free, "target": pick})
	s["next_order"] = maxi(int(s["next_order"]), sim.tick + 150)     # дать постоять у шахты
	return true


func _free_units() -> Array:
	var out: Array = []
	for id in _army:
		var kind := String(sim.units[id]["order"].get("type", "idle"))
		if kind == "idle" or kind == "move":
			out.append(id)
	return out


func _military() -> void:
	if _army.is_empty():
		s["state"] = "gather"
		return
	if sim.tick < int(s["next_order"]):
		return
	s["next_order"] = sim.tick + 30
	var to_center := (_center() - _base).normalized()
	var rally := _base + to_center * 9.0
	# оборона базы важнее всего
	var threat := _foes_near(_base, 17.0)
	if threat.size() >= 3 and threat.size() > _army.size() and _base != Vector2.ZERO:      # люди: по тревоге — ополчение
		for hid in _done("hall"):
			for act in sim.buildings[hid]["def"].get("actions", []):
				if String(act["key"]) == "militia" and sim.tick >= int(sim.buildings[hid].get("cds", {}).get("militia", 0)):
					_cmd({"type": "action", "building": hid, "action": "militia"})
	if not threat.is_empty() and _base != Vector2.ZERO:
		var where: Vector2 = sim.units[threat[0]]["pos"]
		var defenders: Array = []
		for id in _army:
			if String(sim.units[id]["order"].get("type")) != "attack":
				defenders.append(id)
		if not defenders.is_empty():
			_cmd({"type": "amove", "units": defenders, "target": where})
		return
	if String(s["state"]) == "gather":
		var need: int = mini(int(_p["wave_base"]) + int(s["wave"]) * int(_p["wave_step"]), int(_p["wave_max"]))
		var p: Dictionary = sim.players[me]
		if sim.tick < int(_p["first_attack"]):
			need = 999     # в начале игры противник не нападает
		if _army.size() >= need or (sim.tick >= int(_p["first_attack"]) and sim.supply_max(me) >= 60 and int(p["supply_used"]) >= sim.supply_max(me) - 3):
			s["state"] = "attack"
			s["wave"] = int(s["wave"]) + 1
		else:
			if _p["creep"] and _army.size() >= 5 and sim.tick >= int(s["next_creep"]) and _creep():
				return
			if _p["creep"] and _army.size() >= 6 and sim.tick >= int(s.get("next_capture", 1500)) and _capture():
				return
			var far: Array = []
			for id in _free_units():
				if (sim.units[id]["pos"] as Vector2).distance_to(rally) > 7.0:
					far.append(id)
			if not far.is_empty():
				_cmd({"type": "move", "units": far, "target": rally})
			return
	# атака: идём на ближайшее вражеское здание
	if _army.size() < 3:
		s["state"] = "gather"
		_cmd({"type": "move", "units": _army.duplicate(), "target": rally})
		return
	var centre := Vector2.ZERO
	for id in _army:
		centre += sim.units[id]["pos"]
	centre /= float(_army.size())
	var target := Vector2(-1, -1)
	var best := INF
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		if sim.enemies(int(b["player"]), me) and int(b["player"]) != Sim.NEUTRAL and not sim.players[b["player"]].get("defeated", false) and (b["pos"] as Vector2).distance_to(centre) < best:
			best = (b["pos"] as Vector2).distance_to(centre)
			target = b["pos"]
	if target.x < 0.0:
		s["state"] = "gather"
		return
	var free := _free_units()
	if not free.is_empty():
		_cmd({"type": "amove", "units": free, "target": target})


## Зачистка слабого лагеря нейтралов ради золота. Возвращает true, если пошли.
func _creep() -> bool:
	var camps: Dictionary = {}     # лагерь -> {level, hp, unit}
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if int(u["player"]) != Sim.NEUTRAL:
			continue
		var c: int = int(u["camp"])
		if not camps.has(c):
			camps[c] = {"level": 0, "hp": 0.0, "unit": int(id), "dist": (u["home"] as Vector2).distance_to(_base)}
		camps[c]["level"] = maxi(int(camps[c]["level"]), int(u["level"]))
		camps[c]["hp"] = float(camps[c]["hp"]) + float(u["hp"])
		camps[c]["unit"] = mini(int(camps[c]["unit"]), int(id))
	var power := 0.0
	for id in _army:
		power += float(sim.units[id]["hp"])
	var pick := -1
	var best := 40.0
	var keys: Array = camps.keys()
	keys.sort()
	for c in keys:
		var camp: Dictionary = camps[c]
		if int(camp["level"]) <= 2 + int(s["wave"]) / 2 and float(camp["hp"]) < power * 0.55 and float(camp["dist"]) < best:
			best = float(camp["dist"])
			pick = int(camp["unit"])
	if pick < 0:
		s["next_creep"] = sim.tick + 300
		return false
	var free := _free_units()
	if free.size() < 4:
		return false
	_cmd({"type": "attack", "units": free, "target": pick})
	s["next_creep"] = sim.tick + 150
	return true


# ---------- покупка предметов героям ----------

## Пока армия собирается у базы и есть лишнее золото, герой ходит в лавку за предметами.
func _shopping() -> void:
	if String(s["state"]) != "gather" or sim.tick < int(s.get("next_shop", 600)):
		return
	s["next_shop"] = sim.tick + 80
	var items: Dictionary = sim.players[Sim.NEUTRAL]["data"].get("items", {})
	var shop_id := -1
	var best := 34.0
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		if String(b["def"].get("role", "")) == "shop" and (b["pos"] as Vector2).distance_to(_base) < best:
			best = (b["pos"] as Vector2).distance_to(_base)
			shop_id = int(id)
	if shop_id < 0 or items.is_empty() or not _foes_near(sim.buildings[shop_id]["pos"], 10.0).is_empty():
		return
	for hid in _army:
		var h: Dictionary = sim.units[hid]
		if not h["hero"] or (h["items"] as Array).size() >= Sim.MAX_ITEMS:
			continue
		var wish: Array = ["belt", "plate", "blade", "ring", "axe", "fang"] if float(h["range"]) < 2.0 else ["amulet", "belt", "boots", "ring", "staff", "cloak"]
		for key in wish:
			if (h["items"] as Array).has(key) or not items.has(key):
				continue
			if not _afford({"gold": int(items[key]["cost"]["gold"]) + 250, "wood": 0}):
				return      # копим: на предмет и ещё запас на войска
			if (h["pos"] as Vector2).distance_to(sim.buildings[shop_id]["pos"]) <= Sim.SHOP_RANGE - 1.0:
				_cmd({"type": "buy", "unit": hid, "shop": shop_id, "item": key})
			elif String(h["order"].get("type", "idle")) in ["idle", "move"]:
				_cmd({"type": "move", "units": [hid], "target": (sim.buildings[shop_id]["pos"] as Vector2) + (_base - (sim.buildings[shop_id]["pos"] as Vector2)).normalized() * 3.0})
				s["next_order"] = maxi(int(s["next_order"]), sim.tick + 60)     # не тянуть героя обратно сразу
			return


# ---------- заклинания героев ----------

func _spells() -> void:
	for hid in _army:
		var h: Dictionary = sim.units[hid]
		if not h["hero"] or String(h["order"].get("type")) == "cast":
			continue
		var foes := _foes_near(h["pos"], 9.0)
		for ab in h["def"].get("abilities", []):
			if String(ab["type"]) != "active" or sim.rank(h, String(ab["key"])) <= 0 or float(h["mana"]) < float(ab["mana"]) or sim.tick < int(h["cds"].get(ab["key"], 0)):
				continue
			var e: Dictionary = ab["effect"]
			var cmd := {"type": "cast", "unit": hid, "ability": ab["key"]}
			match String(e["kind"]):
				"blink":
					continue
				"chain":
					if foes.is_empty():
						continue
					cmd["target"] = _toughest(foes)
				"leap":
					var landing := -1
					for fid in foes:
						if _foes_near(sim.units[fid]["pos"], float(e["radius"])).size() >= 2:
							landing = fid
							break
					if landing < 0:
						continue
					cmd["pos"] = sim.units[landing]["pos"]
				"heal":
					var hurt := _weakest_ally(h["pos"], float(ab["range"]) + 2.0, 0.55)
					if hurt < 0:
						continue
					cmd["target"] = hurt
				"area_heal":
					if _weakest_ally(h["pos"], float(e["radius"]), 0.6) < 0:
						continue
				"bolt", "smite":
					if foes.is_empty():
						continue
					cmd["target"] = _toughest(foes)
				"area_damage":
					var radius: float = float(e["radius"])
					if String(e.get("center", "self")) == "self":
						if _foes_near(h["pos"], radius).size() < 2:
							continue
					else:
						var spot := -1
						for fid in foes:
							if _foes_near(sim.units[fid]["pos"], radius).size() >= 2:
								spot = fid
								break
						if spot < 0:
							continue
						cmd["pos"] = sim.units[spot]["pos"]
				"buff":
					if foes.is_empty():
						continue
					if String(e.get("who")) == "area_enemies":
						cmd["pos"] = sim.units[foes[0]]["pos"]
					elif String(e.get("who")) == "self" and float(e["mods"].get("damage_taken_mul", 1.0)) < 1.0 and float(h["hp"]) > float(h["max_hp"]) * 0.4:
						continue      # щит — только когда герою уже тяжело
					if String(e.get("who")) == "target":
						var ally := _fighting_ally(h["pos"], float(ab["range"]), String(ab["key"]))
						if ally < 0:
							continue
						cmd["target"] = ally
				"summon":
					if foes.is_empty():
						continue
			_cmd(cmd)
			return     # одно заклинание за раз


func _weakest_ally(pos: Vector2, radius: float, below: float) -> int:
	var best := -1
	var worst := below
	for id in _army:
		var u: Dictionary = sim.units[id]
		var ratio: float = float(u["hp"]) / float(u["max_hp"])
		if ratio < worst and (u["pos"] as Vector2).distance_to(pos) <= radius:
			worst = ratio
			best = id
	return best


func _toughest(ids: Array) -> int:
	var best: int = ids[0]
	for id in ids:
		if float(sim.units[id]["hp"]) > float(sim.units[best]["hp"]):
			best = id
	return best


func _fighting_ally(pos: Vector2, radius: float, buff_key: String) -> int:
	var best := -1
	var top := 0.0
	for id in _army:
		var u: Dictionary = sim.units[id]
		if String(u["order"].get("type")) != "attack" or (u["pos"] as Vector2).distance_to(pos) > radius:
			continue
		var has := false
		for b in u["buffs"]:
			if String(b["key"]) == buff_key:
				has = true
		if not has and float(u["damage"]) > top:
			top = float(u["damage"])
			best = id
	return best
