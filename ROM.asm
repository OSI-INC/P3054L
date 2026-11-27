; Control Register Locations.
const mmu_irqb  0x0200 ; Interrupt Request Bits (Read)
const mmu_irst  0x0201 ; Interrupt Reset Bits (Write)
const mmu_acfg  0x0202 ; Amplifier Configuration (Write)
const mmu_led   0x0203 ; Lamp Switch (Write)
const mmu_rst   0x0204 ; Software Reset (Write)
const mmu_xch   0x0205 ; Transmit Channel Number (Write/Strobe)
const mmu_rfc   0x0206 ; Radio Frequency Calibration (Write)
const mmu_dfr   0x0207 ; Diagnostic Flags (Write)
const mmu_sr    0x0208 ; Status Register (Read)
const mmu_cmp   0x0209 ; Command Memory Portal (Read/Write/Strobe)
const mmu_fck   0x020A ; Fast Clock Mask (Write)
const mmu_i2c00 0x020B ; i2c SDA=0 SCL=0 (Write)
const mmu_i2c01 0x020C ; i2c SDA=0 SCL=1 (Write)
const mmu_i2cA0 0x020D ; i2c SDA=A SCL=0 (Write)
const mmu_i2cA1 0x020E ; i2c SDA=A SCL=1 (Write)
const mmu_i2cZ0 0x020F ; i2c SDA=Z SCL=0 (Write)
const mmu_i2cZ1 0x0210 ; i2c SDA=Z SCL=1 (Write)
const mmu_i2cMR 0x0211 ; i2c Most Recent Eight Bits (Read)
const mmu_x1cfg 0x0212 ; X1 Configuration (Write)
const mmu_x2cfg 0x0213 ; X2 Configuration (Write)
const mmu_x3cfg 0x0214 ; X3 Configuration (Write)
const mmu_x4cfg 0x0215 ; X4 Configuration (Write)
const mmu_saddr 0x0216 ; Sample Memory Addr (Write)
const mmu_sacc  0x0217 ; Sample Accumulator Control (Write/Strobe)

main:

ld A,(mmu_irqb)
and A,(1)
jp z,main

; Select sample memory location one.
ld A,(1)
ld (mmu_saddr),A

; Take control of sample memory.
ld A,(4)
ld (mmu_sacc),A

; Initiate transmission on channel one.
ld A,(1)
ld (mmu_xch),A

; Wait for transmission to complete.
ld A,(13)

tx_wait:

sub A,(1)
jp nz,tx_wait

; Reset sample accumulator.
ld A,(5)
ld (mmu_sacc),A

; Write zero to sample memory.
ld A,(6)
ld (mmu_sacc),A

; Return sample memory to Telemetry Manager.
ld A,(0)
ld (mmu_sacc),A

; Acknowledge dispatch request.
ld A,(1)
ld (mmu_irst),A

jp main

;include "I2C.asm"
