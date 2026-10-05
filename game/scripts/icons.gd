extends RefCounted
## Иконки способностей: рисуются кодом по точкам, без файлов-картинок.

static var _cache: Dictionary = {}


static func make(kind: String, color: Color) -> ImageTexture:
	var id := kind + color.to_html()
	if _cache.has(id):
		return _cache[id]
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for py in n:
		for px in n:
			var x := (px + 0.5) / n * 2.0 - 1.0
			var y := (py + 0.5) / n * 2.0 - 1.0
			var bg := color.darkened(0.55).lerp(color.darkened(0.2), (y + 1.0) * 0.5)
			if absf(x) > 0.9 or absf(y) > 0.9:
				bg = Color("#14110f")
			img.set_pixel(px, py, Color.WHITE.lerp(color, 0.15) if _inside(kind, x, y) else bg)
	_cache[id] = ImageTexture.create_from_image(img)
	return _cache[id]


static func _circle(x: float, y: float, cx: float, cy: float, r: float) -> bool:
	return Vector2(x - cx, y - cy).length() < r


## Расстояние от точки до отрезка ab.
static func _seg(x: float, y: float, a: Vector2, b: Vector2) -> float:
	var p := Vector2(x, y)
	var t := clampf((p - a).dot(b - a) / maxf(0.0001, (b - a).length_squared()), 0.0, 1.0)
	return p.distance_to(a + (b - a) * t)


static func _inside(kind: String, x: float, y: float) -> bool:
	var r := Vector2(x, y).length()
	var ang := atan2(y, x)
	match kind:
		"heal":
			return (absf(x) < 0.2 and absf(y) < 0.62) or (absf(y) < 0.2 and absf(x) < 0.62)
		"shield":
			if y < -0.62 or y > 0.72:
				return false
			var half := 0.52 if y < 0.0 else 0.52 * sqrt(maxf(0.0, 1.0 - pow(y / 0.72, 2.0)))
			return absf(x) < half and not (absf(x) < 0.07 and y > -0.4 and y < 0.4) or (absf(x) < 0.3 and absf(y + 0.05) < 0.07)
		"fire":
			if _circle(x, y, 0.0, 0.25, 0.42):
				return not _circle(x, y, 0.0, 0.4, 0.18)
			return y > -0.75 and y < 0.2 and absf(x + 0.1 * sin(y * 6.0)) < 0.4 * (y + 0.75) / 0.95
		"snow":
			for k in 3:
				var p := Vector2(x, y).rotated(float(k) * PI / 3.0)
				if absf(p.x) < 0.07 and absf(p.y) < 0.7:
					return true
				if absf(absf(p.y) - 0.45) < 0.06 and absf(p.x) < 0.2:
					return true
			return false
		"stomp":
			return r < 0.3 + 0.38 * absf(cos(ang * 4.0)) and r > 0.12
		"cry":
			if _circle(x, y, -0.5, 0.0, 0.2):
				return true
			for rr in [0.45, 0.72, 0.98]:
				if absf(Vector2(x + 0.5, y).length() - float(rr)) < 0.07 and x > -0.3 and absf(atan2(y, x + 0.5)) < 0.75:
					return true
			return false
		"paw":
			return _circle(x, y, 0.0, 0.28, 0.32) or _circle(x, y, -0.45, -0.1, 0.15) or _circle(x, y, -0.16, -0.42, 0.15) or _circle(x, y, 0.16, -0.42, 0.15) or _circle(x, y, 0.45, -0.1, 0.15)
		"aura":
			return absf(r - 0.62) < 0.09 or r < 0.22 or (absf(r - 0.4) < 0.04)
		"regen":
			return absf(r - 0.68) < 0.07 or (absf(x) < 0.12 and absf(y) < 0.4) or (absf(y) < 0.12 and absf(x) < 0.4)
		"blade":
			var q := Vector2(x, y).rotated(-PI / 4)
			return (absf(q.x) < 0.1 and q.y > -0.75 and q.y < 0.3) or (absf(q.y - 0.35) < 0.07 and absf(q.x) < 0.3) or (absf(q.x) < 0.06 and q.y > 0.3 and q.y < 0.7)
		"leaf":
			return _circle(x, y, 0.2, 0.0, 0.62) and _circle(x, y, -0.2, 0.0, 0.62) and not (absf(x) < 0.04 and absf(y) < 0.5)
		"arrows":
			for k in 3:
				var ax := x - (float(k) - 1.0) * 0.42
				if (absf(ax) < 0.05 and y > -0.5 and y < 0.6) or (y > 0.3 and y < 0.7 and absf(ax) < (0.7 - y) * 0.5):
					return true
			return false
		"boot":
			return (absf(x + 0.1) < 0.2 and y > -0.65 and y < 0.45) or (y > 0.15 and y < 0.5 and x > -0.3 and x < 0.6) or (absf(y - 0.58) < 0.06 and x > -0.35 and x < 0.65)
		"heart":
			return (_circle(x, y, -0.27, -0.15, 0.32) or _circle(x, y, 0.27, -0.15, 0.32) or (y > -0.05 and y < 0.65 and absf(x) < (0.65 - y) * 0.85))
		"cancel":
			var c1 := Vector2(x, y).rotated(PI / 4)
			return (absf(c1.x) < 0.13 and absf(c1.y) < 0.7) or (absf(c1.y) < 0.13 and absf(c1.x) < 0.7)
		"mana":
			return absf(x) + absf(y) * 0.7 < 0.55 and not (absf(x) + absf(y) * 0.7 < 0.25)
		# --- предметы ---
		"ring":
			return absf(Vector2(x, y - 0.12).length() - 0.42) < 0.1 or _circle(x, y, 0.0, -0.42, 0.17)
		"glove":
			if absf(x + 0.05) < 0.33 and y > -0.12 and y < 0.62:
				return true
			for i in 4:
				if absf(x - (-0.32 + 0.18 * i)) < 0.07 and y > -0.62 + absf(i - 1.5) * 0.08 and y < 0.0:
					return true
			return _seg(x, y, Vector2(0.3, 0.25), Vector2(0.58, -0.08)) < 0.09
		"axe":
			var qa := Vector2(x, y).rotated(-PI / 4)
			if absf(qa.x) < 0.06 and absf(qa.y) < 0.78:
				return true
			return _circle(x, y, -0.18, -0.3, 0.42) and not _circle(x, y, 0.12, 0.0, 0.42) and x + y < 0.0
		"cloak":
			if _circle(x, y, 0.0, -0.45, 0.24) and not _circle(x, y, 0.0, -0.4, 0.12):
				return true
			return y > -0.3 and y < 0.72 and absf(x) < 0.16 + (y + 0.3) * 0.38 and not (absf(x) < 0.04 and y > 0.0)
		"fang":
			if absf(x) < 0.62 and y > -0.68 and y < -0.46:
				return true
			for cx in [-0.27, 0.27]:
				if y > -0.5 and y < 0.62 and absf(x - float(cx)) < 0.2 * (0.62 - y) / 1.12:
					return true
			return false
		"thorns":
			return r < 0.26 + 0.48 * pow(absf(cos(ang * 4.0)), 10.0) or r < 0.3
		"staff":
			if _circle(x, y, 0.33, -0.43, 0.22):
				return not _circle(x, y, 0.33, -0.43, 0.09)
			return _seg(x, y, Vector2(0.2, -0.25), Vector2(-0.5, 0.72)) < 0.07
		"crown":
			if absf(x) < 0.62 and y > 0.12 and y < 0.5:
				return true
			for px in [-0.48, 0.0, 0.48]:
				if y > -0.42 and y <= 0.12 and absf(x - float(px)) < (y + 0.42) * 0.38:
					return true
				if _circle(x, y, float(px), -0.5, 0.1):
					return true
			return false
		"potion":
			return _circle(x, y, 0.0, 0.22, 0.44) or (absf(x) < 0.14 and y > -0.6 and y < 0.0) or (absf(x) < 0.24 and y > -0.72 and y < -0.58)
		"scroll":
			if absf(x) >= 0.4 and absf(x) < 0.6 and absf(y) < 0.48:
				return true
			if absf(x) < 0.4 and absf(y) < 0.36:
				for k in [-0.16, 0.0, 0.16]:
					if absf(y - float(k)) < 0.035 and absf(x) < 0.28:
						return false
				return true
			return false
		"book":
			return absf(x) < 0.55 and absf(y) < 0.46 and not (absf(x) < 0.04) and not (absf(x) > 0.1 and absf(x) < 0.45 and absf(y + 0.18) < 0.03)
		# --- способности ---
		"hammer":
			return (absf(x) < 0.5 and y > -0.62 and y < -0.2) or (absf(x) < 0.08 and y >= -0.2 and y < 0.72)
		"halo":
			if absf(Vector2(x, (y + 0.42) * 2.6).length() - 0.48) < 0.13:
				return true
			return _circle(x, y, 0.0, 0.25, 0.28) or (absf(x) < 0.42 - (0.72 - y) * 0.3 and y > 0.42 and y < 0.72)
		"bolt":
			return _seg(x, y, Vector2(0.28, -0.78), Vector2(-0.2, 0.02)) < 0.11 or _seg(x, y, Vector2(-0.2, 0.02), Vector2(0.25, -0.02)) < 0.11 or _seg(x, y, Vector2(0.25, -0.02), Vector2(-0.25, 0.78)) < 0.11
		"meteor":
			if _circle(x, y, 0.25, 0.28, 0.32):
				return true
			var tt := clampf((0.25 - x + 0.28 - y) / 1.6, 0.0, 1.0)
			return _seg(x, y, Vector2(0.25, 0.28), Vector2(-0.6, -0.58)) < 0.24 * (1.0 - tt) and x < 0.25
		"leap":
			if absf(y - 0.6) < 0.07 and absf(x) < 0.75:
				return true
			var arc := Vector2(x + 0.05, y - 0.5)
			return (absf(arc.length() - 0.6) < 0.08 and y < 0.45 and x < 0.42) or _seg(x, y, Vector2(0.52, 0.1), Vector2(0.62, -0.25)) < 0.08 or _seg(x, y, Vector2(0.52, 0.1), Vector2(0.2, 0.0)) < 0.08
		"fist":
			if absf(x) > 0.46 or absf(y) > 0.48:
				return false
			if absf(x) > 0.3 and absf(y) > 0.32 and Vector2(absf(x) - 0.3, absf(y) - 0.32).length() > 0.16:
				return false     # скруглённые углы
			for k in [-0.15, 0.08, 0.31]:
				if absf(x - float(k)) < 0.03 and y < -0.05:
					return false
			return not (absf(y + 0.05) < 0.03 and x > -0.38)
		"skull":
			if _circle(x, y, -0.2, -0.1, 0.13) or _circle(x, y, 0.2, -0.1, 0.13):
				return false
			if absf(x) < 0.3 and y > 0.25 and y < 0.62:
				return not (absf(fposmod(x + 0.3, 0.15) - 0.075) < 0.02 and y > 0.42)
			return _circle(x, y, 0.0, -0.12, 0.5)
		"bear":
			if _circle(x, y, -0.18, 0.02, 0.07) or _circle(x, y, 0.18, 0.02, 0.07):
				return false
			return _circle(x, y, 0.0, 0.12, 0.46) or _circle(x, y, -0.38, -0.3, 0.17) or _circle(x, y, 0.38, -0.3, 0.17)
		"blink":
			return r < 0.75 and r > 0.08 and fposmod(ang + r * 7.0, TAU) < 1.4
		"star":
			var a := fposmod(ang + PI / 2.0, TAU / 5.0) - PI / 5.0
			return r < 0.28 + 0.48 * pow(1.0 - absf(a) / (PI / 5.0), 2.0)
		"roots":
			if absf(y - 0.62) < 0.06 and absf(x) < 0.75:
				return true
			for k in 3:
				if absf(x - (float(k) - 1.0) * 0.36 - 0.1 * sin(y * 7.0 + float(k) * 2.0)) < 0.07 and y > -0.7 + absf(float(k) - 1.0) * 0.2 and y < 0.62:
					return true
			return false
		# --- характеристики ---
		"hourglass":
			return (absf(y) < 0.62 and absf(x) < absf(y) * 0.62 + 0.05) or (absf(absf(y) - 0.68) < 0.06 and absf(x) < 0.48)
		"target":
			return absf(r - 0.62) < 0.07 or absf(r - 0.34) < 0.07 or r < 0.1 or (absf(x) < 0.03 and absf(y) < 0.8) or (absf(y) < 0.03 and absf(x) < 0.8)
		"clock":
			return absf(r - 0.6) < 0.08 or (absf(x) < 0.06 and y > -0.45 and y < 0.03) or (absf(y) < 0.06 and x > -0.03 and x < 0.35)
		"plus":
			return (absf(x) < 0.16 and absf(y) < 0.6) or (absf(y) < 0.16 and absf(x) < 0.6)
		# --- значки верхней панели ---
		"coin":     # монета с ободком и знаком
			return (r < 0.62 and r > 0.5) or (r < 0.4 and not (absf(x) < 0.08 and absf(y) < 0.24))
		"log":      # бревно: торец с кольцами и ствол
			if x > -0.1:
				return absf(y) < 0.32 and x < 0.72
			var rr := Vector2((x + 0.1) / 0.55, y / 0.42).length()
			return rr < 1.0 and not (rr > 0.45 and rr < 0.62)
		"house":    # дом: крыша-треугольник и стены
			if y < -0.05:
				return absf(x) < (y + 0.75) * 0.95 and y > -0.75
			return absf(x) < 0.5 and y < 0.62 and not (absf(x) < 0.13 and y > 0.25)
		"sun":
			return r < 0.32 or (r > 0.45 and r < 0.68 and absf(sin(ang * 4.0)) > 0.75)
		"moon":     # полумесяц
			return r < 0.58 and Vector2(x - 0.26, y + 0.12).length() > 0.48
		"eye":      # глаз: миндалевидный контур и зрачок
			var lid := 0.42 * (1.0 - pow(x / 0.78, 2.0))
			var outline := absf(x) < 0.78 and absf(absf(y) - lid) < 0.07
			return outline or (r < 0.24 and r > 0.1) or r < 0.06
		"rune":     # камень руны: ромб с вырезанным знаком
			if absf(x) + absf(y) > 0.72:
				return false
			return not ((absf(x) < 0.06 and absf(y) < 0.4) or (absf(y + x * 0.8) < 0.06 and absf(x) < 0.25 and y < 0.0))
	return r < 0.5
