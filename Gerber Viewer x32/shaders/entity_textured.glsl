/// vertex

in vec3 in_Position;
in vec3 in_Normal;
in vec3 in_Color;

out vec3 ex_Color;
out float ex_DiffuseLight;
out vec3 ex_Position;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;
uniform vec3 SunDirection;

void main()
{
	mat4 ModelViewMatrix = ViewMatrix * ModelMatrix;
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ModelViewMatrix;
	vec4 position = ModelViewMatrix * vec4(in_Position, 1.0);
	ex_Position = position.xyz / position.w;
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 1.0);
	
	vec3 N = (ModelMatrix * vec4(in_Normal, 0.0)).xyz;
	vec3 L = SunDirection;
	
	float nDotL = max(dot(N, L), 0);
	
	ex_Color = in_Color;
	ex_DiffuseLight = nDotL;
}

/// fragment
#include "lib.glsl"

in vec3 ex_Color;
in float ex_DiffuseLight;
in vec3 ex_Position;
in vec2 ex_TexCoord;

out vec4 out_Color;
DECLARE_DEPTH()

uniform mat4 ViewMatrix;
uniform mat4 ShadowMatrix;
uniform sampler2DShadow ShadowTexture;
uniform sampler2D AlbedoTexture;
uniform bool HasAlbedoTexture;

const float ambient = 0.4;
const float diffuse = 0.8;

void main()
{
#if CAST_SHADOWS
	vec4 shadowPosition = ShadowMatrix * inverse(ViewMatrix) * vec4(ex_Position, 1);
	vec3 shadowCoord = (shadowPosition.xyz / shadowPosition.w);
	float shadow;
	if (0 < shadowCoord.x && shadowCoord.x < 1 &&
		0 < shadowCoord.y && shadowCoord.y < 1 &&
		0 < shadowCoord.z && shadowCoord.z < 1)
		shadow = texture(ShadowTexture, shadowCoord);
	else
		shadow = 1;
#else
	float shadow = 1;
#endif
	
	float light = ambient + ex_DiffuseLight * diffuse * shadow;
	vec4 color = HasAlbedoTexture ? texture(AlbedoTexture, ex_Color.xy) : vec4(ex_Color, 1);
	out_Color = vec4(color.rgb * light, color.a);
	
	WRITE_DEPTH();
}

// vi: ft=c
