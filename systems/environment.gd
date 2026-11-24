extends Node3D

# Sky, fog and the sun. The sun is exposed so the UI can toggle its shadows.

var sun: DirectionalLight3D


func _ready() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.52, 0.82)
	sky_mat.sky_horizon_color = Color(0.78, 0.84, 0.9)
	sky_mat.ground_horizon_color = Color(0.6, 0.66, 0.6)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.0015
	env.fog_light_color = Color(0.75, 0.82, 0.9)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, -40.0, 0.0)
	sun.light_color = Color(1.0, 0.93, 0.8)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)
