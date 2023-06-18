# WGSL Preprocessor

Does what it says on the tin. Written in Zig.

Inspired by Bevy's preprocessor.

## Features
### Import other files using the `#import` directive

*shader.wgsl*:

```wgsl 
#import "other_shader.wgsl"

var b = 10;
```

*other_shader.wgsl*:

```wgsl
var a = 5;
```

*Result*:

```wgsl 
var a = 5;

var b = 10;
```

### `#if` directives with conditions at shader compile time

```zig
// ... somewhere in your Zig code
const processed_wgsl = ShaderPreprocessor.process("conditional.wgsl", .{
    .conditions = .{
        .full_screen = global.config.full_screen,
        .mouse_captured = false,
        .foo = true,
    }
});
```

*conditional.wgsl*:

```wgsl
#if full_screen
var screen_dims = vec2<u32>(1920, 1080);
#else
var screen_dims = vec2<u32>(1280, 720);
#endif

@compute @workgroup_size(8, 8, 1)
fn main() {
    #if mouse_captured
    // Do something
    #endif

    #if foo
    // Do something else
    #endif 
}
```

### Constants to inject into the shader at compile time using `#(constant_ident)`
```zig
// ... somewhere in your Zig code
const processed_wgsl = ShaderPreprocessor.process("constants.wgsl", .{
    .constants = {
        .workgroup_x = app.config.workgroup_size,
        .workgroup_y = app.config.workgroup_size, 
    }
});
```

*constants.wgsl*:

```wgsl
@compute @workgroup_size(#(workgroup_x), #(workgroup_y), 1)
fn main() {
}
```

## Dependencies
- Mecha - parser combinator library
