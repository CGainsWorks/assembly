/*
 * Shared assembler scaffolding for every kernel in src/asm.
 *
 * The kernel bodies are written once, against the System V AMD64 calling
 * convention: arguments in rdi, rsi, rdx, rcx and the result in rax. This file
 * supplies the three macros that wrap them so the same source also assembles
 * and runs under the Microsoft x64 convention used by Windows:
 *
 *   HP_FUNC name     symbol, type information and alignment, then the entry
 *   HP_RET           every return from a kernel goes through this
 *   HP_ENDFUNC name  closes the symbol
 *
 * On System V these are a plain label, ret and .size.
 *
 * On Windows two things differ that matter here. Arguments arrive in rcx, rdx,
 * r8 and r9, and rdi and rsi are callee saved rather than argument registers.
 * So the Windows entry saves rdi and rsi, moves the four argument registers
 * into their System V positions, and runs the unchanged body; HP_RET restores
 * the two registers on the way out. The saves are described with .seh_*
 * directives, which is what lets the Windows unwinder walk through a kernel if
 * a fault is ever raised inside one.
 *
 * Windows also treats xmm6 to xmm15 as callee saved. No kernel touches them:
 * the SSE and AVX2 kernels stay within xmm0 to xmm5 and ymm0 to ymm4, and the
 * AVX-512 kernels use zmm16 and up, which are volatile on both systems.
 * tests/test_abi.c checks every one of those promises at run time on both.
 *
 * Every kernel is a leaf that never touches the stack, so the shim costs six
 * instructions on entry and two on exit and changes nothing else.
 */
#ifndef HOTPATH_ASM_H
#define HOTPATH_ASM_H

#if defined(_WIN32)

#define HP_RODATA_SECTION .section .rdata,"dr"
#define HP_NOTE_GNU_STACK

    .macro  HP_FUNC name
    .globl  \name
    .def    \name
    .scl    2
    .type   32
    .endef
    .p2align 4
\name:
    .seh_proc \name
    push    rdi
    .seh_pushreg rdi
    push    rsi
    .seh_pushreg rsi
    .seh_endprologue
    mov     rdi, rcx
    mov     rsi, rdx
    mov     rdx, r8
    mov     rcx, r9
    .endm

    .macro  HP_RET
    pop     rsi
    pop     rdi
    ret
    .endm

    .macro  HP_ENDFUNC name
    .seh_endproc
    .endm

#else /* System V */

#define HP_RODATA_SECTION .section .rodata
/* Mark the stack non-executable; without this the linker assumes otherwise. */
#define HP_NOTE_GNU_STACK .section .note.GNU-stack,"",@progbits

    .macro  HP_FUNC name
    .globl  \name
    .type   \name, @function
    .p2align 4
\name:
    .endm

    .macro  HP_RET
    ret
    .endm

    .macro  HP_ENDFUNC name
    .size   \name, .-\name
    .endm

#endif

#endif /* HOTPATH_ASM_H */
