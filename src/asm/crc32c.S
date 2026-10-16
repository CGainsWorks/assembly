/*
 * CRC-32C (Castagnoli) using the SSE4.2 CRC32 instruction.
 *
 * The CRC32 instruction consumes eight bytes per issue but its result feeds
 * straight back into its own input, so a single stream is limited by latency
 * rather than throughput: three cycles per eight bytes on every Intel and AMD
 * part that implements it. The fix is to run three independent CRC registers
 * over three disjoint blocks of the buffer, which fills the pipeline, then to
 * stitch the three results back into one.
 *
 * Stitching works because a CRC is a remainder in GF(2)[x] modulo the
 * generator polynomial. Appending n zero bytes to a message multiplies its
 * remainder by x^(8n), a linear map over GF(2), so advancing a CRC register
 * across a block of known length needs no memory traffic at all: four table
 * loads and three exclusive ors. The tables come from
 * tools/gen_crc32c_tables.py, which validates them against a direct CRC over
 * real zero bytes before emitting them.
 *
 * Two block sizes are used. The long one amortises the stitching cost over a
 * large buffer, the short one keeps mid sized buffers on the fast path, and
 * whatever is left falls through to a single stream tail.
 *
 * Written against the System V AMD64 ABI: arguments in edi, rsi, rdx, result
 * in eax. src/asm/hp_asm.h adapts entry and exit for Windows, where rdi is
 * callee saved; the shim saves it, so the body's use of rdi as a table
 * pointer is safe under both conventions.
 */
#include "hp_asm.h"

    .intel_syntax noprefix

/* Must match SHORT_BLOCK and LONG_BLOCK in tools/gen_crc32c_tables.py. */
#define HP_CRC32C_SHORT 256
#define HP_CRC32C_LONG  8192

    .text

/*
 * Advance the CRC register in eax across one block of zero bytes using the
 * flattened operator table based at \tbl. Clobbers ecx and r10d.
 */
    .macro  CRC32C_SHIFT tbl
    mov     ecx, eax
    and     ecx, 0xFF
    mov     r10d, dword ptr [\tbl + rcx*4]
    mov     ecx, eax
    shr     ecx, 8
    and     ecx, 0xFF
    xor     r10d, dword ptr [\tbl + 1024 + rcx*4]
    mov     ecx, eax
    shr     ecx, 16
    and     ecx, 0xFF
    xor     r10d, dword ptr [\tbl + 2048 + rcx*4]
    mov     ecx, eax
    shr     ecx, 24
    xor     r10d, dword ptr [\tbl + 3072 + rcx*4]
    mov     eax, r10d
    .endm

/* uint32_t hp_crc32c_sse42(uint32_t crc, const void *buf, size_t len) */
    HP_FUNC hp_crc32c_sse42
    mov     eax, edi                /* running raw CRC register            */
    not     eax                     /* zlib convention: invert on the way in */

/* ---- three way pipeline over 3 * 8192 byte groups ---- */
.Lcrc_long:
    cmp     rdx, 3 * HP_CRC32C_LONG
    jb      .Lcrc_short
    xor     r8d, r8d                /* second stream starts from zero      */
    xor     r9d, r9d                /* third stream starts from zero       */
    mov     ecx, HP_CRC32C_LONG / 8
    .p2align 4
.Lcrc_long_loop:
    crc32   rax, qword ptr [rsi]
    crc32   r8,  qword ptr [rsi + HP_CRC32C_LONG]
    crc32   r9,  qword ptr [rsi + 2 * HP_CRC32C_LONG]
    add     rsi, 8
    dec     ecx
    jnz     .Lcrc_long_loop
    lea     rdi, [rip + hp_crc32c_zeros_long]
    CRC32C_SHIFT rdi                /* carry stream one across block two   */
    xor     eax, r8d
    CRC32C_SHIFT rdi                /* and across block three              */
    xor     eax, r9d
    add     rsi, 2 * HP_CRC32C_LONG
    sub     rdx, 3 * HP_CRC32C_LONG
    jmp     .Lcrc_long

/* ---- same shape over 3 * 256 byte groups ---- */
.Lcrc_short:
    cmp     rdx, 3 * HP_CRC32C_SHORT
    jb      .Lcrc_tail8
    xor     r8d, r8d
    xor     r9d, r9d
    mov     ecx, HP_CRC32C_SHORT / 8
    .p2align 4
.Lcrc_short_loop:
    crc32   rax, qword ptr [rsi]
    crc32   r8,  qword ptr [rsi + HP_CRC32C_SHORT]
    crc32   r9,  qword ptr [rsi + 2 * HP_CRC32C_SHORT]
    add     rsi, 8
    dec     ecx
    jnz     .Lcrc_short_loop
    lea     rdi, [rip + hp_crc32c_zeros_short]
    CRC32C_SHIFT rdi
    xor     eax, r8d
    CRC32C_SHIFT rdi
    xor     eax, r9d
    add     rsi, 2 * HP_CRC32C_SHORT
    sub     rdx, 3 * HP_CRC32C_SHORT
    jmp     .Lcrc_short

/* ---- single stream tail ---- */
.Lcrc_tail8:
    cmp     rdx, 8
    jb      .Lcrc_tail1
    crc32   rax, qword ptr [rsi]
    add     rsi, 8
    sub     rdx, 8
    jmp     .Lcrc_tail8

.Lcrc_tail1:
    test    rdx, rdx
    jz      .Lcrc_done
.Lcrc_tail1_loop:
    crc32   eax, byte ptr [rsi]
    inc     rsi
    dec     rdx
    jnz     .Lcrc_tail1_loop

.Lcrc_done:
    not     eax
    HP_RET
    HP_ENDFUNC hp_crc32c_sse42

    HP_NOTE_GNU_STACK
