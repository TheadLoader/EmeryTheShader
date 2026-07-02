// ------------------------------------------------------------------------- //
//   PROCEDURAL FIRE                                                          //
//   based on the shadertoy fbm fire remix chain (XsXXRN -> llc3DM ->         //
//   MtcGD7 -> color remix). the iChannel0 detail texture is replaced         //
//   with an fbm term; everything else is a direct port.                      //
// ------------------------------------------------------------------------- //

float pf_rand(vec2 n) {
	return fract(sin(cos(dot(n, vec2(12.9898, 12.1414)))) * 83758.5453);
}

float pf_noise(vec2 n) {
	const vec2 d = vec2(0.0, 1.0);
	vec2 b = floor(n);
	vec2 f = smoothstep(vec2(0.0), vec2(1.0), fract(n));
	return mix(mix(pf_rand(b), pf_rand(b + d.yx), f.x), mix(pf_rand(b + d.xy), pf_rand(b + d.yy), f.x), f.y);
}

float pf_fbm(vec2 n) {
	float total = 0.0, amplitude = 1.0;
	for (int i = 0; i < 5; i++) {
		total += pf_noise(n) * amplitude;
		n += n * 1.7;
		amplitude *= 0.47;
	}
	return total;
}

// uv: x = horizontal along the flame, y = 0 at the flame base, 1 at the top
vec3 proceduralFire(vec2 uv, float time, bool soulFire) {
	float iTime = time * PROCEDURAL_FIRE_SPEED;

	const vec3 c1 = vec3(0.5, 0.0, 0.1);
	const vec3 c2 = vec3(0.9, 0.1, 0.0);
	const vec3 c3 = vec3(0.2, 0.1, 0.7);
	const vec3 c4 = vec3(1.0, 0.9, 0.1);
	const vec3 c5 = vec3(0.1);
	const vec3 c6 = vec3(0.9);

	vec2 speed = vec2(0.1, 0.9);
	float dist = 3.5 - sin(iTime * 0.4) / 1.89;

	vec2 p = uv * dist * PROCEDURAL_FIRE_SCALE;
	p += sin(p.yx * 4.0 + vec2(0.2, -0.3) * iTime) * 0.04;
	p += sin(p.yx * 8.0 + vec2(0.6, 0.1) * iTime) * 0.01;
	p.x -= iTime / 1.1;

	float q  = pf_fbm(p - iTime * 0.3  + 1.0  * sin(iTime + 0.5) / 2.0);
	float qb = pf_fbm(p - iTime * 0.4  + 0.1  * cos(iTime) / 2.0);
	float q2 = pf_fbm(p - iTime * 0.44 - 5.0  * cos(iTime) / 2.0)  - 6.0;
	float q3 = pf_fbm(p - iTime * 0.9  - 10.0 * cos(iTime) / 15.0) - 4.0;
	float q4 = pf_fbm(p - iTime * 1.4  - 20.0 * sin(iTime) / 14.0) + 2.0;
	q = (q + qb - 0.4 * q2 - 2.0 * q3 + 0.6 * q4) / 3.8;

	vec2 r = vec2(pf_fbm(p + q / 2.0 + iTime * speed.x - p.x - p.y), pf_fbm(p + q - iTime * speed.y));

	vec3 baseColor = soulFire ? vec3(0.05, 0.35, 1.0) : vec3(1.0, 0.2, 0.05);
	vec3 tintA     = soulFire ? vec3(0.2, 0.6, 0.9)   : vec3(0.9, 0.4, 0.3);
	vec3 tintB     = soulFire ? vec3(0.3, 0.8, 0.7)   : vec3(0.7, 0.5, 0.2);

	vec3 color = baseColor / (pow((r.y + r.y) * max(0.0, p.y) + 0.1, 4.0));
	// iChannel0 detail term replaced with an fbm sample
	color += (pf_fbm(uv * 4.0 + iTime * 0.5) * 0.01 * pow((r.y + r.y) * 0.65, 5.0) + 0.055) * mix(tintA, tintB, uv.y);
	color = color / (1.0 + max(vec3(0.0), color));

	return clamp(color, 0.0, 1.0);
}
