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
elsif ARM64 or ARM64E or RISCV64
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
elsif ARM64 or ARM64E or RISCV64
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
    baddis increment, Wasm::LLIntCallee::m_tierUpCounter + Wasm::LLIntTierUpCounter::m_counter[ws0], .continue
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
    elsif X86_64 or RISCV64
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
    elsif X86_64 or RISCV64
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
    storei PC, ArgumentCountIncludingThis + TagOffset[cfr]
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

macro restoreStackPointerAfterCall()
    loadp CodeBlock[cfr], ws1
    loadi Wasm::LLIntCallee::m_numCalleeLocals[ws1], ws1
    lshiftp 3, ws1
    addp maxFrameExtentForSlowPathCall, ws1
if ARMv7
    subp cfr, ws1, ws1
    move ws1, sp
else
    subp cfr, ws1, sp
end        
end

macro wasmPrologue(codeBlockGetter, codeBlockSetter, loadWasmInstance)
    # Set up the call frame and check if we should OSR.
    preserveCallerPCAndCFR()
    preserveCalleeSavesUsedByWasm()
    loadWasmInstance()
    reloadMemoryRegistersFromInstance(wasmInstance, ws0, ws1)

    loadp Wasm::Instance::m_owner[wasmInstance], ws0
    storep ws0, ThisArgumentOffset[cfr]

    codeBlockGetter(ws0)
    codeBlockSetter(ws0)

    # Get new sp in ws1 and check stack height.
    loadi Wasm::LLIntCallee::m_numCalleeLocals[ws0], ws1
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
    loadp Wasm::LLIntCallee::m_instructionsRawPointer[ws0], PB
    move 0, PC

    loadi Wasm::LLIntCallee::m_numVars[ws0], ws1
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

macro commonWasmOp(opcodeName, opcodeStruct, prologue, fn)
    commonOp(opcodeName, prologue, macro(size)
        fn(macro(fn2)
            fn2(opcodeName, opcodeStruct, size)
        end)
    end)
end

# Less convenient, but required for opcodes that collide with reserved instructions (e.g. wasm_nop)
macro unprefixedWasmOp(opcodeName, opcodeStruct, fn)
    commonWasmOp(opcodeName, opcodeStruct, traceExecution, fn)
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

macro jumpToException()
    if ARM64E
        move r0, a0
        leap JSCConfig + constexpr JSC::offsetOfJSCConfigGateMap + (constexpr Gate::exceptionHandler) * PtrSize, a1
        jmp [a1], NativeToJITGatePtrTag # ExceptionHandlerPtrTag
    else
        jmp r0, ExceptionHandlerPtrTag
    end
end

op(wasm_throw_from_slow_path_trampoline, macro ()
    loadp Wasm::Instance::m_pointerToTopEntryFrame[wasmInstance], t5
    loadp [t5], t5
    copyCalleeSavesToEntryFrameCalleeSavesBuffer(t5)

    move cfr, a0
    addp PB, PC, a1
    move wasmInstance, a2
    # Slow paths and the throwException macro store the exception code in the ArgumentCountIncludingThis slot
    loadi ArgumentCountIncludingThis + PayloadOffset[cfr], a3
    storei 0, ArgumentCountIncludingThis + TagOffset[cfr]
    cCall4(_slow_path_wasm_throw_exception)
    jumpToException()
end)

macro wasm_throw_from_fault_handler(instance)
    # instance should be in a2 when we get here
    loadp Wasm::Instance::m_pointerToTopEntryFrame[instance], a0
    loadp [a0], a0
    copyCalleeSavesToEntryFrameCalleeSavesBuffer(a0)

    move constexpr Wasm::ExceptionType::OutOfBoundsMemoryAccess, a3
    move 0, a1
    move cfr, a0
    storei 0, ArgumentCountIncludingThis + TagOffset[cfr]
    cCall4(_slow_path_wasm_throw_exception)
    jumpToException()
end

op(wasm_throw_from_fault_handler_trampoline_fastTLS, macro ()
    loadWasmInstanceFromTLSTo(a2)
    wasm_throw_from_fault_handler(a2)
end)

op(wasm_throw_from_fault_handler_trampoline_reg_instance, macro ()
    move wasmInstance, a2
    wasm_throw_from_fault_handler(a2)
end)

# Disable wide version of narrow-only opcodes
noWide(wasm_enter)
noWide(wasm_wide16)
noWide(wasm_wide32)

# Opcodes that always invoke the slow path

slowWasmOp(ref_func)
slowWasmOp(table_get)
slowWasmOp(table_set)
slowWasmOp(table_init)
slowWasmOp(elem_drop)
slowWasmOp(table_size)
slowWasmOp(table_fill)
slowWasmOp(table_copy)
slowWasmOp(table_grow)
slowWasmOp(memory_fill)
slowWasmOp(memory_copy)
slowWasmOp(memory_init)
slowWasmOp(data_drop)
slowWasmOp(set_global_ref)
slowWasmOp(set_global_ref_portable_binding)
slowWasmOp(memory_atomic_wait32)
slowWasmOp(memory_atomic_wait64)
slowWasmOp(memory_atomic_notify)

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

wasmOp(get_global, WasmGetGlobal, macro(ctx)
    loadp Wasm::Instance::m_globals[wasmInstance], t0
    wgetu(ctx, m_globalIndex, t1)
    loadq [t0, t1, 8], t0
    returnq(ctx, t0)
end)

wasmOp(set_global, WasmSetGlobal, macro(ctx)
    loadp Wasm::Instance::m_globals[wasmInstance], t0
    wgetu(ctx, m_globalIndex, t1)
    mloadq(ctx, m_value, t2)
    storeq t2, [t0, t1, 8]
    dispatch(ctx)
end)

wasmOp(get_global_portable_binding, WasmGetGlobalPortableBinding, macro(ctx)
    loadp Wasm::Instance::m_globals[wasmInstance], t0
    wgetu(ctx, m_globalIndex, t1)
    loadq [t0, t1, 8], t0
    loadq [t0], t0
    returnq(ctx, t0)
end)

wasmOp(set_global_portable_binding, WasmSetGlobalPortableBinding, macro(ctx)
    loadp Wasm::Instance::m_globals[wasmInstance], t0
    wgetu(ctx, m_globalIndex, t1)
    mloadq(ctx, m_value, t2)
    loadq [t0, t1, 8], t0
    storeq t2, [t0]
    dispatch(ctx)
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

wasmOp(f32_add, WasmF32Add, macro(ctx)
    mloadf(ctx, m_lhs, ft0)
    mloadf(ctx, m_rhs, ft1)
    addf ft0, ft1
    returnf(ctx, ft1)
end)

wasmOp(f32_sub, WasmF32Sub, macro(ctx)
    mloadf(ctx, m_lhs, ft0)
    mloadf(ctx, m_rhs, ft1)
    subf ft1, ft0
    returnf(ctx, ft0)
end)

wasmOp(f32_mul, WasmF32Mul, macro(ctx)
    mloadf(ctx, m_lhs, ft0)
    mloadf(ctx, m_rhs, ft1)
    mulf ft0, ft1
    returnf(ctx, ft1)
end)

wasmOp(f32_div, WasmF32Div, macro(ctx)
    mloadf(ctx, m_lhs, ft0)
    mloadf(ctx, m_rhs, ft1)
    divf ft1, ft0
    returnf(ctx, ft0)
end)

wasmOp(f32_min, WasmF32Min, macro(ctx)
    mloadf(ctx, m_lhs, ft0)
    mloadf(ctx, m_rhs, ft1)

    bfeq ft0, ft1, .equal
    bflt ft0, ft1, .lt
    bfgt ft0, ft1, .return

.NaN:
    addf ft0, ft1
    jmp .return

.equal:
    orf ft0, ft1
    jmp .return

.lt:
    moved ft0, ft1

.return:
    returnf(ctx, ft1)
end)

wasmOp(f32_max, WasmF32Max, macro(ctx)
    mloadf(ctx, m_lhs, ft0)
    mloadf(ctx, m_rhs, ft1)

    bfeq ft1, ft0, .equal
    bflt ft1, ft0, .lt
    bfgt ft1, ft0, .return

.NaN:
    addf ft0, ft1
    jmp .return

.equal:
    andf ft0, ft1
    jmp .return

.lt:
    moved ft0, ft1

.return:
    returnf(ctx, ft1)
end)

wasmOp(throw, WasmThrow, macro(ctx)
    loadp Wasm::Instance::m_pointerToTopEntryFrame[wasmInstance], t5
    loadp [t5], t5
    copyCalleeSavesToEntryFrameCalleeSavesBuffer(t5)

    callWasmSlowPath(_slow_path_wasm_throw)
    jumpToException()
end)

wasmOp(rethrow, WasmRethrow, macro(ctx)
    loadp Wasm::Instance::m_pointerToTopEntryFrame[wasmInstance], t5
    loadp [t5], t5
    copyCalleeSavesToEntryFrameCalleeSavesBuffer(t5)

    callWasmSlowPath(_slow_path_wasm_rethrow)
    jumpToException()
end)

macro commonCatchImpl(ctx, storeWasmInstance)
    loadp Callee[cfr], t3
    convertCalleeToVM(t3)
    restoreCalleeSavesFromVMEntryFrameCalleeSavesBuffer(t3, t0)

    loadp VM::calleeForWasmCatch[t3], ws1
    storep 0, VM::calleeForWasmCatch[t3]
    storep ws1, Callee[cfr]

    loadp VM::callFrameForCatch[t3], cfr
    storep 0, VM::callFrameForCatch[t3]

    restoreStackPointerAfterCall()

    loadp ThisArgumentOffset[cfr], wasmInstance
    loadp JSWebAssemblyInstance::m_instance[wasmInstance], wasmInstance
    storeWasmInstance(wasmInstance)
    reloadMemoryRegistersFromInstance(wasmInstance, ws0, ws1)

    loadp CodeBlock[cfr], PB
    loadp Wasm::LLIntCallee::m_instructionsRawPointer[PB], PB
    loadp VM::targetInterpreterPCForThrow[t3], PC
    subp PB, PC

    callWasmSlowPath(_slow_path_wasm_retrieve_and_clear_exception)
end

macro catchAllImpl(ctx, storeWasmInstance)
    commonCatchImpl(ctx, storeWasmInstance)
    traceExecution()
    dispatch(ctx)
end

macro catchImpl(ctx, storeWasmInstance)
    commonCatchImpl(ctx, storeWasmInstance)

    move r1, t1

    wgetu(ctx, m_startOffset, t2)
    wgetu(ctx, m_argumentCount, t3)

    lshifti 3, t2
    subp cfr, t2, t2

.copyLoop:
    btiz t3, .done
    loadq [t1], t6
    storeq t6, [t2]
    subi 1, t3
    # FIXME: Use arm store-add/sub instructions in wasm LLInt catch
    # https://bugs.webkit.org/show_bug.cgi?id=231210
    subp 8, t2
    addp 8, t1
    jmp .copyLoop

.done:
    traceExecution()
    dispatch(ctx)
end

commonWasmOp(wasm_catch, WasmCatch, macro() end, macro(ctx)
    catchImpl(ctx, storeWasmInstanceToTLS)
end)

commonWasmOp(wasm_catch_no_tls, WasmCatch, macro() end, macro(ctx)
    catchImpl(ctx, macro(instance) end)
end)

commonWasmOp(wasm_catch_all, WasmCatchAll, macro() end, macro(ctx)
    catchAllImpl(ctx, storeWasmInstanceToTLS)
end)

commonWasmOp(wasm_catch_all_no_tls, WasmCatchAll, macro() end, macro(ctx)
    catchAllImpl(ctx, macro(instance) end)
end)

# Value-representation-specific code.
if JSVALUE64
    include WebAssembly64
else
    include WebAssembly32_64
end
