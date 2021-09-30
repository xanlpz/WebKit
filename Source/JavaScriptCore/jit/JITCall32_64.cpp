/*
 * Copyright (C) 2020 Igalia, S.L. All rights reserved.
 * Copyright (C) 2020 Metrological Group B.V.
 * Copyright (C) 2008-2019 Apple Inc. All rights reserved.
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

#include "config.h"

#if ENABLE(JIT)
#if USE(JSVALUE32_64)
#include "JIT.h"

#include "BytecodeOperandsForCheckpoint.h"
#include "CacheableIdentifierInlines.h"
#include "CallFrameShuffler.h"
#include "CodeBlock.h"
#include "JITInlines.h"
#include "ScratchRegisterAllocator.h"
#include "SetupVarargsFrame.h"
#include "SlowPathCall.h"
#include "StackAlignment.h"
#include "ThunkGenerators.h"
namespace JSC {

template<typename Op>
void JIT::emitPutCallResult(const Op& bytecode)
{
    emitValueProfilingSite(bytecode, JSValueRegs(regT1, regT0));
    emitStore(destinationFor(bytecode, m_bytecodeIndex.checkpoint()).virtualRegister(), regT1, regT0);
}

void JIT::emit_op_ret(const Instruction* currentInstruction)
{
    auto bytecode = currentInstruction->as<OpRet>();
    VirtualRegister value = bytecode.m_value;

    emitLoad(value, regT1, regT0);

    checkStackPointerAlignment();
    emitRestoreCalleeSaves();
    emitFunctionEpilogue();
    ret();
}

void JIT::emitSlow_op_call(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpCall>(currentInstruction, iter, m_callLinkInfoIndex++);
}

void JIT::emitSlow_op_tail_call(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpTailCall>(currentInstruction, iter, m_callLinkInfoIndex++);
}

void JIT::emitSlow_op_call_eval(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpCallEval>(currentInstruction, iter, m_callLinkInfoIndex);
}
 
void JIT::emitSlow_op_call_varargs(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpCallVarargs>(currentInstruction, iter, m_callLinkInfoIndex++);
}

void JIT::emitSlow_op_tail_call_varargs(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpTailCallVarargs>(currentInstruction, iter, m_callLinkInfoIndex++);
}

void JIT::emitSlow_op_tail_call_forward_arguments(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpTailCallForwardArguments>(currentInstruction, iter, m_callLinkInfoIndex++);
}
    
void JIT::emitSlow_op_construct_varargs(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpConstructVarargs>(currentInstruction, iter, m_callLinkInfoIndex++);
}
    
void JIT::emitSlow_op_construct(const Instruction* currentInstruction, Vector<SlowCaseEntry>::iterator& iter)
{
    compileOpCallSlowCase<OpConstruct>(currentInstruction, iter, m_callLinkInfoIndex++);
}

void JIT::emit_op_call(const Instruction* currentInstruction)
{
    compileOpCall<OpCall>(currentInstruction, m_callLinkInfoIndex++);
}

void JIT::emit_op_tail_call(const Instruction* currentInstruction)
{
    compileOpCall<OpTailCall>(currentInstruction, m_callLinkInfoIndex++);
}

void JIT::emit_op_call_eval(const Instruction* currentInstruction)
{
    compileOpCall<OpCallEval>(currentInstruction, m_callLinkInfoIndex);
}

void JIT::emit_op_call_varargs(const Instruction* currentInstruction)
{
    compileOpCall<OpCallVarargs>(currentInstruction, m_callLinkInfoIndex++);
}

void JIT::emit_op_tail_call_varargs(const Instruction* currentInstruction)
{
    compileOpCall<OpTailCallVarargs>(currentInstruction, m_callLinkInfoIndex++);
}

void JIT::emit_op_tail_call_forward_arguments(const Instruction* currentInstruction)
{
    compileOpCall<OpTailCallForwardArguments>(currentInstruction, m_callLinkInfoIndex++);
}
    
void JIT::emit_op_construct_varargs(const Instruction* currentInstruction)
{
    compileOpCall<OpConstructVarargs>(currentInstruction, m_callLinkInfoIndex++);
}
    
void JIT::emit_op_construct(const Instruction* currentInstruction)
{
    compileOpCall<OpConstruct>(currentInstruction, m_callLinkInfoIndex++);
}

template <typename Op>
std::enable_if_t<
    Op::opcodeID != op_call_varargs && Op::opcodeID != op_construct_varargs
    && Op::opcodeID != op_tail_call_varargs && Op::opcodeID != op_tail_call_forward_arguments
, void>
JIT::compileSetupFrame(const Op& bytecode, JITConstantPool::Constant)
{
    unsigned checkpoint = m_bytecodeIndex.checkpoint();
    int argCount = argumentCountIncludingThisFor(bytecode, checkpoint);
    int registerOffset = -static_cast<int>(stackOffsetInRegistersForCall(bytecode, checkpoint));

    if (Op::opcodeID == op_call && shouldEmitProfiling()) {
        emitLoad(VirtualRegister(registerOffset + CallFrame::argumentOffsetIncludingThis(0)), regT0, regT1);
        Jump done = branchIfNotCell(regT0);
        load32(Address(regT1, JSCell::structureIDOffset()), regT1);
        store32ToMetadata(regT1, bytecode, OpCall::Metadata::offsetOfCallLinkInfo() + LLIntCallLinkInfo::offsetOfArrayProfile() + ArrayProfile::offsetOfLastSeenStructureID());
        done.link(this);
    }

    addPtr(TrustedImm32(registerOffset * sizeof(Register) + sizeof(CallerFrameAndPC)), callFrameRegister, stackPointerRegister);
    store32(TrustedImm32(argCount), Address(stackPointerRegister, CallFrameSlot::argumentCountIncludingThis * static_cast<int>(sizeof(Register)) + PayloadOffset - sizeof(CallerFrameAndPC)));
}

template<typename Op>
std::enable_if_t<
    Op::opcodeID == op_call_varargs || Op::opcodeID == op_construct_varargs
    || Op::opcodeID == op_tail_call_varargs || Op::opcodeID == op_tail_call_forward_arguments
, void>
JIT::compileSetupFrame(const Op& bytecode, JITConstantPool::Constant callLinkInfoConstant)
{
    VirtualRegister thisValue = bytecode.m_thisValue;
    VirtualRegister arguments = bytecode.m_arguments;
    int firstFreeRegister = bytecode.m_firstFree.offset();
    int firstVarArgOffset = bytecode.m_firstVarArg;

    emitLoad(arguments, regT1, regT0);
    Z_JITOperation_GJZZ sizeOperation;
    if (Op::opcodeID == op_tail_call_forward_arguments)
        sizeOperation = operationSizeFrameForForwardArguments;
    else
        sizeOperation = operationSizeFrameForVarargs;
    callOperation(sizeOperation, TrustedImmPtr(m_profiledCodeBlock->globalObject()), JSValueRegs(regT1, regT0), -firstFreeRegister, firstVarArgOffset);
    move(TrustedImm32(-firstFreeRegister), regT1);
    emitSetVarargsFrame(*this, returnValueGPR, false, regT1, regT1);
    addPtr(TrustedImm32(-(sizeof(CallerFrameAndPC) + WTF::roundUpToMultipleOf(stackAlignmentBytes(), 6 * sizeof(void*)))), regT1, stackPointerRegister);
    emitLoad(arguments, regT2, regT4);
    F_JITOperation_GFJZZ setupOperation;
    if (Op::opcodeID == op_tail_call_forward_arguments)
        setupOperation = operationSetupForwardArgumentsFrame;
    else
        setupOperation = operationSetupVarargsFrame;
    callOperation(setupOperation, TrustedImmPtr(m_profiledCodeBlock->globalObject()), regT1, JSValueRegs(regT2, regT4), firstVarArgOffset, regT0);
    move(returnValueGPR, regT1);

    // Profile the argument count.
    load32(Address(regT1, CallFrameSlot::argumentCountIncludingThis * static_cast<int>(sizeof(Register)) + PayloadOffset), regT2);
    loadConstant(callLinkInfoConstant, regT0);
    load32(Address(regT0, CallLinkInfo::offsetOfMaxArgumentCountIncludingThis()), regT3);
    Jump notBiggest = branch32(Above, regT3, regT2);
    store32(regT2, Address(regT0, CallLinkInfo::offsetOfMaxArgumentCountIncludingThis()));
    notBiggest.link(this);

    // Initialize 'this'.
    emitLoad(thisValue, regT2, regT0);
    store32(regT0, Address(regT1, PayloadOffset + (CallFrame::thisArgumentOffset() * static_cast<int>(sizeof(Register)))));
    store32(regT2, Address(regT1, TagOffset + (CallFrame::thisArgumentOffset() * static_cast<int>(sizeof(Register)))));

    addPtr(TrustedImm32(sizeof(CallerFrameAndPC)), regT1, stackPointerRegister);
}

template<typename Op>
bool JIT::compileCallEval(const Op&)
{
    return false;
}

template<>
bool JIT::compileCallEval(const OpCallEval& bytecode)
{
    addPtr(TrustedImm32(-static_cast<ptrdiff_t>(sizeof(CallerFrameAndPC))), stackPointerRegister, argumentGPR1);
    storePtr(callFrameRegister, Address(argumentGPR1, CallFrame::callerFrameOffset()));

    resetSP();

    move(TrustedImm32(bytecode.m_ecmaMode.value()), argumentGPR2);
    callOperation(operationCallEval, TrustedImmPtr(m_profiledCodeBlock->globalObject()), regT1, regT2);
    addSlowCase(branchIfEmpty(returnValueGPR));

    emitPutCallResult(bytecode);

    return true;
}

void JIT::compileCallEvalSlowCase(const Instruction* instruction, Vector<SlowCaseEntry>::iterator& iter)
{
    linkAllSlowCases(iter);

    auto bytecode = instruction->as<OpCallEval>();
    CallLinkInfo* info = m_evalCallLinkInfos.add(CodeOrigin(m_bytecodeIndex));
    info->setUpCall(CallLinkInfo::Call, regT0);

    int registerOffset = -bytecode.m_argv;
    VirtualRegister callee = bytecode.m_callee;

    addPtr(TrustedImm32(registerOffset * sizeof(Register) + sizeof(CallerFrameAndPC)), callFrameRegister, stackPointerRegister);

    emitLoad(callee, regT1, regT0);
    
    // FIXME: do we need more registers here to load the global object?
    loadGlobalObject(regT3);
    emitVirtualCallWithoutMovingGlobalObject(*m_vm, info);
    
    resetSP();

    emitPutCallResult(bytecode);
}

template <typename Op>
void JIT::compileOpCall(const Instruction* instruction, unsigned callLinkInfoIndex)
{
    OpcodeID opcodeID = Op::opcodeID;
    auto bytecode = instruction->as<Op>();
    VirtualRegister callee = calleeFor(bytecode, m_bytecodeIndex.checkpoint());

    /* Caller always:
        - Updates callFrameRegister to callee callFrame.
        - Initializes ArgumentCount; CallerFrame; Callee.

       For a JS call:
        - Callee initializes ReturnPC; CodeBlock.
        - Callee restores callFrameRegister before return.

       For a non-JS call:
        - Caller initializes ReturnPC; CodeBlock.
        - Caller restores callFrameRegister after return.
    */
    UnlinkedCallLinkInfo* info = nullptr;
    JITConstantPool::Constant infoConstant = UINT_MAX;
    if (opcodeID != op_call_eval) {
        info = m_unlinkedCalls.add();
        info->bytecodeIndex = m_bytecodeIndex;
        info->callType = CallLinkInfo::callTypeFor(opcodeID);

        infoConstant = addToConstantPool(JITConstantPool::Type::CallLinkInfo, info);

        ASSERT(m_callCompilationInfo.size() == callLinkInfoIndex);
        m_callCompilationInfo.append(CallCompilationInfo());
        m_callCompilationInfo[callLinkInfoIndex].unlinkedCallLinkInfo = info;
        m_callCompilationInfo[callLinkInfoIndex].callLinkInfoConstant = infoConstant;
    }
    compileSetupFrame(bytecode, infoConstant);
    
    // SP holds newCallFrame + sizeof(CallerFrameAndPC), with ArgumentCount initialized.
    uint32_t locationBits = CallSiteIndex(m_bytecodeIndex).bits();
    store32(TrustedImm32(locationBits), Address(callFrameRegister, CallFrameSlot::argumentCountIncludingThis * static_cast<int>(sizeof(Register)) + TagOffset));
    emitLoad(callee, regT1, regT0); // regT1, regT0 holds callee.

    store32(regT0, Address(stackPointerRegister, CallFrameSlot::callee * static_cast<int>(sizeof(Register)) + PayloadOffset - sizeof(CallerFrameAndPC)));
    store32(regT1, Address(stackPointerRegister, CallFrameSlot::callee * static_cast<int>(sizeof(Register)) + TagOffset - sizeof(CallerFrameAndPC)));

    if (compileCallEval(bytecode))
        return;

    loadConstant(infoConstant, regT2);
    if (opcodeID == op_tail_call || opcodeID == op_tail_call_varargs || opcodeID == op_tail_call_forward_arguments) {
        auto slowPaths = CallLinkInfo::emitTailCallDataICFastPath(*this, regT0, regT2, [&] {
            emitRestoreCalleeSaves();
            prepareForTailCallSlow(regT2);
        });
        addSlowCase(slowPaths);
        auto doneLocation = label();
        m_callCompilationInfo[callLinkInfoIndex].doneLocation = doneLocation;
        return;
    }

    auto slowPaths = CallLinkInfo::emitDataICFastPath(*this, regT0, regT2);
    auto doneLocation = label();
    addSlowCase(slowPaths);

    m_callCompilationInfo[callLinkInfoIndex].doneLocation = doneLocation;

    resetSP();

    emitPutCallResult(bytecode);
}

template <typename Op>
void JIT::compileOpCallSlowCase(const Instruction* instruction, Vector<SlowCaseEntry>::iterator& iter, unsigned callLinkInfoIndex)
{
    OpcodeID opcodeID = Op::opcodeID;
    if (opcodeID == op_call_eval) {
        compileCallEvalSlowCase(instruction, iter);
        return;
    }

    linkAllSlowCases(iter);


    move(TrustedImmPtr(m_profiledCodeBlock->globalObject()), regT3);
    loadConstant(m_callCompilationInfo[callLinkInfoIndex].callLinkInfoConstant, regT2);

    if (opcodeID == op_tail_call || opcodeID == op_tail_call_varargs || opcodeID == op_tail_call_forward_arguments)
        emitRestoreCalleeSaves();

    CallLinkInfo::emitDataICSlowPath(*m_vm, *this, regT2);

    if (opcodeID == op_tail_call || opcodeID == op_tail_call_varargs || opcodeID == op_tail_call_forward_arguments) {
        abortWithReason(JITDidReturnFromTailCall);
        return;
    }

    resetSP();

    auto bytecode = instruction->as<Op>();
    emitPutCallResult(bytecode);
}

void JIT::emit_op_iterator_open(const Instruction* instruction)
{
    auto bytecode = instruction->as<OpIteratorOpen>();
    auto* tryFastFunction = ([&] () {
        switch (instruction->width()) {
        case Narrow: return iterator_open_try_fast_narrow;
        case Wide16: return iterator_open_try_fast_wide16;
        case Wide32: return iterator_open_try_fast_wide32;
        default: RELEASE_ASSERT_NOT_REACHED();
        }
    })();

    JITSlowPathCall slowPathCall(this, instruction, tryFastFunction);
    slowPathCall.call();
    Jump fastCase = branch32(NotEqual, GPRInfo::returnValueGPR2, TrustedImm32(static_cast<uint32_t>(IterationMode::Generic)));

    compileOpCall<OpIteratorOpen>(instruction, m_callLinkInfoIndex++);

    advanceToNextCheckpoint();

    // call result (iterator) is in regT1 (tag)/regT0 (payload)
    const Identifier* ident = &vm().propertyNames->next;

    emitJumpSlowCaseIfNotJSCell(regT1);

    GPRReg tagIteratorGPR = regT1;
    GPRReg payloadIteratorGPR = regT0;

    GPRReg tagNextGPR = tagIteratorGPR;
    GPRReg payloadNextGPR = payloadIteratorGPR;

    JSValueRegs nextRegs = JSValueRegs(tagNextGPR, payloadNextGPR);

    JITGetByIdGenerator gen(
        nullptr, JITType::BaselineJIT, CodeOrigin(m_bytecodeIndex), CallSiteIndex(BytecodeIndex(m_bytecodeIndex.offset())), RegisterSet::stubUnavailableRegisters(),
        CacheableIdentifier::createFromImmortalIdentifier(ident->impl()), JSValueRegs(tagIteratorGPR, payloadIteratorGPR), nextRegs, regT2, AccessType::GetById);

    UnlinkedStructureStubInfo* stubInfo = m_unlinkedStubInfos.add();
    stubInfo->accessType = AccessType::GetById;
    stubInfo->bytecodeIndex = m_bytecodeIndex;
    JITConstantPool::Constant stubInfoIndex = addToConstantPool(JITConstantPool::Type::StructureStubInfo, stubInfo);
    gen.m_unlinkedStubInfoConstantIndex = stubInfoIndex;
    gen.m_unlinkedStubInfo = stubInfo;

    gen.generateBaselineDataICFastPath(*this, stubInfoIndex, regT2);
    resetSP(); // We might OSR exit here, so we need to conservatively reset SP
    addSlowCase();
    m_getByIds.append(gen);

    emitValueProfilingSite(bytecode, nextRegs);
    emitPutVirtualRegister(bytecode.m_next, nextRegs);

    fastCase.link(this);
}

void JIT::emitSlow_op_iterator_open(const Instruction* instruction, Vector<SlowCaseEntry>::iterator& iter)
{
    linkAllSlowCases(iter);
    compileOpCallSlowCase<OpIteratorOpen>(instruction, iter, m_callLinkInfoIndex++);
    emitJumpSlowToHotForCheckpoint(jump());

    linkAllSlowCases(iter);

    GPRReg tagIteratorGPR = regT1;
    GPRReg payloadIteratorGPR = regT0;

    JumpList notObject;
    notObject.append(branchIfNotCell(tagIteratorGPR));
    notObject.append(branchIfNotObject(payloadIteratorGPR));

    auto bytecode = instruction->as<OpIteratorOpen>();
    VirtualRegister nextVReg = bytecode.m_next;
    UniquedStringImpl* ident = vm().propertyNames->next.impl();

    JITGetByIdGenerator& gen = m_getByIds[m_getByIdIndex++];

    Label coldPathBegin = label();

    loadConstant(gen.m_unlinkedStubInfoConstantIndex, argumentGPR1);
    callOperationWithProfile<decltype(operationGetByIdOptimize)>(
        bytecode,
        Address(argumentGPR1, StructureStubInfo::offsetOfSlowOperation()),
        nextVReg, // result
        TrustedImmPtr(m_profiledCodeBlock->globalObject()), // arg1
        argumentGPR1,
        JSValueRegs(tagIteratorGPR, payloadIteratorGPR), // arg3
        CacheableIdentifier::createFromImmortalIdentifier(ident).rawBits()); // arg4
    gen.reportSlowPathCall(coldPathBegin, Call());

    auto done = jump();

    notObject.link(this);
    callOperation(operationThrowIteratorResultIsNotObject, TrustedImmPtr(m_profiledCodeBlock->globalObject()));

    done.link(this);
}

void JIT::emit_op_iterator_next(const Instruction* instruction)
{
    auto bytecode = instruction->as<OpIteratorNext>();
    auto* tryFastFunction = ([&] () {
        switch (instruction->width()) {
        case Narrow: return iterator_next_try_fast_narrow;
        case Wide16: return iterator_next_try_fast_wide16;
        case Wide32: return iterator_next_try_fast_wide32;
        default: RELEASE_ASSERT_NOT_REACHED();
        }
    })();

    JSValueRegs nextRegs(regT1, regT0);
    emitGetVirtualRegister(bytecode.m_next, nextRegs);
    Jump genericCase = branchIfNotEmpty(nextRegs);

    JITSlowPathCall slowPathCall(this, instruction, tryFastFunction);
    slowPathCall.call();
    Jump fastCase = branch32(NotEqual, GPRInfo::returnValueGPR2, TrustedImm32(static_cast<uint32_t>(IterationMode::Generic)));

    genericCase.link(this);

    // FIXME: why are we loading the metadata from the payload?
    load8FromMetadata(bytecode, OpIteratorNext::Metadata::offsetOfIterationMetadata() + IterationModeMetadata::offsetOfSeenModes(), nextRegs.payloadGPR());
    or32(TrustedImm32(static_cast<uint8_t>(IterationMode::Generic)), nextRegs.payloadGPR());
    store8ToMetadata(nextRegs.payloadGPR(), bytecode, OpIteratorNext::Metadata::offsetOfIterationMetadata() + IterationModeMetadata::offsetOfSeenModes());

    compileOpCall<OpIteratorNext>(instruction, m_callLinkInfoIndex++);
    advanceToNextCheckpoint();
    // call result ({ done, value } JSObject) in regT1, regT0

    GPRReg tagValueGPR = regT1;
    GPRReg payloadValueGPR = regT0;

    GPRReg tagDoneGPR = regT5;
    GPRReg payloadDoneGPR = regT4;

    {
        JSValueRegs doneRegs = JSValueRegs(tagDoneGPR, payloadDoneGPR);

        GPRReg tagIterResultGPR = regT3;
        GPRReg payloadIterResultGPR = regT2;

        // iterResultGPR will get trashed by the first get by id below.
        move(regT1, tagIterResultGPR);
        move(regT0, payloadIterResultGPR);

        emitJumpSlowCaseIfNotJSCell(tagIterResultGPR);

        RegisterSet preservedRegs = RegisterSet::stubUnavailableRegisters();
        preservedRegs.add(tagValueGPR);
        preservedRegs.add(payloadValueGPR);
        JITGetByIdGenerator gen(
            nullptr,
            JITType::BaselineJIT,
            CodeOrigin(m_bytecodeIndex),
            CallSiteIndex(BytecodeIndex(m_bytecodeIndex.offset())),
            preservedRegs,
            CacheableIdentifier::createFromImmortalIdentifier(vm().propertyNames->done.impl()),
            JSValueRegs(tagIterResultGPR, payloadIterResultGPR),
            doneRegs,
            regT6,
            AccessType::GetById);

        UnlinkedStructureStubInfo* stubInfo = m_unlinkedStubInfos.add();
        stubInfo->accessType = AccessType::GetById;
        stubInfo->bytecodeIndex = m_bytecodeIndex;
        JITConstantPool::Constant stubInfoIndex = addToConstantPool(JITConstantPool::Type::StructureStubInfo, stubInfo);
        gen.m_unlinkedStubInfoConstantIndex = stubInfoIndex;
        gen.m_unlinkedStubInfo = stubInfo;

        gen.generateBaselineDataICFastPath(*this, stubInfoIndex, regT6);
        resetSP(); // We might OSR exit here, so we need to conservatively reset SP
        addSlowCase();
        m_getByIds.append(gen);

        emitValueProfilingSite(bytecode, doneRegs);
        emitPutVirtualRegister(bytecode.m_done, doneRegs);
        advanceToNextCheckpoint();
    }

    {
        RegisterSet usedRegisters(tagValueGPR, payloadValueGPR, tagDoneGPR, payloadDoneGPR);
        ScratchRegisterAllocator scratchAllocator(usedRegisters);
        GPRReg scratch1 = scratchAllocator.allocateScratchGPR();
        GPRReg scratch2 = scratchAllocator.allocateScratchGPR();
        GPRReg globalGPR = scratchAllocator.allocateScratchGPR();

        JSValueRegs resultRegs = JSValueRegs(tagValueGPR, payloadValueGPR);
        GPRReg tagIterResultGPR = tagValueGPR;
        GPRReg payloadIterResultGPR = payloadValueGPR;
                
        const bool shouldCheckMasqueradesAsUndefined = false;
        loadGlobalObject(globalGPR);
        JumpList iterationDone = branchIfTruthy(vm(), JSValueRegs(tagDoneGPR, payloadDoneGPR), scratch1, scratch2, fpRegT0, fpRegT1, shouldCheckMasqueradesAsUndefined, globalGPR);

        JITGetByIdGenerator gen(
            nullptr,
            JITType::BaselineJIT,
            CodeOrigin(m_bytecodeIndex),
            CallSiteIndex(BytecodeIndex(m_bytecodeIndex.offset())),
            RegisterSet::stubUnavailableRegisters(),
            CacheableIdentifier::createFromImmortalIdentifier(vm().propertyNames->value.impl()),
            JSValueRegs(tagIterResultGPR, payloadIterResultGPR),
            resultRegs,
            regT6,
            AccessType::GetById);

        UnlinkedStructureStubInfo* stubInfo = m_unlinkedStubInfos.add();
        stubInfo->accessType = AccessType::GetById;
        stubInfo->bytecodeIndex = m_bytecodeIndex;
        JITConstantPool::Constant stubInfoIndex = addToConstantPool(JITConstantPool::Type::StructureStubInfo, stubInfo);
        gen.m_unlinkedStubInfoConstantIndex = stubInfoIndex;
        gen.m_unlinkedStubInfo = stubInfo;

        gen.generateBaselineDataICFastPath(*this, stubInfoIndex, regT6);
        resetSP(); // We might OSR exit here, so we need to conservatively reset SP
        addSlowCase();
        m_getByIds.append(gen);

        emitValueProfilingSite(bytecode, resultRegs);
        emitPutVirtualRegister(bytecode.m_value, resultRegs);

        iterationDone.link(this);
    }

    fastCase.link(this);
}

void JIT::emitSlow_op_iterator_next(const Instruction* instruction, Vector<SlowCaseEntry>::iterator& iter)
{
    linkAllSlowCases(iter);
    compileOpCallSlowCase<OpIteratorNext>(instruction, iter, m_callLinkInfoIndex++);
    emitJumpSlowToHotForCheckpoint(jump());

    GPRReg tagIterResultGPR = regT3;
    GPRReg payloadIterResultGPR = regT2;

    auto bytecode = instruction->as<OpIteratorNext>();
    {
        VirtualRegister doneVReg = bytecode.m_done;

        linkAllSlowCases(iter);
        JumpList notObject;
        notObject.append(branchIfNotCell(tagIterResultGPR));

        UniquedStringImpl* ident = vm().propertyNames->done.impl();
        JITGetByIdGenerator& gen = m_getByIds[m_getByIdIndex++];

        Label coldPathBegin = label();
        
        notObject.append(branchIfNotObject(payloadIterResultGPR));
        
        loadConstant(gen.m_unlinkedStubInfoConstantIndex, regT6);
        callOperationWithProfile<decltype(operationGetByIdOptimize)>(
            bytecode, // metadata
            Address(regT6, StructureStubInfo::offsetOfSlowOperation()), 
            doneVReg, // result
            TrustedImmPtr(m_profiledCodeBlock->globalObject()), // arg1
            regT6, // arg2
            JSValueRegs(tagIterResultGPR, payloadIterResultGPR), // arg3
            CacheableIdentifier::createFromImmortalIdentifier(ident).rawBits());

        gen.reportSlowPathCall(coldPathBegin, Call());

        GPRReg tagDoneGPR = regT5;
        GPRReg payloadDoneGPR = regT4;

        GPRReg tagValueGPR = regT1;
        GPRReg payloadValueGPR = regT0;

        emitGetVirtualRegister(doneVReg, JSValueRegs(tagDoneGPR, payloadDoneGPR));
        emitGetVirtualRegister(bytecode.m_value, JSValueRegs(tagValueGPR, payloadValueGPR));
        emitJumpSlowToHotForCheckpoint(jump());

        notObject.link(this);
        callOperation(operationThrowIteratorResultIsNotObject, TrustedImmPtr(m_profiledCodeBlock->globalObject()));
    }

    {   
        GPRReg tagIterResultGPR = regT1;
        GPRReg payloadIterResultGPR = regT0;

        linkAllSlowCases(iter);
        VirtualRegister valueVReg = bytecode.m_value;

        UniquedStringImpl* ident = vm().propertyNames->value.impl();
        JITGetByIdGenerator& gen = m_getByIds[m_getByIdIndex++];

        Label coldPathBegin = label();

        loadConstant(gen.m_unlinkedStubInfoConstantIndex, regT6);
        callOperationWithProfile<decltype(operationGetByIdOptimize)>(
            bytecode, 
            Address(regT6, StructureStubInfo::offsetOfSlowOperation()), 
            valueVReg, // result
            TrustedImmPtr(m_profiledCodeBlock->globalObject()), // arg1
            regT6, // arg2
            JSValueRegs(tagIterResultGPR, payloadIterResultGPR), // arg3
            CacheableIdentifier::createFromImmortalIdentifier(ident).rawBits()); // arg4
        gen.reportSlowPathCall(coldPathBegin, Call());
    }
}

} // namespace JSC

#endif // USE(JSVALUE32_64)
#endif // ENABLE(JIT)
