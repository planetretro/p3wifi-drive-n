; ----------------------------------------------------------------------------
; Open a TCP request to the server, send the 9-byte read command, and stream
; the 512-byte sector reply into the buffer pointed to by (data_pointer).
; ----------------------------------------------------------------------------
; Entry:
;   ddl_parms+6..+e holds the 9-byte read command block
;   (data_pointer) = destination buffer address
;   (ddl_parms)    = destination RAM bank
; Exit
;   Sector bytes written to the destination buffer
; Corrupts
;   AF, BC, DE, HL, shadow set
; ----------------------------------------------------------------------------
loadSector:
    ld      hl, d_host
    ld      de, ddl_parms+6             ; 9-byte binary command
    ld      bc, d_port
    call    openRequest
    call    sendCmdData
    call    loadData
    ret

; ----------------------------------------------------------------------------
; Open a TCP request to the server, send the 9-byte write command, then stream
; 512 bytes from the source buffer (paging the bank in per byte) as the payload.
; ----------------------------------------------------------------------------
; Entry:
;   ddl_parms+6..+e holds the 9-byte write command block
;   (ddl_parms+1)  = source buffer address
;   (ddl_parms)    = source RAM bank
; Exit
;   ZF = 1 on success, 0 on failure
; Corrupts
;   AF, BC, DE, HL, shadow set
; ----------------------------------------------------------------------------
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

; ----------------------------------------------------------------------------
; Send a geometry request (cmd=$07) and stream the 27-byte XDPB reply straight
; into bytes 0..$1A of the local XDPB.
; ----------------------------------------------------------------------------
; Entry:
;   ddl_parms+6 = $07 (geometry command)
; Exit
;   ZF = 1 on success (xdpb[0..$1A] populated), 0 on failure
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
fetchGeom:
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


; ----------------------------------------------------------------------------
; Open a TCP connection to a host and send the AT+CIPSTART prelude, then issue
; AT+CIPSEND= ready for the caller to supply a payload length.
; ----------------------------------------------------------------------------
; Entry:
;   HL = Address of null-terminated host string
;   DE = Address of command/payload pointer (stored in path_ptr for callers)
;   BC = Address of null-terminated port string
; Exit
;   On success: ESP primed with AT+CIPSEND=
;   On failure: border error indicator set via reqErr
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
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

; ----------------------------------------------------------------------------
; Send the 9-byte binary command pointed to by (path_ptr) as a single CIPSEND
; payload, then close the send phase.
; ----------------------------------------------------------------------------
; Entry:
;   (path_ptr) set to source address by a prior openRequest
; Exit
;   On success: command delivered, connectionOpen set
;   On failure: tail-calls reqErr
; Corrupts
;   AF, BC, DE, HL, shadow set
; ----------------------------------------------------------------------------
sendCmdData:
    ld      bc, 9
    call    openSendData
    jr      nz, reqErr

    ld      hl, (path_ptr)
    ld      b, 9
    call    sendBytes

    jp      closeSend

; ----------------------------------------------------------------------------
; Signal a request error by setting the border red, then return.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   Border set to red
; Corrupts
;   AF
; ----------------------------------------------------------------------------
reqErr:
    ld      a, 2
    out     (-2), a
    ret

; ----------------------------------------------------------------------------
; Discard the remainder of an in-flight ESP response. Zeros (data_pointer) so
; getPacket discards bytes, then falls through to loadData.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   (data_pointer) = 0, (connectionOpen) = 0
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
dropData:
    ld     hl, 0                     ; Flag to getPacket to discard remaining packet data
    ld     (data_pointer), hl        ; by setting data_pointer to 0

    ; ... falls through ...

; ----------------------------------------------------------------------------
; Call getPacket in a loop until (connectionOpen) is zero, draining the
; connection.
; ----------------------------------------------------------------------------
; Entry:
;   (data_pointer) = destination buffer, or 0 to discard
;   (ddl_parms)    = destination RAM bank
; Exit
;   (connectionOpen) = 0
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
loadData:
    call    getPacket                ; Fetch next data packet
    ld      a, (connectionOpen)      ; Check connection status
    or      a                        ; Test if zero
    ret     z                        ; Exit loop if connection closed
    jp      loadData                 ; Process next packet

; ----------------------------------------------------------------------------
; Issue AT+CIPSEND=<BC> and wait for the ESP '>' prompt. Must be called after
; openRequest.
; ----------------------------------------------------------------------------
; Entry:
;   BC = Total payload byte count that will follow
; Exit
;   On success: '>' prompt consumed, caller may send BC bytes
;   On failure: ZF = 0 and A = 0
; Corrupts
;   AF, BC, DE, HL
; ----------------------------------------------------------------------------
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

; ----------------------------------------------------------------------------
; Terminate the AT+CIPSEND payload with CRLF and mark the connection as open so
; loadData will drain until a CLOSED prelude arrives.
; ----------------------------------------------------------------------------
; Entry:
;   None
; Exit
;   (connectionOpen) = 1, ZF = 1
; Corrupts
;   AF, BC, HL
; ----------------------------------------------------------------------------
closeSend:
    ld      hl, crlf
    call    uartWriteStringZ
    ld      a, 1
    ld      (connectionOpen), a
    xor     a                           ; Set zero flag
    ret

; ----------------------------------------------------------------------------
; Send B raw bytes starting at (HL) over the UART.
; ----------------------------------------------------------------------------
; Entry:
;   HL = Address of source bytes
;   B  = Byte count
; Exit
;   HL = Address past the last byte sent
; Corrupts
;   AF, B, HL, shadow BC/HL (uartWriteByte); shadow restored via exx pairs
; ----------------------------------------------------------------------------
sendBytes:
    ld      a, (hl)
    exx
    call    uartWriteByte
    exx
    inc     hl
    djnz    sendBytes
    ret

data_addr       defw    0
data_len        defw    0

data_pointer    defw    0
data_recv       defw    0
fstream         defb    0

crlf            defb    13, 10, 0

d_host          defb    '192.168.1.50', 0
                defs    32
d_port          db      '7650', 0
                defs    1

connectionOpen  db      0

srv_ptr         dw      0
path_ptr        dw      0
port_ptr        dw      0
