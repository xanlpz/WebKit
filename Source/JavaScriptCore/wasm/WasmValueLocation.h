/*
 * Copyright (C) 2015-2018 Apple Inc. All rights reserved.
 * Copyright (C) 2021 Igalia S.L. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(WEBASSEMBLY)

#include "FPRInfo.h"
#include "GPRInfo.h"
#include "Reg.h"
#include <wtf/PrintStream.h>
#include "WasmOps.h"

namespace JSC {

namespace Wasm {

#if USE(JSVALUE64)
class ValueRegisters {
    WTF_MAKE_FAST_ALLOCATED;
public:
    ValueRegisters()
        : m_reg(InvalidGPRReg)
    {
    }

    ValueRegisters(Reg reg)
        : m_reg(reg)
    {
    }

    Reg reg() const { return m_reg; }
    GPRReg gpr() const { return m_reg.gpr(); }
    FPRReg fpr() const { return m_reg.fpr(); }

private:
    Reg m_reg;
};
#elif USE(JSVALUE32_64)
class ValueRegisters {
    WTF_MAKE_FAST_ALLOCATED;
public:
    ValueRegisters()
        : m_hi(InvalidGPRReg)
        , m_lo(InvalidGPRReg)
        , m_kind(TypeKind::Void)
    {
    }

    ValueRegisters(Reg hi, Reg lo)
        : m_hi(hi)
        , m_lo(lo)
        , m_kind(TypeKind::I64)
    {
    }

    ValueRegisters(Reg gpr)
        : m_hi(gpr)
        , m_lo(InvalidGPRReg)
        , m_kind(TypeKind::I32)
    {
    }

    // FIXME: this can probably be optimized to only have one register when needed.
    Reg reg() const { ASSERT(m_kind == TypeKind::I32); return m_hi; }
    GPRReg gpr() const { ASSERT(m_kind == TypeKind::I32); return m_hi.gpr(); }
    FPRReg fpr() const { /*ASSERT(m_kind == TypeKind::F32 || m_kind == TypeKind::F64);*/ return m_hi.fpr(); } //FIXME: we only use m_hi?
    Reg hi() const { ASSERT(m_kind == TypeKind::I64); return m_hi; }
    Reg lo() const { ASSERT(m_kind == TypeKind::I64); return m_lo; }

private:
    Reg m_hi;
    Reg m_lo;
    TypeKind m_kind;
};
#endif

class ValueLocation {
    WTF_MAKE_FAST_ALLOCATED;
public:
    enum Kind : uint8_t {
        Register,
        Stack,
        StackArgument,
    };

    ValueLocation()
        : m_kind(Register)
    {
    }

    explicit ValueLocation(ValueRegisters reg)
        : m_kind(Register)
    {
        u.reg = reg;
    }

    explicit ValueLocation(Reg reg)
        : m_kind(Register)
    {
        u.reg = ValueRegisters(reg);
    }

#if USE(JSVALUE32_64)
    explicit ValueLocation(Reg hi, Reg lo)
        : m_kind(Register)
    {
        u.reg = ValueRegisters(hi, lo);
    }
#endif

    ValueLocation(const ValueLocation&) = default;

    static ValueLocation reg(Reg reg)
    {
        return ValueLocation(ValueRegisters(reg));
    }
    
    static ValueLocation reg(ValueRegisters reg)
    {
        return ValueLocation(reg);
    }

    static ValueLocation stack(intptr_t offsetFromFP)
    {
        ValueLocation result;
        result.m_kind = Stack;
        result.u.offsetFromFP = offsetFromFP;
        return result;
    }

    static ValueLocation stackArgument(intptr_t offsetFromSP)
    {
        ValueLocation result;
        result.m_kind = StackArgument;
        result.u.offsetFromSP = offsetFromSP;
        return result;
    }

    Kind kind() const { return m_kind; }

    bool isReg() const { return kind() == Register; }

    ValueRegisters reg() const
    {
        ASSERT(isReg());
        return u.reg;
    }

    GPRReg gpr() const { return reg().gpr(); }
    FPRReg fpr() const { return reg().fpr(); }

    bool isStack() const { return kind() == Stack; }

    intptr_t offsetFromFP() const
    {
        ASSERT(isStack());
        return u.offsetFromFP;
    }

    bool isStackArgument() const { return kind() == StackArgument; }

    intptr_t offsetFromSP() const
    {
        ASSERT(isStackArgument());
        return u.offsetFromSP;
    }

    JS_EXPORT_PRIVATE void dump(PrintStream&) const;

private:
    union U {
        ValueRegisters reg;
        intptr_t offsetFromFP;
        intptr_t offsetFromSP;

        U()
        {
            memset(static_cast<void*>(this), 0, sizeof(*this));
        }
    } u;
    Kind m_kind;
};

} } // namespace JSC::Wasm

namespace WTF {

void printInternal(PrintStream&, JSC::Wasm::ValueLocation::Kind);

} // namespace WTF

#endif // ENABLE(WEBASSEMBLY)
