extends Node
## Звуки игры. Файлов со звуками нет: все эффекты синтезируются кодом при запуске.

const RATE := 22050

var enabled := true
var gain_db := 0.0      # общая громкость из настроек
var sounds: Dictionary = {}
var _pool: Array = []
var _next := 0
var _last: Dictionary = {}     # имя звука -> когда играл в последний раз
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 5
	for i in 14:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	sounds["hit"] = _make(0.16, func(t: float) -> float: return sin(TAU * (130.0 - 380.0 * t) * t) * exp(-20.0 * t) * 0.9 + _noise() * exp(-45.0 * t) * 0.5)
	sounds["sword"] = _make(0.24, func(t: float) -> float: return (sin(TAU * 1900.0 * t) + sin(TAU * 2750.0 * t) * 0.7 + sin(TAU * 4150.0 * t) * 0.4) * exp(-24.0 * t) * 0.35 + _noise() * exp(-90.0 * t) * 0.5)
	sounds["arrow"] = _make(0.18, func(t: float) -> float: return _noise() * sin(PI * t / 0.18) * 0.35 * (0.4 + 0.6 * sin(TAU * (500.0 + 2500.0 * t) * t)))
	sounds["magic"] = _make(0.3, func(t: float) -> float: return sin(TAU * (700.0 + 900.0 * t) * t) * sin(PI * t / 0.3) * 0.4 + sin(TAU * 1900.0 * t) * exp(-14.0 * t) * 0.15)
	sounds["chop"] = _make(0.11, func(t: float) -> float: return (sin(TAU * 520.0 * t) * exp(-48.0 * t) + sin(TAU * 1040.0 * t) * 0.4 * exp(-65.0 * t)) * 0.7 + _noise() * exp(-130.0 * t) * 0.4)
	sounds["gold"] = _make(0.26, func(t: float) -> float: return (sin(TAU * 2100.0 * t) + sin(TAU * 3160.0 * t) * 0.6) * exp(-20.0 * t) * 0.3 + (sin(TAU * 2640.0 * maxf(0.0, t - 0.08)) * exp(-22.0 * maxf(0.0, t - 0.08)) * 0.3 if t > 0.08 else 0.0))
	sounds["click"] = _make(0.05, func(t: float) -> float: return sin(TAU * 950.0 * t) * exp(-70.0 * t) * 0.5)
	sounds["error"] = _make(0.16, func(t: float) -> float: return signf(sin(TAU * 170.0 * t)) * 0.18 * sin(PI * t / 0.16))
	sounds["spell"] = _make(0.5, func(t: float) -> float: return sin(TAU * (380.0 + 1500.0 * t) * t) * sin(PI * t / 0.5) * 0.35 + sin(TAU * (760.0 + 3000.0 * t) * t) * sin(PI * t / 0.5) * 0.12)
	sounds["heal"] = _make(0.55, func(t: float) -> float: return (sin(TAU * 660.0 * t) + sin(TAU * 990.0 * t) * 0.6 + sin(TAU * 1320.0 * t) * 0.3) * sin(PI * t / 0.55) * 0.22)
	sounds["death"] = _make(0.4, func(t: float) -> float: return sin(TAU * (300.0 - 260.0 * t) * t) * exp(-7.0 * t) * 0.5 + _noise() * exp(-22.0 * t) * 0.25)
	sounds["crash"] = _make(0.7, func(t: float) -> float: return _noise() * exp(-5.0 * t) * 0.55 + sin(TAU * (90.0 - 50.0 * t) * t) * exp(-6.0 * t) * 0.6)
	sounds["done"] = _notes([660.0, 880.0], 0.11, 0.3)
	sounds["levelup"] = _notes([523.0, 659.0, 784.0, 1047.0], 0.09, 0.3)
	sounds["shot"] = _make(0.3, func(t: float) -> float: return _noise() * exp(-28.0 * t) * 0.7 + sin(TAU * (120.0 - 60.0 * t) * t) * exp(-14.0 * t) * 0.5)      # выстрел ружья
	sounds["ping"] =_notes([1319.0, 988.0, 1319.0], 0.07, 0.28)      # сигнал союзника на карте
	sounds["victory"] = _notes([523.0, 659.0, 784.0, 1047.0, 784.0, 1047.0], 0.16, 0.32)
	sounds["defeat"] = _notes([392.0, 349.0, 311.0, 262.0], 0.24, 0.32)
	sounds["horn"] = _make(0.7, func(t: float) -> float: return (fmod(t * 196.0, 1.0) - 0.5 + (fmod(t * 294.0, 1.0) - 0.5) * 0.6) * minf(1.0, t * 14.0) * minf(1.0, (0.7 - t) * 6.0) * 0.4)


func _noise() -> float:
	return _rng.randf_range(-1.0, 1.0)


func _make(duration: float, wave: Callable) -> AudioStreamWAV:
	var n := int(duration * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var v: float = clampf(wave.call(float(i) / RATE), -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	return stream


## Короткая мелодия из нот одинаковой длины.
func _notes(freqs: Array, each: float, volume: float) -> AudioStreamWAV:
	return _make(each * freqs.size() + 0.15, func(t: float) -> float:
		var i: int = mini(int(t / each), freqs.size() - 1)
		var local: float = t - i * each
		var f: float = freqs[i]
		return (sin(TAU * f * t) + sin(TAU * f * 2.0 * t) * 0.3) * exp(-7.0 * local) * volume)


func play(sound: String, volume_db: float = 0.0) -> void:
	if not enabled or not sounds.has(sound):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last.get(sound, -1000)) < 45:
		return     # один и тот же звук не чаще 20 раз в секунду
	_last[sound] = now
	var p: AudioStreamPlayer = _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = sounds[sound]
	p.volume_db = volume_db + gain_db
	p.pitch_scale = randf_range(0.93, 1.07)
	p.play()
