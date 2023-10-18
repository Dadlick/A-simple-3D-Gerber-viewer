/// vertex

in vec3 in_Position;
in vec2 in_TexCoord;

invariant gl_Position;
out vec3 ex_Position;
out vec2 ex_TexCoord;

void main()
{
	gl_Position = vec4(in_Position, 1.0);
	ex_Position = in_Position;
	ex_TexCoord = in_TexCoord;
}

/// fragment
#include "lib.glsl"

in vec3 ex_Position;
in vec2 ex_TexCoord;

out vec4 out_Color;

#if MULTISAMPLE
#define SAMPLER sampler2DMS
#define SAMPLE gl_SampleID
#else
#define SAMPLER sampler2D
#define SAMPLE 0
#endif

uniform SAMPLER ColorTexture;
#if USE_DISTANCE_BUFFER
uniform SAMPLER DistanceTexture;
#endif
uniform sampler2D ScatteringTexture;
#if USE_DITHERING
uniform sampler2D DitheringTexture;
#endif

uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrixInverse;
uniform vec3 SunDirection;

uniform int DebugNumber;

const float pi = 3.14159265359;
const float radius = 4 * 100 * 100 * 100 / (2 * pi); // 4000 km circonference, rougly 500 km radus
const vec3 SkyCenter = vec3(0, -radius, 0);
const float AtmosphereRadius = radius + 10*1000;

void main()
{
	// see:
	// - http://en.wikipedia.org/wiki/Airmass
	// - http://en.wikipedia.org/wiki/Beer%27s_law
	
	float distanceToAtmosphere = 0;
	{
		vec4 centerOffsetH = ViewMatrix * vec4(SkyCenter, 1);
		vec3 centerOffset = centerOffsetH.xyz / centerOffsetH.w;
		vec3 centerDirection = normalize(centerOffset);
		
		vec2 position = ex_Position.xy;
		vec4 directionH = ProjectionMatrixInverse * vec4(position, 0, 1);
		vec3 direction = normalize(directionH.xyz / directionH.w);
		
		float h = length(centerOffset);
		float r = AtmosphereRadius;
		
		if (h > r)
		{
			float alpha = acos(dot(direction, centerDirection));
			float sin_alpha = sin(alpha);
			float gamma = pi - asin(h*sin_alpha/r);
			float beta = pi - alpha - gamma;
			float d = r * sin(beta) / sin_alpha;
#if 0
			// when zenith angle approaches pi, sinus imprecision create a dark spot
			if (sin_alpha < 0.03)
			{
				// :FIXME: find a better solution, problem is still visible
				float factor = pow(sin_alpha / 0.03, 4);
				d = d * factor + (h - r) * (1 - factor);
			}
#endif
			
			if (d >= 0)
				distanceToAtmosphere = d;
			else
				distanceToAtmosphere = -1; // camera and target are outside of the atmosphere
		}
	}
	
	vec4 FragPosition = ProjectionMatrixInverse * vec4(ex_Position, 1);
	vec3 FragDirection = normalize(FragPosition.xyz);
	float d = dot(SunDirection, FragDirection);
	float angleToSun = acos(d);
	
	float x = angleToSun / 3.14159265359;
	
	vec4 color = vec4(0, 0, 0, 0);
	
#if MULTISAMPLE
	float msfactor = 1.0 / MULTISAMPLE;
	for (int sampleID=0; sampleID<MULTISAMPLE; ++sampleID)
#else
	float msfactor = 1.0;
	int sampleID = 0;
#endif
	{
#if USE_DISTANCE_BUFFER
		float distanceToScene = texelFetch(DistanceTexture, ivec2(gl_FragCoord.x, gl_FragCoord.y), sampleID).r * kDepthToDist;
		
		float thickness = distanceToAtmosphere!=-1 ? distanceToScene - distanceToAtmosphere : 0.0;
#else
		float thickness = 0;
#endif
		
		float y = log(thickness) / log(10.0*1000.0*1000.0);
		y = 0;
		vec4 scattering = texture(ScatteringTexture, vec2(x, y)) * 15;
		scattering.a = 1;
		
#if ATMOSPHERE
		float factor = clamp(thickness / (200*1000), 0, 1); // :TODO: use scattering alpha, since texel already depends on distance
#endif
		vec4 direct = texelFetch(ColorTexture, ivec2(gl_FragCoord.x, gl_FragCoord.y), sampleID);
#if ATMOSPHERE
		vec4 sample = (direct * (1-factor) + scattering * factor);
#else
		vec4 sample = direct;
#endif
		color += sample * msfactor;
	}
	// we need to divide by alpha to "spill" the color over transparent areas
	// of the pixel, since alpha blending will re-multiply by alpha
	// (in other words, normal rendering is alpha-pre-multiplied, but UI textures are not)
	color.rgb = color.rgb / color.a;
	
#if USE_DITHERING
	color += (texture(DitheringTexture, gl_FragCoord.xy / 128) - vec4(0.5,0.5,0.5,0.5)) / 255;
#endif
#if ATMOSPHERE
	out_Color = vec4(color.rgb, 1);
#else
	out_Color = color;
#endif
}

// vi: ft=c
