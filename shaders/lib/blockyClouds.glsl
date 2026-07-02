// ------------------------------------------------------------------------- //
//   BLOCKY VOLUMETRIC CLOUDS                                                 //
//   ported from Photon Shader by SixthSurge (include/sky/blocky_clouds.glsl) //
//   adapted to this pack's cloud API, lighting inputs and settings.          //
//                                                                            //
//   the cloud shapes come from the actual vanilla clouds.png, bound as       //
//   a custom texture (blockyCloudTex) in shaders.properties.                 //
// ------------------------------------------------------------------------- //

uniform sampler2D blockyCloudTex;

const float BC_PI = 3.14159265359;

const float bc_thickness = float(BLOCKY_CLOUDS_THICKNESS);

float bc_linearStep(float edge0, float edge1, float x) {
	return clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
}

float bc_kleinNishinaPhase(float cosTheta, float e) {
	return e / (2.0 * BC_PI * (e * (1.0 - cosTheta) + 1.0) * log(2.0 * e + 1.0));
}

float bc_henyeyGreensteinPhase(float cosTheta, float g) {
	const float isotropic = 1.0 / (4.0 * BC_PI);
	return isotropic * (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cosTheta, 1.5);
}

float bc_phaseSingle(float cosTheta) {
	return 0.7 * bc_kleinNishinaPhase(cosTheta, 2600.0)
	     + 0.3 * bc_henyeyGreensteinPhase(cosTheta, -0.2);
}

float bc_phaseMulti(float cosTheta, vec3 g) {
	return 0.65 * bc_henyeyGreensteinPhase(cosTheta,  g.x)
	     + 0.10 * bc_henyeyGreensteinPhase(cosTheta,  g.y)
	     + 0.25 * bc_henyeyGreensteinPhase(cosTheta, -g.z);
}

float bc_extinctionCoeff() {
	return mix(0.66, 1.0, smoothstep(0.0, 0.3, abs(sunElevation)));
}

// sharp-edged bilinear: the closer the borders are to 0.5, the blockier the clouds
float bc_textureSoft(sampler2D tex, vec2 coord, float softness) {
	vec2 res = vec2(textureSize(tex, 0));

	coord = coord * res + 0.5;
	vec2 i, f = modf(coord, i);

	f = smoothstep(0.5 - softness, 0.5 + softness, f);
	coord = (i + 1.0) / res;

	vec4 samples = textureGather(tex, coord, 3);
	vec4 weights = vec4(
		f.y - f.x * f.y,
		f.x * f.y,
		f.x - f.x * f.y,
		1.0 - f.x - f.y + f.x * f.y
	);

	return dot(samples, weights);
}

float bc_density(vec3 worldPos, float altitudeFraction, float layerOffset) {
	const float windAngle = 30.0 * (BC_PI / 180.0);
	const vec2 windVelocity = 0.33 * vec2(cos(windAngle), sin(windAngle));

	const float roundness = 0.5 * BLOCKY_CLOUDS_ROUNDNESS;
	const float sharpness = 0.5 * BLOCKY_CLOUDS_SHARPNESS;

	worldPos.xz = abs(worldPos.xz + 3000.0 + layerOffset);
	worldPos.xz += windVelocity * frameTimeCounter * 20.0;

	// vanilla minecraft cloud pattern
	float density = bc_textureSoft(blockyCloudTex, worldPos.xz * 0.00018 / BLOCKY_CLOUDS_SIZE, roundness);

	density *= bc_linearStep(0.0, roundness, altitudeFraction);
	density *= bc_linearStep(0.0, roundness, 1.0 - altitudeFraction);
	density  = bc_linearStep(sharpness, 1.0 - sharpness, density);

	return clamp(density, 0.0, 1.0);
}

float bc_opticalDepth(vec3 rayOrigin, vec3 rayDir, float layerAltitude, float layerOffset, float dither, const int stepCount) {
	const float stepGrowth = 1.2;

	float stepLength = bc_thickness / float(stepCount);

	vec3 rayPos = rayOrigin;
	vec4 rayStep = vec4(rayDir, 1.0) * stepLength;

	float opticalDepth = 0.0;

	for (int i = 0; i < stepCount; ++i, rayPos += rayStep.xyz) {
		rayStep *= stepGrowth;
		vec3 worldPos = rayPos + rayStep.xyz * dither;
		float altitudeFraction = clamp((worldPos.y - layerAltitude) / bc_thickness, 0.0, 1.0);

		opticalDepth += bc_density(worldPos, altitudeFraction, layerOffset) * rayStep.w;
	}

	return opticalDepth;
}

vec2 bc_scattering(float density, float lightOpticalDepth, float skyOpticalDepth, float groundOpticalDepth, float stepTransmittance, float cosTheta, float bouncedLight) {
	const float isotropicPhase = 1.0 / (4.0 * BC_PI);

	vec2 scattering = vec2(0.0);

	float extinctionCoeff = bc_extinctionCoeff();
	float scatterAmount = extinctionCoeff;
	float extinctAmount = extinctionCoeff;

	float powder = 5.0 * (1.0 - exp2(-8.0 * density));

	float scatteringIntegral = (1.0 - stepTransmittance) / extinctionCoeff;

	float phase = bc_phaseSingle(cosTheta);
	vec3 phaseG = pow(vec3(0.6, 0.9, 0.3), vec3(1.0 + lightOpticalDepth));

	for (int i = 0; i < 8; ++i) {
		scattering.x += scatterAmount * exp(-extinctAmount * lightOpticalDepth) * phase;
		scattering.x += scatterAmount * exp(-extinctAmount * groundOpticalDepth) * isotropicPhase * bouncedLight;
		scattering.y += scatterAmount * exp(-extinctAmount * skyOpticalDepth) * isotropicPhase;

		scatterAmount *= 0.5;
		extinctAmount *= 0.5;
		phaseG *= 0.8;

		phase = bc_phaseMulti(cosTheta, phaseG);
	}

	return scattering * scatteringIntegral * powder;
}

vec4 bc_raymarchLayer(vec3 worldDir, float geometryDistance, bool sky, float layerAltitude, float layerOffset, vec2 dither, vec3 lightDir, vec3 lightColor, vec3 ambientColor, inout float hitDistance, inout float hitWeight) {
	const int primarySteps = 12;
	const int lightingSteps = 4;
	const float maxRayLength = 512.0;
	const float minTransmittance = 0.075;

	float eyeAltitude = cameraPosition.y;

	float distanceToLowerPlane = (layerAltitude - eyeAltitude) / worldDir.y;
	float distanceToUpperPlane = (layerAltitude + bc_thickness - eyeAltitude) / worldDir.y;
	float distanceToVolumeStart, distanceToVolumeEnd;

	if (eyeAltitude < layerAltitude) {
		distanceToVolumeStart = distanceToLowerPlane;
		distanceToVolumeEnd = worldDir.y < 0.0 ? -1.0 : distanceToUpperPlane;
	} else if (eyeAltitude < layerAltitude + bc_thickness) {
		distanceToVolumeStart = 0.0;
		distanceToVolumeEnd = worldDir.y < 0.0 ? distanceToLowerPlane : distanceToUpperPlane;
	} else {
		distanceToVolumeStart = distanceToUpperPlane;
		distanceToVolumeEnd = worldDir.y < 0.0 ? distanceToLowerPlane : -1.0;
	}

	if (distanceToVolumeEnd < 0.0) return vec4(vec3(0.0), 1.0);

	float rayLength = sky ? distanceToVolumeEnd : geometryDistance;
	rayLength = clamp(rayLength - distanceToVolumeStart, 0.0, maxRayLength);

	if (rayLength <= 0.0) return vec4(vec3(0.0), 1.0);

	float stepLength = rayLength / float(primarySteps);

	vec3 worldStep = worldDir * stepLength;
	vec3 worldPos = cameraPosition + worldDir * (distanceToVolumeStart + stepLength * dither.x);

	vec3 scattering = vec3(0.0);
	float transmittance = 1.0;

	float cosTheta = dot(worldDir, lightDir);
	const float bouncedLight = 0.0;

	mat2x3 lightColors = mat2x3(lightColor, ambientColor);

	float distanceSum = 0.0;
	float distanceWeightSum = 0.0;

	for (int i = 0; i < primarySteps; ++i, worldPos += worldStep) {
		if (transmittance < minTransmittance) break;

		float altitudeFraction = (worldPos.y - layerAltitude) / bc_thickness;

		float density = bc_density(worldPos, altitudeFraction, layerOffset);
		if (density < 1e-6) continue;

		float stepOpticalDepth = density * bc_extinctionCoeff() * stepLength;
		float stepTransmittance = exp(-stepOpticalDepth);

		float lightOpticalDepth = bc_opticalDepth(worldPos, lightDir, layerAltitude, layerOffset, dither.y, lightingSteps);
		float groundOpticalDepth = bc_thickness * altitudeFraction;
		float skyOpticalDepth = bc_thickness * (1.0 - altitudeFraction);

		float heightShade = mix(0.8, 1.25, altitudeFraction * altitudeFraction * (3.0 - 2.0 * altitudeFraction));

		scattering += lightColors * bc_scattering(density, lightOpticalDepth, skyOpticalDepth, groundOpticalDepth, stepTransmittance, cosTheta, bouncedLight) * transmittance * heightShade;

		transmittance *= stepTransmittance;

		float distanceToSample = distance(cameraPosition, worldPos);
		distanceSum += distanceToSample * density;
		distanceWeightSum += density;
	}

	// remap the transmittance so that minTransmittance is 0
	transmittance = bc_linearStep(minTransmittance, 1.0, transmittance);

	// distance fade
	float distanceFade = distanceWeightSum == 0.0 ? 1.0 : exp(-0.002 * distanceSum / distanceWeightSum);

	scattering *= distanceFade * mix(vec3(1.0, 0.66, 0.50), vec3(1.0), distanceFade);
	transmittance = mix(1.0, transmittance, distanceFade);

	if (distanceWeightSum > 0.0) {
		hitDistance += distanceSum;
		hitWeight += distanceWeightSum;
	}

	return vec4(scattering, transmittance);
}

vec4 GetBlockyClouds(
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

	bool moonlit = sunElevation < -0.035;
	vec3 lightDir = moonlit ? moonVector : sunVector;
	vec3 lightColor = (moonlit ? directLightCol2 : directLightCol) * 6.0 * BLOCKY_CLOUDS_BRIGHTNESS;
	lightColor *= 1.5 - 0.5 * smoothstep(0.0, 0.15, abs(sunElevation));
	lightColor *= 1.0 - 0.8 * rainStrength;
	vec3 ambientColor = indirectLightCol * 4.0 * BLOCKY_CLOUDS_BRIGHTNESS;

	float hitDistance = 0.0;
	float hitWeight = 0.0;

	vec4 result = vec4(0.0, 0.0, 0.0, 1.0);

	#ifdef BLOCKY_CLOUDS_LAYER_2
		// march the nearer layer first so blending order is correct
		float altA = BLOCKY_CLOUDS_ALTITUDE;
		float altB = BLOCKY_CLOUDS_ALTITUDE_2;
		if (abs(cameraPosition.y - altB) < abs(cameraPosition.y - altA)) {
			float tmp = altA; altA = altB; altB = tmp;
		}

		vec4 layerA = bc_raymarchLayer(worldDir, geometryDistance, sky, altA, abs(altA - BLOCKY_CLOUDS_ALTITUDE_2) < 0.5 ? 3000.0 : 0.0, dither, lightDir, lightColor, ambientColor, hitDistance, hitWeight);
		vec4 layerB = bc_raymarchLayer(worldDir, geometryDistance, sky, altB, abs(altB - BLOCKY_CLOUDS_ALTITUDE_2) < 0.5 ? 3000.0 : 0.0, dither, lightDir, lightColor, ambientColor, hitDistance, hitWeight);

		result.rgb = layerA.rgb + layerA.a * layerB.rgb;
		result.a = layerA.a * layerB.a;
	#else
		result = bc_raymarchLayer(worldDir, geometryDistance, sky, BLOCKY_CLOUDS_ALTITUDE, 0.0, dither, lightDir, lightColor, ambientColor, hitDistance, hitWeight);
	#endif

	if (hitWeight > 0.0) {
		cloudPlaneDistance = clamp(hitDistance / hitWeight, 0.0, far * 8.0);
	}

	return result;
}
