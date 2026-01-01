        device ZXSPECTRUM128

bank1       equ 0x7ffd
bankm       equ 0x5B5c
xdpb_ptrs   equ 0xe2a0              ; This is the same on the +3e, +3 or +2A
bordcr      equ $5c48

    org     0xc000 - (3*1024)

start:
    display $
    jp      start2

    ; Variables that can be peeked / poked from BASIC

    defw    d_host                  ; Addresses so we can poke in IP address
    defw    d_port                  ; and port of server if needed
disk_type:
    defb    0                       ; Disk type

start2:

    ; Set up the stack and save HL' so we can return to BASIC

    di
    ld   (old_sp), sp               ; Move stack so it doesn't get paged out
    ld   sp, tmp_stack              ; when calling +3DOS
    exx
    ld   (temp_hl), hl              ; Save HL' as it's needed if returning to BASIC
    exx
    ei

    ; Load WiFi config + init ESP

    ld   a, (wifiConnected)
    or   a
    jr   nz, 1F

;        call text_init

    call loadWiFiConfig
    call initWiFi
    ld   a, 1                           ; Flag wifi as connected
    ld   (wifiConnected), a

1:
    ; Set up XDPB for drive 'N:'

    ld      a, 'N'
    call    getXDPBPtr              ; Return the pointer to XDPB for drive N

    di
    ld      a, 7
    call    ram_page_in

    ld      a, low xdpb             ; Set pointer to point to our XDPB
    ld      (hl), a
    inc     hl
    ld      a, high xdpb
    ld      (hl), a
    dec     hl

    call    ram_page_out
    ei

    ld      ix, xdpb
    ld      a, (disk_type)          ; 0 = Standard +3 format disk
    ld      hl, exit
    push    hl
    ld      hl, dd_sel_format
    push    hl
    jp      dos_tos

login:
    jp      cmd_success

;    B = Page for C000h (49152)...FFFFh (65535)
;    C = Unit (0/1)
;    D = Logical track, 0 base
;    E = Logical sector, 0 base
;   HL = Address of buffer
;   IX = Address of XDPB
read:
    ld   a, 5
    ld   (ddl_parms+$06), a             ; Read command
    call prepFloppyCmd
    call loadSector
    jr   nz, cmd_fail
    jr   cmd_success

write:
    jr   cmd_fail

prepFloppyCmd:
    push hl
    push de
    push bc
    call buildFloppyCmd                 ; Build command to ddl_parms
    pop  bc
    pop  de
    pop  hl
    call floppyCmdToString              ; Convert to hex string

    ld   hl, (ddl_parms+1)              ; buffer address for sector read/write
    ld   (data_pointer), hl
    ret

cmd_success:
    call restoreBorder
    xor  a
    scf                                 ; Signal success
    ret

cmd_fail:
    call restoreBorder
    xor  a
    ld   a, 2                           ; Seek fail
    ret

exit:
    di
    ld      sp, (old_sp)
    exx
    ld      hl, (temp_hl)
    exx

    call    restoreBorder

    ei
    ret

restoreBorder:
    ld      a, (bordcr)                 ; Restore border colour
    and     $38
    rrca
    rrca
    rrca
    out     (-2), a
    ret

floppyCmdToString:
    ld   hl, ddl_parms+6
    ld   bc, 0x09
    ld   de, d_path
    call bytesToHex
    xor  a                              ; Null terminate string
    ld   (hl), a
    ret

bytesToHex:
1:  ld   a, (hl)
    push bc
    call hexToBuf
    pop  bc
    inc  hl
    dec  bc
    ld   a, b
    or   c
    ret  z
    ld   a, ' '
    ld   (de), a
    inc  de
    jr   1B

; Entry:
;   A = Hex value
;  DE = Output buffer
hexToBuf:
    ld   c, a
    rra
    rra
    rra
    rra
    call 1f
    ld   a, c
1:  and  0x0f
    add  a, 0x90
    daa
    adc  a, 0x40
    daa
    ld   (de), a
    inc  de
    ret

xdpb:
    defs $1b, 0

.l17f6
    defb    $04,'N',$00         ; flags,drive,unit
    defb    $00,$00,$00,$00     ; last access,filesopen
    defw    $0000,$0000         ; #free direntries,last used
    defw    chksm_a,alloc_a     ; checksum vector,alloc bitmap
    defw    login               ; login disk
    defw    read                ; read sector
    defw    write               ; write sector

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

l1b9c
    ld      (ddl_parms+1),hl        ; store buffer address
    ld      l,a                     ; Floppy command
    ld      a,b                     ; Page
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

l1bb5
    ld      a,(ix+$11)
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

l1bc8
    ld      a,d
    sub     (ix+$12)                ; subtract # tracks
    jr      c,l1bd4                 ; if < # tracks, physical=logical so move on
    sub     (ix+$12)                ; on successive side, tracks count back down
    cpl
    ld      d,a
    inc     b                       ; and use side 1

l1bd4
    ld      a,b                     ; A = side (0 or 1)
    add     a,a                     ; A*= 2
    add     a,a
    or      c                       ; OR in unit number
    ld      c,a                     ; update unit number with side bit as bit 1
    ret

; ----------------------------------------------------------------------------
; Get the address of the pointer to an XDPB for a given drive letter
; ----------------------------------------------------------------------------
; Entry:
;   A = Drive letter, 'A'...'P'
; Exit
;   HL = Address in page 7 of pointer, or 0 if error
; ----------------------------------------------------------------------------
getXDPBPtr:
    push    af
    ld      a, 7
    call    ram_page_in
    pop     af
    call    .getPtr
    call    ram_page_out
    ret

.getPtr
    ld      hl,xdpb_ptrs
    sub     'A'
    jr      c, .error         ; error if <A
    cp      $10
    jr      nc, .error        ; error if >P
    add     a,a
    add     a, low xdpb_ptrs
    ld      l,a
    adc     a, high xdpb_ptrs
    sub     l
    ld      h, a             ; HL=xdpb_ptrs+2*drive
    ret
.error:
    ld      hl, 0
    ret

; Entry
;   IX = +3dos routine to call
dos_ix:
    di
    call dos_in
    call call_ix                        ; Call routine in IX
    call dos_out
    ei
    ret

dos_tos:
    call dos_in
    exx                  ; preserve parameters
    pop  hl               ; address of the DOS routine
    ld   de,dos_tos_return ; return address from the DOS routine
    push de              ; force the return later
    push hl              ; address of the DOS routine
    exx                  ; restore parameters
    ret                  ; call routine in TOS, then continue at dos.ix.return

dos_tos_return:
    call dos_out
    ret

; ----------------------------------------------------------------------------
; Page in +3dos
; ----------------------------------------------------------------------------
dos_in:
    push af
    push bc              ; temp save registers while switching
    ld   bc,bank1        ; port used for horiz. ROM switch and RAM paging
    ld   a,(bankm)       ; RAM/ROM switching system variable
    res  4,a             ; and DOS ROM
    or   7               ; set bits 0-3: RAM 7
    ld   (bankm),a       ; keep system variables up to date
    out  (c),a           ; RAM page 7 to top and DOS ROM
    pop  bc
    pop  af
    ret

; A = RAM page
ram_page_in:
    ld      e, a
    ld      bc, $7ffd
    ld      a, (bankm)
    and     %11111000       ; Lose RAM bits
    or      e               ; Or in RAM page
    out     (c), a
    ret

ram_page_out:
    ld      bc, $7ffd
    ld      a, (bankm)
    out     (c), a          ; restore memory configuration
    ret

call_ix:
    jp   (ix)                           ; Jump to IX and return

; ----------------------------------------------------------------------------
; Page out +3DOS
; ----------------------------------------------------------------------------
dos_out:
    push af
    push bc
    ld   a,(bankm)
    and  %11111000           ; reset bits 0-3: RAM 0
    set  4,a                 ; switch to ROM 3 (48 BASIC)
    ld   bc,bank1
    ld   (bankm),a
    out  (c),a               ; switch back to RAM page 0 and 48 BASIC
    pop  bc
    pop  af
    ret

; dosError:
;     ld   (0x4000), a
;     ld   a, 2
;     out  (-2), a
;     ret

; Data

; Space for floppy emulation command
ddl_parms
    defs    $6

dd_cmd
    defs    $13

temp_hl:
    defw    0

wifiConnected:
    defb    0

chksm_a
    defs $10, 0

alloc_a
    defs $2d, 0

old_sp:
    defw 0

    defs 100
tmp_stack:
    defw 0

    include "p3dos.asm"
    include "prtwifi.asm"
    include "ring.asm"
    include "utils.asm"
    include "wifi.asm"
    include "request.asm"
;    include "screen42.asm"
;    include "font42.asm"

conf_file
    defb "iw.cfg",0xff
    defs 13-($-conf_file), 0xff

ssid:
    defs    80
pass:
    defs    80

end:

; ddl_parms layout

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

    save3dos "driven.bin", start, end-start
    savebin  "drvn.bin", start, end-start

