clear 46079
load "driven.bin" code
let a=peek (46080+3)+ peek (46080+4)*256

print "Drive N: Config"
print "Enter server IP address"

input line i$
let i$=i$+chr$(0)
for i=1 to len(i$)
let b=code(i$(i))
poke a+i-1,b
next i

save "driven.bin"code 46080,3072

print "Please copy iw.cfg to this disk"
print "before loading the disk"
print "program to connect to drive N:"


