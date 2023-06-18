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
        InvalidPath,
        InvalidFile,
        InvalidImport,
        CyclicImport,
        CacheError,
        SyntaxError,
        AllocatorError,
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

    pub fn process(self: *Self, path: []const u8) Error![]const u8 {
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const abs_path = std.fs.realpath(path, &path_buffer) catch {
            return Error.InvalidPath;
        };

        const file: std.fs.File = std.fs.openFileAbsolute(abs_path, .{}) catch {
            return Error.InvalidFile;
        };
        defer file.close();

        // Mark the current path as visited to avoid infinite recursion if cyclically referenced
        self.visited_paths.put(abs_path, {}) catch {
            return Error.AllocatorError;
        };

        const file_bytes = file.readToEndAlloc(self.allocator, ShaderPreprocessor.MAX_FILE_READ_BYTES) catch {
            return Error.AllocatorError;
        };
        defer self.allocator.free(file_bytes);

        var process_array = std.ArrayList(u8).init(self.allocator);
        defer process_array.deinit();

        var it = std.mem.splitScalar(u8, file_bytes, '\n');
        var i: u32 = 0;
        while (it.next()) |line| : (i += 1) {
            // Only throw parser errors if the line is meant to be parsed, i.e. starts with #
            const trimmed_line = std.mem.trim(u8, line, " \t");
            const log_data = LogData{
                .path = abs_path,
                .line_number = i + 1,
                .line_contents = line,
            };

            if (std.mem.startsWith(u8, trimmed_line, "#import")) {
                const import_bytes = self.processImport(abs_path, trimmed_line) catch |err| {
                    logError(err, log_data);
                    return err;
                };
                defer self.allocator.free(import_bytes);
                process_array.appendSlice(import_bytes) catch {
                    return Error.AllocatorError;
                };
            } else {
                // TODO: Add more macros
                // Normal wgsl
                process_array.appendSlice(line) catch {
                    return Error.AllocatorError;
                };
            }
            if (it.rest().len > 0) {
                process_array.append('\n') catch {
                    return Error.AllocatorError;
                };
            }
        }

        const shader_content = process_array.toOwnedSlice() catch {
            return Error.AllocatorError;
        };
        self.shader_file_cache.put(abs_path, shader_content) catch {
            return Error.CacheError;
        };

        return shader_content;
    }

    const LogData = struct {
        path: []const u8,
        line_number: u32,
        line_contents: []const u8,
    };

    fn logError(err: Error, log_data: LogData) void {
        switch (err) {
            Error.InvalidImport => {
                log("Invalid import!", log_data);
            },
            Error.CyclicImport => {
                log("Cycle detected in imports!", log_data);
            },
            Error.SyntaxError => {
                log("Syntax error!", log_data);
            },
            else => {
                log("Error occured during import!", log_data);
            },
        }
    }

    fn log(description: []const u8, log_data: LogData) void {
        std.log.err("{s}\n{s} (line {d}): {s}\n", .{
            description,
            log_data.path,
            log_data.line_number,
            log_data.line_contents,
        });
    }

    fn processImport(self: *Self, abs_path: []const u8, line: []const u8) ![]const u8 {
        const import_path = self.parseImportPath(line) catch {
            return Error.InvalidImport;
        };

        // #import "path/to/shader.wgsl"
        if (import_path) |p| {
            // We are given ownership of the path slice from parseImportPath, so we free it ourselves
            defer self.allocator.free(p);

            var import_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            var import_abs_path: []const u8 = undefined;

            if (std.fs.path.isAbsolute(p)) {
                import_abs_path = std.fs.realpath(p, &import_path_buffer) catch {
                    return Error.InvalidImport;
                };
            } else {
                // If we were given a relative path, ensure we are resolving it relative to the shader itself, not where we are running this
                const dirname = std.fs.path.dirname(abs_path).?;
                const p2 = std.fs.path.join(self.allocator, &[_][]const u8{ dirname, p }) catch {
                    return Error.InvalidImport;
                };
                defer self.allocator.free(p2);
                import_abs_path = std.fs.realpath(p2, &import_path_buffer) catch {
                    return Error.InvalidImport;
                };
            }

            if (std.mem.eql(u8, abs_path, import_abs_path) or self.visited_paths.contains(import_abs_path)) {
                return Error.CyclicImport;
            }

            if (self.shader_file_cache.contains(import_abs_path)) {
                return self.shader_file_cache.get(import_abs_path).?;
            }

            // Recursive call to evaluate other imports
            const import_file_bytes = try self.process(import_abs_path);

            return import_file_bytes;
        } else {
            return Error.SyntaxError;
        }
    }

    fn parseImportPath(self: *Self, raw_line: []const u8) !?[]const u8 {
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

test "parseImportPath success" {
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
        const result = try preprocessor.parseImportPath(value);
        try std.testing.expect(result != null);
        errdefer allocator.free(result.?);
        try std.testing.expectEqualStrings(result.?, paths[i]);
        allocator.free(result.?);
    }
}

test "parseImportPath fail" {
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
        _ = preprocessor.parseImportPath(value) catch |err| {
            try std.testing.expect(err == mecha.Error.ParserFailed);
            return;
        };
        try std.testing.expect(false);
    }
}
