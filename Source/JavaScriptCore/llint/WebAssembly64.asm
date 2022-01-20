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

# i32 binary ops

wasmOp(i32_div_s, WasmI32DivS, macro (ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)

    btiz t1, .throwDivisionByZero

    bineq t1, -1, .safe
    bieq t0, constexpr INT32_MIN, .throwIntegerOverflow

.safe:
    if X86_64
        # FIXME: Add a way to static_asset that t0 is rax and t2 is rdx
        # https://bugs.webkit.org/show_bug.cgi?id=203692
        cdqi
        idivi t1
    elsif ARM64 or ARM64E or RISCV64
        divis t1, t0
    else
        error
    end
    returni(ctx, t0)

.throwDivisionByZero:
    throwException(DivisionByZero)

.throwIntegerOverflow:
    throwException(IntegerOverflow)
end)

wasmOp(i32_div_u, WasmI32DivU, macro (ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)

    btiz t1, .throwDivisionByZero

    if X86_64
        xori t2, t2
        udivi t1
    elsif ARM64 or ARM64E or RISCV64
        divi t1, t0
    else
        error
    end
    returni(ctx, t0)

.throwDivisionByZero:
    throwException(DivisionByZero)
end)

wasmOp(i32_rem_s, WasmI32RemS, macro (ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)

    btiz t1, .throwDivisionByZero

    bineq t1, -1, .safe
    bineq t0, constexpr INT32_MIN, .safe

    move 0, t2
    jmp .return

.safe:
    if X86_64
        # FIXME: Add a way to static_asset that t0 is rax and t2 is rdx
        # https://bugs.webkit.org/show_bug.cgi?id=203692
        cdqi
        idivi t1
    elsif ARM64 or ARM64E
        divis t1, t0, t2
        muli t1, t2
        subi t0, t2, t2
    elsif RISCV64
        remis t1, t0
    else
        error
    end

.return:
    returni(ctx, t2)

.throwDivisionByZero:
    throwException(DivisionByZero)
end)

wasmOp(i32_rem_u, WasmI32RemU, macro (ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)

    btiz t1, .throwDivisionByZero

    if X86_64
        xori t2, t2
        udivi t1
    elsif ARM64 or ARM64E
        divi t1, t0, t2
        muli t1, t2
        subi t0, t2, t2
    elsif RISCV64
        remi t1, t0
    else
        error
    end
    returni(ctx, t2)

.throwDivisionByZero:
    throwException(DivisionByZero)
end)

# i64 binary ops

wasmOp(i64_add, WasmI64Add, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    addq t0, t1
    returnq(ctx, t1)
end)

wasmOp(i64_sub, WasmI64Sub, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    subq t1, t0
    returnq(ctx, t0)
end)

wasmOp(i64_mul, WasmI64Mul, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    mulq t0, t1
    returnq(ctx, t1)
end)

wasmOp(i64_div_s, WasmI64DivS, macro (ctx)
    crashOn32BitPlatforms() # FIXME
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)

    btqz t1, .throwDivisionByZero

    bqneq t1, -1, .safe
    bqeq t0, constexpr INT64_MIN, .throwIntegerOverflow

.safe:
    if X86_64
        # FIXME: Add a way to static_asset that t0 is rax and t2 is rdx
        # https://bugs.webkit.org/show_bug.cgi?id=203692
        cqoq
        idivq t1
    elsif ARM64 or ARM64E or RISCV64
        divqs t1, t0
    else
        error
    end
    returnq(ctx, t0)

.throwDivisionByZero:
    throwException(DivisionByZero)

.throwIntegerOverflow:
    throwException(IntegerOverflow)
end)

wasmOp(i64_div_u, WasmI64DivU, macro (ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)

    btqz t1, .throwDivisionByZero

    if X86_64
        xorq t2, t2
        udivq t1
    elsif ARM64 or ARM64E or RISCV64
        divq t1, t0
    else
        error
    end
    returnq(ctx, t0)

.throwDivisionByZero:
    throwException(DivisionByZero)
end)

wasmOp(i64_rem_s, WasmI64RemS, macro (ctx)
    crashOn32BitPlatforms() # FIXME
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)

    btqz t1, .throwDivisionByZero

    bqneq t1, -1, .safe
    bqneq t0, constexpr INT64_MIN, .safe

    move 0, t2
    jmp .return

.safe:
    if X86_64
        # FIXME: Add a way to static_asset that t0 is rax and t2 is rdx
        # https://bugs.webkit.org/show_bug.cgi?id=203692
        cqoq
        idivq t1
    elsif ARM64 or ARM64E
        divqs t1, t0, t2
        mulq t1, t2
        subq t0, t2, t2
    elsif RISCV64
        remqs t1, t0
    else
        error
    end

.return:
    returnq(ctx, t2) # rdx has the remainder

.throwDivisionByZero:
    throwException(DivisionByZero)
end)

wasmOp(i64_rem_u, WasmI64RemU, macro (ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)

    btqz t1, .throwDivisionByZero

    if X86_64
        xorq t2, t2
        udivq t1
    elsif ARM64 or ARM64E
        divq t1, t0, t2
        mulq t1, t2
        subq t0, t2, t2
    elsif RISCV64
        remq t1, t0
    else
        error
    end
    returnq(ctx, t2)

.throwDivisionByZero:
    throwException(DivisionByZero)
end)

wasmOp(i64_and, WasmI64And, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    andq t0, t1
    returnq(ctx, t1)
end)

wasmOp(i64_or, WasmI64Or, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    orq t0, t1
    returnq(ctx, t1)
end)

wasmOp(i64_xor, WasmI64Xor, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    xorq t0, t1
    returnq(ctx, t1)
end)

wasmOp(i64_shl, WasmI64Shl, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    lshiftq t1, t0
    returnq(ctx, t0)
end)

wasmOp(i64_shr_u, WasmI64ShrU, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    urshiftq t1, t0
    returnq(ctx, t0)
end)

wasmOp(i64_shr_s, WasmI64ShrS, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    rshiftq t1, t0
    returnq(ctx, t0)
end)

wasmOp(i64_rotr, WasmI64Rotr, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    rrotateq t1, t0
    returnq(ctx, t0)
end)

wasmOp(i64_rotl, WasmI64Rotl, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    lrotateq t1, t0
    returnq(ctx, t0)
end)

wasmOp(i64_eq, WasmI64Eq, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqeq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_ne, WasmI64Ne, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqneq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_lt_s, WasmI64LtS, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqlt t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_le_s, WasmI64LeS, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqlteq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_lt_u, WasmI64LtU, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqb t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_le_u, WasmI64LeU, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqbeq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_gt_s, WasmI64GtS, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqgt t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_ge_s, WasmI64GeS, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqgteq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_gt_u, WasmI64GtU, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqa t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i64_ge_u, WasmI64GeU, macro(ctx)
    mloadq(ctx, m_lhs, t0)
    mloadq(ctx, m_rhs, t1)
    cqaeq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

# i64 unary ops

wasmOp(i64_ctz, WasmI64Ctz, macro (ctx)
    crashOn32BitPlatforms() # FIXME
    mloadq(ctx, m_operand, t0)
    tzcntq t0, t0
    returnq(ctx, t0)
end)

wasmOp(i64_clz, WasmI64Clz, macro(ctx)
    crashOn32BitPlatforms() # FIXME
    mloadq(ctx, m_operand, t0)
    lzcntq t0, t1
    returnq(ctx, t1)
end)

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

