/// vertex

in vec3 in_Position;

out vec3 v_Position;

uniform mat4 ModelMatrix;
uniform mat4 ViewMatrix;
uniform mat4 ProjectionMatrix;

void main()
{
	mat4 ModelViewMatrix = ViewMatrix * ModelMatrix;
	mat4 ModelViewProjectionMatrix = ProjectionMatrix * ModelViewMatrix;
	vec4 position = ModelViewMatrix * vec4(in_Position, 1.0);
	v_Position = position.xyz / position.w;
	gl_Position = ModelViewProjectionMatrix * vec4(in_Position, 1.0);
}

/// geometry

layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

in vec3 v_Position[3];

out vec3 ex_Position;
out vec3 g_TriDistance;

void main()
{
	g_TriDistance = vec3(1, 0, 0);
	ex_Position = v_Position[0];
	gl_Position = gl_in[0].gl_Position; EmitVertex();
	
	g_TriDistance = vec3(0, 1, 0);
	ex_Position = v_Position[1];
	gl_Position = gl_in[1].gl_Position; EmitVertex();
	
	g_TriDistance = vec3(0, 0, 1);
	ex_Position = v_Position[2];
	gl_Position = gl_in[2].gl_Position; EmitVertex();
	
	EndPrimitive();
}

/// fragment
#include "lib.glsl"

in vec3 ex_Position;
in vec3 g_TriDistance;

out vec4 out_Color;
DECLARE_DEPTH()

uniform vec3 Color;

float amplify(float d, float scale, float offset)
{
	d = scale * d + offset;
	d = clamp(d, 0, 1);
	d = 1 - exp2(-2*d*d);
	return d;
}

void main()
{
	float d = min(g_TriDistance.x, min(g_TriDistance.y, g_TriDistance.z));
	float f = amplify(d, 40, -0.5);
	out_Color = vec4(Color, 1.0) * f + vec4(1,1,1,1) * (1-f);
	
	WRITE_DEPTH();
}

// vi: ft=c
