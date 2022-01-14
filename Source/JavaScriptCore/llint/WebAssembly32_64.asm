# Copyright (C) 2011-2021 Apple Inc. All rights reserved.
# Copyright (C) 2021 Igalia S.L. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

# - Working on instruction coverage, i32/f32 by far the most complete
# - andf/orf need implementation for f32.{max,min} to work with equal values
# - One return value.
# - TODO:
#       Support all ops
#       multiple return values
#       not enough scratch gpr registers (see WasmCallingConvention)
#       stack arguments
#       WasmMemory size does not fit on 32bit integer
#       WasmToJS is mostly TODO
#       atomic ops.

# Opcodes that should eventually be shared with JS llint

wasmOp(mov, WasmMov, macro(ctx)
    mload2i(ctx, m_src, t1, t0)
    return2i(ctx, t1, t0)
end)

# Wasm specific bytecodes

macro emitCheckAndPreparePointer(pointer, offset, size)
    # This macro updates 'pointer' to target address, and may thrash 'offset'
if ARMv7
    # Not enough registers on arm to keep the memory base and size in pinned
    # registers, so load them on each access instead. FIXME: improve this.
    addps offset, pointer
    bcs .throw
    addps size - 1, pointer, offset # Use offset as scratch register
    bcs .throw
    bpb offset, Wasm::Instance::m_cachedBoundsCheckingSize[wasmInstance], .continuation
.throw:
    throwException(OutOfBoundsMemoryAccess)
.continuation:
    addp Wasm::Instance::m_cachedMemory[wasmInstance], pointer
else
    crash()
end
end

macro wasmLoadOp(name, struct, size, fn)
    wasmOp(name, struct, macro(ctx)
        mloadi(ctx, m_pointer, t0)
        wgetu(ctx, m_offset, t1)
        emitCheckAndPreparePointer(t0, t1, size)
        fn(t0, t3, t2)
        return2i(ctx, t3, t2)
    end)
end

wasmLoadOp(load8_u, WasmLoad8U, 1, macro(addr, dstMsw, dstLsw)
    loadb LswOffset[addr], dstLsw
    move 0, dstMsw
end)
wasmLoadOp(load16_u, WasmLoad16U, 2, macro(addr, dstMsw, dstLsw)
    loadh LswOffset[addr], dstLsw
    move 0, dstMsw
end)
wasmLoadOp(load32_u, WasmLoad32U, 4, macro(addr, dstMsw, dstLsw)
    loadi LswOffset[addr], dstLsw
    move 0, dstMsw
end)
wasmLoadOp(load64_u, WasmLoad64U, 8, macro(addr, dstMsw, dstLsw)
    # Might be unaligned, so can't use load2ia
    loadi LswOffset[addr], dstLsw
    loadi MswOffset[addr], dstMsw
end)

wasmLoadOp(i32_load8_s, WasmI32Load8S, 1, macro(addr, dstMsw, dstLsw)
    loadbsi LswOffset[addr], dstLsw
    move 0, dstMsw
end)
wasmLoadOp(i32_load16_s, WasmI32Load16S, 2, macro(addr, dstMsw, dstLsw)
    loadhsi LswOffset[addr], dstLsw
    move 0, dstMsw
end)
wasmLoadOp(i64_load8_s, WasmI64Load8S, 1, macro(addr, dstMsw, dstLsw)
    loadbsi LswOffset[addr], dstLsw
    rshifti dstLsw, 31, dstMsw
end)
wasmLoadOp(i64_load16_s, WasmI64Load16S, 2, macro(addr, dstMsw, dstLsw)
    loadhsi LswOffset[addr], dstLsw
    rshifti dstLsw, 31, dstMsw
end)
wasmLoadOp(i64_load32_s, WasmI64Load32S, 4, macro(addr, dstMsw, dstLsw)
    loadi LswOffset[addr], dstLsw
    rshifti dstLsw, 31, dstMsw
end)

macro wasmStoreOp(name, struct, size, fn)
    wasmOp(name, struct, macro(ctx)
        mloadi(ctx, m_pointer, t0)
        wgetu(ctx, m_offset, t1)
        emitCheckAndPreparePointer(t0, t1, size)
        mload2i(ctx, m_value, t3, t2)
        fn(t3, t2, t0)
        dispatch(ctx)
    end)
end

wasmStoreOp(store8, WasmStore8, 1, macro(srcMsw, srcLsw, addr)
    storeb srcLsw, LswOffset[addr]
end)
wasmStoreOp(store16, WasmStore16, 2, macro(srcMsw, srcLsw, addr)
    storeh srcLsw, LswOffset[addr]
end)
wasmStoreOp(store32, WasmStore32, 4, macro(srcMsw, srcLsw, addr)
    storei srcLsw, LswOffset[addr]
end)
wasmStoreOp(store64, WasmStore64, 8, macro(srcMsw, srcLsw, addr)
    # Might be unaligned, so can't use store2ia
    storei srcLsw, LswOffset[addr]
    storei srcMsw, MswOffset[addr]
end)

# Opcodes that don't have the `b3op` entry in wasm.json. This should be kept in sync

wasmOp(i64_popcnt, WasmI64Popcnt, macro (ctx)
    mload2i(ctx, m_operand, a3, a2)
    prepareStateForCCall()
    move PC, a0
    cCall2(_slow_path_wasm_popcountll)
    restoreStateAfterCCall()
    return2i(ctx, 0, r1)
end)

wasmOp(i64_eqz, WasmI64Eqz, macro(ctx)
    mload2i(ctx, m_operand, t1, t0)
    btinz t1, .notZero
    cieq t0, 0, t0
    returni(ctx, t0)
.notZero:
    returni(ctx, 0)
end)

wasmOp(i64_eq, WasmI64Eq, macro(ctx)
    mload2i(ctx, m_lhs, t1, t0)
    mload2i(ctx, m_rhs, t3, t2)
    bineq t1, t3, .notEqual
    cieq t0, t2, t0
    returni(ctx, t0)
.notEqual:
    returni(ctx, 0)
end)
