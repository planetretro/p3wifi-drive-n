# Makefile for dskreader project

# Compiler and flags
CC = gcc
CFLAGS = -Wall -Wextra -O2
LDFLAGS = -ldsk

# Target executable
TARGET = dskserver

# Source files
SRCS = main.c
SERVER_SRCS = server.c
OBJS = $(SRCS:.c=.o)
SERVER_OBJS = $(SERVER_SRCS:.c=.o)

# Default target
all: $(TARGET)

# Link the server executable
$(TARGET): server.o
	$(CC) server.o -o $(TARGET) $(LDFLAGS)

# Compile source files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Clean build artifacts
clean:
	rm -f server.o $(TARGET) a.out

# Install (optional - installs to /usr/local/bin)
install: $(TARGET) $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/

# Uninstall
uninstall:
	rm -f /usr/local/bin/$(TARGET)

# Phony targets
.PHONY: all clean install uninstall
