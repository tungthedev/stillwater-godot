// Position-only painted ground albedo shared by the near-tile baker (shaders/ground_bake.gdshader)
// and the one-time valley macro baker (shaders/valley_bake.gdshader).
//
// Returns RGBA8-ready values:
//   rgb = sqrt(linear albedo in [0, 1]) for extra precision in dark forest greens
//   a   = open-trail emissive weight (trM * openPath), continuous so bilinear filtering is exact.
//
// Requires W_NOISE(uv) defined as textureLod(noise_tex, uv, 0.0), plus stillwater.gdshaderinc
// and world.gdshaderinc included first.

uniform vec4 ao_spot = vec4(615.25, 796.96, 7.5, 0.35);
uniform vec4 waterfall = vec4(-893.95, 132.59, 118.0, 58.0);
uniform float water_level = 22.0;

float g_sq(float x) {
	return x * x;
}

vec4 g_cliff_plane(vec2 p, bool is_near) {
	vec4 vn = W_NOISE(p * 0.022);
	vec4 vf = W_NOISE(p * 0.14 + 0.37);
	float hi1 = is_near ? n_noise(p * 0.45 + vec2(3.1, 7.4)) : 0.5;
	float hi2 = is_near ? n_noise(p * 1.35 + vec2(9.2, 1.8)) : 0.5;
	float y_warp = p.y + (vn.r - 0.5) * 0.78 + (hi1 - 0.5) * 0.32;
	float x_warp = p.x + (vn.g - 0.5) * 1.25 + (hi1 - 0.5) * 0.42;
	float strata_band = fract(y_warp * 0.18 + vn.b * 0.10);
	float strata_top = smoothstep(0.68, 0.78, strata_band);
	float strata_under = w_rstep(0.18, 0.04, strata_band);
	float b1 = W_NOISE(vec2(x_warp * 0.055 + 0.13, floor(y_warp * 0.18) * 0.27)).r;
	float b2 = W_NOISE(vec2(x_warp * 0.11 + 0.47, y_warp * 0.085)).g;
	float facet = b1 * 0.52 + b2 * 0.32 + hi1 * 0.16;
	float plane_step = smoothstep(0.32, 0.37, facet) * 0.50 + smoothstep(0.60, 0.65, facet) * 0.50;
	float shelf_edge = max(strata_top * 0.88, smoothstep(0.62, 0.72, b2 * 0.7 + hi1 * 0.3) * smoothstep(0.36, 0.66, vn.b));
	float joint_h = smoothstep(0.0, 0.055, abs(strata_band - 0.04));
	float joint_v = smoothstep(0.0, 0.045, abs(fract(x_warp * 0.095 + floor(y_warp * 0.18) * 0.41 + vn.a * 0.22) - 0.5));
	float crevice = mix(0.28, 1.0, min(joint_h, joint_v) * 0.78 + 0.22 * smoothstep(0.24, 0.68, vf.b * 0.6 + hi2 * 0.4));
	vec3 c = mix(vec3(0.10, 0.13, 0.21), vec3(0.35, 0.36, 0.40), smoothstep(0.0, 0.50, plane_step));
	c = mix(c, vec3(0.60, 0.56, 0.48), smoothstep(0.46, 1.0, plane_step) * 0.82 + strata_top * 0.52);
	c *= mix(1.0, 0.42, strata_under * 0.85);
	c *= crevice * (0.88 + 0.22 * hi2);
	float moss_spot = shelf_edge * smoothstep(0.36, 0.60, vn.g * 0.6 + hi1 * 0.4);
	return vec4(c, (moss_spot * 1.25 + strata_top * 0.62) - strata_under * 0.92 - (1.0 - crevice) * 0.80);
}

vec4 bake_ground_albedo(vec2 xz, bool is_near) {
	float fb = w_near_blend(xz);
	float h = w_height(xz);
	vec3 wp = vec3(xz.x, h, xz.y);
	float e = is_near ? 1.0 : mix(4.0, 28.0, fb);
	vec3 n = w_normal(xz, e);
	vec3 n_pre = n;
	float slope_fine = 1.0 - n.y;
	float slope = slope_fine;

	const mat2 R1 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));
	const mat2 R2 = mat2(vec2(0.28, 0.96), vec2(-0.96, 0.28));
	vec4 nH = W_NOISE(R2 * xz * 0.00031 + 0.21);
	vec4 nz = W_NOISE(R1 * xz * 0.0019);
	vec4 nm = W_NOISE(xz * 0.013);
	vec4 nd = is_near ? W_NOISE(R2 * xz * 0.11) : vec4(0.5);
	vec4 nf = is_near ? W_NOISE(xz * 0.63) : vec4(0.5);

	vec4 bio = w_biome(xz);
	float trail_raw = w_trail_raw(xz);
	float trail = max(trail_raw, 0.0);
	float bed = max(-trail_raw, 0.0);

	vec2 fall = n.xz + 1e-4;
	fall = fall * inversesqrt(max(dot(fall, fall), 1e-20));
	vec2 across = vec2(-fall.y, fall.x);
	vec2 gp = vec2(dot(xz, across) * 0.018, dot(xz, fall) * 0.0024);
	float gully = W_NOISE(gp).g * 0.58 + W_NOISE(gp * 3.1 + 0.4).b * 0.42;
	float t_wet = 0.0;

	vec3 forestF = vec3(0.045, 0.155, 0.055);
	vec3 rockA = vec3(0.32, 0.31, 0.34);
	vec3 rockB = vec3(0.58, 0.53, 0.48);
	vec3 rockW_ = vec3(0.56, 0.46, 0.37);
	vec3 dirt = vec3(0.74, 0.50, 0.26);
	vec3 sand = vec3(0.76, 0.66, 0.47);
	vec3 snow = vec3(0.99, 0.995, 1.0);
	vec3 mud = vec3(0.28, 0.31, 0.22);

	// ---- grass ----
	vec3 grass = w_grass_color(xz, h) * (0.90 + 0.18 * nd.b);
	// Macro warm/cool meadow patches live in both the near bake and the valley macro bake so the
	// transition over 54-68 m stays seamless in hue and value.
	float warm_patch = smoothstep(0.46, 0.76, W_NOISE(xz * 0.032 + 0.13).b);
	float cool_patch = smoothstep(0.48, 0.76, W_NOISE(xz * 0.018 + 0.61).r);
	if (is_near) {
		float gMacro = n_noise(xz * 0.42 + vec2(1.9, 7.3));
		float gClover = n_noise(xz * 1.45 + vec2(4.2, 1.9));
		// Keep baked spatial frequencies below the 12.8 cm texel Nyquist limit; finer micro-tufts
		// come from the live mipmapped detail fetch in terrain_baked.gdshader.
		float gTuft = n_noise(xz * 2.8 + vec2(8.7, 3.3));
		grass = mix(grass, grass * vec3(0.56, 0.78, 0.68), smoothstep(0.46, 0.76, gClover * 0.6 + gMacro * 0.4) * 0.58);
		grass = mix(grass, grass * vec3(1.24, 1.12, 0.72), smoothstep(0.52, 0.80, (1.0 - gClover) * 0.55 + gMacro * 0.45) * 0.46);
		grass *= 0.84 + 0.30 * smoothstep(0.20, 0.80, gTuft);
		float soilPeek = smoothstep(0.74, 0.89, gTuft) * smoothstep(0.50, 0.78, nd.r);
		grass = mix(grass, vec3(0.16, 0.15, 0.08), soilPeek * 0.45);
		grass = mix(grass, grass * vec3(1.20, 1.10, 0.74), warm_patch * 0.32);
		grass = mix(grass, grass * vec3(0.70, 0.90, 0.80), cool_patch * 0.28);
	} else {
		grass = mix(grass, grass * vec3(1.20, 1.10, 0.74), warm_patch * 0.58);
		grass = mix(grass, grass * vec3(0.70, 0.90, 0.80), cool_patch * 0.48);
		// Subtle warm floral lift across distant flower meadows without single-texel speckling.
		float fl_field = smoothstep(0.22, 0.62, bio.g + bio.b * 0.14) * smoothstep(0.42, 0.78, nm.a);
		grass = mix(grass, vec3(0.46, 0.48, 0.20), fl_field * 0.16);
	}

	// ---- forest ----
	vec3 col = grass;
	float forest = smoothstep(0.12, 0.55, bio.r);
	float farF = fb * w_rstep(1040.0, 860.0, h + (nH.g - 0.5) * 90.0) * w_rstep(0.48, 0.28, slope) * smoothstep(160.0, 340.0, h);
	forest = max(forest * (1.0 - fb), farF);
	float crowns = W_NOISE(xz * 0.042).a * 0.6 + W_NOISE(xz * 0.014).a * 0.4;
	vec3 forestHue = mix(forestF, vec3(0.068, 0.20, 0.062), smoothstep(0.32, 0.78, nH.r));
	forestHue = mix(forestHue, vec3(0.032, 0.14, 0.095), smoothstep(0.52, 0.80, nz.b) * 0.65);
	vec3 canopy = mix(vec3(0.042, 0.165, 0.072), vec3(0.078, 0.225, 0.074), smoothstep(0.30, 0.78, nH.r));
	canopy *= 0.80 + 0.32 * smoothstep(0.26, 0.76, crowns);
	vec3 fCol = is_near ? (forestHue * (0.72 + 0.54 * crowns)) : mix(forestHue * (0.72 + 0.54 * crowns), canopy, 0.45);
	col = mix(col, fCol, forest);
	col *= mix(1.0, 0.68, smoothstep(0.28, 0.74, bio.r) * (1.0 - fb));

	float cotClear = ao_spot.z > 0.1 ? smoothstep(26.0, 48.0, length(xz - ao_spot.xy)) : 1.0;
	float ff = smoothstep(0.44, 0.80, bio.r) * cotClear * (1.0 - fb);
	if (ff > 0.005) {
		if (is_near) {
			vec4 lf = W_NOISE(xz * 0.14 + 0.13);
			float mossCushion = n_noise(xz * 1.45 + vec2(2.3, 5.7));
			float leafLarge = n_noise(xz * 3.1 + vec2(7.1, 1.4));
			float rootStreak = n_noise(vec2(xz.x * 2.0 + mossCushion * 1.2, xz.y * 3.4));
			vec3 fBase = vec3(0.036, 0.088, 0.032) * (0.78 + 0.42 * mossCushion);
			float mossMask = smoothstep(0.36, 0.66, mossCushion * 0.65 + lf.g * 0.35);
			vec3 mossC = mix(vec3(0.042, 0.175, 0.038), vec3(0.115, 0.285, 0.058), smoothstep(0.35, 0.75, leafLarge));
			fBase = mix(fBase, mossC * (0.90 + 0.20 * leafLarge), mossMask * 0.85);
			float soilMask = smoothstep(0.45, 0.74, lf.r * 0.6 + (1.0 - mossCushion) * 0.4);
			fBase = mix(fBase, vec3(0.088, 0.058, 0.036) * (0.86 + 0.26 * leafLarge), soilMask * 0.82);
			fBase = mix(fBase, vec3(0.16, 0.11, 0.068), smoothstep(0.76, 0.88, rootStreak) * soilMask * 0.55);
			float leafBed = smoothstep(0.44, 0.68, leafLarge * 0.6 + lf.b * 0.4);
			vec3 leafCol = mix(vec3(0.24, 0.125, 0.048), vec3(0.38, 0.22, 0.072), smoothstep(0.48, 0.82, leafLarge));
			fBase = mix(fBase, leafCol, leafBed * 0.24);
			col = mix(col, fBase, ff * 0.94);
		} else {
			// Match the near forest floor's average moss/soil/leaf tone at the same ff * 0.94 weight
			// so the near-ring -> valley macro transition under trees has no colour step.
			vec3 fMid = vec3(0.036, 0.088, 0.032);
			fMid = mix(fMid, vec3(0.075, 0.220, 0.048), smoothstep(0.32, 0.72, nm.g) * 0.48);
			fMid = mix(fMid, vec3(0.088, 0.058, 0.036), smoothstep(0.38, 0.74, nm.r) * 0.52);
			fMid = mix(fMid, vec3(0.28, 0.155, 0.055), smoothstep(0.42, 0.74, nm.b) * 0.22);
			col = mix(col, fMid, ff * 0.94);
		}
	}

	// ---- rock & cliffs ----
	float strata = smoothstep(0.28, 0.72, sin(h * 0.045 + nz.g * 3.4 + gully * 3.2) * 0.5 + 0.5);
	vec3 rock = mix(rockA, rockB, strata * 0.22 + gully * 0.52 + nH.b * 0.22);
	rock = mix(rock, rockW_, smoothstep(0.55, 0.8, nH.g) * 0.42);
	rock *= 0.88 + 0.22 * nf.g;

	float cliffW = smoothstep(0.26, 0.50, slope_fine);
	float wfZone = waterfall.w > 0.1 ? (1.0 - smoothstep(waterfall.w * 0.55, waterfall.w * 1.45, length(xz - waterfall.xz))) : 0.0;
	if (cliffW > 0.0) {
		vec3 n2 = n_pre * n_pre;
		vec3 tw = n2 * n2 * n2;
		tw /= max(tw.x + tw.y + tw.z, 1e-4);
		vec4 cX = g_cliff_plane(vec2(wp.z, wp.y), is_near);
		vec4 cZ = g_cliff_plane(vec2(wp.x, wp.y), is_near);
		vec4 cY = g_cliff_plane(vec2(wp.x, wp.z), is_near);
		vec3 cliffC = cX.rgb * tw.x + cZ.rgb * tw.z + cY.rgb * tw.y;
		float shelfStep = cX.a * tw.x + cZ.a * tw.z;
		vec4 vf = W_NOISE(vec2(wp.z, wp.y) * 0.26 + 0.37) * tw.x
				+ W_NOISE(vec2(wp.x, wp.z) * 0.26 + 0.37) * tw.y
				+ W_NOISE(vec2(wp.x, wp.y) * 0.26 + 0.37) * tw.z;
		float topFace = smoothstep(0.52, 0.82, n_pre.y);
		float ledgeMoss = smoothstep(0.28, 0.78, shelfStep) * (0.45 + 0.55 * smoothstep(0.12, 0.46, n_pre.y));
		float shelfMoss = clamp(topFace + ledgeMoss * (0.55 + 0.45 * wfZone), 0.0, 1.0) * smoothstep(0.26, 0.66, vf.g + nd.r * 0.26) * w_rstep(950.0, 500.0, h);
		vec3 mossCol = mix(vec3(0.065, 0.24, 0.055), vec3(0.17, 0.39, 0.075), vf.b);
		cliffC = mix(cliffC, mossCol, shelfMoss * 0.90);
		if (wfZone > 0.01) {
			float wfd = length(xz - waterfall.xz);
			float wfWet = 1.0 - smoothstep(waterfall.w * 0.14, waterfall.w * 0.56, wfd);
			cliffC = mix(cliffC, cliffC * vec3(0.36, 0.42, 0.52), wfWet * 0.76);
			t_wet = max(t_wet, wfWet * cliffW * 0.34);
		}
		rock = mix(rock, cliffC, cliffW);
	}

	rock *= mix(mix(0.66, 1.08, smoothstep(0.28, 0.65, gully)), 1.0, wfZone);
	float altR = smoothstep(980.0, 1480.0, h + (nH.g - 0.5) * 260.0);
	float rockEdge = 0.06;
	float steepThresh = mix(0.68, 0.44, smoothstep(540.0, 920.0, h)) - altR * 0.18;
	steepThresh = mix(steepThresh, 0.20, wfZone);
	float rockW = smoothstep(steepThresh, steepThresh + rockEdge, max(slope, slope_fine * wfZone) + ((nz.b - 0.5) * 0.035 + (gully - 0.5) * 0.03));
	float scree = smoothstep(0.38, 0.54, slope) * (1.0 - rockW) * smoothstep(0.60, 0.82, gully + nz.r * 0.22) * smoothstep(760.0, 1180.0, h);
	col = mix(col, mix(rockB * 0.72, vec3(0.14, 0.24, 0.085), 0.72) * (0.88 + 0.22 * nf.r), scree * 0.14);
	col = mix(col, rock, rockW);

	// ---- snow ----
	float snowLine = 1780.0 + (nH.r - 0.5) * 220.0 - n.z * 90.0;
	float slopeCap = w_rstep(0.56, 0.38, slope);
	float snowEdge = (nz.g - 0.5) * 110.0 + (nm.a - 0.5) * 60.0;
	float snowW = smoothstep(snowLine + snowEdge, snowLine + snowEdge + 22.0, h) * smoothstep(0.0, 0.08, slopeCap - 0.42);
	snowW = max(snowW, smoothstep(snowLine + 320.0, snowLine + 520.0, h) * w_rstep(0.76, 0.58, slope));
	col = mix(col, snow * (0.92 + 0.08 * nd.b), snowW);

	// ---- shoreline & underwater ----
	float wl = water_level;
	vec4 shN = W_NOISE(xz * 0.009 + 0.42);
	vec4 shN2 = W_NOISE(xz * 0.045 + 0.19);
	float beachWidth = mix(0.18, 1.35, smoothstep(0.32, 0.72, shN.r));
	float shore = (1.0 - smoothstep(0.05, beachWidth, abs(h - wl - 0.15) + (shN2.g - 0.5) * 0.35)) * smoothstep(0.28, 0.55, shN.g + 0.15);
	float pebbleMask = smoothstep(0.45, 0.68, shN2.a);
	vec3 beachCol = mix(sand * (0.85 + 0.25 * nf.b), vec3(0.48, 0.45, 0.40) * (0.8 + 0.38 * nf.a), pebbleMask * 0.75);
	col = mix(col, beachCol, shore * (1.0 - rockW) * 0.88);
	float under = w_rstep(wl + 0.12, wl - 0.55, h);
	col = mix(col, mix(sand * 0.78, mud, w_rstep(wl - 0.6, wl - 4.5, h)), under);
	t_wet = max(t_wet, 1.0 - smoothstep(wl - 0.1, wl + 0.55, h));

	// ---- hiking trail ----
	if (trail > 0.01) {
		float trHi1 = is_near ? n_noise(xz * 2.1 + vec2(1.7, 5.2)) : 0.5;
		float trHi2 = is_near ? n_noise(xz * 3.6 + vec2(6.3, 2.9)) : 0.5;
		float summitNarrow = smoothstep(210.0, 345.0, h) * 0.36;
		float trTuftTongue = is_near ? (smoothstep(0.46, 0.78, trHi1 * 0.62 + trHi2 * 0.38) * (1.0 - smoothstep(0.68, 0.94, trail)) * 0.28) : 0.06;
		float trailEdge2 = trail + (nd.g - 0.5) * 0.16 + (trHi1 - 0.5) * 0.26 + (trHi2 - 0.5) * 0.15 - summitNarrow - trTuftTongue;
		float twTrail = smoothstep(0.48, 0.515, trailEdge2);
		vec4 cb2 = is_near ? W_NOISE(xz * 0.85 + 0.31) : vec4(0.5);
		vec3 tcol = dirt * (0.82 + 0.24 * trHi2) * (0.90 + 0.20 * nz.r);
		float rut = exp(-g_sq((trail - 0.74) * 8.5)) * 0.32 + exp(-g_sq((trail - 0.91) * 9.5)) * 0.22;
		tcol *= 1.0 - rut;
		float fpath = smoothstep(0.28, 0.68, bio.r);
		float fRoot = is_near ? smoothstep(0.74, 0.86, n_noise(vec2(xz.x * 2.2 + trHi1 * 1.4, xz.y * 3.6))) : 0.0;
		float fLeaf = is_near ? smoothstep(0.58, 0.78, trHi2 * 0.6 + cb2.b * 0.4) * smoothstep(0.32, 0.70, trHi1) : 0.12;
		vec3 earth = vec3(0.155, 0.105, 0.062) * (0.80 + 0.32 * trHi2);
		earth = mix(earth, vec3(0.095, 0.065, 0.038), smoothstep(0.45, 0.78, cb2.r) * 0.50);
		earth = mix(earth, vec3(0.22, 0.145, 0.082), fRoot * 0.68);
		earth = mix(earth, mix(vec3(0.34, 0.175, 0.055), vec3(0.46, 0.26, 0.078), cb2.g), fLeaf * 0.34);
		earth *= 1.0 - rut * 0.85;
		tcol = mix(tcol, earth, fpath);
		float aCrack = is_near ? smoothstep(0.0, 0.16, abs(n_noise(xz * 3.2 + vec2(3.1, 8.2)) - 0.5)) : 0.85;
		float aRock = is_near ? smoothstep(0.54, 0.72, trHi2 * 0.65 + cb2.a * 0.35) : 0.25;
		float aMoss = smoothstep(0.46, 0.70, trHi1) * (1.0 - smoothstep(0.50, 0.76, trailEdge2));
		vec3 alpinePath = vec3(0.28, 0.24, 0.20) * (0.70 + 0.40 * aCrack);
		alpinePath = mix(alpinePath, vec3(0.50, 0.46, 0.40), aRock * 0.68);
		alpinePath = mix(alpinePath, vec3(0.24, 0.16, 0.09), fRoot * 0.42);
		alpinePath = mix(alpinePath, vec3(0.095, 0.24, 0.055), aMoss * 0.84);
		alpinePath *= 1.0 - rut * 0.90;
		tcol = mix(tcol, alpinePath, smoothstep(195.0, 320.0, h) * 0.92);
		tcol *= mix(0.62, 1.04, smoothstep(0.49, 0.62, trailEdge2));
		float vergeLip = smoothstep(0.32, 0.48, trailEdge2) * (1.0 - twTrail);
		col = mix(col, col * 0.60 + vec3(0.018, 0.022, 0.008), vergeLip * 0.76);
		col = mix(col, tcol, twTrail);
	}

	// ---- stream bed ----
	if (bed > 0.05) {
		vec4 pbLarge = is_near ? W_NOISE(xz * 0.95 + 0.17) : vec4(0.5);
		vec4 pbMed = is_near ? W_NOISE(xz * 2.2 + 0.51) : vec4(0.5);
		float cobble = smoothstep(0.44, 0.64, pbLarge.a);
		float peb = smoothstep(0.46, 0.66, pbMed.a);
		vec3 cWarm = vec3(0.55, 0.48, 0.38);
		vec3 gravel = mix(vec3(0.28, 0.26, 0.22), mix(vec3(0.38, 0.40, 0.42), cWarm, pbLarge.g), cobble);
		gravel = mix(gravel, mix(cWarm, vec3(0.62, 0.50, 0.34), pbMed.r), peb * 0.65);
		float bankMoss = w_rstep(0.58, 0.22, bed) * smoothstep(0.32, 0.68, pbLarge.r);
		gravel = mix(gravel, vec3(0.12, 0.32, 0.08), bankMoss * 0.75);
		if (!is_near) {
			gravel = mix(gravel, vec3(0.10, 0.28, 0.34), 0.55);
		}
		col = mix(col, gravel * 0.85, smoothstep(0.18, 0.48, bed));
		t_wet = max(t_wet, smoothstep(0.25, 0.55, bed) * 0.85);
	}

	col *= 0.93 + 0.14 * nH.a;

	// ---- underwater absorption, wetness, cottage AO ----
	vec3 albedo = col;
	float depthW = water_level - h;
	if (depthW > 0.0) {
		albedo *= exp(-depthW * vec3(0.32, 0.09, 0.07));
	}
	albedo *= mix(1.0, 0.56, t_wet);
	if (ao_spot.z > 0.0) {
		float dA = length(xz - ao_spot.xy);
		albedo *= 1.0 - ao_spot.w * (1.0 - smoothstep(ao_spot.z * 0.75, ao_spot.z * 1.35, dA));
	}

	// Open-trail glow weight (continuous in [0, 1] so bilinear filtering across tile texels is exact).
	float trM = smoothstep(0.35, 0.60, trail);
	float openPath = 1.0 - smoothstep(0.32, 0.68, bio.r) * 0.85;
	float trail_glow = clamp(trM * openPath, 0.0, 1.0);

	albedo = clamp(w_denan(albedo, vec3(0.15, 0.25, 0.10)), vec3(0.0), vec3(1.0));
	return vec4(sqrt(albedo), trail_glow);
}
