#import "other_shader.wgsl"

@group(0) @binding(0)
var<storage, read> buf: array<u32>;

@workgroups(8, 8, 1) @compute
fn main() {
  // Shader 1! 
}
