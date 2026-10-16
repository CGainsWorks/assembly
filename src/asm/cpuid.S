/*
 * Raw CPUID and XGETBV access.
 *
 * These exist in assembly rather than as compiler intrinsics for two reasons:
 * rbx is callee saved in the System V AMD64 ABI yet CPUID clobbers it, and
 * XGETBV must not be executed unless CPUID already reported OSXSAVE, so the
 * two have to stay separable.
 *
 * Written against the System V AMD64 ABI: integer arguments in rdi, rsi, rdx,
 * rcx, r8, r9, and callee saved rbx, rbp, r12 to r15. src/asm/hp_asm.h adapts
 * the entry and exit for the Windows x64 convention. rbx is parked in r11
 * rather than pushed, because r11 is volatile under both conventions and a
 * kernel that never moves the stack pointer needs no unwind description of
 * its own body.
 */
#include "hp_asm.h"

    .intel_syntax noprefix
    .text

/* void hp_asm_cpuid(uint32_t leaf, uint32_t subleaf, uint32_t out[4]) */
    HP_FUNC hp_asm_cpuid
    mov     r11, rbx                /* CPUID clobbers rbx, which is callee saved */
    mov     r8, rdx                 /* r8 = out, rdx is about to be overwritten  */
    mov     eax, edi                /* eax = leaf                                */
    mov     ecx, esi                /* ecx = subleaf                             */
    cpuid
    mov     dword ptr [r8 + 0],  eax
    mov     dword ptr [r8 + 4],  ebx
    mov     dword ptr [r8 + 8],  ecx
    mov     dword ptr [r8 + 12], edx
    mov     rbx, r11
    HP_RET
    HP_ENDFUNC hp_asm_cpuid

/*
 * uint64_t hp_asm_xgetbv0(void)
 *
 * Reads XCR0. The caller must have confirmed the OSXSAVE bit first, otherwise
 * this faults with #UD.
 */
    HP_FUNC hp_asm_xgetbv0
    xor     ecx, ecx
    xgetbv                          /* edx:eax = XCR0 */
    shl     rdx, 32
    mov     eax, eax                /* zero extend the low half */
    or      rax, rdx
    HP_RET
    HP_ENDFUNC hp_asm_xgetbv0

    HP_NOTE_GNU_STACK
