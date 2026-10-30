        device ZXSPECTRUM128

bank1       equ 0x7ffd
bankm       equ 0x5B5c
xdpb_ptrs   equ 0xe2a0              ; This is the same on the +3e, +3 or +2A
bordcr      equ $5c48

    org     0xc000 - (3*1024)

; ----------------------------------------------------------------------------
; BASIC entry point. Jumps to start2.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   None
; Corrupts
;   None
; ----------------------------------------------------------------------------
start:
    display $
    jp      start2

    ; Variables that can be peeked / poked from BASIC (set by CONFIG.BAS)

    defw    d_host                  ; Addresses so we can poke in IP address
    defw    d_port                  ; and port of server if needed

; ----------------------------------------------------------------------------
; Main setup. Loads WiFi config, inits the ESP, installs the N: XDPB pointer in
; page 7, and zeroes the DPB and logged-in flag so the next access re-logs in.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   Returns to BASIC via exit
; Corrupts
;   AF, BC, DE, HL, IX, shadow set
; ----------------------------------------------------------------------------
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

    ld   a, (wifiConnected)         ; Skip connect if already connected
    or   a
    jr   nz, skipWiFi

    call loadWiFiConfig
    call initWiFi
    ld   a, 1                       ; Flag wifi as connected
    ld   (wifiConnected), a

skipWiFi:

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

    ld      hl, xdpb                ; Zero XDPB in case of being called
    ld      de, xdpb+1              ; again from BASIC "GOTO 30" in loader
    ld      bc, $1c                 ; to remove stale disk image info
    ld      (hl), 0
    ldir

    jp      exit

; ----------------------------------------------------------------------------
; +3DOS login hook for N:. Builds a geometry-request command (cmd=$07) and
; calls fetchGeom to populate the XDPB bytes 0..$1A from the server reply.
; ----------------------------------------------------------------------------
; Entry:
;   C  = Unit (ignored)
;   IX = Address of destination XDPB
; Exit
;   On success: XDPB populated, CF = 1
;   On failure: A = $06 ("Bad format"), CF = 0
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
login:
    push    ix
    ld      a, 7                     ; disk geom command - server ignores
    ld      (ddl_parms+6), a         ; other bytes for command 0x07
    call    fetchGeom                ; populates (xdpb+0)..(xdpb+$1A)
    pop     ix
    jr      nz, .fail
    jr      cmd_success
.fail:
    call    restoreBorder
    ld      a, $06                   ; "Bad format" - matches A: login's convention
    or      a                        ; CF=0 = failure
    ret

; ----------------------------------------------------------------------------
; +3DOS read-sector hook for N: - translates the logical track/sector to a
; physical command and calls loadSector to fetch the sector into the buffer.
; ----------------------------------------------------------------------------
; Entry:
;   B  = RAM page for $C000..$FFFF
;   C  = Unit (0/1)
;   D  = Logical track, 0-based
;   E  = Logical sector, 0-based
;   HL = Address of destination buffer
;   IX = Address of XDPB
; Exit
;   On success: CF = 1
;   On failure: A = 2 ("Seek fail"), CF = 0
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
read:
    push ix
    ld   a, 5
    ld   (ddl_parms+$06), a             ; Read command
    call prepFloppyCmd
    call loadSector
    pop  ix
    jr   nz, cmd_fail
    jr   cmd_success

; ----------------------------------------------------------------------------
; +3DOS write-sector hook for N: - same entry/exit as read but ships the sector
; payload to the server via storeSector.
; ----------------------------------------------------------------------------
; Entry:
;   B  = RAM page for $C000..$FFFF
;   C  = Unit (0/1)
;   D  = Logical track, 0-based
;   E  = Logical sector, 0-based
;   HL = Address of source buffer
;   IX = Address of XDPB
; Exit
;   On success: CF = 1
;   On failure: A = 2 ("Seek fail"), CF = 0
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
write:
    push ix
    ld   a, 6
    ld   (ddl_parms+$06), a             ; Write command
    call prepFloppyCmd
    call storeSector
    pop  ix
    jr   nz, cmd_fail
    jr   cmd_success

; ----------------------------------------------------------------------------
; Call buildFloppyCmd to populate ddl_parms, then set the sector buffer
; address into data_pointer so getPacket can stream bytes into it.
; ----------------------------------------------------------------------------
; Entry:
;   B, C, D, E, HL, IX as for the read/write hook
; Exit
;   ddl_parms filled, (data_pointer) = buffer address
; Corrupts
;   AF
; ----------------------------------------------------------------------------
prepFloppyCmd:
    push hl
    push de
    push bc
    call buildFloppyCmd                 ; Build command to ddl_parms
    pop  bc
    pop  de
    pop  hl

    ld   hl, (ddl_parms+1)              ; buffer address for sector read/write
    ld   (data_pointer), hl
    ret

; ----------------------------------------------------------------------------
; Common success routine for the read/write hooks: restore border, set CF.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   A = 0, CF = 1
; Corrupts
;   AF
; ----------------------------------------------------------------------------
cmd_success:
    call restoreBorder
    xor  a
    scf                                 ; Signal success
    ret

; ----------------------------------------------------------------------------
; Common failure routine for the read/write hooks
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   A = 2 ("Seek fail"), CF = 0
; Corrupts
;   AF
; ----------------------------------------------------------------------------
cmd_fail:
    call restoreBorder
    xor  a
    ld   a, 2                           ; Seek fail
    ret

; ----------------------------------------------------------------------------
; Restore BASIC's stack and HL', reset the border, and return to BASIC.
; ----------------------------------------------------------------------------
; Entry:
;   (old_sp) and (temp_hl) populated by start2
; Exit
;   Control returns to the BASIC caller
; Corrupts
;   AF
; ----------------------------------------------------------------------------
exit:
    di
    ld      sp, (old_sp)                ; Restore SP
    exx
    ld      hl, (temp_hl)               ; Restore HL' for BASIC
    exx
    call    restoreBorder
    ei
    ret

; ----------------------------------------------------------------------------
; Reset the border to the colour BASIC had set via BORDCR.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   None
; Corrupts
;   AF
; ----------------------------------------------------------------------------
restoreBorder:
    ld      a, (bordcr)                 ; Restore border colour
    and     $38
    rrca
    rrca
    rrca
    out     (-2), a
    ret

; ----------------------------------------------------------------------------
; CP/M 2.2 Disk Parameter Block for +3 standard 180KB format.
; ----------------------------------------------------------------------------
xdpb:
    defw    36                  ; +$00 SPT: 9 sectors × 4 = 36 128-byte records
    defb    3                   ; +$02 BSH: block shift (block = 128 << 3 = 1024)
    defb    7                   ; +$03 BLM: block mask
    defb    0                   ; +$04 EXM: extent mask
    defw    174                 ; +$05 DSM: max block number (175 blocks)
    defw    63                  ; +$07 DRM: max directory entry (64 entries)
    defb    $c0                 ; +$09 AL0: blocks 0+1 reserved for directory
    defb    $00                 ; +$0a AL1
    defb    16                  ; +$0b CKS LSB: checksum vector size (DRM+1)/4
    defb    $80                 ; +$0c CKS MSB with bit 7 set to indicate fixed drive
    defw    1                   ; +$0d OFF: reserved tracks (track 0 = boot)
    defs    $1b - 15, 0         ; $0f-$1a: dd_sel_format writes $11-$19

.l17f6
    defb    $00,'N',$00         ; flags,drive,unit - bit 2 CLEAR so +3DOS
                                ; doesn't probe the (non-existent) FDC for
                                ; write-protect status during SAVE
    defb    $00,$00,$00,$00     ; last access,filesopen
    defw    $0000,$0000         ; #free direntries,last used
    defw    chksm_a,alloc_a     ; checksum vector,alloc bitmap
    defw    login               ; login disk
    defw    read                ; read sector
    defw    write               ; write sector

; ----------------------------------------------------------------------------
; Convert a logical track/sector to a physical command block in ddl_parms+6..+e.
; Also stores the buffer address, bank, and sector size via l1b9c.
; ----------------------------------------------------------------------------
; Entry:
;   D  = Logical track
;   E  = Logical sector
;   C  = Unit
;   HL = Buffer address
;   B  = Buffer bank
;   A  = Floppy command byte
;   IX = XDPB
; Exit
;   ddl_parms+1..+e populated
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
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

; ----------------------------------------------------------------------------
; Fill the common part of the ddl_parms block (buffer address, bank, command
; byte, unit, sector size) ready for a sector read/write command.
; ----------------------------------------------------------------------------
; Entry:
;   HL = Buffer address
;   A  = Floppy command byte
;   B  = Buffer bank
;   D  = Logical track (passed through to l1bb5)
;   C  = Unit
;   IX = XDPB
; Exit
;   ddl_parms layout partially populated
; Corrupts
;   AF, BC, HL
; ----------------------------------------------------------------------------
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

; ----------------------------------------------------------------------------
; Map a logical track to a physical (side, track) using the sidedness byte in
; the XDPB. Side bit is also ORed into the unit byte via l1bd4.
; ----------------------------------------------------------------------------
; Entry:
;   D  = Logical track
;   C  = Unit
;   IX = XDPB
; Exit
;   B  = Physical side
;   D  = Physical track
;   C  = Unit with side bit ORed in at bit 2
; Corrupts
;   AF
; ----------------------------------------------------------------------------
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
;   HL = Address in page 7, or 0 if error
; Corrupts
;   AF, BC, DE
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
    jr      c, .error               ; error if <A
    cp      $10
    jr      nc, .error              ; error if >P
    add     a,a
    add     a, low xdpb_ptrs
    ld      l,a
    adc     a, high xdpb_ptrs
    sub     l
    ld      h, a                    ; HL=xdpb_ptrs+2*drive
    ret

.error:
    ld      hl, 0
    ret

; ----------------------------------------------------------------------------
; Page in +3DOS, call the routine whose address is in IX, then page out.
; ----------------------------------------------------------------------------
; Entry:
;   IX = Address of +3DOS routine to call
;   Other registers as required by the target routine
; Exit
;   As set by the target routine
; Corrupts
;   AF, BC (via paging) plus whatever the target routine corrupts
; ----------------------------------------------------------------------------
dos_ix:
    di
    call dos_in
    call call_ix                        ; Call routine in IX
    call dos_out
    ei
    ret

; ----------------------------------------------------------------------------
; Page +3DOS and RAM page 7 into $C000..$FFFF.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   None
; Corrupts
;   (none - AF, BC preserved via internal push/pop)
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

; ----------------------------------------------------------------------------
; Page the requested RAM bank into $C000..$FFFF without changing the ROM map.
; ----------------------------------------------------------------------------
; Entry:
;   A = RAM page number (0..7)
; Exit
;   None
; Corrupts
;   AF, BC, E
; ----------------------------------------------------------------------------
ram_page_in:
    ld      e, a
    ld      bc, $7ffd
    ld      a, (bankm)
    and     %11111000       ; Lose RAM bits
    or      e               ; Or in RAM page
    out     (c), a
    ret

; ----------------------------------------------------------------------------
; Restore the default banking configuration (whatever is in bankm).
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   None
; Corrupts
;   AF, BC
; ----------------------------------------------------------------------------
ram_page_out:
    ld      bc, $7ffd
    ld      a, (bankm)
    out     (c), a          ; restore memory configuration
    ret

; ----------------------------------------------------------------------------
; Jump through IX. Helper so dos_ix can CALL into IX with a RET-back path.
; ----------------------------------------------------------------------------
; Entry:
;   IX = Target address
; Exit
;   As set by the target routine
; Corrupts
;   As set by the target routine
; ----------------------------------------------------------------------------
call_ix:
    jp   (ix)                           ; Jump to IX and return

; ----------------------------------------------------------------------------
; Page +3DOS out and restore RAM page 0 and ROM 3 (48K BASIC).
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   None
; Corrupts
;   (none - AF, BC preserved via internal push/pop)
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

; Sized for the largest supported geometry:
;   chksm_a: max CKS = 64 bytes (DRM=255 on 720K and 8M → (DRM+1)/4 = 64)
;   alloc_a: max alloc bitmap = 128 bytes (DSM=1023 on 4M and 8M → 1024/8)
chksm_a
    defs 64, 0

alloc_a
    defs 128, 0

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

; +$06    1     Command byte
; +$07    1     Unit byte                   x x x x x H U1 U0
; +$08    1     Track
; +$09    1     Side
; +$0A    1     1st sector id
; +$0B    1     Sector size
; +$0C    1     Last sector id (=1st)
; +$0D    1     Gap size
; +$0E    1     Dummy data length ($ff)

    save3dos "build/driven.bin", start, end-start   ; Version for build disk
    savebin  "drive_n.bin", start, end-start        ; Version for loading directly to RAM
