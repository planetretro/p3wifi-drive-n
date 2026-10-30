; ----------------------------------------------------------------------------
; Push one byte to the tail of the 32-byte ring buffer.
; ----------------------------------------------------------------------------
; Entry:
;   A = Byte to push
; Exit
;   None
; Corrupts
;   F, BC, DE, HL
; ----------------------------------------------------------------------------
pushRing:
    ld   hl, ring_buffer + 1
    ld   de, ring_buffer
    ld   bc, 31
    ldir
    ld   (ring_buffer + 31), a
    ret

; ----------------------------------------------------------------------------
; Test whether a string appears at the end of the ring buffer.
; ----------------------------------------------------------------------------
; Entry:
;   HL = Address of search string
;   B  = Length of search string
; Exit
;   CF = 1 if found, 0 if not
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
searchRing:
    ld   a, low(ring_buffer + 32)
    sub  b
    ld   e, a
    ld   a, high(ring_buffer + 32)
    sbc  a, 0
    ld   d, a                           ; DE = ring_buffer + 32 - strlen

    ; Compare string

1:  ld   a, (de)
    cp   (hl)
    jp   nz, .failed
    inc  de
    inc  hl
    djnz 1B
    scf
    ret

.failed
    xor  a
    ret

ring_buffer
    ds  32, 0
