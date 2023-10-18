/// vertex

in vec3 in_Position;
in vec3 in_Color;

out vec3 ex_Color;
out vec3 ex_Position;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;

void main()
{
	mat4 ModelViewMatrix = ViewMatrix * ModelMatrix;
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ModelViewMatrix;
	vec4 position = ModelViewMatrix * vec4(in_Position, 1.0);
	ex_Position = position.xyz / position.w;
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 1.0);
	
	ex_Color = in_Color;
}

/// fragment
#include "lib.glsl"

in vec3 ex_Color;
in vec3 ex_Position;

out vec4 out_Color;
DECLARE_DEPTH()

void main()
{
	out_Color = vec4(ex_Color, 1.0);
	
	WRITE_DEPTH();
}

// vi: ft=c
