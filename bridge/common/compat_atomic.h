/*
 * compat_atomic.h - C11 <stdatomic.h> compatibility for GCC < 4.9
 *
 * GCC 4.8 supports __atomic_* builtins but not <stdatomic.h>.
 * This header provides the C11 atomic API using GCC builtins.
 */
#ifndef COMPAT_ATOMIC_H
#define COMPAT_ATOMIC_H

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L && \
    !defined(__STDC_NO_ATOMICS__) && \
    !(defined(__GNUC__) && __GNUC__ == 4 && __GNUC_MINOR__ < 9)
/* Compiler natively supports <stdatomic.h> */
#include <stdatomic.h>

#else
/* GCC 4.8 fallback using __atomic builtins */

#include <stdint.h>

/* Memory order constants */
#define memory_order_relaxed __ATOMIC_RELAXED
#define memory_order_consume __ATOMIC_CONSUME
#define memory_order_acquire __ATOMIC_ACQUIRE
#define memory_order_release __ATOMIC_RELEASE
#define memory_order_acq_rel __ATOMIC_ACQ_REL
#define memory_order_seq_cst __ATOMIC_SEQ_CST

/* _Atomic qualifier - GCC 4.8 doesn't support it, use volatile */
#define _Atomic volatile

/* Atomic type aliases */
typedef volatile int            atomic_int;
typedef volatile uint32_t       atomic_uint_least32_t;
typedef volatile uint64_t       atomic_uint_least64_t;

/* atomic_store / atomic_load */
#define atomic_store(ptr, val) \
    __atomic_store_n(ptr, val, __ATOMIC_SEQ_CST)

#define atomic_load(ptr) \
    __atomic_load_n(ptr, __ATOMIC_SEQ_CST)

/* atomic_store_explicit / atomic_load_explicit */
#define atomic_store_explicit(ptr, val, order) \
    __atomic_store_n(ptr, val, order)

#define atomic_load_explicit(ptr, order) \
    __atomic_load_n(ptr, order)

/* atomic_exchange */
#define atomic_exchange(ptr, val) \
    __atomic_exchange_n(ptr, val, __ATOMIC_SEQ_CST)

/* atomic_compare_exchange_weak */
#define atomic_compare_exchange_weak(ptr, expected, desired) \
    __atomic_compare_exchange_n(ptr, expected, desired, 1, \
                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)

/* atomic_fetch_add / atomic_fetch_sub */
#define atomic_fetch_add(ptr, val) \
    __atomic_fetch_add(ptr, val, __ATOMIC_SEQ_CST)

#define atomic_fetch_sub(ptr, val) \
    __atomic_fetch_sub(ptr, val, __ATOMIC_SEQ_CST)

#endif /* stdatomic check */
#endif /* COMPAT_ATOMIC_H */
