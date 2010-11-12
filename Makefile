CFLAGS=-Wall

all: brmdoor

clean:
	rm -f brmdoor

brmdoor: brmdoor.c
	gcc $(CFLAGS) brmdoor.c -o brmdoor
