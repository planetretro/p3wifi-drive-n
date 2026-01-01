; hl - server
; de - path
; bc - port
; a - page
doSector:
    call    makeRequest
    jp      loadData

; HL - domain stringZ
; DE - path stringZ
; BC - port stringZ
makeRequest:
    ld      (srv_ptr), hl
    ld      (path_ptr), de
    ld      (port_ptr), bc

    ; Open TCP connection
    ld      hl, cmd_open1
    call    uartWriteStringZ
    ld      hl, (srv_ptr)
    call    uartWriteStringZ
    ld      hl, cmd_open2
    call    uartWriteStringZ
    ld      hl, (port_ptr)
    call    uartWriteStringZ
    ld      hl, cmd_open3
    call    okErrCmd

    ; call    dumpRing
    cp      1
    jp      nz, reqErr

    ; Send request
    ld      hl, cmd_send
    call    uartWriteStringZ
    ld      hl, (path_ptr)
    call    getStringLength

    push    bc
    pop     hl

    ; Write sends 512 bytes of sector data

    ld      a, (ddl_parms+0x06)
    cp      6
    jr      nz, 1F
    ld      de, 512
    add     hl, de

1:
    call    B2D16

    ld      hl, B2DBUF
    call    SkipWhitespace
    call    uartWriteStringZ
    ld      hl, crlf
    call    okErrCmd

    ; call    dumpRing
    cp      1
    jp      nz, reqErr

wPrmt:
    call    uartReadBlocking
    call    pushRing
    ld      hl, send_prompt
    call    searchRing
    jr      nc, wPrmt

    ld      hl, (path_ptr)
    call    uartWriteStringZ

    ; if write, we need to send 512 bytes of sector data here

    ld      a, (ddl_parms+0x06)
    cp      6                           ; Is it a write command?
    jr      nz, .skipWriteSector        ; No, skip sending sector data

    ld      hl, (data_pointer)
    ld      bc, 512
1:
    di
    push    hl
    push    bc
    ld      a, (ddl_parms)
    call    ram_page_in

    ld      a, (hl)
    call    uartWriteByte

    di                                  ; Need to disable again, as uartWriteByte re-enables interrupts
    call    ram_page_out
    pop     bc
    pop     hl

    inc     hl
    dec     bc

    ld      a, b
    or      c
    jr      nz, 1B

    ei

    ; Skip saving read packet data by setting data_pointer to 0
    ld   hl, 0
    ld   (data_pointer), hl

.skipWriteSector
    ld      hl, crlf
    call    uartWriteStringZ

    ld      a, 1
    ld      (connectionOpen), a
    xor     a
    ret

reqErr:
    ld      a, 2
    out     (-2), a
    ret

; HL - data pointer
; data_pointer = pointer to buffer
loadData:
    call    getPacket                ; Fetch next data packet

    ld      a, (connectionOpen)      ; Check connection status
    or      a                        ; Test if zero
    ret     z                        ; Exit loop if connection closed

    jp      loadData                 ; Process next packet

data_pointer    defw    0
data_recv       defw    0
fstream         defb    0

crlf            defb    13, 10, 0

d_path          defs    32, 0
d_host          defb    '192.168.7.164', 0
                defs    32
d_port          db      '7650', 0
                defs    1

connectionOpen  db      0

srv_ptr         dw  0
path_ptr        dw  0
port_ptr        dw  0

