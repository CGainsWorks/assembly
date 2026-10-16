/*
 * AVX2 kernels for counting, searching and validating byte buffers.
 *
 * Three routines live here because they share the same shape: broadcast a
 * comparison value into a 256 bit register, sweep the buffer 32 bytes at a
 * time, then finish whatever does not fill a vector with a scalar tail. The
 * tail is always scalar rather than a masked or overlapping vector load, so no
 * kernel ever touches a byte outside the caller's buffer. tests/test_overread.c
 * holds that promise to a guard page.
 *
 * Written against the System V AMD64 ABI: arguments in rdi, rsi, edx, result
 * in rax or eax. src/asm/hp_asm.h adapts entry and exit for Windows. Only
 * registers that are caller saved under both conventions are used, ymm0 to
 * ymm4 included, so the body needs no prologue or epilogue of its own. Every
 * exit path runs vzeroupper first to avoid the SSE to AVX transition penalty
 * in whatever the caller does next.
 */
#include "hp_asm.h"

    .intel_syntax noprefix
    .text

/* ------------------------------------------------------------------------ */
/* size_t hp_count_byte_avx2(const void *buf, size_t len, uint8_t needle)    */
/*                                                                          */
/* vpcmpeqb yields 0x00 or 0xFF per lane, so subtracting the result from an  */
/* accumulator adds one per match. That accumulator is only eight bits wide  */
/* per lane, so it has to be drained before any lane can reach 256. Draining */
/* with vpsadbw folds each half into a 64 bit lane sum for free.             */
/* ------------------------------------------------------------------------ */
    HP_FUNC hp_count_byte_avx2
    movzx   eax, dl
    vmovd   xmm0, eax
    vpbroadcastb ymm0, xmm0         /* needle in every lane                 */
    vpxor   ymm4, ymm4, ymm4        /* constant zero for vpsadbw            */
    vpxor   ymm3, ymm3, ymm3        /* running total, four 64 bit lanes     */
    xor     eax, eax
    mov     rcx, rsi                /* bytes remaining                      */
    cmp     rcx, 128
    jb      .Lcb_32

.Lcb_outer:
    /* At most 63 groups of 128 bytes per drain: each group can add at most
       four to a lane, and 63 * 4 = 252 stays below the 255 lane ceiling. */
    mov     r8, rcx
    shr     r8, 7
    cmp     r8, 63
    jbe     1f
    mov     r8d, 63
1:
    vpxor   ymm2, ymm2, ymm2        /* per lane byte counters               */
    mov     r9, r8
    .p2align 4
.Lcb_inner:
    vmovdqu ymm1, ymmword ptr [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpsubb  ymm2, ymm2, ymm1
    vmovdqu ymm1, ymmword ptr [rdi + 32]
    vpcmpeqb ymm1, ymm1, ymm0
    vpsubb  ymm2, ymm2, ymm1
    vmovdqu ymm1, ymmword ptr [rdi + 64]
    vpcmpeqb ymm1, ymm1, ymm0
    vpsubb  ymm2, ymm2, ymm1
    vmovdqu ymm1, ymmword ptr [rdi + 96]
    vpcmpeqb ymm1, ymm1, ymm0
    vpsubb  ymm2, ymm2, ymm1
    add     rdi, 128
    dec     r9
    jnz     .Lcb_inner
    vpsadbw ymm2, ymm2, ymm4        /* eight bit lanes to 64 bit sums       */
    vpaddq  ymm3, ymm3, ymm2
    shl     r8, 7
    sub     rcx, r8
    cmp     rcx, 128
    jae     .Lcb_outer

.Lcb_32:
    /* At most three iterations, so one drain at the end is enough. */
    cmp     rcx, 32
    jb      .Lcb_reduce
    vpxor   ymm2, ymm2, ymm2
.Lcb_32_loop:
    vmovdqu ymm1, ymmword ptr [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpsubb  ymm2, ymm2, ymm1
    add     rdi, 32
    sub     rcx, 32
    cmp     rcx, 32
    jae     .Lcb_32_loop
    vpsadbw ymm2, ymm2, ymm4
    vpaddq  ymm3, ymm3, ymm2

.Lcb_reduce:
    vextracti128 xmm1, ymm3, 1
    vpaddq  xmm3, xmm3, xmm1
    vpshufd xmm1, xmm3, 0x4E
    vpaddq  xmm3, xmm3, xmm1
    vmovq   rax, xmm3

    test    rcx, rcx
    jz      .Lcb_done
.Lcb_tail:
    xor     r8d, r8d
    cmp     byte ptr [rdi], dl
    sete    r8b
    add     rax, r8
    inc     rdi
    dec     rcx
    jnz     .Lcb_tail

.Lcb_done:
    vzeroupper
    HP_RET
    HP_ENDFUNC hp_count_byte_avx2

/* ------------------------------------------------------------------------ */
/* const void *hp_find_byte_avx2(const void *buf, size_t len, uint8_t x)     */
/*                                                                          */
/* vpmovmskb collapses the comparison to one bit per byte, so a whole 32     */
/* byte window is tested with a single branch. bsf rather than tzcnt keeps   */
/* this kernel free of any BMI1 requirement.                                 */
/* ------------------------------------------------------------------------ */
    HP_FUNC hp_find_byte_avx2
    movzx   eax, dl
    vmovd   xmm0, eax
    vpbroadcastb ymm0, xmm0
    mov     rcx, rsi
    cmp     rcx, 32
    jb      .Lfb_tail
    .p2align 4
.Lfb_loop:
    vmovdqu ymm1, ymmword ptr [rdi]
    vpcmpeqb ymm1, ymm1, ymm0
    vpmovmskb eax, ymm1
    test    eax, eax
    jnz     .Lfb_hit
    add     rdi, 32
    sub     rcx, 32
    cmp     rcx, 32
    jae     .Lfb_loop
    jmp     .Lfb_tail

.Lfb_hit:
    bsf     eax, eax                /* index of the first set bit           */
    add     rdi, rax
    mov     rax, rdi
    vzeroupper
    HP_RET

.Lfb_tail:
    test    rcx, rcx
    jz      .Lfb_miss
.Lfb_tail_loop:
    cmp     byte ptr [rdi], dl
    je      .Lfb_tail_hit
    inc     rdi
    dec     rcx
    jnz     .Lfb_tail_loop

.Lfb_miss:
    xor     eax, eax
    vzeroupper
    HP_RET

.Lfb_tail_hit:
    mov     rax, rdi
    vzeroupper
    HP_RET
    HP_ENDFUNC hp_find_byte_avx2

/* ------------------------------------------------------------------------ */
/* int hp_is_ascii_avx2(const void *buf, size_t len)                         */
/*                                                                          */
/* Only the sign bit of each byte matters, so the whole buffer can be folded */
/* into one register with vpor and inspected once at the end. That keeps the */
/* loop free of branches on data.                                            */
/* ------------------------------------------------------------------------ */
    HP_FUNC hp_is_ascii_avx2
    vpxor   ymm2, ymm2, ymm2        /* running bitwise or of every byte     */
    mov     rcx, rsi
    cmp     rcx, 128
    jb      .Lia_32
    .p2align 4
.Lia_loop128:
    vmovdqu ymm1, ymmword ptr [rdi]
    vpor    ymm2, ymm2, ymm1
    vmovdqu ymm1, ymmword ptr [rdi + 32]
    vpor    ymm2, ymm2, ymm1
    vmovdqu ymm1, ymmword ptr [rdi + 64]
    vpor    ymm2, ymm2, ymm1
    vmovdqu ymm1, ymmword ptr [rdi + 96]
    vpor    ymm2, ymm2, ymm1
    add     rdi, 128
    sub     rcx, 128
    cmp     rcx, 128
    jae     .Lia_loop128

.Lia_32:
    cmp     rcx, 32
    jb      .Lia_check
.Lia_loop32:
    vmovdqu ymm1, ymmword ptr [rdi]
    vpor    ymm2, ymm2, ymm1
    add     rdi, 32
    sub     rcx, 32
    cmp     rcx, 32
    jae     .Lia_loop32

.Lia_check:
    vpmovmskb eax, ymm2             /* one bit per byte, taken from bit 7   */
    test    eax, eax
    jnz     .Lia_false
    xor     eax, eax
    test    rcx, rcx
    jz      .Lia_true
.Lia_tail:
    movzx   r8d, byte ptr [rdi]
    or      eax, r8d
    inc     rdi
    dec     rcx
    jnz     .Lia_tail
    test    eax, 0x80
    jnz     .Lia_false

.Lia_true:
    mov     eax, 1
    vzeroupper
    HP_RET

.Lia_false:
    xor     eax, eax
    vzeroupper
    HP_RET
    HP_ENDFUNC hp_is_ascii_avx2

    HP_NOTE_GNU_STACK
