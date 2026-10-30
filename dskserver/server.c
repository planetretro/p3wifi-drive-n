#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include "libdsk.h"

// Server config
#define PORT 7650
#define BUFFER_SIZE 1024

// Config for build_xdpb
#define MAX_ALLOC_BYTES   128    // alloc bitmap ceiling (B); decides BSH
#define DIR_ENTRIES_MIN    64    // directory entries

// 0 = silent (-q), 1 = default (startup + \r Read/Write), 2 = -v (per-request), 3 = -vv (debug dumps).
static int verbosity = 1;

DSK_PDRIVER driver = NULL;

// dir_blocks: how many disk blocks to set aside for the directory. We
// hard-code the values the +3 ROM uses for the two standard sizes so N:
// shows the same free space as a real +3 would: 180K uses 2, 720K uses 4.
// Set to 0 for 4M and 8M where there's no ROM standard to match, and
// build_xdpb works out a sensible value from the disk size instead.
typedef struct {
    const char   *name;
    int           dir_blocks;
    DSK_GEOMETRY  g;
} named_geom_t;

// Supported disk geometries
static const named_geom_t GEOMETRIES[] = {
    { "180K", 2, {
        .dg_sidedness = SIDES_ALT, .dg_cylinders = 40,  .dg_heads = 1, .dg_sectors = 9,
        .dg_secbase   = 1,         .dg_secsize   = 512,
        .dg_datarate  = RATE_SD,   .dg_rwgap     = 42,  .dg_fmtgap = 82,
        .dg_fm        = RECMODE_MFM
    }},
    { "720K", 4, {
        .dg_sidedness = SIDES_ALT, .dg_cylinders = 80,  .dg_heads = 2, .dg_sectors = 9,
        .dg_secbase   = 1,         .dg_secsize   = 512,
        .dg_datarate  = RATE_SD,   .dg_rwgap     = 42,  .dg_fmtgap = 82,
        .dg_fm        = RECMODE_MFM
    }},
    { "4M", 0, {
        .dg_sidedness = SIDES_ALT, .dg_cylinders = 128, .dg_heads = 2, .dg_sectors = 32,
        .dg_secbase   = 1,         .dg_secsize   = 512,
        .dg_datarate  = RATE_HD,   .dg_rwgap     = 42,  .dg_fmtgap = 82,
        .dg_fm        = RECMODE_MFM
    }},
    { "8M", 0, {
        .dg_sidedness = SIDES_ALT, .dg_cylinders = 128, .dg_heads = 2, .dg_sectors = 64,
        .dg_secbase   = 1,         .dg_secsize   = 512,
        .dg_datarate  = RATE_ED,   .dg_rwgap     = 42,  .dg_fmtgap = 82,
        .dg_fm        = RECMODE_MFM
    }},
};
#define NGEOMETRIES (sizeof(GEOMETRIES) / sizeof(GEOMETRIES[0]))

// Current geometry
DSK_GEOMETRY geom;

// How many blocks of the disk to reserve for the directory. 0 = let
// build_xdpb work it out from the disk size.
int dir_blocks_override = 0;

// Command structure
typedef struct {
    unsigned char ddCmd;
    unsigned char ddUnit;
    unsigned char ddTrack;
    unsigned char ddSide;
    unsigned char ddStartSec;
    unsigned char ddSize;
    unsigned char ddEndSec;
    unsigned char ddGap;
    unsigned char ddLen;
    unsigned char ddHead;
    unsigned char ddError;
} DiskCommand;

/**
 * Decode 9 raw command bytes into the DiskCommand struct.
 * Bytes map 1:1 to Spectrum's ddl_parms+6..+e.
 */
int parse_command(const unsigned char *input, DiskCommand *cmd) {
    cmd->ddError    = 0;
    cmd->ddCmd      = input[0];
    cmd->ddUnit     = input[1];
    cmd->ddTrack    = input[2];
    cmd->ddSide     = input[3];
    cmd->ddStartSec = input[4];
    cmd->ddSize     = input[5];
    cmd->ddEndSec   = input[6];
    cmd->ddGap      = input[7];
    cmd->ddLen      = input[8];

    // Side is already in ddSide (ddl_parms+9)
    cmd->ddHead     = cmd->ddSide;

    if (verbosity >= 2) {
        for (int i = 0; i < 9; i++) printf("%02x ", input[i]);
        printf("\n");
    }
    return 0;
}

/**
 * Compute 27 XDPB bytes (CP/M DPB + +3DOS extended format fields) from the
 * current libdsk geometry. Fields are packed in XDPB offset order so the
 * Spectrum can `ld (hl), a : inc hl` straight into its XDPB.
 *
 * Returns 0 on success, non-zero if no BSH 3..7 keeps the alloc bitmap under
 * MAX_ALLOC_BYTES (which only happens for implausibly large disks).
 */
int build_xdpb(const DSK_GEOMETRY *g, size_t capacity, int dir_blocks_hint,
               uint8_t out[27]) {
    /* --- Physical geometry straight from libdsk --- */
    unsigned ss = (unsigned)g->dg_secsize;
    int psh = 0;
    while (ss > 128) { ss >>= 1; psh++; }           /* log2(secsize/128)      */
    int phm = (1 << psh) - 1;
    int spt = (int)(g->dg_sectors * (g->dg_secsize / 128));

    /* --- CP/M DPB policy --- */
    int off = (capacity <= 1024u * 1024u) ? 1 : 0;
    /* OFF is in CP/M logical tracks. For ALT, a logical track = one side,
     * i.e. SPT × secsize bytes — NOT a whole cylinder. +3DOS maps
     * logical track 0 to physical cyl 0 side 0 only. */
    size_t reserved = (size_t)off * g->dg_sectors * g->dg_secsize;
    if (reserved >= capacity) return -1;
    size_t data_bytes = capacity - reserved;

    int bsh = -1;
    size_t block = 0, blocks = 0;
    for (int b = 3; b <= 7; b++) {
        size_t cand_block  = 128UL << b;
        size_t cand_blocks = data_bytes / cand_block;
        if (cand_blocks == 0) continue;
        /* CP/M 2.2 constraint: DSM ≥ 256 forces 2-byte block pointers in
         * directory entries, which requires BSH ≥ 4 (block ≥ 2 KB) so that
         * one 16 KB extent still fits in the 8 pointers of one entry.
         * Skip BSH=3 when the resulting DSM would exceed 255. */
        if (cand_blocks > 256 && b < 4) continue;
        size_t cand_alloc  = (cand_blocks + 7) / 8;
        if (cand_alloc <= MAX_ALLOC_BYTES) {
            bsh = b; block = cand_block; blocks = cand_blocks;
            break;
        }
    }
    if (bsh < 0) return -2;

    int dsm = (int)(blocks - 1);
    int blm = (1 << bsh) - 1;
    int exm = (dsm < 256)
            ? ((1 << (bsh - 3)) - 1)
            : ((1 << (bsh - 4)) - 1);

    size_t entries_per_block = block / 32;
    int dir_blocks = dir_blocks_hint > 0
        ? dir_blocks_hint
        : (int)((DIR_ENTRIES_MIN + entries_per_block - 1) / entries_per_block);
    if (dir_blocks < 1) dir_blocks = 1;
    int entries = dir_blocks * (int)entries_per_block;
    int drm = entries - 1;
    int al0 = ((1 << dir_blocks) - 1) << (8 - dir_blocks);  /* $80, $C0, $E0 */
    int al1 = 0;
    int cks = (drm + 1) / 4;

    /* --- Pack bytes in XDPB offset order --- */
    out[0x00] = spt & 0xff;
    out[0x01] = (spt >> 8) & 0xff;
    out[0x02] = (uint8_t)bsh;
    out[0x03] = (uint8_t)blm;
    out[0x04] = (uint8_t)exm;
    out[0x05] = dsm & 0xff;
    out[0x06] = (dsm >> 8) & 0xff;
    out[0x07] = drm & 0xff;
    out[0x08] = (drm >> 8) & 0xff;
    out[0x09] = (uint8_t)al0;
    out[0x0A] = (uint8_t)al1;
    out[0x0B] = cks & 0xff;
    out[0x0C] = (cks >> 8) & 0x7f;
    out[0x0D] = off & 0xff;
    out[0x0E] = (off >> 8) & 0xff;
    out[0x0F] = (uint8_t)psh;
    out[0x10] = (uint8_t)phm;
    /* +3DOS sidedness byte: $00 single, $01 ALT, $81 successive. Single-sided
     * drives MUST be $00 - otherwise l1bb5 does ALT translation and the
     * side bit gets ORed into the unit byte on every access. */
    if (g->dg_heads < 2)                   out[0x11] = 0x00;
    else if (g->dg_sidedness == SIDES_ALT) out[0x11] = 0x01;
    else                                   out[0x11] = 0x81;
    out[0x12] = (uint8_t)g->dg_cylinders;
    out[0x13] = (uint8_t)g->dg_sectors;
    out[0x14] = (uint8_t)g->dg_secbase;
    out[0x15] = g->dg_secsize & 0xff;
    out[0x16] = (g->dg_secsize >> 8) & 0xff;
    out[0x17] = (uint8_t)g->dg_rwgap;
    out[0x18] = (uint8_t)g->dg_fmtgap;
    out[0x19] = 0x60;                                /* match dd_sel_format   */
    out[0x1A] = 0x00;

    return 0;
}

/**
 * Handle client connection and process disk read command
 */
void handle_client(int client_socket) {
    char recv_buffer[BUFFER_SIZE];
    unsigned char sector_data[512];
    DiskCommand cmd;
    ssize_t bytes_received;
    ssize_t total_sent = 0;
    dsk_err_t result;
    int flag = 1;

    // Disable Nagle's algorithm for immediate send (ESP-12 compatibility)
    setsockopt(client_socket, IPPROTO_TCP, TCP_NODELAY, (char *)&flag, sizeof(int));

    // Receive command from client. Loop until we have at least the 9-byte
    // command header; a single CIPSEND may deliver command + payload together,
    // in which case we read as much as fits in one go.
    memset(recv_buffer, 0, BUFFER_SIZE);
    bytes_received = 0;
    while (bytes_received < 9) {
        ssize_t n = recv(client_socket, recv_buffer + bytes_received,
                         BUFFER_SIZE - 1 - bytes_received, 0);
        if (n <= 0) {
            if (n == 0) {
                if (verbosity >= 2) printf("Client disconnected\n");
            } else {
                perror("recv failed");
            }
            close(client_socket);
            return;
        }
        bytes_received += n;
    }

    if (verbosity >= 2) printf("Received %zd bytes\n", bytes_received);

    // Parse the command
    if (parse_command((const unsigned char *)recv_buffer, &cmd) != 0) {
        fprintf(stderr, "Error parsing command\n");
        close(client_socket);
        return;
    }

    // Display parsed command
    if (verbosity >= 3) {
        printf("Parsed command:\n");
        printf("  %-11s 0x%02X\n", "ddCmd:",      cmd.ddCmd);
        printf("  %-11s 0x%02X\n", "ddUnit:",     cmd.ddUnit);
        printf("  %-11s %d\n",     "ddTrack:",    cmd.ddTrack);
        printf("  %-11s %d\n",     "ddSide:",     cmd.ddSide);
        printf("  %-11s %d\n",     "ddStartSec:", cmd.ddStartSec);
        printf("  %-11s 0x%02X\n", "ddSize:",     cmd.ddSize);
        printf("  %-11s %d\n",     "ddEndSec:",   cmd.ddEndSec);
        printf("  %-11s 0x%02X\n", "ddGap:",      cmd.ddGap);
        printf("  %-11s 0x%02X\n", "ddLen:",      cmd.ddLen);
        printf("  %-11s %d\n",     "ddHead:",     cmd.ddHead);
    }

    // Get XDPB (login handshake)
    if (cmd.ddCmd == 0x07) {
        uint8_t xdpb[27];
        size_t cap = (size_t)geom.dg_cylinders * geom.dg_heads
                   * geom.dg_sectors * geom.dg_secsize;

        if (build_xdpb(&geom, cap, dir_blocks_override, xdpb) != 0) {
            fprintf(stderr, "build_xdpb failed for capacity %zu bytes\n", cap);
            goto done;   /* close without sending → Spectrum login bails */
        }

        if (verbosity >= 2) {
            printf(" Geom:");
            for (int i = 0; i < 27; i++) printf(" %02X", xdpb[i]);
            printf("\n");
        }

        /* 27 raw XDPB bytes. Loop send for ESP compatibility. */
        ssize_t sent = 0;
        while (sent < 27) {
            ssize_t n = send(client_socket, xdpb + sent, 27 - sent, 0);
            if (n < 0) { perror("send geom"); goto done; }
            sent += n;
        }
        goto done;
    }

    // Read sector from disk
    if (cmd.ddCmd == 0x05) {
        memset(sector_data, 0, sizeof(sector_data));
        if (verbosity == 1) {
            printf("\rRead:  Track %3d, Sector %2d, Head %d   ",
                   cmd.ddTrack, cmd.ddStartSec, cmd.ddHead);
            fflush(stdout);
        } else if (verbosity >= 2) {
            printf(" Read: Track %d, Sector %d, Head %d\n",
                   cmd.ddTrack, cmd.ddStartSec, cmd.ddHead);
        }

        result = dsk_pread(driver, &geom, sector_data, cmd.ddTrack, cmd.ddHead, cmd.ddStartSec);

        if (result != DSK_ERR_OK) {
            fprintf(stderr, "Error reading sector: %d\n", result);
            close(client_socket);
            return;
        }

        // Send 512 bytes of sector data back to client
        // Use a loop to ensure all bytes are sent (ESP-12 compatibility)
        while (total_sent < 512) {
            ssize_t bytes_sent = send(client_socket, sector_data + total_sent, 512 - total_sent, 0);

            if (bytes_sent < 0) {
                perror("send failed");
                goto done;
                return;
            }

            total_sent += bytes_sent;

            if (verbosity >= 3) {
                printf("Sent %zd bytes (total: %zd/512)\n", bytes_sent, total_sent);
            }
        }
    }
    else if (cmd.ddCmd == 0x06) {
        size_t have = 0;

        // The first recv() may have consumed some payload bytes past the
        // 26-byte command header; carry them forward.
        if (bytes_received > 9) {
            size_t extra = bytes_received - 9;
            if (extra > sizeof(sector_data)) extra = sizeof(sector_data);
            memcpy(sector_data, recv_buffer + 9, extra);
            have = extra;
        }

        // Pull the rest of the raw 512-byte sector payload off the socket.
        while (have < sizeof(sector_data)) {
            ssize_t n = recv(client_socket, sector_data + have,
                             sizeof(sector_data) - have, 0);
            if (n <= 0) {
                perror("recv payload");
                goto done;
            }
            have += n;
        }

        if (verbosity == 1) {
            printf("\rWrite: Track %3d, Sector %2d, Head %d   ",
                   cmd.ddTrack, cmd.ddStartSec, cmd.ddHead);
            fflush(stdout);
        } else if (verbosity >= 2) {
            printf("Write: Track %d, Sector %d, Head %d\n",
                   cmd.ddTrack, cmd.ddStartSec, cmd.ddHead);
        }

        result = dsk_pwrite(driver, &geom, sector_data,
                            cmd.ddTrack, cmd.ddHead, cmd.ddStartSec);
        if (result != DSK_ERR_OK) {
            fprintf(stderr, "dsk_pwrite failed: %d\n", result);
        }
        /* No reply payload: fall through to shutdown+close in `done:` */
    }

done:
    // Shutdown the write side to signal we're done sending
    shutdown(client_socket, SHUT_WR);
    usleep(100000); // 100ms delay for ESP before closing
    close(client_socket);
}

/**
 * Start TCP server
 */
int start_server(void) {
    int server_socket, client_socket;
    struct sockaddr_in server_addr, client_addr;
    socklen_t client_addr_len;
    int opt = 1;

    // Create socket
    server_socket = socket(AF_INET, SOCK_STREAM, 0);
    if (server_socket < 0) {
        perror("Socket creation failed");
        return -1;
    }

    // Set socket options to reuse address
    if (setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("setsockopt failed");
        close(server_socket);
        return -1;
    }

    // Configure server address
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(PORT);

    // Bind socket to port
    if (bind(server_socket, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        perror("Bind failed");
        close(server_socket);
        return -1;
    }

    // Listen for connections
    if (listen(server_socket, 5) < 0) {
        perror("Listen failed");
        close(server_socket);
        return -1;
    }

    printf("Server listening on port %d\n", PORT);

    // Accept and handle client connections
    while (1) {
        client_addr_len = sizeof(client_addr);
        client_socket = accept(server_socket, (struct sockaddr *)&client_addr, &client_addr_len);

        if (client_socket < 0) {
            perror("Accept failed");
            continue;
        }

        if (verbosity >= 2) {
            printf("\nClient connected from %s:%d\n",
                   inet_ntoa(client_addr.sin_addr),
                   ntohs(client_addr.sin_port));
        }

        handle_client(client_socket);
    }

    close(server_socket);
    return 0;
}

static const named_geom_t *lookup_geometry(const char *name) {
    for (size_t i = 0; i < NGEOMETRIES; i++) {
        if (strcasecmp(GEOMETRIES[i].name, name) == 0) {
            return &GEOMETRIES[i];
        }
    }
    return NULL;
}

/* Match a file size against the GEOMETRIES[] table. mkdsk writes small formats
 * as CPCEMU .dsk containers (256 B disk header + 256 B track info per track)
 * and large formats as raw. We accept either size per entry. Returns NULL if
 * no row matches - caller should then require -f. */
static const named_geom_t *infer_geometry(off_t file_size) {
    for (size_t i = 0; i < NGEOMETRIES; i++) {
        const DSK_GEOMETRY *g = &GEOMETRIES[i].g;
        off_t tracks = (off_t)g->dg_cylinders * g->dg_heads;
        off_t raw_size = tracks * g->dg_sectors * g->dg_secsize;
        off_t dsk_size = 256 + tracks * (256 + g->dg_sectors * g->dg_secsize);
        if (file_size == raw_size || file_size == dsk_size) {
            return &GEOMETRIES[i];
        }
    }
    return NULL;
}

static void usage(FILE *out, const char *progname) {
    fprintf(out,
        "Usage: %s [-f FORMAT] <disk_image>\n"
        "\n"
        "If -f is omitted, the format is inferred from the file size.\n"
        "\n"
        "Options:\n"
        "  -f FORMAT   Disk geometry: ", progname);
    for (size_t i = 0; i < NGEOMETRIES; i++) {
        fprintf(out, "%s%s", i ? ", " : "", GEOMETRIES[i].name);
    }
    fprintf(out, "\n  -q          Quiet: no output\n");
    fprintf(out, "  -v          Verbose: per-request log\n");
    fprintf(out, "  -vv         Debug: adds parsed-command dump and send chunks\n");
    fprintf(out, "  -h          Show this help\n");
}

/**
 * Main entry point
 */
int main(int argc, char *argv[]) {
    dsk_err_t result;
    const char *disk_image_path;
    const named_geom_t *chosen = NULL; // NULL = infer from size
    int opt;

    while ((opt = getopt(argc, argv, "f:vqh")) != -1) {
        switch (opt) {
            case 'f':
                chosen = lookup_geometry(optarg);
                if (!chosen) {
                    fprintf(stderr, "error: unknown format '%s'\n\n", optarg);
                    usage(stderr, argv[0]);
                    return 1;
                }
                break;
            case 'v': verbosity++; break;
            case 'q': verbosity = 0; break;
            case 'h': usage(stdout, argv[0]); return 0;
            default:  usage(stderr, argv[0]); return 1;
        }
    }

    /* -q: no output including perror and fatal errors. */
    if (verbosity == 0) {
        freopen("/dev/null", "w", stdout);
        freopen("/dev/null", "w", stderr);
    }

    if (optind >= argc) {
        fprintf(stderr, "error: no disk image specified\n\n");
        usage(stderr, argv[0]);
        return 1;
    }
    disk_image_path = argv[optind];

    /* If -f wasn't given, infer the format from the file size. mkdsk's raw
     * images are exactly cyl × heads × sectors × secsize bytes; its .dsk
     * images add 256-byte disk and per-track headers. We check both. */
    if (!chosen) {
        struct stat st;
        if (stat(disk_image_path, &st) != 0) {
            perror(disk_image_path);
            return 1;
        }

        chosen = infer_geometry(st.st_size);

        if (!chosen) {
            fprintf(stderr,
                "error: can't infer disk format from file size (%lld bytes); "
                "specify one with -f.\n\n", (long long)st.st_size);
            usage(stderr, argv[0]);
            return 1;
        }
    }

    dir_blocks_override = chosen->dir_blocks;

    /* Copy the chosen geometry into the live `geom` global. All subsequent
     * dsk_pread / dsk_pwrite / build_xdpb calls use this. */
    geom = chosen->g;

    // Open disk image
    result = dsk_open(&driver, disk_image_path, NULL, NULL);

    // Fallback to 'raw' type for custom disk images
    if (result != DSK_ERR_OK) {
        result = dsk_open(&driver, disk_image_path, "raw", NULL);
    }

    if (result != DSK_ERR_OK) {
        fprintf(stderr, "Failed to open disk image: %s\n", disk_image_path);
        return 1;
    }

    /* We DO NOT call dsk_getgeom here. libdsk can't infer geometry from the
     * 0xE5-filled files mkdsk produces */
    printf("Disk image opened: %s (format %s)\n", disk_image_path, chosen->name);
    printf("Geometry: %d cylinders, %d heads, %d sectors, %zu bytes/sector\n",
           geom.dg_cylinders, geom.dg_heads, geom.dg_sectors, geom.dg_secsize);

    // Start server
    start_server();

    // Cleanup
    dsk_close(&driver);

    return 0;
}
