/*
 * Crypto vector exercise routines.
 *
 * Each routine loads inputs into explicit vector registers (mirroring how
 * the emulator gadgets move guest vregs around), runs ONE instruction, and
 * stores the full 128-bit result. The wrap tests place the table at
 * {v30,v31,v0,v1} to exercise architectural register-number wraparound,
 * which the emulator must reproduce when gathering table registers.
 *
 * ABI: x0 = out (16 bytes), x1..x3 = inputs. Only v0-v7/v16-v31 are used.
 */
#if defined(__APPLE__)
#define SYM(x) _##x
#else
#define SYM(x) x
#endif

.text
.align 2

// ---- TBL 16-bit forms ----
.globl SYM(t_tbl16_wrap4)
SYM(t_tbl16_wrap4):
    ldr q30, [x1]
    ldr q31, [x1, #16]
    ldr q0,  [x1, #32]
    ldr q1,  [x1, #48]
    ldr q2,  [x2]
    .inst 0x4e0263c3         // tbl v3.16b, {v30,v31,v0,v1}, v2.16b
    str q3, [x0]
    ret

.globl SYM(t_tbl16_1)
SYM(t_tbl16_1):
    ldr q16, [x1]
    ldr q17, [x2]
    .inst 0x4e110203         // tbl v3.16b, {v16}, v17.16b
    str q3, [x0]
    ret

.globl SYM(t_tbl16_2)
SYM(t_tbl16_2):
    ldr q16, [x1]
    ldr q17, [x1, #16]
    ldr q18, [x2]
    .inst 0x4e122203         // tbl v3.16b, {v16,v17}, v18.16b
    str q3, [x0]
    ret

.globl SYM(t_tbl16_3)
SYM(t_tbl16_3):
    ldr q16, [x1]
    ldr q17, [x1, #16]
    ldr q18, [x1, #32]
    ldr q19, [x2]
    .inst 0x4e134203         // tbl v3.16b, {v16,v17,v18}, v19.16b
    str q3, [x0]
    ret

// ---- TBL 8-bit forms (upper half of Vd must be zeroed) ----
.globl SYM(t_tbl8_wrap4)
SYM(t_tbl8_wrap4):
    ldr q30, [x1]
    ldr q31, [x1, #16]
    ldr q0,  [x1, #32]
    ldr q1,  [x1, #48]
    ldr q2,  [x2]
    .inst 0x0e0263c3         // tbl v3.8b, {v30,v31,v0,v1}, v2.8b
    str q3, [x0]
    ret

.globl SYM(t_tbl8_2)
SYM(t_tbl8_2):
    ldr q16, [x1]
    ldr q17, [x1, #16]
    ldr q18, [x2]
    .inst 0x0e122203         // tbl v3.8b, {v16,v17}, v18.8b
    str q3, [x0]
    ret

// ---- TBX 16-bit forms (out-of-range preserves Vd) ----
.globl SYM(t_tbx16_wrap4)
SYM(t_tbx16_wrap4):
    ldr q30, [x1]
    ldr q31, [x1, #16]
    ldr q0,  [x1, #32]
    ldr q1,  [x1, #48]
    ldr q2,  [x2]
    ldr q3,  [x3]
    .inst 0x4e0273c3         // tbx v3.16b, {v30,v31,v0,v1}, v2.16b
    str q3, [x0]
    ret

.globl SYM(t_tbx16_3)
SYM(t_tbx16_3):
    ldr q16, [x1]
    ldr q17, [x1, #16]
    ldr q18, [x1, #32]
    ldr q19, [x2]
    ldr q3,  [x3]
    .inst 0x4e135203         // tbx v3.16b, {v16,v17,v18}, v19.16b
    str q3, [x0]
    ret

// ---- TBX 8-bit forms (upper half of Vd must be preserved) ----
.globl SYM(t_tbx8_2)
SYM(t_tbx8_2):
    ldr q16, [x1]
    ldr q17, [x1, #16]
    ldr q18, [x2]
    ldr q3,  [x3]
    .inst 0x0e123203         // tbx v3.8b, {v16,v17}, v18.8b
    str q3, [x0]
    ret

// ---- PMULL / PMULL2 (all four legal forms) ----
.globl SYM(t_pmull8h)
SYM(t_pmull8h):
    ldr q1, [x1]
    ldr q2, [x2]
    .inst 0x0e22e020         // pmull v0.8h, v1.8b, v2.8b
    str q0, [x0]
    ret

.globl SYM(t_pmull2_8h)
SYM(t_pmull2_8h):
    ldr q1, [x1]
    ldr q2, [x2]
    .inst 0x4e22e020         // pmull2 v0.8h, v1.16b, v2.16b
    str q0, [x0]
    ret

.globl SYM(t_pmull1q)
SYM(t_pmull1q):
    ldr q1, [x1]
    ldr q2, [x2]
    .inst 0x0ee2e020         // pmull v0.1q, v1.1d, v2.1d
    str q0, [x0]
    ret

.globl SYM(t_pmull2_1q)
SYM(t_pmull2_1q):
    ldr q1, [x1]
    ldr q2, [x2]
    .inst 0x4ee2e020         // pmull2 v0.1q, v1.2d, v2.2d
    str q0, [x0]
    ret

// ---- EOR3 (FEAT_SHA3) ----
.globl SYM(t_eor3)
SYM(t_eor3):
    ldr q1, [x1]
    ldr q2, [x2]
    ldr q3, [x3]
    .inst 0xce020c20         // eor3 v0.16b, v1.16b, v2.16b, v3.16b
    str q0, [x0]
    ret

// ---- AESE regression canary (untouched gadget; guards the file edit) ----
.globl SYM(t_aese)
SYM(t_aese):
    ldr q0, [x1]
    ldr q1, [x2]
    .inst 0x4e284820         // aese v0.16b, v1.16b
    str q0, [x0]
    ret
