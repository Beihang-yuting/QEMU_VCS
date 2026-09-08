/*
 * tests/test_check.h — 测试专用断言宏（tests/unit、tests/integration 共用）
 *
 * 为什么需要这一层：标准 assert() 在 Release/RelWithDebInfo 构建下因
 * NDEBUG 被整体删除。历史上测试普遍写 assert(xxx_open(...) == 0)，
 * 断言一旦被删，带副作用的被测调用也随之消失，导致结构体未初始化
 * 段错误（trace_log/eth_shm 等）或握手缺失死等超时（precise_mode）。
 * CHECK() 不受 NDEBUG 影响：表达式在任何构建类型下都必然求值，
 * 失败时打印表达式原文与文件行号后 abort()，行为与 Debug 下的
 * assert 一致，故测试可安全地把副作用调用写进 CHECK()。
 *
 * 依赖：仅 C 标准库（stdio/stdlib）。无所有权语义——纯宏头文件。
 */
#ifndef COSIM_TEST_CHECK_H
#define COSIM_TEST_CHECK_H

#include <stdio.h>
#include <stdlib.h>

/*
 * CHECK(expr)：恒定生效的测试断言。
 * 失败路径：向 stderr 打印诊断后 abort()，交由测试框架按崩溃计失败。
 * do-while(0) 包裹保证宏在 if/else 等语境下语法安全。
 */
#define CHECK(expr)                                                        \
    do {                                                                   \
        if (!(expr)) {                                                     \
            fprintf(stderr, "CHECK failed: %s (%s:%d)\n",                  \
                    #expr, __FILE__, __LINE__);                            \
            abort();                                                       \
        }                                                                  \
    } while (0)

#endif /* COSIM_TEST_CHECK_H */
