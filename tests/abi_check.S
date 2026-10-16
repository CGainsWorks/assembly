/*
 * Calling convention checker for tests/test_abi.c.
 *
 * void hp_abi_call(hp_abi_frame *frame)
 *
 * Loads a distinct canary into every register the callee is obliged to
 * preserve, calls frame->fn with frame->args[0..3] in the native argument
 * registers, then records the return value and a bit for every preserved
 * register that came back changed. A kernel that returns the right answer
 * while clobbering a callee saved register passes every functional test and
 * then corrupts its caller, usually somewhere far away and only at some
 * optimisation levels. This is how that is caught instead.
 *
 * The frame layout must match hp_abi_frame in tests/test_abi.c:
 *   0   fn
 *   8   args[4]
 *   40  result
 *   48  clobbered
 *
 * Clobber bits: 0 rbx, 1 rbp, 2 r12, 3 r13, 4 r14, 5 r15, and on Windows also
 * 6 rdi, 7 rsi, and 8 to 17 for xmm6 to xmm15.
 *
 * This file is deliberately written natively for each convention rather than
 * through the shim in src/asm/hp_asm.h, because it is the thing that checks
 * the shim.
 */
    .intel_syntax noprefix

    .macro  CHECKGPR reg, value, bit
    movabs  r10, \value
    cmp     \reg, r10
    je      1f
    or      r8, (1 << \bit)
1:
    .endm

#if defined(_WIN32)
/* ------------------------------------------------------- Windows x64 --- */

    .section .rdata,"dr"
    .p2align 4
.Lcanary_xmm:
    .quad   0x0606060606060606, 0x6060606060606060
    .quad   0x0707070707070707, 0x7070707070707070
    .quad   0x0808080808080808, 0x8080808080808080
    .quad   0x0909090909090909, 0x9090909090909090
    .quad   0x0A0A0A0A0A0A0A0A, 0xA0A0A0A0A0A0A0A0
    .quad   0x0B0B0B0B0B0B0B0B, 0xB0B0B0B0B0B0B0B0
    .quad   0x0C0C0C0C0C0C0C0C, 0xC0C0C0C0C0C0C0C0
    .quad   0x0D0D0D0D0D0D0D0D, 0xD0D0D0D0D0D0D0D0
    .quad   0x0E0E0E0E0E0E0E0E, 0xE0E0E0E0E0E0E0E0
    .quad   0x0F0F0F0F0F0F0F0F, 0xF0F0F0F0F0F0F0F0

    .macro  CHECKXMM reg, idx, bit
    lea     r10, [rip + .Lcanary_xmm]
    movdqu  xmm0, xmmword ptr [r10 + 16 * \idx]
    pcmpeqb xmm0, \reg
    pmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    je      1f
    or      r8, (1 << \bit)
1:
    .endm

    .text
    .globl  hp_abi_call
    .def    hp_abi_call
    .scl    2
    .type   32
    .endef
    .p2align 4
hp_abi_call:
    .seh_proc hp_abi_call
    push    rbp
    .seh_pushreg rbp
    push    rbx
    .seh_pushreg rbx
    push    rdi
    .seh_pushreg rdi
    push    rsi
    .seh_pushreg rsi
    push    r12
    .seh_pushreg r12
    push    r13
    .seh_pushreg r13
    push    r14
    .seh_pushreg r14
    push    r15
    .seh_pushreg r15
    /* 32 shadow, 8 frame pointer, 8 pad, 160 for xmm6 to xmm15, 8 to bring
       rsp back to a multiple of 16 before the call. */
    sub     rsp, 216
    .seh_stackalloc 216
    movaps  xmmword ptr [rsp + 48],  xmm6
    .seh_savexmm xmm6, 48
    movaps  xmmword ptr [rsp + 64],  xmm7
    .seh_savexmm xmm7, 64
    movaps  xmmword ptr [rsp + 80],  xmm8
    .seh_savexmm xmm8, 80
    movaps  xmmword ptr [rsp + 96],  xmm9
    .seh_savexmm xmm9, 96
    movaps  xmmword ptr [rsp + 112], xmm10
    .seh_savexmm xmm10, 112
    movaps  xmmword ptr [rsp + 128], xmm11
    .seh_savexmm xmm11, 128
    movaps  xmmword ptr [rsp + 144], xmm12
    .seh_savexmm xmm12, 144
    movaps  xmmword ptr [rsp + 160], xmm13
    .seh_savexmm xmm13, 160
    movaps  xmmword ptr [rsp + 176], xmm14
    .seh_savexmm xmm14, 176
    movaps  xmmword ptr [rsp + 192], xmm15
    .seh_savexmm xmm15, 192
    .seh_endprologue

    mov     qword ptr [rsp + 32], rcx

    movabs  rbx, 0x1111111111111111
    movabs  rbp, 0x2222222222222222
    movabs  r12, 0x3333333333333333
    movabs  r13, 0x4444444444444444
    movabs  r14, 0x5555555555555555
    movabs  r15, 0x6666666666666666
    movabs  rdi, 0x7777777777777777
    movabs  rsi, 0x1234567812345678
    lea     rax, [rip + .Lcanary_xmm]
    movdqu  xmm6,  xmmword ptr [rax + 0]
    movdqu  xmm7,  xmmword ptr [rax + 16]
    movdqu  xmm8,  xmmword ptr [rax + 32]
    movdqu  xmm9,  xmmword ptr [rax + 48]
    movdqu  xmm10, xmmword ptr [rax + 64]
    movdqu  xmm11, xmmword ptr [rax + 80]
    movdqu  xmm12, xmmword ptr [rax + 96]
    movdqu  xmm13, xmmword ptr [rax + 112]
    movdqu  xmm14, xmmword ptr [rax + 128]
    movdqu  xmm15, xmmword ptr [rax + 144]

    mov     rax, rcx
    mov     rdx, qword ptr [rax + 16]
    mov     r8,  qword ptr [rax + 24]
    mov     r9,  qword ptr [rax + 32]
    mov     rcx, qword ptr [rax + 8]
    call    qword ptr [rax]

    mov     r11, qword ptr [rsp + 32]
    mov     qword ptr [r11 + 40], rax
    xor     r8d, r8d
    CHECKGPR rbx, 0x1111111111111111, 0
    CHECKGPR rbp, 0x2222222222222222, 1
    CHECKGPR r12, 0x3333333333333333, 2
    CHECKGPR r13, 0x4444444444444444, 3
    CHECKGPR r14, 0x5555555555555555, 4
    CHECKGPR r15, 0x6666666666666666, 5
    CHECKGPR rdi, 0x7777777777777777, 6
    CHECKGPR rsi, 0x1234567812345678, 7
    CHECKXMM xmm6,  0, 8
    CHECKXMM xmm7,  1, 9
    CHECKXMM xmm8,  2, 10
    CHECKXMM xmm9,  3, 11
    CHECKXMM xmm10, 4, 12
    CHECKXMM xmm11, 5, 13
    CHECKXMM xmm12, 6, 14
    CHECKXMM xmm13, 7, 15
    CHECKXMM xmm14, 8, 16
    CHECKXMM xmm15, 9, 17
    mov     qword ptr [r11 + 48], r8

    movaps  xmm6,  xmmword ptr [rsp + 48]
    movaps  xmm7,  xmmword ptr [rsp + 64]
    movaps  xmm8,  xmmword ptr [rsp + 80]
    movaps  xmm9,  xmmword ptr [rsp + 96]
    movaps  xmm10, xmmword ptr [rsp + 112]
    movaps  xmm11, xmmword ptr [rsp + 128]
    movaps  xmm12, xmmword ptr [rsp + 144]
    movaps  xmm13, xmmword ptr [rsp + 160]
    movaps  xmm14, xmmword ptr [rsp + 176]
    movaps  xmm15, xmmword ptr [rsp + 192]
    add     rsp, 216
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rsi
    pop     rdi
    pop     rbx
    pop     rbp
    ret
    .seh_endproc

#else
/* ---------------------------------------------------- System V AMD64 --- */

    .text
    .globl  hp_abi_call
    .type   hp_abi_call, @function
    .p2align 4
hp_abi_call:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rdi                     /* frame; seven pushes realign rsp to 16 */

    movabs  rbx, 0x1111111111111111
    movabs  rbp, 0x2222222222222222
    movabs  r12, 0x3333333333333333
    movabs  r13, 0x4444444444444444
    movabs  r14, 0x5555555555555555
    movabs  r15, 0x6666666666666666

    mov     rax, rdi
    mov     rsi, qword ptr [rax + 16]
    mov     rdx, qword ptr [rax + 24]
    mov     rcx, qword ptr [rax + 32]
    mov     rdi, qword ptr [rax + 8]
    call    qword ptr [rax]

    mov     r11, qword ptr [rsp]
    mov     qword ptr [r11 + 40], rax
    xor     r8d, r8d
    CHECKGPR rbx, 0x1111111111111111, 0
    CHECKGPR rbp, 0x2222222222222222, 1
    CHECKGPR r12, 0x3333333333333333, 2
    CHECKGPR r13, 0x4444444444444444, 3
    CHECKGPR r14, 0x5555555555555555, 4
    CHECKGPR r15, 0x6666666666666666, 5
    mov     qword ptr [r11 + 48], r8

    pop     rdi
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
    .size   hp_abi_call, .-hp_abi_call

    .section .note.GNU-stack,"",@progbits
#endif
