; TODO: UTF-8 chars

;extern charset42
;extern scroll_all
;extern xy_to_paddr

;public text_init
;public goto_xy
;public putstr
;public putc
;public set_min_x

;putC equ putc
;gotoXY equ goto_xy
;mvCR equ nextrow

mvCR:
    push   bc
    push   de
    push   hl
    jp     nextrow

; B = Line number
clearLine:
    ld   h, b
    ld   l, 0
    call xy_to_paddr
    ld   e, l
    ld   bc, 0x2008                     ; 32 cols and 8 rows
    xor  a
1:  ld   (hl), a                        ; Blank pixels
    inc  l                              ; Move to next column
    djnz 1B                             ; 32 cols cleared?
    ld   b, 0x20                        ; Reset column count
    ld   l, e                           ; Back to column 0
    inc  h                              ; Next line
    dec  c                              ; Decrease row count
    jr   nz, 1B                         ; Jump back for next row
    ret

clearScreen:
    xor  a
    out  (#fe), a

    IFNDEF ZX48
    ld   hl, #c000
    ld   de, #c001
    ELSE
    ld   hl, #4000
    ld   de, #4001
    ENDIF

    ld   (hl), 0
    ld   bc, #17FF
    ldir

    IFNDEF ZX48
    ld   hl, #d800
    ld   de, #d801
    ELSE
    ld   hl, #5800
    ld   de, #5801
    ENDIF

    ld   a, 7
    ld   (hl), a
    ld   bc, #2FF
    ldir

text_init:
    xor a
    ld (v_column), a
    ld (v_rowcount), a

    IFNDEF ZX48
    ld   hl, 0xc000
    ELSE
    ld   hl, 0x4000
    ENDIF

    ld (v_row), hl
    ret

set_min_x:
    ld (min_v), a
    ret

backspace_inner:
    pop   hl
    pop   de
    pop   bc
backspace:
    ld  a, (v_column)
    ld  hl, min_v
    cp  (hl)
    ret c

    dec a
    ld  (v_column), a
    call eraseChar
    ret

clearchar:
    ret

gotoXY:
    ld   h, b
    ld   l, c

; hl = yx
goto_xy:
    ld   a, l
    ld   (v_column), a
    ld   a, h
    ld   (v_rowcount), a

setrow_addr_hl:
    call xy_to_paddr
    ld   (v_row), hl
    ret

setrow_addr:
    ld (v_row), hl
    ret

putstr:
    ld      a, (hl)
    and     a                   ; NULL?
    ret     z

    call    putc                ; print the char
    inc     hl
    jr      putstr

putC:
putc:
    push   bc
    push   de
    push   hl

    cp      0x0A                  ; CR?
    jr      z, nextrow            ; TODO: Reset char column if CR

    cp      13                  ; Newline?
    jr      z, nextrow

    cp      12
    jp      z, backspace_inner

    cp      0x80
    jp      nc, cp866

    ; Work out the bitmap address from A

cp866_not_handled:
    sub     32                  ; space = offset 0
    ld      l, a
cp866_cont:
    ld      h, 0

    add     hl, hl              ; Multiply hl by 8
    add     hl, hl
    add     hl, hl

    ld      de, charset42       ; add the offset
    add     hl, de
    ex      de, hl

    ld      hl, (col_table)     ; col_lookup must be page aligned!
    ld      a, (v_column)
    ld      b, a
    add     a, l                ; 8 bit add!
    ld      l, a                ; hl = pointer to byte in lookup table
    ld      a, (hl)             ; a = lookup table value
    ld      hl, (v_row)         ; hl = framebuffer pointer for start of row
    add     a, l
    ld      l, a                ; hl = frame buffer address

; de contains the address of the char bitmap
; hl contains address in the frame buffer

paintchar1:
    ld      a, b                    ; retrieve column
    and     3                       ; find out how much we need to rotate
    jr      z, norotate1            ; no need to rotate, character starts at MSB
    rla                             ; multipy by 2
    ld      (tmp_a), a              ; save A
    ld      b, 8                    ; byte copy count for outer loop

fbwriterotated1:
    push    bc                      ; save outer loop count
    ld      a, (tmp_a)
    ld      b, a                    ; set up rotate loop count
    ld      a, (de)                 ; get character bitmap
    ld      c, a                    ; C contains rightmost fragment of bitmap
    xor     a                       ; set a=0 to accept lefmost fragment of bitmap
rotloop1:
    rl      c
    rla                             ; suck out leftmost bit from the carry flag
    djnz    rotloop1

writerotated1:
    or      (hl)                    ; merge with existing character
    ld      (hl), a
    ld      a, c
    or      a
    jr      z, writerotated1_skip1  ; nothing to do

    inc     l                       ; next char cell
    or      (hl)
    ld      (hl), a
    dec     l                       ; restore l
writerotated1_skip1:
    inc     h                       ; next line
    inc     de                      ; next line of character bitmap
    pop     bc                      ; retrieve outer loop count
    djnz    fbwriterotated1
nextchar1:
    ld      a, (v_column)
    inc     a
    cp      42
    jr      nz, nextchar1_done1

nextrow:
    ld      a, (v_rowcount)
    cp      23
    jr      nz, nextrow_cont

;    call    scroll_all
    jp      nextchar1_saverow2

nextrow_cont:
    inc     a
    ld      (v_rowcount), a  ; TODO: If A == 22 then we need to scroll the screen one line

    ld      hl, (v_row)    ; advance framebuffer pointer to next character row
    ld      a, l
    add     a, 32
    jr      c, nextthird1
    ld      l, a
    jr      nextchar1_saverow1

nextthird1:
    ld      l, 0
    ld      a, h
    add     a, 8
    ld      h, a

nextchar1_saverow1:
    ld      (v_row), hl

nextchar1_saverow2:
    xor     a
nextchar1_done1:
    ld      (v_column), a

leave1:
    pop     hl
    pop     de
    pop     bc
    ret

norotate1:
    ld      b, 8
norotate1_loop1:
    ld      a, (de)             ; move bitmap into the frame buffer
    ld      (hl), a
    inc     de                  ; next line of bitmap
    inc     h                   ; next line of frame buffer
    djnz    norotate1_loop1
    jp      nextchar1

eraseChar:
    ; Find the address in the frame buffer.
    ld hl, col_lookup

    ld a, (v_column)
    ld b, a
    add a, l
    ld l, a     ; hl = pointer to byte in lookup table
    ld a, (hl)  ; a = lookup table value
    ld hl, (v_row)  ; hl = framebuffer pointer for start of row
    add a, l
    ld l, a     ; hl = frame buffer address
    ld a, b     ; retrieve column
    and 3       ; find out how much rotation is needed
    jr z, norotate3    ; no need to do any at all

    rla     ; multiply by 2
    ld b, a     ; set loop count
    ld a, 0xFC  ; binary 11111100 - mask with no rotation

    ; now create two masks - one for the left byte, and one for the
    ; right byte.
    ld c, 0     ; c will contain left mask
maskloop3:
    rla
    rl c
    djnz maskloop3
rotated3:
    cpl     ; turn it into the proper mask value
    ld (tmp_a), a  ; save right byte mask
    ld b, 8     ; 8 bytes high
rotated_loop3:
    inc l       ; right hand byte
    and (hl)    ; make new value
    ld (hl), a  ; write it back
    ld a, c     ; get left mask
    cpl
    dec l       ; point at left byte
    and (hl)
    ld (hl), a  ; write it back
    inc h       ; next line in frame buffer
    ld a, (tmp_a)  ; retrieve right byte mask
    djnz rotated_loop3
    ret     ; done

norotate3:
    ld b, 8     ; 8 bytes high
norotate_loop3:
    ld a, 0x03  ; mask out left 6 bits
    and (hl)    ; mask out character cell at current position
    ld (hl), a  ; write back to frame buffer
    inc h
    djnz norotate_loop3
    ret

cp866:
;    add  0x80

    cp   0xDB
    jr   nz, s1
    ld   l, 160
    jp   cp866_cont
s1:
    cp   194
    jr   nz, s2
    ld   l, 161
    jp   cp866_cont
s2:
not_handled:
    ld  a, '?'
    jp  cp866_not_handled

; enter : h = valid character y coordinate
;         l = valid character x coordinate
;
; exit  : hl = screen address corresponding to the top
;              pixel row of the character square
;
; uses  : af, hl
xy_to_paddr:
   ld   a, h

   rrca
   rrca
   rrca
   and  0xe0
   or   l
   ld   l, a

   ld   a, h
   and  0x18
;   or   0x40

    IFNDEF ZX48
    or      #c0
    ELSE
    or      #40
    ENDIF

   ld   h, a
   ret

; enter : h = valid character y coordinate
;         l = valid character x coordinate
;
; exit  : hl = attribute address corresponding to character
;
; uses  : af, hl
xy_to_aaddr:
   ld   a, h
   rrca
   rrca
   rrca
   ld   h, a

   and  0xe0
   or   l
   ld   l, a

   ld   a, h
   and  0x03
;   or   0x58

    IFNDEF ZX48
    or  #d8
    ELSE
    or  #58
    ENDIF

   ld   h, a
   ret

   align 256

col_lookup:
    defb 0, 0, 1, 2, 3, 3, 4, 5, 6, 6, 7, 8, 9, 9, 10, 11, 12, 12, 13, 14, 15, 15
    defb 16, 17, 18, 18, 19, 20, 21, 21, 22, 23, 24, 24, 25, 26, 27, 27, 28, 29, 30, 30, 31

col_table:
    defw col_lookup

v_row:
    defw    $0000

v_rowcount:
    defb    $00

v_column:
    defb    $00

min_v:
    defb    $00

tmp_a:
    defb    $00
