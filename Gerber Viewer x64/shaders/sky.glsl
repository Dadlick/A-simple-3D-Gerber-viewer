/// vertex

in vec2 in_Position;

out vec2 ex_Position;

void main()
{
	ex_Position = in_Position;
	gl_Position = vec4(in_Position, 1, 1.0);
}

/// fragment
#include "lib.glsl"

in vec2 ex_Position;

out vec4 out_Color;
DECLARE_DEPTH()

uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;
uniform mat4 ProjectionMatrixInverse;

const float pi = 3.14159265359;
const float radius = 4 * 100 * 100 * 100 / (2 * pi); // 4000 km circonference, rougly 500 km radus
const vec3 SkyCenter = vec3(0, -radius, 0);
const float AtmosphereRadius = radius + 10*1000;

void main()
{
	vec4 centerOffsetH = ViewMatrix * vec4(SkyCenter, 1);
	vec3 centerOffset = centerOffsetH.xyz / centerOffsetH.w;
	vec3 centerDirection = normalize(centerOffset);
	
	vec2 position = ex_Position;
	vec4 directionH = ProjectionMatrixInverse * vec4(position, 0, 1);
	vec3 direction = normalize(directionH.xyz / directionH.w);
	
	float ar = acos(dot(direction, centerDirection));
	float h = length(centerOffset);
	float r = AtmosphereRadius;
	
	if (h > r)
	{
		float max_ar = asin(r/h);
		if (ar > max_ar)
		{
			discard;
		}
	}
	
	float sin_ar = sin(ar);
	float ah = asin( h * sin_ar / r );
	float ad = pi - ar - ah;
	float d = r * sin(ad) / sin_ar;
#if 0
	// when zenith angle approaches zero, sinus imprecision create a dark spot
	if (sin_ar < 0.03)
	{
		// :FIXME: find a better solution, problem is still visible
		float factor = pow(sin_ar / 0.03, 4);
		d = d * factor + (r - h) * (1 - factor);
	}
#endif
	
	float distToCam = d;
	
	vec4 spherePosition = ProjectionMatrix * vec4(direction * distToCam, 1);
	
	out_Color = vec4(0, 0, 0, 1); // :TODO: compute alpha depending on distToCam and atmosphere scattering texture
	// :NOTE: the vertex shader generate a default depth on the far plane,
	// so only write a different value if we have objects outside of the
	// atmosphere (the depth test would fail on them even though the sky
	// is closer)
//	gl_FragDepth = spherePosition.z / spherePosition.w;
#if USE_DISTANCE_BUFFER
	out_Distance = distToCam * kDistToDepth;
#endif
}

// vi: ft=c
