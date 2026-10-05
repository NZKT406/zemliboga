extends Node3D
## Фон главного меню: живая сценка сражения людей и огров из моделей самой игры.

const Models = preload("res://scripts/models.gd")
const Anim = preload("res://scripts/anim.gd")
const BLUE := Color("#2f6fd6")
const RED := Color("#c8372d")

var _fighters: Array = []
var _cam: Camera3D
var _time := 0.0


func setup(races: Dictionary) -> void:
	var env := Environment.new()
	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color("#4a545e")
	sky.sky_horizon_color = Color("#b08a62")
	sky.ground_bottom_color = Color("#2a3326")
	sky.ground_horizon_color = Color("#b08a62")
	var sky_res := Sky.new()
	sky_res.sky_material = sky
	env.background_mode = Environment.BG_SKY
	env.sky = sky_res
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#9a8f86")
	env.ambient_light_energy = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color("#8a7a66")
	env.fog_density = 0.012
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.82
	env.adjustment_contrast = 1.12
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-32), deg_to_rad(40), 0)
	sun.light_color = Color("#ffd9a8")
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)

	# земля, холмы и лес на заднем плане
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(160, 160)
	ground.mesh = plane
	ground.material_override = Models.mat(Color("#5f7a40"))
	add_child(ground)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12
	for i in 9:
		Models.ball(self, rng.randf_range(6, 12), Vector3(-44 + i * 11, -3.0, rng.randf_range(-34, -24)), Color("#4f8a44").lerp(Color("#6fa85a"), rng.randf()), Vector3(1.6, 0.8, 1))
	for i in 46:
		var t := Models.tree(i * 13 + 2)
		t.position = Vector3(rng.randf_range(-30, 30), 0, rng.randf_range(-22, -9))
		t.scale *= rng.randf_range(1.2, 2.0)
		add_child(t)
	for i in 30:
		var p := Vector3(rng.randf_range(-14, 14), 0.1, rng.randf_range(-6, 5))
		Models.ball(self, 0.09, p, [Color("#ffffff"), Color("#ffd94a"), Color("#e8484f")][i % 3])
	for i in 8:
		Models.ball(self, rng.randf_range(0.3, 0.7), Vector3(rng.randf_range(-13, 13), 0.0, rng.randf_range(-7, 3)), Color("#8d867a"), Vector3(1, 0.6, 1))

	# замки сторон на заднем плане
	var hall := Models.building({"shape": "townhall"}, 4, BLUE)
	hall.position = Vector3(-11, 0, -8)
	hall.rotation.y = 0.5
	hall.scale = Vector3.ONE * 1.4
	add_child(hall)
	var tower := Models.building({"shape": "watchtower"}, 2, BLUE)
	tower.position = Vector3(-6.5, 0, -6)
	add_child(tower)
	var lair := Models.building({"shape": "ogre_lair"}, 4, RED)
	lair.position = Vector3(11, 0, -8)
	lair.rotation.y = -0.6
	lair.scale = Vector3.ONE * 1.4
	add_child(lair)
	var totem := Models.building({"shape": "ogre_totem"}, 3, RED)
	totem.position = Vector3(6.5, 0, -6.5)
	add_child(totem)

	# бойцы: люди слева, огры справа
	var h: Dictionary = races.get("humans", {}).get("units", {})
	var o: Dictionary = races.get("ogres", {}).get("units", {})
	var lineup := [
		[h, "paladin", -1.5, 0.6], [h, "melee", -1.3, -1.4], [h, "melee", -1.6, 2.4], [h, "heavy", -3.6, -2.6],
		[h, "ranged", -4.6, 0.2], [h, "ranged", -4.9, 2.0], [h, "archmage", -5.6, -1.2],
		[o, "chieftain", 1.5, 0.6], [o, "melee", 1.2, -1.5], [o, "melee", 1.4, 2.5], [o, "heavy", 3.9, -2.8],
		[o, "ranged", 4.6, 1.6], [o, "shaman", 5.4, -0.6],
	]
	for i in lineup.size():
		var item: Array = lineup[i]
		var units: Dictionary = item[0]
		if not units.has(item[1]):
			continue
		var left: bool = float(item[2]) < 0.0
		var node := Models.unit(units[item[1]]["model"], BLUE if left else RED)
		node.position = Vector3(float(item[2]), 0, float(item[3]))
		node.rotation.y = PI / 2 if left else -PI / 2
		add_child(node)
		_fighters.append({
			"node": node, "parts": node.get_meta("parts"), "phase": float(i), "walk": 0.0,
			"atk_t": -1.0, "atk_len": 0.9, "next": 0.4 + fmod(i * 0.37, 1.6),
			"period": float(units[item[1]].get("attack_cooldown", 1.5)), "front": absf(float(item[2])) < 2.0,
		})

	_cam = Camera3D.new()
	_cam.fov = 42
	_cam.h_offset = -1.9     # сцена смещена вправо: слева стоят кнопки меню
	add_child(_cam)


func _process(delta: float) -> void:
	_time += delta
	for f in _fighters:
		f["next"] = float(f["next"]) - delta
		if float(f["next"]) <= 0.0 and float(f["atk_t"]) < 0.0:
			f["atk_t"] = 0.0
			f["next"] = float(f["period"]) + randf() * 0.5
			if f["front"]:
				get_tree().create_timer(float(f["atk_len"]) * 0.5).timeout.connect(_spark.bind((f["node"] as Node3D).position))
		Anim.animate(f, false, 0.0, false, delta, _time)
	if _cam != null:
		_cam.position = Vector3(sin(_time * 0.12) * 1.6, 2.7 + sin(_time * 0.2) * 0.2, 13.5)
		_cam.look_at(Vector3(0, 1.5, 0), Vector3.UP)


func _spark(from: Vector3) -> void:
	var s := Models.ball(self, 0.16, Vector3(from.x * 0.25, 1.3 + randf() * 0.5, from.z + randf_range(-0.2, 0.2)), Color("#fff3b0"), Vector3.ONE, true)
	var tw := create_tween()
	tw.tween_property(s, "scale", Vector3.ONE * 2.4, 0.12)
	tw.tween_property(s, "scale", Vector3.ZERO, 0.12)
	tw.tween_callback(s.queue_free)
