/*
 * Copyright (c) 2008, 2025, Oracle and/or its affiliates. All rights reserved.
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

#include "gc/shared/barrierSet.hpp"
#include "gc/shared/cardTable.hpp"
#include "gc/shared/cardTableBarrierSet.inline.hpp"
#include "gc/shared/collectedHeap.hpp"
#include "memory/universe.hpp"
#include "runtime/frame.inline.hpp"
#include "runtime/javaThread.hpp"

// The ARM32 body from os_cpu/linux_arm, with the thread context taken from a
// windows CONTEXT rather than a ucontext_t. The card table cache and the
// unsafe-section guard are CPU-level, not OS-level: the cpu/arm JIT reads both
// through the Rthread register, so they stay.

frame JavaThread::pd_last_frame() {
  assert(has_last_Java_frame(), "must have last_Java_sp() when suspended");
  if (_anchor.last_Java_pc() != nullptr) {
    return frame(_anchor.last_Java_sp(), _anchor.last_Java_fp(), _anchor.last_Java_pc());
  } else {
    // This will pick up pc from sp
    return frame(_anchor.last_Java_sp(), _anchor.last_Java_fp());
  }
}

void JavaThread::cache_global_variables() {
  BarrierSet* bs = BarrierSet::barrier_set();

  if (bs->is_a(BarrierSet::CardTableBarrierSet)) {
    _card_table_base = (address) (barrier_set_cast<CardTableBarrierSet>(bs)->card_table()->byte_map_base());
  } else {
    _card_table_base = nullptr;
  }
}

bool JavaThread::pd_get_top_frame_for_signal_handler(frame* fr_addr,
  void* ucontext, bool isInJava) {
  assert(Thread::current() == this, "caller must be current thread");
  return pd_get_top_frame(fr_addr, ucontext, isInJava);
}

bool JavaThread::pd_get_top_frame_for_profiling(frame* fr_addr, void* ucontext, bool isInJava) {
  return pd_get_top_frame(fr_addr, ucontext, isInJava);
}

bool JavaThread::pd_get_top_frame(frame* fr_addr, void* ucontext, bool isInJava) {
  // If we have a last_Java_frame, then we should use it even if
  // isInJava == true.  It should be more reliable than CONTEXT info.
  if (has_last_Java_frame()) {
    *fr_addr = pd_last_frame();
    return true;
  }

  // Could be in a code section that plays with the stack, like
  // MacroAssembler::verify_heapbase()
  if (in_top_frame_unsafe_section()) {
    return false;
  }

  // At this point, we don't have a last_Java_frame, so
  // we try to glean some information out of the CONTEXT
  // if we were running Java code when the profiler interrupted us.
  if (isInJava) {
    intptr_t* ret_fp;
    intptr_t* ret_sp;
    address addr = os::fetch_frame_from_context(ucontext, &ret_sp, &ret_fp);
    if (addr == nullptr || ret_sp == nullptr) {
      // CONTEXT wasn't useful
      return false;
    }

    frame ret_frame(ret_sp, ret_fp, addr);
    if (!ret_frame.safe_for_sender(this)) {
#ifdef COMPILER2
      // C2 uses fp as a general register, see if a null fp helps
      frame ret_frame2(ret_sp, nullptr, addr);
      if (!ret_frame2.safe_for_sender(this)) {
        // nothing else to try if the frame isn't good
        return false;
      }
      ret_frame = ret_frame2;
#else
      // nothing else to try if the frame isn't good
      return false;
#endif /* COMPILER2 */
    }
    *fr_addr = ret_frame;
    return true;
  }

  // nothing else to try
  return false;
}
