extends Node3D
## Всё, что видит и нажимает игрок: меню, камера, выделение, приказы, интерфейс.
## Сама игра считается в Sim (scripts/sim.gd); здесь её только показывают.

const Sim = preload("res://scripts/sim.gd")
const Models = preload("res://scripts/models.gd")
const Terrain = preload("res://scripts/terrain.gd")
const MapGen = preload("res://scripts/mapgen.gd")
const Anim = preload("res://scripts/anim.gd")
const Icons = preload("res://scripts/icons.gd")
const Backdrop = preload("res://scripts/backdrop.gd")
const AI = preload("res://scripts/ai.gd")
const Audio = preload("res://scripts/audio.gd")
const W = preload("res://scripts/widgets.gd")
const Online = preload("res://scripts/online.gd")
const Fog = preload("res://scripts/fog.gd")
## Цвета игроков 1…8 (у каждого свой, как в классических стратегиях) и серый — нейтралы.
const TEAM_COLORS := [Color("#1450e6"), Color("#e0200e"), Color("#18b8a8"), Color("#7a2ad0"), Color("#e8d020"), Color("#f07818"), Color("#30b030"), Color("#e060b0")]
const NEUTRAL_COLOR := Color("#8a8072")
const SIDE_COLORS := [Color("#d8d8d8"), Color("#ff9a6a"), Color("#6ab8ff"), Color("#8ae08a"), Color("#e0a8ff")]   # «сам за себя», команды 1…4
const SAVE_SLOTS := 3
const SAVE_VERSION := 6
const SETTINGS_PATH := "user://settings.cfg"
const DIFFICULTY := {"easy": "Лёгкий", "normal": "Обычный", "hard": "Тяжёлый"}
const DIFFICULTY_NOTE := {
	"easy": "Нападает через 7 минут малыми отрядами, не строит башен, не колдует.",
	"normal": "Нападает через 4 минуты, волны растут, герои применяют заклинания.",
	"hard": "Нападает через 3 минуты большими волнами и получает на 20% больше ресурсов.",
}
const PAN_SPEED := 28.0
const EDGE := 12.0
const DAMAGE_NAMES := {"normal": "обычный", "pierce": "колющий", "siege": "осадный", "magic": "магический", "holy": "святой", "chaos": "хаос"}
const ARMOR_NAMES := {"light": "лёгкая", "medium": "средняя", "heavy": "тяжёлая", "fortified": "укреплённая", "unarmored": "без брони", "hero": "геройская"}
const CONTROLS_MORE := "\nДвойной щелчок — все такие же юниты на экране\nCtrl+1…9 — запомнить отряд,  1…9 — выбрать (дважды — камера к нему)\nX — всё войско,  Z — рабочий без дела,  Пробел — камера на базу\nПКМ при выбранном здании — точка сбора новых юнитов\n+ / − — скорость одиночной игры,  F6 — союзники и передача ресурсов\nAlt+ЛКМ — сигнал союзникам,  Enter — чат союзникам (Shift+Enter — всем)"
const CONTROLS := "ЛКМ — выбрать юнита или здание (потянуть — рамка, Shift — добавить)\nПКМ — идти / атаковать / добывать / достраивать\nCtrl+ПКМ — идти с боем\nQ, E, R, T, F — кнопки панели справа внизу\nH — стоп,  Esc — отмена и снять выделение\nWASD, стрелки, край экрана — камера,  колёсико — масштаб\nF10 — это меню"

var races: Dictionary = {}
var neutral: Dictionary = {}
var combat: Dictionary = {}
var sim: Sim
var terrain: Terrain
var ais: Array = []               # компьютерные противники
var local_player := 0
var difficulty := "normal"
var enemy_choice := "random"      # раса противников или "random"
var opponents := 1                # сколько компьютеров в одиночной игре (союзники + противники)
var allies := 0                   # сколько из них — ваши союзники
var foes_together := false        # противники — одна команда (иначе каждый сам за себя)
var player_names: Array = []      # имена игроков по номерам
var online: Node                  # сетевая часть (scripts/online.gd)
var _page := ""                   # открытая страница меню
var map_choice := 96              # сторона карты: 96, 192 (×4) или 272 (×8)
var selected: Array = []          # выбранные свои юниты
var sel_building := -1            # или одно выбранное здание
var inspect := -1                 # или чужой юнит, которого просто рассматривают
var views: Dictionary = {}        # id юнита -> {node, parts, ring, ...}
var bviews: Dictionary = {}       # id здания -> Node3D
var rviews: Dictionary = {}       # id ресурса -> Node3D
var pviews: Dictionary = {}       # id снаряда -> Node3D
var corpses: Array = []           # погибшие юниты, доигрывающие анимацию
var floaters: Array = []          # всплывающие надписи «+30»

var _acc := 0.0
var _time := 0.0
var _paused := false
var _rig: Node3D
var _cam: Camera3D
var _zoom := 19.0
var _ui: CanvasLayer
var _menu: Control
var _menu_box: VBoxContainer
var _backdrop: Node3D
var _pause: Control
var _pause_note: Label
var _controls: Label
var _res: Label
var _fps: Label                   # счётчик кадров в секунду (правый верхний угол)
var _fps_time := 0.0
var _msg: Label
var _msg_time := 0.0
var _hint: Label
var _banner: Label
var _bars: Control
var _stats: PanelContainer
var _stat_name: Label
var _stat_extra: Label
var _hp_bar: W.Bar
var _mana_bar: W.Bar
var _xp_bar: W.Bar
var _chips: HBoxContainer          # характеристики иконками: урон, скорость атаки, броня...
var _effects: HBoxContainer        # эффекты на юните с анимацией оставшегося времени
var _effects_key := ""
var _queue: HBoxContainer          # заказы здания с крестиками отмены
var _queue_key := ""
var _bag: GridContainer            # сумка героя
var _bag_hero := -1
var _item_menu: PopupMenu
var _menu_slot := -1
var _portrait: TextureRect
var _lookup: Dictionary = {}       # ключ способности или предмета -> {name, icon, color}
var lviews: Dictionary = {}        # id предмета на земле -> Node3D
var _card: GridContainer
var _card_panel: PanelContainer
var _card_key := ""
var _card_items: Array = []       # [{hotkey, action, button, cd, ability}]
var _tip: Label
var _tip_panel: PanelContainer
var _icons: Dictionary = {}
var _box: Panel
var _mini: Control
var _mini_top: Control             # слой мини-карты поверх тумана
var _idle_btn: Button
var _rally_mark: Node3D
var _double := false
# --- сетевая игра ---
const NET_DELAY := 3              # на сколько тиков вперёд назначаются команды (0,3 с)
var net_mode := ""                # "", "host" или "client"
var _outbox: Array = []           # мои команды, ещё не отправленные
var _local_turns: Dictionary = {} # тик -> мои команды
var _sums: Dictionary = {}
var _net_status: Label
var _net_lost := false
var audio: Node
var _alert_time := -100.0
var _mini_pings: Array = []       # красные метки тревоги на мини-карте
var groups: Dictionary = {}        # номер клавиши -> отряд
var _group_tap := {"n": -1, "t": 0.0}
var _mini_tex: ImageTexture
const MINI_SIZE := 216.0
var _dragging := false
var _drag_from := Vector2.ZERO
var _placing := ""                # ключ здания, которое сейчас ставим
var _casting: Dictionary = {}     # заклинание, для которого выбирают цель
var _ghost: MeshInstance3D
var _ghost_cell := Vector2i.ZERO
var _sel_ring: MeshInstance3D
var _range_ring: MeshInstance3D
var _show_hitboxes := false      # F11: показать зоны столкновений
var _mmb_drag := false            # камера тянется зажатым колёсиком
var _mouse_in := true             # курсор внутри окна игры (иначе край экрана не двигает камеру)
var fog: Fog                      # туман войны (только картинка этого игрока)
var fog_on := true                # включён ли туман в этой партии
var _bseen: Dictionary = {}       # чужие здания, которые мы уже видели (дальше видны и в тумане)
const SPEEDS := [0.5, 1.0, 1.5, 2.0, 3.0]
var speed := 1.0                  # скорость одиночной игры (клавиши + и -)
var _speed_label: Label
var _feed: VBoxContainer          # лента чата и сообщений союзников (слева над мини-картой)
var _chat_edit: LineEdit          # поле ввода чата (Enter)
var _chat_allies := true          # кому пишем: союзникам или всем
var _allies_btn: Button
var _allies_panel: PanelContainer
var _allies_rows: Array = []      # [{player, label}]
var _allies_key := ""
var _room_chat: Array = []        # чат комнаты до начала партии
var _room_chat_label: Label
var _sun: DirectionalLight3D
var _env: Environment
var _clock_label: Label           # время партии и день/ночь
var _day_icon: TextureRect
var _res_labels: Dictionary = {}  # gold / wood / supply -> Label
var _shown_res := {"gold": -1, "wood": -1}
var runeviews: Dictionary = {}    # id руны -> Node3D


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_ENTER:
		_mouse_in = true
	elif what == NOTIFICATION_WM_MOUSE_EXIT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_mouse_in = false
var _test := {}
var _frames := 0
var _deaths := 0


func _ready() -> void:
	_load_data()
	_ui = CanvasLayer.new()
	add_child(_ui)
	audio = Audio.new()
	add_child(audio)
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		_test[kv[0]] = kv[1] if kv.size() > 1 else "1"
	# сетевая часть живёт в корне дерева: вход и соединение переживают выход в меню
	online = get_tree().root.get_node_or_null("Online")
	if online == null:
		online = Online.new()
		online.name = "Online"
		get_tree().root.add_child.call_deferred(online)
	if _test.has("server"):      # выделенный сервер: только аккаунты, комнаты и пересылка команд
		_start_server.call_deferred()
		return
	_load_settings()
	_online_signals()
	if _test.has("autonet"):
		_autonet_begin()
		return
	if _test.has("load"):
		_start_loaded()
	elif _test.has("race"):
		_start_new(String(_test["race"]))
	else:
		_show_main_menu()
		if _test.has("menu") and String(_test["menu"]) != "1":
			_menu_page(String(_test["menu"]))


func _start_server() -> void:
	var err: int = online.start_server(int(_test.get("port", Online.DEFAULT_PORT)))
	if err != OK:
		print("SERVER: не удалось открыть порт (ошибка %d)" % err)
		get_tree().quit(1)
		return
	print("SERVER: адреса этого компьютера: %s" % ", ".join(_my_addresses()))


## Сцена уходит (выход в меню): отцепляемся от сетевых сигналов, которые переживут нас.
func _exit_tree() -> void:
	for src in [online, multiplayer]:
		if src == null:
			continue
		for sig in (src as Object).get_signal_list():
			for con in (src as Object).get_signal_connection_list(String(sig["name"])):
				var cb: Callable = con["callable"]
				if cb.get_object() == self:
					(src as Object).disconnect(String(sig["name"]), cb)


func _read_json(path: String) -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary:
		return data
	push_error("Ошибка в файле данных: " + path)
	return {}


func _load_data() -> void:
	for f in DirAccess.open("res://data/races").get_files():
		if f.ends_with(".json"):
			var race := _read_json("res://data/races/" + f)
			if race.has("id"):
				races[String(race["id"])] = race
	neutral = _read_json("res://data/neutral.json")
	combat = _read_json("res://data/combat.json")
	for rid in races:      # справочник для иконок эффектов: от какой способности или предмета эффект
		for ukey in races[rid]["units"]:
			for ab in races[rid]["units"][ukey].get("abilities", []):
				_lookup[String(ab["key"])] = {"name": ab["name"], "icon": ab["icon"], "color": ab["color"]}
	for ikey in neutral.get("items", {}):
		var it: Dictionary = neutral["items"][ikey]
		_lookup[String(ikey)] = {"name": it["name"], "icon": it["icon"], "color": it["color"]}
	_lookup["chill"] = {"name": "Холод глубин", "icon": "snow", "color": "#7fd0e8"}
	for rkey in Sim.RUNE_INFO:      # усиления от рун
		_lookup["rune_" + String(rkey)] = {"name": Sim.RUNE_INFO[rkey]["name"], "icon": "rune", "color": Sim.RUNE_INFO[rkey]["color"]}


# =====================================================================
#  ГЛАВНОЕ МЕНЮ
# =====================================================================

func _menu_button(text: String, action: Callable, enabled := true) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(380, 62)
	b.add_theme_font_size_override("font_size", 23)
	b.disabled = not enabled
	b.pressed.connect(action)
	return b


func _show_main_menu() -> void:
	_backdrop = Backdrop.new()
	add_child(_backdrop)
	_backdrop.setup(races)
	_menu = Control.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_menu)
	var side := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.1, 0.7)
	sb.border_color = Color(0.75, 0.62, 0.3, 0.9)
	sb.border_width_right = 3
	side.add_theme_stylebox_override("panel", sb)
	side.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	side.custom_minimum_size = Vector2(500, 0)
	side.size = Vector2(500, 0)
	_menu.add_child(side)
	_menu_side = side
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 50
	col.offset_right = -50
	col.offset_top = 30
	col.offset_bottom = -20
	col.add_theme_constant_override("separation", 10)
	side.add_child(col)
	var title := Label.new()
	title.text = "ZEMLIBOGA"
	title.add_theme_color_override("font_color", Color("#ffd24a"))
	_outlined(title, 62)
	col.add_child(title)
	var sub := Label.new()
	sub.text = "Земли Бога"
	sub.modulate = Color(1, 1, 1, 0.8)
	sub.add_theme_font_size_override("font_size", 20)
	col.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	col.add_child(gap)
	var scroll := ScrollContainer.new()     # если кнопки не помещаются по высоте, появляется ползунок
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	col.add_child(scroll)
	_menu_box = VBoxContainer.new()
	_menu_box.add_theme_constant_override("separation", 12)
	_menu_box.custom_minimum_size = Vector2(380, 0)
	scroll.add_child(_menu_box)
	_menu_page("main")


## Открыть страницу меню. Перестраивается она в следующем кадре: страницу часто меняет кнопка,
## которая сама при этом удаляется, — удалять её посреди её же нажатия нельзя.
func _menu_page(page: String) -> void:
	_page = page
	if not _menu_pending:
		_menu_pending = true
		_build_menu.call_deferred()


var _menu_pending := false
var _menu_side: Panel


func _build_menu() -> void:
	_menu_pending = false
	if _menu_box == null or not is_instance_valid(_menu_box):
		return
	var page := _page
	var wide: float = 720.0 if page == "room" else (580.0 if page == "race" else 500.0)      # в комнате у каждого места много кнопок
	if _menu_side != null and is_instance_valid(_menu_side):
		_menu_side.custom_minimum_size.x = wide
		_menu_side.size.x = wide
	for c in _menu_box.get_children():
		_menu_box.remove_child(c)
		c.queue_free()
	match page:
		"main":
			var any_save := false
			for slot in range(1, SAVE_SLOTS + 1):
				any_save = any_save or _save_header(slot) != null
			if not online.profile.is_empty():
				_menu_box.add_child(_note_label("Вы вошли как %s" % online.profile["nick"], Color("#9fe0ff")))
			_menu_box.add_child(_menu_button("Одиночная игра", _menu_page.bind("race")))
			_menu_box.add_child(_menu_button("Загрузить игру", _menu_page.bind("load"), any_save))
			_menu_box.add_child(_menu_button("Сетевая игра", _menu_page.bind("online")))
			_menu_box.add_child(_menu_button("Настройки", _menu_page.bind("settings")))
			_menu_box.add_child(_menu_button("Выход", get_tree().quit))
			if not any_save:
				_menu_box.add_child(_note_label("Сохранений пока нет", Color(1, 1, 1, 0.55)))
		"load":
			_menu_box.add_child(_head_label("Загрузить игру"))
			for slot in range(1, SAVE_SLOTS + 1):
				var b := _menu_button(_slot_text(slot), _start_loaded.bind(slot), _save_header(slot) != null)
				b.custom_minimum_size.y = 78
				_menu_box.add_child(b)
			_menu_box.add_child(_menu_button("Назад", _menu_page.bind("main")))
		"settings":
			_menu_box.add_child(_head_label("Настройки"))
			_settings_box(_menu_box)
			_menu_box.add_child(_menu_button("Назад", _menu_page.bind("main")))
		"online":
			_online_page()
		"lobby":
			_lobby_page()
		"room":
			_room_page()
		_:
			_skirmish_page()


func _head_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 28)
	return l


func _note_label(text: String, color: Color = Color(1, 1, 1, 0.7)) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(380, 0)
	l.add_theme_color_override("font_color", color)
	return l


func _field(placeholder: String, value: String, secret := false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = value
	e.secret = secret
	e.custom_minimum_size = Vector2(380, 44)
	e.add_theme_font_size_override("font_size", 19)
	return e


## Ряд переключателей: options — [[значение, подпись], ...]; current — выбранное.
func _toggle_row(options: Array, current, on_pick: Callable, width := 380.0, font := 16) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var buttons: Array = []
	for opt in options:
		var b := Button.new()
		b.text = String(opt[1])
		b.toggle_mode = true
		b.button_pressed = opt[0] == current
		b.disabled = opt.size() > 2 and not bool(opt[2])
		b.custom_minimum_size = Vector2((width - 6.0 * (options.size() - 1)) / options.size(), 42)
		b.add_theme_font_size_override("font_size", font)
		buttons.append(b)
		row.add_child(b)
		b.pressed.connect(func() -> void:
			for o in buttons:
				(o as Button).button_pressed = o == b
			on_pick.call(opt[0]))
	return row


func _race_options(with_random := false) -> Array:
	var out: Array = [["random", "Любая"]] if with_random else []
	var ids: Array = races.keys()
	ids.sort()
	for id in ids:
		out.append([id, String(races[id]["name"]).split(" ")[-1].capitalize()])
	return out


## Одиночная игра: противники-компьютеры, сложность, размер карты, своя раса.
func _skirmish_page() -> void:
	_menu_box.add_child(_head_label("Одиночная игра"))
	var max_opp: int = int(MapGen.MAX_PLAYERS_ON[map_choice]) - 1
	opponents = mini(opponents, max_opp)
	_menu_box.add_child(_note_label("Компьютеров (на этой карте до %d)" % max_opp, Color.WHITE))
	var opp: Array = []
	for i in range(1, 8):
		opp.append([i, str(i), i <= max_opp])
	_menu_box.add_child(_toggle_row(opp, opponents, func(v) -> void:
		opponents = int(v)
		_menu_page("race")))
	allies = clampi(allies, 0, opponents - 1)
	_menu_box.add_child(_note_label("Из них ваших союзников (остальные — противники: %d)" % (opponents - allies), Color.WHITE))
	var al: Array = []
	for i in range(0, 7):
		al.append([i, str(i), i <= opponents - 1])
	_menu_box.add_child(_toggle_row(al, allies, func(v) -> void:
		allies = int(v)
		_menu_page("race")))
	if opponents - allies >= 2:
		_menu_box.add_child(_toggle_row([[false, "Противники каждый сам за себя"], [true, "Противники — одна команда"]], foes_together, func(v) -> void: foes_together = bool(v), 380.0, 14))
	var fog_box := CheckButton.new()
	fog_box.text = "Туман войны"
	fog_box.button_pressed = bool(settings.get("fog", true))
	fog_box.add_theme_font_size_override("font_size", 18)
	fog_box.toggled.connect(func(on: bool) -> void:
		settings["fog"] = on
		_apply_settings())
	_menu_box.add_child(fog_box)
	_menu_box.add_child(_note_label("Раса противников", Color.WHITE))
	_menu_box.add_child(_toggle_row(_race_options(true), enemy_choice, func(v) -> void: enemy_choice = String(v), 470.0, 14))
	_menu_box.add_child(_note_label("Сложность противников", Color.WHITE))
	var note := _note_label(DIFFICULTY_NOTE[difficulty])
	var diffs: Array = []
	for key in DIFFICULTY:
		diffs.append([key, DIFFICULTY[key]])
	_menu_box.add_child(_toggle_row(diffs, difficulty, func(v) -> void:
		difficulty = String(v)
		note.text = DIFFICULTY_NOTE[difficulty], 380.0, 17))
	_menu_box.add_child(note)
	_menu_box.add_child(_size_row(func() -> void: _menu_page("race")))
	_menu_box.add_child(_note_label("Ваша раса (нажмите, чтобы начать)", Color.WHITE))
	var ids: Array = races.keys()
	ids.sort()
	for id in ids:
		_menu_box.add_child(_menu_button(String(races[id]["name"]), _start_new.bind(String(id))))
		_menu_box.add_child(_note_label(String(races[id].get("description", ""))))
	_menu_box.add_child(_menu_button("Назад", _menu_page.bind("main")))


## Сетевая игра, шаг 1: создать игру на своём ПК или подключиться к другу по адресу
## (локальная сеть или Radmin VPN), затем вход по логину и паролю.
func _online_page() -> void:
	_menu_box.add_child(_head_label("Сетевая игра"))
	if not online.connected:
		_menu_box.add_child(_note_label("Играйте по локальной сети или через Radmin VPN: один игрок создаёт игру, остальные подключаются к его адресу.", Color(1, 1, 1, 0.75)))
		_menu_box.add_child(_menu_button("Создать игру на этом ПК", func() -> void:
			var err: int = online.host()
			if err != OK:
				_online_status("Не удалось открыть порт %d (ошибка %d). Может, игра уже создана в другом окне?" % [Online.DEFAULT_PORT, err])
				return
			_online_status("Игра создана. Друзья подключаются к адресу: %s" % _host_hint())
			_menu_page("online")))
		_menu_box.add_child(_note_label("Подключиться к другу — адрес его ПК (в Radmin VPN он начинается с 26.)", Color.WHITE))
		var url := _field("например, 26.12.34.56", String(settings.get("server", "")))
		_menu_box.add_child(url)
		var join := func() -> void:
			var address := url.text.strip_edges()
			if address == "":
				_online_status("Введите адрес хозяина игры")
				return
			settings["server"] = address
			_apply_settings()
			_online_status("Подключаемся к %s..." % address)
			if online.connect_to(address) != OK:
				_online_status("Неверный адрес")
		url.text_submitted.connect(func(_t: String) -> void: join.call())
		_menu_box.add_child(_menu_button("Подключиться", join))
	elif online.profile.is_empty():
		if online.plays:
			_menu_box.add_child(_note_label("Вы — хозяин игры. Адрес для друзей: %s" % _host_hint(), Color("#ffd24a")))
		_menu_box.add_child(_note_label("Вход или регистрация (аккаунты хранятся у хозяина игры)", Color.WHITE))
		var login := _field("логин (латиница, цифры, _)", String(settings.get("login", "")))
		var password := _field("пароль", "", true)
		_menu_box.add_child(login)
		_menu_box.add_child(password)
		_menu_box.add_child(_menu_button("Войти", func() -> void:
			settings["login"] = login.text.strip_edges()
			_apply_settings()
			online.login(login.text, password.text)))
		_menu_box.add_child(_menu_button("Зарегистрироваться", func() -> void:
			settings["login"] = login.text.strip_edges()
			_apply_settings()
			online.register(login.text, password.text)))
		password.text_submitted.connect(func(_t: String) -> void: online.login(login.text, password.text))
	else:
		_menu_page("lobby")
		return
	_net_status = _note_label(_online_text, Color("#9fe0ff"))
	_menu_box.add_child(_net_status)
	_menu_box.add_child(_menu_button("Назад", func() -> void:
		if not online.connected or online.profile.is_empty():
			online.close()
		_menu_page("main")))


var _online_text := ""


func _online_status(text: String) -> void:
	_online_text = text
	if _net_status != null and is_instance_valid(_net_status):
		_net_status.text = text
	print("NET: ", text)


## IPv4-адреса этого компьютера; адрес Radmin VPN (26.x.x.x) — первым.
func _my_addresses() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	out.sort_custom(func(x: String, y: String) -> bool: return x.begins_with("26.") and not y.begins_with("26."))
	return out


func _host_hint() -> String:
	var list := _my_addresses()
	if list.is_empty():
		return "адрес этого ПК не найден"
	var radmin: Array = list.filter(func(a: String) -> bool: return a.begins_with("26."))
	return ("%s (Radmin VPN)" % radmin[0]) if not radmin.is_empty() else ", ".join(list)


var _room_name := ""
var _room_slots := 4


## Сетевая игра, шаг 2: профиль (смена ника), список комнат, создание комнаты.
func _lobby_page() -> void:
	var p: Dictionary = online.profile
	_menu_box.add_child(_head_label("Лобби"))
	if online.plays:
		_menu_box.add_child(_note_label("Вы — хозяин игры. Адрес для друзей: %s" % _host_hint(), Color("#ffd24a")))
	_menu_box.add_child(_note_label("Вы: %s   ·   побед %d, поражений %d" % [p.get("nick", ""), int(p.get("wins", 0)), int(p.get("losses", 0))], Color("#ffd24a")))
	var nick := _field("новый ник", String(p.get("nick", "")))
	_menu_box.add_child(nick)
	_menu_box.add_child(_menu_button("Сменить ник", func() -> void: online.set_nick(nick.text)))
	_menu_box.add_child(_note_label("Комнаты", Color.WHITE))
	if online.rooms.is_empty():
		_menu_box.add_child(_note_label("Пока нет ни одной. Создайте свою!"))
	for r in online.rooms:
		var b := _menu_button("%s   ·   %d/%d   ·   %s%s" % [r["name"], int(r["used"]), int(r["slots"]), String(MapGen.SIZES.get(int(r["size"]), "")).to_lower(), "   (идёт игра)" if r["started"] else ""], online.join_room.bind(int(r["id"])), not r["started"])
		b.add_theme_font_size_override("font_size", 16)
		_menu_box.add_child(b)
	_menu_box.add_child(_menu_button("Обновить список", online.refresh_rooms))
	_menu_box.add_child(_note_label("Новая комната", Color.WHITE))
	var rn := _field("название комнаты", _room_name)
	rn.text_changed.connect(func(t: String) -> void: _room_name = t)
	_menu_box.add_child(rn)
	_menu_box.add_child(_size_row(func() -> void: _menu_page("lobby")))
	var max_slots: int = int(MapGen.MAX_PLAYERS_ON[map_choice])
	_room_slots = clampi(_room_slots, 2, max_slots)
	var sl: Array = []
	for i in range(2, 9):
		sl.append([i, str(i), i <= max_slots])
	_menu_box.add_child(_note_label("Мест в комнате", Color.WHITE))
	_menu_box.add_child(_toggle_row(sl, _room_slots, func(v) -> void: _room_slots = int(v)))
	_menu_box.add_child(_menu_button("Создать комнату", func() -> void: online.create_room(_room_name, map_choice, _room_slots)))
	_net_status = _note_label(_online_text, Color("#9fe0ff"))
	_menu_box.add_child(_net_status)
	_menu_box.add_child(_menu_button("Закрыть игру (отключит всех)" if online.plays else "Отключиться", func() -> void:
		online.close()
		_online_text = ""
		_menu_page("online")))
	_menu_box.add_child(_menu_button("Назад", _menu_page.bind("main")))


## Сетевая игра, шаг 3: комната — места игроков и компьютеров, расы, старт.
func _room_page() -> void:
	var r: Dictionary = online.room
	if r.is_empty():
		_menu_page("lobby")
		return
	var host: bool = online.is_host()
	var me: int = multiplayer.get_unique_id()
	_menu_box.add_child(_head_label(String(r["name"])))
	_menu_box.add_child(_note_label("Карта: %s" % String(MapGen.SIZES.get(int(r["size"]), "")).to_lower(), Color.WHITE))
	_menu_box.add_child(_note_label("Команда: нажмите на кнопку команды, чтобы сменить её. «Сам за себя» — против всех; игроки одной команды — союзники и побеждают вместе.", Color(1, 1, 1, 0.65)))
	var kinds := {"open": "Открыто", "ai": "Компьютер", "closed": "Закрыто"}
	var players: Array = []
	for i in (r["slots"] as Array).size():
		var s: Dictionary = r["slots"][i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := Label.new()
		l.custom_minimum_size = Vector2(150, 0)
		l.clip_text = true
		l.add_theme_color_override("font_color", TEAM_COLORS[i].lightened(0.3))
		l.text = "%d. %s" % [i + 1, s.get("nick", kinds.get(s["kind"], ""))]
		row.add_child(l)
		var kind := String(s["kind"])
		var mine := kind == "human" and int(s.get("peer", 0)) == me
		var team := int(s.get("team", 0))
		var race := String(s.get("race", "humans"))
		var diff := String(s.get("diff", "normal"))
		if kind == "human" or kind == "ai":
			players.append(s)
			var rb := Button.new()      # раса: нажатие переключает на следующую
			rb.text = String(races.get(race, races["humans"])["name"]).split(" ")[-1].capitalize()
			rb.disabled = not (mine or (host and kind == "ai"))
			rb.custom_minimum_size = Vector2(104, 40)
			rb.pressed.connect(func() -> void:
				var opts := _race_options()
				var at := 0
				for k in opts.size():
					if opts[k][0] == race:
						at = k
				online.set_slot(i, kind, String(opts[(at + 1) % opts.size()][0]), diff, team))
			row.add_child(rb)
		if kind != "closed":
			var tb := Button.new()      # команда: сам за себя → 1 → 2 → 3 → 4
			tb.text = "Сам за себя" if team == 0 else "Команда %d" % team
			tb.add_theme_color_override("font_color", SIDE_COLORS[team])
			tb.add_theme_color_override("font_disabled_color", SIDE_COLORS[team].darkened(0.2))
			tb.disabled = not (mine or host)
			tb.custom_minimum_size = Vector2(118, 40)
			tb.pressed.connect(func() -> void: online.set_slot(i, kind, race, diff, (team + 1) % (Online.MAX_TEAMS + 1)))
			row.add_child(tb)
		if host and kind != "human":
			var kb := Button.new()      # хозяин: открыто → компьютер → закрыто
			kb.text = kinds[kind]
			kb.custom_minimum_size = Vector2(100, 40)
			kb.pressed.connect(func() -> void:
				var order := ["open", "ai", "closed"]
				online.set_slot(i, order[(order.find(kind) + 1) % 3], race, diff, team))
			row.add_child(kb)
			if kind == "ai":
				var db := Button.new()
				db.text = String(DIFFICULTY.get(diff, ""))
				db.custom_minimum_size = Vector2(90, 40)
				db.pressed.connect(func() -> void:
					var order := ["easy", "normal", "hard"]
					online.set_slot(i, "ai", race, order[(order.find(diff) + 1) % 3], team))
				row.add_child(db)
		if kind == "open":
			var sit := Button.new()      # пересесть на свободное место (вместе с его командой)
			sit.text = "Сесть сюда"
			sit.custom_minimum_size = Vector2(100, 40)
			sit.pressed.connect(online.move_to.bind(i))
			row.add_child(sit)
		if host and kind == "human" and not mine:
			var kick := Button.new()
			kick.text = "✕"
			kick.tooltip_text = "Убрать игрока из комнаты"
			kick.custom_minimum_size = Vector2(40, 40)
			kick.add_theme_color_override("font_color", Color("#ff6a5a"))
			kick.pressed.connect(online.kick.bind(i))
			row.add_child(kick)
		_menu_box.add_child(row)
	var sides: int = Online.sides(players)
	var ok := players.size() >= 2 and sides >= 2
	_menu_box.add_child(_note_label("Игроков: %d, сторон в бою: %d%s" % [players.size(), sides, "" if ok else " — нужно хотя бы две враждующие стороны"], Color.WHITE if ok else Color("#ff9a7a")))
	var fog_box := CheckButton.new()
	fog_box.text = "Туман войны"
	fog_box.button_pressed = bool(r.get("fog", true))
	fog_box.disabled = not host      # меняет только хозяин комнаты
	fog_box.add_theme_font_size_override("font_size", 18)
	fog_box.toggled.connect(func(on: bool) -> void: online.set_option("fog", on))
	_menu_box.add_child(fog_box)
	# чат комнаты
	_room_chat_label = _note_label("\n".join(_room_chat) if not _room_chat.is_empty() else "Чат комнаты пуст", Color("#d8e8f0"))
	_menu_box.add_child(_room_chat_label)
	var say := _field("сообщение в чат комнаты (Enter)", "")
	say.text_submitted.connect(func(t: String) -> void:
		if t.strip_edges() != "":
			online.send_chat(t, false)
		say.text = "")
	_menu_box.add_child(say)
	if host:
		_menu_box.add_child(_menu_button("Начать игру", online.start_game, ok))
	else:
		_menu_box.add_child(_note_label("Ждём, когда хозяин начнёт игру"))
	_net_status = _note_label(_online_text, Color("#9fe0ff"))
	_menu_box.add_child(_net_status)
	_menu_box.add_child(_menu_button("Покинуть комнату", online.leave_room))


## Выбор размера карты: три переключателя и пояснение. changed — что сделать после выбора.
func _size_row(changed: Callable = Callable()) -> Control:
	var box := VBoxContainer.new()
	box.add_child(_note_label("Размер карты", Color.WHITE))
	var notes := {96: "Быстрые партии на 2–4 игроков: всё рядом.", 192: "Вчетверо больше места: до 8 игроков, больше рудников, лагерей и строений.", 272: "Огромная карта для долгих партий: до 8 игроков, в восемь раз больше всего."}
	var opts: Array = []
	for size in MapGen.SIZES:
		opts.append([size, MapGen.SIZES[size]])
	box.add_child(_toggle_row(opts, map_choice, func(v) -> void:
		map_choice = int(v)
		if changed.is_valid():
			changed.call(), 380.0, 15))
	box.add_child(_note_label(notes[map_choice]))
	return box


func _slot_text(slot: int) -> String:
	var header = _save_header(slot)
	if header == null:
		return "Слот %d\nпусто" % slot
	return "Слот %d\n%s, %s, %s" % [slot, header.get("race", ""), String(DIFFICULTY.get(header.get("difficulty", "normal"), "")).to_lower(), _clock(float(header.get("time", 0)))]


# ---------- настройки (хранятся в отдельном файле и переживают перезапуск) ----------

var settings := {"fullscreen": false, "volume": 80, "hints": true, "show_fps": true, "server": "", "login": "", "fog": true}


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		for key in settings:
			settings[key] = cfg.get_value("game", key, settings[key])
	var server := String(settings["server"])      # старый формат ws://адрес:порт -> просто адрес
	if server.begins_with("ws://"):
		server = server.trim_prefix("ws://").get_slice(":", 0)
	settings["server"] = "" if server in ["127.0.0.1", "localhost"] else server
	_apply_settings(false)


func _apply_settings(save: bool = true) -> void:
	if _test.is_empty():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if settings["fullscreen"] else DisplayServer.WINDOW_MODE_WINDOWED)
	audio.enabled = int(settings["volume"]) > 0
	audio.gain_db = linear_to_db(maxf(0.01, float(settings["volume"]) / 80.0))
	if save:
		var cfg := ConfigFile.new()
		for key in settings:
			cfg.set_value("game", key, settings[key])
		cfg.save(SETTINGS_PATH)


func _settings_box(parent: Control) -> void:
	var full := CheckButton.new()
	full.text = "Полный экран"
	full.button_pressed = settings["fullscreen"]
	full.add_theme_font_size_override("font_size", 20)
	full.toggled.connect(func(on: bool) -> void:
		settings["fullscreen"] = on
		_apply_settings())
	parent.add_child(full)
	var hints := CheckButton.new()
	hints.text = "Подсказки для новичка"
	hints.button_pressed = settings["hints"]
	hints.add_theme_font_size_override("font_size", 20)
	hints.toggled.connect(func(on: bool) -> void:
		settings["hints"] = on
		_apply_settings())
	parent.add_child(hints)
	var fps := CheckButton.new()
	fps.text = "Счётчик кадров (FPS)"
	fps.button_pressed = settings["show_fps"]
	fps.add_theme_font_size_override("font_size", 20)
	fps.toggled.connect(func(on: bool) -> void:
		settings["show_fps"] = on
		_apply_settings())
	parent.add_child(fps)
	var vl := Label.new()
	vl.text = "Громкость звука: %d" % int(settings["volume"])
	vl.add_theme_font_size_override("font_size", 20)
	parent.add_child(vl)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 5
	slider.value = int(settings["volume"])
	slider.custom_minimum_size = Vector2(340, 28)
	slider.value_changed.connect(func(v: float) -> void:
		settings["volume"] = int(v)
		vl.text = "Громкость звука: %d" % int(v)
		_apply_settings()
		audio.play("click"))
	parent.add_child(slider)


func _clock(seconds: float) -> String:
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]


func _leave_menu() -> void:
	if _menu:
		# Меню убираем через queue_free: сюда приходим из нажатия кнопки этого же меню,
		# и мгновенный free() удалял кнопку посреди её сигнала — игра падала.
		_menu.hide()
		_menu.queue_free()
		_menu = null
		_menu_box = null
	if _backdrop:
		_backdrop.free()
		_backdrop = null


# =====================================================================
#  ЗАПУСК ПАРТИИ, СОХРАНЕНИЕ И ЗАГРУЗКА
# =====================================================================

## Одиночная игра: игрок 0 и 1…7 компьютерных противников.
func _start_new(race_id: String) -> void:
	_leave_menu()
	var map_seed: int = int(_test["seed"]) if _test.has("seed") else int(randi() % 1000000)
	var size := int(_test.get("size", map_choice))
	var n_opp := clampi(int(_test.get("opponents", opponents)), 1, int(MapGen.MAX_PLAYERS_ON.get(size, 8)) - 1)
	var choice := String(_test.get("enemy", enemy_choice))
	var others: Array = races.keys()
	others.sort()
	var list: Array = [races[race_id]]
	var names: Array = ["Вы"]
	var pick := RandomNumberGenerator.new()      # случайные расы противников (одинаковые при одном зерне)
	pick.seed = hash(map_seed)
	var n_ally := clampi(int(_test.get("allies", allies)), 0, n_opp - 1)
	var foes_team := bool(int(_test.get("foes_team", 1 if foes_together else 0)))
	for i in n_opp:
		var rid: String = choice if races.has(choice) and i >= n_ally else String(others[pick.randi_range(0, others.size() - 1)])
		list.append(races[rid])
		names.append("Союзник %d" % (i + 1) if i < n_ally else "Компьютер %d" % (i + 1 - n_ally))
	print("LOG: новая игра, раса=", race_id, " противников=", n_opp - n_ally, " союзников=", n_ally, " сложность=", difficulty, " seed=", map_seed, " размер=", size)
	var world := MapGen.generate(list, neutral, combat, map_seed, size)
	sim = world["sim"]
	terrain = world["terrain"]
	player_names = names
	if n_ally > 0 or foes_team:      # команды: вы и союзники — команда 1, противники — команда 2 или каждый сам за себя
		for i in n_opp + 1:
			sim.set_team(i, 1 if i <= n_ally else (2 if foes_team else 0))
	fog_on = bool(settings.get("fog", true))
	if _test.has("diff"):
		difficulty = String(_test["diff"])
	_make_ais({})
	for ai in ais:
		var ally: bool = sim.allies(ai.me, local_player)
		ai.s["difficulty"] = "normal" if ally else difficulty      # сложность — только у противников
		if difficulty == "hard" and ai.me != local_player and not ally:
			sim.players[ai.me]["income_mul"] = 1.2
	_build_world()
	_build_hud()
	var base: Vector2 = terrain.bases[local_player]
	_rig.position = Vector3(base.x, 0, base.y + 3.0)
	print("LOG: партия запущена")


# =====================================================================
#  СЕТЕВАЯ ИГРА (через сервер, scripts/online.gd)
#  Каждый игрок считает одну и ту же игру и посылает на сервер только свои команды.
#  Команда назначается на тик через NET_DELAY тиков, чтобы успеть дойти по сети.
#  Компьютерные противники считаются у всех одинаково, их команды по сети не ходят.
# =====================================================================

func _online_signals() -> void:
	online.note.connect(func(text: String) -> void:
		_online_status(text)
		if sim != null:
			_say(text))
	online.auth_changed.connect(func() -> void:
		if _menu_box != null and _page in ["online", "lobby"]:
			if not online.profile.is_empty():
				online.refresh_rooms()
			_menu_page("lobby" if not online.profile.is_empty() else "online"))
	online.rooms_changed.connect(func() -> void:
		if _menu_box != null and _page == "lobby":
			_menu_page("lobby"))
	online.room_changed.connect(func() -> void:
		if _menu_box != null and _page in ["lobby", "room"]:
			if online.room.is_empty():
				_room_chat.clear()
				online.refresh_rooms()
			_menu_page("room" if not online.room.is_empty() else "lobby"))
	online.game_started.connect(_start_online)
	online.chat.connect(_on_chat)
	online.pinged.connect(func(index: int, pos: Vector2) -> void:
		if sim != null:
			_show_ping(index, pos))
	online.player_left.connect(func(index: int) -> void:
		if sim != null:
			_say("%s покинул игру" % _player_name(index)))
	online.desynced.connect(func(at_tick: int) -> void:
		if sim != null and not _net_lost:
			_net_lost = true
			_banner.text = "Игры разошлись (рассинхронизация)"
			_banner.add_theme_color_override("font_color", Color("#ff6a5a"))
			_banner.visible = true
			print("NET: DESYNC at tick ", at_tick))
	online.connection_lost.connect(func() -> void:
		if sim != null and net_mode != "":
			_net_lost = true
			_banner.text = "Соединение с сервером потеряно"
			_banner.add_theme_color_override("font_color", Color("#ff6a5a"))
			_banner.visible = true
		elif _menu_box != null:
			_online_text = "Соединение с сервером потеряно"
			_menu_page("online")
		print("NET: соединение потеряно"))
	multiplayer.connected_to_server.connect(func() -> void:
		if _menu_box != null and _page == "online":
			_menu_page("online"))


func _start_online(info: Dictionary) -> void:
	net_mode = "online"
	local_player = int(info["index"])
	_leave_menu()
	var list: Array = []
	player_names = []
	for p in info["players"]:
		list.append(races.get(String(p["race"]), races["humans"]))
		player_names.append(String(p["nick"]))
	var world := MapGen.generate(list, neutral, combat, int(info["seed"]), int(info["size"]))
	sim = world["sim"]
	terrain = world["terrain"]
	for i in (info["players"] as Array).size():      # команды из лобби: союзники не бьют друг друга
		sim.set_team(i, int(info["players"][i].get("team", 0)))
	fog_on = bool(info.get("fog", true))
	_room_chat.clear()
	ais.clear()
	for i in (info["players"] as Array).size():      # компьютеры считаются у всех одинаково
		var p: Dictionary = info["players"][i]
		if String(p["kind"]) == "ai":
			var ai := AI.new(sim, terrain, i)
			ai.s["difficulty"] = String(p.get("diff", "normal"))
			if ai.s["difficulty"] == "hard":
				sim.players[i]["income_mul"] = 1.2
			ais.append(ai)
	_local_turns.clear()
	_outbox.clear()
	_build_world()
	_build_hud()
	var base: Vector2 = terrain.bases[local_player]
	_rig.position = Vector3(base.x, 0, base.y + 3.0)
	print("NET: партия началась, я игрок %d из %d" % [local_player + 1, list.size()])


## Команда игрока: в одиночной игре сразу в симуляцию, в сетевой — в очередь на отправку.
func _issue(cmd: Dictionary) -> void:
	if net_mode == "":
		sim.push_command(cmd)
	else:
		_outbox.append(cmd)


## Подготовка следующего тика в сетевой игре. Возвращает false, если команды
## остальных игроков на этот тик ещё не пришли и нужно подождать.
func _net_turn() -> bool:
	if _net_lost:
		return false
	var t := sim.tick + 1
	if not _local_turns.has(t + NET_DELAY):
		_local_turns[t + NET_DELAY] = true
		online.send_turn(t + NET_DELAY, _outbox)
		_outbox = []
	if t > NET_DELAY and not online.turns.has(t):
		return false
	for cmd in online.turns.get(t, []):      # сервер уже подписал каждую команду номером её игрока
		sim.push_command_at(cmd, t)
	online.turns.erase(t)
	_local_turns.erase(t)
	if sim.tick % 50 == 0 and sim.tick > 0:           # сверка: одинаково ли идёт игра у всех
		online.send_sum(sim.tick, sim.checksum())
	return true


## Компьютерные противники: все игроки, кроме себя (и в проверке --ai0 — и за себя).
func _make_ais(saved: Dictionary) -> void:
	ais.clear()
	if _test.has("noai") or net_mode != "":
		return
	for pl in sim.players:
		if int(pl) == Sim.NEUTRAL or (int(pl) == local_player and not _test.has("ai0")):
			continue
		var ai := AI.new(sim, terrain, int(pl))
		if saved.has(pl):
			ai.s = saved[pl]
			if int(pl) != local_player:
				difficulty = String(ai.s.get("difficulty", "normal"))
		ais.append(ai)


func _player_name(p: int) -> String:
	if p >= 0 and p < player_names.size():
		return String(player_names[p])
	return "Игрок %d" % (p + 1)


func _slot_path(slot: int) -> String:
	return "user://save_%d.dat" % slot


func _save_header(slot: int = 1):
	if not FileAccess.file_exists(_slot_path(slot)):
		return null
	var f := FileAccess.open(_slot_path(slot), FileAccess.READ)
	if f == null:
		return null
	var header = f.get_var()
	if header is Dictionary and int(header.get("version", 0)) == SAVE_VERSION:
		return header
	return null


func _save_game(slot: int = 1) -> void:
	if net_mode != "":
		_pause_note.text = "В сетевой игре сохранение недоступно"
		return
	var f := FileAccess.open(_slot_path(slot), FileAccess.WRITE)
	if f == null:
		_pause_note.text = "Не удалось сохранить игру"
		return
	f.store_var({"version": SAVE_VERSION, "race": sim.players[local_player]["data"]["name"], "time": sim.tick * Sim.TICK_DT, "difficulty": difficulty})
	var ai_state: Dictionary = {}
	for ai in ais:
		ai_state[ai.me] = ai.s
	f.store_var({"sim": sim.save_state(), "cam": [_rig.position.x, _rig.position.z, _zoom], "ai": ai_state,
		"names": player_names, "fog_on": fog.enabled, "fog": fog.save() if fog.enabled else {}, "bseen": _bseen.keys()})
	f.close()
	if _pause_note:
		_pause_note.text = "Игра сохранена в слот %d (%s)" % [slot, _clock(sim.tick * Sim.TICK_DT)]
		_pause_note.add_theme_color_override("font_color", Color("#6dff7a"))


func _start_loaded(slot: int = 1) -> void:
	if _save_header(slot) == null:
		return
	var f := FileAccess.open(_slot_path(slot), FileAccess.READ)
	f.get_var()
	var data = f.get_var()
	f.close()
	if not (data is Dictionary):
		return
	_leave_menu()
	var state: Dictionary = data["sim"]
	var n_players := 0      # рельеф зависит и от числа игроков (базы стоят по кругу)
	for p in state["players"]:
		if int(p) != Sim.NEUTRAL:
			n_players += 1
	terrain = Terrain.new(int(state["seed"]), int(state.get("map_size", Sim.MAP_SIZE)), n_players)
	player_names = data.get("names", [])
	fog_on = bool(data.get("fog_on", true))
	sim = Sim.new()
	sim.set_map_size(int(state.get("map_size", Sim.MAP_SIZE)))
	sim.combat = combat
	for x in sim.map_size:
		for y in sim.map_size:
			if terrain.blocked(Vector2i(x, y)):
				sim.block_cell(Vector2i(x, y))
	sim.load_state(state)
	_make_ais(data.get("ai", {}))
	_build_world()
	for bid in data.get("bseen", []):
		_bseen[bid] = true
	if data.has("fog"):
		fog.restore(data["fog"])
		fog.update(sim, local_player, 0.0, true)
	_build_hud()
	_rig.position = Vector3(float(data["cam"][0]), 0, float(data["cam"][1]))
	_zoom = float(data["cam"][2])
	_apply_zoom()


## Центр карты (зависит от её размера).
func _center() -> Vector2:
	return Vector2(sim.map_size, sim.map_size) * 0.5


func _build_world() -> void:
	var taken: Dictionary = {}   # клетки под деревьями, рудниками и зданиями: там не растут цветы
	for group in [sim.resources, sim.buildings]:
		for id in group:
			var t: Dictionary = group[id]
			for x in int(t["size"]):
				for y in int(t["size"]):
					taken[t["cell"] + Vector2i(x, y)] = true
	terrain.build(self, Models, func(p: Vector2) -> bool: return taken.has(Vector2i(floori(p.x), floori(p.y))))

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52), deg_to_rad(-35), 0)
	sun.light_energy = 1.25
	sun.light_color = Color("#ffe6c4")
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0      # дальше края экрана тени не нужны
	add_child(sun)
	_sun = sun
	var env := Environment.new()
	_env = env
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#6f777c")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#7f8a98")
	env.ambient_light_energy = 0.42
	env.fog_enabled = true                 # лёгкая дымка вдали
	env.fog_light_color = Color("#6f777c")
	env.fog_density = 0.0028
	env.adjustment_enabled = true          # общая коррекция: меньше насыщенности, больше контраста
	env.adjustment_saturation = 0.82
	env.adjustment_contrast = 1.12
	env.adjustment_brightness = 0.96
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_rig = Node3D.new()
	add_child(_rig)
	_cam = Camera3D.new()
	_cam.fov = 40
	_cam.current = true
	_rig.add_child(_cam)
	_apply_zoom()
	fog = Fog.new()
	add_child(fog)
	fog.setup(sim.map_size, _cam, fog_on and not _test.has("nofog"))
	fog.update(sim, local_player, 0.0, true)

	_ghost = MeshInstance3D.new()
	_ghost.mesh = BoxMesh.new()
	_ghost.material_override = _flat(Color(0.2, 1, 0.3, 0.45), true)
	_ghost.visible = false
	add_child(_ghost)
	_sel_ring = _torus(1.0, 0.06, Color("#3cff5a"), 4)
	_sel_ring.rotation.y = PI / 4
	_sel_ring.visible = false
	add_child(_sel_ring)
	_rally_mark = Node3D.new()
	Models.box(_rally_mark, Vector3(0.06, 1.4, 0.06), Vector3(0, 0.7, 0), Models.DARKWOOD)
	Models.box(_rally_mark, Vector3(0.5, 0.32, 0.03), Vector3(0.27, 1.22, 0), Color("#3cff5a"))
	_rally_mark.visible = false
	add_child(_rally_mark)
	_range_ring = _torus(1.0, 0.012, Color("#7fd6ff"), 48)
	_range_ring.visible = false
	add_child(_range_ring)

	for id in sim.resources:
		var r: Dictionary = sim.resources[id]
		var node: Node3D = Models.tree(int(id) * 31 + r["cell"].x) if r["kind"] == "tree" else Models.gold_mine(float(r["size"]))
		node.position = _at(r["pos"], -0.05)
		if r["kind"] == "gold":
			node.rotation.y = _face_angle(r["pos"])
		add_child(node)
		rviews[id] = node
	for id in sim.loot:
		_make_loot_view(int(id))
	for id in sim.runes:
		_make_rune_view(int(id))
	_setup_visuals()
	# всё, что уже есть в мире (новая партия или загруженное сохранение)
	sim.events.clear()
	for id in sim.buildings:
		_make_building_view(sim.buildings[id])
	for id in sim.units:
		_make_unit_view(sim.units[id])


## Свой или союзный игрок: его всё видно и в тумане войны.
func _friendly(player: int) -> bool:
	return player == local_player or sim.allies(player, local_player)


## Виден ли сейчас юнит (свои и союзные — всегда, чужие — только не в тумане).
func _seen(u: Dictionary) -> bool:
	return fog == null or _friendly(int(u["player"])) or fog.visible_at(u["pos"])


## Здание видно, если оно наше или союзное, или если мы его уже хоть раз видели.
func _building_seen(b: Dictionary) -> bool:
	if fog == null or not fog.enabled or _friendly(int(b["player"])) or _bseen.has(b["id"]):
		return true
	var c: Vector2i = b["cell"]
	var n := int(b["size"])
	for p in [b["pos"], Vector2(c) + Vector2(0.5, 0.5), Vector2(c) + Vector2(n - 0.5, n - 0.5), Vector2(c) + Vector2(0.5, n - 0.5), Vector2(c) + Vector2(n - 0.5, 0.5)]:
		if fog.visible_at(p):
			_bseen[b["id"]] = true
			return true
	return false


## Свои всегда синие, противник красный, нейтралы серые — и в сетевой игре тоже.
func _team(player: int) -> Color:
	return NEUTRAL_COLOR if player < 0 or player >= TEAM_COLORS.size() else TEAM_COLORS[player]


func _flat(color: Color, transparent := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _torus(radius: float, width: float, color: Color, rings: int = 24) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = radius - width
	t.outer_radius = radius
	t.rings = rings
	t.ring_segments = 4
	mi.mesh = t
	mi.material_override = _flat(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Рудники поворачиваются входом к ближайшей базе или к центру карты.
func _face_angle(pos: Vector2) -> float:
	var to := _center() - pos
	for b in terrain.bases:
		if pos.distance_to(b) < 16.0:
			to = (b as Vector2) - pos
	if absf(to.x) > absf(to.y):
		return PI / 2 if to.x > 0.0 else -PI / 2
	return 0.0 if to.y > 0.0 else PI


## Здания стоят входом к центру карты.
func _building_facing(pos: Vector2) -> float:
	var to_center := _center() - pos
	if absf(to_center.x) > absf(to_center.y):
		return PI / 2 if to_center.x > 0.0 else -PI / 2
	return 0.0 if to_center.y > 0.0 else PI


func _make_building_view(b: Dictionary) -> void:
	var owner := int(b.get("owner", -1))      # захваченная шахта — в цвете хозяина
	var node := Models.building(b["def"].get("model", {}), float(b["size"]), _team(owner if owner >= 0 else int(b["player"])))
	node.position = _at(b["pos"], -0.08)
	node.rotation.y = _building_facing(b["pos"])
	add_child(node)
	bviews[b["id"]] = node
	terrain.clear_rect(Rect2i(b["cell"], Vector2i(int(b["size"]), int(b["size"]))))


func _make_unit_view(u: Dictionary) -> void:
	var node := Models.unit(u["def"].get("model", {}), _team(int(u["player"])))
	node.position = _at(u["pos"])
	node.rotation.y = atan2(u["facing"].x, u["facing"].y)
	add_child(node)
	var r: float = float(u["radius"]) + 0.15
	var ring := _torus(r, 0.06, Color("#3cff5a"), 20)
	ring.position.y = 0.1
	ring.scale.y = 0.2
	ring.visible = false
	node.add_child(ring)
	var fx := _torus(r + 0.22, 0.09, Color("#ffd24a"), 20)   # кольцо эффектов: усиление, замедление, оглушение
	fx.position.y = 0.07
	fx.scale.y = 0.2
	fx.visible = false
	node.add_child(fx)
	if u["hero"]:   # героев видно по золотому кольцу под ногами
		var mark := _torus(r + 0.42, 0.04, Color("#ffd24a"), 28)
		mark.position.y = 0.05
		mark.scale.y = 0.2
		node.add_child(mark)
	views[u["id"]] = {
		"node": node, "parts": node.get_meta("parts"), "ring": ring, "fx": fx,
		"phase": float(int(u["id"]) % 7), "walk": 0.0, "atk_t": -1.0, "atk_len": 0.6,
		"hp": u["hp"],
	}


# =====================================================================
#  ИНТЕРФЕЙС
# =====================================================================

func _outlined(label: Label, size: int) -> void:
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)


func _panel_style(alpha := 0.82) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.14, alpha)
	sb.border_color = Color(0.75, 0.62, 0.3, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	return sb


func _build_hud() -> void:
	_bars = Control.new()
	_bars.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars.draw.connect(_draw_bars)
	_ui.add_child(_bars)

	var menu_btn := Button.new()
	menu_btn.text = "Меню (F10)"
	menu_btn.position = Vector2(12, 10)
	menu_btn.custom_minimum_size = Vector2(140, 38)
	menu_btn.focus_mode = Control.FOCUS_NONE
	menu_btn.pressed.connect(_toggle_pause)
	_ui.add_child(menu_btn)

	# --- верхняя панель: золото, дерево, лимит (справа) и часы дня и ночи (по центру) ---
	var res_panel := PanelContainer.new()
	var rsb := _panel_style(0.86)
	rsb.set_content_margin_all(6)
	rsb.content_margin_left = 14
	rsb.content_margin_right = 16
	res_panel.add_theme_stylebox_override("panel", rsb)
	res_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	res_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	res_panel.position = Vector2(-12, 8)
	res_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	res_panel.tooltip_text = "Золото, дерево и лимит войск (сколько занято из доступного).\nЛимит растёт с постройкой домов."
	_ui.add_child(res_panel)
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 8)
	res_panel.add_child(rrow)
	for spec in [["coin", "#f0c63a", "gold"], ["log", "#a07a4a", "wood"], ["house", "#c9b080", "supply"]]:
		var ic := TextureRect.new()
		ic.texture = Icons.make(String(spec[0]), Color(String(spec[1])))
		ic.custom_minimum_size = Vector2(28, 28)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rrow.add_child(ic)
		var l := Label.new()
		_outlined(l, 21)
		l.custom_minimum_size = Vector2(78 if spec[2] == "supply" else 64, 0)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rrow.add_child(l)
		_res_labels[spec[2]] = l
	_res = _res_labels["gold"]
	var clock_panel := PanelContainer.new()
	var csb := _panel_style(0.8)
	csb.set_content_margin_all(5)
	csb.content_margin_left = 12
	csb.content_margin_right = 14
	clock_panel.add_theme_stylebox_override("panel", csb)
	clock_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	clock_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	clock_panel.position.y = 8
	clock_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui.add_child(clock_panel)
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 8)
	clock_panel.add_child(crow)
	_day_icon = TextureRect.new()
	_day_icon.custom_minimum_size = Vector2(26, 26)
	_day_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_day_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crow.add_child(_day_icon)
	_clock_label = Label.new()
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outlined(_clock_label, 18)
	crow.add_child(_clock_label)
	clock_panel.tooltip_text = "Время партии и до смены дня и ночи.\nНочью юниты видят на четверть ближе (кроме эльфов),\nа нежить восстанавливает здоровье."
	_fps = Label.new()
	_fps.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_fps.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_fps.position = Vector2(-16, 58)
	_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outlined(_fps, 17)
	_ui.add_child(_fps)

	_hint = Label.new()
	_hint.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.position.y = 58
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_color_override("font_color", Color("#9fe0ff"))
	_outlined(_hint, 20)
	_ui.add_child(_hint)

	_msg = Label.new()
	_msg.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_msg.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_msg.position.y = 96
	_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msg.add_theme_color_override("font_color", Color("#ffd24a"))
	_outlined(_msg, 26)
	_ui.add_child(_msg)

	_banner = Label.new()
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_outlined(_banner, 64)
	_banner.visible = false
	_ui.add_child(_banner)

	# --- панель статистики снизу по центру: портрет и характеристики ---
	_stats = PanelContainer.new()
	_stats.add_theme_stylebox_override("panel", _panel_style(0.88))
	_stats.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_stats.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_stats.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_stats.position.y = -12
	_stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats.visible = false
	_ui.add_child(_stats)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats.add_child(row)
	var frame := PanelContainer.new()
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color("#2a3644")
	fsb.border_color = Color(0.75, 0.62, 0.3, 0.9)
	fsb.set_border_width_all(2)
	frame.add_theme_stylebox_override("panel", fsb)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(frame)
	_portrait = TextureRect.new()
	_portrait.custom_minimum_size = Vector2(112, 112)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_portrait)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	info.custom_minimum_size = Vector2(440, 0)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)
	_stat_name = Label.new()
	_stat_name.add_theme_font_size_override("font_size", 19)
	_stat_name.add_theme_color_override("font_color", Color("#ffd24a"))
	info.add_child(_stat_name)
	_hp_bar = W.Bar.new(Color("#3ddc55"), 20, 14)
	info.add_child(_hp_bar)
	_mana_bar = W.Bar.new(Color("#3a7cff"), 16, 13)
	info.add_child(_mana_bar)
	_xp_bar = W.Bar.new(Color("#c9a23a"), 12, 11)
	info.add_child(_xp_bar)
	_chips = HBoxContainer.new()
	_chips.add_theme_constant_override("separation", 12)
	_chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(_chips)
	var lower := HBoxContainer.new()
	lower.add_theme_constant_override("separation", 10)
	lower.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(lower)
	_effects = HBoxContainer.new()
	_effects.add_theme_constant_override("separation", 4)
	_effects.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lower.add_child(_effects)
	_queue = HBoxContainer.new()
	_queue.add_theme_constant_override("separation", 6)
	_queue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lower.add_child(_queue)
	_stat_extra = Label.new()
	_stat_extra.add_theme_font_size_override("font_size", 15)
	_stat_extra.add_theme_color_override("font_color", Color("#9fe0ff"))
	lower.add_child(_stat_extra)
	# сумка героя: 6 ячеек, наведи — описание, ЛКМ — использовать, ПКМ — выбросить или уничтожить
	_bag = GridContainer.new()
	_bag.columns = 3
	_bag.add_theme_constant_override("h_separation", 4)
	_bag.add_theme_constant_override("v_separation", 4)
	_bag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_bag)
	for i in Sim.MAX_ITEMS:
		var slot := Button.new()
		slot.custom_minimum_size = Vector2(50, 50)
		slot.expand_icon = true
		slot.focus_mode = Control.FOCUS_NONE
		slot.button_mask = MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT
		slot.gui_input.connect(_bag_input.bind(i))
		slot.mouse_entered.connect(func() -> void: _show_tip(_bag_tip(i), slot.get_global_rect()))
		slot.mouse_exited.connect(_hide_tip)
		_bag.add_child(slot)
	_item_menu = PopupMenu.new()
	_item_menu.add_theme_font_size_override("font_size", 17)
	_item_menu.id_pressed.connect(_item_action)
	_ui.add_child(_item_menu)

	_build_hints()
	_build_team_ui()

	# --- мини-карта слева внизу ---
	var mini_panel := PanelContainer.new()
	mini_panel.add_theme_stylebox_override("panel", _panel_style(0.95))
	mini_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	mini_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	mini_panel.position = Vector2(12, -12)
	_ui.add_child(mini_panel)
	_mini = Control.new()
	_mini.custom_minimum_size = Vector2(MINI_SIZE, MINI_SIZE)
	_mini.clip_contents = true
	_mini.draw.connect(_draw_mini)
	_mini.gui_input.connect(_mini_input)
	mini_panel.add_child(_mini)
	_mini_tex = _make_mini_texture()
	if fog.enabled:      # туман на мини-карте: умножение на яркость клеток (неразведанное — чёрное)
		var fog_rect := TextureRect.new()
		fog_rect.texture = fog.texture
		fog_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fog_rect.stretch_mode = TextureRect.STRETCH_SCALE
		fog_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mul := CanvasItemMaterial.new()
		mul.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
		fog_rect.material = mul
		_mini.add_child(fog_rect)
	_mini_top = Control.new()      # рамка обзора и метки — поверх тумана
	_mini_top.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mini_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mini_top.draw.connect(_draw_mini_top)
	_mini.add_child(_mini_top)
	_idle_btn = Button.new()
	_idle_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_idle_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_idle_btn.position = Vector2(12, -MINI_SIZE - 44)
	_idle_btn.custom_minimum_size = Vector2(MINI_SIZE + 20, 34)
	_idle_btn.focus_mode = Control.FOCUS_NONE
	_idle_btn.pressed.connect(_next_idle_worker)
	_idle_btn.visible = false
	_ui.add_child(_idle_btn)

	# --- панель команд справа внизу ---
	_card_panel = PanelContainer.new()
	_card_panel.add_theme_stylebox_override("panel", _panel_style())
	_card_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_card_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_card_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_card_panel.position = Vector2(-14, -14)
	_card_panel.visible = false
	_ui.add_child(_card_panel)
	_card = GridContainer.new()
	_card.columns = 5        # кнопки заполняют ряды слева направо и не сдвигаются от появления новых
	_card.add_theme_constant_override("h_separation", 6)
	_card.add_theme_constant_override("v_separation", 6)
	_card_panel.add_child(_card)

	_tip_panel = PanelContainer.new()
	_tip_panel.add_theme_stylebox_override("panel", _panel_style(0.94))
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.visible = false
	_tip_panel.z_index = 10
	_ui.add_child(_tip_panel)
	_tip = Label.new()
	_tip.add_theme_font_size_override("font_size", 16)     # длинные строки переносит _wrap()
	_tip_panel.add_child(_tip)

	_box = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.3, 1.0, 0.4, 0.12)
	sb.border_color = Color(0.3, 1.0, 0.4, 0.9)
	sb.set_border_width_all(2)
	_box.add_theme_stylebox_override("panel", sb)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.visible = false
	_ui.add_child(_box)

	# --- меню паузы ---
	_pause = ColorRect.new()
	(_pause as ColorRect).color = Color(0, 0, 0, 0.55)
	_pause.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.visible = false
	_ui.add_child(_pause)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.add_child(center)
	var pp := PanelContainer.new()
	var psb := _panel_style(0.96)
	psb.set_content_margin_all(28)
	pp.add_theme_stylebox_override("panel", psb)
	center.add_child(pp)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 12)
	pp.add_child(pv)
	var pt := Label.new()
	pt.text = "Пауза\nСложность: %s" % String(DIFFICULTY[difficulty]).to_lower()
	pt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pt.add_theme_font_size_override("font_size", 38)
	pt.add_theme_color_override("font_color", Color("#ffd24a"))
	pv.add_child(pt)
	pv.add_child(_menu_button("Продолжить", _toggle_pause))
	var sl := Label.new()
	sl.text = "Сохранить игру в слот:"
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pv.add_child(sl)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	pv.add_child(srow)
	for slot in range(1, SAVE_SLOTS + 1):
		var sbtn := Button.new()
		sbtn.text = _slot_text(slot)
		sbtn.custom_minimum_size = Vector2(121, 62)
		sbtn.add_theme_font_size_override("font_size", 14)
		sbtn.pressed.connect(func() -> void:
			_save_game(slot)
			sbtn.text = _slot_text(slot))
		srow.add_child(sbtn)
	pv.add_child(_menu_button("Управление", func() -> void: _controls.visible = not _controls.visible))
	var set_box := VBoxContainer.new()
	set_box.visible = false
	_settings_box(set_box)
	pv.add_child(_menu_button("Настройки", func() -> void: set_box.visible = not set_box.visible))
	pv.add_child(set_box)
	pv.add_child(_menu_button("Выйти в главное меню", _to_main_menu))
	_pause_note = Label.new()
	_pause_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_note.add_theme_color_override("font_color", Color("#6dff7a"))
	pv.add_child(_pause_note)
	_controls = Label.new()
	_controls.text = CONTROLS + CONTROLS_MORE
	_controls.add_theme_font_size_override("font_size", 16)
	_controls.visible = false
	pv.add_child(_controls)


## Неподвижная часть мини-карты: трава, вода, плато, камни, вулкан. Считается один раз.
var _mini_ground: Image
var _mini_dirty := true          # срубили дерево — слой с ресурсами надо обновить
var _mini_redraw := 0.0


func _make_mini_texture() -> ImageTexture:
	var n := sim.map_size
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var p := Vector2(x + 0.5, y + 0.5)
			var c := Color("#33452b").lerp(Color("#5a6b3c"), clampf(terrain.height(p) / 1.5, 0.0, 1.0))
			if terrain.plateau(p) > 0.4:
				c = Color("#5a564f")
			elif terrain.water_dist(p) < 0.4:
				c = Color("#274650").lerp(Color("#6f8a86"), terrain.ford(p))
			elif terrain.prop_cells.has(Vector2i(x, y)):
				c = c.darkened(0.2)
			if p.distance_to(terrain.CENTER) < terrain.vol_out - 0.5:
				c = Color("#3a2a24") if not terrain.volcano_wall(p) else Color("#24201c")
				if p.distance_to(terrain.CENTER) < terrain.vol_in:
					c = Color("#7a2a10")
			img.set_pixel(x, y, c)
	_mini_ground = img
	return ImageTexture.create_from_image(img)


## Деревья и рудники запекаются в картинку мини-карты (а не рисуются каждый кадр по одному).
func _bake_mini() -> void:
	var img: Image = _mini_ground.duplicate()
	var tree_c := Color("#245a2e")
	for id in sim.resources:
		var r: Dictionary = sim.resources[id]
		if r["kind"] == "tree":
			img.set_pixelv(r["cell"], tree_c)
	for id in sim.resources:
		var r: Dictionary = sim.resources[id]
		if r["kind"] == "gold":
			img.fill_rect(Rect2i(r["cell"] - Vector2i(1, 1), Vector2i(5, 5)), Color("#1c1a18"))
			img.fill_rect(Rect2i(r["cell"], Vector2i(3, 3)), Color("#ffd940"))
	_mini_tex.update(img)
	_mini_dirty = false


func _draw_mini() -> void:
	if sim == null or _cam == null:
		return
	var k := MINI_SIZE / sim.map_size
	if _mini_dirty:
		_bake_mini()
	_mini.draw_texture_rect(_mini_tex, Rect2(Vector2.ZERO, Vector2(MINI_SIZE, MINI_SIZE)), false)
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		if bviews.has(id) and not (bviews[id] as Node3D).visible:
			continue      # чужое здание, которое ещё не видели
		var rect := Rect2(Vector2(b["cell"]) * k, Vector2(b["size"], b["size"]) * k)
		_mini.draw_rect(rect.grow(1.0), Color.BLACK)
		var owner := int(b.get("owner", -1))
		var mc := _mini_color(owner if owner >= 0 else int(b["player"]))
		match String(b["def"].get("role", "")):
			"capture":
				mc = mc if owner >= 0 else Color("#c9a23a")
			"fountain":
				mc = Color("#6ad8b0")
			"mercenary":
				mc = Color("#c96a3a")
		_mini.draw_rect(rect, mc)
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if not _seen(u):
			continue
		var pos: Vector2 = (u["pos"] as Vector2) * k
		var boss: bool = int(u["player"]) == Sim.NEUTRAL and int(u["def"].get("level", 1)) >= 5
		var size := 5.0 if u["hero"] or boss else 3.0
		if boss:      # сильные нейтралы видны издалека
			_mini.draw_rect(Rect2(pos - Vector2(size, size) * 0.5 - Vector2(1, 1), Vector2(size + 2, size + 2)), Color("#b0202d"))
		elif u["hero"]:
			_mini.draw_rect(Rect2(pos - Vector2(size, size) * 0.5 - Vector2(1, 1), Vector2(size + 2, size + 2)), Color.WHITE)
		_mini.draw_rect(Rect2(pos - Vector2(size, size) * 0.5, Vector2(size, size)), _mini_color(int(u["player"])))
	for rid in sim.runes:      # руны — ромбики своего цвета
		var rp: Vector2 = (sim.runes[rid]["pos"] as Vector2) * k
		if fog.visible_at(sim.runes[rid]["pos"]):
			_mini.draw_colored_polygon(PackedVector2Array([rp + Vector2(0, -4), rp + Vector2(4, 0), rp + Vector2(0, 4), rp + Vector2(-4, 0)]), Color(String(Sim.RUNE_INFO[sim.runes[rid]["kind"]]["color"])))
	_mini_top.queue_redraw()


## Поверх тумана: рамка обзора камеры и метки (тревога, сигналы союзников).
func _draw_mini_top() -> void:
	if sim == null or _cam == null:
		return
	var k := MINI_SIZE / sim.map_size
	# рамка: какую часть карты сейчас видно на экране
	var vs := get_viewport().get_visible_rect().size
	var pts := PackedVector2Array()
	for corner in [Vector2(0, 0), Vector2(vs.x, 0), vs, Vector2(0, vs.y)]:
		var hit = Plane(Vector3.UP, 0.0).intersects_ray(_cam.project_ray_origin(corner), _cam.project_ray_normal(corner))
		if hit == null:
			return
		pts.append(Vector2(hit.x, hit.z) * k)
	pts.append(pts[0])
	_mini_top.draw_polyline(pts, Color.WHITE, 1.5)
	var live: Array = []
	for ping in _mini_pings:      # метки тревоги
		ping["t"] = float(ping["t"]) + get_process_delta_time()
		if float(ping["t"]) < 4.0:
			live.append(ping)
			_mini_top.draw_arc((ping["pos"] as Vector2) * k, 5.0 + fmod(float(ping["t"]) * 14.0, 12.0), 0.0, TAU, 20, ping.get("color", Color("#ff3a2a")), 2.0)
	_mini_pings = live


func _mini_color(player: int) -> Color:
	if player == Sim.NEUTRAL:
		return Color("#e8b03a")
	return _team(player).lightened(0.25)


## ЛКМ по мини-карте переносит камеру, ПКМ отправляет туда выбранных юнитов.
func _mini_input(event: InputEvent) -> void:
	if _paused or sim == null:
		return
	var pos := Vector2(-1, -1)
	var right := false
	if event is InputEventMouseButton and event.pressed:
		pos = event.position
		right = event.button_index == MOUSE_BUTTON_RIGHT
		if event.button_index != MOUSE_BUTTON_LEFT and not right:
			return
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		pos = event.position
	if pos.x < 0.0:
		return
	var world := (pos / MINI_SIZE * sim.map_size).clamp(Vector2.ZERO, Vector2(sim.map_size, sim.map_size))
	if event is InputEventMouseButton and not right and event.alt_pressed:
		_signal_at(world)      # Alt+ЛКМ по мини-карте — сигнал союзникам
	elif right:
		if not selected.is_empty():
			_issue({"type": "amove" if event.ctrl_pressed else "move", "player": local_player, "units": selected.duplicate(), "target": world})
			_ping(world, Color("#3cff5a"))
	else:
		_rig.position = Vector3(world.x, 0, world.y + _zoom * 0.08)
	_mini.accept_event()


## Экран итогов партии: победа или поражение и статистика всех игроков.
func _show_results(won: bool) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)
	var panel := PanelContainer.new()
	var sb := _panel_style(0.96)
	sb.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)
	var title := Label.new()
	title.text = "Победа!" if won else "Поражение"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color("#ffd24a") if won else Color("#ff6a5a"))
	title.add_theme_font_size_override("font_size", 52)
	col.add_child(title)
	var sub := Label.new()
	sub.text = "Время игры %s   ·   карта: %s" % [_clock(sim.tick * Sim.TICK_DT), String(MapGen.SIZES.get(sim.map_size, "")).to_lower()]
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(1, 1, 1, 0.75)
	col.add_child(sub)
	var stats := [["Игрок", ""], ["Убито", "killed"], ["Потеряно", "lost"], ["Разрушено", "razed"], ["Нанято", "trained"], ["Построено", "built"], ["Золото", "gold"], ["Дерево", "wood"]]
	var grid := GridContainer.new()
	grid.columns = stats.size()
	grid.add_theme_constant_override("h_separation", 22)
	grid.add_theme_constant_override("v_separation", 6)
	col.add_child(grid)
	for st in stats:
		var h := Label.new()
		h.text = String(st[0])
		h.add_theme_font_size_override("font_size", 17)
		h.add_theme_color_override("font_color", Color("#ffd24a"))
		grid.add_child(h)
	for p in sim.players:
		if int(p) == Sim.NEUTRAL:
			continue
		for st in stats:
			var cell := Label.new()
			cell.add_theme_font_size_override("font_size", 17)
			if String(st[1]) == "":
				cell.text = "%s%s%s" % [_player_name(int(p)), "  [команда %d]" % sim.team_of(int(p)) if sim.team_of(int(p)) > 0 else "", "  ✝" if sim.players[p].get("defeated", false) else ""]
				cell.add_theme_color_override("font_color", _team(int(p)).lightened(0.35))
			else:
				cell.text = str(sim.players[p]["stats"][st[1]])
				cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			grid.add_child(cell)
	col.add_child(_menu_button("Продолжить наблюдать", dim.queue_free))
	col.add_child(_menu_button("В главное меню", _to_main_menu))


func _to_main_menu() -> void:
	if net_mode != "":
		online.leave_room()
	get_tree().reload_current_scene()

# ---------- подсказки для новичка ----------

var _hint_box: PanelContainer
var _hint_label: Label
var _hint_last := 0.0
var _hint_seen := 0.0


func _build_hints() -> void:
	_hint_box = PanelContainer.new()
	_hint_box.add_theme_stylebox_override("panel", _panel_style(0.9))
	_hint_box.position = Vector2(12, 58)
	_hint_box.visible = false
	_ui.add_child(_hint_box)
	var v := VBoxContainer.new()
	_hint_box.add_child(v)
	var head := Label.new()
	head.text = "Подсказка"
	head.add_theme_color_override("font_color", Color("#ffd24a"))
	v.add_child(head)
	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size = Vector2(330, 0)
	_hint_label.add_theme_font_size_override("font_size", 16)
	v.add_child(_hint_label)
	var off := Button.new()
	off.text = "Скрыть подсказки"
	off.focus_mode = Control.FOCUS_NONE
	off.pressed.connect(func() -> void:
		settings["hints"] = false
		_apply_settings())
	v.add_child(off)


## Показывает первую ещё не выполненную подсказку.
func _update_hints() -> void:
	if not settings["hints"] or sim.game_over:
		_hint_box.visible = false
		return
	var p: Dictionary = sim.players[local_player]
	var names: Dictionary = p["data"]["buildings"]
	var gathering := 0
	var army := 0
	var hero := false
	var points := false
	var has: Dictionary = {}
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if int(u["player"]) != local_player:
			continue
		var kind := String(u["order"].get("type", "idle"))
		if kind == "gather" or kind == "return":
			gathering += 1
		if not sim.is_worker(u):
			army += 1
		hero = hero or u["hero"]
		points = points or sim.skill_points(u) > 0
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		if int(b["player"]) == local_player and b["done"]:
			has[b["key"]] = true
	var text := ""
	if points:
		text = "У героя есть очко навыка. Выберите героя и нажмите зелёный «+» на кнопке способности (или Ctrl + её клавиша). Новые способности открываются с ростом уровня, сильнейшая — на 6-м."
	elif gathering < 3 and sim.tick < 1200:
		text = "Выделите рабочих рамкой (зажмите левую кнопку мыши и потяните) и нажмите правой кнопкой по золотому руднику или дереву. Они начнут добычу."
	elif not has.has("supply") and int(p["supply_cap"]) - int(p["supply_used"]) < 6:
		text = "Выберите рабочего и постройте «%s» (кнопки справа внизу, клавиша %s): это увеличит лимит армии." % [names["supply"]["name"], names["supply"]["hotkey"]]
	elif not has.has("barracks"):
		text = "Постройте «%s» (клавиша %s у рабочего). Потом щёлкните по готовому зданию, чтобы нанимать в нём войска." % [names["barracks"]["name"], names["barracks"]["hotkey"]]
	elif army < 7:
		text = "Наймите несколько бойцов. Правая кнопка по врагу — атака, Ctrl + правая кнопка — идти с боем. Ctrl+1 запоминает отряд."
	elif not hero and names.has("altar"):
		text = "Постройте «%s» и наймите героя: у него есть заклинания, и он растёт в уровне, получая опыт в бою." % names["altar"]["name"]
	elif int(p["stats"]["killed"]) < 3:
		text = "Жёлтые точки на мини-карте — лагеря нейтралов. Они не нападают первыми, а за победу дают золото и опыт герою. Начните со слабых рядом с базой."
	elif _hint_seen < 45.0:
		_hint_seen += 1.0
		text = "Противник нападает волнами. Башни и улучшения из «%s» помогут отбиться. Чтобы победить, разрушьте все его здания." % (names["forge"]["name"] if names.has("forge") else "кузницы")
	_hint_box.visible = text != ""
	_hint_label.text = text


func _toggle_pause() -> void:
	if net_mode != "":       # в сетевой игре меню открывается, но игра не останавливается
		_pause.visible = not _pause.visible
		_pause_note.text = "Сетевая игра идёт без паузы"
		return
	_paused = not _paused
	_pause.visible = _paused
	_pause_note.text = "Несохранённая игра будет потеряна при выходе" if _paused else ""
	_pause_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	if _paused:
		_placing = ""
		_casting = {}
		_dragging = false
		_box.visible = false


## Картинка модели, снятая отдельной камерой: иконки кнопок и портреты.
func _render(id: String, model: Node3D, eye: Vector3, look: Vector3, size: float, pixels: int) -> Texture2D:
	if _icons.has(id):
		model.free()
		return _icons[id]
	var vp := SubViewport.new()
	vp.size = Vector2i(pixels, pixels)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	vp.add_child(model)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-40), deg_to_rad(25), 0)
	vp.add_child(light)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.6
	cam.environment = env
	vp.add_child(cam)
	cam.position = eye
	cam.look_at(look, Vector3.UP)
	_icons[id] = vp.get_texture()
	return _icons[id]


func _unit_def(player: int, key: String) -> Dictionary:
	var data: Dictionary = sim.players[player]["data"]
	if data["units"].has(key):
		return data["units"][key]
	return data.get("summons", {}).get(key, neutral["units"].get(key, {}))


func _icon(kind: String, player: int, key: String) -> Texture2D:
	var id := "%s:%d:%s" % [kind, player, key]
	if _icons.has(id):
		return _icons[id]
	if kind == "building":
		var def: Dictionary = sim.players[player]["data"]["buildings"][key]
		var extent := float(def["size"]) * (1.25 if int(def["size"]) > 2 else 1.75)
		return _render(id, Models.building(def.get("model", {}), float(def["size"]), _team(player)), Vector3(6, 5.5 + extent * 0.42, 8), Vector3(0, extent * 0.42, 0), extent, 96)
	var model := Models.unit(_unit_def(player, key).get("model", {}), _team(player))
	var h: float = float(model.get_meta("parts")["height"])
	if kind == "portrait":   # крупный план: голова и плечи
		var quad := String(model.get_meta("parts")["kind"]) == "quad"
		var yc := h * (0.55 if quad else 0.76)
		return _render(id, model, Vector3(1.6, yc + 0.5, 5.0), Vector3(0, yc, 0.15 if quad else 0.0), h * (1.0 if quad else 0.52), 128)
	return _render(id, model, Vector3(6, 5.5 + h * 0.5, 8), Vector3(0, h * 0.48, 0), h * 1.15, 96)


func _cost_text(cost: Dictionary) -> String:
	var parts: Array = ["%d золота" % int(cost.get("gold", 0))]
	if int(cost.get("wood", 0)) > 0:
		parts.append("%d дерева" % int(cost["wood"]))
	return ", ".join(parts)


func _range_text(value: float) -> String:
	return "ближний бой" if value < 2.0 else ("%.1f" % value)


func _unit_tip(def: Dictionary, key: String) -> String:
	var text := "%s  (ур. %d)   [%s]\n" % [def["name"], int(def.get("level", 1)), def.get("hotkey", "")]
	var cost: Dictionary = def.get("cost", {})
	if def.get("hero", false):
		var h = sim.players[local_player]["heroes"].get(key)
		var state := "" if h == null else String(h["state"])
		if state == "alive":
			text += "Герой уже в строю\n"
		elif state == "training":
			text += "Герой уже нанимается\n"
		elif state == "dead":
			text += "ВОСКРЕСИТЬ за полцены и вдвое быстрее\n"
			cost = {"gold": int(cost.get("gold", 0)) / 2, "wood": int(cost.get("wood", 0)) / 2}
		text += String(def.get("description", "")) + "\n"
	elif def.has("description"):
		text += String(def["description"]) + "\n"
	for line in _traits(def):
		text += "• %s\n" % line
	text += "%s, лимит %d\n" % [_cost_text(cost), int(def.get("supply", 0))]
	text += "Здоровье %d   Урон %d (%s)   Броня %d (%s)\n" % [int(def["hp"]), int(def["damage"]), DAMAGE_NAMES.get(def["damage_type"], ""), int(def["armor"]), ARMOR_NAMES.get(def["armor_type"], "")]
	text += "Атака раз в %.1f с   Дальность: %s   Скорость %.1f" % [float(def["attack_cooldown"]), _range_text(float(def["range"])), float(def["speed"])]
	if float(def.get("mana", 0)) > 0.0:
		text += "\nМана %d" % int(def["mana"])
		for ab in def.get("abilities", []):
			text += "\n• %s: %s" % [ab["name"], _describe(ab, 1)]
		text += "\nРастёт до 10 уровня, получая опыт в бою"
	return text


## Особые свойства юнита одной строкой каждое.
func _traits(def: Dictionary) -> Array:
	var out: Array = []
	if def.has("autocast"):
		var ac: Dictionary = def["autocast"]
		if String(ac.get("kind", "heal")) == "summon":
			out.append("В бою сам поднимает помощников: до %d сразу, раз в %d с" % [int(ac.get("max", 2)), int(ac.get("cooldown", 12))])
		elif float(ac.get("mana", 0)) > 0.0:
			out.append("Сама лечит раненых союзников: %d здоровья за %d маны, не чаще раза в %.1f с" % [int(ac["amount"]), int(ac["mana"]), float(ac["cooldown"])])
		else:
			out.append("Сама лечит раненых союзников: %d здоровья раз в %.1f с" % [int(ac["amount"]), float(ac["cooldown"])])
	if def.has("aura"):
		out.append("Аура (радиус %d): %s" % [int(def["aura"]["radius"]), _mods_text(def["aura"]["mods"])])
	if def.has("chill"):
		var ch: Dictionary = def["chill"]
		out.append("Холод глубин: удар замедляет врага на %d%% и его атаки на %d%% на %.1f с" % [roundi((1.0 - float(ch.get("speed_mul", 0.7))) * 100.0), roundi((float(ch.get("cooldown_mul", 1.15)) - 1.0) * 100.0), float(ch.get("duration", 2.0))])
	if float(def.get("splash_radius", 0)) > 0.0:
		out.append("Урон по площади: %d%% врагам рядом с целью" % roundi(float(def.get("splash", 0.5)) * 100.0))
	for k in [["crit_chance", "Шанс критического удара"], ["evasion", "Уклонение"], ["lifesteal", "Вампиризм"], ["thorns", "Шипы"]]:
		if float(def.get(k[0], 0)) > 0.0:
			out.append("%s: %d%%" % [k[1], roundi(float(def[k[0]]) * 100.0)])
	return out


func _building_tip(def: Dictionary) -> String:
	var text := "%s   [%s]\n%s\nПрочность %d" % [def["name"], def.get("hotkey", ""), _cost_text(def.get("cost", {})), int(def["hp"])]
	if def.has("supply_given"):
		text += "   Лимит +%d" % int(def["supply_given"])
	if def.has("damage"):
		text += "   Урон %d, дальность %s" % [int(def["damage"]), str(def["range"])]
	if def.has("trains"):
		var names: Array = []
		for k in def["trains"]:
			names.append(String(sim.players[local_player]["data"]["units"][k]["name"]).to_lower())
		text += "\nНанимает: " + ", ".join(names)
	return text


## Подставляет в описание способности числа для её текущего ранга.
func _describe(ab: Dictionary, r: int) -> String:
	var values: Dictionary = {}
	if ab.has("effect"):
		values = sim.scaled_effect(ab["effect"], r)
		for k in values.get("mods", {}):
			values[k] = values["mods"][k]
	for part in ["aura", "self_mods"]:
		if ab.has(part):
			var mods: Dictionary = ab[part]["mods"] if part == "aura" else ab[part]
			var scaled: Dictionary = sim.scaled_mods(mods, r)
			for k in scaled:
				values[k] = scaled[k]
	var text := String(ab["description"])
	for k in values:
		if not (values[k] is float or values[k] is int):
			continue
		var v: float = float(values[k])
		var pct: int = roundi(absf(v - 1.0) * 100.0)
		if String(k) == "cooldown_mul":
			pct = roundi(absf(1.0 / maxf(v, 0.01) - 1.0) * 100.0)
		elif String(k) in ["crit_chance", "evasion", "lifesteal", "thorns"]:
			pct = roundi(v * 100.0)      # доли: 0,2 -> 20%
		text = text.replace("{%s%%}" % k, str(pct))
		text = text.replace("{%s}" % k, str(roundi(v)) if (absf(v) >= 10.0 or absf(v - roundf(v)) < 0.05) else ("%.1f" % v))
	return text


## Подсказка способности героя: текущий ранг, следующий ранг и когда он откроется.
func _ability_tip(ab: Dictionary, u: Dictionary) -> String:
	var key := String(ab["key"])
	var r: int = sim.rank(u, key)
	var index: int = (u["def"]["abilities"] as Array).find(ab)
	var head := String(ab["name"])
	if ab.get("hotkey", "") != "":
		head += "   [%s]" % ab["hotkey"]
	if ab.get("ultimate", false):
		head += "   ·   высшая"
	if String(ab["type"]) == "passive":
		head += "   ·   пассивная"
	var text := head + "\n" + ("Ранг %d из %d" % [r, Sim.MAX_RANK] if r > 0 else "Не изучена")
	if String(ab["type"]) == "active":
		text += "   ·   мана %d   ·   перезарядка %d с" % [int(ab["mana"]), roundi(sim.cooldown_of(ab, maxi(r, 1)))]
	if r > 0:
		text += "\n" + _describe(ab, r)
	if r < Sim.MAX_RANK:
		text += "\n%s %s" % ["Ранг %d:" % (r + 1) if r > 0 else "", _describe(ab, r + 1)]
		var need: int = sim.learn_level(index, r + 1)
		if int(u["level"]) < need:
			text += "\nОткроется на %d уровне героя" % need
		elif sim.skill_points(u) > 0:
			text += "\nНажмите «+», чтобы изучить (Ctrl+%s)" % ab["hotkey"] if ab.get("hotkey", "") != "" else "\nНажмите «+», чтобы изучить"
	return text.replace("\n ", "\n")


## Подсказка не должна быть шире экрана: длинные строки переносим по словам.
func _wrap(text: String, width: int = 58) -> String:
	var out: Array = []
	for line in text.split("\n"):
		var cur := ""
		for word in line.split(" "):
			if cur != "" and cur.length() + 1 + word.length() > width:
				out.append(cur)
				cur = word
			else:
				cur = word if cur == "" else cur + " " + word
		out.append(cur)
	return "\n".join(out)


## Подсказка над элементом интерфейса (rect — его место на экране).
func _show_tip(text: String, rect: Rect2) -> void:
	if text == "":
		_hide_tip()
		return
	_tip.text = _wrap(text)
	_tip_panel.reset_size()
	var sz := _tip_panel.get_combined_minimum_size()
	_tip_panel.size = sz
	var vs := get_viewport().get_visible_rect().size
	var pos := Vector2(rect.position.x + rect.size.x * 0.5 - sz.x * 0.5, rect.position.y - sz.y - 8.0)
	pos.x = clampf(pos.x, 8.0, maxf(8.0, vs.x - sz.x - 8.0))
	if pos.y < 8.0:
		pos.y = rect.end.y + 8.0
	_tip_panel.position = pos
	_tip_panel.visible = true


func _hide_tip() -> void:
	_tip_panel.visible = false


## Что сейчас показывать внизу: {kind: "unit" | "building" | "none", id}
func _subject() -> Dictionary:
	for id in selected:
		if sim.units.has(id) and sim.units[id]["hero"]:
			return {"kind": "unit", "id": id}
	if not selected.is_empty() and sim.units.has(selected[0]):
		return {"kind": "unit", "id": selected[0]}
	if sel_building >= 0 and sim.buildings.has(sel_building):
		return {"kind": "building", "id": sel_building}
	if inspect >= 0 and sim.units.has(inspect):
		return {"kind": "unit", "id": inspect}
	return {"kind": "none", "id": -1}


func _update_stats() -> void:
	var s := _subject()
	_stats.visible = String(s["kind"]) != "none"
	_stat_extra.text = ""
	var chips: Array = []
	var fx: Array = []
	_bag.visible = false
	_xp_bar.visible = false
	_mana_bar.visible = false
	if String(s["kind"]) == "unit":
		var u: Dictionary = sim.units[s["id"]]
		var d: Dictionary = u["def"]
		_portrait.texture = _icon("portrait", int(u["player"]), String(u["key"]))
		var title := "%s   ·   %s %d" % [d["name"], "герой, уровень" if u["hero"] else "уровень", int(u["level"])]
		if selected.size() > 1:
			title += "   (выбрано: %d)" % selected.size()
		elif int(u["player"]) == Sim.NEUTRAL:
			title += "   (нейтрал, награда %d" % int(u["bounty"]) + (", лагерь %d ур.)" % int(u["camp_level"]) if u.has("camp_level") else ")")
		elif int(u["player"]) != local_player:
			title += "   (враг)"
		elif u["hero"] and sim.skill_points(u) > 0:
			title += "   ·   очки навыков: %d" % sim.skill_points(u)
		_stat_name.text = title
		var hr := float(u["hp"]) / float(u["max_hp"])
		_hp_bar.set_value(hr, "%d / %d" % [ceili(float(u["hp"])), int(u["max_hp"])], _hp_color(hr))
		if float(u["max_mana"]) > 0.0:
			_mana_bar.visible = true
			_mana_bar.set_value(float(u["mana"]) / float(u["max_mana"]), "%d / %d" % [int(u["mana"]), int(u["max_mana"])])
		if u["hero"]:
			_xp_bar.visible = true
			if int(u["level"]) >= Sim.MAX_HERO_LEVEL:
				_xp_bar.set_value(1.0, "максимальный уровень")
			else:
				var need: int = sim.xp_needed(int(u["level"]))
				_xp_bar.set_value(float(u["xp"]) / float(need), "опыт %d / %d" % [int(u["xp"]), need])
			_bag.visible = true
			_update_bag(u)
		chips = _unit_chips(u)
		if sim.tick < int(u["stun"]):
			fx.append({"key": "stun", "icon": "star", "color": "#fff06a", "ratio": 0.0, "tip": "Оглушён: ещё %.1f с" % ((int(u["stun"]) - sim.tick) * Sim.TICK_DT)})
		if u["hero"] and sim.players[u["player"]].get("dragon_buff", false):
			fx.append({"key": "dragon", "icon": "fire", "color": "#ff5a1a", "ratio": 0.0, "tip": "Сила дракона (навсегда)\n%s\nЗа победу над красным драконом" % _mods_text(Sim.DRAGON_MODS)})
		if u["def"].get("undead", false):
			fx.append({"key": "undead", "icon": "skull", "color": "#6a7a6a", "ratio": 0.0, "tip": "Нежить\nПолучает в %.2f раза больше святого урона\nНочью восстанавливает %d здоровья в секунду%s" % [Sim.HOLY_VS_UNDEAD, int(Sim.NIGHT_UNDEAD_REGEN), " (сейчас ночь)" if sim.is_night() else ""]})
		for b in u["buffs"]:
			var info: Dictionary = _lookup.get(String(b["key"]), {"name": String(b["key"]), "icon": "aura", "color": "#ffffff"})
			var left: float = (int(b["until"]) - sim.tick) * Sim.TICK_DT
			var total: float = maxf(0.1, int(b.get("len", 1)) * Sim.TICK_DT)
			fx.append({"key": String(b["key"]), "icon": info["icon"], "color": info["color"], "ratio": clampf(1.0 - left / total, 0.0, 1.0),
				"tip": "%s\n%s\nОсталось %d с" % [info["name"], _mods_text(b["mods"]), ceili(left)]})
	elif String(s["kind"]) == "building":
		var b: Dictionary = sim.buildings[s["id"]]
		var d: Dictionary = b["def"]
		_portrait.texture = _icon("building", int(b["player"]), String(b["key"]))
		_stat_name.text = String(d["name"])
		var hr := float(b["hp"]) / float(b["max_hp"])
		_hp_bar.set_value(hr, "%d / %d" % [ceili(float(b["hp"])), int(b["max_hp"])], _hp_color(hr))
		if d.has("damage"):
			chips.append(_chip("blade", "#c9ced6", str(int(d["damage"])), "Урон: %d (%s)" % [int(d["damage"]), DAMAGE_NAMES.get(d.get("damage_type", ""), "")]))
			chips.append(_chip("hourglass", "#e8c23a", "%.1f с" % float(d["attack_cooldown"]), "Стреляет раз в %.2f с" % float(d["attack_cooldown"])))
		chips.append(_armor_chip(float(b["armor"]), String(b["armor_type"])))
		if d.has("range"):
			chips.append(_chip("target", "#9fd65a", "%.1f" % float(d["range"]), "Дальность стрельбы: %.1f" % float(d["range"])))
		if d.has("supply_given"):
			chips.append(_chip("plus", "#b9a77a", "+%d" % int(d["supply_given"]), "Увеличивает лимит армии на %d" % int(d["supply_given"])))
		match String(d.get("role", "")):      # нейтральные строения: что они дают и чьи они
			"capture":
				var owner := int(b.get("owner", -1))
				var who := "ничья" if owner < 0 else ("ваша" if owner == local_player else "противника")
				_stat_extra.text = "Шахта %s. +%d золота в минуту хозяину" % [who, int(d.get("income", 40))]
				if owner == local_player:
					_stat_extra.text += "  ·  следующий доход через %d с" % ceili((int(b.get("next_income", 0)) - sim.tick) * Sim.TICK_DT)
				if float(b.get("cap", 0.0)) > 0.0:
					_stat_extra.text += "\nЗахват: %d%%" % int(float(b["cap"]) / float(d.get("capture_time", 6)) * 100.0)
				elif b.get("guarded", false):
					_stat_extra.text += "\nСначала разбейте нейтралов, охраняющих шахту"
				elif owner != local_player:
					_stat_extra.text += "\nПриведите войска к шахте, пока рядом нет врагов"
			"fountain":
				_stat_extra.text = _wrap(String(d.get("description", "")), 60)
			"mercenary":
				var cd := ceili((int(b.get("hire_cd", 0)) - sim.tick) * Sim.TICK_DT)
				_stat_extra.text = "Наёмники отдыхают: %d с" % cd if cd > 0 else "Наёмники готовы. Нужен ваш юнит рядом"
			"shop":
				_stat_extra.text = "Подведите героя и купите предмет"
		if not b["done"]:
			_stat_extra.text = "Строится: %d%%" % int(float(b["progress"]) * 100.0)
		elif not (b["queue"] as Array).is_empty():
			var q: Dictionary = b["queue"][0]
			var what := "Исследуется" if q.get("research", false) else ("Воскрешается" if q.get("revive", false) else "Нанимается")
			_stat_extra.text = "%s: %d%%" % [what, int((1.0 - float(q["left"]) / float(q["total"])) * 100.0)]
	_set_chips(chips)
	_set_effects(fx)
	_update_queue(s)


func _hp_color(ratio: float) -> Color:
	return Color("#3ddc55").lerp(Color("#e8c23a"), clampf((1.0 - ratio) * 2.0, 0.0, 1.0)).lerp(Color("#e0443a"), clampf((0.5 - ratio) * 2.0, 0.0, 1.0))


func _chip(icon: String, color: String, text: String, tip: String) -> Dictionary:
	return {"icon": icon, "color": color, "text": text, "tip": tip}


func _armor_chip(armor: float, kind: String) -> Dictionary:
	var k: float = maxf(0.0, armor) * float(combat.get("armor_k", 0.06))
	return _chip("shield", "#8aa0c0", str(roundi(armor)), "Броня: %d (%s)\nСнижает урон на %d%%" % [roundi(armor), ARMOR_NAMES.get(kind, kind), roundi(k / (1.0 + k) * 100.0)])


## Характеристики юнита для панели: иконка, число и подробная подсказка.
func _unit_chips(u: Dictionary) -> Array:
	var out: Array = []
	var dmg := float(u["damage"])
	if dmg > 0.0:
		out.append(_chip("blade", "#c9ced6", str(roundi(dmg)), "Урон: %d (%s)" % [roundi(dmg), DAMAGE_NAMES.get(u["damage_type"], u["damage_type"])]))
		out.append(_chip("hourglass", "#e8c23a", "%.1f с" % float(u["attack_cooldown"]), "Скорость атаки: удар раз в %.2f с" % float(u["attack_cooldown"])))
	out.append(_armor_chip(float(u["armor"]), String(u["armor_type"])))
	out.append(_chip("boot", "#c98a3a", "%.1f" % float(u["speed"]), "Скорость бега: %.1f" % float(u["speed"])))
	if dmg > 0.0:
		out.append(_chip("target", "#9fd65a", "ближ." if float(u["range"]) < 2.0 else "%.1f" % float(u["range"]), "Дальность атаки: %s" % _range_text(float(u["range"]))))
	if float(u["hp_regen"]) > 0.0:
		out.append(_chip("regen", "#6dff7a", "+%.1f" % float(u["hp_regen"]), "Восстанавливает %.1f здоровья в секунду" % float(u["hp_regen"])))
	if float(u.get("crit", 0.0)) > 0.0:
		out.append(_chip("axe", "#c0392b", "%d%%" % roundi(float(u["crit"]) * 100.0), "Шанс критического удара: %d%%\nКритический удар наносит двойной урон" % roundi(float(u["crit"]) * 100.0)))
	if float(u.get("evasion", 0.0)) > 0.0:
		out.append(_chip("cloak", "#6a5a9a", "%d%%" % roundi(float(u["evasion"]) * 100.0), "Шанс увернуться от обычной атаки: %d%%" % roundi(float(u["evasion"]) * 100.0)))
	if float(u.get("lifesteal", 0.0)) > 0.0:
		out.append(_chip("fang", "#b0202d", "%d%%" % roundi(float(u["lifesteal"]) * 100.0), "Вампиризм: атаки лечат на %d%% нанесённого урона" % roundi(float(u["lifesteal"]) * 100.0)))
	if float(u.get("thorns", 0.0)) > 0.0:
		out.append(_chip("thorns", "#a07a4a", "%d%%" % roundi(float(u["thorns"]) * 100.0), "Шипы: бьющие вблизи получают %d%% своего урона" % roundi(float(u["thorns"]) * 100.0)))
	if float(u.get("dmg_taken", 1.0)) < 1.0:
		out.append(_chip("halo", "#fff3b0", "-%d%%" % roundi((1.0 - float(u["dmg_taken"])) * 100.0), "Получает на %d%% меньше урона" % roundi((1.0 - float(u["dmg_taken"])) * 100.0)))
	var d: Dictionary = u["def"]
	if d.has("autocast"):
		var summon: bool = String(d["autocast"].get("kind", "heal")) == "summon"
		out.append(_chip("heal", String(d["autocast"].get("color", "#9fffa0")), "×%d" % int(d["autocast"].get("max", 2)) if summon else "+%d" % int(d["autocast"].get("amount", 0)), _traits(d)[0]))
	if d.has("aura"):
		out.append(_chip("aura", "#ffd24a", "аура", "Аура (радиус %d): %s" % [int(d["aura"]["radius"]), _mods_text(d["aura"]["mods"])]))
	if d.has("chill"):
		out.append(_chip("snow", "#7fd0e8", "холод", _traits(d).filter(func(s): return String(s).begins_with("Холод"))[0]))
	if float(d.get("splash_radius", 0)) > 0.0:
		out.append(_chip("stomp", "#ff7a2a", "%d%%" % roundi(float(d.get("splash", 0.5)) * 100.0), "Урон по площади: враги рядом с целью получают %d%% урона" % roundi(float(d.get("splash", 0.5)) * 100.0)))
	if int(u["expires"]) >= 0:
		var left := ceili((int(u["expires"]) - sim.tick) * Sim.TICK_DT)
		out.append(_chip("clock", "#9fe0ff", "%d с" % left, "Призванное существо исчезнет через %d с" % left))
	return out


## Что делает эффект — для подсказки над его иконкой.
func _mods_text(mods: Dictionary) -> String:
	var parts: Array = []
	for k in mods:
		var v := float(mods[k])
		match String(k):
			"armor_add":
				parts.append("%+d к броне" % roundi(v))
			"damage_add":
				parts.append("%+d к урону" % roundi(v))
			"damage_mul":
				parts.append("урон %+d%%" % roundi((v - 1.0) * 100.0))
			"cooldown_mul":
				parts.append("атакует на %d%% %s" % [roundi(absf(1.0 / maxf(v, 0.01) - 1.0) * 100.0), "чаще" if v < 1.0 else "реже"])
			"speed_mul":
				parts.append("скорость бега %+d%%" % roundi((v - 1.0) * 100.0))
			"hp_regen":
				parts.append("%+.1f здоровья в секунду" % v)
			"mana_regen":
				parts.append("%+.1f маны в секунду" % v)
			"crit_chance":
				parts.append("шанс крит. удара %d%%" % roundi(v * 100.0))
			"evasion":
				parts.append("уклонение %d%%" % roundi(v * 100.0))
			"lifesteal":
				parts.append("вампиризм %d%%" % roundi(v * 100.0))
			"thorns":
				parts.append("шипы %d%%" % roundi(v * 100.0))
			"damage_taken_mul":
				parts.append("неуязвимость" if v <= 0.01 else "получаемый урон %+d%%" % roundi((v - 1.0) * 100.0))
	return ", ".join(parts)


func _set_chips(list: Array) -> void:
	while _chips.get_child_count() < list.size():
		var c := HBoxContainer.new()
		c.add_theme_constant_override("separation", 3)
		c.mouse_filter = Control.MOUSE_FILTER_PASS
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(22, 22)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(tr)
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 16)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(l)
		c.mouse_entered.connect(func() -> void: _show_tip(String(c.get_meta("tip", "")), c.get_global_rect()))
		c.mouse_exited.connect(_hide_tip)
		_chips.add_child(c)
	for i in _chips.get_child_count():
		var c: HBoxContainer = _chips.get_child(i)
		c.visible = i < list.size()
		if c.visible:
			var ch: Dictionary = list[i]
			(c.get_child(0) as TextureRect).texture = Icons.make(String(ch["icon"]), Color(String(ch["color"])))
			(c.get_child(1) as Label).text = String(ch["text"])
			c.set_meta("tip", ch["tip"])


## Иконки эффектов: затемнение по кругу показывает, сколько эффекта уже прошло.
func _set_effects(list: Array) -> void:
	var key := ""
	for f in list:
		key += String(f["key"]) + ","
	if key != _effects_key:
		_effects_key = key
		for c in _effects.get_children():
			_effects.remove_child(c)
			c.queue_free()
		for f in list:
			var box := TextureRect.new()
			box.custom_minimum_size = Vector2(30, 30)
			box.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			box.texture = Icons.make(String(f["icon"]), Color(String(f["color"])))
			box.mouse_entered.connect(func() -> void: _show_tip(String(box.get_meta("tip", "")), box.get_global_rect()))
			box.mouse_exited.connect(_hide_tip)
			box.add_child(W.Sweep.new())
			_effects.add_child(box)
	var nodes := _effects.get_children()
	for i in mini(nodes.size(), list.size()):
		var box: TextureRect = nodes[i]
		box.set_meta("tip", list[i]["tip"])
		(box.get_child(0) as W.Sweep).ratio = float(list[i]["ratio"])


## Заказы здания иконками; у каждого маленький крестик отмены. Панель команд при этом не двигается.
func _update_queue(s: Dictionary) -> void:
	var b = null
	var key := ""
	if String(s["kind"]) == "building" and int(sim.buildings[s["id"]]["player"]) == local_player:
		b = sim.buildings[s["id"]]
		if not b["done"]:
			key = "build:%d" % int(b["id"])
		else:
			key = "q:%d" % int(b["id"])
			for q in b["queue"]:
				key += ":" + String(q["key"])
	if key != _queue_key:
		_queue_key = key
		for c in _queue.get_children():
			_queue.remove_child(c)
			c.queue_free()
		if b != null and not b["done"]:
			_queue_slot(_icon("building", local_player, String(b["key"])), "Строится: %s\nКрестик или C — отменить, вернётся 75%% цены" % b["def"]["name"], -1)
		elif b != null:
			var data: Dictionary = sim.players[local_player]["data"]
			for i in (b["queue"] as Array).size():
				var q: Dictionary = b["queue"][i]
				if q.get("research", false):
					var up: Dictionary = data["upgrades"][q["key"]]
					_queue_slot(Icons.make(String(up["icon"]), Color(String(up["color"]))), "Исследование: %s\nКрестик — отменить, вернётся полная цена" % up["name"], i)
				else:
					_queue_slot(_icon("unit", local_player, String(q["key"])), "%s: %s\nКрестик — отменить, вернётся %s цены" % ["Воскрешение" if q.get("revive", false) else "Найм", _unit_def(local_player, String(q["key"])).get("name", ""), "половина" if q.get("revive", false) else "полная"], i)
	if b == null or _queue.get_child_count() == 0:
		return
	var first: Control = _queue.get_child(0)
	if not b["done"]:
		(first.get_meta("sweep") as W.Sweep).ratio = 1.0 - float(b["progress"])
	elif not (b["queue"] as Array).is_empty():
		var q0: Dictionary = b["queue"][0]
		(first.get_meta("sweep") as W.Sweep).ratio = clampf(float(q0["left"]) / float(q0["total"]), 0.0, 1.0)


func _queue_slot(icon: Texture2D, tip: String, index: int) -> void:
	var slot := TextureRect.new()
	slot.custom_minimum_size = Vector2(44, 44)
	slot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	slot.texture = icon
	slot.mouse_entered.connect(func() -> void: _show_tip(tip, slot.get_global_rect()))
	slot.mouse_exited.connect(_hide_tip)
	var sweep := W.Sweep.new()
	slot.add_child(sweep)
	slot.set_meta("sweep", sweep)
	if index > 0:
		slot.modulate = Color(0.8, 0.8, 0.8)
	var x := Button.new()
	x.icon = Icons.make("cancel", Color("#c8372d"))
	x.expand_icon = true
	x.focus_mode = Control.FOCUS_NONE
	x.custom_minimum_size = Vector2(22, 22)
	x.size = Vector2(22, 22)
	x.position = Vector2(26, -6)
	x.mouse_entered.connect(func() -> void: _show_tip(tip, slot.get_global_rect()))
	x.mouse_exited.connect(_hide_tip)
	x.pressed.connect(func() -> void:
		audio.play("click", -6.0)
		var cmd := {"type": "cancel", "player": local_player, "building": sel_building}
		if index >= 0:
			cmd["index"] = index
		_issue(cmd))
	slot.add_child(x)
	_queue.add_child(slot)


# ---------- сумка героя ----------

func _update_bag(u: Dictionary) -> void:
	_bag_hero = int(u["id"])
	var own := int(u["player"]) == local_player
	for i in Sim.MAX_ITEMS:
		var slot: Button = _bag.get_child(i)
		if i < (u["items"] as Array).size():
			var it: Dictionary = sim.item_def(String(u["items"][i]))
			var tex := Icons.make(String(it.get("icon", "")), Color(String(it.get("color", "#ffffff"))))
			if slot.icon != tex:
				slot.icon = tex
			slot.modulate = Color.WHITE if own else Color(0.85, 0.85, 0.85)
		elif slot.icon != null:
			slot.icon = null


func _bag_tip(i: int) -> String:
	var u = sim.units.get(_bag_hero) if sim != null else null
	if u == null:
		return ""
	if i >= (u["items"] as Array).size():
		return "Пустая ячейка сумки\nПредметы продаются в лавке торговца" if int(u["player"]) == local_player else ""
	var it: Dictionary = sim.item_def(String(u["items"][i]))
	var text := "%s\n%s" % [it["name"], it["description"]]
	if int(u["player"]) == local_player:
		text += "\n%sПКМ — выбросить или уничтожить" % ("ЛКМ — использовать,  " if it.has("use") else "")
	return text


func _bag_input(event: InputEvent, i: int) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var u = sim.units.get(_bag_hero)
	if u == null or int(u["player"]) != local_player or i >= (u["items"] as Array).size():
		return
	var it: Dictionary = sim.item_def(String(u["items"][i]))
	if event.button_index == MOUSE_BUTTON_LEFT:
		if it.has("use"):
			_issue({"type": "use_item", "player": local_player, "unit": _bag_hero, "slot": i})
			audio.play("click", -6.0)
		else:
			_say("Этот предмет действует сам, пока лежит в сумке")
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_menu_slot = i
		_item_menu.clear()
		if it.has("use"):
			_item_menu.add_item("Использовать", 0)
		_item_menu.add_item("Выбросить на землю", 1)
		_item_menu.add_item("Уничтожить", 2)
		_hide_tip()
		var r: Rect2 = (_bag.get_child(i) as Control).get_global_rect()      # меню открывается прямо над ячейкой
		_item_menu.reset_size()
		_item_menu.popup(Rect2i(Vector2i(int(r.position.x), int(r.position.y) - _item_menu.get_contents_minimum_size().y - 4), Vector2i.ZERO))
	_bag.get_child(i).accept_event()


func _item_action(id: int) -> void:
	var u = sim.units.get(_bag_hero)
	if u == null or int(u["player"]) != local_player or _menu_slot >= (u["items"] as Array).size():
		return
	var kind: String = ["use_item", "drop_item", "destroy_item"][id]
	_issue({"type": kind, "player": local_player, "unit": _bag_hero, "slot": _menu_slot})


## Панель команд зависит от того, что выбрано: герой колдует, рабочие строят, здания нанимают.
func _refresh_card() -> void:
	var key := ""
	var s := _subject()
	var hero_id := -1
	if String(s["kind"]) == "unit" and sim.units[s["id"]]["hero"] and int(sim.units[s["id"]]["player"]) == local_player:
		hero_id = int(s["id"])
		var hu: Dictionary = sim.units[hero_id]
		key = "hero:%d:%d:%s:%d" % [hero_id, int(hu["level"]), str(hu["skills"]), sim.skill_points(hu)]
	elif sel_building >= 0 and sim.buildings.has(sel_building) and String(sim.buildings[sel_building]["def"].get("role", "")) == "shop":
		key = "shop:%d" % sel_building
	elif sel_building >= 0 and sim.buildings.has(sel_building) and String(sim.buildings[sel_building]["def"].get("role", "")) == "mercenary":
		key = "merc:%d" % sel_building
	elif sel_building >= 0 and sim.buildings.has(sel_building) and int(sim.buildings[sel_building]["player"]) == local_player:
		key = "building:%d:%s:%s:%s:%s" % [sel_building, str(sim.players[local_player]["heroes"]), str(sim.players[local_player]["upgrades"]), str(sim.players[local_player]["research_wip"]), str(sim.buildings[sel_building]["done"])]
	elif not _selected_workers().is_empty():
		key = "workers"
	if key == _card_key:
		return
	_card_key = key
	_card_items.clear()
	_hide_tip()
	for c in _card.get_children():
		_card.remove_child(c)      # убираем сразу, чтобы новые кнопки встали на свои места в этом же кадре
		c.queue_free()
	var data: Dictionary = sim.players[local_player]["data"]
	if hero_id >= 0:
		var hu: Dictionary = sim.units[hero_id]
		for ab in hu["def"].get("abilities", []):
			var item := _add_card_button(Icons.make(String(ab["icon"]), Color(String(ab["color"]))), String(ab.get("hotkey", "")), _ability_tip(ab, hu), _begin_cast.bind(String(ab["key"])))
			item["ability"] = ab
			var b: Button = item["button"]
			var pips := W.Pips.new()
			pips.set_anchors_preset(Control.PRESET_FULL_RECT)
			pips.set_rank(sim.rank(hu, String(ab["key"])))
			b.add_child(pips)
			var learn := Button.new()      # «+» в углу: изучить следующий ранг
			learn.icon = Icons.make("plus", Color("#46c83a"))
			learn.expand_icon = true
			learn.focus_mode = Control.FOCUS_NONE
			learn.size = Vector2(30, 30)
			learn.position = Vector2(44, -6)
			learn.visible = sim.learn_block(hu, String(ab["key"])) == ""
			learn.pressed.connect(_learn.bind(String(ab["key"])))
			learn.mouse_entered.connect(func() -> void: _show_tip(_ability_tip(ab, sim.units[hero_id]) if sim.units.has(hero_id) else "", _card_panel.get_global_rect()))
			learn.mouse_exited.connect(_hide_tip)
			b.add_child(learn)
			item["learn"] = learn
			if sim.rank(hu, String(ab["key"])) <= 0 or String(ab["type"]) == "passive":
				b.disabled = true
			if sim.rank(hu, String(ab["key"])) <= 0:
				b.modulate = Color(0.45, 0.45, 0.5)
	elif key.begins_with("shop:"):
		for ikey in sim.buildings[sel_building]["def"].get("sells", []):
			var it: Dictionary = sim.item_def(String(ikey))
			var tip := "%s\n%d золота%s\n%s\nПокупает ваш герой, стоящий рядом с лавкой (сумка — %d ячеек)." % [it["name"], int(it["cost"]["gold"]), "   ·   расходуется" if it.has("use") else "", it["description"], Sim.MAX_ITEMS]
			_add_card_button(Icons.make(String(it["icon"]), Color(String(it["color"]))), "", tip, _buy.bind(String(ikey)), 60, it["cost"])
	elif key.begins_with("merc:"):
		var hires: Dictionary = sim.buildings[sel_building]["def"]["hires"]
		for ukey in hires:
			var def: Dictionary = neutral["units"][ukey]
			var offer: Dictionary = hires[ukey]
			var tip := "Нанять: %s   ·   %d золота, лимит %d\n" % [def["name"], int(offer["gold"]), int(offer.get("supply", 2))]
			tip += "Здоровье %d   Урон %d (%s)   Броня %d\n" % [int(def["hp"]), int(def["damage"]), DAMAGE_NAMES.get(def["damage_type"], ""), int(def["armor"])]
			for line in _traits(def):
				tip += "• %s\n" % line
			tip += "Нужен любой ваш юнит рядом с лагерем. После найма лагерь отдыхает %d с." % int(sim.buildings[sel_building]["def"].get("hire_cooldown", 20))
			_add_card_button(_icon("unit", local_player, String(ukey)), "", tip, _hire.bind(String(ukey)), 72, offer)
	elif key == "workers":
		for bkey in data["buildings"]:
			var def: Dictionary = data["buildings"][bkey]
			_add_card_button(_icon("building", local_player, String(bkey)), String(def.get("hotkey", "")), _building_tip(def), _begin_place.bind(String(bkey)), 72, def.get("cost", {}))
	elif key != "":
		var cur: Dictionary = sim.buildings[sel_building]
		for ukey in (cur["def"].get("trains", []) if cur["done"] else []):
			var def: Dictionary = data["units"][ukey]
			var lock := ""
			var my_tier: int = sim.tier(local_player)
			if int(def.get("tier", 1)) > my_tier:
				lock = "ЗАКРЫТО: нужно улучшить главное здание (%s)\n" % String(data["buildings"]["hall"]["name"]).to_lower()
			elif def.get("hero", false) and not sim.players[local_player]["heroes"].has(ukey) and (sim.players[local_player]["heroes"] as Dictionary).size() >= my_tier:
				lock = "ЗАКРЫТО: для второго героя улучшите главное здание (%s)\n" % String(data["buildings"]["hall"]["name"]).to_lower()
			var ucost: Dictionary = def.get("cost", {})
			var hstate = sim.players[local_player]["heroes"].get(ukey)
			if def.get("hero", false) and hstate != null and String(hstate["state"]) == "dead":
				ucost = {"gold": int(ucost.get("gold", 0)) / 2, "wood": int(ucost.get("wood", 0)) / 2}     # воскрешение за полцены
			var uitem := _add_card_button(_icon("unit", local_player, String(ukey)), String(def.get("hotkey", "")), lock + _unit_tip(def, String(ukey)), _train.bind(String(ukey)), 72, ucost)
			if lock != "":
				(uitem["button"] as Button).modulate = Color(0.45, 0.45, 0.45)
		for rkey in (cur["def"].get("researches", []) if cur["done"] else []):
			var up: Dictionary = data["upgrades"][rkey]
			var lvl: int = int(sim.players[local_player]["upgrades"].get(rkey, 0))
			var tip := "%s   ·   уровень %d из %d   [%s]\n" % [up["name"], lvl, int(up["max"]), up.get("hotkey", "")]
			if lvl >= int(up["max"]):
				tip += "Изучено полностью\n"
			elif sim.players[local_player]["research_wip"].has(rkey):
				tip += "Исследуется...\n"
			else:
				tip += "Следующий уровень: %s\n" % _cost_text(sim.upgrade_cost(local_player, String(rkey)))
			tip += String(up["description"])
			var item := _add_card_button(Icons.make(String(up["icon"]), Color(String(up["color"]))), String(up.get("hotkey", "")), tip, _research.bind(String(rkey)), 72, {} if lvl >= int(up["max"]) else sim.upgrade_cost(local_player, String(rkey)))
			(item["cd"] as Label).text = str(lvl) if lvl > 0 else ""
			(item["button"] as Button).disabled = lvl >= int(up["max"])
	_card_panel.visible = not _card_items.is_empty()


func _add_card_button(icon: Texture2D, hotkey: String, tip: String, action: Callable, px: int = 72, cost: Dictionary = {}) -> Dictionary:
	var b := Button.new()
	b.custom_minimum_size = Vector2(px, px)
	b.icon = icon
	b.expand_icon = true
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	b.pressed.connect(func() -> void: audio.play("click", -6.0))
	b.mouse_entered.connect(func() -> void: _show_tip(tip, _card_panel.get_global_rect()))
	b.mouse_exited.connect(_hide_tip)
	var sweep := W.Sweep.new()
	b.add_child(sweep)
	var k := Label.new()
	k.text = hotkey
	k.position = Vector2(5, 1)
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	k.add_theme_color_override("font_color", Color("#ffd24a"))
	_outlined(k, 15)
	b.add_child(k)
	var cd := Label.new()
	cd.set_anchors_preset(Control.PRESET_FULL_RECT)
	cd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cd.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outlined(cd, 26)
	b.add_child(cd)
	if not cost.is_empty():      # цена видна сразу, без наведения курсора
		var price := HBoxContainer.new()
		price.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		price.offset_top = -19
		price.offset_bottom = -1
		price.add_theme_constant_override("separation", 3)
		price.alignment = BoxContainer.ALIGNMENT_CENTER
		price.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for part in [["gold", Color("#ffd94a")], ["wood", Color("#8fe36a")]]:
			if int(cost.get(part[0], 0)) > 0:
				var pl := Label.new()
				pl.text = str(int(cost[part[0]]))
				pl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				pl.add_theme_color_override("font_color", part[1])
				_outlined(pl, 13 if px < 70 else 14)
				pl.add_theme_constant_override("outline_size", 5)
				price.add_child(pl)
		b.add_child(price)
	_card.add_child(b)
	var item := {"hotkey": hotkey, "action": action, "button": b, "cd": cd, "sweep": sweep, "ability": null, "learn": null}
	_card_items.append(item)
	return item


## Кнопки заклинаний: круговая перезарядка, нехватка маны, «+» для изучения.
func _update_ability_buttons() -> void:
	var s := _subject()
	if String(s["kind"]) != "unit" or not sim.units.has(s["id"]):
		return
	var u: Dictionary = sim.units[s["id"]]
	for item in _card_items:
		var ab = item["ability"]
		if ab == null:
			continue
		var r: int = sim.rank(u, String(ab["key"]))
		if item["learn"] != null:
			(item["learn"] as Button).visible = sim.learn_block(u, String(ab["key"])) == ""
		if String(ab["type"]) != "active" or r <= 0:
			continue
		var b: Button = item["button"]
		var left: float = (int(u["cds"].get(ab["key"], 0)) - sim.tick) * Sim.TICK_DT
		(item["cd"] as Label).text = str(ceili(left)) if left > 0.0 else ""
		(item["sweep"] as W.Sweep).ratio = clampf(left / maxf(0.1, sim.cooldown_of(ab, r)), 0.0, 1.0)
		b.disabled = left > 0.0
		b.modulate = Color(0.55, 0.6, 1.0) if float(u["mana"]) < float(ab["mana"]) and left <= 0.0 else Color.WHITE


func _learn(key: String) -> void:
	var s := _subject()
	if String(s["kind"]) == "unit" and sim.units[s["id"]]["hero"] and int(sim.units[s["id"]]["player"]) == local_player:
		_issue({"type": "learn", "player": local_player, "unit": s["id"], "ability": key})
		audio.play("click", -6.0)


func _train(unit_key: String) -> void:
	if sel_building >= 0:
		_issue({"type": "train", "player": local_player, "building": sel_building, "unit": unit_key})


## Покупка предмета ближайшим к лавке героем.
func _buy(item_key: String) -> void:
	if sel_building < 0 or not sim.buildings.has(sel_building):
		return
	var shop_pos: Vector2 = sim.buildings[sel_building]["pos"]
	var best := -1
	var best_d := Sim.SHOP_RANGE
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if int(u["player"]) == local_player and u["hero"] and (u["pos"] as Vector2).distance_to(shop_pos) <= best_d:
			best_d = (u["pos"] as Vector2).distance_to(shop_pos)
			best = int(id)
	if best < 0:
		_say("Подведите героя к лавке")
		audio.play("error", -8.0)
		return
	_issue({"type": "buy", "player": local_player, "unit": best, "shop": sel_building, "item": item_key})


func _hire(unit_key: String) -> void:
	if sel_building >= 0:
		_issue({"type": "hire", "player": local_player, "building": sel_building, "unit": unit_key})


func _cancel() -> void:
	if sel_building >= 0:
		_issue({"type": "cancel", "player": local_player, "building": sel_building})


func _research(upgrade_key: String) -> void:
	if sel_building >= 0:
		_issue({"type": "research", "player": local_player, "building": sel_building, "upgrade": upgrade_key})


func _idle_workers() -> Array:
	var out: Array = []
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if int(u["player"]) == local_player and sim.is_worker(u) and String(u["order"].get("type", "idle")) == "idle":
			out.append(int(id))
	out.sort()
	return out


func _next_idle_worker() -> void:
	var idle := _idle_workers()
	if idle.is_empty():
		return
	var pick: int = idle[0]
	for id in idle:      # каждый раз следующий по кругу
		if not selected.is_empty() and id > int(selected[0]):
			pick = id
			break
	selected = [pick]
	sel_building = -1
	inspect = -1
	_focus(sim.units[pick]["pos"])


func _focus(pos: Vector2) -> void:
	_rig.position = Vector3(pos.x, 0, pos.y + _zoom * 0.08)


func _begin_cast(key: String) -> void:
	var s := _subject()
	if String(s["kind"]) != "unit":
		return
	var u: Dictionary = sim.units[s["id"]]
	var ab = sim.ability(u, key)
	if ab == null or String(ab["type"]) != "active" or int(u["player"]) != local_player:
		return
	_placing = ""
	if String(ab["target"]) == "none":
		_issue({"type": "cast", "player": local_player, "unit": u["id"], "ability": key})
	else:
		_casting = {"unit": int(u["id"]), "ability": ab}


func _finish_cast(screen: Vector2) -> void:
	var ab: Dictionary = _casting["ability"]
	var cmd := {"type": "cast", "player": local_player, "unit": _casting["unit"], "ability": ab["key"]}
	var hit = _ground_point(screen)
	var ground := Vector2.ZERO if hit == null else Vector2(hit.x, hit.z)
	match String(ab["target"]):
		"unit_ally":
			cmd["target"] = _unit_at(screen, true)
		"unit_enemy":
			cmd["target"] = _foe_at(screen, ground)
		"point":
			cmd["pos"] = ground
	if cmd.has("target") and int(cmd["target"]) < 0:
		_say("Нужно указать юнита")
		return
	_issue(cmd)
	if cmd.has("target"):
		_mark_entity(int(cmd["target"]), Color(String(ab["color"])))
	else:
		_ping(ground, Color(String(ab["color"])))
	_casting = {}


# =====================================================================
#  КАЖДЫЙ КАДР
# =====================================================================

func _process(delta: float) -> void:
	if _test.has("server"):
		return      # выделенный серверу игровой цикл не нужен: он только пересылает команды
	if sim == null:
		if not _test.is_empty():
			_run_test()
		return
	if not _paused:
		_time += delta
		_acc += delta * (speed if net_mode == "" else 1.0)
		while _acc >= Sim.TICK_DT:
			if net_mode != "" and not _net_turn():
				_acc = minf(_acc, Sim.TICK_DT)      # ждём команды второго игрока
				break
			_acc -= Sim.TICK_DT
			sim.step()
			_consume_events()
			for ai in ais:      # каждый компьютер думает раз в секунду, но в свой тик — без общих рывков
				if (sim.tick + int(ai.me) * 3) % 10 == 0:
					ai.think()
			for wid in views:
				var wu: Dictionary = sim.units[wid] if sim.units.has(wid) else {}
				if not wu.is_empty() and wu["busy"] and float(wu["swing"]) < 0.0 and sim.is_worker(wu) and (sim.tick + int(wid) * 3) % 8 == 0:
					_sfx("chop", wu["pos"], -10.0)
					var tid = wu["order"].get("target", -1)
					if String(wu["order"].get("type")) == "gather" and String(wu["order"].get("kind")) == "tree" and rviews.has(tid):
						var tree: Node3D = rviews[tid]      # дерево вздрагивает от удара
						var tw := create_tween()
						tw.tween_property(tree, "rotation:z", 0.07, 0.06)
						tw.tween_property(tree, "rotation:z", 0.0, 0.25).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
		_update_camera(delta)
		fog.update(sim, local_player, delta)
		_update_views(delta)
		_update_projectiles()
		_update_ghost()
		_update_hud(delta)
		_update_presentation()
		_bars.queue_redraw()
		_mini_redraw -= delta
		if _mini_redraw <= 0.0:      # мини-карта обновляется 15 раз в секунду, а не каждый кадр
			_mini_redraw = 1.0 / 15.0
			_mini.queue_redraw()
	if not _test.is_empty():
		_run_test()


## Симуляция сообщает, что изменилось; здесь под это подстраивается картинка.
func _consume_events() -> void:
	var batch: Array = sim.events.duplicate()
	sim.events.clear()       # очередь очищается сразу: сбой в одном событии не должен повторяться вечно
	for e in batch:
		match String(e["type"]):
			"unit_added":
				if sim.units.has(e["id"]):
					_make_unit_view(sim.units[e["id"]])
			"building_added":
				if sim.buildings.has(e["id"]):
					_make_building_view(sim.buildings[e["id"]])
			"building_removed":
				if bviews.has(e["id"]):
					_sfx("crash", Vector2((bviews[e["id"]] as Node3D).position.x, (bviews[e["id"]] as Node3D).position.z), 0.0)
					_collapse(bviews[e["id"]])
					bviews.erase(e["id"])
				if sel_building == int(e["id"]):
					sel_building = -1
			"resource_removed":
				_mini_dirty = true
				if rviews.has(e["id"]):
					_fell(rviews[e["id"]])
					rviews.erase(e["id"])
			"loot_added":
				_make_loot_view(int(e["id"]))
			"captured":      # шахта гоблинов сменила хозяина: перекрашиваем
				if bviews.has(e["id"]) and sim.buildings.has(e["id"]):
					(bviews[e["id"]] as Node3D).queue_free()
					bviews.erase(e["id"])
					_make_building_view(sim.buildings[e["id"]])
					_ring_fx(sim.buildings[e["id"]]["pos"], 3.0, _team(int(e["player"])))
					audio.play("done", -4.0)
			"loot_removed":
				if lviews.has(e["id"]):
					(lviews[e["id"]] as Node3D).queue_free()
					lviews.erase(e["id"])
			"picked":
				if int(e["player"]) == local_player:
					audio.play("gold", -6.0)
					_say("Подобрано: %s" % String(sim.item_def(String(e["item"])).get("name", "")).to_lower())
			"learned":
				if int(e["player"]) == local_player:
					audio.play("levelup", -10.0)
					if views.has(e["id"]):
						_ring_fx(sim.units[e["id"]]["pos"], 1.4, Color("#ffd24a"))
			"beam":
				if fog.visible_at(e["from"]) or fog.visible_at(e["to"]):
					_beam(e["from"], e["to"], Color(String(e["color"])))
			"attack":
				if views.has(e["id"]):
					views[e["id"]]["atk_t"] = 0.0
					views[e["id"]]["atk_len"] = float(e["windup"]) / 0.5
					var au: Dictionary = sim.units.get(e["id"], {})
					if au.is_empty():
						pass      # юнит успел погибнуть в этом же тике
					elif String(au["def"].get("projectile", "")) == "bullet":
						_sfx("shot", au["pos"], -5.0)
					elif float(au["range"]) > 2.0:
						_sfx("magic" if String(au["damage_type"]) == "magic" else "arrow", au["pos"], -6.0)
					else:
						_sfx("sword" if String(au["def"]["model"].get("weapon", "")) in ["sword", "spear", "lance", "hammer"] else "hit", au["pos"], -9.0)
			"cast":
				if views.has(e["id"]):
					var v: Dictionary = views[e["id"]]
					v["atk_t"] = 0.0
					v["atk_len"] = 0.8
					v["style"] = "smash" if String(e["key"]) in ["stomp", "leap", "rampage"] else "cast"
			"blast":
				if fog.visible_at(e["pos"]):
					_ring_fx(e["pos"], float(e["radius"]), Color(String(e["color"])))
					_sfx("spell", e["pos"], -3.0)
			"building_done":
				if sim.buildings.has(e["id"]) and int(sim.buildings[e["id"]]["player"]) == local_player:
					audio.play("done", -6.0)
			"bought":
				if int(e["player"]) == local_player:
					audio.play("gold", -4.0)
					if e.has("hired"):
						_say("Нанят: %s" % String(e["hired"]).to_lower())
					else:
						_say("Куплено: %s" % String(sim.players[Sim.NEUTRAL]["data"]["items"][e["item"]]["name"]).to_lower())
			"research_done":
				if int(e["player"]) == local_player:
					audio.play("done", -6.0)
			"float":
				if int(e.get("player", local_player)) == local_player and fog.visible_at(e["pos"]):
					floaters.append({"pos": _at(e["pos"], 1.6), "text": String(e["text"]), "t": 0.0, "color": Color(String(e["color"]))})
				if String(e["text"]).begins_with("+"):
					_sfx("heal", e["pos"], -4.0)
			"levelup":
				if fog.visible_at(e["pos"]):
					_ring_fx(e["pos"], 2.2, Color("#ffd24a"))
				if int(e["player"]) == local_player:
					floaters.append({"pos": _at(e["pos"], 2.4), "text": "Уровень %d!" % int(e["level"]), "t": 0.0, "color": Color("#ffd24a")})
					audio.play("levelup", -5.0)
			"hit":
				var hte = sim.entity(int(e["id"]))
				if hte != null and fog.visible_at(hte["pos"]):
					_spark(int(e["id"]))
				var ht = sim.entity(int(e["id"]))
				if ht != null:
					_sfx("hit", ht["pos"], -12.0)
					if int(ht["player"]) == local_player:
						_alert(ht["pos"])
			"death":
				_deaths += 1
				if views.has(e["id"]):
					_sfx("death", Vector2((views[e["id"]]["node"] as Node3D).position.x, (views[e["id"]]["node"] as Node3D).position.z), -6.0)
				selected.erase(e["id"])
				if inspect == int(e["id"]):
					inspect = -1
				if views.has(e["id"]):
					var v: Dictionary = views[e["id"]]
					(v["ring"] as Node3D).visible = false
					(v["fx"] as Node3D).visible = false
					corpses.append({"node": v["node"], "parts": v["parts"], "t": 0.0})
					views.erase(e["id"])
			"bounty":
				if int(e["player"]) == local_player:
					floaters.append({"pos": _at(e["pos"], 1.6), "text": "+%d" % int(e["amount"]), "t": 0.0, "color": Color("#ffd940")})
					audio.play("gold", -6.0)
			"msg":
				if int(e["player"]) == local_player:
					_say(String(e["text"]))
					if String(e["text"]).begins_with("Из лагеря"):
						audio.play("done", -6.0)
					elif not String(e["text"]).begins_with("Исследовано"):
						audio.play("error", -8.0)
			"defeated":
				if int(e["player"]) == local_player:
					_banner.text = "Поражение"
					_banner.add_theme_color_override("font_color", Color("#ff6a5a"))
					_banner.visible = true
					audio.play("defeat")
					if net_mode != "":
						online.send_result(false)
					_show_results(false)
				else:
					_say("%s выбывает из игры" % _player_name(int(e["player"])))
			"game_over":
				if int(e["winner"]) == local_player or ((e.get("winners", []) as Array).has(local_player) and not sim.players[local_player].get("defeated", false)):
					_banner.text = "Победа!" if (e.get("winners", []) as Array).size() <= 1 else "Победа команды!"
					_banner.add_theme_color_override("font_color", Color("#ffd24a"))
					_banner.visible = true
					audio.play("victory")
					if net_mode != "":
						online.send_result(true)
					_show_results(true)
			"gift":      # союзники передали ресурсы
				var what := []
				if int(e["gold"]) > 0:
					what.append("%d золота" % int(e["gold"]))
				if int(e["wood"]) > 0:
					what.append("%d дерева" % int(e["wood"]))
				if int(e["to"]) == local_player:
					_feed_line("%s передаёт вам %s" % [_player_name(int(e["from"])), " и ".join(what)], Color("#ffd940"))
					audio.play("gold", -4.0)
				elif int(e["from"]) == local_player:
					_feed_line("Вы передали %s: %s" % [_player_name(int(e["to"])), " и ".join(what)], Color("#ffe9a0"))
			"rune_added":
				_make_rune_view(int(e["id"]))
			"rune_taken":
				if runeviews.has(e["id"]):
					(runeviews[e["id"]] as Node3D).queue_free()
					runeviews.erase(e["id"])
				if int(e["player"]) == local_player:
					audio.play("levelup", -6.0)
				elif sim.allies(int(e["player"]), local_player):
					_feed_line("%s берёт: %s" % [_player_name(int(e["player"])), String(Sim.RUNE_INFO[e["kind"]]["name"]).to_lower()], Color(String(Sim.RUNE_INFO[e["kind"]]["color"])))
			"camp_spawned":      # новый лагерь нейтралов: метка на мини-карте
				_mini_pings.append({"pos": e["pos"], "t": 0.0, "color": Color("#e8b03a")})
			"boss_slain":
				_ring_fx(e["pos"], 6.0, Color("#ff5a1a"))
				audio.play("victory" if int(e["player"]) == local_player else "horn", -4.0)


## Звук из точки на карте: чем дальше от камеры, тем тише; совсем далёкие не слышны.
func _sfx(sound: String, pos: Vector2, gain: float = 0.0) -> void:
	if fog != null and not fog.visible_at(pos):
		return      # что происходит в тумане, не слышно
	var d := pos.distance_to(Vector2(_rig.position.x, _rig.position.z))
	if d < 34.0:
		audio.play(sound, gain - d * 0.55 - (_zoom - 19.0) * 0.25)


## Тревога, если бьют наших там, куда игрок сейчас не смотрит.
func _alert(pos: Vector2) -> void:
	if _time - _alert_time < 12.0 or pos.distance_to(Vector2(_rig.position.x, _rig.position.z)) < 16.0:
		return
	_alert_time = _time
	_say("Нас атакуют!")
	audio.play("horn", -4.0)
	_mini_pings.append({"pos": pos, "t": 0.0})


func _say(text: String) -> void:
	_msg.text = text
	_msg_time = 2.5


func _spark(id: int) -> void:
	var t = sim.entity(id)
	if t == null:
		return
	var s := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.12
	m.height = 0.24
	m.radial_segments = 5
	m.rings = 2
	s.mesh = m
	s.material_override = _flat(Color("#fff3b0"))
	s.position = _at(t["pos"], 0.9 if not t["is_building"] else 1.2) + Vector3(randf_range(-0.2, 0.2), randf_range(-0.2, 0.2), randf_range(-0.2, 0.2))
	add_child(s)
	var tw := create_tween()
	tw.tween_property(s, "scale", Vector3.ONE * 2.2, 0.12)
	tw.tween_property(s, "scale", Vector3.ZERO, 0.1)
	tw.tween_callback(s.queue_free)


## Расходящееся кольцо: взрыв, лечение, клич, призыв.
func _ring_fx(pos: Vector2, radius: float, color: Color) -> void:
	for i in 2:
		var ring := _torus(1.0, clampf(0.16 / maxf(radius, 0.5), 0.02, 0.2), color, 32)
		ring.material_override = _flat(Color(color.r, color.g, color.b, 0.9), true)
		ring.position = _at(pos, 0.2 + i * 0.5)
		ring.scale = Vector3(0.2, 0.3, 0.2)
		add_child(ring)
		var tw := create_tween()
		tw.tween_interval(i * 0.08)
		tw.tween_property(ring, "scale", Vector3(radius, 0.3, radius), 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(ring.material_override, "albedo_color:a", 0.0, 0.3)
		tw.tween_callback(ring.queue_free)


func _collapse(node: Node3D) -> void:
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector3(1.05, 0.05, 1.05), 0.6)
	tw.tween_callback(node.queue_free)


## Срубленное дерево не исчезает мгновенно: падает набок и уходит в землю.
func _fell(node: Node3D) -> void:
	var dir := randf() * TAU
	var tw := create_tween()
	tw.tween_property(node, "rotation", Vector3(sin(dir) * 1.45, node.rotation.y, cos(dir) * 1.45), 1.1).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_interval(1.2)
	tw.tween_property(node, "position:y", node.position.y - 1.2, 1.4)
	tw.parallel().tween_property(node, "scale", Vector3.ONE * 0.4, 1.4)
	tw.tween_callback(node.queue_free)
	_sfx("crash", Vector2(node.position.x, node.position.z), -10.0)


## Молния между двумя точками: вспыхивает и гаснет.
func _beam(from: Vector2, to: Vector2, color: Color) -> void:
	if from.distance_to(to) < 0.3:
		return      # лечение самого себя: линия не нужна, хватит вспышки
	var a := _at(from, 1.3)
	var b := _at(to, 1.0)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(0.09, 0.09, maxf(0.1, a.distance_to(b)))
	mi.mesh = m
	mi.material_override = _flat(Color(color.r, color.g, color.b, 1.0), true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.position = (a + b) * 0.5
	if a.distance_to(b) > 0.05:
		mi.look_at(b, Vector3.UP)
	var tw := create_tween()
	tw.tween_property(mi.material_override, "albedo_color:a", 0.0, 0.35)
	tw.tween_callback(mi.queue_free)
	_sfx("magic", to, -4.0)


## Предмет на земле: мешочек цвета предмета со светящимся кольцом.
func _make_loot_view(id: int) -> void:
	if not sim.loot.has(id) or lviews.has(id):
		return
	var it: Dictionary = sim.item_def(String(sim.loot[id]["key"]))
	var c := Color(String(it.get("color", "#ffd24a")))
	var n := Node3D.new()
	Models.ball(n, 0.24, Vector3(0, 0.22, 0), Color("#8a6a3a"), Vector3(1, 0.85, 1))
	Models.cyl(n, 0.05, 0.12, 0.14, Vector3(0, 0.46, 0), Color("#6a4a26"))
	Models.ball(n, 0.1, Vector3(0, 0.62, 0), c, Vector3.ONE, true)
	var ring := _torus(0.42, 0.05, c, 20)
	ring.position.y = 0.05
	ring.scale.y = 0.2
	n.add_child(ring)
	n.position = _at(sim.loot[id]["pos"])
	add_child(n)
	lviews[id] = n


## Руна силы: парящий светящийся кристалл над каменной плитой.
func _make_rune_view(id: int) -> void:
	if not sim.runes.has(id) or runeviews.has(id):
		return
	var c := Color(String(Sim.RUNE_INFO[sim.runes[id]["kind"]]["color"]))
	var n := Node3D.new()
	Models.cyl(n, 0.55, 0.62, 0.1, Vector3(0, 0.05, 0), Models.STONE.darkened(0.1), 8)
	var gem := Node3D.new()
	gem.name = "Gem"
	gem.position.y = 0.9
	n.add_child(gem)
	Models.cyl(gem, 0.0, 0.26, 0.4, Vector3(0, 0.2, 0), c, 4, Vector3.ZERO, true)
	Models.cyl(gem, 0.26, 0.0, 0.4, Vector3(0, -0.2, 0), c.darkened(0.15), 4, Vector3.ZERO, true)
	var ring := _torus(0.5, 0.05, c, 24)
	ring.position.y = 0.12
	ring.scale.y = 0.2
	n.add_child(ring)
	n.position = _at(sim.runes[id]["pos"])
	add_child(n)
	runeviews[id] = n


func _update_views(delta: float) -> void:
	var alpha := _acc / Sim.TICK_DT
	var feet: Array = []
	var eye := Vector2(_rig.position.x, _rig.position.z)
	var far_sq := pow(28.0 + _zoom * 1.6, 2.0)      # дальше этого юнитов не видно: их не анимируем
	for id in views:
		if not sim.units.has(id):
			continue
		var u: Dictionary = sim.units[id]
		var v: Dictionary = views[id]
		var node: Node3D = v["node"]
		var seen := _seen(u)      # в тумане чужих юнитов не видно
		if node.visible != seen:
			node.visible = seen
		v["far"] = not seen or (u["pos"] as Vector2).distance_squared_to(eye) > far_sq
		if v["far"]:
			continue
		var p: Vector2 = (u["prev_pos"] as Vector2).lerp(u["pos"], alpha)
		feet.append(p)
		var step: Vector2 = u["pos"] - u["prev_pos"]
		var moving := step.length() > 0.02
		var facing: Vector2 = u["facing"]
		node.rotation.y = lerp_angle(node.rotation.y, atan2(facing.x, facing.y), minf(1.0, delta * 12.0))
		node.position = _at(p)
		var stunned: bool = sim.tick < int(u["stun"])
		var working: bool = u["busy"] and float(u["swing"]) < 0.0 and sim.is_worker(u)
		Anim.animate(v, moving, float(u["speed"]), working, 0.0 if stunned else delta, _time)
		(v["ring"] as Node3D).visible = selected.has(id) or id == inspect
		((v["ring"] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color = Color("#3cff5a") if int(u["player"]) == local_player else Color("#ff5a4a")
		var fx: MeshInstance3D = v["fx"]
		var buffs: Array = u["buffs"]
		fx.visible = stunned or not buffs.is_empty()
		if fx.visible:
			var slowed := false
			for b in buffs:
				if float(b["mods"].get("speed_mul", 1.0)) < 1.0:
					slowed = true
			(fx.material_override as StandardMaterial3D).albedo_color = Color("#fff06a") if stunned else (Color("#7fd6ff") if slowed else Color("#ff9a3a"))
			fx.rotation.y = _time * 3.0
		var parts: Dictionary = v["parts"]
		if parts["gold"] != null:
			var carrying: bool = int(u["carry"]) > 0
			(parts["gold"] as Node3D).visible = carrying and u["carry_kind"] == "gold"
			(parts["wood"] as Node3D).visible = carrying and u["carry_kind"] == "wood"
	terrain.trample(feet)
	if inspect >= 0 and sim.units.has(inspect) and not _seen(sim.units[inspect]):
		inspect = -1      # рассматриваемый чужой юнит ушёл в туман
	for id in lviews:
		if sim.loot.has(id):
			(lviews[id] as Node3D).visible = fog.visible_at(sim.loot[id]["pos"])
	for id in runeviews:      # руны парят и вращаются
		var rn: Node3D = runeviews[id]
		rn.visible = sim.runes.has(id) and fog.visible_at(sim.runes[id]["pos"])
		var gem: Node3D = rn.get_node("Gem")
		gem.rotation.y = _time * 1.6
		gem.position.y = 0.9 + sin(_time * 2.2 + float(id)) * 0.12
	_update_daylight()
	for id in bviews:
		var b: Dictionary = sim.buildings[id]
		var bseen := _building_seen(b)
		if (bviews[id] as Node3D).visible != bseen:
			(bviews[id] as Node3D).visible = bseen
		var grown: float = 1.15 if String(b["def"].get("role", "")) == "hall" and sim.tier(int(b["player"])) > 1 else 1.0
		(bviews[id] as Node3D).scale = Vector3(grown, grown * (1.0 if b["done"] else lerpf(0.12, 1.0, float(b["progress"]))), grown)
	var keep: Array = []
	for c in corpses:
		if Anim.die(c, delta):
			(c["node"] as Node3D).queue_free()
		else:
			keep.append(c)
	corpses = keep
	_sel_ring.visible = sel_building >= 0 and sim.buildings.has(sel_building)
	if _sel_ring.visible:
		var sb: Dictionary = sim.buildings[sel_building]
		_sel_ring.position = _at(sb["pos"], 0.15)
		_sel_ring.scale = Vector3(float(sb["size"]) * 0.78, 0.25, float(sb["size"]) * 0.78)
	_range_ring.visible = not _casting.is_empty() and sim.units.has(_casting.get("unit", -1))
	if _range_ring.visible:
		var r: float = float(_casting["ability"]["range"]) + float(sim.units[_casting["unit"]]["radius"])
		_range_ring.position = _at(sim.units[_casting["unit"]]["pos"], 0.25)
		_range_ring.scale = Vector3(r, 1.0, r)
	elif not _casting.is_empty():
		_casting = {}


func _update_projectiles() -> void:
	var alpha := _acc / Sim.TICK_DT
	for id in pviews.keys():
		if not sim.projectiles.has(id):
			(pviews[id] as Node3D).queue_free()
			pviews.erase(id)
	for id in sim.projectiles:
		var p: Dictionary = sim.projectiles[id]
		if not pviews.has(id):
			var n := Node3D.new()
			match String(p["kind"]):
				"arrow":
					Models.box(n, Vector3(0.03, 0.03, 0.55), Vector3.ZERO, Models.WOOD)
					Models.cyl(n, 0.0, 0.045, 0.14, Vector3(0, 0, 0.32), Models.STEEL, 4, Vector3(PI / 2, 0, 0))
					Models.box(n, Vector3(0.1, 0.01, 0.12), Vector3(0, 0, -0.24), Color.WHITE)
				"fireball":
					Models.ball(n, 0.3, Vector3.ZERO, Color("#ff7a2a"), Vector3.ONE, true)
					Models.ball(n, 0.18, Vector3(0, 0, 0.12), Color("#ffe07a"), Vector3.ONE, true)
					Models.ball(n, 0.2, Vector3(0, 0, -0.3), Color("#ff4a1a"), Vector3.ONE, true)
				"magic":
					Models.ball(n, 0.17, Vector3.ZERO, Color("#8fd0ff"), Vector3.ONE, true)
					Models.ball(n, 0.1, Vector3(0, 0, -0.2), Color("#5a8cff"), Vector3.ONE, true)
				"bullet":      # пуля с огненным следом
					Models.ball(n, 0.06, Vector3.ZERO, Color("#ffe08a"), Vector3.ONE, true)
					Models.box(n, Vector3(0.03, 0.03, 0.5), Vector3(0, 0, -0.28), Color("#ffb03a"), Vector3.ZERO, true)
				_:
					Models.ball(n, 0.2, Vector3.ZERO, Models.STONE, Vector3(1, 0.85, 0.95))
			add_child(n)
			pviews[id] = n
		var pos: Vector2 = (p["prev_pos"] as Vector2).lerp(p["pos"], alpha)
		var total: float = maxf(0.1, (p["start"] as Vector2).distance_to(p["tpos"]))
		var k: float = clampf((p["start"] as Vector2).distance_to(pos) / total, 0.0, 1.0)
		var arc: float = (2.0 if p["kind"] == "rock" else 0.5) * minf(1.0, total / 6.0)
		var from_y: float = terrain.height(p["start"]) + float(p["height"])
		var to_y: float = terrain.height(p["tpos"]) + 0.8
		var here := Vector3(pos.x, lerpf(from_y, to_y, k) + sin(k * PI) * arc, pos.y)
		var node: Node3D = pviews[id]
		node.visible = fog.visible_at(pos)
		if here.distance_to(node.position) > 0.01 and node.position != Vector3.ZERO:
			node.look_at(node.position + (node.position - here), Vector3.UP)
		node.position = here


func _update_camera(delta: float) -> void:
	var dir := Vector2.ZERO
	var typing := _chat_edit != null and _chat_edit.visible      # пока пишем в чат, WASD — это буквы
	if not typing:
		if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): dir.x -= 1
		if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): dir.x += 1
		if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): dir.y -= 1
		if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): dir.y += 1
	var win := get_window()
	if win.has_focus() and _mouse_in and _test.is_empty() and not _dragging and not _mmb_drag:
		# координаты мыши и размер берём в одной системе — в кадре игры (в браузере пиксели окна другие)
		var m := get_viewport().get_mouse_position()
		var sz := get_viewport().get_visible_rect().size
		if Rect2(Vector2.ZERO, sz).has_point(m):
			if m.x < EDGE: dir.x -= 1
			if m.x > sz.x - EDGE: dir.x += 1
			if m.y < EDGE: dir.y -= 1
			if m.y > sz.y - EDGE: dir.y += 1
	if dir != Vector2.ZERO:
		dir = dir.normalized() * PAN_SPEED * (_zoom / 26.0) * delta
		_rig.position.x = clampf(_rig.position.x + dir.x, 0, sim.map_size)
		_rig.position.z = clampf(_rig.position.z + dir.y, 0, sim.map_size)


func _apply_zoom() -> void:
	_cam.position = Vector3(0, _zoom, _zoom * 0.72)
	_cam.look_at(_rig.global_position, Vector3.UP)


func _selected_workers() -> Array:
	var out: Array = []
	for id in selected:
		if sim.units.has(id) and sim.is_worker(sim.units[id]):
			out.append(id)
	return out


func _update_hud(delta: float) -> void:
	var p: Dictionary = sim.players[local_player]
	for k in ["gold", "wood"]:      # число вспыхивает, когда ресурс прибавился
		var lab: Label = _res_labels[k]
		if int(p[k]) != int(_shown_res[k]):
			if int(_shown_res[k]) >= 0 and int(p[k]) > int(_shown_res[k]):
				lab.modulate = Color(1.6, 1.5, 0.9)
				create_tween().tween_property(lab, "modulate", Color.WHITE, 0.35)
			_shown_res[k] = int(p[k])
			lab.text = str(int(p[k]))
	var capped: bool = int(p["supply_used"]) >= int(p["supply_cap"])
	_res_labels["supply"].text = "%d/%d" % [p["supply_used"], p["supply_cap"]]
	_res_labels["supply"].add_theme_color_override("font_color", Color("#ff7a6a") if capped else Color.WHITE)
	_fps.visible = settings["show_fps"]
	_fps_time -= delta
	if _fps.visible and _fps_time <= 0.0:      # обновляем дважды в секунду, чтобы цифры не мельтешили
		_fps_time = 0.5
		var fps_now := int(Engine.get_frames_per_second())
		_fps.text = "FPS: %d" % fps_now
		_fps.add_theme_color_override("font_color", Color("#6dff7a") if fps_now >= 50 else (Color("#ffd24a") if fps_now >= 30 else Color("#ff5a4a")))
	if not _casting.is_empty():
		_hint.text = "%s: выберите цель (ПКМ — отмена)" % _casting["ability"]["name"]
	elif _placing != "":
		_hint.text = "Выберите место для постройки (ЛКМ — поставить, ПКМ — отмена)"
	else:
		_hint.text = ""
	if _time - _hint_last >= 1.0:
		_hint_last = _time
		_update_hints()
	var idle := _idle_workers().size()
	_idle_btn.visible = idle > 0
	_idle_btn.text = "Рабочие без дела: %d   [Z]" % idle
	_rally_mark.visible = sel_building >= 0 and sim.buildings.has(sel_building) and sim.buildings[sel_building]["rally"] != null
	if _rally_mark.visible:
		_rally_mark.position = _at(_rally_pos(sim.buildings[sel_building]))
	_update_stats()
	_refresh_card()
	_update_ability_buttons()
	_msg_time -= delta
	_msg.visible = _msg_time > 0.0
	_update_feed()
	if int(_time * 2.0) != int((_time - delta) * 2.0):      # дважды в секунду
		_allies_btn.visible = _have_allies()
		_refresh_allies()


## Где стоит флажок сбора: на объекте-цели (он может двигаться) или на земле.
func _rally_pos(b: Dictionary) -> Vector2:
	var tid := int(b.get("rally_target", -1))
	if sim.entity(tid) != null:
		return sim.entity(tid)["pos"]
	if sim.resources.has(tid):
		return sim.resources[tid]["pos"]
	return b["rally"]


## Полоски здоровья и всплывающие надписи рисуются поверх игры.
func _draw_bars() -> void:
	if sim == null or _cam == null:
		return
	var view := Rect2(Vector2(-40, -40), _bars.size + Vector2(80, 80))
	var k := clampf(19.0 / _zoom, 0.6, 1.5)
	for id in views:
		if not sim.units.has(id) or views[id].get("far", false):
			continue
		var u: Dictionary = sim.units[id]
		var v: Dictionary = views[id]
		v["hp"] = lerpf(float(v["hp"]), float(u["hp"]), 0.25)
		var top: Vector3 = (v["node"] as Node3D).position + Vector3(0, float(v["parts"]["height"]) + 0.2, 0)
		if _cam.is_position_behind(top):
			continue
		var sp := _cam.unproject_position(top)
		if not view.has_point(sp):
			continue
		var w := (26.0 + 26.0 * float(u["radius"])) * k * (1.3 if u["hero"] else 1.0)
		var ratio := clampf(float(v["hp"]) / float(u["max_hp"]), 0.0, 1.0)
		var color := Color("#3ddc55").lerp(Color("#e8c23a"), clampf((1.0 - ratio) * 2.0, 0.0, 1.0)).lerp(Color("#e0443a"), clampf((0.5 - ratio) * 2.0, 0.0, 1.0))
		if int(u["player"]) == Sim.NEUTRAL:
			color = Color("#e8a23a").lerp(Color("#e0443a"), 1.0 - ratio)
		elif sim.allies(int(u["player"]), local_player):
			color = Color("#4ad8e8")      # союзники — бирюзовые
		elif int(u["player"]) != local_player:
			color = Color("#ff5a4a")
		_bar(sp, w, (7.0 if u["hero"] else 5.0) * k, ratio, color, float(u["max_hp"]), Color("#e8b83a") if u["hero"] else Color(0, 0, 0, 0.9))
		if float(u["max_mana"]) > 0.0:
			_bar(sp + Vector2(0, 8.0 * k), w, 4.0 * k, float(u["mana"]) / float(u["max_mana"]), Color("#4a8cff"))
		if u["hero"]:     # уровень героя рядом с полоской
			var lp := sp + Vector2(-w * 0.5 - 16.0, 7.0)
			_bars.draw_string_outline(ThemeDB.fallback_font, lp, str(int(u["level"])), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 5, Color.BLACK)
			_bars.draw_string(ThemeDB.fallback_font, lp, str(int(u["level"])), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#ffd24a"))
	var eye := Vector2(_rig.position.x, _rig.position.z)
	var far_sq := pow(30.0 + _zoom * 1.6, 2.0)
	for id in bviews:
		var b: Dictionary = sim.buildings[id]
		if b["done"] and float(b["hp"]) >= float(b["max_hp"]) and id != sel_building and (b["queue"] as Array).is_empty():
			continue
		if (b["pos"] as Vector2).distance_squared_to(eye) > far_sq:
			continue
		if not _friendly(int(b["player"])) and not fog.visible_at(b["pos"]):
			continue      # здоровье чужого здания в тумане неизвестно
		var top := _at(b["pos"], 1.2 + float(b["size"]) * 0.7)
		if _cam.is_position_behind(top):
			continue
		var sp := _cam.unproject_position(top)
		if not view.has_point(sp):
			continue
		var w := 26.0 * float(b["size"]) * k
		_bar(sp, w, 6.0 * k, float(b["hp"]) / float(b["max_hp"]), Color("#3ddc55") if int(b["player"]) == local_player else (Color("#e8c23a") if int(b["player"]) == Sim.NEUTRAL else Color("#ff5a4a")))
		if not b["done"]:
			_bar(sp + Vector2(0, 8.0 * k), w, 4.0 * k, float(b["progress"]), Color("#e8e2cf"))
		elif not (b["queue"] as Array).is_empty() and int(b["player"]) == local_player:
			var q: Dictionary = b["queue"][0]
			_bar(sp + Vector2(0, 8.0 * k), w, 4.0 * k, 1.0 - float(q["left"]) / float(q["total"]), Color("#4ac8ff"))
	var font := ThemeDB.fallback_font
	if _show_hitboxes:
		_draw_hitboxes(view)
	if _rally_mark.visible:      # пунктир от выбранного здания к точке сбора
		var a3 := _at(sim.buildings[sel_building]["pos"], 0.3)
		var b3 := _at(_rally_pos(sim.buildings[sel_building]), 0.3)
		if not _cam.is_position_behind(a3) and not _cam.is_position_behind(b3):
			_bars.draw_dashed_line(_cam.unproject_position(a3), _cam.unproject_position(b3), Color(0.24, 1.0, 0.35, 0.8), 2.0, 10.0)
	for id in lviews:      # названия предметов, лежащих на земле
		if not sim.loot.has(id) or not (lviews[id] as Node3D).visible:
			continue
		var lp := _at(sim.loot[id]["pos"], 1.0)
		if _cam.is_position_behind(lp):
			continue
		var iname := String(sim.item_def(String(sim.loot[id]["key"])).get("name", ""))
		var sp := _cam.unproject_position(lp) - Vector2(font.get_string_size(iname, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x * 0.5, 0)
		if view.has_point(sp):
			_bars.draw_string_outline(font, sp, iname, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, Color.BLACK)
			_bars.draw_string(font, sp, iname, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#ffe9a0"))
	var left: Array = []
	for f in floaters:
		f["t"] = float(f["t"]) + get_process_delta_time()
		if float(f["t"]) < 1.4:
			left.append(f)
			var pos: Vector3 = f["pos"] + Vector3(0, float(f["t"]) * 1.2, 0)
			if not _cam.is_position_behind(pos):
				var sp := _cam.unproject_position(pos) - Vector2(18, 0)
				var a := clampf(1.6 - float(f["t"]), 0.0, 1.0)
				var c: Color = f["color"]
				_bars.draw_string_outline(font, sp, String(f["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, 6, Color(0, 0, 0, a))
				_bars.draw_string(font, sp, String(f["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(c.r, c.g, c.b, a))
	floaters = left


## F11: зоны столкновений. Круг юнита — его размер в правилах игры (так юниты расталкиваются
## и так считается дистанция атаки); прямоугольники — клетки, занятые зданиями и ресурсами.
func _draw_hitboxes(view: Rect2) -> void:
	for id in views:
		if not sim.units.has(id) or views[id].get("far", false):
			continue
		var u: Dictionary = sim.units[id]
		var c := Color("#3cff5a") if int(u["player"]) == local_player else (Color("#ffd24a") if int(u["player"]) == Sim.NEUTRAL else Color("#ff4a3a"))
		_ground_circle(u["pos"], float(u["radius"]), c, 2.0, view)
		if selected.has(id) and float(u["range"]) > 0.0:      # у выбранных — ещё и дальность атаки
			_ground_circle(u["pos"], float(u["radius"]) + float(u["range"]), Color(c.r, c.g, c.b, 0.35), 1.0, view)
	for group in [sim.buildings, sim.resources]:
		for id in group:
			var t: Dictionary = group[id]
			if (t["pos"] as Vector2).distance_to(Vector2(_rig.position.x, _rig.position.z)) > 30.0 + _zoom:
				continue
			var r := Rect2(Vector2(t["cell"]), Vector2(t["size"], t["size"]))
			var pts := PackedVector2Array()
			for corner in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), r.position]:
				var p3 := _at(corner, 0.05)
				if _cam.is_position_behind(p3):
					pts.clear()
					break
				pts.append(_cam.unproject_position(p3))
			if pts.size() == 5:
				_bars.draw_polyline(pts, Color("#7fd6ff") if t.get("is_building", false) else Color("#c9a23a"), 1.5)


func _ground_circle(center: Vector2, radius: float, color: Color, width: float, view: Rect2) -> void:
	var pts := PackedVector2Array()
	for i in 17:
		var p := center + Vector2(radius, 0).rotated(TAU * i / 16.0)
		var p3 := _at(p, 0.05)
		if _cam.is_position_behind(p3):
			return
		pts.append(_cam.unproject_position(p3))
	if view.has_point(pts[0]):
		_bars.draw_polyline(pts, color, width)


## Полоска: тёмная подложка в рамке, заливка с бликом сверху, деления (по 100 единиц из total)
## и, для героев, золотая рамка.
func _bar(center: Vector2, w: float, h: float, ratio: float, color: Color, total := 0.0, frame := Color(0, 0, 0, 0.9)) -> void:
	var r := Rect2(center - Vector2(w * 0.5, h * 0.5), Vector2(w, h))
	_bars.draw_rect(r.grow(1.0), frame)
	_bars.draw_rect(r, Color(0.08, 0.08, 0.1, 0.85))
	var fill := Rect2(r.position, Vector2(w * clampf(ratio, 0.0, 1.0), h))
	_bars.draw_rect(fill, color.darkened(0.12))
	_bars.draw_rect(Rect2(fill.position, Vector2(fill.size.x, h * 0.45)), color.lightened(0.18))
	if total > 0.0 and h >= 4.0:
		var step := 100.0 if total <= 2000.0 else 500.0
		var n := int(total / step)
		if n >= 2 and w / float(n) >= 3.0:
			for i in range(1, n):
				var x := r.position.x + w * (i * step / total)
				_bars.draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(0, 0, 0, 0.45), 1.0)


# ---------- строительство ----------

func _begin_place(key: String) -> void:
	if _selected_workers().is_empty():
		return
	_casting = {}
	_placing = key


var _ghost_model: Node3D           # полупрозрачная модель здания, которое ставим
var _ghost_key := ""
var _ghost_mat: StandardMaterial3D


func _update_ghost() -> void:
	_ghost.visible = _placing != ""
	if _placing == "" or _selected_workers().is_empty():
		_placing = ""
		if _ghost_model != null:
			_ghost_model.visible = false
		return
	var def: Dictionary = sim.players[local_player]["data"]["buildings"][_placing]
	var s: int = int(def.get("size", 2))
	if _ghost_key != _placing:      # сменили здание: строим его прозрачную модель
		_ghost_key = _placing
		if _ghost_model != null:
			_ghost_model.queue_free()
		_ghost_mat = _flat(Color(0.3, 1.0, 0.4, 0.4), true)
		_ghost_model = Models.building(def.get("model", {}), float(s), _team(local_player))
		for mi in _ghost_model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = _ghost_mat
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_ghost_model)
	var hit = _ground_point(get_viewport().get_mouse_position())
	if hit == null:
		return
	_ghost_cell = Vector2i(roundi(hit.x - s * 0.5), roundi(hit.z - s * 0.5))
	var ok := sim.can_place(s, _ghost_cell) and sim.can_afford(local_player, def.get("cost", {}))
	var center := Vector2(_ghost_cell) + Vector2(s, s) * 0.5
	(_ghost.mesh as BoxMesh).size = Vector3(s, 0.06, s)      # основание — клетки, которые займёт здание
	_ghost.position = _at(center, 0.05)
	(_ghost.material_override as StandardMaterial3D).albedo_color = Color(0.2, 1.0, 0.3, 0.35) if ok else Color(1.0, 0.2, 0.2, 0.45)
	_ghost_model.visible = true
	_ghost_model.position = _at(center, -0.05)
	_ghost_model.rotation.y = _building_facing(center)
	_ghost_mat.albedo_color = Color(0.35, 1.0, 0.45, 0.42) if ok else Color(1.0, 0.3, 0.25, 0.42)


func _place() -> void:
	_issue({"type": "build", "player": local_player, "units": _selected_workers(), "building": _placing, "cell": _ghost_cell})
	_placing = ""


# =====================================================================
#  ОФОРМЛЕНИЕ: курсоры, подсветка под курсором, свет и атмосфера
# =====================================================================

var _cursors: Dictionary = {}     # вид курсора -> [текстура, точка нажатия]
var _cursor_now := ""
var _hover: Dictionary = {}       # что под курсором: {kind: unit/building/resource, id, rel}
var _hover_ring: MeshInstance3D   # кольцо под юнитом
var _hover_box: MeshInstance3D    # квадрат под зданием
var _hover_mat: StandardMaterial3D
var _hover_frame := 0
var _fireflies: CPUParticles3D
var _vignette: ShaderMaterial
var _sun_night := 0.0             # 0 — день, 1 — ночь (плавно)


## Курсор рисуется кодом: многоугольники с тёмной обводкой (32×32).
func _cursor_tex(polys: Array, outline: Color) -> ImageTexture:
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var inside := []
	inside.resize(n * n)
	for py in n:
		for px in n:
			var p := Vector2(px + 0.5, py + 0.5)
			var c = null
			for poly in polys:
				if Geometry2D.is_point_in_polygon(p, PackedVector2Array(poly[0])):
					c = poly[1]
			inside[py * n + px] = c
	for py in n:
		for px in n:
			var c = inside[py * n + px]
			if c != null:
				var shade := 1.0 - float(py) / n * 0.25      # лёгкий объём: сверху светлее
				img.set_pixel(px, py, Color((c as Color).r * shade, (c as Color).g * shade, (c as Color).b * shade, 1.0))
				continue
			var edge := false
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var x: int = px + dx
					var y: int = py + dy
					if x >= 0 and y >= 0 and x < n and y < n and inside[y * n + x] != null:
						edge = true
			img.set_pixel(px, py, outline if edge else Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)


func _make_cursors() -> void:
	var gold := Color("#ffd24a")
	_cursors["normal"] = [_cursor_tex([[[Vector2(2, 2), Vector2(2, 25), Vector2(8, 19.5), Vector2(12.5, 29), Vector2(16.5, 27.5), Vector2(12, 18), Vector2(20, 18)], gold]], Color("#1a1208")), Vector2(2, 2)]
	_cursors["attack"] = [_cursor_tex([
		[[Vector2(2, 2), Vector2(7, 2), Vector2(22, 17), Vector2(17, 22), Vector2(2, 7)], Color("#e8e4dc")],
		[[Vector2(14, 24), Vector2(24, 14), Vector2(26.5, 16.5), Vector2(16.5, 26.5)], Color("#ffb03a")],
		[[Vector2(20.5, 22.5), Vector2(22.5, 20.5), Vector2(29, 27), Vector2(27, 29)], Color("#c0392b")]], Color("#3a0a06")), Vector2(2, 2)]
	_cursors["gather"] = [_cursor_tex([
		[[Vector2(3, 27), Vector2(6, 30), Vector2(23, 13), Vector2(20, 10)], Color("#a0703a")],
		[[Vector2(9, 3), Vector2(19, 5), Vector2(27, 12), Vector2(30, 21), Vector2(26.5, 21), Vector2(22, 14), Vector2(17, 9.5), Vector2(8.5, 7)], Color("#d8dce4")]], Color("#1a1208")), Vector2(28, 20)]
	_cursors["build"] = [_cursor_tex([
		[[Vector2(3, 27), Vector2(6, 30), Vector2(20, 16), Vector2(17, 13)], Color("#a0703a")],
		[[Vector2(10, 9), Vector2(17, 2), Vector2(29, 14), Vector2(22, 21)], Color("#c9a24a")]], Color("#1a1208")), Vector2(16, 16)]
	var ring: Array = []
	for i in 24:
		ring.append(Vector2(16, 16) + Vector2(12, 0).rotated(TAU * i / 24.0))
	for i in 24:
		ring.append(Vector2(16, 16) + Vector2(9, 0).rotated(-TAU * i / 24.0))
	_cursors["target"] = [_cursor_tex([
		[ring, Color("#7fe8ff")],
		[[Vector2(15, 1), Vector2(17, 1), Vector2(17, 11), Vector2(15, 11)], Color("#7fe8ff")],
		[[Vector2(15, 21), Vector2(17, 21), Vector2(17, 31), Vector2(15, 31)], Color("#7fe8ff")],
		[[Vector2(1, 15), Vector2(11, 15), Vector2(11, 17), Vector2(1, 17)], Color("#7fe8ff")],
		[[Vector2(21, 15), Vector2(31, 15), Vector2(31, 17), Vector2(21, 17)], Color("#7fe8ff")]], Color("#06222a")), Vector2(16, 16)]
	_set_cursor("normal")


func _set_cursor(kind: String) -> void:
	if kind == _cursor_now or not _cursors.has(kind):
		return
	_cursor_now = kind
	Input.set_custom_mouse_cursor(_cursors[kind][0], Input.CURSOR_ARROW, _cursors[kind][1])


## Свет, тени, атмосфера: тональная коррекция, мягкое свечение ярких огней, затемнение краёв, светлячки.
func _setup_visuals() -> void:
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.tonemap_exposure = 1.08
	_env.tonemap_white = 1.6
	_env.glow_enabled = true
	_env.glow_intensity = 0.55
	_env.glow_strength = 0.9
	_env.glow_bloom = 0.04
	_env.glow_hdr_threshold = 0.95
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	# затемнение по краям экрана (ночью сильнее и с синевой)
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform float strength = 0.38;
uniform vec3 tint = vec3(0.0, 0.0, 0.02);
void fragment() {
	vec2 d = UV - vec2(0.5);
	d.x *= 1.2;
	float v = smoothstep(0.45, 0.95, length(d) * 1.35);
	COLOR = vec4(tint, v * strength);
}
"""
	_vignette = ShaderMaterial.new()
	_vignette.shader = sh
	rect.material = _vignette
	layer.add_child(rect)
	# подсветка того, что под курсором
	_hover_mat = _flat(Color(1, 1, 1, 0.75), true)
	_hover_mat.no_depth_test = true
	_hover_mat.render_priority = 5
	_hover_ring = _torus(1.0, 0.07, Color.WHITE, 28)
	_hover_ring.material_override = _hover_mat
	_hover_ring.scale.y = 0.2
	_hover_ring.visible = false
	add_child(_hover_ring)
	_hover_box = _torus(1.0, 0.05, Color.WHITE, 4)
	_hover_box.material_override = _hover_mat
	_hover_box.rotation.y = PI / 4
	_hover_box.visible = false
	add_child(_hover_box)
	# ночные светлячки вокруг камеры
	_fireflies = CPUParticles3D.new()
	_fireflies.amount = 80
	_fireflies.lifetime = 5.0
	_fireflies.preprocess = 5.0
	_fireflies.local_coords = false
	_fireflies.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_fireflies.emission_box_extents = Vector3(24, 1.0, 18)
	_fireflies.direction = Vector3(0, 1, 0)
	_fireflies.spread = 180.0
	_fireflies.initial_velocity_min = 0.1
	_fireflies.initial_velocity_max = 0.45
	_fireflies.gravity = Vector3.ZERO
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.add_point(0.25, Color(1, 1, 1, 1))
	ramp.add_point(0.75, Color(1, 1, 1, 0.8))
	ramp.set_color(ramp.get_point_count() - 1, Color(1, 1, 1, 0))
	_fireflies.color_ramp = ramp
	var dot := SphereMesh.new()
	dot.radius = 0.07
	dot.height = 0.14
	dot.radial_segments = 4
	dot.rings = 2
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.vertex_color_use_as_albedo = true
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.albedo_color = Color("#e8ff7a")
	dot.material = fm
	_fireflies.mesh = dot
	_fireflies.position = Vector3(0, 1.4, 4)
	_fireflies.emitting = false
	_rig.add_child(_fireflies)
	_make_cursors()


## Каждый кадр: курсор по тому, что под ним, и подсветка; ночью — светлячки и сильнее затемнение краёв.
func _update_presentation() -> void:
	if _hover_ring == null:
		return
	var night: float = clampf(_sun_night, 0.0, 1.0)
	_vignette.set_shader_parameter("strength", lerpf(0.36, 0.55, night))
	_vignette.set_shader_parameter("tint", Vector3(0.0, 0.0, 0.02).lerp(Vector3(0.0, 0.02, 0.08), night))
	_fireflies.emitting = night > 0.6 and not _test.has("noflies")
	_hover_frame += 1
	if _hover_frame % 3 == 0:
		_hover = _pick_hover(get_viewport().get_mouse_position())
	var kind := "normal"
	if not _casting.is_empty():
		kind = "target"
	elif _placing != "":
		kind = "build"
	elif not _hover.is_empty():
		var rel := String(_hover["rel"])
		if rel == "enemy" and not selected.is_empty():
			kind = "attack"
		elif String(_hover["kind"]) == "resource" and not _selected_workers().is_empty():
			kind = "gather"
		elif rel == "own_site" and not _selected_workers().is_empty():
			kind = "build"
	_set_cursor(kind)
	# кольцо или квадрат под тем, что под курсором
	_hover_ring.visible = false
	_hover_box.visible = false
	if _hover.is_empty():
		return
	var c: Color = {"enemy": Color("#ff4a3a"), "neutral": Color("#ffd24a"), "own": Color("#6dff7a"), "own_site": Color("#6dff7a"), "ally": Color("#4ad8e8"), "resource": Color("#fff3c0")}.get(String(_hover["rel"]), Color.WHITE)
	_hover_mat.albedo_color = Color(c.r, c.g, c.b, 0.55 + 0.25 * sin(_time * 6.0))
	var id := int(_hover["id"])
	match String(_hover["kind"]):
		"unit":
			if views.has(id) and sim.units.has(id):
				var r: float = float(sim.units[id]["radius"]) + 0.28
				_hover_ring.position = (views[id]["node"] as Node3D).position + Vector3(0, 0.12, 0)
				_hover_ring.scale = Vector3(r, 0.2, r)
				_hover_ring.visible = true
		"building":
			if sim.buildings.has(id) and id != sel_building:
				var b: Dictionary = sim.buildings[id]
				_hover_box.position = _at(b["pos"], 0.15)
				_hover_box.scale = Vector3(float(b["size"]) * 0.8, 0.25, float(b["size"]) * 0.8)
				_hover_box.visible = true
		"resource":
			if sim.resources.has(id):
				var rs: Dictionary = sim.resources[id]
				var rr: float = float(rs["size"]) * 0.6 + 0.2
				_hover_ring.position = _at(rs["pos"], 0.12)
				_hover_ring.scale = Vector3(rr, 0.2, rr)
				_hover_ring.visible = true


func _pick_hover(m: Vector2) -> Dictionary:
	var gui := get_viewport().gui_get_hovered_control()
	if gui != null and gui != _bars and gui.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return {}      # курсор над панелью интерфейса
	var foe := _unit_at(m, false, 16.0)
	if foe >= 0:
		return {"kind": "unit", "id": foe, "rel": "neutral" if int(sim.units[foe]["player"]) == Sim.NEUTRAL else "enemy"}
	var friend := _unit_at(m, true, 16.0, true)
	if friend >= 0:
		return {"kind": "unit", "id": friend, "rel": "own" if int(sim.units[friend]["player"]) == local_player else "ally"}
	var hit = _ground_point(m)
	var ground: Vector2 = Vector2(hit.x, hit.z) if hit != null else Vector2(-99, -99)
	var b := _building_under(m, ground)
	if b >= 0 and _building_seen(sim.buildings[b]):
		var bp := int(sim.buildings[b]["player"])
		var rel := "neutral" if bp == Sim.NEUTRAL else ("enemy" if sim.enemies(bp, local_player) else ("own_site" if bp == local_player and not sim.buildings[b]["done"] else ("own" if bp == local_player else "ally")))
		if bp == Sim.NEUTRAL and String(sim.buildings[b]["def"].get("role", "")) in ["shop", "capture", "fountain", "mercenary"]:
			rel = "neutral"
		return {"kind": "building", "id": b, "rel": rel}
	if hit != null:
		var res := _resource_at(m, ground)
		if res >= 0 and (sim.resources[res]["pos"] as Vector2).distance_to(ground) < float(sim.resources[res]["size"]) * 0.5 + 0.9:
			return {"kind": "resource", "id": res, "rel": "resource"}
	return {}


# =====================================================================
#  СОЮЗНИКИ, ЧАТ, СИГНАЛЫ НА КАРТЕ, СКОРОСТЬ ИГРЫ
# =====================================================================

func _build_team_ui() -> void:
	_speed_label = Label.new()
	_speed_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_speed_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_speed_label.position = Vector2(-16, 82)
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_speed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_speed_label.add_theme_color_override("font_color", Color("#9fe0ff"))
	_outlined(_speed_label, 18)
	_speed_label.visible = false
	_ui.add_child(_speed_label)

	_feed = VBoxContainer.new()
	_feed.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_feed.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_feed.position = Vector2(14, -MINI_SIZE - 136)
	_feed.custom_minimum_size = Vector2(560, 0)
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_theme_constant_override("separation", 2)
	_ui.add_child(_feed)

	_chat_edit = LineEdit.new()
	_chat_edit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_edit.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_chat_edit.position = Vector2(12, -MINI_SIZE - 92)
	_chat_edit.custom_minimum_size = Vector2(520, 38)
	_chat_edit.max_length = 200
	_chat_edit.add_theme_font_size_override("font_size", 18)
	_chat_edit.visible = false
	_chat_edit.text_submitted.connect(_send_chat)
	_chat_edit.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventKey and e.pressed and not e.echo:
			if e.physical_keycode == KEY_ESCAPE:
				_close_chat()
				_chat_edit.accept_event()
			elif e.physical_keycode == KEY_TAB:
				_chat_allies = not _chat_allies and _have_allies()
				_chat_hint()
				_chat_edit.accept_event())
	_ui.add_child(_chat_edit)

	_allies_btn = Button.new()
	_allies_btn.text = "Союзники (F6)"
	_allies_btn.position = Vector2(160, 10)
	_allies_btn.custom_minimum_size = Vector2(150, 38)
	_allies_btn.focus_mode = Control.FOCUS_NONE
	_allies_btn.pressed.connect(_toggle_allies)
	_allies_btn.visible = _have_allies()
	_ui.add_child(_allies_btn)
	_allies_panel = PanelContainer.new()
	_allies_panel.add_theme_stylebox_override("panel", _panel_style(0.92))
	_allies_panel.position = Vector2(12, 56)
	_allies_panel.visible = false
	_ui.add_child(_allies_panel)


func _have_allies() -> bool:
	for p in sim.players:
		if sim.allies(int(p), local_player):
			return true
	return false


## Панель союзников: их казна и передача им золота и дерева.
func _toggle_allies() -> void:
	_allies_panel.visible = not _allies_panel.visible and _have_allies()
	_allies_key = ""
	_refresh_allies()


func _refresh_allies() -> void:
	if not _allies_panel.visible:
		return
	var key := ""
	for p in sim.players:
		if sim.allies(int(p), local_player):
			key += "%d%s," % [int(p), "x" if sim.players[p].get("defeated", false) else ""]
	if key != _allies_key:      # состав изменился — строим заново (иначе только обновляем цифры)
		_allies_key = key
		for c in _allies_panel.get_children():
			c.queue_free()
		_allies_rows.clear()
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 6)
		_allies_panel.add_child(col)
		var head := Label.new()
		head.text = "Союзники — передать ресурсы (Shift — по 500)"
		head.add_theme_color_override("font_color", Color("#ffd24a"))
		col.add_child(head)
		for p in sim.players:
			if not sim.allies(int(p), local_player):
				continue
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			col.add_child(row)
			var l := Label.new()
			l.custom_minimum_size = Vector2(330, 0)
			l.add_theme_color_override("font_color", _team(int(p)).lightened(0.35))
			row.add_child(l)
			var dead: bool = sim.players[p].get("defeated", false)
			for res in [["gold", "+ золото"], ["wood", "+ дерево"]]:
				var b := Button.new()
				b.text = res[1]
				b.focus_mode = Control.FOCUS_NONE
				b.disabled = dead
				b.custom_minimum_size = Vector2(104, 34)
				b.pressed.connect(func() -> void:
					var n := 500 if Input.is_key_pressed(KEY_SHIFT) else 100
					_issue({"type": "gift", "player": local_player, "to": int(p), res[0]: n}))
				row.add_child(b)
			_allies_rows.append({"player": int(p), "label": l})
	for r in _allies_rows:
		var ap: Dictionary = sim.players[r["player"]]
		(r["label"] as Label).text = "%s (%s)%s   золото %d, дерево %d" % [_player_name(int(r["player"])), String(ap["data"]["name"]).split(" ")[-1].to_lower(),
			"  — выбыл" if ap.get("defeated", false) else "", int(ap["gold"]), int(ap["wood"])]


## Строка в ленте слева: чат, подарки, сигналы. Исчезает через 14 секунд.
func _feed_line(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(560, 0)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outlined(l, 17)
	_feed.add_child(l)
	l.set_meta("born", _time)
	while _feed.get_child_count() > 8:
		var old := _feed.get_child(0)
		_feed.remove_child(old)
		old.queue_free()


func _update_feed() -> void:
	for l in _feed.get_children():
		var age: float = _time - float(l.get_meta("born", 0.0))
		(l as Label).modulate.a = clampf(14.0 - age, 0.0, 1.0)
		if age > 14.0:
			_feed.remove_child(l)
			l.queue_free()


func _open_chat(to_all: bool) -> void:
	if net_mode == "":
		_say("Чат работает в сетевой игре")
		return
	_chat_allies = not to_all and _have_allies()
	_chat_hint()
	_chat_edit.visible = true
	_chat_edit.text = ""
	_chat_edit.grab_focus()


func _chat_hint() -> void:
	_chat_edit.placeholder_text = ("Союзникам" if _chat_allies else "Всем") + ": сообщение (Enter — отправить, Tab — кому, Esc — отмена)"
	_chat_edit.add_theme_color_override("font_color", Color("#7fe8ff") if _chat_allies else Color.WHITE)


func _close_chat() -> void:
	_chat_edit.visible = false
	_chat_edit.release_focus()


func _send_chat(text: String) -> void:
	_close_chat()
	if text.strip_edges() != "":
		online.send_chat(text, _chat_allies)


func _on_chat(index: int, nick: String, text: String, allies_only: bool) -> void:
	if sim == null:      # ещё в комнате: чат комнаты
		_room_chat.append("%s: %s" % [nick, text])
		while _room_chat.size() > 8:
			_room_chat.pop_front()
		if _room_chat_label != null and is_instance_valid(_room_chat_label):
			_room_chat_label.text = "\n".join(_room_chat)
		audio.play("click", -12.0)
		return
	print("CHAT: %s%s: %s" % ["[allies] " if allies_only else "", nick, text])
	var color := _team(index).lightened(0.45) if index >= 0 else Color.WHITE
	_feed_line("%s%s: %s" % ["[Союзникам] " if allies_only else "", nick, text], color)
	audio.play("click", -8.0)


## Сигнал союзникам: Alt+ЛКМ по земле или по мини-карте.
func _signal_at(pos: Vector2) -> void:
	if net_mode != "":
		online.send_ping(pos)
	else:
		_show_ping(local_player, pos)


func _show_ping(index: int, pos: Vector2) -> void:
	var c := _team(index).lightened(0.3)
	print("PING: player %d at %s" % [index, pos])
	_mini_pings.append({"pos": pos, "t": 0.0, "color": c})
	_ping(pos, c)
	_ring_fx(pos, 2.5, c)
	audio.play("ping", -6.0)
	if index != local_player:
		_feed_line("%s подаёт сигнал — смотрите на мини-карту" % _player_name(index), c)


## День и ночь: плавно меняются солнце, небо и рассеянный свет; часы в углу экрана.
func _update_daylight() -> void:
	if _sun == null:
		return
	var t := float(sim.tick % Sim.DAY_CYCLE) + _acc / Sim.TICK_DT
	var n := smoothstep(Sim.DAY_LEN - 200.0, Sim.DAY_LEN, t) - smoothstep(Sim.DAY_CYCLE - 200.0, Sim.DAY_CYCLE, t)
	_sun_night = n
	_sun.light_energy = lerpf(1.25, 0.52, n)
	_sun.light_color = Color("#ffe6c4").lerp(Color("#b4c0e8"), n)
	_env.ambient_light_color = Color("#7f8a98").lerp(Color("#66708e"), n)
	_env.adjustment_saturation = lerpf(0.82, 0.62, n)      # ночью краски приглушённее
	_env.ambient_light_energy = lerpf(0.42, 0.5, n)
	_env.background_color = Color("#6f777c").lerp(Color("#1c2230"), n)
	_env.fog_light_color = _env.background_color
	if _clock_label != null:
		var left := sim.phase_left()
		_clock_label.text = "%s   ·   %s ещё %s" % [_clock(sim.tick * Sim.TICK_DT), "ночь" if sim.is_night() else "день", _clock(left)]
		_clock_label.add_theme_color_override("font_color", Color("#9ab8ff") if sim.is_night() else Color("#ffe6a0"))
		_day_icon.texture = Icons.make("moon" if sim.is_night() else "sun", Color("#6a8aff") if sim.is_night() else Color("#ffc23a"))


func _change_speed(step: int) -> void:
	if net_mode != "":
		_say("В сетевой игре скорость не меняется")
		return
	var i := clampi(SPEEDS.find(speed) + step, 0, SPEEDS.size() - 1)
	speed = SPEEDS[i]
	var shown := str(int(speed)) if speed == floorf(speed) else str(speed).replace(".", ",")
	_speed_label.text = "Скорость ×%s" % shown
	_speed_label.visible = speed != 1.0
	_say("Скорость игры ×%s" % shown)


# =====================================================================
#  УПРАВЛЕНИЕ
# =====================================================================

func _unhandled_input(event: InputEvent) -> void:
	if sim == null:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F10:
		_toggle_pause()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F11:
		_show_hitboxes = not _show_hitboxes      # F11 — показать зоны столкновений (хитбоксы)
		_say("Хитбоксы: %s" % ("показаны" if _show_hitboxes else "скрыты"))
		return
	# зажатое колёсико мыши — двигать камеру, перетаскивая карту
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE:
		_mmb_drag = (event as InputEventMouseButton).pressed
		return
	if event is InputEventMouseMotion and _mmb_drag and not _paused:
		var rel: Vector2 = (event as InputEventMouseMotion).relative
		var per_px := 2.0 * _zoom * 1.23 * tan(deg_to_rad(_cam.fov * 0.5)) / maxf(1.0, get_viewport().get_visible_rect().size.y)
		_rig.position.x = clampf(_rig.position.x - rel.x * per_px, 0, sim.map_size)
		_rig.position.z = clampf(_rig.position.z - rel.y * per_px * 1.35, 0, sim.map_size)
		return
	if _paused:
		if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
			_toggle_pause()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom = maxf(10.0, _zoom - 2.0)
			_apply_zoom()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom = minf(48.0, _zoom + 2.0)
			_apply_zoom()
		elif not _casting.is_empty():
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				_finish_cast(mb.position)
			elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
				_casting = {}
		elif _placing != "":
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				_place()
			elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
				_placing = ""
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.alt_pressed:
			var sig = _ground_point(mb.position)      # Alt+ЛКМ — сигнал союзникам
			if sig != null:
				_signal_at(Vector2(sig.x, sig.z))
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_double = mb.double_click
				_drag_from = mb.position
			elif _dragging:
				_dragging = false
				_box.visible = false
				_select(Rect2(_drag_from, mb.position - _drag_from).abs(), mb.shift_pressed)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var hit = _ground_point(mb.position)
			if hit != null and not selected.is_empty():
				_smart_order(mb.position, Vector2(hit.x, hit.z), mb.ctrl_pressed)
			elif hit != null and sel_building >= 0 and sim.buildings.has(sel_building) and int(sim.buildings[sel_building]["player"]) == local_player:
				# ПКМ при выбранном здании ставит точку сбора: на землю или на объект
				var g := Vector2(hit.x, hit.z)
				var target := _foe_at(mb.position, g)
				if target < 0:
					target = _unit_at(mb.position, true, 22.0, true)
				if target < 0:
					target = _resource_at(mb.position, g)
				if target < 0:
					var ob := _building_under(mb.position, g)
					target = ob if ob != sel_building else -1
				_issue({"type": "rally", "player": local_player, "building": sel_building, "pos": g, "target": target})
				if target >= 0:
					_mark_entity(target, Color("#ff3a2a") if sim.entity(target) != null and sim.enemies(int(sim.entity(target)["player"]), local_player) else Color("#3cff5a"))
				else:
					_ping(g, Color("#3cff5a"))
	elif event is InputEventMouseMotion and _dragging:
		var r := Rect2(_drag_from, (event as InputEventMouseMotion).position - _drag_from).abs()
		_box.visible = r.size.length() > 12.0
		_box.position = r.position
		_box.size = r.size
	elif event is InputEventKey and event.pressed and not event.echo:
		var code: int = event.physical_keycode
		if code == KEY_ENTER or code == KEY_KP_ENTER:
			_open_chat(event.shift_pressed)      # Enter — союзникам, Shift+Enter — всем
		elif code == KEY_F6:
			_toggle_allies()
		elif code == KEY_EQUAL or code == KEY_KP_ADD:
			_change_speed(1)
		elif code == KEY_MINUS or code == KEY_KP_SUBTRACT:
			_change_speed(-1)
		elif code == KEY_ESCAPE:
			if not _casting.is_empty() or _placing != "":
				_casting = {}
				_placing = ""
			else:
				selected.clear()
				sel_building = -1
				inspect = -1
		elif code == KEY_H and not selected.is_empty():
			_issue({"type": "stop", "player": local_player, "units": selected.duplicate()})
		elif code == KEY_Z:
			_next_idle_worker()
		elif code == KEY_X:          # всё войско разом
			selected.clear()
			sel_building = -1
			inspect = -1
			for id in sim.units:
				if int(sim.units[id]["player"]) == local_player and not sim.is_worker(sim.units[id]):
					selected.append(id)
		elif code == KEY_SPACE:      # камера на главное здание
			for id in sim.buildings:
				var hb: Dictionary = sim.buildings[id]
				if int(hb["player"]) == local_player and String(hb["def"].get("role", "")) == "hall":
					_focus(hb["pos"])
					break
		elif code >= KEY_1 and code <= KEY_9:
			var n: int = code - KEY_0
			if event.ctrl_pressed:
				groups[n] = selected.duplicate()       # Ctrl+цифра запоминает отряд
				_say("Отряд %d: %d" % [n, selected.size()])
			elif groups.has(n):
				var alive: Array = []
				for id in groups[n]:
					if sim.units.has(id):
						alive.append(id)
				groups[n] = alive
				selected = alive.duplicate()
				sel_building = -1
				inspect = -1
				if int(_group_tap["n"]) == n and _time - float(_group_tap["t"]) < 0.4 and not alive.is_empty():
					_focus(sim.units[alive[0]]["pos"])       # двойное нажатие — камера к отряду
				_group_tap = {"n": n, "t": _time}
		elif code == KEY_C and sel_building >= 0 and sim.buildings.has(sel_building) and int(sim.buildings[sel_building]["player"]) == local_player:
			_cancel()        # C — отменить последний заказ или недостроенное здание
		else:
			for item in _card_items:
				if String(item["hotkey"]) == "" or code != OS.find_keycode_from_string(String(item["hotkey"])):
					continue
				if event.ctrl_pressed and item["ability"] != null:      # Ctrl+буква — изучить способность
					_learn(String(item["ability"]["key"]))
					break
				if not (item["button"] as Button).disabled:
					(item["action"] as Callable).call()
					break


## Правая кнопка сама понимает, что имелось в виду: враг — атаковать,
## ресурс — добывать, своя стройка — достраивать, иначе — идти.
func _smart_order(screen: Vector2, ground: Vector2, with_fight: bool) -> void:
	var ids: Array = selected.duplicate()
	var foe := _foe_at(screen, ground)
	if foe >= 0:
		_issue({"type": "attack", "player": local_player, "units": ids, "target": foe})
		_mark_entity(foe, Color("#ff3a2a"))
		return
	var workers := _selected_workers()
	var movers: Array = ids
	var drop := _loot_at(ground)
	if drop >= 0:      # ПКМ по предмету на земле: ближайший выбранный герой идёт его поднять
		var hero := -1
		for id in ids:
			if sim.units.has(id) and sim.units[id]["hero"] and (hero < 0 or (sim.units[id]["pos"] as Vector2).distance_to(ground) < (sim.units[hero]["pos"] as Vector2).distance_to(ground)):
				hero = int(id)
		if hero >= 0:
			_issue({"type": "pickup", "player": local_player, "unit": hero, "target": drop})
			movers = ids.filter(func(x) -> bool: return x != hero)
			_mark_entity(drop, Color("#ffd24a"))
			if movers.is_empty():
				return
	if not workers.is_empty():
		var others: Array = movers.filter(func(x) -> bool: return not workers.has(x))
		var res_id := _resource_at(screen, ground)
		var b_id := _building_under(screen, ground)
		if res_id >= 0:
			# видно, что рабочие пошли именно к этому дереву или руднику
			_issue({"type": "gather", "player": local_player, "units": workers, "target": res_id})
			_mark_entity(res_id, Color("#ffd24a") if String(sim.resources[res_id]["kind"]) == "gold" else Color("#8fe36a"))
			movers = others
		elif b_id >= 0 and int(sim.buildings[b_id]["player"]) == local_player and not sim.buildings[b_id]["done"]:
			_issue({"type": "resume", "player": local_player, "units": workers, "target": b_id})
			_mark_entity(b_id, Color("#3cff5a"))
			movers = others
		if movers.is_empty():
			return
	var friend := _unit_at(screen, true, 22.0, true)
	if friend >= 0 and not movers.has(friend):      # ПКМ по своему или союзному юниту — идти следом за ним
		_issue({"type": "follow", "player": local_player, "units": movers, "target": friend})
		_mark_entity(friend, Color("#3cff5a"))
		return
	_issue({"type": "amove" if with_fight else "move", "player": local_player, "units": movers, "target": ground})
	_ping(ground, Color("#ffb03a") if with_fight else Color("#3cff5a"))


func _loot_at(ground: Vector2) -> int:
	for id in sim.loot:
		if (sim.loot[id]["pos"] as Vector2).distance_to(ground) < 0.7:
			return int(id)
	return -1


## Юнит под курсором: свой (mine = true; с allies — и союзный) или вражеский (mine = false).
## Если курсор на здании, а юнит только рядом (не прямо под курсором), выбирается здание.
func _unit_at(screen: Vector2, mine: bool, reach: float = 38.0, allies := false) -> int:
	var pick := _pick_unit(screen, mine, reach, allies)
	if pick.is_empty():
		return -1
	var bh := _building_hit(screen)
	if not bh.is_empty() and (not bool(pick["direct"]) or float(pick["depth"]) > float(bh["t"]) + 1.0):
		return -1      # курсор на здании: рядом стоящий (или спрятанный за ним) юнит клик не перехватывает
	return int(pick["id"])


## Лучший юнит под курсором: {id, direct (курсор прямо на фигуре), depth (расстояние от камеры)}.
func _pick_unit(screen: Vector2, mine: bool, reach: float, allies: bool) -> Dictionary:
	var best := {}
	var best_score := INF
	var right := _cam.global_transform.basis.x
	for id in views:
		var u: Dictionary = sim.units[id]
		var p := int(u["player"])
		var node: Node3D = views[id]["node"]
		if mine and p != local_player and not (allies and sim.allies(p, local_player)):
			continue
		if not mine and (not sim.enemies(p, local_player) or not node.visible):
			continue
		var feet: Vector3 = node.position
		var top: Vector3 = feet + Vector3(0, float(views[id]["parts"]["height"]), 0)
		if _cam.is_position_behind(feet) or _cam.is_position_behind(top):
			continue
		var a := _cam.unproject_position(feet)
		var b := _cam.unproject_position(top)
		var d := Geometry2D.get_closest_point_to_segment(screen, a, b).distance_to(screen)
		var r_px := maxf(9.0, _cam.unproject_position(feet + right * (float(u["radius"]) + 0.1)).distance_to(a))
		var direct := d <= r_px
		var score := d / r_px if direct else 10.0 + d      # попадание прямо в фигуру важнее близости
		if (direct or d < reach) and score < best_score:
			best_score = score
			best = {"id": int(id), "direct": direct, "depth": _cam.global_position.distance_to((feet + top) * 0.5)}
	return best


## Здание под курсором: луч из камеры пересекает объём здания (а не землю за ним —
## иначе клик по крыше или стене попадал «мимо»). Возвращает {id, t} или {}.
func _building_hit(screen: Vector2) -> Dictionary:
	var from := _cam.project_ray_origin(screen)
	var dir := _cam.project_ray_normal(screen)
	var best := {}
	for id in bviews:
		var node: Node3D = bviews[id]
		if not node.visible or not sim.buildings.has(id):
			continue
		var b: Dictionary = sim.buildings[id]
		var t := _box_hit(node, Vector2(b["cell"]), float(b["size"]), from, dir)
		if t >= 0.0 and (best.is_empty() or t < float(best["t"])):
			best = {"id": int(id), "t": t}
	return best


var _heights: Dictionary = {}      # модель -> её высота (считается один раз)


## Расстояние вдоль луча до «коробки» объекта (клетки основания × высота модели) или -1.
func _box_hit(node: Node3D, cell: Vector2, size: float, from: Vector3, dir: Vector3) -> float:
	if not _heights.has(node):
		var top := 1.0
		var inv := node.global_transform.affine_inverse()
		for mi in node.find_children("*", "MeshInstance3D", true, false):
			var box: AABB = (inv * (mi as MeshInstance3D).global_transform) * (mi as MeshInstance3D).get_aabb()
			top = maxf(top, box.end.y)
		_heights[node] = minf(top, size * 2.2 + 2.0)
	var h: float = float(_heights[node]) * node.scale.y
	var lo := Vector3(cell.x - 0.1, node.position.y - 0.5, cell.y - 0.1)
	var box := AABB(lo, Vector3(size + 0.2, h + 0.5, size + 0.2))
	var hit = box.intersects_ray(from, dir)
	return from.distance_to(hit) if hit != null else -1.0


## Здание под курсором (по объёму), иначе — по клетке основания под точкой на земле.
func _building_under(screen: Vector2, ground: Vector2) -> int:
	var bh := _building_hit(screen)
	if not bh.is_empty():
		return int(bh["id"])
	var b := _building_at(ground)
	return b if b >= 0 and (not bviews.has(b) or (bviews[b] as Node3D).visible) else -1


## Чужой юнит или здание под курсором.
func _foe_at(screen: Vector2, ground: Vector2) -> int:
	var best := _unit_at(screen, false, 34.0)
	if best >= 0:
		return best
	var b := _building_under(screen, ground)
	if b >= 0 and sim.enemies(int(sim.buildings[b]["player"]), local_player) and _building_seen(sim.buildings[b]):
		return b
	return -1


func _resource_at(screen: Vector2, ground: Vector2) -> int:
	var best := -1
	var best_d := 30.0
	var from := _cam.project_ray_origin(screen)
	var dir := _cam.project_ray_normal(screen)
	for id in sim.resources:      # рудник — высокий: попадание по его объёму, как у зданий
		var gm: Dictionary = sim.resources[id]
		if String(gm["kind"]) == "gold" and rviews.has(id) and _box_hit(rviews[id], Vector2(gm["cell"]), float(gm["size"]), from, dir) >= 0.0:
			return int(id)
	for id in sim.resources:
		var r: Dictionary = sim.resources[id]
		var pos: Vector2 = r["pos"]
		if pos.distance_to(ground) > 6.0:
			continue
		var half: float = float(r["size"]) * 0.5 + 0.15
		if absf(ground.x - pos.x) <= half and absf(ground.y - pos.y) <= half:
			return int(id)
		var d := _cam.unproject_position(_at(pos, 0.9)).distance_to(screen)
		if d < best_d:
			best_d = d
			best = int(id)
	return best


func _building_at(ground: Vector2) -> int:
	for id in sim.buildings:
		var b: Dictionary = sim.buildings[id]
		if Rect2(Vector2(b["cell"]), Vector2(b["size"], b["size"])).grow(0.2).has_point(ground):
			return int(id)
	return -1


func _select(rect: Rect2, add: bool) -> void:
	if not add:
		selected.clear()
	sel_building = -1
	inspect = -1
	var before := selected.size()
	if rect.size.length() > 12.0:      # рамка: все свои юниты внутри
		for id in views:
			if int(sim.units[id]["player"]) != local_player or selected.has(id):
				continue
			var mid: Vector3 = (views[id]["node"] as Node3D).position + Vector3(0, float(views[id]["parts"]["height"]) * 0.5, 0)
			if not _cam.is_position_behind(mid) and rect.has_point(_cam.unproject_position(mid)):
				selected.append(id)
		if selected.size() > before or rect.size.length() > 40.0:
			return
		# маленькая пустая рамка — это просто дрогнувшая при щелчке мышь: считаем обычным щелчком
	rect = Rect2(_drag_from if rect.grow(1.0).has_point(_drag_from) else rect.position, Vector2.ZERO)
	var own := _unit_at(rect.position, true)
	if own >= 0:
		if _double:      # двойной щелчок: все такие же юниты на экране
			var screen := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
			for id in views:
				var u: Dictionary = sim.units[id]
				if int(u["player"]) == local_player and String(u["key"]) == String(sim.units[own]["key"]) and not selected.has(id):
					var at: Vector3 = (views[id]["node"] as Node3D).position
					if not _cam.is_position_behind(at) and screen.has_point(_cam.unproject_position(at)):
						selected.append(id)
		elif not selected.has(own):
			selected.append(own)
		return
	if not selected.is_empty():
		return
	inspect = _unit_at(rect.position, false)   # чужого юнита можно рассмотреть
	if inspect < 0:
		inspect = _unit_at(rect.position, true, 38.0, true)      # или союзного
	if inspect < 0:
		var hit = _ground_point(rect.position)
		var b := _building_under(rect.position, Vector2(hit.x, hit.z) if hit != null else Vector2(-99, -99))
		if b >= 0 and _building_seen(sim.buildings[b]):
			sel_building = b


func _ground_point(screen: Vector2):
	# Земля неровная, поэтому идём вдоль луча от камеры, пока не упрёмся в рельеф.
	var from := _cam.project_ray_origin(screen)
	var dir := _cam.project_ray_normal(screen)
	if dir.y > -0.01:
		return null
	var t := maxf(0.0, (from.y - 8.0) / -dir.y)
	var end := (from.y + 2.0) / -dir.y
	var prev := t
	while t < end:
		var p := from + dir * t
		if p.y <= terrain.height(Vector2(p.x, p.z)):
			var lo := prev
			var hi := t
			for i in 8:
				var mid := (lo + hi) * 0.5
				var q := from + dir * mid
				if q.y <= terrain.height(Vector2(q.x, q.z)):
					hi = mid
				else:
					lo = mid
			return from + dir * hi
		prev = t
		t += 0.4
	return from + dir * end


## Точка на карте -> точка в 3D с учётом высоты земли.
func _at(p: Vector2, lift: float = 0.0) -> Vector3:
	return Vector3(p.x, terrain.height(p) + lift, p.y)


## Материал отметок приказа: рисуется поверх всего, чтобы деревья и юниты её не закрывали.
func _mark_mat(color: Color) -> StandardMaterial3D:
	var m := _flat(Color(color.r, color.g, color.b, 0.95), true)
	m.no_depth_test = true
	m.render_priority = 10
	return m


## Отметка приказа на земле: сужающееся кольцо, расходящаяся волна и стрелка, опускающаяся в точку.
func _ping(target: Vector2, color: Color) -> void:
	var ring := _torus(0.75, 0.14, color, 28)
	ring.material_override = _mark_mat(color)
	ring.position = _at(target, 0.12)
	ring.scale = Vector3(1.0, 0.25, 1.0)
	add_child(ring)
	var tw := create_tween()
	tw.tween_property(ring, "scale", Vector3(0.25, 0.25, 0.25), 0.5).set_ease(Tween.EASE_IN)
	tw.tween_callback(ring.queue_free)
	var wave := _torus(0.5, 0.05, color, 28)
	wave.material_override = _mark_mat(color)
	wave.position = _at(target, 0.1)
	wave.scale = Vector3(0.6, 0.25, 0.6)
	add_child(wave)
	var ww := create_tween()
	ww.tween_property(wave, "scale", Vector3(2.2, 0.25, 2.2), 0.55).set_ease(Tween.EASE_OUT)
	ww.parallel().tween_property(wave.material_override, "albedo_color:a", 0.0, 0.55)
	ww.tween_callback(wave.queue_free)
	var arrow := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.22
	cone.bottom_radius = 0.0
	cone.height = 0.5
	cone.radial_segments = 4
	cone.rings = 1
	arrow.mesh = cone
	arrow.material_override = _mark_mat(color)
	arrow.position = _at(target, 1.6)
	add_child(arrow)
	var aw := create_tween()
	aw.tween_property(arrow, "position:y", arrow.position.y - 1.25, 0.28).set_ease(Tween.EASE_IN)
	aw.tween_property(arrow, "scale", Vector3(1.6, 0.2, 1.6), 0.12)
	aw.tween_property(arrow.material_override, "albedo_color:a", 0.0, 0.15)
	aw.tween_callback(arrow.queue_free)


## Цель приказа коротко вспыхивает цветом (подсвечивается сама модель), плюс кольцо под ней.
func _mark_target(node: Node3D, pos: Vector2, radius: float, color: Color) -> void:
	var ring := _torus(radius, 0.09, color, 32)
	ring.material_override = _mark_mat(color)
	ring.position = _at(pos, 0.12)
	ring.scale = Vector3(1.3, 0.25, 1.3)
	add_child(ring)
	var tw := create_tween()
	tw.tween_property(ring, "scale", Vector3(1.0, 0.25, 1.0), 0.12)
	tw.tween_interval(0.3)
	tw.tween_property(ring.material_override, "albedo_color:a", 0.0, 0.25)
	tw.tween_callback(ring.queue_free)
	if node == null or not is_instance_valid(node):
		return
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow.albedo_color = Color(color.r, color.g, color.b, 0.0)
	_set_overlay(node, glow, null)
	var gt := create_tween()
	for i in 2:      # две вспышки за полсекунды
		gt.tween_property(glow, "albedo_color:a", 0.85, 0.07)
		gt.tween_property(glow, "albedo_color:a", 0.15, 0.16)
	gt.tween_property(glow, "albedo_color:a", 0.0, 0.12)
	gt.tween_callback(func() -> void:
		if is_instance_valid(node):
			_set_overlay(node, null, glow))


## Накладывает (или снимает) подсветку на все детали модели. Снимается только своя подсветка.
func _set_overlay(node: Node, m: Material, only_if: Material) -> void:
	for c in node.get_children():
		if c is GeometryInstance3D and (only_if == null or (c as GeometryInstance3D).material_overlay == only_if):
			(c as GeometryInstance3D).material_overlay = m
		_set_overlay(c, m, only_if)


## Цель приказа по номеру: юнит, здание, ресурс или предмет на земле.
func _mark_entity(id: int, color: Color) -> void:
	if sim.units.has(id) and views.has(id):
		_mark_target(views[id]["node"], sim.units[id]["pos"], float(sim.units[id]["radius"]) + 0.3, color)
	elif sim.buildings.has(id):
		_mark_target(bviews.get(id), sim.buildings[id]["pos"], float(sim.buildings[id]["size"]) * 0.75, color)
	elif sim.resources.has(id):
		_mark_target(rviews.get(id), sim.resources[id]["pos"], float(sim.resources[id]["size"]) * 0.75 + 0.25, color)
	elif sim.loot.has(id):
		_mark_target(lviews.get(id), sim.loot[id]["pos"], 0.6, color)


# =====================================================================
#  АВТОПРОВЕРКА (запускается только с параметрами командной строки)
# =====================================================================

func _mine(workers: bool) -> Array:
	var out: Array = []
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if int(u["player"]) == local_player and sim.is_worker(u) == workers:
			out.append(id)
	out.sort()
	return out


func _nearest_of(player: int, from: Vector2) -> int:
	var best := -1
	var best_d := INF
	for id in sim.units:
		var u: Dictionary = sim.units[id]
		if int(u["player"]) == player and (u["pos"] as Vector2).distance_to(from) < best_d:
			best_d = (u["pos"] as Vector2).distance_to(from)
			best = int(id)
	return best


func _test_heroes() -> Array:
	var out: Array = []
	for id in _mine(false):
		if sim.units[id]["hero"]:
			out.append(id)
	return out


## Проверка сетевой игры: обе копии отдают приказы и сравнивают итог.
func _net_test() -> void:
	if sim.tick == 20 and _frames >= 0:
		_frames = -1
		var w := _mine(true)
		var base: Vector2 = terrain.bases[local_player]
		_issue({"type": "gather", "player": local_player, "units": [w[0], w[1]], "target": sim.nearest_resource("gold", base, 99.0)})
		_issue({"type": "gather", "player": local_player, "units": [w[2]], "target": sim.nearest_resource("tree", base, 99.0)})
		_issue({"type": "train", "player": local_player, "building": sim.nearest_hall(sim.units[w[0]]), "unit": "worker"})
		_issue({"type": "amove", "player": local_player, "units": _mine(false), "target": _center()})
		online.send_chat("привет от игрока %d всем" % (local_player + 1), false)
		online.send_chat("план для союзников от игрока %d" % (local_player + 1), true)
		online.send_ping(base)
		for p in sim.players:      # подарок союзнику проходит через сеть как обычная команда
			if sim.allies(int(p), local_player):
				_issue({"type": "gift", "player": local_player, "to": int(p), "gold": 50})
		var other := (local_player + 1) % (sim.players.size() - 1)
		var foreign: Array = []
		for id in sim.units:
			if int(sim.units[id]["player"]) == other:
				foreign.append(id)
		_issue({"type": "move", "player": other, "units": foreign, "target": _center()})      # подделка: сервер подпишет её моим номером, чужие юниты не сдвинутся
	if sim.tick >= int(_test["until"]):
		if not _paused:
			print("NETRESULT player=%d tick=%d sum=%d units=%d gold=%d" % [local_player, sim.tick, sim.checksum(), sim.units.size(), int(sim.players[local_player]["gold"])])
			_paused = true       # дальше не считаем, даём второй копии дойти до того же тика
			get_tree().create_timer(4.0).timeout.connect(get_tree().quit)


## Автоматическая сетевая проверка: --autonet=host|join --login=… --pass=… [--addr=127.0.0.1] [--port=24600]
## [--humans=2] [--ai_slots=1] [--teams=1,1,2] --until=N. Хозяин (host) сам создаёт игру и играет в ней.
func _autonet_begin() -> void:
	var addr := String(_test.get("addr", "127.0.0.1"))
	var port := int(_test.get("port", Online.DEFAULT_PORT))
	var teams: Array = []
	if _test.has("teams"):
		for t in String(_test["teams"]).split(","):
			teams.append(int(t))
	multiplayer.connected_to_server.connect(func() -> void:
		online.register(String(_test["login"]), String(_test.get("pass", "test1234"))))
	online.auth_changed.connect(func() -> void:
		if online.profile.is_empty():
			online.login(String(_test["login"]), String(_test.get("pass", "test1234")))
		elif online.room.is_empty():
			if String(_test["autonet"]) == "host":
				online.create_room("autotest", int(_test.get("size", 96)), int(_test.get("humans", 2)) + int(_test.get("ai_slots", 0)))
			else:
				online.refresh_rooms())
	online.rooms_changed.connect(func() -> void:
		if online.room.is_empty():
			for r in online.rooms:
				if not r["started"]:
					online.join_room(int(r["id"]))
					return
			get_tree().create_timer(0.5).timeout.connect(online.refresh_rooms))
	online.room_changed.connect(func() -> void:
		if not online.is_host() or online.room.is_empty() or online.room["started"]:
			return
		var humans := 0
		var ai_set := 0
		for i in (online.room["slots"] as Array).size():
			var s: Dictionary = online.room["slots"][i]
			if s["kind"] == "human":
				humans += 1
			elif s["kind"] == "ai":
				ai_set += 1
			elif s["kind"] == "open" and ai_set < int(_test.get("ai_slots", 0)) and i >= int(_test.get("humans", 2)):
				online.set_slot(i, "ai", String(_test.get("ai_race", "undead")), "normal", int(teams[i]) if i < teams.size() else 0)
				return
		if humans < int(_test.get("humans", 2)) or ai_set < int(_test.get("ai_slots", 0)):
			return
		for i in mini(teams.size(), (online.room["slots"] as Array).size()):      # раздать команды
			var s: Dictionary = online.room["slots"][i]
			if int(s.get("team", 0)) != int(teams[i]):
				online.set_slot(i, String(s["kind"]), String(s.get("race", "humans")), String(s.get("diff", "normal")), int(teams[i]))
				return
		online.start_game())
	if String(_test["autonet"]) == "host":
		(func() -> void:
			if online.host(port) != OK:
				print("NET: не удалось создать игру")
				get_tree().quit(1)
				return
			online.register(String(_test["login"]), String(_test.get("pass", "test1234")))).call_deferred()
	else:
		(func() -> void: online.connect_to(addr, port)).call_deferred()


func _run_test() -> void:
	if _test.has("autonet"):
		if sim != null:
			_net_test()
		return
	_frames += 1
	if sim == null:
		if _frames == int(_test.get("frames", 60)):
			get_viewport().get_texture().get_image().save_png(String(_test.get("shot", "user://menu.png")))
			get_tree().quit()
		return
	var base: Vector2 = terrain.bases[local_player]
	var p: Dictionary = sim.players[local_player]
	if _frames == 5:
		if _test.has("eco"):
			var w := _mine(true)
			var hall_id := sim.nearest_hall(sim.units[w[0]])
			var spot := sim.nearest_free_cell(Vector2i(base + (_center() - base).normalized() * 9.0))
			sim.push_command({"type": "build", "player": local_player, "units": [w[0]], "building": "supply", "cell": spot + Vector2i(2, 2)})
			sim.push_command({"type": "gather", "player": local_player, "units": [w[1], w[2]], "target": sim.nearest_resource("gold", base, 99.0)})
			sim.push_command({"type": "gather", "player": local_player, "units": [w[3]], "target": sim.nearest_resource("tree", base, 99.0)})
			sim.push_command({"type": "train", "player": local_player, "building": hall_id, "unit": "worker"})
			sel_building = hall_id
		if _test.has("hero"):
			# алтарь и оба героя сразу, чтобы не ждать найма
			p["gold"] = 3000
			p["wood"] = 2000
			p["supply_cap"] = int(p["supply_cap"]) + 40
			var front: Vector2 = sim.units[(_mine(false) + _mine(true))[0]]["pos"]
			var adef: Dictionary = p["data"]["buildings"]["altar"]
			var cell := Vector2i(base) + Vector2i(-7, 3)
			for dx in range(-8, 9):
				for dy in range(-8, 9):
					if sim.can_place(5, Vector2i(base) + Vector2i(dx, dy) - Vector2i(1, 1)) and Vector2(dx, dy).length() > 6.0 and Vector2(dx, dy).length() < Vector2(cell - Vector2i(base)).length() + 0.5:
						cell = Vector2i(base) + Vector2i(dx, dy)
			var altar := sim.spawn_building(local_player, "altar", adef, cell)
			var n := 0
			for key in adef["trains"]:
				var hid := sim.spawn_unit(local_player, String(key), p["data"]["units"][key], front + Vector2(1.5 + n * 2.0, 2.5))
				p["heroes"][key] = {"state": "alive", "altar": altar}
				n += 1
			sel_building = altar
			_rig.position = Vector3(front.x + 2.0, 0, front.y + 3.0)
		if _test.has("show"):      # все здания расы в ряд, чтобы посмотреть модели
			var n2 := 0
			var placed := 0
			for dx in range(-14, 30):
				var keys: Array = p["data"]["buildings"].keys()
				if placed >= keys.size():
					break
				var bdef: Dictionary = p["data"]["buildings"][keys[placed]]
				var c := Vector2i(base) + Vector2i(dx, 7)
				if dx >= n2 and sim.can_place(int(bdef["size"]), c):
					sim.spawn_building(local_player, String(keys[placed]), bdef, c)
					placed += 1
					n2 = dx + int(bdef["size"]) + 1
			_rig.position = Vector3(base.x + 4.0, 0, base.y + 9.0)
		if _test.has("heavy"):
			var hp: Vector2 = sim.units[(_mine(false) + _mine(true))[0]]["pos"]
			for i in 2:
				sim.spawn_unit(local_player, "heavy", p["data"]["units"]["heavy"], hp + Vector2(-2.0 - i * 2.2, 2.5))
		if _test.has("battle"):
			selected = _mine(false)
			var foe := _nearest_of(Sim.NEUTRAL, base)
			sim.push_command({"type": "attack", "player": local_player, "units": selected.duplicate(), "target": foe})
		if _test.has("war"):
			selected = _mine(false)
			sim.push_command({"type": "amove", "player": local_player, "units": selected.duplicate(), "target": terrain.bases[1]})
		if _test.has("selw"):
			selected = _mine(true)
		if _test.has("selh"):
			selected = [_test_heroes()[int(_test["selh"])]]
			sel_building = -1
		if _test.has("sela"):
			selected = _mine(false)
			sel_building = -1
		if _test.has("units"):
			var up: Vector2 = sim.units[(_mine(false) + _mine(true))[1]]["pos"]
			_rig.position = Vector3(up.x, 0, up.y + 0.6)
		if _test.has("seeshop"):
			for bid in sim.buildings:
				if String(sim.buildings[bid]["def"].get("role", "")) == "shop":
					sel_building = int(bid)
					_focus(sim.buildings[bid]["pos"])
					break
		if _test.has("fall"):
			var fp2: Vector2 = terrain.plateau_corner + terrain.fall_dir * (terrain.plateau_r + 3.0)
			_rig.position = Vector3(fp2.x, 0, fp2.y + 1.0)
		if _test.has("cam"):
			var c := String(_test["cam"]).split(",")
			_rig.position = Vector3(float(c[0]), 0, float(c[1]))
			_zoom = float(c[2])
			_apply_zoom()
		if _test.has("zoom"):
			_zoom = float(_test["zoom"])
			_apply_zoom()
	if _test.has("sel") and _frames == 8:      # выбрать своё здание по роли: --sel=hall
		for bid in sim.buildings:
			if int(sim.buildings[bid]["player"]) == local_player and String(sim.buildings[bid]["def"].get("role", "")) == String(_test["sel"]):
				selected.clear()
				sel_building = int(bid)
	if _test.has("tier") and _frames == int(_test["tier"]):
		sim.players[local_player]["gold"] = 5000
		sim.players[local_player]["wood"] = 5000
		for bid in sim.buildings:
			var tb: Dictionary = sim.buildings[bid]
			if int(tb["player"]) == local_player and tb["def"].get("researches", []).has("tier"):
				_issue({"type": "research", "player": local_player, "building": bid, "upgrade": "tier"})
	if _test.has("cast") and _frames == int(_test["cast"]):
		# каждый герой применяет все свои заклинания
		for hid in _test_heroes():
			var h: Dictionary = sim.units[hid]
			h["hp"] = float(h["max_hp"]) * 0.5
			var foe := _nearest_of(Sim.NEUTRAL, h["pos"])
			for ab in h["def"]["abilities"]:
				h["skills"][ab["key"]] = 1      # для проверки — все способности сразу изучены
			for ab in h["def"]["abilities"]:
				if String(ab["type"]) != "active":
					continue
				h["cds"] = {}
				var cmd := {"type": "cast", "player": local_player, "unit": hid, "ability": ab["key"], "target": hid, "pos": (h["pos"] as Vector2) + Vector2(2, 0)}
				if not sim.units.has(foe):       # прошлое заклинание могло убить цель
					foe = _nearest_of(Sim.NEUTRAL, h["pos"])
				if String(ab["target"]) == "unit_enemy":
					cmd["target"] = foe
					h["pos"] = (sim.units[foe]["pos"] as Vector2) + Vector2(4, 0)
				sim.push_command(cmd)
				sim.step()
				sim.step()
				_consume_events()
			print("  hero %s hp=%d mana=%d buffs=%d pos=%s" % [h["key"], int(h["hp"]), int(h["mana"]), (h["buffs"] as Array).size(), h["pos"]])
			h["skills"] = {}
	if _test.has("bag") and _frames == int(_test["bag"]):
		# сумка: выпить зелье, выбросить предмет и снова поднять, уничтожить
		var hid3: int = _test_heroes()[0]
		var h3: Dictionary = sim.units[hid3]
		for ik in ["potion_heal", "axe", "belt", "fang"]:
			sim._give_item(h3, ik)
		h3["hp"] = 100.0
		var hp0 := int(h3["max_hp"])
		sim.push_command({"type": "use_item", "player": local_player, "unit": hid3, "slot": 0})
		sim.step()
		var after_potion := int(h3["hp"])
		sim.push_command({"type": "drop_item", "player": local_player, "unit": hid3, "slot": 1})      # belt
		sim.step()
		var hp_dropped := int(h3["max_hp"])
		var lid: int = sim.loot.keys()[0] if not sim.loot.is_empty() else -1
		sim.push_command({"type": "pickup", "player": local_player, "unit": hid3, "target": lid})
		for i in 20:
			sim.step()
		sim.push_command({"type": "destroy_item", "player": local_player, "unit": hid3, "slot": 0})   # axe
		sim.step()
		_consume_events()
		print("  bag: hp after potion=%d, max_hp %d -> %d after drop -> %d after pickup, loot left=%d, items=%s, crit=%.2f lifesteal=%.2f" % [after_potion, hp0, hp_dropped, int(h3["max_hp"]), sim.loot.size(), h3["items"], float(h3["crit"]), float(h3["lifesteal"])])
	if _test.has("xp") and _frames == int(_test["xp"]):
		for hid in _test_heroes():
			sim._gain_xp(sim.units[hid], 700)
			var h: Dictionary = sim.units[hid]
			for ab in h["def"]["abilities"]:      # тратим очки навыков, как это сделал бы игрок
				while sim.learn_block(h, String(ab["key"])) == "":
					sim.push_command({"type": "learn", "player": local_player, "unit": hid, "ability": ab["key"]})
					sim.step()
			print("  xp: %s level=%d xp=%d hp=%d dmg=%.0f points=%d skills=%s | %s" % [h["key"], h["level"], h["xp"], int(h["max_hp"]), float(h["base"]["damage"]), sim.skill_points(h), h["skills"], _describe(h["def"]["abilities"][0], sim.rank(h, String(h["def"]["abilities"][0]["key"])))])
	if _test.has("shop") and _frames == int(_test["shop"]):
		for bid in sim.buildings:
			if String(sim.buildings[bid]["def"].get("role", "")) == "shop":
				var hid2: int = _test_heroes()[0]
				sim.units[hid2]["pos"] = (sim.buildings[bid]["pos"] as Vector2) + Vector2(3, 0)
				for ik in ["boots", "blade", "belt", "plate", "ring"]:
					sim.push_command({"type": "buy", "player": local_player, "unit": hid2, "shop": bid, "item": ik})
				sim.step()
				sim.step()
				_consume_events()
				var hh: Dictionary = sim.units[hid2]
				print("  shop: items=%s gold=%d hp=%d dmg=%.0f armor=%.1f speed=%.2f" % [hh["items"], p["gold"], int(hh["max_hp"]), float(hh["damage"]), float(hh["armor"]), float(hh["speed"])])
				break
	if _test.has("cancel") and _frames == int(_test["cancel"]):
		var w2 := _mine(true)
		var hall2 := sim.nearest_hall(sim.units[w2[0]])
		var g0: int = int(p["gold"])
		var s0: int = int(p["supply_used"])
		sim.push_command({"type": "train", "player": local_player, "building": hall2, "unit": "worker"})
		sim.step()
		sim.push_command({"type": "cancel", "player": local_player, "building": hall2})
		sim.step()
		var spot2 := sim.nearest_free_cell(Vector2i(base + (_center() - base).normalized() * 9.0)) + Vector2i(2, 2)
		sim.push_command({"type": "build", "player": local_player, "units": [w2[0]], "building": "supply", "cell": spot2})
		sim.step()
		var count_before := sim.buildings.size()
		sim.push_command({"type": "cancel", "player": local_player, "building": sim.buildings.keys().max()})
		sim.step()
		_consume_events()
		print("  cancel: gold %d -> %d, supply %d -> %d, buildings %d -> %d, can rebuild there: %s" % [g0, p["gold"], s0, p["supply_used"], count_before, sim.buildings.size(), sim.can_place(2, spot2)])
	if _test.has("killhero") and _frames == int(_test["killhero"]):
		var hid: int = _test_heroes()[0]
		var key := String(sim.units[hid]["key"])
		sim._kill(sim.units[hid], 1)
		_consume_events()
		print("  after death: ", p["heroes"][key])
		sim.push_command({"type": "train", "player": local_player, "building": sel_building, "unit": key})
	if _test.has("save") and _frames == int(_test["save"]):
		_save_game()
		print("  saved at tick ", sim.tick)
	if _test.has("results") and _frames == int(_test["results"]):
		_show_results(true)
	if _test.has("pause") and _frames == int(_test["pause"]):
		_toggle_pause()
	if _frames == int(_test.get("frames", 60)):
		var counts: Dictionary = {}
		for id in sim.units:
			counts[int(sim.units[id]["player"])] = int(counts.get(int(sim.units[id]["player"]), 0)) + 1
		print("seed=%d tick=%d gold=%d wood=%d supply=%d/%d units mine=%d enemy=%d neutral=%d deaths=%d trees=%d over=%s players=%d" % [sim.seed_value, sim.tick, p["gold"], p["wood"], p["supply_used"], p["supply_cap"], int(counts.get(0, 0)), int(counts.get(1, 0)), int(counts.get(Sim.NEUTRAL, 0)), _deaths, sim.resources.size(), sim.game_over, sim.players.size() - 1])
		var per: Array = []
		for pl in sim.players:
			if int(pl) != Sim.NEUTRAL:
				per.append("P%d %s units=%d tier=%d heroes=%d%s" % [int(pl), sim.players[pl]["race"], int(counts.get(int(pl), 0)), sim.tier(int(pl)), (sim.players[pl]["heroes"] as Dictionary).size(), " DEFEATED" if sim.players[pl].get("defeated", false) else ""])
		print("  players: ", " | ".join(per))
		print("  heroes=", p["heroes"])
		for uid in sim.units:
			if sim.units[uid]["hero"]:
				print("  HEROITEMS player=%d %s level=%d items=%s skills=%s" % [sim.units[uid]["player"], sim.units[uid]["key"], sim.units[uid]["level"], sim.units[uid]["items"], sim.units[uid]["skills"]])
		for hid in _test_heroes():
			print("  hero %s level=%d xp=%d" % [sim.units[hid]["key"], sim.units[hid]["level"], sim.units[hid]["xp"]])
		for ai in ais:
			var ep: Dictionary = sim.players[ai.me]
			var eb: Dictionary = {}
			for id in sim.buildings:
				if int(sim.buildings[id]["player"]) == ai.me:
					eb[sim.buildings[id]["key"]] = int(eb.get(sim.buildings[id]["key"], 0)) + 1
			print("  AI%d %s gold=%d wood=%d supply=%d/%d state=%s buildings=%s heroes=%s" % [ai.me, ep["data"]["id"], ep["gold"], ep["wood"], ep["supply_used"], ep["supply_cap"], ai.s, eb, ep["heroes"].keys()])
		for id in sim.buildings:
			var b: Dictionary = sim.buildings[id]
			if int(b["player"]) == local_player:
				print("  building %s done=%s hp=%d queue=%d" % [b["key"], b["done"], int(b["hp"]), (b["queue"] as Array).size()])
		if _test.has("shot"):
			get_viewport().get_texture().get_image().save_png(String(_test["shot"]))
		get_tree().quit()
