# Copyright (C) 2019-2020 Apple Inc. All rights reserved.
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

# Calling conventions
const CalleeSaveSpaceAsVirtualRegisters = constexpr Wasm::numberOfLLIntCalleeSaveRegisters
const CalleeSaveSpaceStackAligned = (CalleeSaveSpaceAsVirtualRegisters * SlotSize + StackAlignment - 1) & ~StackAlignmentMask
const WasmEntryPtrTag = constexpr WasmEntryPtrTag

if HAVE_FAST_TLS
    const WTF_WASM_CONTEXT_KEY = constexpr WTF_WASM_CONTEXT_KEY
end

if X86_64
    const NumberOfWasmArgumentGPRs = 6
elsif ARM64 or ARM64E
    const NumberOfWasmArgumentGPRs = 8
elsif ARMv7
    const NumberOfWasmArgumentGPRs = 4
else
    error
end

if not ARMv7
    const NumberOfWasmArgumentFPRs = 8
else
    const NumberOfWasmArgumentFPRs = 6
end

const NumberOfWasmArguments = NumberOfWasmArgumentGPRs + NumberOfWasmArgumentFPRs

# All callee saves must match the definition in WasmCallee.cpp

# These must match the definition in WasmMemoryInformation.cpp
if X86_64 or ARM64 or ARM64E
    const wasmInstance = csr0
    const memoryBase = csr3
    const boundsCheckingSize = csr4
elsif ARMv7
    const wasmInstance = csr0
    const memoryBase = t4
    const boundsCheckingSize = t5
else
    error
end

// Define this elsewhere? Also for both big and little endian
const HiOffset = 0
const LoOffset = 4

# This must match the definition in LowLevelInterpreter.asm
if X86_64
    const PB = csr2
elsif ARM64 or ARM64E
    const PB = csr7
elsif ARMv7
    const PB = csr1
else
    error
end

macro forEachArgumentGPR(fn)
    fn(0 * 8, wa0)
    fn(1 * 8, wa1)
    fn(2 * 8, wa2)
    fn(3 * 8, wa3)
    if not ARMv7
        fn(4 * 8, wa4)
        fn(5 * 8, wa5)
        if ARM64 or ARM64E
            fn(6 * 8, wa6)
            fn(7 * 8, wa7)
        end
    end
end

macro forEachArgumentGPR2(fn)
    fn(0 * 4, wa1)
    fn(1 * 4, wa0)
    fn(2 * 4, wa3)
    fn(3 * 4, wa2)
end

macro forEachArgumentFPR(fn)
    fn((NumberOfWasmArgumentGPRs + 0) * 8, wfa0)
    fn((NumberOfWasmArgumentGPRs + 1) * 8, wfa1)
    fn((NumberOfWasmArgumentGPRs + 2) * 8, wfa2)
    fn((NumberOfWasmArgumentGPRs + 3) * 8, wfa3)
    fn((NumberOfWasmArgumentGPRs + 4) * 8, wfa4)
    fn((NumberOfWasmArgumentGPRs + 5) * 8, wfa5)
    if not ARMv7
        fn((NumberOfWasmArgumentGPRs + 6) * 8, wfa6)
        fn((NumberOfWasmArgumentGPRs + 7) * 8, wfa7)
    end
end

# Helper macros
# FIXME: Eventually this should be unified with the JS versions
# https://bugs.webkit.org/show_bug.cgi?id=203656

macro wasmDispatch(advanceReg)
    addp advanceReg, PC
    wasmNextInstruction()
end

macro wasmDispatchIndirect(offsetReg)
    wasmDispatch(offsetReg)
end

macro wasmNextInstruction()
    loadb [PB, PC, 1], t0
    leap _g_opcodeMap, t1
    jmp NumberOfJSOpcodeIDs * PtrSize[t1, t0, PtrSize], BytecodePtrTag, AddressDiversified
end

macro wasmNextInstructionWide16()
    loadb OpcodeIDNarrowSize[PB, PC, 1], t0
    leap _g_opcodeMapWide16, t1
    jmp NumberOfJSOpcodeIDs * PtrSize[t1, t0, PtrSize], BytecodePtrTag, AddressDiversified
end

macro wasmNextInstructionWide32()
    loadb OpcodeIDNarrowSize[PB, PC, 1], t0
    leap _g_opcodeMapWide32, t1
    jmp NumberOfJSOpcodeIDs * PtrSize[t1, t0, PtrSize], BytecodePtrTag, AddressDiversified
end

macro checkSwitchToJIT(increment, action)
    loadp CodeBlock[cfr], ws0
    baddis increment, Wasm::FunctionCodeBlock::m_tierUpCounter + Wasm::LLIntTierUpCounter::m_counter[ws0], .continue
    action()
    .continue:
end

macro checkSwitchToJITForPrologue(codeBlockRegister)
    if WEBASSEMBLY_B3JIT
    checkSwitchToJIT(
        5,
        macro()
            move cfr, a0
            move PC, a1
            move wasmInstance, a2
            cCall4(_slow_path_wasm_prologue_osr)
            btpz r0, .recover
            move r0, ws0

            forEachArgumentGPR(macro (offset, gpr)
                loadq -offset - 8 - CalleeSaveSpaceAsVirtualRegisters * 8[cfr], gpr
            end)

            forEachArgumentFPR(macro (offset, fpr)
                loadd -offset - 8 - CalleeSaveSpaceAsVirtualRegisters * 8[cfr], fpr
            end)

            restoreCalleeSavesUsedByWasm()
            restoreCallerPCAndCFR()
            if ARM64E
                leap JSCConfig + constexpr JSC::offsetOfJSCConfigGateMap + (constexpr Gate::wasmOSREntry) * PtrSize, ws1
                jmp [ws1], NativeToJITGatePtrTag # WasmEntryPtrTag
            else
                jmp ws0, WasmEntryPtrTag
            end
        .recover:
            notFunctionCodeBlockGetter(codeBlockRegister)
        end)
    end
end

macro checkSwitchToJITForLoop()
    if WEBASSEMBLY_B3JIT
    checkSwitchToJIT(
        1,
        macro()
            storei PC, ArgumentCountIncludingThis + TagOffset[cfr]
            prepareStateForCCall()
            move cfr, a0
            move PC, a1
            move wasmInstance, a2
            cCall4(_slow_path_wasm_loop_osr)
            btpz r1, .recover
            restoreCalleeSavesUsedByWasm()
            restoreCallerPCAndCFR()
            move r0, a0
            if ARM64E
                move r1, ws0
                leap JSCConfig + constexpr JSC::offsetOfJSCConfigGateMap + (constexpr Gate::wasmOSREntry) * PtrSize, ws1
                jmp [ws1], NativeToJITGatePtrTag # WasmEntryPtrTag
            else
                jmp r1, WasmEntryPtrTag
            end
        .recover:
            loadi ArgumentCountIncludingThis + TagOffset[cfr], PC
        end)
    end
end

macro checkSwitchToJITForEpilogue()
    if WEBASSEMBLY_B3JIT
    checkSwitchToJIT(
        10,
        macro ()
            callWasmSlowPath(_slow_path_wasm_epilogue_osr)
        end)
    end
end

# Wasm specific helpers

macro preserveCalleeSavesUsedByWasm()
    # NOTE: We intentionally don't save memoryBase and boundsCheckingSize here. See the comment
    # in restoreCalleeSavesUsedByWasm() below for why.
    subp CalleeSaveSpaceStackAligned, sp
    if ARM64 or ARM64E
        emit "stp x19, x26, [x29, #-16]"
    elsif X86_64
        storep PB, -0x8[cfr]
        storep wasmInstance, -0x10[cfr]
    elsif ARMv7
        storep PB, -4[cfr]
        storep wasmInstance, -8[cfr]
    else
        error
    end
end

macro restoreCalleeSavesUsedByWasm()
    # NOTE: We intentionally don't restore memoryBase and boundsCheckingSize here. These are saved
    # and restored when entering Wasm by the JSToWasm wrapper and changes to them are meant
    # to be observable within the same Wasm module.
    if ARM64 or ARM64E
        emit "ldp x19, x26, [x29, #-16]"
    elsif X86_64
        loadp -0x8[cfr], PB
        loadp -0x10[cfr], wasmInstance
    elsif ARMv7
        loadp -4[cfr], PB
        loadp -8[cfr], wasmInstance
    else
        error
    end
end

macro loadWasmInstanceFromTLSTo(reg)
if  HAVE_FAST_TLS
    tls_loadp WTF_WASM_CONTEXT_KEY, reg
else
    crash()
end
end

macro loadWasmInstanceFromTLS()
if  HAVE_FAST_TLS
    loadWasmInstanceFromTLSTo(wasmInstance)
else
    crash()
end
end

macro storeWasmInstanceToTLS(instance)
if  HAVE_FAST_TLS
    tls_storep instance, WTF_WASM_CONTEXT_KEY
else
    crash()
end
end

if not JSVALUE64
macro cagedPrimitiveMayBeNull(ptr, length, scratch, scratch2)
end
end
    
macro reloadMemoryRegistersFromInstance(instance, scratch1, scratch2)
    loadp Wasm::Instance::m_cachedMemory[instance], memoryBase
    loadp Wasm::Instance::m_cachedBoundsCheckingSize[instance], boundsCheckingSize
    cagedPrimitiveMayBeNull(memoryBase, boundsCheckingSize, scratch1, scratch2) # If boundsCheckingSize is 0, pointer can be a nullptr.
end

macro throwException(exception)
    storei constexpr Wasm::ExceptionType::%exception%, ArgumentCountIncludingThis + PayloadOffset[cfr]
    jmp _wasm_throw_from_slow_path_trampoline
end

macro callWasmSlowPath(slowPath)
    prepareStateForCCall()
    move cfr, a0
    move PC, a1
    move wasmInstance, a2
    cCall4(slowPath)
    restoreStateAfterCCall()
end

macro callWasmCallSlowPath(slowPath, action)
    storei PC, ArgumentCountIncludingThis + TagOffset[cfr]
    prepareStateForCCall()
    move cfr, a0
    move PC, a1
    move wasmInstance, a2
    cCall4(slowPath)
    action(r0, r1)
end

macro wasmPrologue(codeBlockGetter, codeBlockSetter, loadWasmInstance)
    # Set up the call frame and check if we should OSR.
    preserveCallerPCAndCFR()
    preserveCalleeSavesUsedByWasm()
    loadWasmInstance()
    reloadMemoryRegistersFromInstance(wasmInstance, ws0, ws1)

    codeBlockGetter(ws0)
    codeBlockSetter(ws0)

    # Get new sp in ws1 and check stack height.
    loadi Wasm::FunctionCodeBlock::m_numCalleeLocals[ws0], ws1
    lshiftp 3, ws1
    addp maxFrameExtentForSlowPathCall, ws1
    subp cfr, ws1, ws1

    if ARMv7
        subp 8, ws1 # align stack pointer
    end
        
    bpa ws1, cfr, .stackOverflow
    bpbeq Wasm::Instance::m_cachedStackLimit[wasmInstance], ws1, .stackHeightOK

.stackOverflow:
    throwException(StackOverflow)

.stackHeightOK:
    move ws1, sp

    forEachArgumentGPR(macro (offset, gpr)
        storeq gpr, -offset - 8 - CalleeSaveSpaceAsVirtualRegisters * 8[cfr]
    end)

    forEachArgumentFPR(macro (offset, fpr)
        stored fpr, -offset - 8 - CalleeSaveSpaceAsVirtualRegisters * 8[cfr]
    end)

    checkSwitchToJITForPrologue(ws0)

    # Set up the PC.
    loadp Wasm::FunctionCodeBlock::m_instructionsRawPointer[ws0], PB
    move 0, PC

    loadi Wasm::FunctionCodeBlock::m_numVars[ws0], ws1
    subi NumberOfWasmArguments + CalleeSaveSpaceAsVirtualRegisters, ws1
    btiz ws1, .zeroInitializeLocalsDone
    negi ws1
    if not ARMv7
    sxi2q ws1, ws1
    end
    leap (NumberOfWasmArguments + CalleeSaveSpaceAsVirtualRegisters + 1) * -8[cfr], ws0
.zeroInitializeLocalsLoop:
    addq 1, ws1
    storeq 0, [ws0, ws1, 8]
    btqz ws1, .zeroInitializeLocalsDone
    jmp .zeroInitializeLocalsLoop
.zeroInitializeLocalsDone:
end

macro traceExecution()
    if TRACING
        callWasmSlowPath(_slow_path_wasm_trace)
    end
end

# Less convenient, but required for opcodes that collide with reserved instructions (e.g. wasm_nop)
macro unprefixedWasmOp(opcodeName, opcodeStruct, fn)
    commonOp(opcodeName, traceExecution, macro(size)
        fn(macro(fn2)
            fn2(opcodeName, opcodeStruct, size)
        end)
    end)
end

macro wasmOp(opcodeName, opcodeStruct, fn)
    unprefixedWasmOp(wasm_%opcodeName%, opcodeStruct, fn)
end

# Same as unprefixedWasmOp, necessary for e.g. wasm_call
macro unprefixedSlowWasmOp(opcodeName)
    unprefixedWasmOp(opcodeName, unusedOpcodeStruct, macro(ctx)
        callWasmSlowPath(_slow_path_%opcodeName%)
        dispatch(ctx)
    end)
end

macro slowWasmOp(opcodeName)
    unprefixedSlowWasmOp(wasm_%opcodeName%)
end

# Most of the 32bit ops can be shared between both value-representation branches.    
wasmOp(i32_add, WasmI32Add, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    addi t0, t1, t2
    returni(ctx, t2)
end)

wasmOp(i32_sub, WasmI32Sub, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    subi t1, t0
    returni(ctx, t0)
end)

wasmOp(i32_mul, WasmI32Mul, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    muli t0, t1
    returni(ctx, t1)
end)

wasmOp(i32_and, WasmI32And, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    andi t0, t1
    returni(ctx, t1)
end)

wasmOp(i32_or, WasmI32Or, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    ori t0, t1
    returni(ctx, t1)
end)

wasmOp(i32_xor, WasmI32Xor, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    xori t0, t1
    returni(ctx, t1)
end)

wasmOp(i32_shl, WasmI32Shl, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    lshifti t1, t0
    returni(ctx, t0)
end)

wasmOp(i32_shr_u, WasmI32ShrU, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    urshifti t1, t0
    returni(ctx, t0)
end)

wasmOp(i32_shr_s, WasmI32ShrS, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    rshifti t1, t0
    returni(ctx, t0)
end)

wasmOp(i32_rotr, WasmI32Rotr, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    rrotatei t1, t0
    returni(ctx, t0)
end)

wasmOp(i32_rotl, WasmI32Rotl, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    lrotatei t1, t0
    returni(ctx, t0)
end)

wasmOp(i32_eq, WasmI32Eq, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    cieq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

wasmOp(i32_ne, WasmI32Ne, macro(ctx)
    mloadi(ctx, m_lhs, t0)
    mloadi(ctx, m_rhs, t1)
    cineq t0, t1, t2
    andi 1, t2
    returni(ctx, t2)
end)

# Value-representation-specific code.
if JSVALUE64
    include WebAssembly64
else
    include WebAssembly32_64
end
