
const float kDistToDepth = 1.0/exp2(64.0);
const float kDepthToDist = exp2(64.0);

#if USE_DISTANCE_BUFFER

#define DECLARE_DEPTH() \
	out float out_Distance;

#define WRITE_DEPTH() { \
	float distToCam = length(ex_Position); \
	/*gl_FragDepth = distToCam * kDistToDepth;*/ \
	out_Distance = distToCam * kDistToDepth; \
}

#else

#define DECLARE_DEPTH()
#define WRITE_DEPTH()

#endif

// vi: ft=c
