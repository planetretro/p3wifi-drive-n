ROM_OPEN_CHANNEL        EQU  0x1601             ; Open a channel
ROM_PRINT               EQU  0x203C             ; Print a string

    macro dodos n
        ld   ix, n
        call dos_ix
    endm

loadWiFiConfig:
    ld      a, 1
    call    ROM_OPEN_CHANNEL
    ld      de, loadingMsg
    ld      bc, loadingMsgLen
    call    ROM_PRINT

    ld      b, 1
    ld      hl, conf_file
    ld      c, ACCESS_MODE_EXCLUSIVE_READ
    ld      d, CREATE_ACTION_DONT_CREATE
    ld      e, OPEN_ACTION_READ_HEADER
    dodos   dos_open
    jr      nc, .error

    ld      b, 1
    ld      c, 0
    ld      de, 160
    ld      hl, ssid
    dodos   dos_read
    jr      nc, .error

    ld      b, 1
    dodos   dos_close
    ret

.error
    ld      a, 2
    out     (-2), a
    ret

; Initialize WiFi chip and connect to WiFi
initWiFi
    ld      a, 1
    call    ROM_OPEN_CHANNEL
    ld      de, connectingMsg
    ld      bc, connectingMsgLen
    call    ROM_PRINT

    call    uartBegin
    ld      hl, cmd_rst
    call    uartWriteStringZ

1
    ; Flush ESP TX buffer
    call    uartBegin

    ; WiFi client mode
    ld      hl, cmd_mode
    call    okErrCmd
    and     1
    jr      z, errInit

    ; Disable ECHO. BTW Basic UART test
    ld      hl, cmd_at
    call    okErrCmd
    and     1
    jr      z, errInit

    ; Lets disconnect from last AP
    ld      hl, cmd_cwqap
    call    okErrCmd
    and     1
    jr      z, errInit

    ; Single connection mode
    ld      hl, cmd_cmux
    call    okErrCmd
    and     1
    jr      z, errInit

    ; FTP enables this info? We doesn't need it :-)
    ld      hl, cmd_inf_off
    call    okErrCmd
    and     1
    jr      z, errInit

; Access Point connection
    ld      hl, cmd_cwjap1
    call    uartWriteStringZ
    ld      hl, ssid
    call    uartWriteStringZ
    ld      hl, cmd_cwjap2
    call    uartWriteStringZ
    ld      hl, pass
    call    uartWriteStringZ
    ld      hl, cmd_cwjap3
    call    okErrCmd

    and 1 :jr z, errInit

    ret

errInit
    ; ld hl, log_err : call putStringZ
    ld   a, 3
    out  (-2), a
    jr $

; Send AT-command and wait for result.
; HL - Z-terminated AT-command(with CR/LF)
; A:
;    1 - Success
;    0 - Failed
okErrCmd
    call    uartWriteStringZ
okErrCmdLp
    call    uartReadBlocking
    call    pushRing

    ld      hl, response_ok
    call    searchRing
    jr      c, okErrOk
    ld      hl, response_err
    call    searchRing
    jr      c, okErrErr
    ld      hl, response_fail
    call    searchRing
    jr      c, okErrErr

    jp      okErrCmdLp
okErrOk
    ld      a, 1
    ret
okErrErr
    xor     a
    ret

; Gets packet from network
; packet will be in var 'output_buffer'
; received packet size in var 'bytes_avail'
;
; If connection was closed it calls 'closed_callback'
getPacket
    call    uartReadBlocking
    cp      '+'
    jr      z, .checkIpdStart
    cp      'O'
    jr      z, .checkClosed
    jr      getPacket

.readPacket
    call    count_ipd_length
    ld      (bytes_avail), hl
    push    hl
    pop     bc                      ; BC = byte count

    ld      hl, (data_pointer)
.readByte
    push    bc
    push    hl
    call    uartReadBlocking

    di

    ld      a, h                    ; Check if we should save data
    or      l
    jr      z, .skip

    push    af
    ld      a, (ddl_parms)
    call    ram_page_in
    pop     af

    pop     hl
    pop     bc

    ld      (hl), a
    inc     hl
    dec     bc

    push    bc
    push    hl
    call    ram_page_out
.skip
    pop     hl
    pop     bc

    ld      a, b
    or      c
    jr      nz, .readByte

    ld      (data_pointer), hl

    ei
    ret

.checkIpdStart
    call uartReadBlocking : cp 'I' : jr nz, getPacket
    call uartReadBlocking : cp 'P' : jr nz, getPacket
    call uartReadBlocking : cp 'D' : jr nz, getPacket
    call uartReadBlocking ; Comma
    jr   .readPacket

.checkClosed
    call uartReadBlocking : cp 'S' : jr nz, getPacket
    call uartReadBlocking : cp 'E' : jr nz, getPacket
    call uartReadBlocking : cp 'D' : jr nz, getPacket
    call uartReadBlocking : cp 13  : jr nz, getPacket
    jp   closed_callback

closed_callback:
    xor  a
    ld   (connectionOpen), a
    ei
    ret

count_ipd_length
    ld   hl, 0          ; count length
1:  push hl
    call uartReadBlocking
    push af
    call pushRing
    pop  af
    pop  hl
    cp   ':'
    ret  z

    call atoi2
    jr   1B

cmd_rst     defb "AT+RST",13, 10, 0
cmd_at      defb "ATE0", 13, 10, 0                  ; Disable echo - less to parse
cmd_mode    defb "AT+CWMODE_DEF=1",13,10,0          ; Client mode
cmd_cmux    defb "AT+CIPMUX=0",13,10,0              ; Single connection mode
cmd_cwqap   defb "AT+CWQAP",13,10,0                 ; Disconnect from AP
cmd_inf_off defb "AT+CIPDINFO=0",13,10,0            ; doesn't send me info about remote port and ip

cmd_cwjap1  defb  "AT+CWJAP_CUR=", #22,0        ;Connect to AP. Send this -> SSID
cmd_cwjap2  defb #22,',',#22,0                  ; -> This -> Password
cmd_cwjap3  defb #22, 13, 10, 0                 ; -> And this

cmd_open1   defb "AT+CIPSTART=", #22, "TCP", #22, ",", #22, 0
cmd_open2   defb #22, ",", 0
cmd_open3   defb 13, 10, 0
cmd_send    defb "AT+CIPSEND=", 0
cmd_close   defb "AT+CIPCLOSE",13,10,0
cmd_send_b  defb "AT+CIPSEND=1", 13, 10,0
closed      defb "CLOSED", 13, 10, 0
ipd         defb 13, 10, "+IPD,", 0

response_rdy        defb 'ready', 0
response_invalid    defb 'invalid', 0
response_ok         defb 'OK', 13, 10, 0      ; Sucessful operation
response_err        defb 13, 10, 'ERROR', 13, 10, 0      ; Failed operation
response_fail       defb 13, 10, 'FAIL', 13, 10, 0       ; Failed connection to WiFi. For us same as ERROR

bytes_avail   defw 0
sbyte_buff    defb 0, 0

send_prompt defb ">",0

loadingMsg:
    defb 0x16, 1, 0, "Loading WiFi config..."
loadingMsgLen: equ $-loadingMsg

connectingMsg:
    defb 0x16, 1, 0, "Connecting...         "
connectingMsgLen equ $-connectingMsg

