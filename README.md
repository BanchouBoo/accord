# accord
NOTE: Accord was made for use with zig master, it is not guaranteed to and likely will not work on release versions

## Features
### Basic usage
- Automatically generate and fill a struct based on input parameters.
- Short and long options.
- Short options work with both `-a -b -c -d 12` and `-abcd12`.
- Long options work with both `--option long` and `--option=long`.
- Everything after a standalone `--` will be considered a positional argument. The index for this will also be stored, so you can slice the positionals before or after `--` if you want to have a distinction between them.
- Positional arguments stored in a struct with `items` storing the actual slice, `separator_index` storing the aforementioned index of `--` if it exists, and `beforeSeparator` and `afterSeparator` functions to get the positionals before and after the `--` (if there's no `--`, then before will return everything and after will return nothing).
    - Positional arguments must be manually freed using `positionals.deinit(allocator)`.
### Types
#### Built in
- Strings (`[]const u8`)
- Signed and unsigned integers
- Floats
- Booleans
- Flags with no arguments via `accord.Flag`, when a flag argument is used it will return the opposite of its default value
- Enums by name, value, or both
- Optionals of any of these types (except `Flag`)
- Mask type via `accord.Mask(int or enum type)`
    - Takes a delimited list of ints/enums and bitwise ORs them together
- Array of any of these types (except `Flag`)
    - Not filling out every value in the array will return an error

#### Settings
- Booleans have `true_strings` and `false_strings` settings to determine what is considered as true/false. Note that these are case insensitive.
    - Defaults:
        - `true_strings = &.{ "true", "t", "yes", "1" }`
        - `false_strings &.{ "false", "f", "no", "0" }`
- Integers have a `radix` u8 setting, defaults to 0.
    - A radix of 0 means assume base 10 unless the value starts with:
        - `0b` = binary
        - `0o` = octal
        - `0x` = hexadecimal
- Enums have an `enum_parsing` enum setting with the values `name`, `value`, and `both`, defaults to `name`. Enums also inherit integer parsing settings for when parsing by `value`.
    - `name` means it will try to match the value with the names of the fields in the enum.
    - `value` means it will try to match the values of the fields.
    - `both` means it will first try to match the field values, and if that fails it will try to match the field names.
- Optionals have the `null_strings` to determine when the value is parsed as `null`. Note that these are case insensitive. Optionals also inherit options from their child type.
    - Default `null_strings = &.{ "null", "nul", "nil" }`
- Arrays and masks have an `array_delimiter` and `mask_delimiter` setting respectively, defaults to `","` for arrays and `"|"` for masks. They will also inherit any settings from their child type (e.g. an array or mask of enums would also have the `enum_parsing` and `radix` settings available)

#### Custom
In addition to all default types built into the library, you can also easily define your own custom parsing by fulfilling a particular interface.

All basic types supported in the library are also implemented through this system, so you can reference all of them for examples, the following is how the parsing interface for integers is implemented:

```zig
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
```

You can also implement custom no-argument flags by omitting the first argument in the function. The implementation of `Flag` is as follows:

```zig
pub const Flag = struct {
    pub fn accordParse(comptime settings: anytype) !bool {
        return !settings.default_value;
    }
};
```

The following is a truncated example of the enum parsing interface which demonstrates merging settings from other types. When merging settings like this, you may have the same field in multiple structs so long as they have the same type, and it will prioritize the default value of the setting of the earliest struct that has the field.

```zig
pub fn EnumInterface(comptime T: type) type {
    const Tag = @typeInfo(T).Enum.tag_type;
    returnt struct {
        pub const AccordParseSettings = MergeStructs(&.{
            struct {
                const EnumSetting = enum { name, value, both };
                enum_parsing: EnumSetting = .name,
            },
            InterfaceSettings(GetInterface(Tag)),
        });
    };
```

## Example usage
```zig
const allocator = std.heap.page_allocator;
var args_iterator = std.process.args();
const options = try accord.parse(&.{
                  //short name //long name         //type           //default value   //parse options
    accord.option('s',         "string",           []const u8,      "default",        .{}),
    accord.option('c',         "color",            u32,             0x000000,         .{ .radix = 16 }),
    accord.option('f',         "float",            f32,             0.0,              .{}),
    accord.option('m',         "mask",             accord.Mask(u8), 0,                .{}),
    accord.option('a',         "",                 accord.Flag,     false,            .{}), // option without long option
    accord.option(0,           "option",           accord.Flag,     false,            .{}), // option without short option
    accord.option('i',         "optionalintarray", [2]?u32,         .{ 0, 0 },        .{ .array_delimiter = "%" }),
}, allocator, &args_iterator);
defer options.positionals.deinit(allocator);
```
The above example called as

`command positional1 -s"some string" --color ff0000 positional2 -f 1.2e4 --mask="2|3" -a positional3 --optionalintarray="null%23" -- --option positional4 positional5`

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
- Subcommands
    - Parsable union containing an Option and Subcommand field
    - Flags before a subcommand use top level flags
    - Flags after a subcommand apply to the subcommand
    - Subcommands after -- are considered normal positionals
    - Subcommand stored as a sub-struct in the parse return struct. Possibly store it's own return value?
- A way to define help strings per argument and print them all nicely
- Required arguments
