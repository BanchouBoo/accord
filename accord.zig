const std = @import("std");

const StringList = std.ArrayListUnmanaged([]const u8);
pub const Flag = void;
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
    long: []const u8,
    type: type,
    default: *const anyopaque,
    settings: *const anyopaque,

    pub fn getDefault(comptime self: Option) *const ValueType(self.type) {
        return @ptrCast(*const ValueType(self.type), @alignCast(@alignOf(ValueType(self.type)), self.default));
    }

    pub fn getSettings(comptime self: Option) *const OptionSettings(self.type) {
        return @ptrCast(*const OptionSettings(self.type), @alignCast(@alignOf(OptionSettings(self.type)), self.settings));
    }
};

fn ValueType(comptime T: type) type {
    return switch (T) {
        void => bool,
        else => T,
    };
}

const Field = std.builtin.Type.StructField;
fn optionSettingsFields(comptime T: type) []const Field {
    comptime var info = @typeInfo(T);
    switch (info) {
        .Int => return &[1]Field{structField("radix", u8, &@as(u8, 0))},
        .Enum => {
            const EnumSetting = enum { name, value, both };
            return optionSettingsFields(info.Enum.tag_type) ++
                &[1]Field{structField("enum_parsing", EnumSetting, &EnumSetting.name)};
        },
        .Optional => return optionSettingsFields(info.Optional.child),
        .Array => {
            // TODO: make them work!
            if (@typeInfo(info.Array.child) == .Array)
                @compileError("Multidimensional arrays not yet supported!");
            const delimiter: []const u8 = ",";
            return optionSettingsFields(info.Array.child) ++
                &[1]Field{structField("delimiter", []const u8, &delimiter)};
        },
        else => return &[0]Field{},
    }
}

pub fn OptionSettings(comptime T: type) type {
    const fields = optionSettingsFields(T);
    return if (fields.len == 0)
        struct { padding_so_i_can_make_a_non_zero_sized_pointer: u1 = 0 }
    else
        @Type(std.builtin.Type{ .Struct = .{
            .layout = .Auto,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        } });
}

pub fn option(
    comptime short: u8,
    comptime long: []const u8,
    comptime T: type,
    comptime default: T,
    comptime settings: OptionSettings(T),
) Option {
    if (short == 0 and long.len == 0)
        @compileError("Must have either a short or long name, cannot have neither!");
    return .{
        .short = short,
        .long = long,
        .type = T,
        .default = if (T == void) &false else @ptrCast(*const anyopaque, &default),
        .settings = &settings,
    };
}

fn structField(
    comptime name: []const u8,
    comptime T: type,
    comptime default: ?*const T,
) std.builtin.Type.StructField {
    return .{
        .name = name,
        .field_type = T,
        .default_value = @ptrCast(?*const anyopaque, default),
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
}

pub fn OptionStruct(comptime options: []const Option) type {
    const Type = std.builtin.Type;
    comptime var struct_fields: [options.len + 1]Type.StructField = undefined;

    for (options) |opt, i| {
        struct_fields[i] = structField(
            if (opt.long.len > 0) opt.long else &[1]u8{opt.short},
            ValueType(opt.type),
            opt.getDefault(),
        );
    }

    struct_fields[options.len] = structField(
        "positionals",
        PositionalData,
        null,
    );

    const struct_info = Type{ .Struct = .{
        .layout = .Auto,
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

fn parseValue(comptime T: type, comptime default: ?T, comptime settings: anytype, string: []const u8) AccordError!T {
    const info = @typeInfo(T);
    switch (T) {
        []const u8 => return string,
        bool => {
            return if (std.ascii.eqlIgnoreCase(string, "true"))
                true
            else if (std.ascii.eqlIgnoreCase(string, "false"))
                false
            else
                error.OptionUnexpectedValue;
        },
        else => {},
    }

    switch (info) {
        .Int => return std.fmt.parseInt(T, string, settings.radix) catch error.OptionUnexpectedValue,
        .Float => {
            return std.fmt.parseFloat(T, string) catch error.OptionUnexpectedValue;
        },
        .Optional => {
            const d = default orelse null;
            return if (std.ascii.eqlIgnoreCase(string, "null"))
                null
            else
                // try is necessary here otherwise there are type errors
                try parseValue(info.Optional.child, d, settings, string);
        },
        .Array => {
            const ChildT = info.Array.child;
            var result: T = default orelse undefined;
            var iterator = std.mem.split(u8, string, settings.delimiter);
            comptime var i: usize = 0; // iterate with i instead of iterator so default can be indexed
            inline while (i < result.len) : (i += 1) {
                // TODO: if token length == 0, grab default value instead
                const token = iterator.next() orelse break;
                result[i] = try parseValue(
                    ChildT,
                    if (default) |d| d[i] else null,
                    settings,
                    token,
                );
            }
            if (i != result.len and default == null) {
                log.err("Optional arrays that have a default value of null must have every value filled out!", .{});
                return error.OptionUnexpectedValue;
            }

            return result;
        },
        .Enum => {
            const TagT = info.Enum.tag_type;
            return switch (settings.enum_parsing) {
                .name => std.meta.stringToEnum(T, string) orelse error.OptionUnexpectedValue,
                .value => std.meta.intToEnum(T, parseValue(
                    TagT,
                    if (default) |d| @enumToInt(d) else null,
                    settings,
                    string,
                ) catch return error.OptionUnexpectedValue) catch error.OptionUnexpectedValue,
                .both => std.meta.intToEnum(T, parseValue(
                    TagT,
                    if (default) |d| @enumToInt(d) else null,
                    settings,
                    string,
                ) catch {
                    return std.meta.stringToEnum(T, string) orelse error.OptionUnexpectedValue;
                }) catch error.OptionUnexpectedValue,
            };
        },
        else => @compileError("Unsupported type '" ++ @typeName(T) ++ "'"),
    }
}

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
                    if (opt.type == void) {
                        if (value_string != null and value_string.?.len > 0) {
                            if (long_name) {
                                log.err("Option '{s}' does not take an argument!", .{opt_name});
                                return error.OptionUnexpectedValue;
                            } else {
                                @field(values, field_name) = true;
                                const next_name = &[1]u8{value_string.?[0]};
                                const next_value_string = if (value_string.?[1..].len > 0)
                                    value_string.?[1..]
                                else
                                    null;
                                try common(false, next_name, next_value_string, values, iterator);
                            }
                        } else @field(values, field_name) = true;
                    } else {
                        const vs = value_string orelse (iterator.next() orelse {
                            log.err("Option '{s}' missing argument!", .{opt_name});
                            return error.OptionMissingValue;
                        });

                        @field(values, field_name) = parseValue(
                            opt.type,
                            comptime opt.getDefault().*,
                            comptime opt.getSettings(),
                            vs,
                        ) catch {
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

fn SliceIterator(comptime T: type) type {
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

const TestEnum = enum(u2) { a, b, c, d };

test "argument parsing" {
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
        "-k10|NULL|d",
        "-lnull",
        "positional4",
        "-m0b00110010",
        "-n", "1.2e4",
        "-o0x10p+10",
        "positional5",
        "-p0x10p-10",
        "-q", "bingusDELIMITERbungusDELIMITERbongoDELIMITERbingo",
        "-r", "bujungo",
        "--",
        "-s",
        "positional6",
    };
    // zig fmt: on
    var args_iterator = SliceIterator([]const u8).init(args[0..]);
    const options = try parse(&.{
        option('a', "longa", []const u8, "", .{}),
        option('b', "", Flag, {}, .{}),
        option('c', "longc", Flag, {}, .{}),
        option('d', "", bool, true, .{}),
        option('e', "", u32, 0, .{ .radix = 16 }),
        option('f', "", TestEnum, .a, .{}),
        option('f', "longf", TestEnum, .a, .{}),
        option('g', "longg", TestEnum, .a, .{ .enum_parsing = .value }),
        option('h', "", [3]TestEnum, .{ .a, .a, .a }, .{ .enum_parsing = .both }),
        option('i', "", ?TestEnum, null, .{}),
        option('j', "", ?[3]TestEnum, null, .{}),
        option('k', "", [3]?TestEnum, .{ null, .a, .a }, .{ .enum_parsing = .both, .delimiter = "|", .radix = 2 }),
        option('l', "", ?[3]?TestEnum, .{ .a, .a, .a }, .{}),
        option('m', "", u8, 0, .{}),
        option('n', "", f32, 0.0, .{}),
        option('o', "", f64, 0.0, .{}),
        option('p', "", f128, 0.0, .{}),
        option('q', "", [4][]const u8, .{ "", "", "", "" }, .{ .delimiter = "DELIMITER" }),
        option('r', "", ?[]const u8, null, .{}),
        option('s', "", Flag, {}, .{}),
    }, allocator, &args_iterator);
    defer options.positionals.deinit(allocator);

    try std.testing.expectEqualStrings("test arg", options.longa);
    try std.testing.expect(options.b);
    try std.testing.expect(options.longc);
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
    for (expected_q) |string, i| {
        try std.testing.expectEqualStrings(string, options.q[i]);
    }
    try std.testing.expectEqualStrings(options.r.?, "bujungo");
    const expected_positionals = [_][]const u8{
        "positional1",
        "positional2",
        "positional3",
        "positional4",
        "positional5",
        "-s",
        "positional6",
    };
    for (expected_positionals) |string, i| {
        try std.testing.expectEqualStrings(string, options.positionals.items[i]);
    }
    for (expected_positionals[0..options.positionals.separator_index]) |string, i| {
        try std.testing.expectEqualStrings(
            string,
            options.positionals.beforeSeparator()[i],
        );
    }
    for (expected_positionals[options.positionals.separator_index..]) |string, i| {
        try std.testing.expectEqualStrings(
            string,
            options.positionals.afterSeparator()[i],
        );
    }
    try std.testing.expectEqual(options.s, false);
}
