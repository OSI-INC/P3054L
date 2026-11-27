; I2C library for RMC5, FCK = 5 MHz.
; Public transactions preserve A, F, reg_C, reg_E, reg_H, reg_L.
; IX advances by the number of bytes. C=0 means 256 bytes.
; Non-reentrant. Identity ROM supplies constants.

; START or repeated START. Enter with SDA released, SCL low or high.
i2c_start:
ld (mmu_i2cZ1),A
nop
nop
ld (mmu_i2c01),A
nop
nop
ld (mmu_i2c00),A
ret

; STOP. Enter with SCL low.
i2c_stop:
ld (mmu_i2c00),A
nop
nop
nop
nop
nop
nop
ld (mmu_i2c01),A
nop
nop
ld (mmu_i2cZ1),A
ret

; Slave ACK (unchecked) or master NACK. SDA released.
i2c_nack:
ld (mmu_i2cZ0),A
nop
nop
nop
nop
nop
nop
ld (mmu_i2cZ1),A
nop
nop
ld (mmu_i2cZ0),A
ret

; Master ACK. SDA driven low during pulse.
i2c_ack:
ld (mmu_i2c00),A
nop
nop
nop
nop
nop
nop
ld (mmu_i2c01),A
nop
nop
ld (mmu_i2cZ0),A
ret

; Transmit A, MSB first, then accept slave ACK.
; Clobbers A, arithmetic flags, reg_E.
i2c_tx_byte:
push A
ld A,(8)
ld (reg_E),A
pop A
i2c_tx_bit:
ld (mmu_i2cA0),A
ld (mmu_i2cA1),A
nop
nop
ld (mmu_i2cA0),A
rl A
push A
ld A,(reg_E)
sub A,(1)
ld (reg_E),A
pop A
jp nz,i2c_tx_bit
jp i2c_nack

; Receive eight bits into A. Caller sends ACK or NACK.
; Clobbers arithmetic flags, preserves reg_E.
i2c_rx_byte:
ld A,(8)
i2c_rx_bit:
ld (mmu_i2cZ0),A
nop
nop
nop
nop
ld (mmu_i2cZ1),A
nop
nop
ld (mmu_i2cZ0),A
sub A,(1)
jp nz,i2c_rx_bit
ld A,(mmu_i2cMR)
ret

; Shared transaction prefix: START, device+W, sub-address.
i2c_select:
call i2c_start
ld A,(reg_H)
clrf
rl A
call i2c_tx_byte
ld A,(reg_L)
jp i2c_tx_byte

; Write C bytes from IX to device H, sub-address L.
i2c_wr:
push F
push A
ld A,(reg_C)
push A
ld A,(reg_E)
push A
call i2c_select
i2c_wr_loop:
ld A,(IX)
call i2c_tx_byte
inc IX
ld A,(reg_C)
sub A,(1)
ld (reg_C),A
jp nz,i2c_wr_loop
jp i2c_finish

; Read C bytes into IX from device H, sub-address L.
i2c_rd:
push F
push A
ld A,(reg_C)
push A
ld A,(reg_E)
push A
call i2c_select
call i2c_start
ld A,(reg_H)
clrf
rl A
or A,(1)
call i2c_tx_byte
i2c_rd_loop:
call i2c_rx_byte
ld (IX),A
inc IX
ld A,(reg_C)
sub A,(1)
ld (reg_C),A
jp z,i2c_rd_last
call i2c_ack
jp i2c_rd_loop
i2c_rd_last:
call i2c_nack

; Shared transaction completion.
i2c_finish:
call i2c_stop
pop A
ld (reg_E),A
pop A
ld (reg_C),A
pop A
pop F
ret
