const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const leb = std.leb;
const mem = std.mem;

const Module = @import("../Module.zig");
const Decl = Module.Decl;
const ir = @import("../ir.zig");
const Inst = ir.Inst;
const Type = @import("../type.zig").Type;
const Value = @import("../value.zig").Value;
const Compilation = @import("../Compilation.zig");

/// Wasm Value, created when generating an instruction
const WValue = union(enum) {
    none: void,
    /// Index of the local variable
    local: u32,
    /// Instruction holding a constant `Value`
    constant: *Inst,
    /// Block label
    block_idx: u32,
};

/// Hashmap to store generated `WValue` for each `Inst`
pub const ValueTable = std.AutoHashMap(*Inst, WValue);

/// Using a given `Type`, returns the corresponding wasm value type
fn genValtype(ty: Type) ?u8 {
    return switch (ty.tag()) {
        .f32 => 0x7D,
        .f64 => 0x7C,
        .u32, .i32 => 0x7F,
        .u64, .i64 => 0x7E,
        else => null,
    };
}

/// Code represents the `Code` section of wasm that
/// belongs to a function
pub const Context = struct {
    /// Reference to the function declaration the code
    /// section belongs to
    decl: *Decl,
    gpa: *mem.Allocator,
    /// Table to save `WValue`'s generated by an `Inst`
    values: ValueTable,
    /// `bytes` contains the wasm bytecode belonging to the 'code' section.
    code: ArrayList(u8),
    /// Contains the generated function type bytecode for the current function
    /// found in `decl`
    func_type_data: ArrayList(u8),
    /// The index the next local generated will have
    /// NOTE: arguments share the index with locals therefore the first variable
    /// will have the index that comes after the last argument's index
    local_index: u32 = 0,
    /// If codegen fails, an error messages will be allocated and saved in `err_msg`
    err_msg: *Compilation.ErrorMsg,

    const InnerError = error{
        OutOfMemory,
        CodegenFail,
    };

    /// Sets `err_msg` on `Context` and returns `error.CodegemFail` which is caught in link/Wasm.zig
    fn fail(self: *Context, src: usize, comptime fmt: []const u8, args: anytype) InnerError {
        self.err_msg = try Compilation.ErrorMsg.create(self.gpa, src, fmt, args);
        return error.CodegenFail;
    }

    /// Resolves the `WValue` for the given instruction `inst`
    /// When the given instruction has a `Value`, it returns a constant instead
    fn resolveInst(self: Context, inst: *Inst) WValue {
        if (!inst.ty.hasCodeGenBits()) return .none;

        if (inst.value()) |_| {
            return WValue{ .constant = inst };
        }

        return self.values.get(inst).?; // Instruction does not dominate all uses!
    }

    /// Writes the bytecode depending on the given `WValue` in `val`
    fn emitWValue(self: *Context, val: WValue) InnerError!void {
        const writer = self.code.writer();
        switch (val) {
            .none, .block_idx => {},
            .local => |idx| {
                try writer.writeByte(0x20); // local.get
                try leb.writeULEB128(writer, idx);
            },
            .constant => |inst| try self.emitConstant(inst.castTag(.constant).?), // creates a new constant onto the stack
        }
    }

    fn genFunctype(self: *Context) InnerError!void {
        const ty = self.decl.typed_value.most_recent.typed_value.ty;
        const writer = self.func_type_data.writer();

        // functype magic
        try writer.writeByte(0x60);

        // param types
        try leb.writeULEB128(writer, @intCast(u32, ty.fnParamLen()));
        if (ty.fnParamLen() != 0) {
            const params = try self.gpa.alloc(Type, ty.fnParamLen());
            defer self.gpa.free(params);
            ty.fnParamTypes(params);
            for (params) |param_type| {
                const val_type = genValtype(param_type) orelse
                    return self.fail(self.decl.src(), "TODO: Wasm codegen - arg type value for type '{s}'", .{param_type.tag()});
                try writer.writeByte(val_type);
            }
        }

        // return type
        const return_type = ty.fnReturnType();
        switch (return_type.tag()) {
            .void, .noreturn => try leb.writeULEB128(writer, @as(u32, 0)),
            else => |ret_type| {
                try leb.writeULEB128(writer, @as(u32, 1));
                const val_type = genValtype(return_type) orelse
                    return self.fail(self.decl.src(), "TODO: Wasm codegen - return type value for type '{s}'", .{ret_type});
                try writer.writeByte(val_type);
            },
        }
    }

    /// Generates the wasm bytecode for the function declaration belonging to `Context`
    pub fn gen(self: *Context) InnerError!void {
        assert(self.code.items.len == 0);
        try self.genFunctype();
        const writer = self.code.writer();

        // Reserve space to write the size after generating the code
        try self.code.resize(5);

        // Write instructions
        // TODO: check for and handle death of instructions
        const tv = self.decl.typed_value.most_recent.typed_value;
        const mod_fn = tv.val.castTag(.function).?.data;

        var locals = std.ArrayList(u8).init(self.gpa);
        defer locals.deinit();

        for (mod_fn.body.instructions) |inst| {
            if (inst.tag != .alloc) continue;

            const alloc: *Inst.NoOp = inst.castTag(.alloc).?;
            const elem_type = alloc.base.ty.elemType();

            const wasm_type = genValtype(elem_type) orelse
                return self.fail(inst.src, "TODO: Wasm codegen - valtype for type '{s}'", .{elem_type.tag()});

            try locals.append(wasm_type);
        }

        try leb.writeULEB128(writer, @intCast(u32, locals.items.len));

        // emit the actual locals amount
        for (locals.items) |local| {
            try leb.writeULEB128(writer, @as(u32, 1));
            try leb.writeULEB128(writer, local); // valtype
        }

        try self.genBody(mod_fn.body);

        try writer.writeByte(0x0B); // end

        // Fill in the size of the generated code to the reserved space at the
        // beginning of the buffer.
        const size = self.code.items.len - 5 + self.decl.fn_link.wasm.?.idx_refs.items.len * 5;
        leb.writeUnsignedFixed(5, self.code.items[0..5], @intCast(u32, size));
    }

    fn genInst(self: *Context, inst: *Inst) InnerError!WValue {
        return switch (inst.tag) {
            .add => self.genAdd(inst.castTag(.add).?),
            .alloc => self.genAlloc(inst.castTag(.alloc).?),
            .arg => self.genArg(inst.castTag(.arg).?),
            .call => self.genCall(inst.castTag(.call).?),
            .constant => unreachable,
            .dbg_stmt => WValue.none,
            .load => self.genLoad(inst.castTag(.load).?),
            .ret => self.genRet(inst.castTag(.ret).?),
            .retvoid => WValue.none,
            .store => self.genStore(inst.castTag(.store).?),
            else => self.fail(inst.src, "TODO: Implement wasm inst: {s}", .{inst.tag}),
        };
    }

    fn genBody(self: *Context, body: ir.Body) InnerError!void {
        for (body.instructions) |inst| {
            const result = try self.genInst(inst);
            try self.values.putNoClobber(inst, result);
        }
    }

    fn genRet(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        // TODO: Implement tail calls
        const operand = self.resolveInst(inst.operand);
        try self.emitWValue(operand);
        return WValue.none;
    }

    fn genCall(self: *Context, inst: *Inst.Call) InnerError!WValue {
        const func_inst = inst.func.castTag(.constant).?;
        const func = func_inst.val.castTag(.function).?.data;
        const target = func.owner_decl;
        const target_ty = target.typed_value.most_recent.typed_value.ty;

        for (inst.args) |arg| {
            const arg_val = self.resolveInst(arg);
            try self.emitWValue(arg_val);
        }

        try self.code.append(0x10); // call

        // The function index immediate argument will be filled in using this data
        // in link.Wasm.flush().
        try self.decl.fn_link.wasm.?.idx_refs.append(self.gpa, .{
            .offset = @intCast(u32, self.code.items.len),
            .decl = target,
        });

        return WValue.none;
    }

    fn genAlloc(self: *Context, inst: *Inst.NoOp) InnerError!WValue {
        defer self.local_index += 1;
        return WValue{ .local = self.local_index };
    }

    fn genStore(self: *Context, inst: *Inst.BinOp) InnerError!WValue {
        const writer = self.code.writer();

        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);
        try self.emitWValue(rhs);

        try writer.writeByte(0x21); // local.set
        try leb.writeULEB128(writer, lhs.local);
        return WValue.none;
    }

    fn genLoad(self: *Context, inst: *Inst.UnOp) InnerError!WValue {
        const operand = self.resolveInst(inst.operand);
        try self.emitWValue(operand);
        return WValue.none;
    }

    fn genArg(self: *Context, inst: *Inst.Arg) InnerError!WValue {
        // arguments share the index with locals
        defer self.local_index += 1;
        return WValue{ .local = self.local_index };
    }

    fn genAdd(self: *Context, inst: *Inst.BinOp) InnerError!WValue {
        const lhs = self.resolveInst(inst.lhs);
        const rhs = self.resolveInst(inst.rhs);

        try self.emitWValue(lhs);
        try self.emitWValue(rhs);

        const opcode: u8 = switch (inst.base.ty.tag()) {
            .u32, .i32 => 0x6A, //i32.add
            .u64, .i64 => 0x7C, //i64.add
            .f32 => 0x92, //f32.add
            .f64 => 0xA0, //f64.add
            else => return self.fail(inst.base.src, "TODO - Implement wasm genAdd for type '{s}'", .{inst.base.ty.tag()}),
        };

        try self.code.append(opcode);
        return WValue.none;
    }

    fn emitConstant(self: *Context, inst: *Inst.Constant) InnerError!void {
        const writer = self.code.writer();
        switch (inst.base.ty.tag()) {
            .u32 => {
                try writer.writeByte(0x41); // i32.const
                try leb.writeILEB128(writer, inst.val.toUnsignedInt());
            },
            .i32 => {
                try writer.writeByte(0x41); // i32.const
                try leb.writeILEB128(writer, inst.val.toSignedInt());
            },
            .u64 => {
                try writer.writeByte(0x42); // i64.const
                try leb.writeILEB128(writer, inst.val.toUnsignedInt());
            },
            .i64 => {
                try writer.writeByte(0x42); // i64.const
                try leb.writeILEB128(writer, inst.val.toSignedInt());
            },
            .f32 => {
                try writer.writeByte(0x43); // f32.const
                // TODO: enforce LE byte order
                try writer.writeAll(mem.asBytes(&inst.val.toFloat(f32)));
            },
            .f64 => {
                try writer.writeByte(0x44); // f64.const
                // TODO: enforce LE byte order
                try writer.writeAll(mem.asBytes(&inst.val.toFloat(f64)));
            },
            .void => {},
            else => |ty| return self.fail(inst.base.src, "Wasm TODO: emitConstant for type {s}", .{ty}),
        }
    }
};
