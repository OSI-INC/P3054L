; Control Register Locations.
const mmu_irqb  0x0201
const mmu_sr    0x0202
const mmu_i2cMR 0x0203

const mmu_irst  0x0211
const mmu_sacc  0x0212
const mmu_cmp   0x0214
const mmu_saddr 0x0218

const mmu_shift 0x0221
const mmu_xch   0x0222
const mmu_rfc   0x0224
const mmu_fck   0x0228

const mmu_dfr   0x0241
const mmu_rst   0x0242

const mmu_i2c00 0x0280
const mmu_i2c01 0x0281
const mmu_i2cA0 0x0282
const mmu_i2cA1 0x0283
const mmu_i2cZ0 0x0284
const mmu_i2cZ1 0x0285

; Regiser locations.
const reg_B     0x0100 
const reg_C     0x0101
const reg_D     0x0102
const reg_E     0x0103
const reg_H     0x0104
const reg_L     0x0105

; Boot and interrupt vectors.
jp main
jp main

; Include files.
include "I2C.asm"

main:

main_loop:

; Check the Telemetry Dispatch bit.
check_dispatch:
ld A,(mmu_irqb)
and A,(0x01)
jp z,check_cmd

; Select sample memory location zero, take
; control of the sample memory and initiate
; transmission on channel one.
ld A,(0)
ld (mmu_saddr),A
ld A,(4)
ld (mmu_sacc),A
ld A,(1)
ld (mmu_xch),A

; Wait for transmission to complete.
ld A,(20)
tx_wait:
sub A,(1)
jp nz,tx_wait

; Reset sample accumulator, write zero to the
; sample memory, and return sample memory to
; the Telemetry Manager. Acknowledge the dispatch
; request.
ld A,(5)
ld (mmu_sacc),A
ld A,(6)
ld (mmu_sacc),A
ld A,(0)
ld (mmu_sacc),A
ld A,(1)
ld (mmu_irst),A

; Check for incoming commmand.
check_cmd:


jp main


