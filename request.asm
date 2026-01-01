loadSector:
    ld      hl, d_host
    ld      de, d_path
    ld      bc, d_port

    push    ix
    call    makeRequest
    call    loadData
    pop     ix

    ret

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

