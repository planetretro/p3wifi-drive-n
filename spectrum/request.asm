loadSector:
    ld      hl, d_host
    ld      de, d_path
    ld      bc, d_port

    push    ix
    call    openRequest
    call    sendTextData
    call    loadData
    pop     ix

    ret

loadSectorBinary:
    ret

; HL - domain stringZ
; DE - path stringZ
; BC - port stringZ
openRequest:
    ld      (srv_ptr), hl
    ld      (path_ptr), de              ; Text string to send
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
    jr      nz, reqErr

    ; Open request
    ld      hl, cmd_send
    call    uartWriteStringZ
    ret

sendTextData:
    ; Calculate data length
    ld      hl, (path_ptr)
    call    getStringLength

    call    openSendData
    jr      nz, reqErr
    ld      hl, (path_ptr)
    call    uartWriteStringZ
    jp      closeSend

reqErr:
    ld      a, 2
    out     (-2), a
    ret

; (ddl_params+0) = page to load data in to
; data_pointer = pointer to buffer, or 0 to throw away data
loadData:
    call    getPacket                ; Fetch next data packet
    ld      a, (connectionOpen)      ; Check connection status
    or      a                        ; Test if zero
    ret     z                        ; Exit loop if connection closed
    jp      loadData                 ; Process next packet

; Should be called after 'openRequest' has been called.

; BC = Total length
openSendData:
    push    bc
    pop     hl

    ; Send length
    call    B2D16
    ld      hl, B2DBUF
    call    SkipWhitespace
    call    uartWriteStringZ
    ld      hl, crlf
    call    okErrCmd

    cp      1
    ret     nz

waitPrompt:
    call    uartReadBlocking
    call    pushRing
    ld      hl, send_prompt
    call    searchRing
    jr      nc, waitPrompt
    ret

sendBinaryData:
    ld      (data_addr), hl
    push    bc
    pop     hl
    ld      (data_len), hl

    ld      hl, (data_addr)
    ld      bc, (data_len)

1:  ld      a, (hl)
    push    hl
    push    bc
    call    uartWriteByte
    call    flashBorder
    pop     bc
    pop     hl
    inc     hl
    dec     bc
    ld      a, b
    or      c
    jr      nz, 1B
    jp      restoreBorder

closeSend:
    ld      hl, crlf
    call    uartWriteStringZ
    ld      a, 1
    ld      (connectionOpen), a
    xor     a                           ; Set zero flag
    ret

data_addr       defw 0
data_len        defw 0

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

