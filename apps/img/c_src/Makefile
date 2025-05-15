CFLAGS=`pkg-config --cflags MagickWand`
LDFLAGS=`pkg-config --libs MagickWand`
OUTDIR=../priv

all:
	@echo "Compiling image manupulation plugin.."
	$(CC) $(CFLAGS) -c -O2 -Wall -g -Wall -fPIC -MMD img.c -o img.o
	$(CC) img.o $(LDFLAGS) -lpthread -lei -o $(OUTDIR)/img

clean:
	rm -f img.o img.d $(OUTDIR)/img

.PHONY: all clean
