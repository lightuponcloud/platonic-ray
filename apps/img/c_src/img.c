/*
 * This is image processing program, that
 * - creates thumbnails
 * - applies watermarks
 *
 */
#include <ei.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>
#include <wand/MagickWand.h>

/* Maximum resolution is 25Mpx */

#define HEADER_SIZE 4
#define HEADER_BYTES_COUNT 4
#define BUF_SIZE 26214400 // 25 MB is big enough for most of JPEGs
#define MAX_COLOR_NAME 64
#define OK 0
#define PONG 1
#define ERROR 2
#define INTERNAL_ERROR -1 // Internal failure during encoding

#undef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#undef ROUND
#define ROUND(f) ((f >= 0) ? (int)(f + .5) : (int)(f - .5))

/* Encode/decode session info. */

/*
* mask_background_color_size can be the following
*
* "transparent"     // Fully transparent
* "none"           // Same as transparent

* "rgba(255,0,0,0)"     // Fully transparent red
* "rgba(255,0,0,0.5)"   // 50% transparent red
* "rgba(0,0,0,0.25)"    // 25% transparent black

* "#FF000000"      // Fully transparent red (RRGGBBAA format)
* "#FF000080"      // 50% transparent red

* "hsla(0,100%,50%,0.5)"  // 50% transparent red in HSL
*/
typedef struct transform
{
    unsigned char *from;
    size_t from_size;
    char to[5];
    unsigned char *watermark;
    size_t watermark_size;
    unsigned char *mask;
    size_t mask_size;
    char mask_background_color[MAX_COLOR_NAME];
    size_t mask_background_color_size;
    unsigned long scale_width;
    unsigned long scale_height;
    unsigned char *tag; // PID
    int crop;           // Crop image
    int just_get_size;  // Just return width and height of provided image
    int just_ping;      // Just return ping response
    size_t tag_size;
} transform_se;

// Mask analysis results
typedef struct {
    int invert_mask;
    double black_percentage;
    double white_percentage;
    size_t total_pixels;
    size_t black_pixels;
    size_t white_pixels;
} MaskAnalysis;

// Color validation structure
typedef struct {
    unsigned char r, g, b, a;
    int is_valid;
    int is_transparent;
} RGBAColor;

void debug(const char* format, ...)
{
    char filename[256];
    pid_t pid = getpid();  // Get the current process ID

    snprintf(filename, sizeof(filename), "/tmp/output/%d.txt", pid);

    FILE* file = fopen(filename, "a");  // Open file in append mode
    if (file == NULL) {
        return;
    }

    va_list args;
    va_start(args, format);

    if (strchr(format, '%') == NULL) {
        // No format specifiers, treat as plain string
        fputs(format, file);
    } else {
        // Format specifiers present, format accordingly
        vfprintf(file, format, args);
    }

    va_end(args);

    // Add newline for readability
    fputc('\n', file);
    fclose(file);
}

void print_transform_attributes(const transform_se *t)
{
    if (t == NULL) {
        debug("Transform structure is NULL");
        return;
    }

    debug("Transform Structure Attributes:");
    debug("================================");

    // Print pointer addresses and sizes for binary data
    debug("from:                    %p", (void*)t->from);
    debug("from_size:               %zu bytes", t->from_size);

    // Print 'to' field (null-terminated string)
    debug("to:                      \"%.4s\"", t->to);

    debug("watermark:               %p", (void*)t->watermark);
    debug("watermark_size:          %zu bytes", t->watermark_size);

    debug("mask:                    %p", (void*)t->mask);
    debug("mask_size:               %zu bytes", t->mask_size);

    // Print mask background color (assuming it's a string)
    debug("mask_background_color:   \"%.63s\"", t->mask_background_color);
    debug("mask_background_color_size: %zu", t->mask_background_color_size);

    debug("scale_width:             %lu", t->scale_width);
    debug("scale_height:            %lu", t->scale_height);

    debug("tag:                     %p", (void*)t->tag);
    debug("tag_size:                %zu bytes", t->tag_size);

    debug("crop:                    %s", t->crop ? "true" : "false");
    debug("just_get_size:           %s", t->just_get_size ? "true" : "false");
    debug("just_ping:               %s", t->just_ping ? "true" : "false");
}

static ssize_t write_exact(unsigned char *buf, ssize_t len)
{
    ssize_t i, wrote = 0;
    do
    {
        if ((i = write(STDOUT_FILENO, buf + wrote, (size_t)len - wrote)) <= 0)
            return i;
        wrote += i;
    } while (wrote < len);
    return len;
}

static ssize_t write_cmd(ei_x_buff *buff)
{
    unsigned char li;

    li = (buff->index >> 24) & 0xff;
    (void)write_exact(&li, 1);
    li = (buff->index >> 16) & 0xff;
    (void)write_exact(&li, 1);
    li = (buff->index >> 8) & 0xff;
    (void)write_exact(&li, 1);
    li = buff->index & 0xff;
    (void)write_exact(&li, 1);

    return write_exact((unsigned char *)buff->buff, buff->index);
}


static int encode_error(transform_se *se, ei_x_buff *result, char *atom_name)
{
    char error_key[6] = "error\0";
    if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2) ||
        ei_x_encode_binary(result, se->tag, se->tag_size) || ei_x_encode_tuple_header(result, 2) ||
        ei_x_encode_atom(result, error_key) || ei_x_encode_atom(result, atom_name))
        return INTERNAL_ERROR;
    return ERROR;
}

static int encode_ping_response(transform_se *se, ei_x_buff *result, char *atom_name)
{
    char ping_key[6] = "ping\0";
    if (!se->tag || se->tag_size == 0)
    {
        return encode_error(se, result, "missing_tag_error");
    }
    if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2) ||
        ei_x_encode_binary(result, se->tag, se->tag_size) || ei_x_encode_tuple_header(result, 2) ||
        ei_x_encode_atom(result, ping_key) || ei_x_encode_atom(result, atom_name))
        return INTERNAL_ERROR;
    return PONG;
}

// Helper function to initialize ImageMagick wand
static MagickWand *init_magick_wand(transform_se *se, ei_x_buff *result, int *encode_stat)
{
    MagickWand *magick_wand;

    MagickWandGenesis();
    magick_wand = NewMagickWand();

    if (MagickReadImageBlob(magick_wand, se->from, se->from_size) == MagickFalse)
    {
        *encode_stat = encode_error(se, result, "blob_src_imagemagick_error");
        (void)DestroyMagickWand(magick_wand);
        return NULL;
    }
    *encode_stat = OK;
    return magick_wand;
}

// Function to handle size-only requests
static int handle_get_size_only(transform_se *se, MagickWand *magick_wand, ei_x_buff *result)
{
    if (!magick_wand) {
        return encode_error(se, result, "get_size_null_wand_error");
    }
    size_t width = MagickGetImageWidth(magick_wand);
    size_t height = MagickGetImageHeight(magick_wand);

    if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2) ||
        ei_x_encode_binary(result, se->tag, se->tag_size) || ei_x_encode_tuple_header(result, 2) ||
        ei_x_encode_ulong(result, width) || ei_x_encode_ulong(result, height))
    {
        return encode_error(se, result, "size_encoding_error");
    }
    return 0;
}

// Function to calculate watermark dimensions
static void calculate_watermark_dimensions(size_t width, size_t height, size_t wm_width, size_t wm_height,
                                           size_t *new_wm_width, size_t *new_wm_height)
{
    size_t wm_scale_width = (width / 5) * 2;
    size_t wm_scale_height = (height / 5) * 2;
    size_t wm_src_ratio = wm_width / wm_height;
    size_t wm_cal_ratio = wm_scale_width / wm_scale_height;

    if (wm_cal_ratio > wm_src_ratio)
    {
        *new_wm_width = wm_scale_width;
        *new_wm_height = wm_scale_width * wm_height / wm_width;
    }
    else if (wm_cal_ratio < wm_src_ratio)
    {
        *new_wm_width = wm_scale_height * wm_width / wm_height;
        *new_wm_height = wm_scale_height;
    }
    else
    {
        *new_wm_width = wm_scale_width;
        *new_wm_height = wm_scale_height;
    }
}

/*
 * Validate color specification and convert to RGB if possible
 * Supports hex codes (#RRGGBB, #RGB) and common color names
 */
/*
 * Enhanced color validation with transparency support
 * Supports:
 * - Named colors: "red", "blue", "transparent", etc.
 * - Hex codes: "#FF0000", "#F00", "#FF000080" (with alpha)
 * - RGB: "rgb(255,0,0)"
 * - RGBA: "rgba(255,0,0,0.5)"
 * - HSL: "hsl(0,100%,50%)"
 * - Special: "transparent", "none"
 */
int validate_color_with_alpha(const char* color_spec, RGBAColor* rgba_out) {
    if (!color_spec || !rgba_out) return 0;

    rgba_out->is_valid = 0;
    rgba_out->is_transparent = 0;

    // Initialize MagickWand for color validation
    MagickWandGenesis();
    PixelWand* pixel_wand = NewPixelWand();

    if (PixelSetColor(pixel_wand, color_spec) == MagickTrue) {
        rgba_out->r = (unsigned char)(PixelGetRed(pixel_wand) * 255);
        rgba_out->g = (unsigned char)(PixelGetGreen(pixel_wand) * 255);
        rgba_out->b = (unsigned char)(PixelGetBlue(pixel_wand) * 255);
        rgba_out->a = (unsigned char)(PixelGetAlpha(pixel_wand) * 255);
        rgba_out->is_valid = 1;

        // Check if color is transparent
        if (PixelGetAlpha(pixel_wand) < 0.01 || 
            strcmp(color_spec, "transparent") == 0 || 
            strcmp(color_spec, "none") == 0) {
            rgba_out->is_transparent = 1;
        }
    }

    DestroyPixelWand(pixel_wand);
    return rgba_out->is_valid;
}

/*
 * Analyze mask to determine dominant color using efficient histogram method
 * This is the core intelligence feature from the Python script
 */
MaskAnalysis analyze_mask_dominant_color(MagickWand* mask_wand) {
    MaskAnalysis analysis = {0};

    // Clone mask for analysis to avoid modifying original
    MagickWand* analysis_wand = CloneMagickWand(mask_wand);
    if (!analysis_wand) return analysis;

    // Convert to grayscale for consistent analysis
    MagickSetImageType(analysis_wand, GrayscaleType);

    // Remove alpha channel if present
    if (MagickGetImageAlphaChannel(analysis_wand) == MagickTrue) {
        MagickSetImageAlphaChannel(analysis_wand, RemoveAlphaChannel);
    }

    // Get image dimensions
    size_t width = MagickGetImageWidth(analysis_wand);
    size_t height = MagickGetImageHeight(analysis_wand);
    analysis.total_pixels = width * height;

    // Use pixel iterator for efficient histogram-like analysis
    PixelIterator* iterator = NewPixelIterator(analysis_wand);
    if (!iterator) {
        DestroyMagickWand(analysis_wand);
        return analysis;
    }

    size_t row_count = 0;
    PixelWand** pixels;

    // Iterate through all pixels
    while ((pixels = PixelGetNextIteratorRow(iterator, &row_count)) != NULL) {
        for (size_t i = 0; i < row_count; i++) {
            double intensity = PixelGetRed(pixels[i]); // Grayscale, so R=G=B

            if (intensity < 0.5) { // Black-ish pixel (threshold at 50%)
                analysis.black_pixels++;
            } else { // White-ish pixel
                analysis.white_pixels++;
            }
        }
    }

    DestroyPixelIterator(iterator);
    DestroyMagickWand(analysis_wand);

    // Calculate percentages
    if (analysis.total_pixels > 0) {
        analysis.black_percentage = (double)analysis.black_pixels / analysis.total_pixels * 100.0;
        analysis.white_percentage = (double)analysis.white_pixels / analysis.total_pixels * 100.0;
    }

    // Determine if mask should be inverted
    // The dominant color should be transparent (show original image)
    analysis.invert_mask = (analysis.black_pixels > analysis.white_pixels) ? 1 : 0;

    return analysis;
}


/*
 * Normalize mask values to ensure consistent intensity
 * This addresses varying mask types and improves processing reliability
 */
int normalize_mask(MagickWand* mask_wand) {
    if (!mask_wand) return 0;

    // Convert to grayscale first
    if (MagickSetImageType(mask_wand, GrayscaleType) == MagickFalse) {
        return 0;
    }

    // Normalize the image to full range (0-255)
    if (MagickNormalizeImage(mask_wand) == MagickFalse) {
        return 0;
    }

    // Enhance contrast to ensure clear black/white separation
    if (MagickContrastImage(mask_wand, MagickTrue) == MagickFalse) {
        return 0;
    }
    return 1;
}


/*
 * Create a pixel wand with proper transparency support
 */
PixelWand* create_background_pixel(const char* color_spec) {
    PixelWand* pixel_wand = NewPixelWand();
    if (!pixel_wand) return NULL;

    // Handle special transparent cases
    if (strcmp(color_spec, "transparent") == 0 || strcmp(color_spec, "none") == 0) {
        PixelSetColor(pixel_wand, "transparent");
        return pixel_wand;
    }

    // Try to set the color
    if (PixelSetColor(pixel_wand, color_spec) == MagickFalse) {
        // If color setting fails, use default transparent
        PixelSetColor(pixel_wand, "transparent");
    }

    return pixel_wand;
}

/*
 * Main layer mask application function with intelligent processing
 */
int apply_layer_mask(transform_se *se, MagickWand *magick_wand, ei_x_buff *result)
{
    if (!magick_wand) {
        return encode_error(se, result, "apply_layer_mask_null_wand_error");
    }
    MagickWand* mask_wand = NULL;
    MagickWand* result_wand = NULL;
    MagickWand* color_wand = NULL;
    MagickWand* mask_copy = NULL;
    int encode_stat = 0;

    // Get input image dimensions directly from the passed magick_wand
    size_t input_width = MagickGetImageWidth(magick_wand);
    size_t input_height = MagickGetImageHeight(magick_wand);

    // Load mask image
    mask_wand = NewMagickWand();
    if (!mask_wand) {
        encode_stat = encode_error(se, result, "mask_wand_create_error");
        goto cleanup;
    }

    if (MagickReadImageBlob(mask_wand, se->mask, se->mask_size) == MagickFalse) {
        encode_stat = encode_error(se, result, "mask_imagemagick_error");
        goto cleanup;
    }

    size_t mask_width = MagickGetImageWidth(mask_wand);
    size_t mask_height = MagickGetImageHeight(mask_wand);

    // Resize mask to match input dimensions if necessary
    if (mask_width != input_width || mask_height != input_height) {
        if (MagickResizeImage(mask_wand, input_width, input_height, TriangleFilter, 1.0) == MagickFalse) {
            encode_stat = encode_error(se, result, "resize_imagemagick_error");
            goto cleanup;
        }
    }

    // Normalize mask for consistent processing
    normalize_mask(mask_wand);

    // Analyze mask to determine processing approach
    MaskAnalysis analysis = analyze_mask_dominant_color(mask_wand);

    // Create result image by cloning the input magick_wand
    result_wand = CloneMagickWand(magick_wand);
    if (!result_wand) {
        encode_stat = encode_error(se, result, "clone_imagemagick_error");
        goto cleanup;
    }

    // Create solid color layer
    color_wand = NewMagickWand();
    if (!color_wand) {
        encode_stat = encode_error(se, result, "color_wand_create_error");
        goto cleanup;
    }

    PixelWand* bg_pixel = create_background_pixel(se->mask_background_color);
    if (!bg_pixel) {
        encode_stat = encode_error(se, result, "pixel_wand_create_error");
        goto cleanup;
    }

    if (MagickNewImage(color_wand, input_width, input_height, bg_pixel) == MagickFalse) {
        encode_stat = encode_error(se, result, "color_imagemagick_error");
        DestroyPixelWand(bg_pixel);
        goto cleanup;
    }
    if (MagickSetImageAlphaChannel(color_wand, ActivateAlphaChannel) == MagickFalse) {
        encode_stat = encode_error(se, result, "alpha_channel_error");
        DestroyPixelWand(bg_pixel);
        goto cleanup;
    }
    DestroyPixelWand(bg_pixel);

    // Prepare mask for compositing
    mask_copy = CloneMagickWand(mask_wand);
    if (!mask_copy) {
        encode_stat = encode_error(se, result, "clone_mask_imagemagick_error");
        goto cleanup;
    }

    if (analysis.invert_mask) {
        // More black pixels detected, we want black areas to show original
        // So we DON'T invert - black stays black (transparent), white becomes opaque
        // Do nothing - keep mask as is
    } else {
        // More white pixels detected, we want white areas to show original  
        // So we DO invert - white becomes black (transparent), black becomes white (opaque)
        if (MagickNegateImage(mask_copy, MagickFalse) == MagickFalse) {
            encode_stat = encode_error(se, result, "invert_mask_imagemagick_error");
            goto cleanup;
        }
    }

    // Use mask as alpha channel for color layer
    if (MagickCompositeImageChannel(color_wand, AlphaChannel, mask_copy,
                                    CopyOpacityCompositeOp, 0, 0) == MagickFalse) {
        encode_stat = encode_error(se, result, "apply_mask_imagemagick_error");
        goto cleanup;
    }

    // Composite color layer over original image
    if (MagickCompositeImage(result_wand, color_wand, OverCompositeOp, 0, 0) == MagickFalse) {
        encode_stat = encode_error(se, result, "compose_imagemagick_error");
        goto cleanup;
    }

    // Clear the original wand
    ClearMagickWand(magick_wand);

    // Get the processed image as blob
    size_t blob_length;
    unsigned char* blob = MagickGetImageBlob(result_wand, &blob_length);
    if (blob == NULL) {
        encode_stat = encode_error(se, result, "get_blob_imagemagick_error");
        goto cleanup;
    }

    // Load the blob back into the original magick_wand
    if (MagickReadImageBlob(magick_wand, blob, blob_length) == MagickFalse) {
        encode_stat = encode_error(se, result, "load_result_imagemagick_error");
        MagickRelinquishMemory(blob);
        goto cleanup;
    }

    MagickRelinquishMemory(blob);

cleanup:
    // Clean up all MagickWand resources
    if (mask_wand) DestroyMagickWand(mask_wand);
    if (result_wand) DestroyMagickWand(result_wand);
    if (color_wand) DestroyMagickWand(color_wand);
    if (mask_copy) DestroyMagickWand(mask_copy);

    return encode_stat;
}


// Function to apply watermark
static int apply_watermark(transform_se *se, MagickWand *magick_wand, ei_x_buff *result)
{
    if (!magick_wand) {
        return encode_error(se, result, "apply_watermark_null_wand_error");
    }
    int encode_stat = 0;
    MagickWand *magick_wand_watermark = NewMagickWand();

    // Load watermark image
    if (MagickReadImageBlob(magick_wand_watermark, se->watermark, se->watermark_size) == MagickFalse)
    {
        encode_stat = encode_error(se, result, "watermark_blob_imagemagick_error");
	goto cleanup;
    }

    // Set watermark transparency
    if (MagickEvaluateImageChannel(magick_wand_watermark, AlphaChannel, MultiplyEvaluateOperator, 0.4) == MagickFalse)
    {
        encode_stat = encode_error(se, result, "alpha_imagemagick_error");
	goto cleanup;
    }

    // Get dimensions
    size_t width = MagickGetImageWidth(magick_wand);
    size_t height = MagickGetImageHeight(magick_wand);
    size_t wm_width = MagickGetImageWidth(magick_wand_watermark);
    size_t wm_height = MagickGetImageHeight(magick_wand_watermark);

    // Calculate new watermark dimensions
    size_t new_wm_width, new_wm_height;
    calculate_watermark_dimensions(width, height, wm_width, wm_height, &new_wm_width, &new_wm_height);

    // Resize watermark
    if (MagickResizeImage(magick_wand_watermark, new_wm_width, new_wm_height, TriangleFilter, 1.0) == MagickFalse)
    {
        encode_stat = encode_error(se, result, "imagemagick_resize_error");
	goto cleanup;
    }

    // Composite watermark onto main image
    if (MagickCompositeImage(magick_wand, magick_wand_watermark, DissolveCompositeOp, width / 5, height / 5) == MagickFalse)
    {
        encode_stat = encode_error(se, result, "composite_imagemagick_error");
	goto cleanup;
    }

cleanup:
    if(magick_wand_watermark) (void)DestroyMagickWand(magick_wand_watermark);

    return encode_stat;
}

// Function to set image format and compression
static int set_image_format(transform_se *se, MagickWand *magick_wand, ei_x_buff *result)
{
    if (strcmp(se->to, "webp") == 0)
    {
        if (MagickSetImageFormat(magick_wand, "WEBP") == MagickFalse)
        {
            return encode_error(se, result, "webp_format_imagemagick_error");
        }
        if (MagickSetImageCompressionQuality(magick_wand, 85) == MagickFalse)
        {
            return encode_error(se, result, "imagemagick_webp_compress_error");
        }
    }
    else if (strcmp(se->to, "jpeg") == 0)
    {
        if (MagickSetImageFormat(magick_wand, "JPEG") == MagickFalse)
        {
            return encode_error(se, result, "jpeg_format_imagemagick_error");
        }
        if (MagickSetImageCompressionQuality(magick_wand, 95) == MagickFalse)
        {
            return encode_error(se, result, "imagemagick_jpeg_compress_error");
        }
    }
    else if (strcmp(se->to, "png") == 0)
    {
        if (MagickSetImageFormat(magick_wand, "PNG") == MagickFalse)
        {
            return encode_error(se, result, "png_format_imagemagick_error");
        }
    }
    return 0;
}

// Function to handle image scaling and cropping
static int scale_and_crop_image(transform_se *se, MagickWand *magick_wand, ei_x_buff *result)
{
    if (!magick_wand) {
        return encode_error(se, result, "scale_and_crop_image_null_wand_error");
    }
    size_t width = MagickGetImageWidth(magick_wand);
    size_t height = MagickGetImageHeight(magick_wand);

    // Set format first
    int format_result = set_image_format(se, magick_wand, result);
    if (format_result != 0)
    {
        return format_result;
    }

    double src_ratio = (double)width / (double)height;
    double cal_ratio = (double)se->scale_width / (double)se->scale_height;

    if (cal_ratio > src_ratio)
    {
        if (MagickResizeImage(magick_wand, se->scale_width, (se->scale_width * height / width), TriangleFilter, 1.0) == MagickFalse)
        {
            return encode_error(se, result, "imagemagick_resize_error");
        }

        if (se->crop == 1)
        {
            width = MagickGetImageWidth(magick_wand);
            height = MagickGetImageHeight(magick_wand);

            size_t new_height = ((height + se->scale_height) / 2) - ((height - se->scale_height) / 2);

            if (MagickCropImage(magick_wand, width, new_height, 0, (height - se->scale_height) / 2) == MagickFalse)
            {
                return encode_error(se, result, "imagemagick_crop_error");
            }
        }
    }
    else if (cal_ratio < src_ratio)
    {
        if (MagickResizeImage(magick_wand, se->scale_height * width / height, se->scale_height, TriangleFilter, 1.0) == MagickFalse)
        {
            return encode_error(se, result, "imagemagick_resize_error");
        }

        if (se->crop == 1)
        {
            width = MagickGetImageWidth(magick_wand);
            height = MagickGetImageHeight(magick_wand);

            size_t new_width = ((width + se->scale_width) / 2) - ((width - se->scale_width) / 2);
            if (MagickCropImage(magick_wand, new_width, height, (width - se->scale_width) / 2, 0) == MagickFalse)
            {
                return encode_error(se, result, "imagemagick_crop_error");
            }
        }
    }
    else
    {
        if (MagickResizeImage(magick_wand, se->scale_width, se->scale_height, TriangleFilter, 1.0) == MagickFalse)
        {
            return encode_error(se, result, "imagemagick_resize_error");
        }
    }

    // Set final compression quality
    if (MagickSetImageCompressionQuality(magick_wand, 95) == MagickFalse)
    {
        return encode_error(se, result, "imagemagick_compress_error");
    }

    return OK;
}

// Function to encode final result
static int encode_final_result(transform_se *se, MagickWand *magick_wand, ei_x_buff *result)
{
    size_t output_len = 0;
    unsigned char *output = MagickGetImageBlob(magick_wand, &output_len);

    int encode_stat = 0;
    if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2) ||
        ei_x_encode_binary(result, se->tag, se->tag_size) || ei_x_encode_binary(result, output, output_len))
    {
        encode_stat = encode_error(se, result, "binary_encoding_error");
    }

    free(output);
    return encode_stat;
}

// Function to cleanup resources
static void cleanup_resources(transform_se *se, MagickWand *magick_wand)
{
    if (magick_wand)
    {
        (void)DestroyMagickWand(magick_wand);
        MagickWandTerminus();
    }

    if (se->watermark_size > 0 && se->watermark)
    {
        free(se->watermark);
    }
    if (se->mask_size > 0 && se->mask)
    {
        free(se->mask);
    }
    if (se->from)
    {
        free(se->from);
    }
    if (se->tag)
    {
        free(se->tag);
    }
}


/*
    Main processing function
    ``se`` -- source data
    ``result`` -- should contain status
*/
int process_image(transform_se *se, ei_x_buff *result)
{
    int encode_stat = 0;
    MagickWand *magick_wand = NULL;

    if (se->just_ping == 1)
    {
        encode_stat = encode_ping_response(se, result, "ping");
        goto cleanup;
    }

    // Initialize ImageMagick wand
    magick_wand = init_magick_wand(se, result, &encode_stat);
    if (!magick_wand)
    {
        goto cleanup;
    }

    if (se->just_get_size == 1)
    {
        encode_stat = handle_get_size_only(se, magick_wand, result);
        goto cleanup;
    }

    print_transform_attributes(se);
    // Early validation
    if (se->from_size == 0)
    {
        encode_stat = encode_error(se, result, "no_src_img_error");
        goto cleanup;
    }

    // Apply watermark if needed
    if (se->watermark_size > 0)
    {
        encode_stat = apply_watermark(se, magick_wand, result);
        if (encode_stat != 0)
        {
            goto cleanup;
        }
        // Continue to encode the watermarked image
    }

    // Apply mask if needed
    if (se->mask_size > 0)
    {
        encode_stat = apply_layer_mask(se, magick_wand, result);
        if (encode_stat != 0)
        {
            goto cleanup;
        }
        // Continue to encode the masked image
    }

    // Handle scaling and cropping
    if (se->scale_width > 0 && se->scale_height > 0)
    {
        encode_stat = scale_and_crop_image(se, magick_wand, result);
        if (encode_stat != 0)
        {
            goto cleanup;
        }
    }

    // Encode final result
    encode_stat = encode_final_result(se, magick_wand, result);

cleanup:
    cleanup_resources(se, magick_wand);
    return encode_stat;
}

/*
    parse_transform -- parses encoded erlang term
    Example of expected Erlang term
    [
        {from, Data},        % image data
        {to, jpeg},          % output format
        {watermark, W},      % optional image data
        {mask, M},           % optional image data
        {scale_width, 1024}, % optional width to resize to
        {scale_height, 768}  % and height
    ]

    ``buf``    -- raw data
    ``offset`` -- offset of list element to start parsing from
    ``arity``  -- the number of elements in list
    ``se``     -- structure to fill result to
    ``result`` -- should contain status
*/
int parse_transform(unsigned char *buf, int offset, int arity, transform_se *se, ei_x_buff result)
{
    int tmp_arity = 0;
    int encode_stat = 0;
    int type = 0;
    char last_atom[MAXATOMLEN] = "";

    se->from_size = 0;
    se->watermark_size = 0;
    se->mask_size = 0;
    se->tag_size = 0;
    se->scale_width = 0;
    se->scale_height = 0;
    se->crop = 1;
    se->just_get_size = 0;
    se->just_ping = 0;

    int i;
    for (i = 0; i < arity; i++)
    {
        (void)ei_get_type((char *)buf, &offset, &type, (int *)&tmp_arity);
        if (ERL_SMALL_TUPLE_EXT != type)
        {
            encode_stat = encode_error(se, &result, "unexpected_arg");
            break;
        }
        if (OK != ei_decode_tuple_header((const char *)buf, &offset, &tmp_arity))
        {
            encode_stat = encode_error(se, &result, "tuple_decode_error");
            break;
        }
        if (tmp_arity != 2)
        {
            encode_stat = encode_error(se, &result, "tuple_value_decode_error");
            break;
        }
        if (ei_decode_atom((const char *)buf, &offset, last_atom))
        {
            encode_stat = encode_error(se, &result, "atom_decode_error");
            break;
        }
        if (strncmp("from", last_atom, strlen(last_atom)) == 0)
        {
            int ei_size;
            long size_long;
            (void)ei_get_type((char *)buf, &offset, &type, &ei_size);
            size_long = (long)ei_size;
            se->from_size = (size_t)size_long;

            if (ERL_BINARY_EXT != type)
            {
                encode_stat = encode_error(se, &result, "binary_decode_error");
                break;
            }
            se->from = malloc(se->from_size);
            if (NULL == se->from)
                return INTERNAL_ERROR;
            memset(se->from, 0, se->from_size);
            if (OK != ei_decode_binary((const char *)buf, &offset, se->from, &size_long))
            {
                encode_stat = encode_error(se, &result, "binary_decode_error");
                break;
            }
        }
        else if (strncmp("to", last_atom, strlen(last_atom)) == 0)
        {
            if (ei_decode_atom((const char *)buf, &offset, last_atom))
            {
                encode_stat = encode_error(se, &result, "atom_decode_error");
                break;
            }
            if (strlen(last_atom) > 4 && strcmp(last_atom, "webp") != 0 && strcmp(last_atom, "jpeg") != 0 &&
                strcmp(last_atom, "png") != 0)
            {
                encode_stat = encode_error(se, &result, "unknown_dst_format");
                break;
            }
            strncpy(se->to, last_atom, sizeof(se->to) - 1);
            se->to[sizeof(se->to) - 1] = '\0';
        }
        else if (strncmp("watermark", last_atom, strlen(last_atom)) == 0)
        {
            int ei_size;
            long size_long;
            (void)ei_get_type((char *)buf, &offset, &type, &ei_size);
            size_long = (long)ei_size;
            se->watermark_size = (size_t)size_long;

            if (ERL_BINARY_EXT != type)
            {
                encode_stat = encode_error(se, &result, "watermark_binary_decode_error");
                break;
            }
            se->watermark = malloc(se->watermark_size);
            if (NULL == se->watermark)
                return INTERNAL_ERROR;
            memset(se->watermark, 0, se->watermark_size);
            if (OK != ei_decode_binary((const char *)buf, &offset, se->watermark, &size_long))
            {
                encode_stat = encode_error(se, &result, "watermark_binary_decode_error");
                break;
            }
        }
        else if (strncmp("mask", last_atom, strlen(last_atom)) == 0)
        {
            int ei_size;
            long size_long;
            (void)ei_get_type((char *)buf, &offset, &type, &ei_size);
            size_long = (long)ei_size;
            se->mask_size = (size_t)size_long;

            if (ERL_BINARY_EXT != type)
            {
                encode_stat = encode_error(se, &result, "mask_binary_decode_error");
                break;
            }
            se->mask = malloc(se->mask_size);
            if (NULL == se->mask)
                return INTERNAL_ERROR;
            memset(se->mask, 0, se->mask_size);
            if (OK != ei_decode_binary((const char *)buf, &offset, se->mask, &size_long))
            {
                encode_stat = encode_error(se, &result, "mask_binary_decode_error");
                break;
            }
        }
        else if (strncmp("mask_background_color", last_atom, strlen(last_atom)) == 0)
        {
            int ei_size;
            long size_long;
            (void)ei_get_type((char *)buf, &offset, &type, &ei_size);
            size_long = (long)ei_size;

            if (ERL_STRING_EXT != type)
            {
                encode_stat = encode_error(se, &result, "mask_color_string_decode_error");
                break;
            }

            // Check if string fits in fixed buffer
            if (size_long >= MAX_COLOR_NAME) {
                encode_stat = encode_error(se, &result, "mask_color_too_long_error");
                break;
            }

            // Decode directly into the fixed buffer (no malloc needed)
            if (OK != ei_decode_string((const char *)buf, &offset, se->mask_background_color))
            {
                encode_stat = encode_error(se, &result, "mask_color_decode_error");
                break;
            }

            // Store the actual size
            se->mask_background_color_size = strlen(se->mask_background_color);

            // Validate the color
            RGBAColor rgb;
            if (!validate_color_with_alpha(se->mask_background_color, &rgb)) {
                // Use default color if validation fails
                strncpy(se->mask_background_color, "white", MAX_COLOR_NAME - 1);
                se->mask_background_color[MAX_COLOR_NAME - 1] = '\0';
                se->mask_background_color_size = strlen(se->mask_background_color);
            }
        }
        else if (strncmp("scale_width", last_atom, strlen(last_atom)) == 0)
        {
            (void)ei_decode_ulong((const char *)buf, &offset, &(se->scale_width));
        }
        else if (strncmp("scale_height", last_atom, strlen(last_atom)) == 0)
        {
            (void)ei_decode_ulong((const char *)buf, &offset, &(se->scale_height));
        }
        else if (strncmp("crop", last_atom, strlen(last_atom)) == 0)
        {
            (void)ei_decode_boolean((const char *)buf, &offset, &(se->crop));
        }
        else if (strncmp("just_get_size", last_atom, strlen(last_atom)) == 0)
        {
            (void)ei_decode_boolean((const char *)buf, &offset, &(se->just_get_size));
        }
        else if (strncmp("ping", last_atom, strlen(last_atom)) == 0)
        {
            if (ei_decode_atom((const char *)buf, &offset, last_atom))
            {
                encode_stat = encode_error(se, &result, "atom_decode_error");
                break;
            }
            se->just_ping = 1;
        }
        else if (strncmp("tag", last_atom, strlen(last_atom)) == 0)
        {
            int ei_size;
            long tag_len;
            (void)ei_get_type((char *)buf, &offset, &type, &ei_size);
            tag_len = (long)ei_size;
            se->tag_size = (size_t)tag_len;

            if (ERL_BINARY_EXT != type)
            {
                encode_stat = encode_error(se, &result, "tag_binary_decode_error");
                break;
            }
            se->tag = malloc(se->tag_size);
            if (NULL == se->tag)
                return INTERNAL_ERROR;
            memset(se->tag, 0, se->tag_size);
            if (OK != ei_decode_binary((const char *)buf, &offset, se->tag, &tag_len))
            {
                encode_stat = encode_error(se, &result, "tag_binary_decode_error");
                break;
            }
        };
    } // forloop

    return encode_stat;
}

static void int_handler(int dummy)
{
    /* async safe ? */
    (void)close(STDIN_FILENO);
    (void)close(STDOUT_FILENO);
}

static ssize_t read_exact(unsigned char *buf, ssize_t len)
{
    ssize_t i, got = 0;
    do
    {
        if ((i = read(STDIN_FILENO, buf + got, len - got)) <= 0)
        {
            return i;
        }
        got += i;
    } while (got < len);
    return len;
}

static ssize_t read_cmd(unsigned char *buf, ssize_t size)
{
    ssize_t len;
    if (read_exact(buf, 4) != 4)
        return (-1);

    len = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];

    if (len > size)
    {
        unsigned char *tmp = (unsigned char *)realloc(buf, len);
        if (tmp == NULL)
            return INTERNAL_ERROR;
        else
            buf = tmp;
    }
    return read_exact(buf, len);
}

int main(void)
{
    (void)signal(SIGINT, int_handler);

    int encode_stat = 0;
    int result_stat = 1;
    int version = 0;
    int offset = 0;
    int arity = 0;

    ei_x_buff result;
    result.buffsz = MAXATOMLEN + 10;
    result.buff = malloc(result.buffsz);
    result.index = 0;
    if (NULL == result.buff)
    {
        fprintf(stderr, "Memory allocation error.\n");
        return INTERNAL_ERROR;
    }
    memset(result.buff, 0, result.buffsz);

    unsigned char *buf;
    buf = (unsigned char *)malloc(sizeof(char) * BUF_SIZE);
    if (NULL == buf)
    {
        fprintf(stderr, "Memory allocation error.\n");
        return INTERNAL_ERROR;
    }
    memset(buf, 0, sizeof(char) * BUF_SIZE);

    transform_se se;
    do
    {
        result_stat = 0;
        (void)read_cmd(buf, BUF_SIZE);
        if (OK != ei_decode_version((const char *)buf, &offset, &version))
        {
            continue;
        }
        else if (OK != ei_decode_list_header((const char *)buf, &offset, &arity))
        {
            fprintf(stderr, "Failed to decode list.\n");
            continue;
        }
        else
        {
            encode_stat = parse_transform(buf, offset, arity, &se, result);
            if (OK == encode_stat)
                encode_stat = process_image(&se, &result);
            if (INTERNAL_ERROR != encode_stat)
            {
                (void)write_cmd(&result);
                result_stat = 1;
            }
        }
        memset(buf, 0, sizeof(char) * BUF_SIZE);
        result.index = 0;
        memset(result.buff, 0, result.buffsz);
        offset = 0;
    } while (result_stat == 1);

    free(buf);
    (void)ei_x_free(&result);
    return 0;
}
