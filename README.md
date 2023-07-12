# accord
NOTE: Accord was made for use with zig master, it is not guaranteed to and likely will not work on release versions

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
    - Optionals of any of these types (except `Flag`)
    - Mask type via `accord.Mask(INT OR ENUM TYPE)`
        - Takes a delimited list of ints/enums and bitwise ORs them together
    - Array of any of these types (except `Flag`)
        - If you don't fill out every array value, the rest will be filled with the defaults (maybe it should be an error instead? need to think on it)
    - Optional array, array of optionals, and optional array of optionals
- Type settings:
    - Integers have a `radix` u8 setting, defaults to 0.
        - A radix of 0 means assume base 10 unless the value starts with:
            - `0b` = binary
            - `0o` = octal
            - `0x` = hexadecimal
    - Enums have an `enum_parsing` enum setting with the values `name`, `value`, and `both`, defaults to `name`. Enums also have the integer `radix` setting for parsing by `value`.
        - `name` means it will try to match the value with the names of the fields in the enum.
        - `value` means it will try to match the values of the fields.
        - `both` means it will first try to match the field values, and if that fails it will try to match the field names.
    - Arrays and masks have an `array_delimiter` and `mask_delimiter` string setting respectively, defaults to `","` for arrays and `"|"` for masks. They will also inherit any settings from their child type (e.g. an array or mask of enums would also have the `enum_parsing` and `radix` settings available)

## Example
```zig
const allocator = std.heap.page_allocator;
var args_iterator = std.process.args();
const options = try accord.parse(&.{
    accord.option('s', "string", []const u8, "default", .{}),
    accord.option('c', "color", u32, 0x000000, .{ .radix = 16 }),
    accord.option('f', "float", f32, 0.0, .{}),
    accord.option('m', "mask", accord.Mask(u8), 0, .{}),
    accord.option('a', "", accord.Flag, {}, .{}), // option without long option
    accord.option(0, "option", accord.Flag, {}, .{}), // option without short option
    accord.option('i', "intarray", [2]?u32, .{ 0, 0 }, .{ .array_delimiter = "%" }),
}, allocator, &args_iterator);
defer options.positionals.deinit(allocator);
```
The above example called as

`command positional1 -s"some string" --color ff0000 positional2 -f 1.2e4 --mask="2|3" -a positional3 --intarray="null%23" -- --option positional4 positional5`

would result in the following value:
```zig
{
    string = "some string"
    color = 0xff0000
    float = 12000.0
    mask = 3
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
        - Multiple fields of the same type (is there a reason you would do this? if not it can just be a compiler error to do so)
        - Should I ensure that every field in a union is a valid, parseable field?
        - How should enums prioritize relative to integers when parsing by value?
        - Does it make sense to allow multiple similar types, e.g. multiple unsigned integers, multiple signed integers, multiple floats
    - probably not worth the effort
- Definable prefix for short and long arguments, instead of forcing `--`.
    - This could include an empty prefix, allowing you to do things like `command option value`
    - Ensure short and long prefixes are different
    - If short prefix > long prefix, check short prefix first
        - or make it an error for short to be greater than long
- More and/or customizable acceptable values for bools
    - e.g. yes/no, 1/2, t/f, etc
- Ability to define custom types, similar to how the custom mask type works but implementable by users without modifying the accord source
