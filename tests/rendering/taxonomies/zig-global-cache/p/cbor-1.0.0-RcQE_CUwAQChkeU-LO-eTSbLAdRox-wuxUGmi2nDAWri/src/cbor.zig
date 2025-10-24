const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const native_endian = builtin.cpu.arch.endian();
const eql = std.mem.eql;
const bufPrint = std.fmt.bufPrint;
const maxInt = std.math.maxInt;
const minInt = std.math.minInt;
const json = std.json;
const fba = std.heap.FixedBufferAllocator;

pub const Error = error{
    IntegerTooLarge,
    IntegerTooSmall,
    InvalidType,
    TooShort,
    WriteFailed,
    OutOfMemory,
    InvalidFloatType,
    InvalidArrayType,
    InvalidMapType,
    InvalidPIntType,
    InvalidUnion,
    JsonIncompatibleType,
    NotAnObject,
    BadArrayAllocExtract,
};

pub const JsonEncodeError = (Error || error{
    UnsupportedType,
});

pub const JsonDecodeError = (Error || error{
    BufferUnderrun,
    SyntaxError,
    UnexpectedEndOfInput,
});

const cbor_magic_null: u8 = 0xf6;
const cbor_magic_true: u8 = 0xf5;
const cbor_magic_false: u8 = 0xf4;
const cbor_magic_float16: u8 = 0xf9;
const cbor_magic_float32: u8 = 0xfa;
const cbor_magic_float64: u8 = 0xfb;

const cbor_magic_type_array: u8 = 4;
const cbor_magic_type_map: u8 = 5;

const value_type = enum(u8) {
    number,
    bytes,
    string,
    array,
    map,
    tag,
    boolean,
    null,
    float,
    any,
    more,
    unknown,
};
pub const number = value_type.number;
pub const bytes = value_type.bytes;
pub const string = value_type.string;
pub const array = value_type.array;
pub const map = value_type.map;
pub const tag = value_type.tag;
pub const boolean = value_type.boolean;
pub const null_ = value_type.null;
pub const any = value_type.any;
pub const more = value_type.more;

const null_value_buf = [_]u8{0xF6};
pub const null_value: []const u8 = &null_value_buf;

pub fn isNull(val: []const u8) bool {
    return eql(u8, val, null_value);
}

fn isAny(value: anytype) bool {
    return if (comptime @TypeOf(value) == value_type) value == value_type.any else false;
}

fn isMore(value: anytype) bool {
    return if (comptime @TypeOf(value) == value_type) value == value_type.more else false;
}

fn write(writer: *Io.Writer, value: u8) Io.Writer.Error!void {
    _ = try writer.write(&[_]u8{value});
}

fn writeTypedVal(writer: *Io.Writer, type_: u8, value: u64) Io.Writer.Error!void {
    const t: u8 = type_ << 5;
    if (value < 24) {
        try write(writer, t | @as(u8, @truncate(value)));
    } else if (value < 256) {
        try write(writer, t | 24);
        try write(writer, @as(u8, @truncate(value)));
    } else if (value < 65536) {
        try write(writer, t | 25);
        try write(writer, @as(u8, @truncate(value >> 8)));
        try write(writer, @as(u8, @truncate(value)));
    } else if (value < 4294967296) {
        try write(writer, t | 26);
        try write(writer, @as(u8, @truncate(value >> 24)));
        try write(writer, @as(u8, @truncate(value >> 16)));
        try write(writer, @as(u8, @truncate(value >> 8)));
        try write(writer, @as(u8, @truncate(value)));
    } else {
        try write(writer, t | 27);
        try write(writer, @as(u8, @truncate(value >> 56)));
        try write(writer, @as(u8, @truncate(value >> 48)));
        try write(writer, @as(u8, @truncate(value >> 40)));
        try write(writer, @as(u8, @truncate(value >> 32)));
        try write(writer, @as(u8, @truncate(value >> 24)));
        try write(writer, @as(u8, @truncate(value >> 16)));
        try write(writer, @as(u8, @truncate(value >> 8)));
        try write(writer, @as(u8, @truncate(value)));
    }
}

pub fn writeArrayHeader(writer: *Io.Writer, sz: usize) Io.Writer.Error!void {
    return writeTypedVal(writer, cbor_magic_type_array, sz);
}

pub fn writeMapHeader(writer: *Io.Writer, sz: usize) Io.Writer.Error!void {
    return writeTypedVal(writer, cbor_magic_type_map, sz);
}

pub fn writeArray(writer: *Io.Writer, args: anytype) Io.Writer.Error!void {
    const args_type_info = @typeInfo(@TypeOf(args));
    if (args_type_info != .@"struct") @compileError("expected tuple or struct argument");
    const fields_info = args_type_info.@"struct".fields;
    try writeArrayHeader(writer, fields_info.len);
    inline for (fields_info) |field_info|
        try writeValue(writer, @field(args, field_info.name));
}

fn writeI64(writer: *Io.Writer, value: i64) Io.Writer.Error!void {
    return if (value < 0)
        writeTypedVal(writer, 1, @as(u64, @bitCast(-(value + 1))))
    else
        writeTypedVal(writer, 0, @as(u64, @bitCast(value)));
}

fn writeU64(writer: *Io.Writer, value: u64) Io.Writer.Error!void {
    return writeTypedVal(writer, 0, value);
}

fn writeF16(writer: *Io.Writer, value: f16) Io.Writer.Error!void {
    try write(writer, cbor_magic_float16);
    const value_bytes = std.mem.asBytes(&value);
    switch (native_endian) {
        .big => try write(writer, value_bytes),
        .little => {
            try write(writer, value_bytes[1]);
            try write(writer, value_bytes[0]);
        },
    }
}

fn writeF32(writer: *Io.Writer, value: f32) Io.Writer.Error!void {
    try write(writer, cbor_magic_float32);
    const value_bytes = std.mem.asBytes(&value);
    switch (native_endian) {
        .big => try write(writer, value_bytes),
        .little => {
            try write(writer, value_bytes[3]);
            try write(writer, value_bytes[2]);
            try write(writer, value_bytes[1]);
            try write(writer, value_bytes[0]);
        },
    }
}

fn writeF64(writer: *Io.Writer, value: f64) Io.Writer.Error!void {
    try write(writer, cbor_magic_float64);
    const value_bytes = std.mem.asBytes(&value);
    switch (native_endian) {
        .big => try write(writer, value_bytes),
        .little => {
            try write(writer, value_bytes[7]);
            try write(writer, value_bytes[6]);
            try write(writer, value_bytes[5]);
            try write(writer, value_bytes[4]);
            try write(writer, value_bytes[3]);
            try write(writer, value_bytes[2]);
            try write(writer, value_bytes[1]);
            try write(writer, value_bytes[0]);
        },
    }
}

fn writeString(writer: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try writeTypedVal(writer, 3, s.len);
    _ = try writer.write(s);
}

fn writeBool(writer: *Io.Writer, value: bool) Io.Writer.Error!void {
    return write(writer, if (value) cbor_magic_true else cbor_magic_false);
}

fn writeNull(writer: *Io.Writer) Io.Writer.Error!void {
    return write(writer, cbor_magic_null);
}

fn writeErrorset(writer: *Io.Writer, err: anyerror) Io.Writer.Error!void {
    var buf: [256]u8 = undefined;
    var fixed_writer: Io.Writer = .fixed(&buf);
    _ = fixed_writer.write("error.") catch @panic("cbor.writeErrorset failed!");
    _ = fixed_writer.write(@errorName(err)) catch @panic("cbor.writeErrorset failed!");
    return writeString(writer, fixed_writer.buffered());
}

fn writeEnum(writer: *Io.Writer, value: anytype) Io.Writer.Error!void {
    const T = @TypeOf(value);

    if (std.meta.hasFn(T, "cborEncode")) {
        return value.cborEncode(writer);
    }

    return writeString(writer, @tagName(value));
}

fn writeUnion(writer: *Io.Writer, value: anytype, info: std.builtin.Type.Union) Io.Writer.Error!void {
    const T = @TypeOf(value);

    if (std.meta.hasFn(T, "cborEncode")) {
        return value.cborEncode(writer);
    }
    if (info.tag_type) |TagType| {
        inline for (info.fields) |u_field| {
            const t = @field(TagType, u_field.name);
            if (value == t) {
                const Payload = std.meta.TagPayload(T, t);
                if (Payload != void) {
                    try writeArrayHeader(writer, 2);
                    try writeEnum(writer, value);
                    return try writeValue(writer, @field(value, u_field.name));
                } else {
                    try writeArrayHeader(writer, 1);
                    try writeEnum(writer, value);
                }

                return;
            }
        } else unreachable;
    } else {
        @compileError("cannot write untagged union '" ++ @typeName(T) ++ "' to cbor stream");
    }
}

pub fn writeValue(writer: *Io.Writer, value: anytype) Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => return if (T == u64) writeU64(writer, value) else writeI64(writer, @intCast(value)),
        .bool => return writeBool(writer, value),
        .optional => return if (value) |v| writeValue(writer, v) else writeNull(writer),
        .error_union => return if (value) |v| writeValue(writer, v) else |err| writeValue(writer, err),
        .error_set => return writeErrorset(writer, value),
        .@"union" => |info| return writeUnion(writer, value, info),
        .@"struct" => |info| {
            if (std.meta.hasFn(T, "cborEncode")) {
                return value.cborEncode(writer);
            }
            if (info.is_tuple) {
                if (info.fields.len == 0) return writeNull(writer);
                try writeArrayHeader(writer, info.fields.len);
                inline for (info.fields) |f|
                    try writeValue(writer, @field(value, f.name));
            } else {
                if (info.fields.len == 0) return writeNull(writer);
                try writeMapHeader(writer, info.fields.len);
                inline for (info.fields) |f| {
                    try writeString(writer, f.name);
                    try writeValue(writer, @field(value, f.name));
                }
            }
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => return writeValue(writer, value.*),
            .many, .c => @compileError("cannot write type '" ++ @typeName(T) ++ "' to cbor stream"),
            .slice => {
                if (ptr_info.child == u8) return writeString(writer, value);
                if (value.len == 0) return writeNull(writer);
                try writeArrayHeader(writer, value.len);
                for (value) |elem|
                    try writeValue(writer, elem);
            },
        },
        .array => |info| {
            if (info.child == u8) return writeString(writer, &value);
            if (value.len == 0) return writeNull(writer);
            try writeArrayHeader(writer, value.len);
            for (value) |elem|
                try writeValue(writer, elem);
        },
        .vector => |info| {
            try writeArrayHeader(writer, info.len);
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                try writeValue(writer, value[i]);
            }
        },
        .null => try writeNull(writer),
        .float => |info| switch (info.bits) {
            16 => try writeF16(writer, value),
            32 => try writeF32(writer, value),
            64 => try writeF64(writer, value),
            else => @compileError("cannot write type '" ++ @typeName(T) ++ "' to cbor stream"),
        },
        .@"enum" => {
            if (std.meta.hasFn(T, "cborEncode")) {
                return value.cborEncode(writer);
            }
            return writeString(writer, @tagName(value));
        },
        else => @compileError("cannot write type '" ++ @typeName(T) ++ "' to cbor stream"),
    }
}

pub fn fmt(buf: []u8, value: anytype) []const u8 {
    var writer: Io.Writer = .fixed(buf);
    writeValue(&writer, value) catch unreachable;
    return writer.buffered();
}

const CborType = struct { type: u8, minor: u5, major: u3 };

pub fn decodeType(iter: *[]const u8) error{TooShort}!CborType {
    if (iter.len < 1)
        return error.TooShort;
    const type_: u8 = iter.*[0];
    const bits: packed struct { minor: u5, major: u3 } = @bitCast(type_);
    iter.* = iter.*[1..];
    return .{ .type = type_, .minor = bits.minor, .major = bits.major };
}

fn decodeUIntLengthRecurse(iter: *[]const u8, length: usize, acc: u64) error{TooShort}!u64 {
    if (iter.len < 1)
        return error.TooShort;
    const v: u8 = iter.*[0];
    iter.* = iter.*[1..];
    var i = acc | v;
    if (length == 1)
        return i;
    i <<= 8;
    // return @call(.always_tail, decodeUIntLengthRecurse, .{ iter, length - 1, i });  FIXME: @call(.always_tail) seems broken as of 0.11.0-dev.2964+e9cbdb2cf
    return decodeUIntLengthRecurse(iter, length - 1, i);
}

fn decodeUIntLength(iter: *[]const u8, length: usize) !u64 {
    return decodeUIntLengthRecurse(iter, length, 0);
}

fn decodePInt(iter: *[]const u8, minor: u5) error{ TooShort, InvalidPIntType }!u64 {
    if (minor < 24) return minor;
    return switch (minor) {
        24 => decodeUIntLength(iter, 1), // 1 byte
        25 => decodeUIntLength(iter, 2), // 2 byte
        26 => decodeUIntLength(iter, 4), // 4 byte
        27 => decodeUIntLength(iter, 8), // 8 byte
        else => error.InvalidPIntType,
    };
}

fn decodeNInt(iter: *[]const u8, minor: u5) Error!i64 {
    return -@as(i64, @intCast(try decodePInt(iter, minor) + 1));
}

pub fn decodeMapHeader(iter: *[]const u8) error{ TooShort, InvalidMapType, InvalidPIntType }!usize {
    const t = try decodeType(iter);
    if (t.type == cbor_magic_null)
        return 0;
    if (t.major != 5)
        return error.InvalidMapType;
    return @intCast(try decodePInt(iter, t.minor));
}

pub fn decodeArrayHeader(iter: *[]const u8) error{ TooShort, InvalidArrayType, InvalidPIntType }!usize {
    const t = try decodeType(iter);
    if (t.type == cbor_magic_null)
        return 0;
    if (t.major != 4)
        return error.InvalidArrayType;
    return @intCast(try decodePInt(iter, t.minor));
}

fn decodeString(iter_: *[]const u8, minor: u5) Error![]const u8 {
    var iter = iter_.*;
    const len: usize = @intCast(try decodePInt(&iter, minor));
    if (iter.len < len)
        return error.TooShort;
    const s = iter[0..len];
    iter = iter[len..];
    iter_.* = iter;
    return s;
}

fn decodeBytes(iter: *[]const u8, minor: u5) Error![]const u8 {
    return decodeString(iter, minor);
}

fn decodeJsonArray(iter_: *[]const u8, minor: u5, arr: *json.Array) Error!bool {
    var iter = iter_.*;
    var n = try decodePInt(&iter, minor);
    while (n > 0) {
        const value = try arr.addOne();
        if (!try matchJsonValue(&iter, value, arr.allocator))
            return false;
        n -= 1;
    }
    iter_.* = iter;
    return true;
}

fn decodeJsonObject(iter_: *[]const u8, minor: u5, obj: *json.ObjectMap) Error!bool {
    var iter = iter_.*;
    var n = try decodePInt(&iter, minor);
    while (n > 0) {
        var key: []const u8 = undefined;
        var value: json.Value = .null;

        if (!try matchString(&iter, &key))
            return false;
        if (!try matchJsonValue(&iter, &value, obj.allocator))
            return false;

        _ = try obj.getOrPutValue(key, value);
        n -= 1;
    }
    iter_.* = iter;
    return true;
}

fn decodeFloat(comptime T: type, iter_: *[]const u8, t: CborType) Error!T {
    var v: T = undefined;
    var iter = iter_.*;
    switch (t.type) {
        cbor_magic_float16 => {
            if (iter.len < 2) return error.TooShort;
            var f: f16 = undefined;
            var f_bytes = std.mem.asBytes(&f);
            switch (native_endian) {
                .big => @memcpy(f_bytes, iter[0..2]),
                .little => {
                    f_bytes[0] = iter[1];
                    f_bytes[1] = iter[0];
                },
            }
            v = @floatCast(f);
            iter = iter[2..];
        },
        cbor_magic_float32 => {
            if (iter.len < 4) return error.TooShort;
            var f: f32 = undefined;
            var f_bytes = std.mem.asBytes(&f);
            switch (native_endian) {
                .big => @memcpy(f_bytes, iter[0..4]),
                .little => {
                    f_bytes[0] = iter[3];
                    f_bytes[1] = iter[2];
                    f_bytes[2] = iter[1];
                    f_bytes[3] = iter[0];
                },
            }
            v = @floatCast(f);
            iter = iter[4..];
        },
        cbor_magic_float64 => {
            if (iter.len < 8) return error.TooShort;
            var f: f64 = undefined;
            var f_bytes = std.mem.asBytes(&f);
            switch (native_endian) {
                .big => @memcpy(f_bytes, iter[0..8]),
                .little => {
                    f_bytes[0] = iter[7];
                    f_bytes[1] = iter[6];
                    f_bytes[2] = iter[5];
                    f_bytes[3] = iter[4];
                    f_bytes[4] = iter[3];
                    f_bytes[5] = iter[2];
                    f_bytes[6] = iter[1];
                    f_bytes[7] = iter[0];
                },
            }
            v = @floatCast(f);
            iter = iter[8..];
        },
        else => return error.InvalidFloatType,
    }
    iter_.* = iter;
    return v;
}

pub fn matchInt(comptime T: type, iter_: *[]const u8, val: *T) Error!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    val.* = switch (t.major) {
        0 => blk: { // positive integer
            const v = try decodePInt(&iter, t.minor);
            if (v > maxInt(T))
                return error.IntegerTooLarge;
            break :blk @intCast(v);
        },
        1 => blk: { // negative integer
            const v = try decodeNInt(&iter, t.minor);
            if (v < minInt(T))
                return error.IntegerTooSmall;
            break :blk @intCast(v);
        },

        else => return false,
    };
    iter_.* = iter;
    return true;
}

pub fn matchIntValue(comptime T: type, iter: *[]const u8, val: T) Error!bool {
    var v: T = 0;
    return if (try matchInt(T, iter, &v)) v == val else false;
}

pub fn matchNull(iter_: *[]const u8) Error!bool {
    var iter = iter_.*;

    if (iter.len > 0 and iter[0] == cbor_magic_null) {
        iter_.* = iter[1..];
        return true;
    }

    return false;
}

pub fn matchBool(iter_: *[]const u8, v: *bool) Error!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    if (t.major == 7) { // special
        if (t.type == cbor_magic_false) {
            v.* = false;
            iter_.* = iter;
            return true;
        }
        if (t.type == cbor_magic_true) {
            v.* = true;
            iter_.* = iter;
            return true;
        }
    }
    return false;
}

fn matchBoolValue(iter: *[]const u8, val: bool) Error!bool {
    var v: bool = false;
    return if (try matchBool(iter, &v)) v == val else false;
}

fn matchFloat(comptime T: type, iter_: *[]const u8, v: *T) Error!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    v.* = decodeFloat(T, &iter, t) catch |e| switch (e) {
        error.InvalidType => return false,
        else => return e,
    };
    iter_.* = iter;
    return true;
}

fn matchFloatValue(comptime T: type, iter: *[]const u8, val: T) Error!bool {
    var v: T = 0.0;
    return if (try matchFloat(T, iter, &v)) v == val else false;
}

pub fn matchEnum(comptime T: type, iter_: *[]const u8, val: *T) Error!bool {
    var iter = iter_.*;
    var str: []const u8 = undefined;
    if (try matchString(&iter, &str)) if (std.meta.stringToEnum(T, str)) |val_| {
        val.* = val_;
        iter_.* = iter;
        return true;
    };
    return false;
}

fn matchEnumValue(comptime T: type, iter: *[]const u8, val: T) Error!bool {
    return matchStringValue(iter, @tagName(val));
}

fn matchUnionScalar(comptime T: type, iter_: *[]const u8, val_: *T) Error!bool {
    var iter = iter_.*;

    const n = decodeArrayHeader(&iter) catch |e| switch (e) {
        error.InvalidArrayType => return false,
        error.InvalidPIntType => return e,
        error.TooShort => return e,
    };
    if (n == 0) return false;

    const TagType = std.meta.Tag(T);
    var unionTag: TagType = undefined;
    if (!try matchEnum(TagType, &iter, &unionTag)) return false;

    inline for (comptime std.meta.tags(TagType)) |t_| {
        if (t_ == unionTag) {
            const Payload = std.meta.TagPayload(T, t_);

            if (Payload == void) {
                if (n != 1) return false;
                val_.* = t_;
                iter_.* = iter;
                return true;
            } else {
                if (n != 2) return false;
                var val: Payload = undefined;
                if (try matchValue(&iter, extract(&val))) {
                    val_.* = @unionInit(T, @tagName(t_), val);
                    iter_.* = iter;
                    return true;
                }
            }
        }
    }

    return false;
}

fn matchUnionAlloc(comptime T: type, iter_: *[]const u8, val_: *T, allocator: std.mem.Allocator) Error!bool {
    var iter = iter_.*;

    const n = decodeArrayHeader(&iter) catch |e| switch (e) {
        error.InvalidArrayType => return false,
        error.InvalidPIntType => return e,
        error.TooShort => return e,
    };
    if (n == 0) return false;

    const TagType = std.meta.Tag(T);
    var unionTag: TagType = undefined;
    if (!try matchEnum(TagType, &iter, &unionTag)) return false;

    inline for (comptime std.meta.tags(TagType)) |t_| {
        if (t_ == unionTag) {
            const Payload = std.meta.TagPayload(T, t_);

            if (Payload == void) {
                if (n != 1) return false;
                val_.* = t_;
                iter_.* = iter;
                return true;
            } else {
                if (n != 2) return false;
                var val: Payload = undefined;
                if (try matchValue(&iter, extractAlloc(&val, allocator))) {
                    val_.* = @unionInit(T, @tagName(t_), val);
                    iter_.* = iter;
                    return true;
                }
            }
        }
    }

    return false;
}

fn matchUnionValue(comptime T: type, iter_: *[]const u8, val: T) Error!bool {
    switch (val) {
        inline else => |v, t| {
            var iter = iter_.*;

            const n = decodeArrayHeader(&iter) catch |e| switch (e) {
                error.InvalidArrayType => return false,
                error.InvalidPIntType => return e,
                error.TooShort => return e,
            };
            if (n == 0) return false;

            if (!try matchEnumValue(std.meta.Tag(T), &iter, t)) return false;

            if (std.meta.TagPayload(T, t) != void) {
                if (n != 2) return false;
                if (!try matchValue(&iter, v)) return false;
            } else {
                if (n != 1) return false;
            }

            iter_.* = iter;
            return true;
        },
    }
}

fn matchStructScalar(comptime T: type, iter_: *[]const u8, val_: *T) Error!bool {
    var iter = iter_.*;
    const info = @typeInfo(T).@"struct";

    const len = decodeMapHeader(&iter) catch |err| switch (err) {
        error.TooShort => return false,
        error.InvalidMapType => return err,
        error.InvalidPIntType => return err,
    };

    if (len != info.fields.len) return false;

    if (info.fields.len == 0) {
        iter_.* = iter;
        val_.* = .{};
        return true;
    }

    var val: T = undefined;

    fields: for (0..info.fields.len) |_| {
        var fieldName: []const u8 = undefined;
        if (!try matchString(&iter, &fieldName)) return false;

        inline for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, fieldName)) {
                var fieldVal: @FieldType(T, f.name) = undefined;
                if (!try matchValue(&iter, extract(&fieldVal))) return false;
                @field(val, f.name) = fieldVal;
                continue :fields;
            }
        }

        return false;
    }

    val_.* = val;
    iter_.* = iter;

    return true;
}

fn matchStructAlloc(comptime T: type, iter_: *[]const u8, val_: *T, allocator: std.mem.Allocator) Error!bool {
    var iter = iter_.*;
    const info = @typeInfo(T).@"struct";

    const len = decodeMapHeader(&iter) catch |err| switch (err) {
        error.TooShort => return false,
        error.InvalidMapType => return err,
        error.InvalidPIntType => return err,
    };

    if (len != info.fields.len) return false;

    if (info.fields.len == 0) {
        iter_.* = iter;
        val_.* = .{};
        return true;
    }

    var val: T = undefined;

    for (0..info.fields.len) |_| {
        var fieldName: []const u8 = undefined;
        if (!try matchString(&iter, &fieldName)) return false;

        inline for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, fieldName)) {
                var fieldVal: @FieldType(T, f.name) = undefined;
                if (!try matchValue(&iter, extractAlloc(&fieldVal, allocator))) return false;
                @field(val, f.name) = fieldVal;
                break;
            }
        } else return false;
    }

    val_.* = val;
    iter_.* = iter;

    return true;
}

fn skipString(iter: *[]const u8, minor: u5) Error!void {
    const len: usize = @intCast(try decodePInt(iter, minor));
    if (iter.len < len)
        return error.TooShort;
    iter.* = iter.*[len..];
}

fn skipBytes(iter: *[]const u8, minor: u5) Error!void {
    return skipString(iter, minor);
}

fn skipArray(iter: *[]const u8, minor: u5) Error!void {
    var len = try decodePInt(iter, minor);
    while (len > 0) {
        try skipValue(iter);
        len -= 1;
    }
}

fn skipMap(iter: *[]const u8, minor: u5) Error!void {
    var len = try decodePInt(iter, minor);
    len *= 2;
    while (len > 0) {
        try skipValue(iter);
        len -= 1;
    }
}

pub fn skipValue(iter: *[]const u8) Error!void {
    try skipValueType(iter, try decodeType(iter));
}

fn skipValueType(iter: *[]const u8, t: CborType) Error!void {
    switch (t.major) {
        0 => { // positive integer
            _ = try decodePInt(iter, t.minor);
        },
        1 => { // negative integer
            _ = try decodeNInt(iter, t.minor);
        },
        2 => { // bytes
            try skipBytes(iter, t.minor);
        },
        3 => { // string
            try skipString(iter, t.minor);
        },
        4 => { // array
            try skipArray(iter, t.minor);
        },
        5 => { // map
            try skipMap(iter, t.minor);
        },
        6 => { // tag
            return error.InvalidType;
        },
        7 => switch (t.type) { // special
            cbor_magic_null, cbor_magic_false, cbor_magic_true => return,
            cbor_magic_float16 => iter.* = iter.*[2..],
            cbor_magic_float32 => iter.* = iter.*[4..],
            cbor_magic_float64 => iter.* = iter.*[8..],
            else => return error.InvalidType,
        },
    }
}

fn matchType(iter_: *[]const u8, v: *value_type) Error!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    try skipValueType(&iter, t);
    switch (t.major) {
        0, 1 => v.* = value_type.number, // positive integer or negative integer
        2 => v.* = value_type.bytes, // bytes
        3 => v.* = value_type.string, // string
        4 => v.* = value_type.array, // array
        5 => v.* = value_type.map, // map
        7 => switch (t.type) { // special
            cbor_magic_null => v.* = value_type.null,
            cbor_magic_false, cbor_magic_true => v.* = value_type.boolean,
            cbor_magic_float16, cbor_magic_float32, cbor_magic_float64 => v.* = value_type.float,
            else => return false,
        },
        else => return false,
    }
    iter_.* = iter;
    return true;
}

fn matchValueType(iter: *[]const u8, t: value_type) Error!bool {
    var v: value_type = value_type.unknown;
    return if (try matchType(iter, &v)) (t == value_type.any or t == v) else false;
}

pub fn matchString(iter_: *[]const u8, val: *[]const u8) Error!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    val.* = switch (t.major) {
        2 => try decodeBytes(&iter, t.minor), // bytes
        3 => try decodeString(&iter, t.minor), // string
        else => return false,
    };
    iter_.* = iter;
    return true;
}

fn matchStringValue(iter: *[]const u8, lit: []const u8) Error!bool {
    var val: []const u8 = undefined;
    return if (try matchString(iter, &val)) eql(u8, val, lit) else false;
}

fn matchError(comptime T: type) noreturn {
    @compileError("cannot match type '" ++ @typeName(T) ++ "' to cbor stream");
}

pub fn matchValue(iter: *[]const u8, value: anytype) Error!bool {
    if (@TypeOf(value) == value_type)
        return matchValueType(iter, value);
    const T = comptime @TypeOf(value);
    if (comptime isExtractor(T))
        return value.extract(iter);
    return switch (comptime @typeInfo(T)) {
        .int => return matchIntValue(T, iter, value),
        .comptime_int => return matchIntValue(i64, iter, value),
        .bool => matchBoolValue(iter, value),
        .pointer => |info| switch (info.size) {
            .one => matchValue(iter, value.*),
            .many, .c => matchError(T),
            .slice => if (info.child == u8) matchStringValue(iter, value) else matchArray(iter, value, info),
        },
        .optional => if (value) |v| matchValue(iter, v) else matchNull(iter),
        .@"struct" => |info| if (info.is_tuple)
            matchArray(iter, value, info)
            // TODO: Add case for matching struct here
        else
            matchError(T),
        .array => |info| if (info.child == u8) matchStringValue(iter, &value) else matchArray(iter, value, info),
        .float => matchFloatValue(T, iter, value),
        .comptime_float => matchFloatValue(f64, iter, value),
        .@"enum" => matchEnumValue(T, iter, value),
        .@"union" => |info| if (info.tag_type) |_|
            matchUnionValue(T, iter, value)
        else
            @compileError("cannot match value type '" ++ @typeName(T) ++ "' to cbor stream"),
        else => @compileError("cannot match value type '" ++ @typeName(T) ++ "' to cbor stream"),
    };
}

fn matchJsonValue(iter_: *[]const u8, v: *json.Value, a: std.mem.Allocator) Error!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    const ret = switch (t.major) {
        0 => ret: { // positive integer
            v.* = json.Value{ .integer = @intCast(try decodePInt(&iter, t.minor)) };
            break :ret true;
        },
        1 => ret: { // negative integer
            v.* = json.Value{ .integer = try decodeNInt(&iter, t.minor) };
            break :ret true;
        },
        2 => ret: { // bytes
            break :ret false;
        },
        3 => ret: { // string
            v.* = json.Value{ .string = try decodeString(&iter, t.minor) };
            break :ret true;
        },
        4 => ret: { // array
            v.* = json.Value{ .array = json.Array.init(a) };
            break :ret try decodeJsonArray(&iter, t.minor, &v.array);
        },
        5 => ret: { // map
            v.* = json.Value{ .object = json.ObjectMap.init(a) };
            break :ret try decodeJsonObject(&iter, t.minor, &v.object);
        },
        6 => ret: { // tag
            break :ret false;
        },
        7 => ret: { // special
            switch (t.type) {
                cbor_magic_false => {
                    v.* = json.Value{ .bool = false };
                    break :ret true;
                },
                cbor_magic_true => {
                    v.* = json.Value{ .bool = true };
                    break :ret true;
                },
                cbor_magic_null => {
                    v.* = json.Value{ .null = {} };
                    break :ret true;
                },
                else => break :ret false,
            }
        },
    };
    if (ret) iter_.* = iter;
    return ret;
}

fn matchArrayMore(iter_: *[]const u8, n_: u64) Error!bool {
    var iter = iter_.*;
    var n = n_;
    while (n > 0) {
        if (!try matchValue(&iter, value_type.any))
            return false;
        n -= 1;
    }
    iter_.* = iter;
    return true;
}

fn matchArray(iter_: *[]const u8, arr: anytype, info: anytype) Error!bool {
    var iter = iter_.*;
    var n = decodeArrayHeader(&iter) catch |e| switch (e) {
        error.InvalidArrayType => return false,
        error.InvalidPIntType => return e,
        error.TooShort => return e,
    };
    inline for (info.fields) |f| {
        const value = @field(arr, f.name);
        if (isMore(value))
            break;
    } else if (info.fields.len != n)
        return false;
    inline for (info.fields) |f| {
        const value = @field(arr, f.name);
        if (isMore(value))
            if (try matchArrayMore(&iter, n)) {
                iter_.* = iter;
                return true;
            } else {
                return false;
            };
        if (n == 0) return false;
        const matched = try matchValue(&iter, @field(arr, f.name));
        if (!matched) return false;
        n -= 1;
    }
    if (n == 0) iter_.* = iter;
    return n == 0;
}

fn matchArrayScalar(iter: *[]const u8, arr: anytype) Error!bool {
    var i: usize = 0;
    var n = try decodeArrayHeader(iter);
    if (n != arr.len) return false;
    while (n > 0) : (n -= 1) {
        if (!(matchValue(iter, extract(&arr[i])) catch return false))
            return false;
        i += 1;
    }
    return true;
}

fn matchArrayAlloc(iter: *[]const u8, element_type: type, arr: anytype, allocator: std.mem.Allocator) Error!bool {
    var arr_: std.ArrayListUnmanaged(element_type) = .empty;
    errdefer arr_.deinit(allocator);
    var n = try decodeArrayHeader(iter);
    while (n > 0) : (n -= 1) {
        var element: element_type = undefined;
        const extractor = GenericExtractorAlloc(element_type).init(&element, allocator);
        if (try extractor.extract(iter)) {
            (try arr_.addOne(allocator)).* = element;
        } else return error.BadArrayAllocExtract;
    }
    arr.* = try arr_.toOwnedSlice(allocator);
    return true;
}

fn matchJsonObject(iter_: *[]const u8, obj: *json.ObjectMap) !bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    if (t.type == cbor_magic_null)
        return true;
    if (t.major != 5)
        return error.NotAnObject;
    const ret = try decodeJsonObject(&iter, t.minor, obj);
    if (ret) iter_.* = iter;
    return ret;
}

pub fn match(buf: []const u8, pattern: anytype) Error!bool {
    var iter: []const u8 = buf;
    return matchValue(&iter, pattern);
}

fn extractError(comptime T: type) noreturn {
    @compileError("cannot extract type '" ++ @typeName(T) ++ "' from a cbor stream");
}

fn extractErrorAlloc(comptime T: type) noreturn {
    @compileError("extracting type '" ++ @typeName(T) ++ "' from a cbor stream requires an allocating extractor, use extractAlloc");
}

fn hasExtractorTag(info: anytype) bool {
    if (info.is_tuple) return false;
    inline for (info.decls) |decl| {
        if (comptime eql(u8, decl.name, "EXTRACTOR_TAG"))
            return true;
    }
    return false;
}

fn isExtractor(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .@"struct" => |info| hasExtractorTag(info),
        else => false,
    };
}

fn ExtractDef(comptime T: type) type {
    return fn (*T, *[]const u8) Error!bool;
}

fn hasExtractMethod(T: type, info: anytype) bool {
    const result = blk: {
        if (info.is_tuple) break :blk false;
        for (info.decls) |decl| {
            if (std.mem.eql(u8, decl.name, "cborExtract") and @TypeOf(@field(T, decl.name)) == ExtractDef(T))
                break :blk true;
        }
        break :blk false;
    };
    // @compileLog("hasExtractMethod", @typeName(T), result);
    return result;
}

pub fn isExtractable(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .@"struct" => |info| hasExtractMethod(T, info),
        .@"enum" => |info| hasExtractMethod(T, info),
        .@"union" => |info| hasExtractMethod(T, info),
        else => false,
    };
}

fn ExtractAllocDef(comptime T: type) type {
    return fn (*T, *[]const u8, std.mem.Allocator) Error!bool;
}

fn hasExtractMethodAlloc(T: type, info: anytype) bool {
    const result = blk: {
        if (@hasField(@TypeOf(info), "is_tuple") and info.is_tuple) break :blk false;
        for (info.decls) |decl| {
            if (std.mem.eql(u8, decl.name, "cborExtract") and @TypeOf(@field(T, decl.name)) == ExtractAllocDef(T))
                break :blk true;
        }
        break :blk false;
    };
    // @compileLog("hasExtractMethodAlloc", @typeName(T), result);
    return result;
}

pub fn isExtractableAlloc(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .@"struct" => |info| hasExtractMethodAlloc(T, info),
        .@"enum" => |info| hasExtractMethodAlloc(T, info),
        .@"union" => |info| hasExtractMethodAlloc(T, info),
        else => false,
    };
}

fn GenericExtractorAlloc(T: type) type {
    return struct {
        dest: *T,
        allocator: std.mem.Allocator,
        const Self = @This();
        pub const EXTRACTOR_TAG = struct {};

        pub fn init(dest: *T, allocator: std.mem.Allocator) Self {
            return .{ .dest = dest, .allocator = allocator };
        }

        pub fn extract(self: Self, iter: *[]const u8) Error!bool {
            if (comptime isExtractableAlloc(T)) {
                return self.dest.cborExtract(iter, self.allocator);
            } else {
                switch (comptime @typeInfo(T)) {
                    .int, .comptime_int => return matchInt(T, iter, self.dest),
                    .bool => return matchBool(iter, self.dest),
                    .pointer => |ptr_info| switch (ptr_info.size) {
                        .slice => {
                            if (ptr_info.child == u8)
                                return matchString(iter, self.dest)
                            else
                                return matchArrayAlloc(iter, ptr_info.child, self.dest, self.allocator);
                        },
                        else => extractError(T),
                    },
                    .optional => |opt_info| {
                        var nested: opt_info.child = undefined;
                        const extractor = GenericExtractorAlloc(opt_info.child).init(&nested, self.allocator);
                        if (try extractor.extract(iter)) {
                            self.dest.* = nested;
                            return true;
                        }
                        return false;
                    },
                    .float => return matchFloat(T, iter, self.dest),
                    .@"enum" => return matchEnum(T, iter, self.dest),
                    .array => return matchArrayScalar(iter, self.dest),
                    else => if (@hasDecl(T, "cborExtract")) {
                        return self.dest.cborExtract(iter);
                    } else switch (comptime @typeInfo(T)) {
                        .@"union" => return matchUnionAlloc(T, iter, self.dest, self.allocator),
                        .@"struct" => return matchStructAlloc(T, iter, self.dest, self.allocator),
                        else => @compileError(@typeName(T) ++ " (" ++ @tagName(@typeInfo(T)) ++ ") is and unsupported or invalid type for cbor extract, or implement cborExtract function"),
                    },
                }
            }
        }
    };
}

const JsonValueExtractor = struct {
    dest: *T,
    const Self = @This();
    pub const EXTRACTOR_TAG = struct {};
    const T = json.Value;

    pub fn init(dest: *T) Self {
        return .{ .dest = dest };
    }

    pub fn extract(self: Self, iter: *[]const u8) Error!bool {
        var null_heap_: [0]u8 = undefined;
        var heap = fba.init(&null_heap_);
        return matchJsonValue(iter, self.dest, heap.allocator());
    }
};

const JsonObjectExtractor = struct {
    dest: *T,
    const Self = @This();
    pub const EXTRACTOR_TAG = struct {};
    const T = json.ObjectMap;

    pub fn init(dest: *T) Self {
        return .{ .dest = dest };
    }

    pub fn extract(self: Self, iter: *[]const u8) Error!bool {
        return matchJsonObject(iter, self.dest);
    }
};

fn Extractor(comptime T: type) type {
    if (T == json.Value)
        return JsonValueExtractor;
    if (T == json.ObjectMap)
        return JsonObjectExtractor;
    return struct {
        dest: *T,
        const Self = @This();
        pub const EXTRACTOR_TAG = struct {};

        pub fn init(dest: *T) Self {
            return .{ .dest = dest };
        }

        pub fn extract(self: Self, iter: *[]const u8) Error!bool {
            switch (comptime @typeInfo(T)) {
                .int, .comptime_int => return matchInt(T, iter, self.dest),
                .bool => return matchBool(iter, self.dest),
                .pointer => |ptr_info| switch (ptr_info.size) {
                    .slice => {
                        if (ptr_info.child == u8) return matchString(iter, self.dest) else extractError(T);
                    },
                    else => extractError(T),
                },
                .optional => |opt_info| {
                    var nested: opt_info.child = undefined;
                    if (try matchNull(iter)) {
                        self.dest.* = null;
                        return true;
                    }
                    const extractor = Extractor(opt_info.child).init(&nested);
                    if (try extractor.extract(iter)) {
                        self.dest.* = nested;
                        return true;
                    }
                    return false;
                },
                .float => return matchFloat(T, iter, self.dest),
                .@"enum" => return matchEnum(T, iter, self.dest),
                .array => return matchArrayScalar(iter, self.dest),
                else => if (@hasDecl(T, "cborExtract")) {
                    return self.dest.cborExtract(iter);
                } else switch (comptime @typeInfo(T)) {
                    .@"union" => return matchUnionScalar(T, iter, self.dest),
                    .@"struct" => return matchStructScalar(T, iter, self.dest),
                    else => @compileError("cannot extract type " ++ @typeName(T)),
                },
            }
        }
    };
}

fn ExtractorType(comptime T: type) type {
    const T_type_info = @typeInfo(T);
    if (T_type_info != .pointer) @compileError("extract requires a pointer argument");
    return if (isExtractableAlloc(T_type_info.pointer.child))
        extractErrorAlloc(T_type_info.pointer.child)
    else
        Extractor(T_type_info.pointer.child);
}

pub fn extract(dest: anytype) ExtractorType(@TypeOf(dest)) {
    comptime {
        if (!isExtractor(ExtractorType(@TypeOf(dest))))
            @compileError("isExtractor self check failed for " ++ @typeName(ExtractorType(@TypeOf(dest))));
    }
    return ExtractorType(@TypeOf(dest)).init(dest);
}

fn ExtractorTypeAlloc(comptime T: type) type {
    const T_type_info = @typeInfo(T);
    if (T_type_info != .pointer) @compileError("extractAlloc requires a pointer argument");
    // @compileLog("ExtractorTypeAlloc", @typeName(T), isExtractableAlloc(T_type_info.pointer.child));
    return GenericExtractorAlloc(T_type_info.pointer.child);
}

pub fn extractAlloc(dest: anytype, allocator: std.mem.Allocator) ExtractorTypeAlloc(@TypeOf(dest)) {
    comptime {
        if (!isExtractor(ExtractorTypeAlloc(@TypeOf(dest))))
            @compileError("isExtractor self check failed for " ++ @typeName(ExtractorTypeAlloc(@TypeOf(dest))));
    }
    return ExtractorTypeAlloc(@TypeOf(dest)).init(dest, allocator);
}

const CborExtractor = struct {
    dest: *[]const u8,
    const Self = @This();
    pub const EXTRACTOR_TAG = struct {};

    pub fn init(dest: *[]const u8) Self {
        return .{ .dest = dest };
    }

    pub fn extract(self: Self, iter: *[]const u8) Error!bool {
        const b = iter.*;
        try skipValue(iter);
        self.dest.* = b[0..(b.len - iter.len)];
        return true;
    }
};

pub fn extract_cbor(dest: *[]const u8) CborExtractor {
    return CborExtractor.init(dest);
}

pub const JsonWriter = struct {
    fn jsonWriteArray(w: *json.Stringify, iter: *[]const u8, minor: u5) !void {
        var count = try decodePInt(iter, minor);
        try w.beginArray();
        while (count > 0) : (count -= 1) {
            try jsonWriteValue(w, iter);
        }
        try w.endArray();
    }

    fn jsonWriteMap(w: *json.Stringify, iter: *[]const u8, minor: u5) !void {
        var count = try decodePInt(iter, minor);
        try w.beginObject();
        while (count > 0) : (count -= 1) {
            const t = try decodeType(iter);
            if (t.major != 3) return error.InvalidType;
            try w.objectField(try decodeString(iter, t.minor));
            try jsonWriteValue(w, iter);
        }
        try w.endObject();
    }

    pub fn jsonWriteValue(w: *json.Stringify, iter: *[]const u8) (JsonEncodeError || Io.Writer.Error)!void {
        const t = try decodeType(iter);
        switch (t.type) {
            cbor_magic_false => return w.write(false),
            cbor_magic_true => return w.write(true),
            cbor_magic_null => return w.write(null),
            cbor_magic_float16 => return w.write(try decodeFloat(f16, iter, t)),
            cbor_magic_float32 => return w.write(try decodeFloat(f32, iter, t)),
            cbor_magic_float64 => return w.write(try decodeFloat(f64, iter, t)),
            else => {},
        }
        return switch (t.major) {
            0 => w.write(try decodePInt(iter, t.minor)), // positive integer
            1 => w.write(try decodeNInt(iter, t.minor)), // negative integer
            2 => error.UnsupportedType, // bytes
            3 => w.write(try decodeString(iter, t.minor)), // string
            4 => jsonWriteArray(w, iter, t.minor), // array
            5 => jsonWriteMap(w, iter, t.minor), // map
            else => error.JsonIncompatibleType,
        };
    }
};

pub fn toJson(cbor_buf: []const u8, json_buf: []u8) (JsonEncodeError || Io.Writer.Error)![]const u8 {
    var writer: Io.Writer = .fixed(json_buf);
    var s: json.Stringify = .{ .writer = &writer };
    var iter: []const u8 = cbor_buf;
    try JsonWriter.jsonWriteValue(&s, &iter);
    return writer.buffered();
}

pub fn toJsonWriter(cbor_buf: []const u8, writer: *Io.Writer, options: std.json.StringifyOptions) !void {
    var s: json.Stringify = .{ .writer = writer, .options = options };
    var iter: []const u8 = cbor_buf;
    try JsonWriter.jsonWriteValue(&s, &iter);
}

pub fn toJsonAlloc(a: std.mem.Allocator, cbor_buf: []const u8) (JsonEncodeError || Io.Writer.Error)![]const u8 {
    var w = Io.Writer.Allocating.init(a);
    defer w.deinit();
    var s: json.Stringify = .{ .writer = &w.writer };
    var iter: []const u8 = cbor_buf;
    try JsonWriter.jsonWriteValue(&s, &iter);
    return w.toOwnedSlice();
}

pub fn toJsonPretty(cbor_buf: []const u8, json_buf: []u8) (JsonEncodeError || Io.Writer.Error)![]const u8 {
    var writer: Io.Writer = .fixed(json_buf);
    var s: json.Stringify = .{
        .writer = &writer,
        .options = .{ .whitespace = .indent_1 },
    };
    var iter: []const u8 = cbor_buf;
    try JsonWriter.jsonWriteValue(&s, &iter);
    return writer.buffered();
}

pub fn toJsonPrettyAlloc(a: std.mem.Allocator, cbor_buf: []const u8) (JsonEncodeError || Io.Writer.Error)![]const u8 {
    var buf = Io.Writer.Allocating.init(a);
    defer buf.deinit();
    var s: json.Stringify = .{
        .writer = &buf.writer,
        .options = .{ .whitespace = .indent_1 },
    };
    var iter: []const u8 = cbor_buf;
    try JsonWriter.jsonWriteValue(&s, &iter);
    return buf.toOwnedSlice();
}

pub fn toJsonOptsAlloc(a: std.mem.Allocator, cbor_buf: []const u8, opts: std.json.StringifyOptions) JsonEncodeError![]const u8 {
    var buf = Io.Writer.Allocating.init(a);
    defer buf.deinit();
    var s: json.Stringify = .{ .writer = &buf.writer, .options = opts };
    var iter: []const u8 = cbor_buf;
    try JsonWriter.jsonWriteValue(&s, &iter);
    return buf.toOwnedSlice();
}

pub fn writeJsonValue(writer: *Io.Writer, value: json.Value) !void {
    try switch (value) {
        .array => |_| unreachable,
        .object => |_| unreachable,
        .null => writeNull(writer),
        inline else => |v| writeValue(writer, v),
    };
}

fn jsonScanUntil(writer: *Io.Writer, scanner: *json.Scanner, end_token: anytype) (JsonDecodeError || Io.Writer.Error)!usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sfa = std.heap.stackFallback(1024, arena.allocator());
    var partial = std.array_list.Managed(u8).init(sfa.get());
    var count: usize = 0;

    var token = try scanner.next();
    while (token != end_token) : (token = try scanner.next()) {
        count += 1;
        switch (token) {
            .object_begin => try writeJsonObject(writer, scanner),
            .array_begin => try writeJsonArray(writer, scanner),

            .true => try writeBool(writer, true),
            .false => try writeBool(writer, false),
            .null => try writeNull(writer),

            .number => |v| {
                try partial.appendSlice(v);
                try writeJsonValue(writer, json.Value.parseFromNumberSlice(partial.items));
                try partial.resize(0);
            },
            .partial_number => |v| {
                try partial.appendSlice(v);
                count -= 1;
            },

            .string => |v| {
                try partial.appendSlice(v);
                try writeString(writer, partial.items);
                try partial.resize(0);
            },
            .partial_string => |v| {
                try partial.appendSlice(v);
                count -= 1;
            },
            .partial_string_escaped_1 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },
            .partial_string_escaped_2 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },
            .partial_string_escaped_3 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },
            .partial_string_escaped_4 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },

            else => return error.SyntaxError,
        }
    }
    return count;
}

fn writeJsonArray(writer_: *Io.Writer, scanner: *json.Scanner) (JsonDecodeError || Io.Writer.Error)!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sfa = std.heap.stackFallback(1024, arena.allocator());
    var buf = Io.Writer.Allocating.init(sfa.get());
    const writer = &buf.writer;
    const count = try jsonScanUntil(writer, scanner, .array_end);
    try writeArrayHeader(writer_, count);
    try writer_.writeAll(buf.written());
}

fn writeJsonObject(writer_: *Io.Writer, scanner: *json.Scanner) (JsonDecodeError || Io.Writer.Error)!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sfa = std.heap.stackFallback(1024, arena.allocator());
    var buf = Io.Writer.Allocating.init(sfa.get());
    const writer = &buf.writer;
    const count = try jsonScanUntil(writer, scanner, .object_end);
    try writeMapHeader(writer_, count / 2);
    try writer_.writeAll(buf.written());
}

pub fn fromJson(json_buf: []const u8, cbor_buf: []u8) (JsonDecodeError || Io.Writer.Error)![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sfa = std.heap.stackFallback(1024, arena.allocator());
    var writer: Io.Writer = .fixed(cbor_buf);

    var scanner = json.Scanner.initCompleteInput(sfa.get(), json_buf);
    defer scanner.deinit();

    _ = try jsonScanUntil(&writer, &scanner, .end_of_document);
    return writer.buffered();
}

pub fn fromJsonAlloc(a: std.mem.Allocator, json_buf: []const u8) JsonDecodeError![]const u8 {
    var stream = std.array_list.Managed(u8).init(a);
    defer stream.deinit();
    const writer = stream.writer();

    var scanner = json.Scanner.initCompleteInput(a, json_buf);
    defer scanner.deinit();

    _ = try jsonScanUntil(writer, &scanner, .end_of_document);
    return stream.toOwnedSlice();
}
