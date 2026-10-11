#include <metal_stdlib>
using namespace metal;

struct ToothpasteShaderUniforms {
    float4 drawableSize;
    float4 textRect;
    float4 animation;
    float4 reserved;
    float4 transform;
    float4 alignedGridBounds;
    float4 pointGridBounds;
    float4 pointGridZBounds;
    float4 keyLight;
    float4 gridSize;
    float4 pathLengthUnit;
    float4 zoomScale;
};

struct ToothpasteShaderSegment {
    float4 start;
    float4 end;
    float4 rangeOfT;
    float4 startTangent;
    float4 endTangent;
    float4 extremity;
};

vertex float4 depthVertex(const device float2 *vertices [[buffer(0)]], uint vertexIndex [[vertex_id]]) {
    return float4(vertices[vertexIndex], 0, 1);
}

fragment float4 toothpasteBackgroundFragment(float4 position [[position]],
                                      constant float4 &size [[buffer(0)]],
                                      texture2d<float> background [[texture(0)]]) {
    constexpr sampler sampleTexture(filter::linear, address::clamp_to_edge);
    float2 coordinates = (position.xy / size.xy - 0.5) * size.zw + 0.5;
    return background.sample(sampleTexture, coordinates);
}

fragment float4 depthFragment(float4 position [[position]],
                              constant ToothpasteShaderUniforms &uniforms [[buffer(0)]],
                              const device ToothpasteShaderSegment *segments [[buffer(1)]],
                              const device int *grid [[buffer(2)]]) {
    float height = uniforms.drawableSize.y;
    float scale = uniforms.transform.x;
    float2 point = float2(position.x * scale + uniforms.transform.z,
                          (height - position.y) * scale + uniforms.transform.w);
    int columns = grid[0];
    int rows = grid[1];
    float cellSize = uniforms.gridSize.x;
    int column = clamp(int(floor((point.x - uniforms.alignedGridBounds.x) / cellSize)), 0, columns - 1);
    int row = clamp(int(floor((point.y - uniforms.alignedGridBounds.y) / cellSize)), 0, rows - 1);
    int offset = grid[2 + row * columns + column];

    float upperZ = -INFINITY;
    float upperCoverage = 0;
    float lowerZ = -INFINITY;
    float lowerCoverage = 0;
    for (int candidateIndex = 0; candidateIndex < grid[offset]; ++candidateIndex) {
        int index = grid[offset + candidateIndex + 1];
        float4 start = segments[index].start;
        float4 end = segments[index].end;
        float2 time = segments[index].rangeOfT.xy;
        float visible = clamp((uniforms.animation.y - time.x) / max(time.y - time.x, 0.000001), 0.0, 1.0);
        if (visible <= 0) continue;
        end = mix(start, end, visible);
        float2 delta = end.xy - start.xy;
        float fraction = clamp(dot(point - start.xy, delta) / max(dot(delta, delta), 0.000001), 0.0, 1.0);
        float4 sample = mix(start, end, fraction);
        float coverage = 1 - smoothstep(sample.w - scale, sample.w + scale,
                                         distance(point, sample.xy));
        float depth = mix(segments[index].rangeOfT.z, segments[index].rangeOfT.w, fraction * visible);
        if (coverage <= 0) continue;
        if (depth > upperZ) {
            lowerZ = upperZ;
            lowerCoverage = upperCoverage;
            upperZ = depth;
            upperCoverage = coverage;
        } else if (depth == upperZ) {
            upperCoverage = max(upperCoverage, coverage);
        } else if (depth > lowerZ) {
            lowerZ = depth;
            lowerCoverage = coverage;
        } else if (depth == lowerZ) {
            lowerCoverage = max(lowerCoverage, coverage);
        }
    }
    if (upperCoverage == 0) return float4(0);
    float low = uniforms.animation.z;
    float high = uniforms.animation.w;
    float upperDepth = high > low ? clamp((upperZ - low) / (high - low), 0.0, 1.0) : 0.5;
    float3 upperColor = mix(float3(0.3, 0.55, 1.0), float3(0.95, 0.95, 1.0), upperDepth);
    if (lowerCoverage == 0) return float4(upperColor, upperCoverage);
    // shortcut: Keep two depth layers; a third crossing layer is discarded.
    float lowerDepth = high > low ? clamp((lowerZ - low) / (high - low), 0.0, 1.0) : 0.5;
    float3 lowerColor = mix(float3(0.3, 0.55, 1.0), float3(0.95, 0.95, 1.0), lowerDepth);
    float lowerVisible = lowerCoverage * (1 - upperCoverage);
    float alpha = upperCoverage + lowerVisible;
    return float4((upperColor * upperCoverage + lowerColor * lowerVisible) / alpha, alpha);
}
