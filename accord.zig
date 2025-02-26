const std = @import("std");
const assert = std.debug.assert;

const StringList = std.ArrayListUnmanaged([]const u8);

fn compileError(comptime fmt: []const u8, comptime args: anytype) noreturn {
    @compileError(std.fmt.comptimePrint(fmt, args));
}

const StructField = std.builtin.Type.StructField;
pub fn MergeStructs(comptime types: []const type) type {
    var fields: []const StructField = &.{};
    for (types) |T| {
        outer: for (@typeInfo(T).@"struct".fields) |t_field| {
            for (fields) |result_field| {
                if (std.mem.eql(u8, result_field.name, t_field.name)) {
                    if (result_field.type != t_field.type) {
                        compileError(
                            "Different types for parsing option '{s}' ({s} and {s})",
                            .{ t_field.name, @typeName(result_field.type), @typeName(t_field.type) },
                        );
                    }
                    continue :outer;
                }
            }
            fields = fields ++ &[1]StructField{t_field};
        }
    }
    return @Type(std.builtin.Type{ .@"struct" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn isInterface(comptime T: type) bool {
    if (@hasDecl(T, "accordParse")) {
        const parse_info = @typeInfo(@TypeOf(@field(T, "accordParse")));
        comptime assert(parse_info == .@"fn");
        const ReturnType = parse_info.@"fn".return_type orelse unreachable;
        comptime assert(ReturnType != void);
        const return_type_info = @typeInfo(ReturnType);
        if (return_type_info == .error_union) {
            comptime assert(return_type_info.error_union.payload != void);
        }
        return true;
    }
    return false;
}

pub fn interfaceIsFlag(comptime T: type) bool {
    comptime assert(isInterface(T));
    const fn_info = @typeInfo(@TypeOf(@field(T, "accordParse"))).@"fn";
    return fn_info.params.len == 1 and fn_info.params[0].type != []const u8;
}

pub fn InterfaceSettings(comptime T: type) type {
    if (@hasDecl(T, "AccordParseSettings")) {
        return T.AccordParseSettings;
    } else {
        return struct {};
    }
}

fn FinalInterfaceSettings(comptime T: type) type {
    return MergeStructs(&.{
        struct { default_value: InterfaceValueType(T) = undefined },
        InterfaceSettings(T),
    });
}

pub fn InterfaceValueType(comptime T: type) type {
    comptime assert(isInterface(T));

    const parse_info = @typeInfo(@TypeOf(@field(T, "accordParse")));
    const ResultType = parse_info.@"fn".return_type orelse unreachable;
    const result_type_info = @typeInfo(ResultType);
    return if (result_type_info == .error_union)
        result_type_info.error_union.payload
    else
        ResultType;
}

pub fn GetInterface(comptime T: type) type {
    switch (T) {
        []const u8 => return StringInterface,
        bool => return BoolInterface,
        else => {},
    }

    @setEvalBranchQuota(10000);
    const info = @typeInfo(T);
    switch (info) {
        .int => return IntegerInterface(T),
        .float => return FloatInterface(T),
        .@"enum" => return if (isInterface(T)) T else return EnumInterface(T),
        .optional => return OptionalInterface(T),
        .array => return ArrayInterface(T),
        .@"struct", .@"union", .@"opaque" => {
            if (isInterface(T)) {
                return T;
            } else {
                @compileError("Type '" ++ @typeName(T) ++ "' does not fulfill the accord parsing interface!");
            }
        },
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    }
}

pub const StringInterface = struct {
    pub fn accordParse(parse_string: []const u8, comptime _: anytype) ![]const u8 {
        return parse_string;
    }
};

pub const BoolInterface = struct {
    pub const AccordParseSettings = struct {
        true_strings: []const []const u8 = &.{ "true", "t", "yes", "1" },
        false_strings: []const []const u8 = &.{ "false", "f", "no", "0" },
    };

    pub fn accordParse(parse_string: []const u8, comptime settings: anytype) AccordError!bool {
        for (settings.true_strings) |string| {
            if (std.ascii.eqlIgnoreCase(parse_string, string)) {
                return true;
            }
        }
        for (settings.false_strings) |string| {
            if (std.ascii.eqlIgnoreCase(parse_string, string)) {
                return false;
            }
        }
        return error.OptionUnexpectedValue;
    }
};

pub fn IntegerInterface(comptime T: type) type {
    return struct {
        pub const AccordParseSettings = struct {
            radix: u8 = 0,
        };

        pub fn accordParse(parse_string: []const u8, comptime settings: anytype) AccordError!T {
            const result = (if (settings.radix == 16)
                std.fmt.parseInt(T, std.mem.trimLeft(u8, parse_string, "#"), settings.radix)
            else
                std.fmt.parseInt(T, parse_string, settings.radix));
            return result catch error.OptionUnexpectedValue;
        }
    };
}

pub fn FloatInterface(comptime T: type) type {
    return struct {
        pub fn accordParse(parse_string: []const u8, comptime _: anytype) AccordError!T {
            return std.fmt.parseFloat(T, parse_string) catch error.OptionUnexpectedValue;
        }
    };
}

pub fn EnumInterface(comptime T: type) type {
    const Tag = @typeInfo(T).@"enum".tag_type;
    return struct {
        pub const AccordParseSettings = MergeStructs(&.{
            struct {
                const EnumSetting = enum { name, value, both };
                enum_parsing: EnumSetting = .name,
            },
            InterfaceSettings(GetInterface(Tag)),
        });

        pub fn accordParse(parse_string: []const u8, comptime settings: anytype) AccordError!T {
            return switch (settings.enum_parsing) {
                .name => std.meta.stringToEnum(T, parse_string) orelse error.OptionUnexpectedValue,
                .value => @enumFromInt(try GetInterface(Tag).accordParse(parse_string, settings)),
                .both => @enumFromInt(GetInterface(Tag).accordParse(parse_string, settings) catch
                    return std.meta.stringToEnum(T, parse_string) orelse error.OptionUnexpectedValue),
            };
        }
    };
}

pub fn OptionalInterface(comptime T: type) type {
    const Child = @typeInfo(T).optional.child;
    return struct {
        pub const AccordParseSettings = MergeStructs(&.{
            struct {
                null_strings: []const []const u8 = &.{ "null", "nul", "nil" },
            },
            InterfaceSettings(GetInterface(Child)),
        });

        pub fn accordParse(parse_string: []const u8, comptime settings: anytype) !T {
            for (settings.null_strings) |string| {
                if (std.ascii.eqlIgnoreCase(parse_string, string)) {
                    return null;
                }
            }
            return try GetInterface(Child).accordParse(parse_string, settings);
        }
    };
}

pub fn ArrayInterface(comptime T: type) type {
    const Child = @typeInfo(T).array.child;
    return struct {
        pub const AccordParseSettings = MergeStructs(&.{
            struct {
                array_delimiter: []const u8 = ",",
            },
            InterfaceSettings(GetInterface(Child)),
        });

        pub fn accordParse(parse_string: []const u8, comptime settings: anytype) !T {
            var result: T = undefined;
            var iterator = std.mem.splitSequence(u8, parse_string, settings.array_delimiter);
            for (0..result.len) |i| {
                const token = iterator.next() orelse return error.OptionMissingValue;
                result[i] = try GetInterface(Child).accordParse(token, settings);
            }
            return result;
        }
    };
}

pub const Flag = struct {
    pub fn accordParse(comptime settings: anytype) !bool {
        return !settings.default_value;
    }
};

pub fn Mask(comptime T: type) type {
    const type_info = @typeInfo(T);
    comptime assert(switch (type_info) {
        .int, .@"enum" => true,
        else => false,
    });

    const is_enum = type_info == .@"enum";
    const Int = if (is_enum) type_info.@"enum".tag_type else T;

    return struct {
        pub const AccordParseSettings = MergeStructs(&.{
            struct {
                mask_delimiter: []const u8 = "|",
            },
            InterfaceSettings(GetInterface(T)),
        });

        pub fn accordParse(parse_string: []const u8, comptime settings: anytype) !T {
            var result: Int = 0;
            var iterator = std.mem.splitSequence(u8, parse_string, settings.mask_delimiter);
            while (iterator.next()) |token| {
                const value = try GetInterface(T).accordParse(token, settings);
                result |= if (is_enum) @intFromEnum(value) else value;
            }
            return if (is_enum)
                if (type_info.@"enum".is_exhaustive)
                    std.meta.intToEnum(T, result) catch error.OptionUnexpectedValue
                else
                    @enumFromInt(result)
            else
                result;
        }
    };
}

pub const PositionalData = struct {
    items: [][]const u8,
    separator_index: usize,

    pub fn beforeSeparator(self: PositionalData) [][]const u8 {
        return self.items[0..self.separator_index];
    }

    pub fn afterSeparator(self: PositionalData) [][]const u8 {
        return self.items[self.separator_index..];
    }

    pub fn deinit(self: PositionalData, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

const log = std.log.scoped(.accord);

pub const Option = struct {
    short: u8,
    long: [:0]const u8,
    type: type,
    settings: *const anyopaque,

    pub fn getDefault(comptime self: Option) *const InterfaceValueType(GetInterface(self.type)) {
        return &self.getSettings().default_value;
    }

    pub fn getSettings(comptime self: Option) *const FinalInterfaceSettings(GetInterface(self.type)) {
        return @ptrCast(@alignCast(self.settings));
    }
};

pub fn option(
    comptime short: u8,
    comptime long: [:0]const u8,
    comptime T: type,
    comptime default: InterfaceValueType(GetInterface(T)),
    comptime settings: FinalInterfaceSettings(GetInterface(T)),
) Option {
    if (short == 0 and long.len == 0)
        @compileError("Must have either a short or long name, cannot have neither!");
    comptime var modified_settings = settings;
    modified_settings.default_value = default;
    const final_settings = modified_settings;
    return .{
        .short = short,
        .long = long,
        .type = T,
        .settings = &final_settings,
    };
}

fn structField(
    comptime name: [:0]const u8,
    comptime T: type,
    comptime default: ?*const T,
) std.builtin.Type.StructField {
    return .{
        .name = name,
        .type = T,
        .default_value_ptr = @ptrCast(default),
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
}

pub fn OptionStruct(comptime options: []const Option) type {
    comptime var struct_fields: [options.len + 1]StructField = undefined;

    for (options, 0..) |opt, i| {
        struct_fields[i] = structField(
            if (opt.long.len > 0) opt.long else &[1:0]u8{opt.short},
            InterfaceValueType(GetInterface(opt.type)),
            opt.getDefault(),
        );
    }

    struct_fields[options.len] = structField(
        "positionals",
        PositionalData,
        null,
    );

    const struct_info = std.builtin.Type{ .@"struct" = .{
        .layout = .auto,
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } };
    return @Type(struct_info);
}

const AccordError = error{
    UnrecognizedOption,
    OptionMissingValue,
    OptionUnexpectedValue,
};

pub fn parse(comptime options: []const Option, allocator: std.mem.Allocator, arg_iterator: anytype) !OptionStruct(options) {
    const OptValues = OptionStruct(options);
    var result = OptValues{ .positionals = undefined };
    var positional_list = StringList{};
    errdefer positional_list.deinit(allocator);

    const Parser = struct {
        pub fn common(comptime long_name: bool, arg_name: []const u8, value_string: ?[]const u8, values: *OptValues, iterator: anytype) AccordError!void {
            inline for (options) |opt| {
                const opt_name = if (long_name) opt.long else &[1]u8{opt.short};
                if (std.mem.eql(u8, arg_name, opt_name)) {
                    const field_name = if (opt.long.len > 0) opt.long else &[1]u8{opt.short};
                    const Interface = GetInterface(opt.type);
                    if (comptime interfaceIsFlag(Interface)) {
                        if (value_string != null and value_string.?.len > 0) {
                            if (long_name) {
                                log.err("Option '{s}' does not take an argument!", .{opt_name});
                                return error.OptionUnexpectedValue;
                            } else {
                                @field(values, field_name) = try Interface.accordParse(opt.getSettings());
                                const next_name = &[1]u8{value_string.?[0]};
                                const next_value_string = if (value_string.?[1..].len > 0)
                                    value_string.?[1..]
                                else
                                    null;
                                try common(false, next_name, next_value_string, values, iterator);
                            }
                        } else @field(values, field_name) = try Interface.accordParse(opt.getSettings());
                    } else {
                        const vs = value_string orelse (iterator.next() orelse {
                            log.err("Option '{s}' missing argument!", .{opt_name});
                            return error.OptionMissingValue;
                        });

                        @field(values, field_name) = Interface.accordParse(vs, opt.getSettings()) catch {
                            log.err("Could not parse value '{s}' for option '{s}!", .{ vs, opt_name });
                            return error.OptionUnexpectedValue;
                        };
                    }
                    break;
                }
            } else {
                log.err("Unrecognized {s} option '{s}'!", .{
                    if (long_name) "long" else "short",
                    arg_name,
                });
                return error.UnrecognizedOption;
            }
        }

        pub fn long(arg: []const u8, values: *OptValues, iterator: anytype) AccordError!void {
            const index = std.mem.indexOf(u8, arg, "=");
            var arg_name: []const u8 = undefined;
            var value_string: ?[]const u8 = undefined;
            if (index) |i| {
                arg_name = arg[2..i];
                value_string = arg[i + 1 ..];
            } else {
                arg_name = arg[2..];
                value_string = null;
            }

            try common(true, arg_name, value_string, values, iterator);
        }

        pub fn short(arg: []const u8, values: *OptValues, iterator: anytype) AccordError!void {
            const arg_name = &[1]u8{arg[1]};
            const value_string = if (arg.len > 2)
                arg[2..]
            else
                null;

            try common(false, arg_name, value_string, values, iterator);
        }
    };

    var all_positional = false;
    while (arg_iterator.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--") and !all_positional) {
            if (arg.len == 2) {
                all_positional = true;
                result.positionals.separator_index = positional_list.items.len;
            } else try Parser.long(arg, &result, arg_iterator);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !all_positional) {
            try Parser.short(arg, &result, arg_iterator);
        } else {
            try positional_list.append(allocator, arg);
        }
    }

    positional_list.shrinkAndFree(allocator, positional_list.items.len);
    result.positionals.items = positional_list.items;
    if (!all_positional)
        result.positionals.separator_index = result.positionals.items.len;

    return result;
}

test "argument parsing" {
    const SliceIterator = struct {
        pub fn SliceIterator(comptime T: type) type {
            return struct {
                slice: []const T,
                index: usize,

                const Self = @This();

                pub fn init(slice: []const T) Self {
                    return Self{ .slice = slice, .index = 0 };
                }

                pub fn next(self: *Self) ?T {
                    var result: ?T = null;
                    if (self.index < self.slice.len) {
                        result = self.slice[self.index];
                        self.index += 1;
                    }
                    return result;
                }
            };
        }
    }.SliceIterator;

    const TestEnum = enum(u2) { a, b, c, d };

    const allocator = std.testing.allocator;
    // zig fmt: off
    const args = [_][]const u8{
        "positional1",
        "-a", "test arg",
        "-b",
        "positional2",
        "-cd", "FaLSE",
        "-eff0000",
        "--longf=c",
        "--longg", "1",
        "positional3",
        "-h1,d,0",
        "-ib",
        "-j", "d,a,b",
        "-k10|NuLL|d",
        "-lniL",
        "positional4",
        "-m0b00110010",
        "-n", "1.2e4",
        "-o0x10p+10",
        "positional5",
        "-p0x10p-10",
        "-q", "bingusDELIMITERbungusDELIMITERbongoDELIMITERbingo",
        "-r", "bujungo",
        "-s", "1110|0110",
        "-u", "nO",
        "--",
        "-t",
        "positional6",
    };
    // zig fmt: on
    var args_iterator = SliceIterator([]const u8).init(args[0..]);
    const options = try parse(&.{
        option('a', "longa", []const u8, "", .{}),
        option('b', "", Flag, false, .{}),
        option('c', "longc", Flag, true, .{}),
        option('d', "", bool, true, .{}),
        option('e', "", u32, 0, .{ .radix = 16 }),
        option('f', "", TestEnum, .a, .{}),
        option('f', "longf", TestEnum, .a, .{}),
        option('g', "longg", TestEnum, .a, .{ .enum_parsing = .value }),
        option('h', "", [3]TestEnum, .{ .a, .a, .a }, .{ .enum_parsing = .both }),
        option('i', "", ?TestEnum, null, .{}),
        option('j', "", ?[3]TestEnum, null, .{}),
        option('k', "", [3]?TestEnum, .{ null, .a, .a }, .{ .enum_parsing = .both, .array_delimiter = "|", .radix = 2 }),
        option('l', "", ?[3]?TestEnum, .{ .a, .a, .a }, .{}),
        option('m', "", u8, 0, .{}),
        option('n', "", f32, 0.0, .{}),
        option('o', "", f64, 0.0, .{}),
        option('p', "", f128, 0.0, .{}),
        option('q', "", [4][]const u8, .{ "", "", "", "" }, .{ .array_delimiter = "DELIMITER" }),
        option('r', "", ?[]const u8, null, .{}),
        option('s', "", Mask(u8), 0, .{ .radix = 2 }),
        option('t', "", Flag, false, .{}),
        option('u', "", bool, true, .{}),
    }, allocator, &args_iterator);
    defer options.positionals.deinit(allocator);

    try std.testing.expectEqualStrings("test arg", options.longa);
    try std.testing.expect(options.b);
    try std.testing.expect(!options.longc);
    try std.testing.expect(!options.d);
    try std.testing.expectEqual(options.e, 0xff0000);
    try std.testing.expectEqual(options.longf, .c);
    try std.testing.expectEqual(options.longg, .b);
    try std.testing.expectEqualSlices(TestEnum, &.{ .b, .d, .a }, options.h[0..]);
    try std.testing.expectEqual(options.i, .b);
    try std.testing.expectEqual(options.j, .{ .d, .a, .b });
    try std.testing.expectEqualSlices(?TestEnum, &.{ .c, null, .d }, options.k[0..]);
    try std.testing.expectEqual(options.l, null);
    try std.testing.expectEqual(options.m, 50);
    try std.testing.expectEqual(options.n, 12000);
    try std.testing.expectEqual(options.o, 16384.0);
    try std.testing.expectEqual(options.p, 0.015625);
    const expected_q = [_][]const u8{ "bingus", "bungus", "bongo", "bingo" };
    for (expected_q, options.q) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqualStrings(options.r.?, "bujungo");
    try std.testing.expectEqual(options.s, 0b1110);
    try std.testing.expectEqual(options.t, false);
    try std.testing.expectEqual(options.u, false);

    const expected_positionals = [_][]const u8{
        "positional1",
        "positional2",
        "positional3",
        "positional4",
        "positional5",
        "-t",
        "positional6",
    };
    for (expected_positionals, options.positionals.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    const expected_positionals_before = expected_positionals[0..5];
    const actual_positionals_before = options.positionals.beforeSeparator();
    for (expected_positionals_before, actual_positionals_before) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    const expected_positionals_after = expected_positionals[5..];
    const actual_positionals_after = options.positionals.afterSeparator();
    for (expected_positionals_after, actual_positionals_after) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}
