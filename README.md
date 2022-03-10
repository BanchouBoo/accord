# accord
NOTE: Accord was made for use with zig master, it will not work on 0.9.1 or older versions.

## Features
- Automatically generate and fill a struct based on input parameters.
- Short and long options.
- Short options work with both `-a -b -c -d 12` and `-abcd12`.
- Long options work with both `--option long` and `--option=long`.
- Everything after a standalone `--` will be considered a positional argument. The index for this will also be stored, so you can slice the positionals before or after `--` if you want to have a distinction between them.
- Positional arguments stored in a struct with `items` storing the actual slice, `separator_index` storing the aforementioned index of `--` if it exists, and `beforeSeparator` and `afterSeparator` functions to get the positionals before and after the `--` (if there's no `--`, then before will return everything and after will return nothing).
    - Positional arguments must be manually freed using `positionals.deinit(allocator)`.
- Types:
    - Strings (`[]const u8`)
    - Signed and unsigned integers
    - Floats
    - Booleans (*must* have `true` or `false` as the value)
    - Flags with no arguments via `void` (or the `accord.Flag` alias for readability)
    - Enums by name, value, or both
    - Optionals of any of these types (except `void`)
    - Array of any of these types (except `void`)
        - If you don't fill out every array value, the rest will be filled with the defaults
    - Optional array, array of optionals, and optional array of optionals
- Type settings:
    - Integers have a `radix` u8 setting, defaults to 0.
        - A radix of 0 means assume base 10 unless the value starts with:
            - `0b` = binary
            - `0o` = octal
            - `0x` = hexadecimal
    - Floats have a `hex` bool setting, defaults to false. Allows you to parse hexadecimal floating point values.
    - Enums have an `enum_parsing` enum setting with the values `name`, `value`, and `both`, defaults to `name`. Enums also have the integer `radix` setting.
        - `name` means it will try to match the value with the names of the fields in the enum.
        - `value` means it will try to match the values of the fields.
        - `both` means it will first try to match the field values, and if that fails it will try to match the field names.
    - Arrays have a `delimiter` string setting, defaults to `","`. It will also inherit any settings from it's child type (e.g. an array of enums would also have the `enum_parsing` and `radix` settings available)
        - Separator between array values.

## Example
```zig
const allocator = std.heap.page_allocator;
var args_iterator = std.process.args();
const options = try accord.parse(&.{
    accord.option('s', "string", []const u8, "default", .{}),
    accord.option('c', "color", u32, 0x000000, .{ .radix = 16 }),
    accord.option('f', "float", f32, 0.0, .{}),
    accord.option('a', "", accord.Flag, {}, .{}), // option without long option
    accord.option(0, "option", accord.Flag, {}, .{}), // option without short option
    accord.option('i', "intarray", [2]?u32, .{ 0, 0 }, .{ .delimiter = "|" }),
}, allocator, &args_iterator);
defer options.positionals.deinit(allocator);
```
The above example called as

`command positional1 -s"some string" --color ff0000 positional2 -f 1.2e4 -a positional3 --intarray="null|23" -- --option positional4 positional5`

would result in the following value:
```zig
{
    string = "some string"
    color = 0xff0000
    float = 12000.0
    a = true
    option = false
    intarray = { null, 23 }
    positionals.items = { "command", "positional1", "positional2", "positional3", "--option", "positional4", "positional5" }
    positionals.beforeSeparator() = { "command", "positional1", "positional2", "positional3" }
    positionals.afterSeparator() = { "--option", "positional4", "positional5" }
}
```

## Possible things to add in the future
- Multidimensional arrays
    - I have a few ideas about how I could do this, would possibly require a bit of restructuring and I'm not sure if it'd be worth the effort
- Unions
    - Sort the fields by type, parse for each type until one of them succeeds.
    - Potential issues/considerations:
        - If there are two optional types in the union, and the parse value is `null`, which field should be set?
            - Perhaps it doesn't make sense to support optionals for unions anyway, since you could instead make the union itself an optional
        - Multiple fields of the same type (probably not a a big deal though? more of a user error if you try and do this, perhaps I could add a compiler error to prevent it though)
        - Should I ensure that every field in a union is a valid, parseable field?
        - How should enums prioritize relative to integers when parsing by value?
        - Does it make sense to allow multiple similar types, e.g. multiple unsigned integers, multiple signed integers, multiple floats
- Special mask type
    - A type generated from an int or enum that parses a delimited list of that type and bitwise ORs them together.
    - Default delimiter `|` to match the actual operator
- Definable prefix for short and long arguments, instead of forcing `--`.
    - This could include an empty prefix, allowing you to do things like `command option value`
    - Ensure short and long prefixes are different
    - If short prefix > long prefix, check short prefix first
