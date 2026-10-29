; Pushes A to ring buffer. LDIR doesn't touch A, so no need to stash it.
; Clobbers F, BC, DE, HL (per LDIR semantics).
pushRing:
    ld   hl, ring_buffer + 1
    ld   de, ring_buffer
    ld   bc, 31
    ldir
    ld   (ring_buffer + 31), a
    ret

; Entry:
;   HL: Search string
;   B:  String length (not including terminator); caller precomputes
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
