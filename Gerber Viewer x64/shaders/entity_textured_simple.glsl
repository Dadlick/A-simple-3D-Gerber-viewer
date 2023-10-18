/// vertex

in vec3 in_Position;
in vec3 in_Normal;
in vec3 in_Color;

out vec3 ex_Color;
out float ex_DiffuseLight;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;
uniform vec3 SunDirection;

void main()
{
	mat4 ModelViewMatrix = ViewMatrix * ModelMatrix;
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ModelViewMatrix;
	vec4 position = ModelViewMatrix * vec4(in_Position, 1.0);
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 1.0);
	
	vec3 N = (ModelMatrix * vec4(in_Normal, 0.0)).xyz;
	vec3 L = SunDirection;
	
	float nDotL = max(dot(N, L), 0);
	
	ex_Color = in_Color;
	ex_DiffuseLight = nDotL;
}

/// fragment

in vec3 ex_Color;
in float ex_DiffuseLight;

out vec4 out_Color;

uniform sampler2D ColorTexture;
uniform bool HasColorTexture;

const float ambient = 0.4;
const float diffuse = 0.8;

void main()
{
	float light = ambient + ex_DiffuseLight * diffuse;
	vec4 color = HasColorTexture ? texture(ColorTexture, ex_Color.xy) : vec4(ex_Color, 1);
	out_Color = vec4(color.rgb * light, color.a);
}

// vi: ft=c
