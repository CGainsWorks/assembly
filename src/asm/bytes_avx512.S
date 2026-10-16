/*
 * AVX-512 kernels for counting, searching and validating byte buffers.
 *
 * The same three routines as bytes_avx2.S, rewritten around the two things
 * AVX-512 adds that matter for this kind of work.
 *
 * Comparisons write a k mask register with one bit per byte rather than a
 * vector of 0x00 and 0xFF lanes. That makes counting a popcnt of the mask, so
 * there is no eight bit accumulator to drain, and makes searching a kortest
 * and a bit scan.
 *
 * Masked loads suppress faults on the bytes they leave out. The AVX2 kernels
 * finish with a scalar loop of up to 31 iterations because a full width load
 * at the end of a buffer could touch the next page. Here the tail is a single
 * masked load covering exactly the bytes that remain, built with bzhi, which
 * is guaranteed by the architecture not to fault on the bytes it excludes.
 * tests/test_overread.c holds that guarantee to a guard page at every length
 * from zero to a full page, under Intel SDE in CI.
 *
 * Tier requirements: AVX512F, AVX512BW, BMI2 for bzhi and POPCNT, plus XCR0
 * reporting opmask, ZMM_Hi256 and Hi16_ZMM state as enabled by the OS.
 *
 * Register choice. Only zmm16 and up are used, for two reasons. Their upper
 * halves are outside the state that vzeroupper manages, so no transition
 * penalty can follow and no vzeroupper is needed on exit. And xmm16 to xmm31
 * are volatile under the Windows x64 convention as well as System V, so the
 * Windows shim in hp_asm.h has nothing extra to save. k1 to k5 are volatile on
 * both too.
 *
 * Written against the System V AMD64 ABI, with arguments in rdi, rsi and edx
 * and the result in rax or eax. src/asm/hp_asm.h adapts entry and exit for
 * Windows.
 *
 * Hardware note. This tier has been executed for correctness under Intel SDE
 * only; the development machine has no AVX-512, so it has never been timed.
 * For that reason hp_best_backend() does not select it automatically. It is
 * reached through HOTPATH_BACKEND=avx512 or hp_set_backend().
 */
#include "hp_asm.h"

    .intel_syntax noprefix
    .text

/*
 * Build a k mask with the low \count bits set, for a tail of 1 to 63 bytes.
 * Clobbers \scratch.
 */
    .macro  TAIL_MASK kreg, count, scratch
    mov     \scratch, -1
    bzhi    \scratch, \scratch, \count
    kmovq   \kreg, \scratch
    .endm

/* ------------------------------------------------------------------------ */
/* size_t hp_count_byte_avx512(const void *buf, size_t len, uint8_t needle)  */
/*                                                                          */
/* Four 64 byte compares per iteration, each popcounted into rax. The four   */
/* popcnt chains are independent until the final add, so they overlap.      */
/* ------------------------------------------------------------------------ */
    HP_FUNC hp_count_byte_avx512
    vpbroadcastb zmm16, edx         /* needle in every lane                 */
    xor     eax, eax
    mov     rcx, rsi                /* bytes remaining                      */
    cmp     rcx, 256
    jb      .Lcb5_64
    .p2align 4
.Lcb5_loop256:
    vpcmpeqb k1, zmm16, zmmword ptr [rdi]
    vpcmpeqb k2, zmm16, zmmword ptr [rdi + 64]
    vpcmpeqb k3, zmm16, zmmword ptr [rdi + 128]
    vpcmpeqb k4, zmm16, zmmword ptr [rdi + 192]
    kmovq   r8, k1
    kmovq   r9, k2
    kmovq   r10, k3
    kmovq   r11, k4
    popcnt  r8, r8
    popcnt  r9, r9
    popcnt  r10, r10
    popcnt  r11, r11
    add     r8, r9
    add     r10, r11
    add     rax, r8
    add     rax, r10
    add     rdi, 256
    sub     rcx, 256
    cmp     rcx, 256
    jae     .Lcb5_loop256

.Lcb5_64:
    cmp     rcx, 64
    jb      .Lcb5_tail
.Lcb5_loop64:
    vpcmpeqb k1, zmm16, zmmword ptr [rdi]
    kmovq   r8, k1
    popcnt  r8, r8
    add     rax, r8
    add     rdi, 64
    sub     rcx, 64
    cmp     rcx, 64
    jae     .Lcb5_loop64

.Lcb5_tail:
    test    rcx, rcx
    jz      .Lcb5_done
    TAIL_MASK k2, rcx, r8
    vmovdqu8 zmm17{k2}{z}, zmmword ptr [rdi]
    /* The zeroed lanes would match a zero needle, so the compare is masked
       as well as the load. */
    vpcmpeqb k1{k2}, zmm17, zmm16
    kmovq   r8, k1
    popcnt  r8, r8
    add     rax, r8

.Lcb5_done:
    HP_RET
    HP_ENDFUNC hp_count_byte_avx512

/* ------------------------------------------------------------------------ */
/* const void *hp_find_byte_avx512(const void *buf, size_t len, uint8_t x)   */
/*                                                                          */
/* The 256 byte loop folds four masks into one test. When it sees a hit it   */
/* hands over to the 64 byte loop at the same address, which finds the exact */
/* block within four iterations, so the hit path stays simple.              */
/* ------------------------------------------------------------------------ */
    HP_FUNC hp_find_byte_avx512
    vpbroadcastb zmm16, edx
    mov     rcx, rsi
    cmp     rcx, 256
    jb      .Lfb5_64
    .p2align 4
.Lfb5_loop256:
    vpcmpeqb k1, zmm16, zmmword ptr [rdi]
    vpcmpeqb k2, zmm16, zmmword ptr [rdi + 64]
    vpcmpeqb k3, zmm16, zmmword ptr [rdi + 128]
    vpcmpeqb k4, zmm16, zmmword ptr [rdi + 192]
    korq    k1, k1, k2
    korq    k3, k3, k4
    kortestq k1, k3
    jnz     .Lfb5_64
    add     rdi, 256
    sub     rcx, 256
    cmp     rcx, 256
    jae     .Lfb5_loop256

.Lfb5_64:
    cmp     rcx, 64
    jb      .Lfb5_tail
.Lfb5_loop64:
    vpcmpeqb k1, zmm16, zmmword ptr [rdi]
    kortestq k1, k1
    jnz     .Lfb5_hit
    add     rdi, 64
    sub     rcx, 64
    cmp     rcx, 64
    jae     .Lfb5_loop64

.Lfb5_tail:
    test    rcx, rcx
    jz      .Lfb5_miss
    TAIL_MASK k2, rcx, r8
    vmovdqu8 zmm17{k2}{z}, zmmword ptr [rdi]
    vpcmpeqb k1{k2}, zmm17, zmm16
    kortestq k1, k1
    jz      .Lfb5_miss

.Lfb5_hit:
    kmovq   rax, k1
    bsf     rax, rax                /* index of the first matching byte     */
    add     rax, rdi
    HP_RET

.Lfb5_miss:
    xor     eax, eax
    HP_RET
    HP_ENDFUNC hp_find_byte_avx512

/* ------------------------------------------------------------------------ */
/* int hp_is_ascii_avx512(const void *buf, size_t len)                       */
/*                                                                          */
/* Two accumulators so consecutive vpord instructions do not wait on each    */
/* other, folded together once at the end. vpmovb2m lifts the sign bit of    */
/* every byte into a mask, and a zero mask means pure ASCII.                 */
/* ------------------------------------------------------------------------ */
    HP_FUNC hp_is_ascii_avx512
    vpxord  zmm16, zmm16, zmm16
    vpxord  zmm17, zmm17, zmm17
    mov     rcx, rsi
    cmp     rcx, 256
    jb      .Lia5_64
    .p2align 4
.Lia5_loop256:
    vpord   zmm16, zmm16, zmmword ptr [rdi]
    vpord   zmm17, zmm17, zmmword ptr [rdi + 64]
    vpord   zmm16, zmm16, zmmword ptr [rdi + 128]
    vpord   zmm17, zmm17, zmmword ptr [rdi + 192]
    add     rdi, 256
    sub     rcx, 256
    cmp     rcx, 256
    jae     .Lia5_loop256

.Lia5_64:
    cmp     rcx, 64
    jb      .Lia5_tail
.Lia5_loop64:
    vpord   zmm16, zmm16, zmmword ptr [rdi]
    add     rdi, 64
    sub     rcx, 64
    cmp     rcx, 64
    jae     .Lia5_loop64

.Lia5_tail:
    test    rcx, rcx
    jz      .Lia5_check
    TAIL_MASK k2, rcx, r8
    vmovdqu8 zmm18{k2}{z}, zmmword ptr [rdi]
    vpord   zmm16, zmm16, zmm18

.Lia5_check:
    vpord   zmm16, zmm16, zmm17
    vpmovb2m k1, zmm16
    xor     eax, eax
    kortestq k1, k1
    setz    al
    HP_RET
    HP_ENDFUNC hp_is_ascii_avx512

    HP_NOTE_GNU_STACK
