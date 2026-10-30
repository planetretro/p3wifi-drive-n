loadSector:
    ld      hl, d_host
    ld      de, ddl_parms+6             ; 9-byte binary command
    ld      bc, d_port
    call    openRequest
    call    sendCmdData
    call    loadData
    ret

storeSector:
    ld      hl, d_host
    ld      de, ddl_parms+6             ; 9-byte binary command
    ld      bc, d_port
    call    openRequest                 ; ends with uart write of "AT+CIPSEND="

    ld      bc, 9 + 512                 ; command + raw binary sector payload
    call    openSendData                ; writes "521\r\n", waits for ">"
    jr      nz, .fail

    ; Send the 9-byte command block via uartWriteByte
    ld      hl, ddl_parms+6
    ld      b, 9
    call    sendBytes

    ld      hl, (ddl_parms+1)           ; buffer start address
    ld      bc, 512                     ; bytes to send
1:
    push    bc
    push    hl

    di
    ld      a, (ddl_parms)              ; buffer bank
    call    ram_page_in
    ld      a, (hl)                     ; grab byte while bank is paged in
    ld      d, a                        ; stash in D (survives ram_page_out)
    call    ram_page_out
    ei

    ld      a, d
    call    uartWriteByte               ; raw byte via UART

    pop     hl
    pop     bc
    inc     hl
    dec     bc
    ld      a, b
    or      c
    jr      nz, 1B

    call    closeSend                   ; trailing CRLF
    call    dropData                    ; discard trailing packet data

    xor     a                           ; Z = success
    ret

.fail:
    or      1                           ; NZ = failure, caller takes cmd_fail
    ret

; Fetch the 27-byte XDPB (DPB + extended format fields) from the server.
;   Entry: ddl_parms+6 already = $07.
;   Exit:  Z  = success; bytes 0..$1A of xdpb populated.
;          NZ = failure; xdpb may be partially written.
fetchGeom:
    ; Stream the 27 raw bytes straight into the XDPB
    ld      hl, xdpb
    ld      (data_pointer), hl

    ld      hl, d_host
    ld      de, ddl_parms+6             ; 9-byte binary command
    ld      bc, d_port
    call    openRequest
    call    sendCmdData                 ; 9-byte cmd via CIPSEND=9
    call    loadData                    ; drains until CLOSED

    ; data_pointer advanced by the number of bytes received.
    ld      hl, (data_pointer)
    ld      de, xdpb
    or      a                           ; clear CF
    sbc     hl, de                      ; HL = bytes received
    ld      a, h
    or      a
    jr      nz, .fail                   ; > 255 ⇒ bogus
    ld      a, l
    cp      27
    jr      nz, .fail                   ; need exactly 27

    xor     a                           ; Z = success
    ret

.fail:
    or      1                           ; NZ = failure
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

    cp      1
    jr      nz, reqErr

    ; Open request
    ld      hl, cmd_send
    call    uartWriteStringZ
    ret

; Send the 9-byte binary command pointed to by path_ptr.
; openRequest should have been called first.
sendCmdData:
    ld      bc, 9
    call    openSendData
    jr      nz, reqErr

    ld      hl, (path_ptr)
    ld      b, 9
    call    sendBytes

    jp      closeSend

reqErr:
    ld      a, 2
    out     (-2), a
    ret

dropData:
    ld     hl, 0                     ; Flag to getPacket to discard remaining packet data
    ld     (data_pointer), hl        ; by setting data_pointer to 0

    ; ... falls through ...

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
    ld      b, send_prompt_len
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

; Send bytes to UART
; Entry:
;   B: Bytes to send
;  HL: Address of data
sendBytes:
    ld      a, (hl)
    exx
    call    uartWriteByte
    exx
    inc     hl
    djnz    sendBytes
    ret

data_addr       defw 0
data_len        defw 0

data_pointer    defw    0
data_recv       defw    0
fstream         defb    0

crlf            defb    13, 10, 0

d_host          defb    '192.168.1.50', 0
                defs    32
d_port          db      '7650', 0
                defs    1

connectionOpen  db      0

srv_ptr         dw  0
path_ptr        dw  0
port_ptr        dw  0
