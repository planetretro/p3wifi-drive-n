#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "libdsk.h"

/* Four fixed geometries. Shared params (sidedness, sector base, sector size,
 * MFM, gap values) are set in build_geometry(); only the differentiators
 * live in this table.
 *
 * disc_spec is the 10-byte "disk specification" written to byte 0..9 of
 * track 0 head 0 sector 1. +3DOS reads this on login to pick a geometry. For
 * 180K/720K we use the standard ROM Type-0 / Type-3 values so a Gotek / +3
 * auto-detects them. For 4M/8M we write a non-standard marker (byte 0 = $FF,
 * rest varied) so that a +3 will reject them if they ever end up on a Gotek. */
typedef struct {
    const char      *name;
    unsigned         cylinders;
    unsigned         heads;
    unsigned         sectors;
    dsk_rate_t       datarate;
    const char      *driver;        /* "dsk" for emulator-compatible containers,
                                     * "raw" where sector count exceeds the
                                     * 29/track DSK/EDSK ceiling. */
    unsigned char    disc_spec[10];
    const char      *capacity_desc;
} format_t;

static const format_t FORMATS[] = {
    { "180K",  40, 1,  9, RATE_SD, "dsk",
      { 0x00, 0x00, 0x28, 0x09, 0x02, 0x01, 0x03, 0x02, 0x2a, 0x52 },
      "180 KB (+3 single-sided, CPCEMU .dsk)" },

    { "720K",  80, 2,  9, RATE_SD, "dsk",
      { 0x03, 0x81, 0x50, 0x09, 0x02, 0x01, 0x04, 0x04, 0x2a, 0x52 },
      "720 KB (PCW double-sided, CPCEMU .dsk)" },

    { "4M",   128, 2, 32, RATE_HD, "raw",
      { 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00 },
      "4 MB (custom, 8 KB blocks, raw)" },

    { "8M",   128, 2, 64, RATE_ED, "raw",
      { 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00 },
      "8 MB (custom, 16 KB blocks, raw)" },
};

#define NFORMATS (sizeof(FORMATS) / sizeof(FORMATS[0]))

static void usage(FILE *out, const char *progname) {
    fprintf(out,
        "Usage: %s -f FORMAT -o OUTFILE [-y]\n"
        "\n"
        "Create a blank DSK image of the given format, sectors filled with 0xE5\n"
        "so the directory appears empty to +3DOS / CP/M.\n"
        "\n"
        "Options:\n"
        "  -f FORMAT   One of: 180K, 720K, 4M, 8M\n"
        "  -o OUTFILE  Output .dsk path\n"
        "  -y          Overwrite OUTFILE if it already exists\n"
        "  -h          Show this help\n"
        "\n"
        "Formats:\n", progname);
    for (size_t i = 0; i < NFORMATS; i++) {
        fprintf(out, "  %-6s  %s\n", FORMATS[i].name, FORMATS[i].capacity_desc);
    }
}

static const format_t *lookup_format(const char *name) {
    for (size_t i = 0; i < NFORMATS; i++) {
        if (strcasecmp(FORMATS[i].name, name) == 0) {
            return &FORMATS[i];
        }
    }
    return NULL;
}

static void build_geometry(const format_t *fmt, DSK_GEOMETRY *geom) {
    memset(geom, 0, sizeof(*geom));
    geom->dg_sidedness = SIDES_ALT;
    geom->dg_cylinders = fmt->cylinders;
    geom->dg_heads     = fmt->heads;
    geom->dg_sectors   = fmt->sectors;
    geom->dg_secbase   = 1;
    geom->dg_secsize   = 512;
    geom->dg_datarate  = fmt->datarate;
    geom->dg_rwgap     = 42;
    geom->dg_fmtgap    = 82;
    geom->dg_fm        = RECMODE_MFM;
    geom->dg_nomulti   = 0;
    geom->dg_noskip    = 0;
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

int main(int argc, char **argv) {
    const char *format_name = NULL;
    const char *outfile     = NULL;
    int         overwrite   = 0;
    int         opt;

    while ((opt = getopt(argc, argv, "f:o:yh")) != -1) {
        switch (opt) {
            case 'f': format_name = optarg; break;
            case 'o': outfile     = optarg; break;
            case 'y': overwrite   = 1;      break;
            case 'h': usage(stdout, argv[0]); return 0;
            default:  usage(stderr, argv[0]); return 1;
        }
    }

    if (!format_name || !outfile) {
        fprintf(stderr, "error: -f and -o are both required\n\n");
        usage(stderr, argv[0]);
        return 1;
    }

    const format_t *fmt = lookup_format(format_name);
    if (!fmt) {
        fprintf(stderr, "error: unknown format '%s'\n\n", format_name);
        usage(stderr, argv[0]);
        return 1;
    }

    if (file_exists(outfile)) {
        if (!overwrite) {
            fprintf(stderr,
                "error: '%s' already exists (use -y to overwrite)\n",
                outfile);
            return 2;
        }
        if (unlink(outfile) != 0) {
            fprintf(stderr, "error: could not remove existing '%s'\n", outfile);
            return 3;
        }
    }

    DSK_GEOMETRY geom;
    build_geometry(fmt, &geom);

    /* Driver per format:
     *   - CPCEMU ".dsk" for 180K and 720K so Fuse / +3E / Gotek etc. can
     *     mount the resulting file directly. These fit inside the DSK
     *     track-info block's 29-sector/track ceiling.
     *   - "raw" for 4M and 8M (32 and 64 sectors/track) which exceed the
     *     DSK/EDSK limit; the file ends up as pure sector bytes. These
     *     images aren't emulator-compatible but the WiFi server reads them
     *     fine via its raw-fallback in dsk_open. */
    DSK_PDRIVER drv = NULL;
    dsk_err_t err = dsk_creat(&drv, outfile, fmt->driver, NULL);
    if (err != DSK_ERR_OK) {
        fprintf(stderr, "dsk_creat failed: %s\n", dsk_strerror(err));
        return 4;
    }

    fprintf(stderr, "Formatting %s (%u×%u×%u @ %u bytes/sector)...\n",
        fmt->name, geom.dg_cylinders, geom.dg_heads, geom.dg_sectors,
        (unsigned)geom.dg_secsize);

    for (dsk_pcyl_t cyl = 0; cyl < geom.dg_cylinders; cyl++) {
        for (dsk_phead_t head = 0; head < geom.dg_heads; head++) {
            err = dsk_apform(drv, &geom, cyl, head, 0xE5);
            if (err != DSK_ERR_OK) {
                fprintf(stderr, "dsk_apform cyl=%u head=%u failed: %s\n",
                    cyl, head, dsk_strerror(err));
                dsk_close(&drv);
                unlink(outfile);
                return 5;
            }
        }
    }

    /* Stamp the +3DOS disc spec into the first sector (track 0, head 0,
     * sector 1). ROM reads only the first 10 bytes; keep the rest $E5. */
    unsigned char spec_sector[512];
    memset(spec_sector, 0xE5, sizeof(spec_sector));
    memcpy(spec_sector, fmt->disc_spec, sizeof(fmt->disc_spec));

    err = dsk_pwrite(drv, &geom, spec_sector, 0, 0, geom.dg_secbase);
    if (err != DSK_ERR_OK) {
        fprintf(stderr, "dsk_pwrite (disc spec) failed: %s\n", dsk_strerror(err));
        dsk_close(&drv);
        unlink(outfile);
        return 5;
    }

    err = dsk_close(&drv);
    if (err != DSK_ERR_OK) {
        fprintf(stderr, "dsk_close failed: %s\n", dsk_strerror(err));
        return 6;
    }

    struct stat st;
    if (stat(outfile, &st) == 0) {
        fprintf(stderr, "Wrote %s (%lld bytes)\n", outfile, (long long)st.st_size);
    } else {
        fprintf(stderr, "Wrote %s\n", outfile);
    }

    return 0;
}
