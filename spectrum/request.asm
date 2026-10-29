loadSector:
    ld      hl, d_host
    ld      de, d_path
    ld      bc, d_port
    call    openRequest
    call    sendTextData
    call    loadData
    ret

; Fetch the 27-byte XDPB (DPB + extended format fields) from the server.
;   Entry: ddl_parms+6 already = $07; prepFloppyCmd already built d_path.
;   Exit:  Z  = success; bytes 0..$1A of xdpb populated.
;          NZ = failure; xdpb untouched.
fetchGeom:
    ; Point data_pointer at the scratch buffer before the send, same way
    ; prepFloppyCmd sets it before read:'s loadSector call. getPacket.readByte
    ; will deposit the raw hex chars from the +IPD, response here.
    ld      hl, geomBuf
    ld      (data_pointer), hl

    ld      hl, d_host
    ld      de, d_path
    ld      bc, d_port
    call    openRequest
    call    sendTextData                ; 26-byte cmd via CIPSEND=26
    call    loadData                    ; drains until CLOSED

    ; How many chars did we actually get? data_pointer advanced that many.
    ld      hl, (data_pointer)
    ld      de, geomBuf
    or      a                           ; clear CF
    sbc     hl, de                      ; HL = bytes received
    ld      a, h
    or      a
    jr      nz, .fail                   ; > 255 ⇒ bogus
    ld      a, l
    cp      54
    jr      nz, .fail                   ; need exactly 54

    ; Convert 27 pairs of ASCII hex into XDPB bytes 0..$1A.
    ld      hl, geomBuf
    ld      de, xdpb
    ld      b, 27
.cvt:
    push    bc
    call    .hexPair                    ; (hl) → A, HL += 2
    jr      nz, .cvtFail
    ld      (de), a
    inc     de
    pop     bc
    djnz    .cvt

    xor     a                           ; Z = success
    ret

.cvtFail:
    pop     bc
.fail:
    or      1                           ; NZ = failure
    ret

; Decode 2 ASCII hex chars at (hl) into a byte in A. Advances HL by 2.
;   Z  = valid pair, A = byte
;   NZ = at least one char was not [0-9A-F], A undefined.
.hexPair:
    ld      a, (hl)
    inc     hl
    call    .hexNib
    ret     nz
    rlca
    rlca
    rlca
    rlca
    ld      c, a                        ; stash high nibble
    ld      a, (hl)
    inc     hl
    call    .hexNib
    ret     nz
    or      c
    cp      a                           ; Z=1, A preserved
    ret

; Decode ASCII hex char in A → nibble 0..15 in A. Z=valid, NZ=invalid.
.hexNib:
    sub     '0'
    cp      10
    jr      c, .hnOk                    ; '0'-'9'
    sub     'A' - '0'
    cp      6
    ret     nc                          ; outside 'A'-'F' → NC → NZ (invalid)
    add     a, 10                       ; 'A'-'F' → 10..15
.hnOk:
    cp      a                           ; Z=1, A preserved
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

; Scratch area for fetchGeom: 54 ASCII hex chars = 27 XDPB bytes.
geomBuf         defs    54, 0
