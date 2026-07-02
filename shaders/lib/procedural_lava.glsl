// ------------------------------------------------------------------------- //
//   PROCEDURAL LAVA                                                          //
//   based on "Lava Pool" by Krzysztof Kondrak @k_kondrak (shadertoy)         //
//                                                                            //
//   the original uses a texture channel for noise and a self-feedback        //
//   buffer for advection. both are replaced here: hash-based value noise     //
//   stands in for iChannel1, and an iterated domain-warped "crust" pattern   //
//   stands in for the iChannel0 feedback loop, keeping the same              //
//   col += base * col * col accumulation that gives the blown-out            //
//   yellow-orange channels over dark crust.                                  //
// ------------------------------------------------------------------------- //

float pl_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float pl_valueNoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = pl_hash(i);
	float b = pl_hash(i + vec2(1.0, 0.0));
	float c = pl_hash(i + vec2(0.0, 1.0));
	float d = pl_hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// stand-in for the shadertoy's  noise(vec3 x)  texture lookup, signed output
float pl_noise3(vec3 x) {
	float z  = x.z * 7.0;
	float fz = smoothstep(0.0, 1.0, fract(z));
	float n0 = pl_valueNoise(x.xy + floor(z)       * vec2(41.3, 289.1));
	float n1 = pl_valueNoise(x.xy + (floor(z) + 1.0) * vec2(41.3, 289.1));
	return mix(n0, n1, fz) * 2.0 - 1.0;
}

vec2 pl_swirl(vec2 p) {
	return vec2(pl_noise3(vec3(p.xy, 0.33)), pl_noise3(vec3(p.yx, 0.66)));
}

// stand-in for the feedback buffer: dark crust with thin glowing channels
vec3 pl_base(vec2 uv, float t) {
	float n = 0.0;
	float amp = 0.5;
	vec2 q = uv;
	for (int i = 0; i < 4; i++) {
		n += amp * abs(pl_noise3(vec3(q, 1.7)));
		q = q * 2.03 + vec2(1.7, 9.2) + 0.05 * t;
		amp *= 0.5;
	}
	float channels = pow(clamp(1.0 - n * 1.6, 0.0, 1.0), 2.0);
	vec3 crust = vec3(0.045, 0.020, 0.012);
	vec3 glow  = vec3(1.0, 0.45, 0.05);
	return mix(crust, glow, channels);
}

vec3 proceduralLavaPool(vec2 uv, float t) {
	vec4 col = vec4(1.0, 0.9, 0.0, 1.0);
	vec2 p = uv;

	for (int i = 0; i < 3; i++) {
		p += 0.01 * pl_swirl(6.66 * p + t * 0.33);
		col += vec4(pl_base(p * 3.0, t), 1.0) * col * col;
	}

	return clamp(col.rgb * 0.066, 0.0, 1.0);
}

// planar-mapped by the dominant face axis so flowing lava sides work too
vec3 getProceduralLava(vec3 worldPos, vec3 worldNormal, float t) {
	vec3 an = abs(worldNormal);
	vec2 uv = an.y >= max(an.x, an.z) ? worldPos.xz : (an.x > an.z ? worldPos.zy : worldPos.xy);

	uv *= 0.08 * PROCEDURAL_LAVA_SCALE;

	return proceduralLavaPool(uv, t * PROCEDURAL_LAVA_SPEED);
}
