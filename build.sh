#!/bin/sh

sjasmplus drive_n.asm --lst

cp blank.dsk build/driven.dsk

iDSK build/driven.dsk -i driven.bin -t 2

