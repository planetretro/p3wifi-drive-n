#!/bin/sh

sjasmplus drive_n.asm --lst

cp blank.dsk build/driven.dsk

zmakebas -i 10 -s 10 -a 10 -l -p -o build/disk loader.bas
zmakebas -i 10 -s 10 -a 10 -l -p -o build/config.bas config.bas

iDSK build/driven.dsk -i build/disk -t 2
iDSK build/driven.dsk -i build/config.bas -t 2
iDSK build/driven.dsk -i build/driven.bin -t 2

