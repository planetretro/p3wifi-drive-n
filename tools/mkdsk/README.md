# mkdsk

Create pre-formatted DSK images for the p3wifi `N:` drive.

Four fixed geometries: the two standard formats +3DOS knows about, plus two custom "large" formats designed for the network drive (essentially giving you a 4M or 8M hard disk served over the network). Every sector is filled with `$E5` so +3DOS sees an empty, clean disk on first access (so there's no need for thse disk images to be fornatted).

180K and 720K are 'standard' DSK images. 4M and 8M disks are EDSK images due to them having more than 29 sectors per track.

## Build

```
make
```

Links against `libdsk` (same dependency as the `dskserver`).

## Usage

```
./mkdsk -f FORMAT -o OUTFILE [-y]
```

- `-f FORMAT`  one of `180K`, `720K`, `4M`, `8M`.
- `-o OUTFILE` output `.dsk` path.
- `-y`         overwrite `OUTFILE` if it already exists (default: don't overwrite existing files).
- `-h`         help.

Examples:

```
./mkdsk -f 180K -o blank180.dsk
./mkdsk -f 4M   -o big.dsk
./mkdsk -f 8M   -o big.dsk -y     # overwrite
```

Exit codes:

| Code | Meaning |
|------|---------|
| 0    | Success |
| 1    | Bad arguments / unknown format |
| 2    | Output file exists and `-y` not given |
| 3    | Could not remove existing output file |
| 4    | `dsk_creat` failed |
| 5    | `dsk_apform` failed |
| 6    | `dsk_close` failed |

## Supported formats

| Format | Geometry (C × H × S × 512 B) | Capacity | Notes |
|--------|------------------------------|----------|-------|
| 180K   | 40 × 1 × 9                   | 180 KB   | Standard +3 SS DT (matches `blank.dsk`) |
| 720K   | 80 × 2 × 9                   | 720 KB   | PCW 720 K double-sided |
| 4M     | 128 × 2 × 32                 | 4096 KB  | Custom - 8 KB CP/M blocks |
| 8M     | 128 × 2 × 64                 | 8192 KB  | Custom - 16 KB CP/M blocks |

All formats share: `SIDES_ALT`, sector base ID = 1, 512-byte sectors, MFM, `rwgap` = 42, `fmtgap` = 82. Datarate is informational only.

## CP/M DPB reference

Values each format that will be needed in the XDPBs:

| Format | BSH | Block | DSM | alloc_a | EXM | DRM | AL0 | CKS | OFF | SPT |
|--------|-----|-------|-----|---------|-----|-----|-----|-----|-----|-----|
| 180K   | 3   | 1 KB  | 174 | 45 B    | 0   | 63  | $C0 | 16  | 1   | 36  |
| 720K   | 4   | 2 KB  | 358 | 46 B    | 0   | 127 | $C0 | 32  | 1   | 36  |
| 4M     | 6   | 8 KB  | 511 | 64 B    | 3   | 255 | $80 | 64  | 0   | 128 |
| 8M     | 7   | 16 KB | 511 | 64 B    | 7   | 511 | $80 | 128 | 0   | 256 |

- `BSH` / `BLM`: block size shift / mask. Block size = 128 << BSH.
- `DSM`: max block number (number of data blocks - 1).
- `alloc_a`: required allocation-bitmap buffer size in RAM, = ⌈(DSM+1)/8⌉.
- `EXM`: extent mask. For DSM ≥ 256 (= our 4M and 8M): `(1 << (BSH-4)) - 1`.
- `DRM`: max directory entry (= directory_size / 32 - 1). Scales with block size because the directory sits in a single block for the big formats.
- `AL0` / `AL1`: bitmask of blocks reserved for the directory. `$C0` = blocks 0 + 1 (2-block directory); `$80` = block 0 only (1-block directory).
- `CKS`: checksum vector size, = (DRM+1)/4. Can be set to 0 and the whole `chksm_a` buffer dropped since the drive is logically fixed - see `~/Documents/Development/spectrum/p3-custom-disk-geom.md` for rationale.
- `OFF`: reserved tracks at the start of the disk. `1` for formats that mimic a bootable floppy, `0` for our custom non-bootable formats.
- `SPT`: sectors per track, in 128-byte records (= sectors × 4 for 512-byte sectors).

> **Spectrum-side XDPB integration is TBD** - see `~/Documents/Development/spectrum/p3-custom-disk-geom.md` for the broader design discussion of how the Spectrum side would select between formats at init.
