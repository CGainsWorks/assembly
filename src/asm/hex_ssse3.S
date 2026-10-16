/*
 * Lowercase hex encoding with SSSE3.
 *
 * Sixteen input bytes become thirty two output characters per iteration. The
 * nibble to character map is a sixteen entry table, which is exactly what
 * pshufb indexes, so both halves of every byte are translated with one shuffle
 * each and no branching. punpcklbw and punpckhbw then interleave the high and
 * low nibble characters back into the correct order.
 *
 * This is used by both the SSE4.2 and the AVX2 tiers. A 256 bit version would
 * need vpermq to repair the lane crossing that vpunpcklbw introduces, and on
 * the buffer sizes this library cares about the extra shuffle cancels most of
 * the gain, so the same 128 bit kernel serves both. See docs/DESIGN.md.
 *
 * Written against the System V AMD64 ABI: arguments in rdi, rsi, rdx, no
 * return value. src/asm/hp_asm.h adapts entry and exit for Windows. Only xmm0
 * to xmm5 are used, which are volatile under both conventions. Legacy SSE
 * encodings throughout, so no vzeroupper is needed.
 */
#include "hp_asm.h"

    .intel_syntax noprefix

    HP_RODATA_SECTION
    .p2align 4
.Lhex_digits:
    .ascii  "0123456789abcdef"
.Lhex_mask:
    .fill   16, 1, 0x0F

    .text

/* void hp_hex_encode_ssse3(char *dst, const void *src, size_t len) */
    HP_FUNC hp_hex_encode_ssse3
    test    rdx, rdx
    jz      .Lhx_done
    lea     r8, [rip + .Lhex_digits]
    movdqu  xmm4, xmmword ptr [r8]
    movdqu  xmm5, xmmword ptr [rip + .Lhex_mask]
    cmp     rdx, 16
    jb      .Lhx_tail
    .p2align 4
.Lhx_loop:
    movdqu  xmm0, xmmword ptr [rsi]
    movdqa  xmm1, xmm0
    psrlw   xmm1, 4                 /* shift words, then mask, which leaves */
    pand    xmm1, xmm5              /* each byte's high nibble in place     */
    pand    xmm0, xmm5              /* low nibbles                          */
    movdqa  xmm2, xmm4
    pshufb  xmm2, xmm1              /* high nibble characters               */
    movdqa  xmm3, xmm4
    pshufb  xmm3, xmm0              /* low nibble characters                */
    movdqa  xmm1, xmm2
    punpcklbw xmm1, xmm3            /* bytes 0 to 7 as sixteen characters   */
    punpckhbw xmm2, xmm3            /* bytes 8 to 15                        */
    movdqu  xmmword ptr [rdi], xmm1
    movdqu  xmmword ptr [rdi + 16], xmm2
    add     rsi, 16
    add     rdi, 32
    sub     rdx, 16
    cmp     rdx, 16
    jae     .Lhx_loop
    test    rdx, rdx
    jz      .Lhx_done

.Lhx_tail:
    movzx   eax, byte ptr [rsi]
    mov     ecx, eax
    shr     ecx, 4
    and     eax, 0x0F
    movzx   ecx, byte ptr [r8 + rcx]
    mov     byte ptr [rdi], cl
    movzx   eax, byte ptr [r8 + rax]
    mov     byte ptr [rdi + 1], al
    inc     rsi
    add     rdi, 2
    dec     rdx
    jnz     .Lhx_tail

.Lhx_done:
    HP_RET
    HP_ENDFUNC hp_hex_encode_ssse3

    HP_NOTE_GNU_STACK
