#!/bin/bash

export C_INCLUDE_PATH=/usr/include/ImageMagick-6:/usr/include/x86_64-linux-gnu/ImageMagick-6
export LIBRARY_PATH=/usr/include/ImageMagick-6

export CFLAGS=`pkg-config --cflags MagickWand`
export LDFLAGS=`pkg-config --libs MagickWand`

cc $CFLAGS -c -O2 -Wall -g -Wall -fPIC -MMD tst.c -o tst.o
cc tst.o $LDFLAGS -lpthread -lei -o tst
