/*
 * ARM64 Cryptographic Extension Gadgets
 *
 * AES, SHA1, SHA256, EOR3 (host FEAT_SHA3), PMULL/PMULL2 and TBL/TBX use
 * native .inst instructions. SHA512 falls back to C without host
 * FEAT_SHA512, EOR3 without host FEAT_SHA3. SM3, SM4 and SVE still use C
 * helper functions.
 */

#include "gadgets.h"

.text

// Mach-O uses GOTPAGE relocations; ELF uses GOT relocations (also PIC-safe).
.macro sha512_check name
#if defined(__APPLE__)
    adrp x8, NAME(ish_host_sha512)@GOTPAGE
    ldr x8, [x8, NAME(ish_host_sha512)@GOTPAGEOFF]
#else
    adrp x8, :got:NAME(ish_host_sha512)
    ldr x8, [x8, :got_lo12:NAME(ish_host_sha512)]
#endif
    ldrb w8, [x8]
    cbz w8, .L\name\()_soft
.endm

// Same gate for FEAT_SHA3 (EOR3): absent on Apple A11 and earlier, present
// on A13/M1+. Never probe by executing; the C helper is the fallback.
.macro sha3_check name
#if defined(__APPLE__)
    adrp x8, NAME(ish_host_sha3)@GOTPAGE
    ldr x8, [x8, NAME(ish_host_sha3)@GOTPAGEOFF]
#else
    adrp x8, :got:NAME(ish_host_sha3)
    ldr x8, [x8, :got_lo12:NAME(ish_host_sha3)]
#endif
    ldrb w8, [x8]
    cbz w8, .L\name\()_soft
.endm

// Match the existing helper-call ABI: CPU/TLB, low cached guest registers,
// code-stream pointer, callee-saved registers and LR survive the C call.
// SIMD guest state lives in CPU_fp, not in host SIMD registers.
.macro sha512_fallback name, helper, three=1
.L\name\()_soft:
    stp x19, x20, [sp, #-0x70]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]
    mrs x8, nzcv
    str x8, [sp, #0x58]
    // Integer helpers may be auto-vectorized; do not leak host FP status.
    mrs x8, fpsr
    str x8, [sp, #0x60]
    save_c
    add x0, x12, x13        // vd
    add x1, x12, x14        // vn
.if \three
    add x2, x12, x15        // vm
.endif
    bl \helper
    restore_c
    ldr x8, [sp, #0x60]
    msr fpsr, x8
    ldr x8, [sp, #0x58]
    msr nzcv, x8
    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x70
    gret
.endm

/*
 * AESE - AES single round encryption
 * Performs AddRoundKey, SubBytes, and ShiftRows
 * Code stream: [gadget addr][rd | rn<<8]
 *
 * Native AESE does XOR(Vd,Vn) then SubBytes+ShiftRows in one instruction
 */
.gadget aese
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn (round key)

    // Native AESE: v0 = SubBytes(ShiftRows(v0 XOR v1))
    .inst 0x4e284820         // aese v0.16b, v1.16b

    str q0, [x12, x13]

    gret

/*
 * AESD - AES single round decryption
 * Performs AddRoundKey, InvSubBytes, and InvShiftRows
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget aesd
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn

    // Native AESD: v0 = InvSubBytes(InvShiftRows(v0 XOR v1))
    .inst 0x4e285820         // aesd v0.16b, v1.16b

    str q0, [x12, x13]

    gret

/*
 * AESMC - AES MixColumns
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget aesmc
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    lsl x14, x10, #4
    ldr q0, [x12, x14]      // q0 = Vn

    // Native AESMC: v0 = MixColumns(v0)
    .inst 0x4e286800         // aesmc v0.16b, v0.16b

    str q0, [x12, x13]      // store to Vd

    gret

/*
 * AESIMC - AES Inverse MixColumns
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget aesimc
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    lsl x14, x10, #4
    ldr q0, [x12, x14]      // q0 = Vn

    // Native AESIMC: v0 = InvMixColumns(v0)
    .inst 0x4e287800         // aesimc v0.16b, v0.16b

    str q0, [x12, x13]      // store to Vd

    gret

/*
 * SHA1 instructions - native .inst implementations
 */

// SHA1H Sd, Sn - SHA1 fixed rotate
// Code stream: [gadget addr][rd | rn<<8]
.gadget sha1h
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp
    lsl x14, x10, #4
    ldr s0, [x12, x14]      // s0 = Sn (32-bit scalar)

    // Native SHA1H: s0 = FixedRotate(s1)
    // Encoding: SHA1H Sd, Sn = 0101_1110_0010_1000_0000_10nn_nnnd_dddd
    // sha1h s0, s0 → 0x5e280800
    .inst 0x5e280800         // sha1h s0, s0

    // Store s0 to Sd and clear upper bits
    lsl x13, x9, #4
    add x15, x12, x13
    str s0, [x15]            // store 32-bit result
    str xzr, [x15, #4]      // clear bits 32-63
    str xzr, [x15, #8]      // clear bits 64-127

    gret

// SHA1C Qd, Sn, Vm.4S - SHA1 hash update (Choose)
// Code stream: [gadget addr][rd | rn<<8 | rm<<16]
.gadget sha1c
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Qd
    lsl x14, x10, #4
    ldr s1, [x12, x14]      // s1 = Sn (32-bit hash state)
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm.4S

    .inst 0x5e020020         // sha1c q0, s1, v2.4s

    str q0, [x12, x13]      // store result to Qd

    gret

// SHA1M Qd, Sn, Vm.4S - SHA1 hash update (Majority)
.gadget sha1m
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Qd
    lsl x14, x10, #4
    ldr s1, [x12, x14]      // s1 = Sn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm.4S

    .inst 0x5e022020         // sha1m q0, s1, v2.4s

    str q0, [x12, x13]

    gret

// SHA1P Qd, Sn, Vm.4S - SHA1 hash update (Parity)
.gadget sha1p
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Qd
    lsl x14, x10, #4
    ldr s1, [x12, x14]      // s1 = Sn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm.4S

    .inst 0x5e021020         // sha1p q0, s1, v2.4s

    str q0, [x12, x13]

    gret

// SHA1SU0 Vd.4S, Vn.4S, Vm.4S - SHA1 schedule update 0
.gadget sha1su0
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    .inst 0x5e023020         // sha1su0 v0.4s, v1.4s, v2.4s

    str q0, [x12, x13]

    gret

// SHA1SU1 Vd.4S, Vn.4S - SHA1 schedule update 1
.gadget sha1su1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn

    .inst 0x5e281820         // sha1su1 v0.4s, v1.4s

    str q0, [x12, x13]

    gret

/*
 * SHA256 instructions
 */

// SHA256H Qd, Qn, Vm.4S
.gadget sha256h
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Qd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Qn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm.4S

    .inst 0x5e024020         // sha256h q0, q1, v2.4s

    str q0, [x12, x13]

    gret

// SHA256H2 Qd, Qn, Vm.4S
.gadget sha256h2
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Qd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Qn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm.4S

    .inst 0x5e025020         // sha256h2 q0, q1, v2.4s

    str q0, [x12, x13]

    gret

// SHA256SU0 Vd.4S, Vn.4S
.gadget sha256su0
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn

    .inst 0x5e282820         // sha256su0 v0.4s, v1.4s

    str q0, [x12, x13]

    gret

// SHA256SU1 Vd.4S, Vn.4S, Vm.4S
.gadget sha256su1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    .inst 0x5e026020         // sha256su1 v0.4s, v1.4s, v2.4s

    str q0, [x12, x13]

    gret

/*
 * SHA512SU0 Vd.2D, Vn.2D
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget sha512su0
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn

    // Execute native SHA512SU0 instruction
    // SHA512SU0 V0.2D, V1.2D
    sha512_check sha512su0
    .inst 0xcec08020         // sha512su0 v0.2d, v1.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret
    sha512_fallback sha512su0, NAME(sha512su0_helper), 0

/*
 * SHA512SU1 Vd.2D, Vn.2D, Vm.2D
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sha512su1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn, Vm from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    // Execute native SHA512SU1 instruction
    // SHA512SU1 V0.2D, V1.2D, V2.2D
    sha512_check sha512su1
    .inst 0xce628820         // sha512su1 v0.2d, v1.2d, v2.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret
    sha512_fallback sha512su1, NAME(sha512su1_helper)

/*
 * SHA512H Qd, Qn, Vm.2D
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sha512h
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn, Vm from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    // Execute native SHA512H instruction
    // SHA512H Qd, Qn, Vm.2D -> SHA512H Q0, Q1, V2.2D
    sha512_check sha512h
    .inst 0xce628020         // sha512h q0, q1, v2.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret
    sha512_fallback sha512h, NAME(sha512h_helper)

/*
 * SHA512H2 Qd, Qn, Vm.2D
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sha512h2
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm

    add x12, _cpu, #CPU_fp

    // Load Vd, Vn, Vm from emulated register file
    lsl x13, x9, #4
    ldr q0, [x12, x13]      // q0 = Vd
    lsl x14, x10, #4
    ldr q1, [x12, x14]      // q1 = Vn
    lsl x15, x11, #4
    ldr q2, [x12, x15]      // q2 = Vm

    // Execute native SHA512H2 instruction
    // SHA512H2 Q0, Q1, V2.2D
    sha512_check sha512h2
    .inst 0xce628420         // sha512h2 q0, q1, v2.2d

    // Store result back to Vd
    str q0, [x12, x13]

    gret
    sha512_fallback sha512h2, NAME(sha512h2_helper)

/*
 * EOR3 Vd.16B, Vn.16B, Vm.16B, Va.16B
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | ra<<24]
 *
 * Native when the host has FEAT_SHA3 (Apple A13/M1+); otherwise the C
 * helper below. EOR3 fully overwrites Vd, so v0 needs no initial load.
 */
.gadget eor3
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5
    ubfx x12, x8, #24, #5

    add x13, _cpu, #CPU_fp

    sha3_check eor3

    ldr q1, [x13, x10, lsl #4]
    ldr q2, [x13, x11, lsl #4]
    ldr q3, [x13, x12, lsl #4]
    .inst 0xce020c20         // eor3 v0.16b, v1.16b, v2.16b, v3.16b
    str q0, [x13, x9, lsl #4]

    gret

.Leor3_soft:
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x13, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x13, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x13, x2         // rm_ptr
    lsl x3, x12, #4
    add x3, x13, x3         // ra_ptr
    bl NAME(eor3_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SM3PARTW1 Vd.4S, Vn.4S, Vm.4S
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sm3partw1
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x12, x2         // rm_ptr
    bl NAME(sm3partw1_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SM4E Vd.4S, Vn.4S
 * Code stream: [gadget addr][rd | rn<<8]
 */
.gadget sm4e
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    bl NAME(sm4e_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SVE EOR ZD.D, ZN.D, ZM.D (modeled as 128-bit vectors)
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16]
 */
.gadget sve_eor_d
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #5

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x12, x2         // rm_ptr
    bl NAME(sve_eor_d_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * SVE XAR ZD.D, ZD.D, ZM.D, #imm (modeled as 128-bit vectors)
 * Code stream: [gadget addr][rd | rn<<8 | imm<<16]
 */
.gadget sve_xar_d
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f
    ubfx x10, x8, #8, #5
    ubfx x11, x8, #16, #8   // imm

    add x12, _cpu, #CPU_fp

    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr (also zn)
    lsl x1, x9, #4
    add x1, x12, x1         // zn_ptr (same as rd)
    lsl x2, x10, #4
    add x2, x12, x2         // zm_ptr
    mov w3, w11             // imm
    bl NAME(sve_xar_d_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * PMULL - Polynomial Multiply Long
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | Q<<24 | size<<26]
 *
 * All four legal forms are native: PMULL shares the v8.0 crypto extension
 * with AESE, which this file already assumes. The destination is fully
 * overwritten in every form, so v0 needs no load. Sizes 01/10 are rejected
 * by the decoder (UNDEF) and can't arrive; the C path below only remains
 * as a defensive fallback for unusual packings.
 */
.gadget pmull
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn
    ubfx x11, x8, #16, #5   // rm
    ubfx x21, x8, #24, #1   // Q
    ubfx x22, x8, #26, #2   // size

    add x12, _cpu, #CPU_fp

    cbz x22, .Lpmull_s0
    cmp x22, #3
    b.eq .Lpmull_s3
    b .Lpmull_soft

.Lpmull_s0:
    ldr q1, [x12, x10, lsl #4]
    ldr q2, [x12, x11, lsl #4]
    cbz x21, .Lpmull_s0_q0
    .inst 0x4e22e020        // pmull2 v0.8h, v1.16b, v2.16b
    b .Lpmull_done
.Lpmull_s0_q0:
    .inst 0x0e22e020        // pmull v0.8h, v1.8b, v2.8b
    b .Lpmull_done
.Lpmull_s3:
    ldr q1, [x12, x10, lsl #4]
    ldr q2, [x12, x11, lsl #4]
    cbz x21, .Lpmull_s3_q0
    .inst 0x4ee2e020        // pmull2 v0.1q, v1.2d, v2.2d
    b .Lpmull_done
.Lpmull_s3_q0:
    .inst 0x0ee2e020        // pmull v0.1q, v1.1d, v2.1d
.Lpmull_done:
    str q0, [x12, x9, lsl #4]

    gret

.Lpmull_soft:
    stp x19, x20, [sp, #-0x60]!
    stp x21, x22, [sp, #0x10]
    stp x23, x24, [sp, #0x20]
    stp x25, x26, [sp, #0x30]
    stp x27, x28, [sp, #0x40]
    str lr, [sp, #0x50]

    save_c
    lsl x0, x9, #4
    add x0, x12, x0         // rd_ptr
    lsl x1, x10, #4
    add x1, x12, x1         // rn_ptr
    lsl x2, x11, #4
    add x2, x12, x2         // rm_ptr
    mov w3, w21             // Q
    mov w4, w22             // size
    bl NAME(pmull_helper)
    restore_c

    ldr lr, [sp, #0x50]
    ldp x27, x28, [sp, #0x40]
    ldp x25, x26, [sp, #0x30]
    ldp x23, x24, [sp, #0x20]
    ldp x21, x22, [sp, #0x10]
    ldp x19, x20, [sp], #0x60

    gret

/*
 * TBL - Table lookup
 * TBL Vd.<Ta>, {Vn.16B...Vn+len.16B}, Vm.<Ta>
 *
 * Each byte of Vm is used as an index into the table formed by
 * Vn..Vn+len (concatenated). If index < table_size, the corresponding
 * byte is placed in Vd. Otherwise, 0 is placed in Vd.
 *
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | len<<24 | Q<<28]
 */
.gadget tbl
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn (first table register)
    ubfx x11, x8, #16, #5   // rm (indices)
    ubfx x12, x8, #24, #2   // len (0-3 means 1-4 registers)
    ubfx x13, x8, #28, #1   // Q (0=8B, 1=16B)

    add x14, _cpu, #CPU_fp
    // Load the (up to) four consecutive table registers, wrapping at v31,
    // plus the index register. Unused table loads cost three 16-byte reads
    // at most - still an order of magnitude cheaper than the old C call.
    and x15, x10, #0x1f
    ldr q1, [x14, x15, lsl #4]
    add x15, x10, #1
    and x15, x15, #0x1f
    ldr q2, [x14, x15, lsl #4]
    add x15, x10, #2
    and x15, x15, #0x1f
    ldr q3, [x14, x15, lsl #4]
    add x15, x10, #3
    and x15, x15, #0x1f
    ldr q4, [x14, x15, lsl #4]
    ldr q5, [x14, x11, lsl #4]

    // Each site below is exactly 8 bytes (inst + branch), so the site table
    // is addressable as base + (Q*4 + len) * 8 with no data relocations.
    lsl x15, x13, #2        // Q * 4
    orr x15, x15, x12       // + len
    adr x16, .Ltbl_base
    add x16, x16, x15, lsl #3
    br x16

.Ltbl_base:
    .inst 0x0e050020        // tbl v0.8b, {v1.16b}, v5.8b
    b .Ltbl_done
    .inst 0x0e052020        // tbl v0.8b, {v1.16b, v2.16b}, v5.8b
    b .Ltbl_done
    .inst 0x0e054020        // tbl v0.8b, {v1.16b-v3.16b}, v5.8b
    b .Ltbl_done
    .inst 0x0e056020        // tbl v0.8b, {v1.16b-v4.16b}, v5.8b
    b .Ltbl_done
    .inst 0x4e050020        // tbl v0.16b, {v1.16b}, v5.16b
    b .Ltbl_done
    .inst 0x4e052020        // tbl v0.16b, {v1.16b, v2.16b}, v5.16b
    b .Ltbl_done
    .inst 0x4e054020        // tbl v0.16b, {v1.16b-v3.16b}, v5.16b
    b .Ltbl_done
    .inst 0x4e056020        // tbl v0.16b, {v1.16b-v4.16b}, v5.16b
.Ltbl_done:
    // The 8B forms zero the top half of Vd, matching guest semantics, so a
    // full 16-byte store is always correct.
    str q0, [x14, x9, lsl #4]

    gret

/*
 * TBX - Table lookup with extend
 * Same as TBL but out-of-range indices preserve the original Vd value
 * instead of being set to 0.
 *
 * Code stream: [gadget addr][rd | rn<<8 | rm<<16 | len<<24 | Q<<28]
 */
.gadget tbx
    ldr x8, [_pc]
    add _pc, _pc, #8

    and x9, x8, #0x1f       // rd
    ubfx x10, x8, #8, #5    // rn (first table register)
    ubfx x11, x8, #16, #5   // rm (indices)
    ubfx x12, x8, #24, #2   // len (0-3 means 1-4 registers)
    ubfx x13, x8, #28, #1   // Q (0=8B, 1=16B)

    add x14, _cpu, #CPU_fp
    and x15, x10, #0x1f
    ldr q1, [x14, x15, lsl #4]
    add x15, x10, #1
    and x15, x15, #0x1f
    ldr q2, [x14, x15, lsl #4]
    add x15, x10, #2
    and x15, x15, #0x1f
    ldr q3, [x14, x15, lsl #4]
    add x15, x10, #3
    and x15, x15, #0x1f
    ldr q4, [x14, x15, lsl #4]
    ldr q5, [x14, x11, lsl #4]
    // TBX preserves Vd bytes whose index is out of range, so Vd must be
    // loaded (TBL above can skip this: it fully overwrites).
    ldr q0, [x14, x9, lsl #4]

    lsl x15, x13, #2        // Q * 4
    orr x15, x15, x12       // + len
    adr x16, .Ltbx_base
    add x16, x16, x15, lsl #3
    br x16

.Ltbx_base:
    .inst 0x0e051020        // tbx v0.8b, {v1.16b}, v5.8b
    b .Ltbx_done
    .inst 0x0e053020        // tbx v0.8b, {v1.16b, v2.16b}, v5.8b
    b .Ltbx_done
    .inst 0x0e055020        // tbx v0.8b, {v1.16b-v3.16b}, v5.8b
    b .Ltbx_done
    .inst 0x0e057020        // tbx v0.8b, {v1.16b-v4.16b}, v5.8b
    b .Ltbx_done
    .inst 0x4e051020        // tbx v0.16b, {v1.16b}, v5.16b
    b .Ltbx_done
    .inst 0x4e053020        // tbx v0.16b, {v1.16b, v2.16b}, v5.16b
    b .Ltbx_done
    .inst 0x4e055020        // tbx v0.16b, {v1.16b-v3.16b}, v5.16b
    b .Ltbx_done
    .inst 0x4e057020        // tbx v0.16b, {v1.16b-v4.16b}, v5.16b
.Ltbx_done:
    str q0, [x14, x9, lsl #4]

    gret
