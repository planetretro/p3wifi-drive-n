
; Convert logical track / sector to physical
; Entry:
;   DE = Logical Track / Sector
;    C = Unit

buildFloppyCmd:
        call    l1b9c                   ; setup basic parameter block data
        ld      a,e
        add     a,(ix+$14)
        ld      e,a                     ; E=physical sector number
        push    de                      ; save physical track & sector numbers
        ld      a,e
        ld      (ddl_parms+$0a),a       ; store 1st sector ID
        ld      l,(ix+$0f)
        ld      h,e
        ld      (ddl_parms+$0b),hl      ; store sector size & last(=1st) sector ID
        ld      a,(ix+$17)
        ld      (ddl_parms+$0d),a       ; store gap length
        ld      h,b
        ld      l,d
        ld      (ddl_parms+8),hl        ; store track & side numbers
        ld      a,$09
        ld      (ddl_parms+5),a         ; store # command bytes
        ld      hl,ddl_parms+$0e
        ld      (hl),$ff                ; store dummy data length
        pop     de
        ret

; Subroutine to setup some of the parameter block for sector read/writes
; (except # command bytes & additional command bytes)

l1b9c   ld      (ddl_parms+1),hl        ; store buffer address
        ld      l,a
        ld      a,b
        ld      (ddl_parms),a           ; store buffer page
        call    l1bb5                   ; C=physical side & unit byte
        ld      h,c
        ld      (ddl_parms+6),hl        ; store command & unit byte
        ld      l,(ix+$15)
        ld      h,(ix+$16)
        ld      (ddl_parms+3),hl        ; store sector size as # bytes to transfer
        ret

; Subroutine to return physical side (B) and track (D) given logical track (D)
; Physical side is also ORed with unit number in C

l1bb5   ld      a,(ix+$11)
        and     $7f                     ; A=sidedness
        ld      b,$00                   ; side 0
        ret     z                       ; exit if single-sided (physical=logical)

        dec     a
        jr      nz,l1bc8                ; move on if double-sided: successive sides

        ld      a,d
        rra                             ; for alternate sides, halve track
        ld      d,a
        ld      a,b
        rla                             ; with side=remainder
        ld      b,a
        jr      l1bd4                   ; move on to OR into unit number

l1bc8   ld      a,d
        sub     (ix+$12)                ; subtract # tracks
        jr      c,l1bd4                 ; if < # tracks, physical=logical so move on
        sub     (ix+$12)                ; on successive side, tracks count back down
        cpl
        ld      d,a
        inc     b                       ; and use side 1

l1bd4   ld      a,b                     ; A = side (0 or 1)
        add     a,a                     ; A*= 2
        add     a,a
        or      c                       ; OR in unit number
        ld      c,a                     ; update unit number with side bit as bit 1
        ret

; Space for floppy emulation command
ddl_parms
        defs    $6
dd_cmd
        defs    $13

; Off.    Size  Desc
; +$00    1     Buffer page
; +$01    2     Buffer address
; +$03    2     Sector size in bytes
; +$05    1     # Command bytes

; READ

; +$06    1     Command byte
; +$07    1     Unit byte                   x x x x x H U1 U0
; +$08    1     Track
; +$09    1     Side
; +$0A    1     1st sector id
; +$0B    1     Sector size
; +$0C    1     Last sector id (=1st)
; +$0D    1     Gap size
; +$0E    1     Dummy data length ($ff)

