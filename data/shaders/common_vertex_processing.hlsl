/*
Copyright(c) 2016-2025 Panos Karabelas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions :

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

//= INCLUDES =========
#include "common.hlsl"
//====================

// - the functions are shared between depth_prepass.hlsl, g_buffer.hlsl and depth_light.hlsl
// - this is because the calculations have to be exactly the same and therefore produce identical values over time (motion vectors) and space (depth pre-pass vs g-buffer)

// vertex buffer input
struct Vertex_PosUvNorTan
{
    float4 position           : POSITION0;
    float2 uv                 : TEXCOORD0;
    float3 normal             : NORMAL0;
    float3 tangent            : TANGENT0;
    matrix instance_transform : INSTANCE_TRANSFORM0;
};

// vertex buffer output
struct gbuffer_vertex
{
    float3 position               : POS_WORLD;
    float3 position_previous      : POS_WORLD_PREVIOUS;
    float4 position_clip          : SV_POSITION;
    float4 position_clip_current  : POS_CLIP;
    float4 position_clip_previous : POS_CLIP_PREVIOUS;
    float3 normal                 : NORMAL_WORLD;
    float3 tangent                : TANGENT_WORLD;
    float2 uv                     : TEXCOORD;
    float3 color                  : COLOR_;
    uint instance_id              : INSTANCE_ID;
    matrix transform              : TRANSFORM;
    matrix transform_previous     : TRANSFORM_PREVIOUS;
};

static float hash(float n)
{
    return frac(sin(n) * 43758.5453f);
}

static float perlin_noise(float x)
{
    float i = floor(x);
    float f = frac(x);
    f = f * f * (3.0 - 2.0 * f);

    return lerp(hash(i), hash(i + 1.0), f);
}

static float3 extract_position(matrix transform)
{
    return float3(transform._31, transform._32, transform._33);
}

static float3 rotate_x(float angle, float3 v)
{
    float c = cos(angle);
    float s = sin(angle);

    // standard x-axis rotation
    return float3(
        v.x,
        c * v.y - s * v.z,
        s * v.y + c * v.z
    );
}

static float3 rotate_y(float angle, float3 v)
{
    float c = cos(angle);
    float s = sin(angle);

    // apply standard y-axis rotation
    return float3(
        c * v.x + s * v.z,
        v.y,
        -s * v.x + c * v.z
    );
}

struct vertex_processing
{
    struct vegetation
    {
        static float3 apply_wind(uint instance_id, float3 position_vertex, float height_percent, float3 wind, float time)
        {
            const float sway_extent       = 0.2f;   // maximum sway amplitude
            const float sway_speed        = 1.0f;   // sway frequency
            const float noise_scale       = 0.1f;   // scale of low-frequency noise
            const float flutter_intensity = 0.025f; // intensity of fluttering
        
            // normalize wind direction and calculate magnitude
            float3 wind_direction = normalize(wind);
            float wind_magnitude  = length(wind);
        
            // base sinusoidal sway
            float phase_offset = float(instance_id) * 0.25f * PI; // unique phase per instance
            float base_wave    = sin(time * sway_speed + phase_offset);
        
            // add low-frequency perlin noise for smooth directional variation
            float low_freq_noise           = perlin_noise(time * noise_scale + instance_id * 0.1f);
            float directional_variation    = lerp(-0.5f, 0.5f, low_freq_noise); // smooth variation
            float3 adjusted_wind_direction = wind_direction + directional_variation;
        
            // add high-frequency flutter (localized and rapid movement)
            float flutter = sin(position_vertex.x * 10.0f + time * 15.0f) * flutter_intensity;
        
            // combine all factors for sway
            float combined_wave = base_wave + flutter;
            float3 sway_offset  = adjusted_wind_direction * combined_wave * sway_extent * height_percent * wind_magnitude;
        
            // apply the calculated sway to the vertex
            position_vertex += sway_offset;
        
            return position_vertex;
        }
        
        static float3 apply_player_bend(float3 position_vertex, float height_percent)
        {
            // calculate horizontal distance to player
            float distance = length(float2(position_vertex.x - buffer_frame.camera_position.x, position_vertex.z - buffer_frame.camera_position.z));
        
            // determine bending strength (inverse square law)
            float bending_strength = saturate(1.0f / (distance * distance + 1.0f));
        
            // direction away from player
            float2 direction_away_from_player = normalize(position_vertex.xz - buffer_frame.camera_position.xz);
        
            // apply rotational bending
            float3 bending_offset = float3(direction_away_from_player * bending_strength * height_percent, bending_strength * height_percent * 0.5f);
        
            // adjust position
            position_vertex.xz += bending_offset.xz * 0.5f; // horizontal effect
            float proposed_y_position = position_vertex.y + bending_offset.y * 1.0f; // vertical effect

            return position_vertex;
        }
    };
    
    struct water
    {
        static float3 apply_wave(float3 position_vertex, float time)
        {
            static const float base_wave_height    = 0.2f;
            static const float base_wave_frequency = 20.0f;
            static const float base_wave_speed     = 0.3f;

            // interleave 4 waves to have a more complex wave pattern
            float3 offset = 0.0f;
            for (int i = 0; i < 4; i++)
            {
                // modulate base wave parameters based on index
                float wave_height    = base_wave_height * (0.75f + i * 0.1f);
                float wave_frequency = base_wave_frequency * (0.9f + i * 0.05f);
                float wave_speed     = base_wave_speed * (0.9f + i * 0.05f);
    
                // dynamically calculate wave direction based on index
                float angle           = 2.0f * 3.14159f * i / 4.0f;
                float2 wave_direction = float2(cos(angle), sin(angle));
    
                // gerstner wave equation
                float k = 2 * 3.14159 / wave_frequency;
                float w = sqrt(9.8f / k) * wave_speed;
    
                // phase and amplitude
                float phase = dot(wave_direction, position_vertex.xz) * k + time * w;
                float c     = cos(phase);
                float s     = sin(phase);
    
                // calculate new position for this wave and add to the offset
                offset.x += wave_height * wave_direction.x * c;
                offset.z += wave_height * wave_direction.y * c;
                offset.y += wave_height * s;
            }
    
            position_vertex.xz += offset.xz;
            position_vertex.y += offset.y;
    
            return position_vertex;
        }

        static float3 apply_ripple(float3 position_vertex, float time)
        {
            static const float ripple_speed                = 0.25f;
            static const float ripple_max_height           = 0.2f;
            static const float ripple_frequency            = 5.0f;
            static const float ripple_decay_rate           = 0.1f;
            static const float ripple_decay_after_movement = 2.0f; // time for ripples to decay after movement stops

            // calculate time since the player last moved
            float time_since_last_movement = time - buffer_frame.camera_last_movement_time;

            // check if the camera (player) is near the sea level (0.0f)
            if (abs(buffer_frame.camera_position.y) < 4.0f)
            {
                float distance = length(position_vertex.xz - buffer_frame.camera_position.xz);
                
                // the ripple phase should consider the distance from the player
                float ripple_phase = ripple_frequency * (time * ripple_speed - distance);

                // adjust the ripple height based on time since last movement
                float decay_factor  = max(1.0f - (time_since_last_movement / ripple_decay_after_movement), 0.0f);
                float ripple_height = ripple_max_height * sin(ripple_phase) * exp(-ripple_decay_rate * distance) * decay_factor;

                position_vertex.y += ripple_height;
            }

            return position_vertex;
        }
    };

    static float3 ambient_animation(Surface surface, float3 position_vertex, float4x4 transform, float height_percent, uint instance_id, float time_offset = 0.0f)
    {
        float time  = (float)buffer_frame.time + time_offset;
        float3 wind = buffer_frame.wind;
        
        if (surface.vertex_animate_wind()) // don't apply wind to grass until we fix it
        {
            position_vertex = vegetation::apply_wind(instance_id, position_vertex, height_percent, wind, time);
            position_vertex = vegetation::apply_player_bend(position_vertex, height_percent);
        }
    
        if (surface.vertex_animate_water())
        {
            position_vertex = water::apply_wave(position_vertex, time);
            position_vertex = water::apply_ripple(position_vertex, time);
        }
    
        return position_vertex;
    }
};

gbuffer_vertex transform_to_world_space(Vertex_PosUvNorTan input, uint instance_id, matrix transform)
{
    MaterialParameters material = GetMaterial();
    Surface surface;
    surface.flags = material.flags;

    // start building the vertex
    gbuffer_vertex vertex;
    vertex.uv    = float2(input.uv.x * material.tiling.x + material.offset.x, input.uv.y * material.tiling.y + material.offset.y);
    vertex.color = 1.0f;

    // compute width and height percent, they represent the position of the vertex relative to the grass blade
    float3 position_transform = extract_position(transform); // bottom-left of the grass blade
    float width_percent       = (input.position.xyz.x) / GetMaterial().local_width;
    float height_percent      = (input.position.xyz.y - position_transform.x) / GetMaterial().local_height;

    // hacky way to detect grass blade and enchance it with certain modifications in local space
    if (surface.is_grass_blade())
    {
        // give it a nice color gradient
        float3 color_base = float3(0.05f, 0.2f, 0.01f); // darker green
        float3 color_tip  = float3(0.5f, 0.5f, 0.1f);   // yellowish
        vertex.color      = lerp(color_base, color_tip, smoothstep(0, 1, height_percent * 0.5f));

        // replace flat normals with curved ones
        const float rotation        = 60.0f * DEG_TO_RAD;
        float3 rotated_normal_left  = rotate_y(rotation, input.normal);
        float3 rotated_normal_right = rotate_y(-rotation, input.normal);
        input.normal                = normalize(lerp(rotated_normal_left, rotated_normal_right, width_percent));

        // bend the grass blade due to gravity
        float random_lean  = perlin_noise(instance_id * 0.1f) * 0.5f;
        float curve_amount = random_lean * height_percent;
        input.position.xyz = rotate_x(curve_amount,  input.position.xyz);
    }

    // compute the final world transform
    bool is_instanced         = instance_id != 0; // not ideal as you can have instancing with instance_id = 0, however it's very performant branching due to predictability
    matrix transform_instance = is_instanced ? input.instance_transform : matrix_identity;
    transform                 = mul(transform, transform_instance);
    // clip the last row as it has encoded data in the first two elements
    matrix full              = pass_get_transform_previous();
    matrix<float, 3, 3> temp = (float3x3)full;
    // manually construct a matrix that can be multiplied with another matrix
    matrix transform_previous = matrix(
        temp._m00, temp._m01, temp._m02, 0.0f,
        temp._m10, temp._m11, temp._m12, 0.0f,
        temp._m20, temp._m21, temp._m22, 0.0f,
        0.0f,      0.0f,      0.0f,      1.0f
    );
    transform_previous = is_instanced ? mul(transform_previous, transform_instance) : full;

    // transform to world space
    vertex.position          = mul(input.position, transform).xyz;
    vertex.position_previous = mul(input.position, transform_previous).xyz;
    vertex.normal            = normalize(mul(input.normal, (float3x3)transform));
    vertex.tangent           = normalize(mul(input.tangent, (float3x3)transform));

    // save some things into the vertex
    vertex.instance_id        = instance_id;
    vertex.transform          = transform;
    vertex.transform_previous = transform_previous;

    // vertex processing
    vertex.position          = vertex_processing::ambient_animation(surface, vertex.position, transform, height_percent, instance_id);
    vertex.position_previous = vertex_processing::ambient_animation(surface, vertex.position_previous, transform_previous, height_percent, instance_id, -buffer_frame.delta_time);

    return vertex;
}

gbuffer_vertex transform_to_clip_space(gbuffer_vertex vertex)
{
    vertex.position_clip          = mul(float4(vertex.position, 1.0f), pass_is_transparent() ? buffer_frame.view_projection_unjittered : buffer_frame.view_projection);
    vertex.position_clip_current  = vertex.position_clip;
    vertex.position_clip_previous = mul(float4(vertex.position_previous, 1.0f), pass_is_transparent() ? buffer_frame.view_projection_previous_unjittered : buffer_frame.view_projection_previous);

    return vertex;
}

// tessellation

#define MAX_POINTS 3
#define MAX_TESS_FACTOR 64
#define TESS_END_DISTANCE 50.0f

struct HsConstantDataOutput
{
    float edges[3] : SV_TessFactor;
    float inside   : SV_InsideTessFactor;
};

HsConstantDataOutput patch_constant_function(InputPatch<gbuffer_vertex, MAX_POINTS> input_patch)
{
    HsConstantDataOutput output;
    float subdivisions = 1.0f;

    // calculate camera to the patch center vector
    float3 patch_center    = (input_patch[0].position + input_patch[1].position + input_patch[2].position) / 3.0f;
    float3 camera_to_patch = patch_center - buffer_frame.camera_position;

    // determine face visibility
    float visibility = 0.0f;
    {
        // calculate the normal of the patch
        float3 tangent1    = input_patch[1].position - input_patch[0].position;
        float3 tangent2    = input_patch[2].position - input_patch[0].position;
        float3 face_normal = cross(tangent1, tangent2);

        // check if the patch is back-facing
        visibility = dot(normalize(face_normal), normalize(camera_to_patch));
    }

    if (visibility > 0) // no tessellation
    {
        subdivisions = 1.0f;
    }
    else // distance based tessellation
    {
        float distance_squared    = dot(camera_to_patch, camera_to_patch);
        float normalized_distance = min(distance_squared / (TESS_END_DISTANCE * TESS_END_DISTANCE), 1.0f);
        float drop_off_factor     = pow(2, -normalized_distance * 10);
        subdivisions              = MAX_TESS_FACTOR * drop_off_factor;
        subdivisions              = max(subdivisions, 1.0f);
    }

    // set uniform tessellation across all edges and inside
    output.edges[0] = subdivisions;
    output.edges[1] = subdivisions;
    output.edges[2] = subdivisions;
    output.inside   = subdivisions;

    return output;
}

[domain("tri")]
[partitioning("fractional_odd")]
[outputtopology("triangle_cw")]
[patchconstantfunc("patch_constant_function")]
[outputcontrolpoints(MAX_POINTS)]
[maxtessfactor(MAX_TESS_FACTOR)]
gbuffer_vertex main_hs(InputPatch<gbuffer_vertex, MAX_POINTS> input_patch, uint cp_id : SV_OutputControlPointID)
{
    return input_patch[cp_id];
}

[domain("tri")]
gbuffer_vertex main_ds(HsConstantDataOutput input, float3 bary_coords : SV_DomainLocation, const OutputPatch<gbuffer_vertex, 3> patch)
{
    gbuffer_vertex vertex;

    // interpolate
    {
        vertex.position          = patch[0].position          * bary_coords.x + patch[1].position          * bary_coords.y + patch[2].position          * bary_coords.z;
        vertex.position_previous = patch[0].position_previous * bary_coords.x + patch[1].position_previous * bary_coords.y + patch[2].position_previous * bary_coords.z;
        
        vertex.normal            = normalize(patch[0].normal  * bary_coords.x + patch[1].normal  * bary_coords.y + patch[2].normal * bary_coords.z);
        vertex.tangent           = normalize(patch[0].tangent * bary_coords.x + patch[1].tangent * bary_coords.y + patch[2].tangent  * bary_coords.z);
        
        vertex.uv                = patch[0].uv * bary_coords.x + patch[1].uv * bary_coords.y + patch[2].uv * bary_coords.z;
    }

    // displace
    MaterialParameters material = GetMaterial(); Surface surface; surface.flags = material.flags;
    bool tessellated  = input.edges[0] > 1.0f || input.edges[1] > 1.0f || input.edges[2] > 1.0f || input.inside > 1.0f;
    if (surface.has_texture_height() && tessellated)
    {
        float height              = 1.0f - GET_TEXTURE(material_texture_index_packed).SampleLevel(GET_SAMPLER(sampler_anisotropic_wrap), vertex.uv, 0.0f).a;
        float strength            = material.height * 0.1f;
        float3 tangent_1          = patch[1].position - patch[0].position;
        float3 tangent_2          = patch[2].position - patch[0].position;
        float3 normal_stable      = cross(tangent_1, tangent_2);
        float3 displacement       = -normal_stable * strength * height;
        vertex.position          += displacement;
        vertex.position_previous += displacement;
    }

    return transform_to_clip_space(vertex);
}
