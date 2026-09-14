/*
 * Copyright (c) 2020, Microsoft Corporation. All rights reserved.
 * Copyright (c) 2022, 2025, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 *
 */

#include "asm/macroAssembler.hpp"
#include "classfile/vmSymbols.hpp"
#include "code/codeCache.hpp"
#include "code/vtableStubs.hpp"
#include "code/nativeInst.hpp"
#include "interpreter/interpreter.hpp"
#include "jvm.h"
#include "memory/allocation.inline.hpp"
#include "os_windows.hpp"
#include "prims/jniFastGetField.hpp"
#include "prims/jvm_misc.hpp"
#include "runtime/arguments.hpp"
#include "runtime/frame.inline.hpp"
#include "runtime/interfaceSupport.inline.hpp"
#include "runtime/java.hpp"
#include "runtime/javaCalls.hpp"
#include "runtime/javaThread.hpp"
#include "runtime/mutexLocker.hpp"
#include "runtime/osThread.hpp"
#include "runtime/sharedRuntime.hpp"
#include "runtime/stubRoutines.hpp"
#include "runtime/timer.hpp"
#include "utilities/debug.hpp"
#include "utilities/events.hpp"
#include "utilities/vmError.hpp"

// put OS-includes here
# include <sys/types.h>
# include <signal.h>
# include <errno.h>
# include <stdlib.h>
# include <stdio.h>

// The ARM32 registers, spelled the way windows spells them in CONTEXT.
// os_cpu/linux_arm reads the same ones out of a ucontext_t as gregs[15],
// gregs[13] and gregs[11]. The interpreter keeps its bytecode pointer in r7,
// which is a cpu/arm convention rather than a linux one, so it holds here too.
#define REG_BCP R7
#define REG_FP  R11

void os::os_exception_wrapper(java_call_t f, JavaValue* value, const methodHandle& method, JavaCallArguments* args, JavaThread* thread) {
  f(value, method, args, thread);
}

PRAGMA_DISABLE_MSVC_WARNING(4172)
// Returns an estimate of the current stack pointer. Result must be guaranteed
// to point into the calling threads stack, and be no lower than the current
// stack pointer.
address os::current_stack_pointer() {
  int dummy;
  address sp = (address)&dummy;
  return sp;
}

address os::fetch_frame_from_context(const void* ucVoid,
                    intptr_t** ret_sp, intptr_t** ret_fp) {
  address  epc;
  CONTEXT* uc = (CONTEXT*)ucVoid;

  if (uc != nullptr) {
    epc = (address)uc->Pc;
    if (ret_sp) *ret_sp = (intptr_t*)uc->Sp;
    if (ret_fp) *ret_fp = (intptr_t*)uc->REG_FP;
  } else {
    // construct empty ExtendedPC for return value checking
    epc = nullptr;
    if (ret_sp) *ret_sp = (intptr_t *)nullptr;
    if (ret_fp) *ret_fp = (intptr_t *)nullptr;
  }
  return epc;
}

frame os::fetch_frame_from_context(const void* ucVoid) {
  intptr_t* sp;
  intptr_t* fp;
  address epc = fetch_frame_from_context(ucVoid, &sp, &fp);
  return frame(sp, fp, epc);
}

#ifdef ASSERT
static bool is_interpreter(const CONTEXT* uc) {
  assert(uc != nullptr, "invariant");
  address pc = reinterpret_cast<address>(uc->Pc);
  assert(pc != nullptr, "invariant");
  return Interpreter::contains(pc);
}
#endif

intptr_t* os::fetch_bcp_from_context(const void* ucVoid) {
  assert(ucVoid != nullptr, "invariant");
  CONTEXT* uc = (CONTEXT*)ucVoid;
  assert(is_interpreter(uc), "invariant");
  return reinterpret_cast<intptr_t*>(uc->REG_BCP);
}

bool os::win32::get_frame_at_stack_banging_point(JavaThread* thread,
        struct _EXCEPTION_POINTERS* exceptionInfo, address pc, frame* fr) {
  PEXCEPTION_RECORD exceptionRecord = exceptionInfo->ExceptionRecord;
  address addr = (address) exceptionRecord->ExceptionInformation[1];
  if (Interpreter::contains(pc)) {
    // interpreter performs stack banging after the fixed frame header has
    // been generated while the compilers perform it before. To maintain
    // semantic consistency between interpreted and compiled frames, the
    // method returns the Java sender of the current frame.
    *fr = os::fetch_frame_from_context((void*)exceptionInfo->ContextRecord);
    if (!fr->is_first_java_frame()) {
      assert(fr->safe_for_sender(thread), "Safety check");
      *fr = fr->java_sender();
    }
  } else {
    // more complex code with compiled code
    assert(!Interpreter::contains(pc), "Interpreted methods should have been handled above");
    CodeBlob* cb = CodeCache::find_blob(pc);
    if (cb == nullptr || !cb->is_nmethod() || cb->is_frame_complete_at(pc)) {
      // Not sure where the pc points to, fallback to default
      // stack overflow handling
      return false;
    } else {
      // In compiled code, the stack banging is performed before LR
      // has been saved in the frame.  LR is live, and SP and FP
      // belong to the caller.
      intptr_t* fp = (intptr_t*)exceptionInfo->ContextRecord->REG_FP;
      intptr_t* sp = (intptr_t*)exceptionInfo->ContextRecord->Sp;
      address pc = (address)(exceptionInfo->ContextRecord->Lr
                         - NativeInstruction::instruction_size);
      *fr = frame(sp, fp, pc);
      if (!fr->is_java_frame()) {
        assert(fr->safe_for_sender(thread), "Safety check");
        assert(!fr->is_first_frame(), "Safety check");
        *fr = fr->java_sender();
      }
    }
  }
  assert(fr->is_java_frame(), "Safety check");
  return true;
}

frame os::get_sender_for_C_frame(frame* fr) {
  ShouldNotReachHere();
  return frame();
}

frame os::current_frame() {
  return frame();  // cannot walk Windows frames this way.  See os::get_native_stack
                   // and os::platform_print_native_stack
}

/////////////////////////////////////////////////////////////////////////////
// helper functions for fatal error handler

void os::print_context(outputStream *st, const void *context) {
  if (context == nullptr) return;

  const CONTEXT* uc = (const CONTEXT*)context;

  st->print_cr("Registers:");

  st->print(  "R0 =" INTPTR_FORMAT, uc->R0);
  st->print(", R1 =" INTPTR_FORMAT, uc->R1);
  st->print(", R2 =" INTPTR_FORMAT, uc->R2);
  st->print(", R3 =" INTPTR_FORMAT, uc->R3);
  st->cr();
  st->print(  "R4 =" INTPTR_FORMAT, uc->R4);
  st->print(", R5 =" INTPTR_FORMAT, uc->R5);
  st->print(", R6 =" INTPTR_FORMAT, uc->R6);
  st->print(", R7 =" INTPTR_FORMAT, uc->R7);
  st->cr();
  st->print(  "R8 =" INTPTR_FORMAT, uc->R8);
  st->print(", R9 =" INTPTR_FORMAT, uc->R9);
  st->print(", R10=" INTPTR_FORMAT, uc->R10);
  st->print(", R11=" INTPTR_FORMAT, uc->R11);
  st->cr();
  st->print(  "R12=" INTPTR_FORMAT, uc->R12);
  st->print(", SP =" INTPTR_FORMAT, uc->Sp);
  st->print(", LR =" INTPTR_FORMAT, uc->Lr);
  st->print(", PC =" INTPTR_FORMAT, uc->Pc);
  st->cr();
  st->cr();
}

void os::print_register_info(outputStream *st, const void *context, int& continuation) {
  const int register_count = 13 /* R0-R12 */;
  int n = continuation;
  assert(n >= 0 && n <= register_count, "Invalid continuation value");
  if (context == nullptr || n == register_count) {
    return;
  }

  const CONTEXT* uc = (const CONTEXT*)context;
  while (n < register_count) {
    // Update continuation with next index before printing location
    continuation = n + 1;
# define CASE_PRINT_REG(n, str, id) case n: st->print(str); print_location(st, uc->id);
    switch (n) {
      CASE_PRINT_REG( 0, " R0=", R0); break;
      CASE_PRINT_REG( 1, " R1=", R1); break;
      CASE_PRINT_REG( 2, " R2=", R2); break;
      CASE_PRINT_REG( 3, " R3=", R3); break;
      CASE_PRINT_REG( 4, " R4=", R4); break;
      CASE_PRINT_REG( 5, " R5=", R5); break;
      CASE_PRINT_REG( 6, " R6=", R6); break;
      CASE_PRINT_REG( 7, " R7=", R7); break;
      CASE_PRINT_REG( 8, " R8=", R8); break;
      CASE_PRINT_REG( 9, " R9=", R9); break;
      CASE_PRINT_REG(10, "R10=", R10); break;
      CASE_PRINT_REG(11, "R11=", R11); break;
      CASE_PRINT_REG(12, "R12=", R12); break;
    }
# undef CASE_PRINT_REG
    ++n;
  }
}

void os::setup_fpu() {
}

#ifndef PRODUCT
void os::verify_stack_alignment() {
  assert(((intptr_t)os::current_stack_pointer() & (StackAlignmentInBytes-1)) == 0, "incorrect stack alignment");
}
#endif

int os::extra_bang_size_in_bytes() {
  // ARM does not require an additional stack bang.
  return 0;
}

extern "C" {
  int SpinPause() {
    return 0;
  }
};
