/// vertex

in vec2 in_Position;
in vec2 in_TexCoord;

out vec2 ex_TexCoord;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;

void main()
{
	mat4 ModelViewMatrix = ViewMatrix * ModelMatrix;
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ModelViewMatrix;
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 0, 1.0);
	
	ex_TexCoord = in_TexCoord;
}

/// fragment

in vec2 ex_TexCoord;

out vec4 out_Color;

uniform sampler2D Texture;
uniform vec3 Color;

void main()
{
	out_Color = texture(Texture, ex_TexCoord) * vec4(Color, 1);
}

// vi: ft=c
