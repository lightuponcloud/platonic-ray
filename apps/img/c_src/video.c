/*
* This is a video processing program, that
* - extracts video frames from input video file, making sure data is consistent
*/
#include <stdio.h>
#include <stdint.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

#define BUFFER_SIZE 1024*1024

typedef struct {
    uint8_t *buffer;
    size_t size;
    size_t position;
} BufferContext;

// Custom IO for reading from memory
int read_packet(void *opaque, uint8_t *buf, int buf_size) {
    BufferContext *ctx = (BufferContext *)opaque;
    size_t remaining = ctx->size - ctx->position;
    size_t read_size = FFMIN(buf_size, remaining);

    if (read_size <= 0)
        return AVERROR_EOF;

    memcpy(buf, ctx->buffer + ctx->position, read_size);
    ctx->position += read_size;
    return read_size;
}

int main() {
    uint8_t *buffer = av_malloc(BUFFER_SIZE);
    uint32_t size;
    AVFormatContext *fmt_ctx = NULL;
    uint8_t *avio_ctx_buffer = NULL;
    size_t avio_ctx_buffer_size = 4096;
    BufferContext buffer_ctx = {0};

    while (1) {
        // Read 4-byte size prefix
        if (fread(&size, 4, 1, stdin) != 1)
            break;

        // Read data chunk
        if (size > BUFFER_SIZE)
            exit(1);
            
        if (fread(buffer, 1, size, stdin) != size)
            break;
            
        buffer_ctx.buffer = buffer;
        buffer_ctx.size = size;
        buffer_ctx.position = 0;
        
        // Setup custom IO
        AVIOContext *avio_ctx = avio_alloc_context(
            avio_ctx_buffer,
            avio_ctx_buffer_size,
            0,
            &buffer_ctx,
            &read_packet,
            NULL,
            NULL
        );
        
        fmt_ctx = avformat_alloc_context();
        fmt_ctx->pb = avio_ctx;
        
        // Parse container
        if (avformat_open_input(&fmt_ctx, NULL, NULL, NULL) < 0)
            exit(1);
            
        // Find complete frames
        AVPacket packet;
        while (av_read_frame(fmt_ctx, &packet) >= 0) {
            // Write frame size and data
            uint32_t frame_size = packet.size;
            fwrite(&frame_size, 4, 1, stdout);
            fwrite(packet.data, 1, packet.size, stdout);
            av_packet_unref(&packet);
        }
        
        // Write remaining buffer
        uint32_t remain_size = size - buffer_ctx.position;
        if (remain_size > 0) {
            fwrite(&remain_size, 4, 1, stdout);
            fwrite(buffer + buffer_ctx.position, 1, remain_size, stdout);
        }
        
        avformat_close_input(&fmt_ctx);
        avio_context_free(&avio_ctx);
    }
    
    av_free(buffer);
    return 0;
}
