/// vertex

in vec3 in_Position;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;

void main()
{
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ViewMatrix * ModelMatrix;
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 1.0);
}

/// fragment

void main()
{
}

// vi: ft=c
