#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <wand/MagickWand.h>

#define OK 0

typedef struct options {
    char *input_file;
    char *output_file;
    char *watermark_file;
    char output_format[10];
    unsigned long scale_width;
    unsigned long scale_height;
    int crop;
    int just_get_size;
} options_t;

void usage(const char *prog_name) {
    printf("Usage: %s [options]\n", prog_name);
    printf("Options:\n");
    printf("  -i <input_file>       Input image file\n");
    printf("  -o <output_file>      Output image file\n");
    printf("  -w <watermark_file>   Optional watermark image file\n");
    printf("  -f <format>           Output format (jpeg, webp, etc.)\n");
    printf("  -width <pixels>       Scale width\n");
    printf("  -height <pixels>      Scale height\n");
    printf("  -crop                 Crop image after scaling (default: true)\n");
    printf("  -nocrop               Don't crop image after scaling\n");
    printf("  -size                 Just get image size\n");
    printf("Example: %s -i input.jpg -o output.webp -f webp -w watermark.png\n", prog_name);
}

int parse_args(int argc, char *argv[], options_t *opts) {
    int i;
    
    // Set defaults
    memset(opts, 0, sizeof(options_t));
    opts->crop = 1;
    strcpy(opts->output_format, "jpeg");
    
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) {
            opts->input_file = argv[++i];
        } else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            opts->output_file = argv[++i];
        } else if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) {
            opts->watermark_file = argv[++i];
        } else if (strcmp(argv[i], "-f") == 0 && i + 1 < argc) {
            strncpy(opts->output_format, argv[++i], 9);
            opts->output_format[9] = '\0'; // Ensure null termination
        } else if (strcmp(argv[i], "-width") == 0 && i + 1 < argc) {
            opts->scale_width = atol(argv[++i]);
        } else if (strcmp(argv[i], "-height") == 0 && i + 1 < argc) {
            opts->scale_height = atol(argv[++i]);
        } else if (strcmp(argv[i], "-crop") == 0) {
            opts->crop = 1;
        } else if (strcmp(argv[i], "-nocrop") == 0) {
            opts->crop = 0;
        } else if (strcmp(argv[i], "-size") == 0) {
            opts->just_get_size = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 1;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }
    
    if (!opts->input_file) {
        fprintf(stderr, "Error: Input file is required\n");
        usage(argv[0]);
        return 1;
    }
    
    if (!opts->output_file && !opts->just_get_size) {
        fprintf(stderr, "Error: Output file is required unless using -size option\n");
        usage(argv[0]);
        return 1;
    }
    
    return 0;
}

int process_image(options_t *opts) {
    MagickBooleanType status;
    MagickWand *magick_wand;
    size_t width, height;
    //unsigned char *image_data = NULL;
    //size_t image_size = 0;
    //FILE *file;
    
    // Initialize ImageMagick
    MagickWandGenesis();
    
    // Create a wand
    magick_wand = NewMagickWand();
    
    // Read the input image
    status = MagickReadImage(magick_wand, opts->input_file);
    if (status == MagickFalse) {
        fprintf(stderr, "Error reading input image: %s\n", opts->input_file);
        DestroyMagickWand(magick_wand);
        MagickWandTerminus();
        return 1;
    }
    
    // If just getting size
    if (opts->just_get_size) {
        width = MagickGetImageWidth(magick_wand);
        height = MagickGetImageHeight(magick_wand);
        printf("Image size: %zu x %zu\n", width, height);
        DestroyMagickWand(magick_wand);
        MagickWandTerminus();
        return 0;
    }
    
    // Set output format
    if (strcmp(opts->output_format, "webp") == 0) {
        status = MagickSetImageFormat(magick_wand, "WEBP");
        if (status == MagickFalse) {
            fprintf(stderr, "Error setting WebP format\n");
            DestroyMagickWand(magick_wand);
            MagickWandTerminus();
            return 1;
        }
    } else if (strcmp(opts->output_format, "jpeg") == 0) {
        status = MagickSetImageFormat(magick_wand, "JPEG");
        if (status == MagickFalse) {
            fprintf(stderr, "Error setting JPEG format\n");
            DestroyMagickWand(magick_wand);
            MagickWandTerminus();
            return 1;
        }
    } else {
        fprintf(stderr, "Unsupported format: %s\n", opts->output_format);
        DestroyMagickWand(magick_wand);
        MagickWandTerminus();
        return 1;
    }
    
    // Apply watermark if specified
    if (opts->watermark_file) {
        MagickWand *watermark_wand = NewMagickWand();
        status = MagickReadImage(watermark_wand, opts->watermark_file);
        if (status == MagickFalse) {
            fprintf(stderr, "Error reading watermark: %s\n", opts->watermark_file);
            DestroyMagickWand(watermark_wand);
            DestroyMagickWand(magick_wand);
            MagickWandTerminus();
            return 1;
        }
        
        // Make watermark semi-transparent
        status = MagickEvaluateImageChannel(watermark_wand, AlphaChannel, MultiplyEvaluateOperator, 0.4);
        if (status == MagickFalse) {
            fprintf(stderr, "Error setting watermark transparency\n");
            DestroyMagickWand(watermark_wand);
            DestroyMagickWand(magick_wand);
            MagickWandTerminus();
            return 1;
        }
        
        width = MagickGetImageWidth(magick_wand);
        height = MagickGetImageHeight(magick_wand);
        
        size_t wm_width = MagickGetImageWidth(watermark_wand);
        size_t wm_height = MagickGetImageHeight(watermark_wand);
        
        size_t wm_scale_width = (width/5)*2;
        size_t wm_scale_height = (height/5)*2;
        double wm_src_ratio = (double)wm_width / (double)wm_height;
        double wm_cal_ratio = (double)wm_scale_width / (double)wm_scale_height;
        
        if (wm_cal_ratio > wm_src_ratio) {
            status = MagickResizeImage(watermark_wand, wm_scale_width, (wm_scale_width * wm_height / wm_width), TriangleFilter, 1.0);
        } else if (wm_cal_ratio < wm_src_ratio) {
            status = MagickResizeImage(watermark_wand, wm_scale_height * wm_width / wm_height, wm_scale_height, TriangleFilter, 1.0);
        } else {
            status = MagickResizeImage(watermark_wand, wm_scale_width, wm_scale_height, TriangleFilter, 1.0);
        }
        
        if (status == MagickFalse) {
            fprintf(stderr, "Error resizing watermark\n");
            DestroyMagickWand(watermark_wand);
            DestroyMagickWand(magick_wand);
            MagickWandTerminus();
            return 1;
        }
        
        // Apply watermark
        status = MagickCompositeImage(magick_wand, watermark_wand, DissolveCompositeOp, width/5, height/5);
        if (status == MagickFalse) {
            fprintf(stderr, "Error applying watermark\n");
            DestroyMagickWand(watermark_wand);
            DestroyMagickWand(magick_wand);
            MagickWandTerminus();
            return 1;
        }
        
        DestroyMagickWand(watermark_wand);
    }
    
    // Resize if specified
    if (opts->scale_width > 0 && opts->scale_height > 0) {
        size_t new_width, new_height;
        width = MagickGetImageWidth(magick_wand);
        height = MagickGetImageHeight(magick_wand);
        
        double src_ratio = (double)width / (double)height;
        double cal_ratio = (double)opts->scale_width / (double)opts->scale_height;
        
        if (cal_ratio > src_ratio) {
            status = MagickResizeImage(magick_wand, opts->scale_width, (opts->scale_width * height / width), TriangleFilter, 1.0);
            if (status == MagickFalse) {
                fprintf(stderr, "Error resizing image\n");
                DestroyMagickWand(magick_wand);
                MagickWandTerminus();
                return 1;
            }
            
            if (opts->crop) {
                width = MagickGetImageWidth(magick_wand);
                height = MagickGetImageHeight(magick_wand);
                
                new_height = ((height + opts->scale_height)/2) - ((height - opts->scale_height)/2);
                
                status = MagickCropImage(magick_wand, width, new_height, 0, (height - opts->scale_height)/2);
                if (status == MagickFalse) {
                    fprintf(stderr, "Error cropping image\n");
                    DestroyMagickWand(magick_wand);
                    MagickWandTerminus();
                    return 1;
                }
            }
        } else if (cal_ratio < src_ratio) {
            status = MagickResizeImage(magick_wand, opts->scale_height * width / height, opts->scale_height, TriangleFilter, 1.0);
            if (status == MagickFalse) {
                fprintf(stderr, "Error resizing image\n");
                DestroyMagickWand(magick_wand);
                MagickWandTerminus();
                return 1;
            }
            
            if (opts->crop) {
                width = MagickGetImageWidth(magick_wand);
                height = MagickGetImageHeight(magick_wand);
                
                new_width = ((width + opts->scale_width)/2) - ((width - opts->scale_width)/2);
                status = MagickCropImage(magick_wand, new_width, height, (width - opts->scale_width)/2, 0);
                if (status == MagickFalse) {
                    fprintf(stderr, "Error cropping image\n");
                    DestroyMagickWand(magick_wand);
                    MagickWandTerminus();
                    return 1;
                }
            }
        } else {
            status = MagickResizeImage(magick_wand, opts->scale_width, opts->scale_height, TriangleFilter, 1.0);
            if (status == MagickFalse) {
                fprintf(stderr, "Error resizing image\n");
                DestroyMagickWand(magick_wand);
                MagickWandTerminus();
                return 1;
            }
        }
    }
    
    // Adjust quality based on format
    if (strcmp(opts->output_format, "webp") == 0) {
        status = MagickSetImageCompressionQuality(magick_wand, 85); // Appropriate for WebP
    } else if (strcmp(opts->output_format, "jpeg") == 0) {
        status = MagickSetImageCompressionQuality(magick_wand, 95); // Higher quality for JPEG
    }
    
    if (status == MagickFalse) {
        fprintf(stderr, "Error setting compression quality\n");
        DestroyMagickWand(magick_wand);
        MagickWandTerminus();
        return 1;
    }
    
    // Write the output image
    status = MagickWriteImage(magick_wand, opts->output_file);
    if (status == MagickFalse) {
        fprintf(stderr, "Error writing output image: %s\n", opts->output_file);
        DestroyMagickWand(magick_wand);
        MagickWandTerminus();
        return 1;
    }
    
    printf("Successfully processed image to: %s\n", opts->output_file);
    
    // Clean up
    DestroyMagickWand(magick_wand);
    MagickWandTerminus();
    
    return 0;
}

int main(int argc, char *argv[]) {
    options_t opts;
    
    if (parse_args(argc, argv, &opts) != 0) {
        return 1;
    }
    
    return process_image(&opts);
}
