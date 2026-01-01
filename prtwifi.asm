; ==============================================================================================
; RS232 through +3 printer port, 57600, 8N1, +CTS, -RTS
; 57600bps (17,3611μs)
; 61.57813T on ZX 128k, 61T will take 17.19811μs, error -0.9% (58146bps)
; 60.76389T on ZX 48k,  61T will take 17.42857μs, error +0.4% (57377bps)
;
; Based on some *amazing* work here: https://cygnus.speccy.cz/popis_zx-spectrum_dg192k_rs232.php
; ==============================================================================================

; --------------------------------------
; 0xFFD: Printer port data latch (Write)
; --------------------------------------
;         Bit 7   TX
;         Bit 0   CTS
; --------------------------------------
; 0xFFD: Printer port busy (Read)
; --------------------------------------
;         Bit 0   RX
; --------------------------------------

uartBegin:
    ld   bc, 0xFFD              ; 10T   printer port to BC
    ld   a, 0x80                ; 7T    TX = 1, CTS = 0 (allow sending)
    out  (c), a                 ; 12T

    ei                          ; Re-enable interrupts, just in case
    ld   a, 50                  ; Flush anything left in TX buffer, by keeping CTS low
1:  halt                        ; for ~1 second
    dec  a
    jr   nz, 1B
    di                          ; Timing critical now, so diable interrupts

    ld   a, 0x81                ; 7T    TX = 1, CTS = 1 (stop sending)
    out  (c), a                 ; 12T

    ld   a, (ix + 0)            ; 19T   Wait at least one bit
    ld   a, (ix + 0)            ; 19T
    ld   a, (ix + 0)            ; 19T
    ret                         ; 10T

uartWriteByte:
    di

    ld   bc, 0xFFD              ; 10T Printer port to BC
    ld   h, 8                   ; 7T H serves as an 8-bit counter
    ld   l, a                   ; 4T copy data from A to L

    nop                         ; 4T
    nop                         ; 4T
    nop                         ; 4T
    nop                         ; 4T

; start bit
    ld   a, 1                   ; TX = 1 (Start bit), CTS = 0 (allow sending - why, we're sending?! - maybe should be 0x81?)
    out  (c), a                 ; 12T write to port

    nop                         ; 4T
    nop                         ; 4T
    nop                         ; 4T
    nop                         ; 4T

; data bits
txLoop:
    ld   a, 0                   ; 7T delay
    ld   a, 0                   ; 7T delay

    rrc  l                      ; 8T next bit at bit position 7
    ld   a, 1                   ; 7T prepare a mask
    or   l                      ; 4T add a mask

; from the beginning start bit 12 + 8 + 8 + 7 + 7 + 8 + 7 + 4 = 61T
; from last bit 12 + 4 + 12 + 7 + 7 + 8 + 7 + 4 = 61T

    out  (c), a                 ; 12T write to port
    dec  h                      ; 4T bit counter
    jr   nz, txLoop             ; 12 / 7T repeat

; stop bit
    ld   a, (ix + 0)            ; 19T delay
    inc  hl                     ; 6T delay
    dec  hl                     ; 6T delay
    ld   a, 0x81                ; 7T, keep bit 0 (CTS) and 7 (TX - stop bit) high (stop sending)

; since the last out in the cycle 12 + 4 + 7 + 19 + 6 + 6 + 7 = 61T

    out   (c), a                ; 12T write to port
    ei
    ret                         ; 10T extends the stop bit duration

uartReadBlocking:
    di

    xor  a                      ; Reset read error count
    ld   (readErrors), a

    ld   bc, 0xFFD              ; 10T   printer port to BC

; Check that RX is idle

rxRetry:
    in   a, (c)                 ; 12T   reads the port, sets the sign flag according to MSB
    and  1                      ; 7T
    jp   z, rxError             ; 10T   error, RxD should be in log. 1 (idle state / stop bit)

; detection delay 12 + 7 + 10 = 29T

    ld   a, 0x80                ; 7T    TX = 1, CTS = 0
    out  (c), a                 ; 12T   Assert CTS to get a byte from the ESP

; Wait for the start bit

rxWFSB:
1:  in   a, (c)                 ; 12T   read port
    rrca                        ; 4T    bit 0 to carry flag
    jp   c, 1B                  ; 10T   Repeat to start bit

; waiting loop 12 + 4 + 10 = 26T

; Immediately de-assert CTS to stop the ESP transmitting another byte
; while we process this one

    ld   a, 0x81                ; 7T    TX = 1, CTS = 1
    out  (c), a                 ; 12T

; start bit started, waiting for bit 0
; the wait length is chosen so that bit 0 is somewhere in its middle
; at least 15T has passed from the edge of the start bit, at most 41T, we take an average of 28T
; you still have to wait 1.5 x 61T - 28T = 63.5T (of which 11T for another IN instruction)

    exx                         ; 4T    secondary set
    ld   bc, 0xFFD              ; 10T   printer port to BC '(and delay at the same time)
    inc  hl                     ; 6T    delay
    dec  hl                     ; 6T    delay
    ld   h, 7                   ; 7T    in the cycle will be read 7 bits and 8th at the end of the cycle

; 6 + 6 + 4 + 10 + 6 + 6 + 7 + 7 = 52T
; now bit 0 is somewhere in the middle, we can read 8 times with a distance of 61T

rxLoop:
    in   a, (c)                 ; 12T   load port
    rrca                        ; 4T    bit 0 to carry flag
    rr   l                      ; 8T    build byte in L
    ld   a, 0                   ; 7T    delay
    ld   a, 0                   ; 7T    delay
    ld   a, r                   ; 9T    delay
    dec  h                      ; 4T    counter
    jp   nz, rxLoop             ; 10T   reads more bits

; 12 + 4 + 8 + 7 + 7 + 9 + 4 + 10 = 61T if repeated (bits 0 to 6)

; followed by reading the MSB, bit 7

    in   a, (c)                 ; 12T   read port (MSB is somewhere in the middle of the duration, to the stop bit approx. 31 ± 13T ± 2T accuracy deviation 3%)
    rrca                        ; 4T    bit 0 to carry flag
    ld   a, l                   ; 4T    almost assembled byte to A
    rra                         ; 4T    rotate the MSB to bit 7 in A

; 12 + 4 + 4 + 4 = 24T

    exx                         ; 4T    primary set

; Delay for stop bit

    ex   af, af'                ; 4T
    ld   a, (ix + 0)            ; 19T delay
    ld   a, (ix + 0)            ; 19T delay
;    xor  a                      ; 4T
;    out  (-2), a                ; 11T    Black border
    ex   af, af'                ; 4T

    ei                          ; 4T
    ret                         ; 10T   Return with byte in A

; 4 + 19 + 4 + 11 + 4 + 4 + 10 = 53T

rxError
    ld   hl, readErrors         ; 3T
    inc  (hl)                   ; 11T
    jp   nz, rxRetry            ; 7/12T

    ld   a, 2                   ; 7T
    out  (-2), a                ; 11T
    ret                         ; 10T

; 3 + 11 + 12 = 26T

readErrors:
    db   0

; saving the apartment takes 4 + 7 + 4 + 4 + 10 = 29T
; total 24 + 29 = 53T
; including line status detection, 75T with verification before start bit
; otherwise, you can directly wait for the next start bit

