/// vertex

in vec2 in_Position;
in vec4 in_Color;

out vec4 ex_Color;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;

void main()
{
	mat4 ModelViewMatrix = ViewMatrix * ModelMatrix;
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ModelViewMatrix;
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 0, 1.0);
	
	ex_Color = in_Color;
}

/// fragment

in vec4 ex_Color;

out vec4 out_Color;

void main()
{
	out_Color = ex_Color;
}

// vi: ft=c
