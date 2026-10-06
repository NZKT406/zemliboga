extends Node
## Сетевая игра по локальной сети или через Radmin VPN (прямое подключение, ENet).
## Один и тот же скрипт бывает в трёх ролях:
##  • хозяин игры — игрок, нажавший «Создать игру»: держит аккаунты, комнату и пересылку команд
##    и при этом сам играет (его «запросы к серверу» просто выполняются у него же);
##  • клиент — игрок, подключившийся по адресу хозяина (например, 26.x.x.x в Radmin VPN);
##  • выделенный сервер без игрока (SERVER.bat) — то же, что хозяин, но сам не играет.
## Сама игра считается у каждого игрока; по сети ходят только команды. Хозяин собирает
## команды всех игроков на тик, подписывает их номером игрока и рассылает всем.

signal auth_changed            # вошли, вышли или сменили ник
signal rooms_changed           # пришёл список комнат
signal room_changed            # изменилась текущая комната
signal game_started(info)      # хозяин начал игру: {seed, size, players, index}
signal note(text)              # сообщение для игрока
signal player_left(index)
signal desynced(tick)
signal connection_lost
signal chat(index, nick, text, allies_only)   # index — номер игрока в партии (-1 в комнате до начала)
signal pinged(index, pos)                     # союзник отметил точку на карте

const DEFAULT_PORT := 24600
const VERSION := "этап 25"        # меняется с каждым обновлением игры: разные версии вместе не играют
const ACCOUNTS := "user://accounts.json"
const MAX_SLOTS := 8
const MAX_TEAMS := 4
const HASH_ROUNDS := 2000

var is_server := false            # этот компьютер держит игру (хозяин или выделенный сервер)
var plays := false                # ...и сам в ней играет (хозяин)
var connected: bool:              # можно ли сейчас пользоваться сетевой игрой
	get:
		if plays:
			return true
		var p := multiplayer.multiplayer_peer if is_inside_tree() else null
		return p != null and not is_server and not (p is OfflineMultiplayerPeer) and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

# --- игрок ---
var profile: Dictionary = {}       # {login, nick, wins, losses}
var rooms: Array = []
var room: Dictionary = {}
var my_index := -1
var turns: Dictionary = {}         # тик -> команды всех игроков на этот тик

# --- тот, кто держит игру ---
var _accounts: Dictionary = {}     # login -> {salt, hash, nick, wins, losses}
var _sessions: Dictionary = {}     # peer -> login
var _rooms: Dictionary = {}        # id -> комната
var _room_of: Dictionary = {}      # peer -> id комнаты
var _verified: Dictionary = {}     # peer -> true: версия игры совпала, можно входить
var _accepted := false             # у игрока: хозяин подтвердил нашу версию
var _waiting: Array = []           # вход и регистрация, ждущие подтверждения версии
var _next_room := 1


func _ready() -> void:
	var ver := preload("res://scripts/net_version.gd").new()      # сверка версий игры у всех игроков
	ver.name = "NetVersion"
	ver.version = VERSION
	for a in OS.get_cmdline_user_args():      # для проверки: --netver=… изображает другую версию
		if a.begins_with("--netver="):
			ver.version = a.trim_prefix("--netver=")
	ver.mismatch.connect(func(host_version: String) -> void:
		note.emit("У хозяина другая версия игры (%s, у вас %s). Все игроки должны играть одной и той же копией игры — обновите её." % [host_version, ver.version]))
	ver.verified.connect(func(peer: int) -> void: _verified[peer] = true)
	ver.accepted.connect(func() -> void:      # версия подтверждена: отправляем отложенный вход
		_accepted = true
		for call in _waiting:
			_srv(call[0], call[1])
		_waiting.clear())
	get_tree().root.add_child.call_deferred(ver)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func() -> void:
		var v := get_tree().root.get_node_or_null("NetVersion")
		if v != null:
			v.check()
		note.emit("Соединение с хозяином игры установлено"))
	multiplayer.connection_failed.connect(func() -> void:
		note.emit("Не удалось подключиться. Проверьте адрес и что игра создана."))
	multiplayer.server_disconnected.connect(func() -> void:
		profile = {}
		room = {}
		connection_lost.emit())


## Запрос «серверу»: у хозяина выполняется сразу у себя, у остальных уходит по сети хозяину.
func _srv(method: String, args: Array = []) -> void:
	if is_server:
		callv(method, args)
	else:
		callv("rpc_id", [1, method] + args)


## Ответ конкретному игроку: если это сам хозяин — выполняется у него же
## (отложенно, на следующем кадре, как будто пришло по сети: так кнопка меню
## не удаляется посреди собственного нажатия).
func _to(peer: int, method: String, args: Array = []) -> void:
	if peer == multiplayer.get_unique_id():
		callv("call_deferred", [method] + args)
	else:
		callv("rpc_id", [peer, method] + args)


## Кто прислал запрос (у хозяина «сам себе» — его собственный номер).
func _sender() -> int:
	var s := multiplayer.get_remote_sender_id()
	return s if s != 0 else multiplayer.get_unique_id()


# =====================================================================
#  ТОТ, КТО ДЕРЖИТ ИГРУ (хозяин или выделенный сервер)
# =====================================================================

## Выделенный сервер без игрока (SERVER.bat).
func start_server(port: int = DEFAULT_PORT) -> int:
	return _listen(port, false)


## «Создать игру»: этот игрок держит игру и сам в ней участвует.
func host(port: int = DEFAULT_PORT) -> int:
	return _listen(port, true)


func _listen(port: int, player: bool) -> int:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 32)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	plays = player
	_load_accounts()
	print("SERVER: слушаю порт %d, аккаунтов: %d%s" % [port, _accounts.size(), " (хозяин играет)" if player else ""])
	return OK


func _load_accounts() -> void:
	_accounts = {}
	if FileAccess.file_exists(ACCOUNTS):
		var data = JSON.parse_string(FileAccess.get_file_as_string(ACCOUNTS))
		if data is Dictionary:
			_accounts = data


func _save_accounts() -> void:
	var f := FileAccess.open(ACCOUNTS, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_accounts, "\t"))


## Пароль хранится только как многократный SHA-256 от «соль + пароль».
static func _hash(salt: String, password: String) -> String:
	var data := (salt + password).to_utf8_buffer()
	for i in HASH_ROUNDS:
		var h := HashingContext.new()
		h.start(HashingContext.HASH_SHA256)
		h.update(data)
		data = h.finish()
	return data.hex_encode()


static func _salt() -> String:
	var c := Crypto.new()
	return c.generate_random_bytes(16).hex_encode()


func _profile_of(login: String) -> Dictionary:
	var a: Dictionary = _accounts[login]
	return {"login": login, "nick": a["nick"], "wins": int(a.get("wins", 0)), "losses": int(a.get("losses", 0))}


func _on_peer_connected(id: int) -> void:
	if is_server:
		print("SERVER: подключился %d" % id)


func _on_peer_disconnected(id: int) -> void:
	if not is_server:
		return
	print("SERVER: отключился %d" % id)
	_leave_room(id)
	_sessions.erase(id)
	_verified.erase(id)


## Входить можно только с той же версией игры, что у хозяина (сам хозяин — всегда).
func _version_ok(id: int) -> bool:
	if id == multiplayer.get_unique_id() or _verified.has(id):
		return true
	_to(id, "_cl_auth", [false, "Версия игры не совпадает с версией хозяина — обновите игру", {}])
	return false


@rpc("any_peer", "call_remote", "reliable")
func _sv_register(login: String, password: String) -> void:
	if not is_server or not _version_ok(_sender()):
		return
	var id := _sender()
	login = login.strip_edges().to_lower()
	var re := RegEx.create_from_string("^[a-z0-9_]{3,16}$")
	if re.search(login) == null:
		_to(id, "_cl_auth", [false, "Логин: 3–16 латинских букв, цифр или «_»", {}])
	elif password.length() < 4:
		_to(id, "_cl_auth", [false, "Пароль должен быть не короче 4 символов", {}])
	elif _accounts.has(login):
		_to(id, "_cl_auth", [false, "Такой логин уже занят", {}])
	else:
		var salt := _salt()
		_accounts[login] = {"salt": salt, "hash": _hash(salt, password), "nick": login, "wins": 0, "losses": 0}
		_save_accounts()
		_sessions[id] = login
		_to(id, "_cl_auth", [true, "Аккаунт создан", _profile_of(login)])


@rpc("any_peer", "call_remote", "reliable")
func _sv_login(login: String, password: String) -> void:
	if not is_server or not _version_ok(_sender()):
		return
	var id := _sender()
	login = login.strip_edges().to_lower()
	if not _accounts.has(login) or _hash(String(_accounts[login]["salt"]), password) != String(_accounts[login]["hash"]):
		_to(id, "_cl_auth", [false, "Неверный логин или пароль", {}])
		return
	for other in _sessions.keys():      # вход с другого места выкидывает прошлую сессию
		if String(_sessions[other]) == login and int(other) != id:
			_leave_room(int(other))
			_sessions.erase(other)
			if int(other) != multiplayer.get_unique_id():
				(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(int(other))
	_sessions[id] = login
	_to(id, "_cl_auth", [true, "Вход выполнен", _profile_of(login)])


@rpc("any_peer", "call_remote", "reliable")
func _sv_nick(nick: String) -> void:
	if not is_server or not _sessions.has(_sender()):
		return
	var id := _sender()
	nick = nick.strip_edges()
	if nick.length() < 2 or nick.length() > 20:
		_to(id, "_cl_note", ["Ник: от 2 до 20 символов"])
		return
	var login: String = _sessions[id]
	_accounts[login]["nick"] = nick
	_save_accounts()
	_to(id, "_cl_auth", [true, "Ник изменён", _profile_of(login)])
	if _room_of.has(id):
		var r: Dictionary = _rooms[_room_of[id]]
		for s in r["slots"]:
			if int(s.get("peer", 0)) == id:
				s["nick"] = nick
		_send_room(r)


@rpc("any_peer", "call_remote", "reliable")
func _sv_list() -> void:
	if not is_server or not _sessions.has(_sender()):
		return
	var out: Array = []
	for rid in _rooms:
		var r: Dictionary = _rooms[rid]
		var used := 0
		for s in r["slots"]:
			if String(s["kind"]) != "open" and String(s["kind"]) != "closed":
				used += 1
		out.append({"id": rid, "name": r["name"], "size": r["size"], "used": used, "slots": (r["slots"] as Array).size(), "started": r["started"]})
	_to(_sender(), "_cl_rooms", [out])


@rpc("any_peer", "call_remote", "reliable")
func _sv_create(room_name: String, size: int, slots: int) -> void:
	var id := _sender()
	if not is_server or not _sessions.has(id) or _room_of.has(id):
		return
	slots = clampi(slots, 2, MAX_SLOTS)
	var r := {"id": _next_room, "name": room_name.strip_edges().left(30) if room_name.strip_edges() != "" else "Игра %s" % _accounts[_sessions[id]]["nick"],
		"size": size if size in [96, 192, 272] else 96, "host": id, "started": false, "slots": [], "turns": {}, "sums": {}, "fog": true}
	_next_room += 1
	for i in slots:
		r["slots"].append({"kind": "open", "team": 0})
	r["slots"][0] = _human(id, 0)
	_rooms[r["id"]] = r
	_room_of[id] = r["id"]
	_send_room(r)


func _human(id: int, team: int) -> Dictionary:
	return {"kind": "human", "peer": id, "nick": _accounts[_sessions[id]]["nick"], "race": "humans", "team": team}


@rpc("any_peer", "call_remote", "reliable")
func _sv_join(room_id: int) -> void:
	var id := _sender()
	if not is_server or not _sessions.has(id) or _room_of.has(id) or not _rooms.has(room_id):
		return
	var r: Dictionary = _rooms[room_id]
	if r["started"]:
		_to(id, "_cl_note", ["Игра в этой комнате уже идёт"])
		return
	for i in (r["slots"] as Array).size():
		if String(r["slots"][i]["kind"]) == "open":
			r["slots"][i] = _human(id, int(r["slots"][i].get("team", 0)))
			_room_of[id] = room_id
			_send_room(r)
			return
	_to(id, "_cl_note", ["В комнате нет свободных мест"])


@rpc("any_peer", "call_remote", "reliable")
func _sv_leave() -> void:
	if is_server:
		_leave_room(_sender())


## Место в комнате. Хозяин меняет пустые места (открыто / компьютер / закрыто), расы компьютеров
## и команды всех; игрок — свою расу и команду. team 0 — «сам за себя», 1…4 — команды.
@rpc("any_peer", "call_remote", "reliable")
func _sv_slot(index: int, kind: String, race: String, diff: String, team: int) -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if r["started"] or index < 0 or index >= (r["slots"] as Array).size():
		return
	var host_me: bool = int(r["host"]) == id
	team = clampi(team, 0, MAX_TEAMS)
	var s: Dictionary = r["slots"][index]
	if String(s["kind"]) == "human":
		if int(s["peer"]) == id or host_me:
			s["race"] = race
			s["team"] = team
	elif host_me and kind in ["open", "ai", "closed"]:
		if kind == "ai":
			r["slots"][index] = {"kind": "ai", "race": race, "nick": "Компьютер", "diff": diff if diff in ["easy", "normal", "hard"] else "normal", "team": team}
		else:
			r["slots"][index] = {"kind": kind, "team": team}
	_send_room(r)


## Игрок пересаживается на свободное место (например, ближе к своей команде).
@rpc("any_peer", "call_remote", "reliable")
func _sv_move(index: int) -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if r["started"] or index < 0 or index >= (r["slots"] as Array).size() or String(r["slots"][index]["kind"]) != "open":
		return
	for i in (r["slots"] as Array).size():
		if int(r["slots"][i].get("peer", 0)) == id:
			var me: Dictionary = r["slots"][i]
			r["slots"][i] = {"kind": "open", "team": int(r["slots"][index].get("team", 0))}
			me["team"] = int(r["slots"][index].get("team", me.get("team", 0)))
			r["slots"][index] = me
			break
	_send_room(r)


## Хозяин выгоняет игрока из комнаты (не из игры: на сервере он остаётся и может зайти снова).
@rpc("any_peer", "call_remote", "reliable")
func _sv_kick(index: int) -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if int(r["host"]) != id or r["started"] or index < 0 or index >= (r["slots"] as Array).size():
		return
	var s: Dictionary = r["slots"][index]
	if String(s["kind"]) != "human" or int(s["peer"]) == id:
		return
	var who := int(s["peer"])
	r["slots"][index] = {"kind": "open", "team": int(s.get("team", 0))}
	_room_of.erase(who)
	_to(who, "_cl_room", [{}])
	_to(who, "_cl_note", ["Хозяин убрал вас из комнаты"])
	_send_room(r)


## Сколько сторон в бою: каждая команда — одна сторона, каждый «сам за себя» — отдельная.
static func sides(players: Array) -> int:
	var seen: Dictionary = {}
	var solo := 0
	for p in players:
		if int(p.get("team", 0)) == 0:
			solo += 1
		else:
			seen[int(p["team"])] = true
	return solo + seen.size()


@rpc("any_peer", "call_remote", "reliable")
func _sv_start() -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if int(r["host"]) != id or r["started"]:
		return
	var players: Array = []
	for s in r["slots"]:
		if String(s["kind"]) in ["human", "ai"]:
			players.append(s)
	if players.size() < 2:
		_to(id, "_cl_note", ["Нужно хотя бы два игрока (можно с компьютером)"])
		return
	if sides(players) < 2:
		_to(id, "_cl_note", ["Все в одной команде — не с кем сражаться. Разделите игроков на команды."])
		return
	r["started"] = true
	r["players"] = players
	var seed_value := randi() % 1000000
	var info: Array = []
	for i in players.size():
		var p: Dictionary = players[i]
		p["index"] = i
		p["left"] = false
		info.append({"kind": p["kind"], "race": p["race"], "nick": p["nick"], "diff": p.get("diff", "normal"), "team": int(p.get("team", 0))})
	for i in players.size():
		if String(players[i]["kind"]) == "human":
			_to(int(players[i]["peer"]), "_cl_start", [seed_value, int(r["size"]), info, i, {"fog": bool(r.get("fog", true)), "biome": String(r.get("biome", "any"))}])


## Настройки комнаты, которые меняет только её хозяин (сейчас — туман войны).
const BIOME_KEYS := ["any", "meadow", "steppe", "autumn", "winter", "lakes", "highlands"]


@rpc("any_peer", "call_remote", "reliable")
func _sv_option(key: String, value) -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if int(r["host"]) != id or r["started"]:
		return
	if key == "fog" and value is bool:
		r[key] = value
	elif key == "biome" and String(value) in BIOME_KEYS:
		r[key] = String(value)
	else:
		return
	_send_room(r)


## Сообщение в чат: всем в комнате или только своей команде.
@rpc("any_peer", "call_remote", "reliable")
func _sv_chat(text: String, allies_only: bool) -> void:
	var id := _sender()
	text = text.strip_edges().left(200)
	if not is_server or not _room_of.has(id) or not _sessions.has(id) or text == "":
		return
	var r: Dictionary = _rooms[_room_of[id]]
	var index := _index_of(r, id) if r["started"] else -1
	var team := _team_of_peer(r, id)
	for peer in _room_peers(r):
		if not allies_only or peer == id or (team > 0 and _team_of_peer(r, peer) == team):
			_to(peer, "_cl_chat", [index, String(_accounts[_sessions[id]]["nick"]), text, allies_only])


## Сигнал на карте: видят только союзники (и сам игрок).
@rpc("any_peer", "call_remote", "reliable")
func _sv_ping(pos: Vector2) -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if not r["started"]:
		return
	var team := _team_of_peer(r, id)
	for peer in _room_peers(r):
		if peer == id or (team > 0 and _team_of_peer(r, peer) == team):
			_to(peer, "_cl_ping", [_index_of(r, id), pos])


## Люди, которые сейчас в комнате (или в её партии и ещё не ушли).
func _room_peers(r: Dictionary) -> Array:
	var out: Array = []
	for s in (r.get("players", []) if r["started"] else r["slots"]):
		if String(s["kind"]) == "human" and not s.get("left", false):
			out.append(int(s["peer"]))
	return out


func _team_of_peer(r: Dictionary, peer: int) -> int:
	for s in (r.get("players", []) if r["started"] else r["slots"]):
		if String(s["kind"]) == "human" and int(s.get("peer", 0)) == peer:
			return int(s.get("team", 0))
	return 0


## Команды игрока на тик. Сервер подписывает их номером игрока (чужими юнитами командовать нельзя)
## и, когда пришли команды от всех живых игроков, рассылает их всем вместе.
@rpc("any_peer", "call_remote", "reliable")
func _sv_turn(at_tick: int, cmds: Array) -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if not r["started"]:
		return
	var index := _index_of(r, id)
	if index < 0:
		return
	for c in cmds:
		if c is Dictionary:
			c["player"] = index
	if not r["turns"].has(at_tick):
		r["turns"][at_tick] = {}
	r["turns"][at_tick][index] = cmds
	_flush_turns(r)


func _index_of(r: Dictionary, peer: int) -> int:
	for p in r.get("players", []):
		if String(p["kind"]) == "human" and int(p.get("peer", 0)) == peer:
			return int(p["index"])
	return -1


func _flush_turns(r: Dictionary) -> void:
	var ticks: Array = r["turns"].keys()
	ticks.sort()
	for t in ticks:
		var got: Dictionary = r["turns"][t]
		var complete := true
		for p in r["players"]:
			if String(p["kind"]) == "human" and not p["left"] and not got.has(int(p["index"])):
				complete = false
		if not complete:
			return      # тики идут по порядку: дальше ждать тоже нечего
		var merged: Array = []
		var idx: Array = got.keys()
		idx.sort()
		for i in idx:
			merged.append_array(got[i])
		for p in r["players"]:
			if String(p["kind"]) == "human" and not p["left"]:
				_to(int(p["peer"]), "_cl_turn", [int(t), merged])
		r["turns"].erase(t)


@rpc("any_peer", "call_remote", "reliable")
func _sv_sum(at_tick: int, value: int) -> void:
	var id := _sender()
	if not is_server or not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	if not r["sums"].has(at_tick):
		r["sums"][at_tick] = value
	elif int(r["sums"][at_tick]) != value:
		for p in r.get("players", []):
			if String(p["kind"]) == "human" and not p["left"]:
				_to(int(p["peer"]), "_cl_desync", [at_tick])
	r["sums"].erase(at_tick - 500)


## Итог партии: в профиль игрока записывается победа или поражение.
@rpc("any_peer", "call_remote", "reliable")
func _sv_result(won: bool) -> void:
	var id := _sender()
	if not is_server or not _sessions.has(id):
		return
	var a: Dictionary = _accounts[_sessions[id]]
	a["wins" if won else "losses"] = int(a.get("wins" if won else "losses", 0)) + 1
	_save_accounts()
	_to(id, "_cl_auth", [true, "", _profile_of(_sessions[id])])


func _leave_room(id: int) -> void:
	if not _room_of.has(id):
		return
	var r: Dictionary = _rooms[_room_of[id]]
	_room_of.erase(id)
	if r["started"]:
		var index := _index_of(r, id)
		for p in r["players"]:
			if int(p.get("index", -1)) == index:
				p["left"] = true
		var anyone := false
		for p in r["players"]:
			if String(p["kind"]) == "human" and not p["left"]:
				anyone = true
				_to(int(p["peer"]), "_cl_left", [index])
		if not anyone:
			_rooms.erase(r["id"])
		else:
			_flush_turns(r)      # больше не ждём команд от ушедшего
		return
	for i in (r["slots"] as Array).size():
		if int(r["slots"][i].get("peer", 0)) == id:
			r["slots"][i] = {"kind": "open", "team": int(r["slots"][i].get("team", 0))}
	if int(r["host"]) == id:      # хозяин комнаты ушёл до начала — комната закрывается
		for s in r["slots"]:
			if String(s["kind"]) == "human":
				_room_of.erase(int(s["peer"]))
				_to(int(s["peer"]), "_cl_room", [{}])
				_to(int(s["peer"]), "_cl_note", ["Хозяин закрыл комнату"])
		_rooms.erase(r["id"])
	else:
		_send_room(r)


func _send_room(r: Dictionary) -> void:
	var view := {"id": r["id"], "name": r["name"], "size": r["size"], "host": r["host"], "slots": r["slots"].duplicate(true), "started": r["started"], "fog": bool(r.get("fog", true)), "biome": String(r.get("biome", "any"))}
	for s in r["slots"]:
		if String(s["kind"]) == "human":
			_to(int(s["peer"]), "_cl_room", [view])


# =====================================================================
#  ИГРОК
# =====================================================================

## Подключиться к хозяину игры по адресу (например, 26.12.34.56 в Radmin VPN или 192.168.1.5).
func connect_to(address: String, port: int = DEFAULT_PORT) -> int:
	close()
	address = address.strip_edges()
	if address.contains(":"):      # можно ввести и «адрес:порт»
		port = int(address.get_slice(":", 1))
		address = address.get_slice(":", 0)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err == OK:
		multiplayer.multiplayer_peer = peer
	return err


func close() -> void:
	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	plays = false
	profile = {}
	room = {}
	rooms = []
	turns.clear()
	_sessions.clear()
	_rooms.clear()
	_room_of.clear()
	_verified.clear()
	_accepted = false
	_waiting.clear()


func register(login_name: String, password: String) -> void:
	_auth_call("_sv_register", [login_name, password])


func login(login_name: String, password: String) -> void:
	_auth_call("_sv_login", [login_name, password])


func _auth_call(method: String, args: Array) -> void:
	if is_server or _accepted:
		_srv(method, args)
	else:
		_waiting = [[method, args]]      # уйдёт, как только хозяин подтвердит версию


func set_nick(nick: String) -> void:
	_srv("_sv_nick", [nick])


func refresh_rooms() -> void:
	_srv("_sv_list")


func create_room(room_name: String, size: int, slots: int) -> void:
	_srv("_sv_create", [room_name, size, slots])


func join_room(room_id: int) -> void:
	_srv("_sv_join", [room_id])


func leave_room() -> void:
	if connected:
		_srv("_sv_leave")
	room = {}
	room_changed.emit()


func set_slot(index: int, kind: String, race: String, diff: String = "normal", team: int = 0) -> void:
	_srv("_sv_slot", [index, kind, race, diff, team])


func move_to(index: int) -> void:
	_srv("_sv_move", [index])


func kick(index: int) -> void:
	_srv("_sv_kick", [index])


func start_game() -> void:
	_srv("_sv_start")


func set_option(key: String, value) -> void:
	_srv("_sv_option", [key, value])


func send_chat(text: String, allies_only: bool) -> void:
	if connected and not room.is_empty():
		_srv("_sv_chat", [text, allies_only])


func send_ping(pos: Vector2) -> void:
	if connected and not room.is_empty():
		_srv("_sv_ping", [pos])


func send_turn(at_tick: int, cmds: Array) -> void:
	_srv("_sv_turn", [at_tick, cmds.duplicate(true)])


func send_sum(at_tick: int, value: int) -> void:
	_srv("_sv_sum", [at_tick, value])


func send_result(won: bool) -> void:
	if connected:
		_srv("_sv_result", [won])


func is_host() -> bool:
	return not room.is_empty() and int(room.get("host", -1)) == multiplayer.get_unique_id()


@rpc("authority", "call_remote", "reliable")
func _cl_auth(ok: bool, text: String, prof: Dictionary) -> void:
	if ok:
		profile = prof
	if text != "":
		note.emit(text)
	auth_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _cl_note(text: String) -> void:
	note.emit(text)


@rpc("authority", "call_remote", "reliable")
func _cl_rooms(list: Array) -> void:
	rooms = list
	rooms_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _cl_room(state: Dictionary) -> void:
	room = state
	room_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _cl_start(seed_value: int, size: int, players: Array, index: int, opts: Dictionary) -> void:
	my_index = index
	turns.clear()
	game_started.emit({"seed": seed_value, "size": size, "players": players, "index": index, "fog": bool(opts.get("fog", true)), "biome": String(opts.get("biome", "any"))})


@rpc("authority", "call_remote", "reliable")
func _cl_chat(index: int, nick: String, text: String, allies_only: bool) -> void:
	chat.emit(index, nick, text, allies_only)


@rpc("authority", "call_remote", "reliable")
func _cl_ping(index: int, pos: Vector2) -> void:
	pinged.emit(index, pos)


@rpc("authority", "call_remote", "reliable")
func _cl_turn(at_tick: int, cmds: Array) -> void:
	turns[at_tick] = cmds


@rpc("authority", "call_remote", "reliable")
func _cl_left(index: int) -> void:
	player_left.emit(index)


@rpc("authority", "call_remote", "reliable")
func _cl_desync(at_tick: int) -> void:
	desynced.emit(at_tick)
