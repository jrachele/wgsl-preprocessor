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

    // Stack to ensure proper if-endif formation
    conditions: std.ArrayList(bool),

    const Self = @This();
    const Megabytes: usize = 1024 * 1024;
    const MAX_FILE_READ_BYTES: usize = 8 * Megabytes;

    const Error = error{
        InvalidCondition,
        InvalidConstant,
        InvalidPath,
        InvalidFile,
        InvalidImport,
        CyclicImport,
        CacheError,
        SyntaxError,
        AllocatorError,
        MismatchedIf,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .shader_file_cache = std.StringHashMap([]const u8).init(allocator),
            .visited_paths = std.StringHashMap(void).init(allocator),
            .conditions = std.ArrayList(bool).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.shader_file_cache.deinit();
        self.visited_paths.deinit();
        self.conditions.deinit();
    }

    // Processes the shader at the given path
    // Options can be given as such:
    // .{
    //  .conditions = .{
    //      .full_screen = true,
    //      .mouse_hidden = global.config.mouse_hidden,
    //  },
    //  .constants = .{
    //      .screen_width = 1280,
    //      .screen_height = 720
    //  }
    // }
    pub fn process(self: *Self, path: []const u8, options: anytype) Error![]const u8 {
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

            // Parse conditions first as later processing is contingent on conditions
            if (std.mem.startsWith(u8, trimmed_line, "#if")) {
                const cond_str = self.parseIf(trimmed_line) catch |err| {
                    logError(err, log_data);
                    return err;
                };
                defer self.allocator.free(cond_str);

                // Match conditions found in the shader with conditions passed through as options to this function
                var cond_valid = false;
                var cond = false;
                if (@hasField(@TypeOf(options), "conditions")) {
                    inline for (std.meta.fields(@TypeOf(options.conditions))) |field| {
                        if (std.mem.eql(u8, field.name, cond_str)) {
                            cond_valid = true;
                            cond = @field(options.conditions, field.name);
                        }
                    }
                }

                if (cond_valid == false) {
                    const err = Error.InvalidCondition;
                    logError(err, log_data);
                    return err;
                }

                self.conditions.append(cond) catch {
                    return Error.AllocatorError;
                };
                continue;
            } else if (std.mem.startsWith(u8, trimmed_line, "#else")) {
                if (self.conditions.popOrNull()) |cond| {
                    self.conditions.append(!cond) catch {
                        return Error.AllocatorError;
                    };
                } else {
                    const err = Error.MismatchedIf;
                    logError(err, log_data);
                    return err;
                }
                continue;
            } else if (std.mem.startsWith(u8, trimmed_line, "#endif")) {
                if (self.conditions.popOrNull() == null) {
                    const err = Error.MismatchedIf;
                    logError(err, log_data);
                    return err;
                }
                continue;
            }

            // If we are in an #if block, however nested, ensure we satisfy all conditions to
            // actually further process any lines
            var can_process = true;
            for (self.conditions.items) |cond| {
                can_process = cond and can_process;
            }

            if (!can_process) {
                continue;
            }

            if (std.mem.startsWith(u8, trimmed_line, "#import")) {
                const import_bytes = self.processImport(abs_path, trimmed_line, options) catch |err| {
                    logError(err, log_data);
                    return err;
                };
                defer self.allocator.free(import_bytes);
                process_array.appendSlice(import_bytes) catch {
                    return Error.AllocatorError;
                };
            } else {

                // Lastly, check if there is a constant #(foo) inlined somewhere
                // TODO: Allow multiple constants per line
                const pound_index = std.mem.indexOfScalar(u8, line, '#');
                if (pound_index) |pound_i| {
                    const constant_ident = self.parseConstant(line[pound_i..]) catch |err| {
                        logError(err, log_data);
                        return err;
                    };
                    defer self.allocator.free(constant_ident);

                    var const_valid = false;
                    // TODO: This seems a little fishy
                    var valueBuf: [128]u8 = undefined;
                    var value: []u8 = "";

                    if (@hasField(@TypeOf(options), "constants")) {
                        inline for (std.meta.fields(@TypeOf(options.constants))) |field| {
                            if (std.mem.eql(u8, field.name, constant_ident)) {
                                const_valid = true;
                                const val = @field(options.constants, field.name);
                                value = std.fmt.bufPrint(&valueBuf, "{any}", .{val}) catch {
                                    return Error.InvalidConstant;
                                };
                            }
                        }
                    }

                    if (const_valid == false) {
                        const err = Error.InvalidConstant;
                        logError(err, log_data);
                        return err;
                    }

                    // Process the line
                    var lineBuf: [128]u8 = undefined;
                    var newLine = std.fmt.bufPrint(&lineBuf, "{s}{s}{s}", .{ line[0..pound_i], value, line[pound_i + constant_ident.len + 3 ..] }) catch {
                        return Error.SyntaxError;
                    };

                    process_array.appendSlice(newLine) catch {
                        return Error.AllocatorError;
                    };
                } else {
                    process_array.appendSlice(line) catch {
                        return Error.AllocatorError;
                    };
                }
            }
            if (it.rest().len > 0) {
                process_array.append('\n') catch {
                    return Error.AllocatorError;
                };
            }
        }

        if (self.conditions.items.len != 0) {
            return Error.MismatchedIf;
        }

        const shader_content = process_array.toOwnedSlice() catch {
            return Error.AllocatorError;
        };
        self.shader_file_cache.put(abs_path, shader_content) catch {
            return Error.CacheError;
        };

        return shader_content;
    }

    fn processImport(self: *Self, abs_path: []const u8, line: []const u8, options: anytype) Error![]const u8 {
        const import_path = self.parseImportPath(line) catch {
            return Error.InvalidImport;
        };

        // #import "path/to/shader.wgsl"
        // We are given ownership of the path slice from parseImportPath, so we free it ourselves
        defer self.allocator.free(import_path);

        var import_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        var import_abs_path: []const u8 = undefined;

        if (std.fs.path.isAbsolute(import_path)) {
            import_abs_path = std.fs.realpath(import_path, &import_path_buffer) catch {
                return Error.InvalidImport;
            };
        } else {
            // If we were given a relative path, ensure we are resolving it relative to the shader itself, not where we are running this
            const dirname = std.fs.path.dirname(abs_path).?;
            const p2 = std.fs.path.join(self.allocator, &[_][]const u8{ dirname, import_path }) catch {
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
        const import_file_bytes = try self.process(import_abs_path, options);

        return import_file_bytes;
    }

    const LogData = struct {
        path: []const u8,
        line_number: u32,
        line_contents: []const u8,
    };

    fn logError(err: Error, log_data: LogData) void {
        switch (err) {
            Error.AllocatorError => {
                log("Error allocating memory!", log_data);
            },
            Error.CacheError => {
                log("Error retrieving shader from cache!", log_data);
            },
            Error.CyclicImport => {
                log("Cycle detected in imports!", log_data);
            },
            Error.InvalidCondition => {
                log("Invalid condition! (Ensure you have it defined in your process options)", log_data);
            },
            Error.InvalidConstant => {
                log("Invalid constant! (Ensure you have it defined in your process options)", log_data);
            },
            Error.InvalidImport => {
                log("Invalid import!", log_data);
            },
            Error.InvalidPath => {
                log("Invalid file path!", log_data);
            },
            Error.MismatchedIf => {
                log("Mismatched #if, #else, or #endif!", log_data);
            },
            Error.SyntaxError => {
                log("Syntax error!", log_data);
            },
            else => {
                log("Error occured during preprocessing!", log_data);
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

    //////////////////////////////////////////////////////////////////////
    // Parsers
    //////////////////////////////////////////////////////////////////////

    const linebreak = mecha.opt(mecha.ascii.char('\n'));
    const whitespace = mecha.opt(mecha.many(mecha.ascii.whitespace, .{}));

    // Extract the import path from an #import statement
    // e.g.
    // #import "path/to/foo.wgsl"
    //
    // This function will return "path/to/foo.wgsl"
    fn parseImportPath(self: *Self, raw_line: []const u8) ![]const u8 {
        const import = comptime mecha.string("#import");
        const quote = comptime mecha.ascii.char('\"');

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
                mechaParseIdent(),
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

    // Extract the if condition from an #if statement
    // e.g.
    // #if some_value
    // var foo = 50;
    // #endif
    //
    // This function will return "some_value"
    fn parseIf(self: *Self, raw_line: []const u8) Error![]const u8 {
        const if_statement = comptime mecha.string("#if");

        const condition = comptime mechaParseIdent();

        const combined = comptime mecha.combine(.{
            if_statement.discard(),
            whitespace.discard(),
            condition,
            whitespace.discard(),
            linebreak.discard(),
        });

        const result = combined.parse(self.arena.allocator(), raw_line) catch {
            return Error.SyntaxError;
        };

        return self.allocator.dupe(u8, result.value) catch {
            return Error.AllocatorError;
        };
    }

    // Extract the constant from an embedded constant in a line
    // e.g.
    // var a = #(some_constant)
    //
    // This function will return "some_constant"
    //
    // Note: It will only return the first constant found in the slice
    fn parseConstant(self: *Self, raw_line: []const u8) Error![]const u8 {
        const constant = comptime mecha.string("#(");
        const rightparen = comptime mecha.ascii.char(')');

        const combined = comptime mecha.combine(.{
            constant.discard(),
            mechaParseIdent(),
            rightparen.discard(),
        });

        const result = combined.parse(self.arena.allocator(), raw_line) catch {
            return Error.SyntaxError;
        };

        return self.allocator.dupe(u8, result.value) catch {
            return Error.AllocatorError;
        };
    }

    fn mechaParseIdent() mecha.Parser([]const u8) {
        const underscore_alphanum = comptime mecha.combine(.{
            mecha.opt(mecha.many(mecha.ascii.char('_'), .{ .collect = false })),
            // somePath12
            mecha.many(mecha.ascii.alphanumeric, .{
                .collect = false,
            }),
        });

        const ident = comptime mecha.many(underscore_alphanum, .{
            .collect = false,
            .max = 16,
        });

        return ident;
    }
};

//////////////////////////////////////////////////////////////////////
// Tests
//////////////////////////////////////////////////////////////////////

test "process import success" {
    const allocator = std.testing.allocator;
    var preprocessor = ShaderPreprocessor.init(allocator);
    defer preprocessor.deinit();

    const result = try preprocessor.process("./test/shader.wgsl", .{});
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
    const depth_result = try preprocessor.process("./test/depth_shader.wgsl", .{});
    defer allocator.free(depth_result);

    try std.testing.expectEqualStrings(expected, depth_result);
}

test "process conditional success" {
    const allocator = std.testing.allocator;
    var preprocessor = ShaderPreprocessor.init(allocator);
    defer preprocessor.deinit();

    const result = try preprocessor.process("./test/conditional.wgsl", .{
        .conditions = .{
            .test_condition = true,
        },
    });
    defer allocator.free(result);

    const expected =
        \\var a = 10;
        \\
    ;

    try std.testing.expectEqualStrings(expected, result);

    const result_false = try preprocessor.process("./test/conditional.wgsl", .{
        .conditions = .{
            .test_condition = false,
        },
    });
    defer allocator.free(result_false);

    const expected_false =
        \\var a = 5;
        \\
    ;

    try std.testing.expectEqualStrings(expected_false, result_false);
}

test "process constant success" {
    const allocator = std.testing.allocator;
    var preprocessor = ShaderPreprocessor.init(allocator);
    defer preprocessor.deinit();

    const result = try preprocessor.process("./test/constant.wgsl", .{
        .constants = .{
            .some_constant = 100,
        },
    });
    defer allocator.free(result);

    const expected =
        \\var a = 10;
        \\var b = 100;
    ;

    try std.testing.expectEqualStrings(expected, result);
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
        errdefer allocator.free(result);
        try std.testing.expectEqualStrings(result, paths[i]);
        allocator.free(result);
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
