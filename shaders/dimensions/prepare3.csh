#include "/lib/settings.glsl"

#if defined ENTITY_WATER_RIPPLES && WATER_INTERACTION == 2
    // this pass also wipes last frame's entity/item ripple stamps
    // (prepare1 and prepare2 already consumed them earlier this frame, and the
    // gbuffers re-stamp fresh positions right after this pass), so it needs one
    // thread per stamp texel instead of a single 1x1 dispatch.
    // the stamp image is half the wave sim resolution.
    layout (local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

    #if WATER_SIM_SCALE == 0
        #if WATER_SIM_DISTANCE == 1
            const ivec3 workGroups = ivec3(16, 16, 1);
        #elif WATER_SIM_DISTANCE == 2
            const ivec3 workGroups = ivec3(32, 32, 1);
        #elif WATER_SIM_DISTANCE == 3
            const ivec3 workGroups = ivec3(48, 48, 1);
        #else
            const ivec3 workGroups = ivec3(64, 64, 1);
        #endif
    #elif WATER_SIM_SCALE == 1
        #if WATER_SIM_DISTANCE == 1
            const ivec3 workGroups = ivec3(32, 32, 1);
        #elif WATER_SIM_DISTANCE == 2
            const ivec3 workGroups = ivec3(64, 64, 1);
        #elif WATER_SIM_DISTANCE == 3
            const ivec3 workGroups = ivec3(96, 96, 1);
        #else
            const ivec3 workGroups = ivec3(128, 128, 1);
        #endif
    #else
        #if WATER_SIM_DISTANCE == 1
            const ivec3 workGroups = ivec3(64, 64, 1);
        #elif WATER_SIM_DISTANCE == 2
            const ivec3 workGroups = ivec3(128, 128, 1);
        #elif WATER_SIM_DISTANCE == 3
            const ivec3 workGroups = ivec3(192, 192, 1);
        #else
            const ivec3 workGroups = ivec3(256, 256, 1);
        #endif
    #endif

    layout (r32ui) uniform writeonly uimage2D entityStampImg;
#else
    layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

    const ivec3 workGroups = ivec3(1, 1, 1);
#endif

#include "/lib/SSBOs.glsl"

uniform float frameTimeCounter;
uniform vec3 cameraPosition;
uniform vec3 relativeEyePosition;

#if IRIS_VERSION >= 11004
  uniform vec3 relativeVehiclePosition;
  uniform bool isRiding;
#endif

void main() {
  #if WATER_INTERACTION == 2

    #ifdef ENTITY_WATER_RIPPLES
      ivec2 imgCoord = ivec2(gl_GlobalInvocationID.xy);
      if (all(lessThan(imgCoord, imageSize(entityStampImg))))
          imageStore(entityStampImg, imgCoord, uvec4(0u));

      // everything below only needs to run once
      if (gl_GlobalInvocationID.x != 0u || gl_GlobalInvocationID.y != 0u) return;

      // the gbuffers set this again later this frame if anything is still in water
      entityRippleWakeSSBO = false;
    #endif

    if (abs(frameTimeCounter - lastFrameTimeCount) > WATER_SIM_FRAMETIME) {
      lastFrameTimeCount = frameTimeCounter;
      
      #if IRIS_VERSION >= 11004
      if(isRiding) {
        previousCameraPositionWave2 = cameraPosition - relativeVehiclePosition;
      } else
      #endif
      {
        previousCameraPositionWave2 = cameraPosition - relativeEyePosition;
      }
    }

    #if IRIS_VERSION >= 11004
    if(isRiding) {
      previousCameraPositionWave = cameraPosition - relativeVehiclePosition;
    } else
    #endif
    {
      previousCameraPositionWave = cameraPosition - relativeEyePosition;
    }
  #endif
}
