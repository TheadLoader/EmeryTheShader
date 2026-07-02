// ------------------------------------------------------------------------- //
//   REALISTIC PHOTON-STYLE CLOUDS                                            //
//   adapted from Photon Shader by SixthSurge (include/sky/clouds/cumulus)    //
//   density shaping, 3D worley detail erosion (using photon's actual         //
//   worley_bubbly / worley_swirley textures) and the multiple-scattering     //
//   octave ladder, fitted to this pack's cloud API. shares the phase and     //
//   scattering helpers from blockyClouds.glsl.                               //
// ------------------------------------------------------------------------- //

uniform sampler3D worleyBubblyTex;
uniform sampler3D worleySwirleyTex;

float pc_hash(vec2 p) {
	p = fract(p * vec2(385.18692, 958.5519));
	p += dot(p, p + 42.4112);
	return fract(p.x * p.y);
}

float pc_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(pc_hash(i), pc_hash(i + vec2(1, 0)), f.x),
	           mix(pc_hash(i + vec2(0, 1)), pc_hash(i + vec2(1, 1)), f.x), f.y);
}

// 2D local coverage, photon-style
float pc_coverage(vec2 pos) {
	pos *= 0.00016;

	float c = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		c += amp * pc_noise(pos);
		pos = pos * 2.4 + 17.31;
		amp *= 0.5;
	}

	float coverageAmount = 0.55 * PHOTON_CLOUDS_COVERAGE + 0.25 * rainStrength;
	return bc_linearStep(1.0 - coverageAmount, 1.05 - 0.5 * coverageAmount, c * 1.35);
}

float pc_density(vec3 worldPos, float altitudeFraction) {
	const float windAngle = 30.0 * (BC_PI / 180.0);
	const vec2 windVelocity = 4.0 * vec2(cos(windAngle), sin(windAngle));
	vec3 wind = vec3(windVelocity * frameTimeCounter, 0.0).xzy;

	worldPos.xz += wind.xz;

	float density = pc_coverage(worldPos.xz);

	// altitude shaping (photon cumulus): grow from the base, carve an egg shape
	density *= bc_linearStep(0.0, 0.2, altitudeFraction);
	density -= smoothstep(0.2, 1.0, altitudeFraction) * 0.6;
	density -= 0.12 * (1.0 - bc_linearStep(0.0, 0.1, altitudeFraction));

	if (density < 1e-4) return 0.0;

	// 3D worley erosion using photon's noise textures
	float worley0 = texture(worleyBubblyTex,  (worldPos + 0.2 * wind) * 0.0035).x;
	float worley1 = texture(worleySwirleyTex, (worldPos + 0.4 * wind) * 0.016).x;

	float detailFade = 0.20 * smoothstep(0.85, 1.0, 1.0 - altitudeFraction)
	                 - 0.35 * smoothstep(0.05, 0.5, altitudeFraction) + 0.6;

	density -= (0.33 * worley0 * worley0) * detailFade * PHOTON_CLOUDS_DETAIL;
	density -= (0.40 * worley1 * worley1) * detailFade * detailFade * PHOTON_CLOUDS_DETAIL;

	if (density < 1e-4) return 0.0;

	// sharpen (photon: adjust density)
	density = 1.0 - pow(1.0 - density, mix(4.0, 10.0, altitudeFraction));
	density *= 0.6 + 0.4 * smoothstep(0.0, 0.25, altitudeFraction);

	return clamp(density, 0.0, 1.0);
}

float pc_opticalDepth(vec3 rayOrigin, vec3 rayDir, float layerAltitude, float dither, const int stepCount) {
	const float stepGrowth = 1.5;

	float stepLength = float(PHOTON_CLOUDS_THICKNESS) * 0.1;

	vec3 rayPos = rayOrigin;
	vec4 rayStep = vec4(rayDir, 1.0) * stepLength;

	float opticalDepth = 0.0;

	for (int i = 0; i < stepCount; ++i, rayPos += rayStep.xyz) {
		rayStep *= stepGrowth;
		vec3 pos = rayPos + rayStep.xyz * dither;
		float altitudeFraction = clamp((pos.y - layerAltitude) / float(PHOTON_CLOUDS_THICKNESS), 0.0, 1.0);
		opticalDepth += pc_density(pos, altitudeFraction) * rayStep.w;
	}

	return opticalDepth;
}

vec4 GetPhotonClouds(
	vec3 viewPos,
	vec2 dither,
	vec3 sunVector,
	vec3 moonVector,
	vec3 directLightCol,
	vec3 directLightCol2,
	vec3 indirectLightCol,

	inout float cloudPlaneDistance,
	inout vec2 cloudDistance
){
	const int primarySteps = PHOTON_CLOUDS_QUALITY;
	const int lightingSteps = 4;
	const float minTransmittance = 0.075;
	const float layerAltitude = float(PHOTON_CLOUDS_ALTITUDE);
	const float layerThickness = float(PHOTON_CLOUDS_THICKNESS);
	const float maxRayLength = layerThickness * 24.0;

	#if defined DISTANT_HORIZONS || defined VOXY
		const float maxdist = dhVoxyFarPlane - 16.0;
	#else
		const float maxdist = far + 16.0*5.0;
	#endif

	cloudPlaneDistance = far * 8.0;
	cloudDistance = vec2(0.0);

	vec4 playerDir = normalize(gbufferModelViewInverse * vec4(viewPos, 1.0) + vec4(gbufferModelViewInverse[3].xyz, 0.0));
	vec3 worldDir = playerDir.xyz;

	float geometryDistance = length(viewPos);
	bool sky = geometryDistance >= maxdist;

	float eyeAltitude = cameraPosition.y;

	float distanceToLowerPlane = (layerAltitude - eyeAltitude) / worldDir.y;
	float distanceToUpperPlane = (layerAltitude + layerThickness - eyeAltitude) / worldDir.y;
	float distanceToVolumeStart, distanceToVolumeEnd;

	if (eyeAltitude < layerAltitude) {
		distanceToVolumeStart = distanceToLowerPlane;
		distanceToVolumeEnd = worldDir.y < 0.0 ? -1.0 : distanceToUpperPlane;
	} else if (eyeAltitude < layerAltitude + layerThickness) {
		distanceToVolumeStart = 0.0;
		distanceToVolumeEnd = worldDir.y < 0.0 ? distanceToLowerPlane : distanceToUpperPlane;
	} else {
		distanceToVolumeStart = distanceToUpperPlane;
		distanceToVolumeEnd = worldDir.y < 0.0 ? distanceToLowerPlane : -1.0;
	}

	if (distanceToVolumeEnd < 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

	float rayLength = sky ? distanceToVolumeEnd : geometryDistance;
	rayLength = clamp(rayLength - distanceToVolumeStart, 0.0, maxRayLength);
	if (rayLength <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

	float stepLength = rayLength / float(primarySteps);
	vec3 worldStep = worldDir * stepLength;
	vec3 worldPos = cameraPosition + worldDir * (distanceToVolumeStart + stepLength * dither.x);

	bool moonlit = sunElevation < -0.035;
	vec3 lightDir = moonlit ? moonVector : sunVector;
	vec3 lightColor = (moonlit ? directLightCol2 : directLightCol) * 6.0 * PHOTON_CLOUDS_BRIGHTNESS;
	lightColor *= 1.5 - 0.5 * smoothstep(0.0, 0.15, abs(sunElevation));
	vec3 ambientColor = indirectLightCol * 4.0 * PHOTON_CLOUDS_BRIGHTNESS;
	mat2x3 lightColors = mat2x3(lightColor, ambientColor);

	float cosTheta = dot(worldDir, lightDir);

	vec3 scattering = vec3(0.0);
	float transmittance = 1.0;
	float distanceSum = 0.0;
	float distanceWeightSum = 0.0;

	for (int i = 0; i < primarySteps; ++i, worldPos += worldStep) {
		if (transmittance < minTransmittance) break;

		float altitudeFraction = (worldPos.y - layerAltitude) / layerThickness;

		float density = pc_density(worldPos, altitudeFraction);
		if (density < 1e-6) continue;

		float stepOpticalDepth = density * bc_extinctionCoeff() * stepLength * 0.1;
		float stepTransmittance = exp(-stepOpticalDepth);

		float lightOpticalDepth = pc_opticalDepth(worldPos, lightDir, layerAltitude, dither.y, lightingSteps) * 0.1;
		float groundOpticalDepth = layerThickness * altitudeFraction * 0.1;
		float skyOpticalDepth = layerThickness * (1.0 - altitudeFraction) * 0.1;

		float heightShade = mix(0.8, 1.25, altitudeFraction * altitudeFraction * (3.0 - 2.0 * altitudeFraction));

		scattering += lightColors * bc_scattering(density, lightOpticalDepth, skyOpticalDepth, groundOpticalDepth, stepTransmittance, cosTheta, 0.0) * transmittance * heightShade;

		transmittance *= stepTransmittance;

		float distanceToSample = distance(cameraPosition, worldPos);
		distanceSum += distanceToSample * density;
		distanceWeightSum += density;
	}

	transmittance = bc_linearStep(minTransmittance, 1.0, transmittance);

	float distanceFade = distanceWeightSum == 0.0 ? 1.0 : exp(-0.0004 * distanceSum / distanceWeightSum);
	scattering *= distanceFade * mix(vec3(1.0, 0.75, 0.6), vec3(1.0), distanceFade);
	transmittance = mix(1.0, transmittance, distanceFade);

	if (distanceWeightSum > 0.0) {
		cloudPlaneDistance = clamp(distanceSum / distanceWeightSum, 0.0, far * 8.0);
	}

	return vec4(scattering, transmittance);
}
