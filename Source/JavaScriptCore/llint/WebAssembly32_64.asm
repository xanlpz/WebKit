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
# - Arguments should be almost there.
# - TODO:
#       Support all ops
#       multiple return values
#       tagging on the stack for exception handling/others
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
