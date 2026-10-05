extends RefCounted
## Мелкие элементы интерфейса, которые рисуют себя сами.


## Затемнение «по часовой стрелке»: показывает, сколько осталось перезарядки или действия эффекта.
## ratio = 1 — всё затемнено, 0 — ничего.
class Sweep extends Control:
	var ratio := 0.0:
		set(v):
			if absf(v - ratio) > 0.002:
				ratio = v
				queue_redraw()
	var tint := Color(0, 0, 0, 0.62)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true          # круг больше кнопки, лишнее обрезается по её краям
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _draw() -> void:
		if ratio <= 0.0:
			return
		var c := size * 0.5
		var rad := size.length() * 0.5 + 1.0
		var pts := PackedVector2Array([c])
		var steps := maxi(2, int(ceil(48.0 * ratio)))
		var start := -PI / 2.0 + TAU * (1.0 - ratio)   # оставшаяся часть — от текущего угла до 12 часов
		for i in steps + 1:
			var a := start + TAU * ratio * float(i) / float(steps)
			pts.append(c + Vector2(cos(a), sin(a)) * rad)
		draw_colored_polygon(pts, tint)
		draw_line(c, c + Vector2(cos(start), sin(start)) * rad, Color(1, 1, 1, 0.55), 1.5)


## Полоска со значением посередине: здоровье, мана, опыт, ход найма.
class Bar extends Control:
	var ratio := 1.0
	var color := Color("#3ddc55")
	var text := ""
	var font_size := 14

	func _init(c: Color, h: float, fs: int = 14) -> void:
		color = c
		font_size = fs
		custom_minimum_size = Vector2(0, h)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_value(r: float, t: String, c = null) -> void:
		r = clampf(r, 0.0, 1.0)
		if c != null:
			color = c
		if absf(r - ratio) > 0.001 or t != text:
			ratio = r
			text = t
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.04, 0.05, 0.07, 0.95))
		draw_rect(Rect2(Vector2.ONE, Vector2((size.x - 2.0) * ratio, size.y - 2.0)), color.darkened(0.15))
		draw_rect(Rect2(Vector2.ONE, Vector2((size.x - 2.0) * ratio, (size.y - 2.0) * 0.45)), color.lightened(0.12))
		draw_rect(r, Color(0.75, 0.62, 0.3, 0.7), false, 1.0)
		if text != "":
			var font := ThemeDB.fallback_font
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var pos := Vector2((size.x - w) * 0.5, (size.y + font_size * 0.72) * 0.5)
			draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color.BLACK)
			draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


## Три точки под кнопкой способности: сколько рангов изучено.
class Pips extends Control:
	var have := 0
	var most := 3

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_rank(r: int) -> void:
		if r != have:
			have = r
			queue_redraw()

	func _draw() -> void:
		var w := 12.0
		var gap := 4.0
		var x0 := (size.x - (w * most + gap * (most - 1))) * 0.5
		for i in most:
			var r := Rect2(Vector2(x0 + i * (w + gap), size.y - 7.0), Vector2(w, 4.0))
			draw_rect(r.grow(1.0), Color(0, 0, 0, 0.9))
			draw_rect(r, Color("#ffd24a") if i < have else Color(0.25, 0.25, 0.28))
