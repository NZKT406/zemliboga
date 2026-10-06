extends RefCounted
## Анимации юнитов: ходьба, удар, выстрел, работа, смерть.
## Никаких заготовленных клипов — позы считаются формулами каждый кадр,
## поэтому одна и та же анимация подходит юниту любого размера.


## Значение по ключевым точкам [[время, значение], ...] с плавным переходом.
static func key(t: float, keys: Array) -> float:
	if t <= float(keys[0][0]):
		return float(keys[0][1])
	for i in range(1, keys.size()):
		if t <= float(keys[i][0]):
			var k := (t - float(keys[i - 1][0])) / maxf(0.0001, float(keys[i][0]) - float(keys[i - 1][0]))
			return lerpf(float(keys[i - 1][1]), float(keys[i][1]), smoothstep(0.0, 1.0, k))
	return float(keys[keys.size() - 1][1])


## v — запись о юните у графики: parts, phase, walk, atk_t, atk_len.
static func animate(v: Dictionary, moving: bool, speed: float, working: bool, delta: float, time: float) -> void:
	var p: Dictionary = v["parts"]
	var kind := String(p["kind"])
	var s: float = float(p["scale"])
	var body: Node3D = p["body"]
	var torso: Node3D = p["torso"]
	var head: Node3D = p["head"]
	var legs: Array = p["legs"]
	var arm_l: Node3D = p["arm_l"]
	var arm_r: Node3D = p["arm_r"]

	v["walk"] = move_toward(float(v["walk"]), 1.0 if moving else 0.0, delta * 7.0)
	var w: float = v["walk"]
	if moving:
		v["phase"] = float(v["phase"]) + delta * speed * (2.4 if kind == "humanoid" else 2.9) / maxf(0.6, s)
	var ph: float = v["phase"]
	var idle := sin(time * 1.7 + ph) * 0.03

	var body_y := 0.0
	var body_z := 0.0
	var body_rx := 0.0
	var torso_rx := idle
	var torso_ry := 0.0
	var al := 0.0
	var ar := 0.0
	var head_rx := 0.0

	match kind:
		"humanoid":
			legs[0].rotation.x = sin(ph) * 0.75 * w
			legs[1].rotation.x = -sin(ph) * 0.75 * w
			al = sin(ph) * 0.5 * w
			ar = -sin(ph) * 0.5 * w
			body_y = absf(sin(ph)) * 0.05 * w * s
			torso_rx += 0.08 * w
		"mounted":
			var offs := [0.0, 0.5, PI, PI + 0.5]
			for i in legs.size():
				legs[i].rotation.x = sin(ph + float(offs[i])) * 0.7 * w
			body_y = absf(sin(ph)) * 0.09 * w
			body_rx = sin(ph) * 0.05 * w
			ar = -0.25
		"quad":
			var offs := [0.0, PI, PI, 0.0]
			for i in legs.size():      # у паука ног 8: фазы повторяются по кругу
				legs[i].rotation.x = sin(ph + float(offs[i % offs.size()]) + (0.6 if i >= 4 else 0.0)) * 0.8 * w
			body_y = absf(sin(ph * 2.0)) * 0.04 * w * s
			head_rx = idle * 2.0
		"slime":       # слизень прыгает и сплющивается
			var hop := absf(sin(ph * 1.4))
			body_y = hop * 0.25 * w * s
			var sq := (0.08 + 0.12 * w * (1.0 - hop)) * (0.6 + 0.4 * sin(time * 3.0 + ph))
			body.scale = Vector3(1.0 + sq, 1.0 - sq, 1.0 + sq) * s
		"dragon":      # дракон: тяжёлая поступь, крылья медленно колышутся, хвост качается
			var offs := [0.0, PI, PI, 0.0]
			for i in legs.size():
				legs[i].rotation.x = sin(ph * 0.7 + float(offs[i])) * 0.45 * w
			body_y = absf(sin(ph * 0.7)) * 0.08 * w
			var flap := sin(time * 1.3 + ph) * 0.25
			var wings: Array = p["wings"]
			wings[0].rotation.z = -flap - 0.1
			wings[1].rotation.z = flap + 0.1
			(p["tail"] as Node3D).rotation.y = sin(time * 0.9 + ph) * 0.3
			head_rx = sin(time * 0.8) * 0.06
		"engine":      # осадная машина: колёса крутятся, корпус слегка покачивается
			for i in legs.size():
				legs[i].rotation.x = ph * 1.6
			body_rx = sin(ph * 3.0) * 0.015 * w
			torso_rx = 0.0

	# особые позы рас (их выставляет графика по состоянию юнита)
	var head_ry := 0.0
	var pose := String(v.get("pose", ""))
	match pose:
		"eat":         # гуль склонился над телом и рвёт его
			var bite := sin(time * 9.0 + ph)
			torso_rx = 0.75 + bite * 0.18
			head_rx = 0.35 + bite * 0.15
			al = -1.0 + bite * 0.35
			ar = -1.0 - bite * 0.35
			body_y -= 0.08 * s
		"entrench":    # гном окопался: присел, щит вперёд
			body_y -= 0.1 * s
			torso_rx += 0.15
			al = -1.25
			if kind == "humanoid" and legs.size() >= 2:
				legs[0].rotation.x = 0.75
				legs[1].rotation.x = -0.45
		"swim":        # наг плывёт: гребёт руками, корпус наклонён
			torso_rx += 0.12
			al = sin(time * 3.2 + ph) * 0.7 - 0.5
			ar = -sin(time * 3.2 + ph) * 0.7 - 0.5
	if pose == "" and kind == "humanoid" and w < 0.05 and not working and float(v["atk_t"]) < 0.0:
		# стоит без дела: время от времени оглядывается
		head_ry = sin(time * 0.5 + ph * 1.7) * 0.45 * smoothstep(0.55, 1.0, sin(time * 0.21 + ph) * 0.5 + 0.5)

	# работа: рубит или строит
	if working and arm_r != null:
		var chop := sin(time * 9.0 + ph)
		ar = -1.7 + chop * 0.9
		torso_rx = 0.18 + chop * 0.12
		al = -0.5

	# атака: замах до середины анимации, удар приходится на t = 0.5
	if float(v["atk_t"]) >= 0.0:
		v["atk_t"] = float(v["atk_t"]) + delta
		var t: float = float(v["atk_t"]) / maxf(0.05, float(v["atk_len"]))
		if t >= 1.0:
			v["atk_t"] = -1.0
			v.erase("style")
			t = 1.0
		match String(v.get("style", p["attack"])):
			"cast":
				ar = key(t, [[0, ar], [0.4, -2.7], [0.55, -2.7], [0.7, -1.2], [1, 0]])
				al = key(t, [[0, al], [0.4, -1.0], [0.7, -0.6], [1, 0]])
				torso_rx = key(t, [[0, 0], [0.4, -0.15], [0.6, 0.2], [1, 0]])
			"swing":
				ar = key(t, [[0, ar], [0.42, -3.3], [0.5, -3.3], [0.62, -0.5], [1, 0]])
				torso_ry = key(t, [[0, 0], [0.45, 0.55], [0.62, -0.45], [1, 0]])
				torso_rx = key(t, [[0, 0], [0.45, -0.16], [0.62, 0.3], [1, 0]])
				al = key(t, [[0, al], [0.45, -0.6], [0.62, 0.4], [1, 0]])
			"smash":
				ar = key(t, [[0, ar], [0.45, -3.2], [0.5, -3.2], [0.62, -0.7], [1, 0]])
				al = ar
				torso_rx = key(t, [[0, 0], [0.45, -0.28], [0.62, 0.42], [1, 0]])
				body_y += key(t, [[0, 0], [0.45, 0.1 * s], [0.62, 0], [1, 0]])
			"thrust":
				ar = key(t, [[0, ar], [0.42, -0.35], [0.5, -0.35], [0.6, -1.25], [1, ar]])
				torso_ry = key(t, [[0, 0], [0.45, 0.4], [0.6, -0.3], [1, 0]])
				torso_rx = key(t, [[0, 0], [0.45, -0.12], [0.6, 0.3], [1, 0]])
				body_z = key(t, [[0, 0], [0.45, -0.15 * s], [0.6, 0.35 * s], [1, 0]])
			"throw":
				ar = key(t, [[0, ar], [0.42, -3.4], [0.5, -3.2], [0.6, -0.9], [1, 0]])
				torso_ry = key(t, [[0, 0], [0.45, 0.5], [0.6, -0.4], [1, 0]])
				torso_rx = key(t, [[0, 0], [0.45, -0.25], [0.6, 0.35], [1, 0]])
				al = key(t, [[0, al], [0.45, -1.2], [0.6, 0.3], [1, 0]])
			"bow":
				al = key(t, [[0, al], [0.2, -1.57], [0.75, -1.57], [1, 0]])
				ar = key(t, [[0, ar], [0.2, -1.5], [0.46, -1.15], [0.5, -1.15], [0.56, -1.55], [0.75, -1.3], [1, 0]])
				torso_ry = key(t, [[0, 0], [0.2, -0.35], [0.75, -0.35], [1, 0]])
			"bite":
				body_z = key(t, [[0, 0], [0.42, -0.2 * s], [0.56, 0.5 * s], [1, 0]])
				head_rx = key(t, [[0, 0], [0.42, -0.45], [0.56, 0.35], [1, 0]])
				body_rx = key(t, [[0, 0], [0.42, -0.12], [0.56, 0.12], [1, 0]])
			"fling":       # рычаг катапульты: оттяжка и бросок вперёд-вверх
				head_rx = key(t, [[0, 0], [0.4, -0.2], [0.52, 2.3], [0.7, 2.3], [1, 0]])
				body_z = key(t, [[0, 0], [0.5, 0], [0.56, -0.06 * s], [0.8, 0], [1, 0]])
			"recoil":      # баллиста: отдача после выстрела
				body_z = key(t, [[0, 0], [0.48, 0], [0.52, -0.18 * s], [0.9, 0], [1, 0]])
				head_rx = key(t, [[0, 0], [0.45, -0.06], [0.55, 0.04], [1, 0]])
			"breath":      # дракон: запрокидывает голову и выдыхает огонь
				head_rx = key(t, [[0, 0], [0.4, -0.5], [0.52, 0.45], [0.85, 0.35], [1, 0]])
				body_z = key(t, [[0, 0], [0.4, -0.2], [0.55, 0.15], [1, 0]])
				(p["flame"] as Node3D).visible = t > 0.48 and t < 0.9
			"ram":         # таран: откат назад и удар
				body_z = key(t, [[0, 0], [0.42, -0.3 * s], [0.55, 0.45 * s], [1, 0]])
				head_rx = key(t, [[0, 0], [0.42, 0.05], [0.55, -0.05], [1, 0]])
		var ammo = p["ammo"]
		if ammo != null:
			(ammo as Node3D).visible = t < 0.5 or t >= 1.0

	# вздрагивает от пропущенного удара
	if float(v.get("flinch", 0.0)) > 0.0:
		v["flinch"] = maxf(0.0, float(v["flinch"]) - delta)
		var f: float = float(v["flinch"]) / 0.22
		torso_rx -= 0.32 * f
		body_z -= 0.07 * f * s
		head_rx -= 0.2 * f

	body.position = Vector3(0, body_y, body_z)
	body.rotation.x = body_rx
	torso.rotation.x = torso_rx
	torso.rotation.y = torso_ry
	head.rotation.x = head_rx
	head.rotation.y = head_ry
	if arm_l != null:
		arm_l.rotation.x = al
		arm_r.rotation.x = ar


## Смерть: юнит падает, лежит и уходит в землю. Возвращает true, когда модель пора убрать.
static func die(c: Dictionary, delta: float) -> bool:
	c["t"] = float(c["t"]) + delta
	if c.get("keep", false) and float(c["t"]) > 2.0:
		c["t"] = 2.0      # тело ещё лежит (его могут съесть или поднять) — не уходит в землю
	var t: float = c["t"]
	var node: Node3D = c["node"]
	var body: Node3D = c["parts"]["body"]
	var fall := smoothstep(0.0, 1.0, minf(1.0, t / 0.45))
	if String(c["parts"]["kind"]) == "humanoid":
		body.rotation.x = -PI * 0.5 * fall
		body.position.y = 0.12 * fall
	else:
		body.rotation.z = PI * 0.5 * fall
		body.position.y = 0.25 * fall
	if t > 2.2:
		node.position.y -= delta * 0.6
	return t > 3.6
