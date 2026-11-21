const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const Type = std.builtin.Type;

const constants = @import("constants.zig");


// Group the parallel reflection arrays for configuration field transforms.
pub fn fieldInfos(comptime T: type) [std.meta.fieldNames(T).len]FieldInfo(T) {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        .@"union" => |value| value,
        else => @compileError("expected a struct or union"),
    };
    var result: [info.field_names.len]FieldInfo(T) = undefined;
    for (info.field_names, info.field_types, info.field_attrs, &result) |name, ty, attrs, *field| {
        field.* = .{ .name = name, .type = ty, .attrs = attrs };
    }
    return result;
}

fn FieldInfo(comptime T: type) type {
    return struct {
        name: [:0]const u8,
        type: type,
        attrs: switch (@typeInfo(T)) {
            .@"struct" => Type.Struct.FieldAttributes,
            .@"union" => Type.Union.FieldAttributes,
            else => @compileError("expected a struct or union"),
        },
    };
}

// turn packed struct to normal struct
pub fn unpacked(comptime T: type) type {
    const fields = fieldInfos(T);
    var len: usize = 0;
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]Type.Struct.FieldAttributes = undefined;
    for (fields) |field| {
        if (field.name[0] == '_') continue;

        names[len] = field.name;
        types[len] = field.@"type";
        attrs[len] = Type.Struct.FieldAttributes {
            .@"comptime" = field.attrs.@"comptime",
            .@"align" = field.attrs.@"align",
            .default_value_ptr = field.attrs.default_value_ptr,
        };
        len += 1;
    }

    return @Struct(
        .auto,
        null,
        names[0..len],
        types[0..len],
        attrs[0..len]
    );
}


pub fn add_default(comptime T: type, comptime object: T) type {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            const len = fieldInfos(T).len;
            var names: [len][]const u8 = undefined;
            var types: [len]type = undefined;
            var attrs: [len]Type.Struct.FieldAttributes = undefined;

            for (0.., fieldInfos(T)) |i, field| {
                const new_T = add_default(field.type, @field(object, field.name));
                const default: new_T = switch (@typeInfo(new_T)) {
                    .@"struct" => .{},
                    .optional => |optional_info| switch (@typeInfo(optional_info.child)) {
                        .@"struct" => if (@field(object, field.name)) |_| .{} else null,
                        else => @field(object, field.name),
                    },
                    else => @field(object, field.name),
                };

                names[i] = field.name;
                types[i] = new_T;
                attrs[i] = Type.Struct.FieldAttributes {
                    .@"comptime" = field.attrs.@"comptime",
                    .@"align" = field.attrs.@"align",
                    .default_value_ptr = @ptrCast(&default),
                };
            }

            return @Struct(info.layout, info.backing_integer, &names, &types, &attrs);
        },
        .optional => |info| return
            if (object) |obj| ?add_default(info.child, obj)
            else T,
        else => return T,
    }
}


pub fn enum_struct(comptime E: type, comptime T: type) type {
    const info = @typeInfo(E).@"enum";

    const len = info.field_names.len;
    var names: [len][]const u8 = undefined;
    var types: [len]type = undefined;
    var attrs: [len]Type.Struct.FieldAttributes = undefined;
    for (0.., info.field_names) |i, name| {
        names[i] = name;
        types[i] = T;
        attrs[i] = Type.Struct.FieldAttributes {
            .@"comptime" = false,
            .@"align" = @alignOf(T),
            .default_value_ptr = switch (@typeInfo(T)) {
                .optional => blk: {
                    const default_value: T = null;
                    break :blk &default_value;
                },
                else => null,
            },
        };
    }

    const S = @Struct(.auto, null, &names, &types, &attrs);

    const Getter = struct {
        pub const instance: @This() = .{};
        pub fn get(self: *const @This(), e: E) T {
            return switch (e) {
                inline else => |v| @field(
                    @as(*const S, @ptrCast(@alignCast(self))),
                    @tagName(v)
                ),
            };
        }
    };

    return @Struct(
        .auto,
        null,
        &(.{ "getter" } ++ names),
        &(.{ Getter } ++ types),
        &(.{
            Type.Struct.FieldAttributes {
                .@"comptime" = false,
                .@"align" = @alignOf(T),
                .default_value_ptr = &Getter.instance
            }
        } ++ attrs)
    );
}


pub fn make_optional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => T,
        .@"struct" => ?make_fields_optional(T),
        else => ?T,
    };
}


pub fn make_fields_optional(comptime T: type) type {

    const len = fieldInfos(T).len;
    var names: [len][]const u8 = undefined;
    var types: [len]type = undefined;
    var attrs: [len]Type.Struct.FieldAttributes = undefined;
    for (0.., fieldInfos(T)) |i, field| {
        const new_T = make_optional(field.type);
        const default_value: new_T = null;
        names[i] = field.name;
        types[i] = new_T;
        attrs[i] = Type.Struct.FieldAttributes {
            .@"comptime" = false,
            .@"align" = @alignOf(new_T),
            .default_value_ptr = &default_value,
        };
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}


pub fn field_mask(comptime T: type) type {

    const len = fieldInfos(T).len;
    var names: [len][]const u8 = undefined;
    var attrs: [len]Type.Struct.FieldAttributes = undefined;
    for (0.., fieldInfos(T)) |i, field| {
        const default_value = false;
        names[i] = field.name;
        attrs[i] = Type.Struct.FieldAttributes {
            .@"comptime" = false,
            .@"align" = @alignOf(bool),
            .default_value_ptr = &default_value,
        };
    }

    return @Struct(.auto, null, &names, &@splat(bool), &attrs);
}


pub fn override(base: anytype, new: anytype) @TypeOf(base) {
    const T = @TypeOf(base);
    var result: T = undefined;
    inline for (fieldInfos(T)) |field_info| {
        const new_field = @field(new, field_info.name);
        const base_field = @field(base, field_info.name);
        @field(result, field_info.name) =
            if (new_field == null) base_field
            else switch (@typeInfo(field_info.type)) {
                .@"struct" => override(base_field, new_field.?),
                else => new_field.?,
            };
    }
    return result;
}


pub fn deep_equal(comptime T: type, a: *const T, b: *const T) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            inline for (fieldInfos(T)) |field| {
                if (!deep_equal(
                    field.type,
                    @ptrCast(&@field(a, field.name)),
                    @ptrCast(&@field(b, field.name)),
                )) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .array => |info| blk: {
            if (a.len != b.len) break :blk false;

            for (a.*, b.*) |elem_a, elem_b| {
                if (!deep_equal(info.child, &elem_a, &elem_b)) {
                    break :blk false;
                }
            }

            break :blk true;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                if (a.len != b.len) break :blk false;

                for (a.*, b.*) |elem_a, elem_b| {
                    if (!deep_equal(info.child, &elem_a, &elem_b)) {
                        break :blk false;
                    }
                }

                break :blk true;
            },
            else => unreachable,
        },
        .@"union" => |info| blk: {
            if (info.tag_type != null) {
                const tag_a = meta.activeTag(a.*);
                const tag_b = meta.activeTag(b.*);

                if (tag_a != tag_b) break :blk false;

                inline for (fieldInfos(T)) |field| {
                    if (@field(T, field.name) == tag_a) {
                        break :blk deep_equal(
                            field.type,
                            &@field(a.*, field.name),
                            &@field(b.*, field.name),
                        );
                    }
                }
                unreachable;
            } else unreachable;
        },
        .optional => |info|
            if (a.* == null and b.* == null) true
            else if (a.* == null or b.* == null) false
            else deep_equal(info.child, &a.*.?, &b.*.?),
        .float => @abs(a.*-b.*) < 1e-9,
        .int, .bool, .@"enum" => a.* == b.*,
        .void => true,
        else => unreachable,
    };
}


/// Copy a parsed ZON value out of its parsing arena. Defaults are copied too,
/// so the returned value owns every pointer and can be freed field by field.
pub fn zon_clone(gpa: mem.Allocator, value: anytype) mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                const result = try gpa.allocWithOptions(info.child, value.len, .fromByteUnitsOptional(info.attrs.@"align"), info.sentinel());
                errdefer gpa.free(result);
                var initialized: usize = 0;
                errdefer for (result[0..initialized]) |item| zon_free(gpa, item, null);
                for (value, result) |item, *dest| {
                    dest.* = try zon_clone(gpa, item);
                    initialized += 1;
                }
                break :blk result;
            },
            .one => blk: {
                const result = try gpa.create(info.child);
                errdefer gpa.destroy(result);
                result.* = try zon_clone(gpa, value.*);
                break :blk result;
            },
            .many, .c => @compileError("unsupported ZON pointer"),
        },
        .@"struct" => blk: {
            var result = value;
            errdefer zon_free(gpa, result, &value);
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                @field(result, name) = try zon_clone(gpa, @field(value, name));
            }
            break :blk result;
        },
        .array => blk: {
            var result = value;
            errdefer zon_free(gpa, result, &value);
            for (value, &result) |item, *dest| dest.* = try zon_clone(gpa, item);
            break :blk result;
        },
        .@"union" => |info| if (info.tag_type != null) switch (value) {
            inline else => |payload, tag| @unionInit(T, @tagName(tag), try zon_clone(gpa, payload)),
        } else if (!requiresAllocator(T)) value else @compileError("unsupported ZON union"),
        .optional => if (value) |payload| try zon_clone(gpa, payload) else null,
        else => value,
    };
}

pub fn zon_free(gpa: mem.Allocator, value: anytype, default: ?*const @TypeOf(value)) void {
    const Value = @TypeOf(value);
    const info = @typeInfo(Value);

    switch (info) {
        .bool, .int, .float, .@"enum" => {},
        .pointer => |pointer| {
            switch (pointer.size) {
                .one => {
                    if (default) |ptr| {
                        if (value == ptr.*) return;
                    }

                    zon_free(gpa, value.*, null);
                    gpa.destroy(value);
                },
                .slice => {
                    if (default) |ptr| {
                        if (value.ptr == ptr.ptr) return;
                    }

                    for (value) |item| {
                        zon_free(gpa, item, null);
                    }
                    gpa.free(value);
                },
                .many, .c => comptime unreachable,
            }
        },
        .array => for (0.., value) |i, item| {
            zon_free(
                gpa,
                item,
                if (default) |ptr| &ptr.*[i] else null
            );
        },
        .@"struct" => inline for (fieldInfos(Value)) |field| {
            zon_free(
                gpa,
                @field(value, field.name),
                if (default) |ptr|
                    @ptrCast(@alignCast(&@field(ptr.*, field.name)))
                else
                    if (field.attrs.default_value_ptr) |ptr| @ptrCast(@alignCast(ptr))
                    else null
            );
        },
        .@"union" => |@"union"| if (@"union".tag_type == null) {
            if (comptime requiresAllocator(Value)) unreachable;
        } else switch (value) {
            inline else => |_, tag| {
                zon_free(
                    gpa,
                    @field(value, @tagName(tag)),
                    if (default) |ptr| (
                        if (meta.activeTag(ptr.*) == tag)
                            &@field(ptr.*, @tagName(tag))
                        else null
                    )
                    else null
                );
            },
        },
        .optional => if (value) |some| {
            zon_free(
                gpa,
                some,
                if (default) |ptr| (
                    if (ptr.* != null) &ptr.*.?
                    else null
                )
                else null
            );
        },
        .vector => |vector| for (0..vector.len) |i|
            zon_free(
                gpa,
                value[i],
                if (default) |ptr| &ptr.*[i] else null
            ),
        .void => {},
        else => comptime unreachable,
    }
}

fn requiresAllocator(T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| return array.len > 0 and requiresAllocator(array.child),
        .@"struct" => inline for (fieldInfos(T)) |field| {
            if (requiresAllocator(field.type)) {
                break true;
            }
        } else false,
        .@"union" => inline for (fieldInfos(T)) |field| {
            if (requiresAllocator(field.type)) {
                break true;
            }
        } else false,
        .optional => |optional| requiresAllocator(optional.child),
        .vector => |vector| return vector.len > 0 and requiresAllocator(vector.child),
        else => false,
    };
}

const CloneTest = struct {
    name: [:0]const u8 = "default",
    items: []const union(enum) { text: []const u8, none: void },
    optional: ?*const struct { value: []const u8 },
    fixed: [2][]const u8,
};

fn clone_test(gpa: mem.Allocator) !void {
    const original: CloneTest = .{
        .items = &.{ .{ .text = "hello" }, .none },
        .optional = &.{ .value = "nested" },
        .fixed = .{ "first", "second" },
    };
    const copy = try zon_clone(gpa, original);
    defer zon_free(gpa, copy, null);
    try std.testing.expectEqualDeep(original, copy);
    try std.testing.expect(copy.name.ptr != original.name.ptr);
    try std.testing.expectEqual(@as(u8, 0), copy.name[copy.name.len]);
    try std.testing.expect(copy.optional.? != original.optional.?);
}

test "ZON clone owns defaults, slices, tagged unions and optional pointers" {
    try clone_test(std.testing.allocator);
}

test "ZON clone frees partial results after allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, clone_test, .{});
}
