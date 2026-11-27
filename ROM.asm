const reg_B 0x0100
const reg_C 0x0101
const reg_D 0x0102
const reg_E 0x0103
const reg_L 0x0104
const reg_H 0x0105

const mmu_i2cZ1 0x0131
const mmu_i2c01 0x0132
const mmu_i2c00 0x0133
const mmu_i2cA0 0x0134
const mmu_i2cA1 0x0135
const mmu_i2cZ0 0x0136
const mmu_i2cMR 0x0137
const mmu_stc  0x20 ; Stimulus Current
const cntr     0x21 ; Counter variable


main:

push A            ; Save A.
ld A,(cntr)       ; Load counter,
add A,(1)     ; increment,
ld (cntr),A       ; and store.
rr A              ; Shift right
rr A              ; a total
rr A              ; of four 
rr A              ; times.
ld (mmu_stc),A    ; Set stimulus current.
pop A             ; Restore A.

ld IX,0
ld A,(IX)
ld (mmu_i2cMR),A
inc IX


ld A,(0)
delay_loop:
add A,(1)
jp z,delay_loop
jp main

include "I2C.asm"
