/// vertex

in vec2 in_Position;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;

void main()
{
	mat4 ModelViewMatrix = ViewMatrix * ModelMatrix;
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ModelViewMatrix;
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 0, 1.0);
}

/// fragment

out vec4 out_Color;

uniform vec4 Color;

void main()
{
	out_Color = Color;
}

// vi: ft=c
