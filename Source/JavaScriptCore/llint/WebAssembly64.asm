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

# Opcodes that should eventually be shared with JS llint

wasmOp(mov, WasmMov, macro(ctx)
    mloadq(ctx, m_src, t0)
    returnq(ctx, t0)
end)

# Wasm specific bytecodes

macro emitCheckAndPreparePointer(ctx, pointer, offset, size)
    leap size - 1[pointer, offset], t5
    bpb t5, boundsCheckingSize, .continuation
    throwException(OutOfBoundsMemoryAccess)
.continuation:
    addp memoryBase, pointer
end

macro wasmLoadOp(name, struct, size, fn)
    wasmOp(name, struct, macro(ctx)
        mloadi(ctx, m_pointer, t0)
        wgetu(ctx, m_offset, t1)
        emitCheckAndPreparePointer(ctx, t0, t1, size)
        fn([t0, t1], t2)
        returnq(ctx, t2)
    end)
end

wasmLoadOp(load8_u, WasmLoad8U, 1, macro(mem, dst) loadb mem, dst end)
wasmLoadOp(load16_u, WasmLoad16U, 2, macro(mem, dst) loadh mem, dst end)
wasmLoadOp(load32_u, WasmLoad32U, 4, macro(mem, dst) loadi mem, dst end)
wasmLoadOp(load64_u, WasmLoad64U, 8, macro(mem, dst) loadq mem, dst end)

wasmLoadOp(i32_load8_s, WasmI32Load8S, 1, macro(mem, dst) loadbsi mem, dst end)
wasmLoadOp(i64_load8_s, WasmI64Load8S, 1, macro(mem, dst) loadbsq mem, dst end)
wasmLoadOp(i32_load16_s, WasmI32Load16S, 2, macro(mem, dst) loadhsi mem, dst end)
wasmLoadOp(i64_load16_s, WasmI64Load16S, 2, macro(mem, dst) loadhsq mem, dst end)
wasmLoadOp(i64_load32_s, WasmI64Load32S, 4, macro(mem, dst) loadis mem, dst end)

macro wasmStoreOp(name, struct, size, fn)
    wasmOp(name, struct, macro(ctx)
        mloadi(ctx, m_pointer, t0)
        wgetu(ctx, m_offset, t1)
        emitCheckAndPreparePointer(ctx, t0, t1, size)
        mloadq(ctx, m_value, t2)
        fn(t2, [t0, t1])
        dispatch(ctx)
    end)
end

wasmStoreOp(store8, WasmStore8, 1, macro(value, mem) storeb value, mem end)
wasmStoreOp(store16, WasmStore16, 2, macro(value, mem) storeh value, mem end)
wasmStoreOp(store32, WasmStore32, 4, macro(value, mem) storei value, mem end)
wasmStoreOp(store64, WasmStore64, 8, macro(value, mem) storeq value, mem end)

# Opcodes that don't have the `b3op` entry in wasm.json. This should be kept in sync

wasmOp(i64_popcnt, WasmI64Popcnt, macro (ctx)
    mloadq(ctx, m_operand, a1)
    prepareStateForCCall()
    move PC, a0
    cCall2(_slow_path_wasm_popcountll)
    restoreStateAfterCCall()
    returnq(ctx, r1)
end)

wasmOp(i64_eqz, WasmI64Eqz, macro(ctx)
    mloadq(ctx, m_operand, t0)
    cqeq t0, 0, t0
    returni(ctx, t0)
end)

wasmOp(i64_eq, WasmI64Eq, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqeq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)
