# +3WiFi - Disk Server

This code implements a disk image server + related Spectrum +3 client to access disk images over WiFi on the Spectrum +3.

> A +3WiFi card from [Planet Retro](https://planet-retro.co.uk) is required for this software to work. It's entirely possible to swap out the ESP-12 code for another driver to use an ESP-12 connected to the AY chip etc.

Once up and running, you'll have a new drive 'N:' in BASIC that can access files from a disk image on a remote machine.

See [this video](https://www.youtube.com/watch?v=A6ab68BPvUA) to see it in action.

> Note the software is currently read only (you can't save files over the network), and it only works with standard 180Kb disk images (.dsk file with a size of 194,816 bytes)

## Building the server

> The server only works on Linux or macOS. I don't run Windows, and I certainly don't program for it, so the server part would need to be written by someone else for Windows machines.

You'll need libdsk installed on your machine to build the server.

```
# macOS
brew install libdsk

# debian
apt install libdsk4

# arch
yay -S libdsk
```

After that, cd to dskserver and run make.

Once that's done, you should be able to do

```
./dskserver diskimage.dsk
```

in a terminal, and the server will be up and running.

> You'll need to know the IP address of your machine to configure the client on the Spectrum side of things.

## Configuring the client

The client disk is already built in `spectrum/build/driven.dsk`.

Make sure to do this before anything else (so we load and save stuff to the correct place when configuring the IP address of the server)

```
load"b:":save"b:" : rem ...or whatever drive you're using for the driven.dsk image
```

There's a program on there called `config.bas`. Load this first, and enter the IP address of the computer running the disk image server.

This will load and patch driven.bin with the IP address you entered and will save the code, so you only have to do this once (as long as the IP address of the disk image server remains static).

After that, you'll need to make sure you have `iw.cfg` (your SSID / password file) from when you originally configured the card copied to the disk image, e.g.

```
copy"c:iw.cfg"to"b:"
```

Once that's done, you can do:

```basic
load"disk"
```

Once WiFi has connected, you should be able to do:

```basic
cat"n:"
```

and see the contents of the drive. Once that works, you can now copy / load files from drive N to whatever you want on the Spectrum.

## Building the client

There's no need to do this, but you'll need iDSK and zmakebas installed to do so.

Change directory to spectrum, then run `./build.sh` to rebuild the disk image.

* https://github.com/cpcsdk/idsk
* https://github.com/z00m128/zmakebas

## Credits

* [Nihirash](https://nihirash.net/projects/) (once again), as the Spectrum ESP-12 network code is largely his work
* [John Elliot](https://www.seasip.info/Unix/LibDsk/index.html) for libdsk
* [cygnus.speccy.cz](cygnus.speccy.cz) for the amazing 56k serial port code
* Amstrad (some of the client code is directly ripped from the +3DOS ROM)

