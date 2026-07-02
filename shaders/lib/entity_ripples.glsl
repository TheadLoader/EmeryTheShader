// ------------------------------------------------------------------------- //
//   ENTITY & ITEM WATER RIPPLES                                              //
//                                                                            //
//   Every vertex of an entity (mobs, other players, boats, dropped items,   //
//   arrows, ...) that sits inside the TOP layer of water stamps a small     //
//   impulse into entityStampImg. prepare1.csh / prepare2.csh then feed      //
//   those impulses into the existing wave simulation as extra pressure,     //
//   and prepare3.csh wipes the stamps again every frame.                    //
//                                                                            //
//   Water detection uses the LPV voxel data (same trick prepare.csh uses    //
//   for the pre-Iris-1.7.4 player detection), so this needs IS_LPV_ENABLED. //
//                                                                            //
//   The includer must provide BEFORE this include:                          //
//     /lib/settings.glsl, /lib/SSBOs.glsl, /lib/blocks.glsl,                //
//     /lib/entities.glsl, uniform vec3 cameraPosition, uniform int entityId //
// ------------------------------------------------------------------------- //

#if defined ENTITIES && defined ENTITY_WATER_RIPPLES && WATER_INTERACTION == 2 && defined IS_LPV_ENABLED

	#define ENTITY_RIPPLES_ACTIVE

	layout(r32ui) uniform uimage2D entityStampImg;

	#include "/lib/lpv_common.glsl"
	#include "/lib/voxel_common.glsl"

	#if IRIS_VERSION >= 11004
		uniform bool isRiding;
		uniform int vehicleId;
	#endif

	uint ER_GetVoxelBlock(const in ivec3 voxelPos) {
		if (clamp(voxelPos, ivec3(0), ivec3(VoxelSize3 - 1u)) != voxelPos)
			return BLOCK_EMPTY;

		return imageLoad(imgVoxelMask, voxelPos).r % 2000u;
	}

	// must match getPlayerMovementOffset() in prepare.csh
	#if WATER_SIM_SCALE == 0
		const float ER_TEXELS_PER_BLOCK = 20.0;
		const int ER_SPLAT_RADIUS = 2;
	#elif WATER_SIM_SCALE == 1
		const float ER_TEXELS_PER_BLOCK = 40.0;
		const int ER_SPLAT_RADIUS = 3;
	#else
		const float ER_TEXELS_PER_BLOCK = 80.0;
		const int ER_SPLAT_RADIUS = 6;
	#endif

	// playerPos = feet-player-space position of the current vertex
	void stampEntityRipple(vec3 playerPos) {

		// things that should never push water around
		if (entityId == ENTITY_SHADOW || entityId == ENTITY_NAME_TAG || entityId == ENTITY_CURRENT_PLAYER) return;

		#if IRIS_VERSION >= 11004
			// the boat/ship the player is riding already gets stamped at the
			// sim center with its own directional shape. don't stamp it twice.
			if (isRiding && entityId == vehicleId && (entityId == ENTITY_BOAT || entityId == ENTITY_SMALLSHIPS)) return;
		#endif

		// only vertices inside the TOP layer of the fluid make ripples:
		// fluid at the vertex, but no fluid directly above it.
		ivec3 voxelPos = ivec3(GetLpvPosition(playerPos));
		uint blockHere  = ER_GetVoxelBlock(voxelPos);
		uint blockAbove = ER_GetVoxelBlock(voxelPos + ivec3(0, 1, 0));

		#ifdef LAVA_RIPPLES
			bool inFluid = blockHere == BLOCK_WATER || blockHere == BLOCK_LAVA;
			bool fluidAbove = blockAbove == BLOCK_WATER || blockAbove == BLOCK_LAVA;
		#else
			bool inFluid = blockHere == BLOCK_WATER;
			bool fluidAbove = blockAbove == BLOCK_WATER;
		#endif

		if (!inFluid || fluidAbove) return;

		// world position -> wave sim texel -> stamp texel (stamp image is sim res / 2)
		ivec2 imgSize = imageSize(entityStampImg);
		vec2 stampPos = (playerPos.xz + cameraPosition.xz - previousCameraPositionWave2.xz) * (ER_TEXELS_PER_BLOCK * 0.5) + vec2(imgSize) * 0.5;

		ivec2 base = ivec2(floor(stampPos));
		if (clamp(base, ivec2(ER_SPLAT_RADIUS + 1), imgSize - ER_SPLAT_RADIUS - 2) != base) return;

		vec2 subTexel = fract(stampPos) - 0.5;

		// splat a small smooth disc. overlapping splats from neighboring
		// vertices max-blend together into the entity's waterline footprint.
		for (int x = -ER_SPLAT_RADIUS; x <= ER_SPLAT_RADIUS; x++) {
			for (int y = -ER_SPLAT_RADIUS; y <= ER_SPLAT_RADIUS; y++) {
				float falloff = smoothstep(float(ER_SPLAT_RADIUS) + 0.5, 0.0, length(vec2(x, y) - subTexel));
				uint value = uint(falloff * 255.0);
				if (value == 0u) continue;

				imageAtomicMax(entityStampImg, base + ivec2(x, y), value);
			}
		}

		// wake the simulation up if it went to sleep
		entityRippleWakeSSBO = true;
	}
#endif
