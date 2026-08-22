/*
 * Raw CPUID and XGETBV access.
 *
 * These exist in assembly rather than as compiler intrinsics for two reasons:
 * rbx is callee saved in the System V AMD64 ABI yet CPUID clobbers it, and
 * XGETBV must not be executed unless CPUID already reported OSXSAVE, so the
 * two have to stay separable.
 *
 * System V AMD64 ABI: integer arguments in rdi, rsi, rdx, rcx, r8, r9.
 * Callee saved: rbx, rbp, r12 to r15.
 */
    .intel_syntax noprefix
    .text

/* void hp_asm_cpuid(uint32_t leaf, uint32_t subleaf, uint32_t out[4]) */
    .globl  hp_asm_cpuid
    .type   hp_asm_cpuid, @function
hp_asm_cpuid:
    push    rbx                     /* CPUID clobbers rbx, which is callee saved */
    mov     r8, rdx                 /* r8 = out, rdx is about to be overwritten  */
    mov     eax, edi                /* eax = leaf                                */
    mov     ecx, esi                /* ecx = subleaf                             */
    cpuid
    mov     dword ptr [r8 + 0],  eax
    mov     dword ptr [r8 + 4],  ebx
    mov     dword ptr [r8 + 8],  ecx
    mov     dword ptr [r8 + 12], edx
    pop     rbx
    ret
    .size   hp_asm_cpuid, .-hp_asm_cpuid

/*
 * uint64_t hp_asm_xgetbv0(void)
 *
 * Reads XCR0. The caller must have confirmed the OSXSAVE bit first, otherwise
 * this faults with #UD.
 */
    .globl  hp_asm_xgetbv0
    .type   hp_asm_xgetbv0, @function
hp_asm_xgetbv0:
    xor     ecx, ecx
    xgetbv                          /* edx:eax = XCR0 */
    shl     rdx, 32
    mov     eax, eax                /* zero extend the low half */
    or      rax, rdx
    ret
    .size   hp_asm_xgetbv0, .-hp_asm_xgetbv0

/* Mark the stack non-executable; without this the linker assumes otherwise. */
    .section .note.GNU-stack,"",@progbits
