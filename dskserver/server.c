#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include "libdsk.h"

#define PORT 7650
#define BUFFER_SIZE 1024

static int debug = 0;

// Disk driver and geometry globals
DSK_PDRIVER driver = NULL;
DSK_GEOMETRY geom = {
    .dg_sidedness = SIDES_ALT,
    .dg_cylinders = 40,
    .dg_heads = 1,
    .dg_sectors = 10,
    .dg_secbase = 1,
    .dg_secsize = 512,
    .dg_datarate = RATE_SD,
    .dg_rwgap = 42,
    .dg_fmtgap = 82,
    .dg_fm = RECMODE_MFM,
    .dg_nomulti = 1,
    .dg_noskip = 0
};

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
 * Parse ASCII hex string into disk command structure
 * Example input: "05 09 01 00 01 02 01 2A FF"
 * Returns 0 on success, -1 on error
 */
int parse_command(const char *input, DiskCommand *cmd) {
    char *token;
    char *ptr;
    unsigned int values[9];
    int count = 0;

    // Initialize error flag
    cmd->ddError = 0;

    // Copy command out of buffer
    char cmdBuffer[29];
    cmdBuffer[26] = ' ';
    cmdBuffer[27] = ' ';
    cmdBuffer[28] = '\0';
    memcpy(cmdBuffer, input, 26);

    // Parse space-separated hex values
    token = strtok(cmdBuffer, " ");

    while (token && count < 9) {
        // Convert hex string to unsigned int
        values[count] = strtoul(token, &ptr, 16);

        // Check if conversion was successful
        if (*ptr != '\0' || (values[count] == 0 && token[0] != '0')) {
            cmd->ddError = 1;
            return -1;
        }

        // Check if value is within byte range
        if (values[count] > 0xFF) {
            cmd->ddError = 1;
            return -1;
        }

        printf("%02x ", values[count]);

        count++;

        // Next token
        token = strtok(NULL, " ");
    }

    printf("\n");

    // Check if we got exactly 9 values (or at least 9)
    if (count < 9) {
        cmd->ddError = 1;
        return -1;
    }

    // Assign values to command structure
    cmd->ddCmd = (unsigned char)values[0];
    cmd->ddUnit = (unsigned char)values[1];
    cmd->ddTrack = (unsigned char)values[2];
    cmd->ddSide = (unsigned char)values[3];
    cmd->ddStartSec = (unsigned char)values[4];
    cmd->ddSize = (unsigned char)values[5];
    cmd->ddEndSec = (unsigned char)values[6];
    cmd->ddGap = (unsigned char)values[7];
    cmd->ddLen = (unsigned char)values[8];

    // Extract head from unit byte (bit 2)
    // Always 0 for now
    cmd->ddHead = 0 ; //(cmd->ddUnit & 0x04) ? 1 : 0;

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

    // Receive command from client
    memset(recv_buffer, 0, BUFFER_SIZE);
    bytes_received = recv(client_socket, recv_buffer, BUFFER_SIZE - 1, 0);

    if (bytes_received <= 0) {
        if (bytes_received == 0) {
            printf("Client disconnected\n");
        } else {
            perror("recv failed");
        }
        close(client_socket);
        return;
    }

    recv_buffer[bytes_received] = '\0';
    printf("Received %d bytes\n", bytes_received);

    // Parse the command
    if (parse_command(recv_buffer, &cmd) != 0) {
        printf("Error parsing command\n");
        close(client_socket);
        return;
    }

    // Display parsed command
    if (debug) {
        printf("Parsed command:\n");
        printf("  ddCmd: 0x%02X\n", cmd.ddCmd);
        printf("  ddUnit: 0x%02X\n", cmd.ddUnit);
        printf("  ddTrack: %d\n", cmd.ddTrack);
        printf("  ddSide: %d\n", cmd.ddSide);
        printf("  ddStartSec: %d\n", cmd.ddStartSec);
        printf("  ddSize: 0x%02X\n", cmd.ddSize);
        printf("  ddEndSec: %d\n", cmd.ddEndSec);
        printf("  ddGap: 0x%02X\n", cmd.ddGap);
        printf("  ddLen: 0x%02X\n", cmd.ddLen);
        printf("  ddHead: %d\n", cmd.ddHead);
    }

    // Read sector from disk
    if (1 || cmd.ddCmd == 0x05) {
        memset(sector_data, 0, sizeof(sector_data));
        printf(" Read: Track %d, Sector %d, Head %d\n", cmd.ddTrack, cmd.ddStartSec, cmd.ddHead);
        result = dsk_pread(driver, &geom, sector_data, cmd.ddTrack, cmd.ddHead, cmd.ddStartSec);

        if (result != DSK_ERR_OK) {
            printf("Error reading sector: %d\n", result);
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

            if (debug) {
                printf("Sent %zd bytes (total: %zd/512)\n", bytes_sent, total_sent);
            }
        }
    }
    else if (cmd.ddCmd == 0x06) {
        printf("Write: Track %d, Sector %d, Head %d\n", cmd.ddTrack, cmd.ddStartSec, cmd.ddHead);
        send(client_socket, "OK", 2, 0);
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

        printf("\nClient connected from %s:%d\n",
               inet_ntoa(client_addr.sin_addr),
               ntohs(client_addr.sin_port));

        handle_client(client_socket);
    }

    close(server_socket);
    return 0;
}

/**
 * Main entry point
 */
int main(int argc, char *argv[]) {
    dsk_err_t result;
    const char *disk_image_path;

    // Check command line arguments
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <disk_image>\n", argv[0]);
        fprintf(stderr, "Example: %s prtwifi.dsk\n", argv[0]);
        return 1;
    }

    disk_image_path = argv[1];

    // Open disk image
    result = dsk_open(&driver, disk_image_path, NULL, NULL);

    if (result != DSK_ERR_OK) {
        fprintf(stderr, "Failed to open disk image: %s\n", disk_image_path);
        return 1;
    }

    // Get disk geometry
    result = dsk_getgeom(driver, &geom);

    if (result != DSK_ERR_OK) {
        fprintf(stderr, "Failed to get disk geometry\n");
        dsk_close(&driver);
        return 1;
    }

    printf("Disk image opened: %s\n", disk_image_path);
    printf("Geometry: %d cylinders, %d heads, %d sectors, %zu bytes/sector\n",
           geom.dg_cylinders, geom.dg_heads, geom.dg_sectors, geom.dg_secsize);

    // Start server
    start_server();

    // Cleanup (unreachable in current implementation due to infinite loop)
    dsk_close(&driver);

    return 0;
}
