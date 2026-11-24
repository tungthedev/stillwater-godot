extends RefCounted

# Noise height field shared by every placeholder system until the real valley data replaces it.

var noise := FastNoiseLite.new()


func _init() -> void:
	noise.seed = 7
	noise.frequency = 0.0025
	noise.fractal_octaves = 4


func height_at(x: float, z: float) -> float:
	return noise.get_noise_2d(x, z) * 45.0 + noise.get_noise_2d(x * 5.0, z * 5.0) * 2.5
