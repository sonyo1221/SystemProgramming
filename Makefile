CC = gcc
CFLAGS = -Wall -Wextra -g

TARGET = comment_editor
SRC = comment_editor.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC)

clean:
	rm -f $(TARGET)
