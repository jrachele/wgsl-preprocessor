const std = @import("std");
const mecha = @import("mecha");

const testing = std.testing;

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const ShaderPreprocessor = struct {
    allocator: std.mem.Allocator,

    // Contains retrieved shader data from files, cached in memory
    shader_file_cache: std.StringHashMap([]const u8),

    // Fields for internal usage
    arena: std.heap.ArenaAllocator,
    visited_paths: std.StringHashMap(void),

    const Self = @This();
    const Megabytes: usize = 1024 * 1024;
    const MAX_FILE_READ_BYTES: usize = 8 * Megabytes;

    const Error = error{
        CyclicImport,
        Syntax,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .shader_file_cache = std.StringHashMap([]const u8).init(allocator),
            .visited_paths = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.shader_file_cache.deinit();
        self.visited_paths.deinit();
    }

    pub fn process(self: *Self, path: []const u8) ![]const u8 {
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const abs_path = try std.fs.realpath(path, &path_buffer);

        const file: std.fs.File = try std.fs.openFileAbsolute(abs_path, .{});
        defer file.close();

        // Mark the current path as visited to avoid infinite recursion if cyclically referenced
        try self.visited_paths.put(abs_path, {});

        const file_bytes = try file.readToEndAlloc(self.allocator, ShaderPreprocessor.MAX_FILE_READ_BYTES);
        defer self.allocator.free(file_bytes);

        var process_array = std.ArrayList(u8).init(self.allocator);
        defer process_array.deinit();

        var it = std.mem.splitScalar(u8, file_bytes, '\n');
        var i: i32 = 0;
        while (it.next()) |line| : (i += 1) {
            const import_path = self.getImportPath(line) catch {
                std.log.err("Syntax error!:\n{s} (line {d}): {s}\n", .{ abs_path, i + 1, line });
                return Error.Syntax;
            };

            // #import "path/to/shader.wgsl"
            if (import_path) |p| {
                // We are given ownership of the path slice from getImportPath, so we free it ourselves
                defer self.allocator.free(p);

                var import_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                var import_abs_path: []const u8 = undefined;

                if (std.fs.path.isAbsolute(p)) {
                    import_abs_path = try std.fs.realpath(p, &import_path_buffer);
                } else {
                    // If we were given a relative path, ensure we are resolving it relative to the shader itself, not where we are running this
                    const dirname = std.fs.path.dirname(abs_path).?;
                    const p2 = try std.fs.path.join(self.allocator, &[_][]const u8{ dirname, p });
                    defer self.allocator.free(p2);
                    import_abs_path = try std.fs.realpath(p2, &import_path_buffer);
                }

                if (std.mem.eql(u8, abs_path, import_abs_path) or self.visited_paths.contains(import_abs_path)) {
                    std.log.err("Cycle detected in preprocessor imports!\n{s} (line {d}): {s}\n", .{ abs_path, i + 1, line });
                    return Error.CyclicImport;
                }

                if (self.shader_file_cache.contains(import_abs_path)) {
                    try process_array.appendSlice(self.shader_file_cache.get(import_abs_path).?);
                    continue;
                }

                // Recursive call to evaluate other imports
                const import_file_bytes = try self.process(import_abs_path);
                defer self.allocator.free(import_file_bytes);

                try process_array.appendSlice(import_file_bytes);
                if (it.rest().len > 0) {
                    try process_array.append('\n');
                }
            } else {
                // Normal wgsl
                try process_array.appendSlice(line);
                if (it.rest().len > 0) {
                    try process_array.append('\n');
                }
            }
        }

        const shader_content = try process_array.toOwnedSlice();
        try self.shader_file_cache.put(abs_path, shader_content);

        return shader_content;
    }

    fn getImportPath(self: *Self, raw_line: []const u8) !?[]const u8 {
        // Only throw parser errors if the line is meant to be parsed, i.e. starts with #
        if (!std.mem.startsWith(u8, raw_line, "#")) {
            return null;
        }

        const import = comptime mecha.string("#import");
        const quote = comptime mecha.ascii.char('\"');
        const linebreak = comptime mecha.opt(mecha.ascii.char('\n'));
        const whitespace = comptime mecha.opt(mecha.many(mecha.ascii.whitespace, .{}));

        // Path
        const extension = comptime mecha.string(".wgsl");
        const path = comptime mecha.combine(.{
            mecha.many(mecha.combine(.{
                // ../
                mecha.opt(mecha.combine(.{
                    mecha.many(mecha.ascii.char('.'), .{ .collect = false }),
                    mecha.ascii.char('/'),
                })),
                // ___
                mecha.opt(mecha.many(mecha.ascii.char('_'), .{})),
                // somePath12
                mecha.many(mecha.ascii.alphanumeric, .{}),
                // /
                mecha.opt(mecha.ascii.char('/')),
            }), .{
                .collect = false,
                .max = 16,
            }),
            // restOfPath
            mecha.many(mecha.ascii.alphanumeric, .{ .collect = false }),
            // .wgsl
            extension,
        });

        const combined = comptime mecha.combine(.{
            import.discard(),
            whitespace.discard(),
            quote.discard(),
            path,
            quote.discard(),
            linebreak.discard(),
        });

        const result = try combined.parse(self.arena.allocator(), raw_line);

        var path_result = std.ArrayList(u8).init(self.allocator);
        inline for (result.value) |field| {
            try path_result.appendSlice(field);
        }

        return try path_result.toOwnedSlice();
    }
};

test "process success" {
    const allocator = std.testing.allocator;
    var preprocessor = ShaderPreprocessor.init(allocator);
    defer preprocessor.deinit();

    const result = try preprocessor.process("./test/shader.wgsl");
    defer allocator.free(result);

    const expected =
        \\// Comment from other_shader.wgsl
        \\
        \\var yup: bool = true;
        \\
        \\@group(0) @binding(0)
        \\var<storage, read> buf: array<u32>;
        \\
        \\@workgroups(8, 8, 1) @compute
        \\fn main() {
        \\  // Shader 1! 
        \\}
    ;

    try std.testing.expectEqualStrings(expected, result);

    // Tests that recursive imports work
    const depth_result = try preprocessor.process("./test/depth_shader.wgsl");
    defer allocator.free(depth_result);

    try std.testing.expectEqualStrings(expected, depth_result);
}

test "getImportPath success" {
    const allocator = std.testing.allocator;
    var preprocessor = ShaderPreprocessor.init(allocator);
    defer preprocessor.deinit();

    const imports = [_][]const u8{
        "#import\"shaders/test1.wgsl\"   \t",
        "#import \"shaders/test1.wgsl\"   \t",
        "#import \"./shaders/test1.wgsl\"   \t",
        "#import \"../shaders/test1.wgsl\"   \t",
        "#import \"../shaders/../test1.wgsl\"   \t",
    };

    const paths = [_][]const u8{
        "shaders/test1.wgsl",
        "shaders/test1.wgsl",
        "./shaders/test1.wgsl",
        "../shaders/test1.wgsl",
        "../shaders/../test1.wgsl",
    };

    for (imports, 0..) |value, i| {
        const result = try preprocessor.getImportPath(value);
        try std.testing.expect(result != null);
        errdefer allocator.free(result.?);
        try std.testing.expectEqualStrings(result.?, paths[i]);
        allocator.free(result.?);
    }
}

test "getImportPath fail" {
    const allocator = std.testing.allocator;
    var preprocessor = ShaderPreprocessor.init(allocator);
    defer preprocessor.deinit();

    const imports = [_][]const u8{
        "#import \"shaders/test1.glsl\"",
        "#import \"shaders//test1.wgsl\"",
        "#import \"____/test1.wgsl\"",
        "#import \"shaders/test1\"",
    };

    for (imports) |value| {
        _ = preprocessor.getImportPath(value) catch |err| {
            try std.testing.expect(err == mecha.Error.ParserFailed);
            return;
        };
        try std.testing.expect(false);
    }
}
