CC = gcc
CFLAGS = -Wall -Wextra -O2
LDFLAGS = -ldsk
TARGET = mkdsk

all: $(TARGET)

$(TARGET): mkdsk.o
	$(CC) mkdsk.o -o $(TARGET) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f mkdsk.o $(TARGET)

.PHONY: all clean
