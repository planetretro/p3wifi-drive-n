; Push value to ring buffer
;
; Entry:
;   A:  Value to push to buffer
; Exit:
;   HL, DE, BC: Corrupt
pushRing:
    ld   hl, ring_buffer + 1
    ld   de, ring_buffer
    ld   bc, 31
    ldir
    ld   (ring_buffer + 31), a
    ret

; Search for string in buffer
;
; Entry:
;   HL: Search string
;   B:  String length (not including terminator)
; Exit:
;   Fc: 1 Found
;       0 Not found
searchRing:
    ld   a, low(ring_buffer + 32)
    sub  b
    ld   e, a
    ld   a, high(ring_buffer + 32)
    sbc  a, 0
    ld   d, a                           ; DE = ring_buffer + 32 - strlen

strcmp:
    ld   a, (de)
    cp   (hl)
    jp   nz, .failed
    inc  de
    inc  hl
    djnz strcmp
    scf
    ret

.failed
    xor  a
    ret

ring_buffer
    ds  32, 0
