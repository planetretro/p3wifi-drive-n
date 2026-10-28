loadSector:
    ld      hl, d_host
    ld      de, d_path
    ld      bc, d_port

    call    openRequest
    call    sendTextData
    call    loadData

    ret

storeSector:
    ; debug - yellow border
    ld   a, 6
    out  (-2), a
    ; debug

    ld      hl, d_host
    ld      de, d_path
    ld      bc, d_port

    call    openRequest                 ; ends with uart write of "AT+CIPSEND="

    ld      bc, 26 + 1024               ; command + hex-encoded sector payload
    call    openSendData                ; writes "1050\r\n", waits for ">"
    jr      nz, .fail

    ld      hl, d_path                  ; 26-byte hex command (null-terminated)
    call    uartWriteStringZ

    ld      hl, (ddl_parms+1)           ; buffer start address
    ld      bc, 512                     ; bytes to encode (× 2 = 1024 chars)
.payloadLoop:
    push    bc
    push    hl

    di
    ld      a, (ddl_parms)              ; buffer bank
    call    ram_page_in                 ; clobbers A,BC,E — HL,D,IX preserved
    ld      a, (hl)                     ; grab byte while bank is in
    ld      d, a                        ; stash in D (survives ram_page_out)
    call    ram_page_out                ; clobbers A,BC — HL,D,IX preserved
    ei

    ld      a, d
    call    sendHexByte                 ; 2 ASCII hex chars via UART

    pop     hl
    pop     bc
    inc     hl
    dec     bc
    ld      a, b
    or      c
    jr      nz, .payloadLoop

    call    closeSend                   ; trailing CRLF
    call    dropData                    ; discard anything else

    xor     a                           ; Z = success
    ret

.fail:
    or      1                           ; NZ = failure, caller takes cmd_fail
    ret

; A = byte; writes high nibble then low nibble as ASCII hex via UART.
sendHexByte:
    push    af                          ; save raw byte for second nibble
    rra
    rra
    rra
    rra
    call    .nibble                     ; write high nibble
    pop     af
    jp      .nibble                     ; tail: write low nibble

.nibble:
    and     0x0f
    add     a, 0x90
    daa
    adc     a, 0x40
    daa
    jp      uartWriteByte               ; tail: UART write returns to caller

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

dropData:
    ld     hl, 0                     ; Flag to getPacket to discard remaining packet data
    ld     (data_pointer), hl        ; by setting data_pointer to 0

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
d_host          defb    '192.168.1.50', 0
                defs    32
d_port          db      '7650', 0
                defs    1

connectionOpen  db      0

srv_ptr         dw  0
path_ptr        dw  0
port_ptr        dw  0
