/*
 * Copyright (c) 2008, 2023, Oracle and/or its affiliates. All rights reserved.
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

#ifndef OS_CPU_WINDOWS_ARM_ATOMIC_WINDOWS_ARM_HPP
#define OS_CPU_WINDOWS_ARM_ATOMIC_WINDOWS_ARM_HPP

#include "memory/allStatic.hpp"
#include "runtime/os.hpp"
#include "runtime/vm_version.hpp"

// os_cpu/linux_arm reaches these through ARMAtomicFuncs, function pointers into
// the kernel user helper page at 0xffff0fxx, because ARM CPUs before v7 have no
// usable ldrex/strex. Windows on ARM has no such page and no pre-v7 CPU, so go
// straight to the compiler builtins, which lower to ldrex/strex plus dmb here.
//
// atomic.hpp requires every read-modify-write to carry two-way barrier
// semantics, so each of these asks for __ATOMIC_SEQ_CST and the memory_order
// argument is ignored, exactly as the linux_arm port ignores it.

template<>
template<typename T>
inline T Atomic::PlatformLoad<8>::operator()(T const volatile* src) const {
  STATIC_ASSERT(8 == sizeof(T));
  // 64-bit on 32-bit ARM is ldrexd/strexd, which the builtin knows to use; a
  // plain load would not be atomic.
  int64_t v = __atomic_load_n(reinterpret_cast<const volatile int64_t*>(src),
                              __ATOMIC_SEQ_CST);
  return PrimitiveConversions::cast<T>(v);
}

template<>
template<typename T>
inline void Atomic::PlatformStore<8>::operator()(T volatile* dest,
                                                 T store_value) const {
  STATIC_ASSERT(8 == sizeof(T));
  __atomic_store_n(reinterpret_cast<volatile int64_t*>(dest),
                   PrimitiveConversions::cast<int64_t>(store_value),
                   __ATOMIC_SEQ_CST);
}

template<size_t byte_size>
struct Atomic::PlatformAdd {
  template<typename D, typename I>
  D add_then_fetch(D volatile* dest, I add_value, atomic_memory_order order) const;

  template<typename D, typename I>
  D fetch_then_add(D volatile* dest, I add_value, atomic_memory_order order) const {
    return add_then_fetch(dest, add_value, order) - add_value;
  }
};

template<>
template<typename D, typename I>
inline D Atomic::PlatformAdd<4>::add_then_fetch(D volatile* dest, I add_value,
                                                atomic_memory_order order) const {
  STATIC_ASSERT(4 == sizeof(I));
  STATIC_ASSERT(4 == sizeof(D));
  return __atomic_add_fetch(dest, add_value, __ATOMIC_SEQ_CST);
}

// No direct support for 8-byte add; emulate using cmpxchg.
template<>
struct Atomic::PlatformAdd<8> : Atomic::AddUsingCmpxchg<8> {};

template<>
template<typename T>
inline T Atomic::PlatformXchg<4>::operator()(T volatile* dest,
                                             T exchange_value,
                                             atomic_memory_order order) const {
  STATIC_ASSERT(4 == sizeof(T));
  return __atomic_exchange_n(dest, exchange_value, __ATOMIC_SEQ_CST);
}

// No direct support for 8-byte xchg; emulate using cmpxchg.
template<>
struct Atomic::PlatformXchg<8> : Atomic::XchgUsingCmpxchg<8> {};

// No direct support for cmpxchg of bytes; emulate using int.
template<>
struct Atomic::PlatformCmpxchg<1> : Atomic::CmpxchgByteUsingInt {};

// __atomic_compare_exchange_n writes the seen value back through its expected
// argument, so hand it a copy and return that; hotspot wants the previous value
// whether or not the exchange happened.
template<>
template<typename T>
inline T Atomic::PlatformCmpxchg<4>::operator()(T volatile* dest,
                                                T compare_value,
                                                T exchange_value,
                                                atomic_memory_order order) const {
  STATIC_ASSERT(4 == sizeof(T));
  T expected = compare_value;
  __atomic_compare_exchange_n(dest, &expected, exchange_value,
                              /*weak*/ false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  return expected;
}

template<>
template<typename T>
inline T Atomic::PlatformCmpxchg<8>::operator()(T volatile* dest,
                                                T compare_value,
                                                T exchange_value,
                                                atomic_memory_order order) const {
  STATIC_ASSERT(8 == sizeof(T));
  T expected = compare_value;
  __atomic_compare_exchange_n(dest, &expected, exchange_value,
                              /*weak*/ false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  return expected;
}

#endif // OS_CPU_WINDOWS_ARM_ATOMIC_WINDOWS_ARM_HPP
