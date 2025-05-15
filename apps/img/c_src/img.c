/*
* This is image processing program, that
* - creates thumbnails
* - applies watermarks
*
*/
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <ei.h>
#include <signal.h>
#include <stdlib.h>
#include <wand/MagickWand.h>

/* Maximum resolution is 25Mpx */

#define HEADER_SIZE         4
#define HEADER_BYTES_COUNT  4
#define BUF_SIZE            26214400 // 25 MB is big enough for most of JPEGs
#define OK                  0

#undef MIN
#define MIN(a,b)        ((a) < (b) ? (a) : (b))
#undef ROUND
#define ROUND(f)        ((f>=0)?(int)(f + .5):(int)(f - .5))

/* encode/decode session info. */
typedef struct transform {
    unsigned char *from;
    size_t from_size;
    char to[5];
    unsigned char *watermark;
    size_t watermark_size;
    unsigned long scale_width;
    unsigned long scale_height;
    unsigned char *tag; // PID
    int crop; // Crop image
    int just_get_size; // Just return width and height of provided image
    size_t tag_size;
} transform_se;

static ssize_t write_exact(unsigned char * buf, ssize_t len) {
    ssize_t i, wrote = 0;

    do {
        if ((i = write(STDOUT_FILENO, buf + wrote, (size_t) len - wrote)) <= 0)
            return i;
        wrote += i;
    } while (wrote < len);
    return len;
}

static ssize_t write_cmd(ei_x_buff * buff) {
    unsigned char li;

    li = (buff->index >> 24) & 0xff;
    (void)write_exact(&li, 1);
    li = (buff->index >> 16) & 0xff;
    (void)write_exact(&li, 1);
    li = (buff->index >> 8) & 0xff;
    (void)write_exact(&li, 1);
    li = buff->index & 0xff;
    (void)write_exact(&li, 1);

    return write_exact((unsigned char *) buff->buff, buff->index);
}

static int encode_error(transform_se *se, ei_x_buff *result, char *atom_name) {
  char error_key[6] = "error\0";
  if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2)
	|| ei_x_encode_binary(result, se->tag, se->tag_size)
	|| ei_x_encode_tuple_header(result, 2)
        || ei_x_encode_atom(result, error_key)
        || ei_x_encode_atom(result, atom_name))
        return -1;
    return 0;
}

static int encode_ping_response(transform_se *se, ei_x_buff *result, char *atom_name) {
  char ping_key[6] = "ping\0";
  if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2)
	|| ei_x_encode_binary(result, se->tag, se->tag_size)
	|| ei_x_encode_tuple_header(result, 2)
        || ei_x_encode_atom(result, ping_key)
        || ei_x_encode_atom(result, atom_name))
        return -1;
    return 0;
}

/*
    ``se`` -- source data
    ``result`` -- should contain status
*/
int process_image(transform_se *se, ei_x_buff *result){
  int encode_stat = 0;
  size_t width, height;
  if(se->from_size == 0){
    encode_stat = encode_error(se, result, "no_src_img_error");
    return encode_stat;
  }
  MagickBooleanType status;
  MagickWand *magick_wand;

  MagickWandGenesis();
  magick_wand = NewMagickWand();

  status = MagickReadImageBlob(magick_wand, se->from, se->from_size);
  if (status == MagickFalse){
    encode_stat = encode_error(se, result, "blob_src_imagemagick_error");
    (void)DestroyMagickWand(magick_wand);
    free(se->from);
    free(se->tag);
    return encode_stat;
  }
  if(se->just_get_size == 1){
    width = MagickGetImageWidth(magick_wand);
    height = MagickGetImageHeight(magick_wand);
    if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2)
	|| ei_x_encode_binary(result, se->tag, se->tag_size)
	|| ei_x_encode_tuple_header(result, 2)
	|| ei_x_encode_ulong(result, width)
	|| ei_x_encode_ulong(result, height))
      encode_stat = encode_error(se, result, "size_encoding_error");

    (void)DestroyMagickWand(magick_wand);
    MagickWandTerminus();
    free(se->from);
    free(se->tag);
    return encode_stat;
  } else if(se->watermark_size > 0){
    // apply watermark
    MagickWand *magick_wand_watermark;

    magick_wand_watermark = NewMagickWand();
    status = MagickReadImageBlob(magick_wand_watermark, se->watermark, se->watermark_size);
    if (status == MagickFalse){
      encode_stat = encode_error(se, result, "watermark_blob_imagemagick_error");
      (void)DestroyMagickWand(magick_wand);
      (void)DestroyMagickWand(magick_wand_watermark);
      free(se->from);
      free(se->tag);
      return encode_stat;
    }

    status = MagickEvaluateImageChannel(magick_wand_watermark, AlphaChannel, MultiplyEvaluateOperator, 0.4);
    if (status == MagickFalse){
      encode_stat = encode_error(se, result, "alpha_imagemagick_error");
      (void)DestroyMagickWand(magick_wand);
      (void)DestroyMagickWand(magick_wand_watermark);
      free(se->from);
      free(se->tag);
      return encode_stat;
    }

    width = MagickGetImageWidth(magick_wand);
    height = MagickGetImageHeight(magick_wand);

    size_t wm_width = MagickGetImageWidth(magick_wand_watermark);
    size_t wm_height = MagickGetImageHeight(magick_wand_watermark);

    size_t wm_scale_width = (width/5)*2;
    size_t wm_scale_height = (height/5)*2;
    size_t wm_src_ratio = wm_width / wm_height;
    size_t wm_cal_ratio = wm_scale_width / wm_scale_height;

    if(wm_cal_ratio > wm_src_ratio){
	status = MagickResizeImage(magick_wand_watermark, wm_scale_width, (wm_scale_width * wm_height / wm_width), TriangleFilter, 1.0);
        if (status == MagickFalse){
          encode_stat = encode_error(se, result, "imagemagick_resize_error");
          (void)DestroyMagickWand(magick_wand);
          (void)DestroyMagickWand(magick_wand_watermark);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
    } else if(wm_cal_ratio < wm_src_ratio){
	status = MagickResizeImage(magick_wand_watermark, wm_scale_height * wm_width / wm_height, wm_scale_height, TriangleFilter, 1.0);
        if (status == MagickFalse){
          encode_stat = encode_error(se, result, "imagemagick_resize_error");
          (void)DestroyMagickWand(magick_wand);
          (void)DestroyMagickWand(magick_wand_watermark);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
      } else {
	status = MagickResizeImage(magick_wand_watermark, wm_scale_width, wm_scale_height, TriangleFilter, 1.0);
        if (status == MagickFalse){
          encode_stat = encode_error(se, result, "imagemagick_resize_error");
          (void)DestroyMagickWand(magick_wand);
          (void)DestroyMagickWand(magick_wand_watermark);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
    }

    status = MagickCompositeImage(magick_wand, magick_wand_watermark, DissolveCompositeOp, width/5, height/5);
    if (status == MagickFalse){
      encode_stat = encode_error(se, result, "composite_imagemagick_error");
      (void)DestroyMagickWand(magick_wand);
      (void)DestroyMagickWand(magick_wand_watermark);
      free(se->from);
      free(se->tag);
      return encode_stat;
    }
    (void)DestroyMagickWand(magick_wand_watermark);
  } else {
    if(se->scale_width > 0 && se->scale_height > 0){
      // resize
      size_t new_width, new_height;
      width = MagickGetImageWidth(magick_wand);
      height = MagickGetImageHeight(magick_wand);

      if(strcmp(se->to, "webp") == 0) {
        status = MagickSetImageFormat(magick_wand, "WEBP");
        if (status == MagickFalse) {
          encode_stat = encode_error(se, result, "webp_format_imagemagick_error");
          (void)DestroyMagickWand(magick_wand);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
	status = MagickSetImageCompressionQuality(magick_wand, 85);
	if (status == MagickFalse) {
	    encode_stat = encode_error(se, result, "imagemagick_webp_compress_error");
	    (void)DestroyMagickWand(magick_wand);
	    free(se->from);
	    free(se->tag);
	    return encode_stat;
	}
      } else if(strcmp(se->to, "jpeg") == 0) {
        status = MagickSetImageFormat(magick_wand, "JPEG");
        if (status == MagickFalse) {
          encode_stat = encode_error(se, result, "jpeg_format_imagemagick_error");
          (void)DestroyMagickWand(magick_wand);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
        status = MagickSetImageCompressionQuality(magick_wand, 95); // Higher quality for JPEG
        if (status == MagickFalse) {
          encode_stat = encode_error(se, result, "imagemagick_jpeg_compress_error");
          (void)DestroyMagickWand(magick_wand);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
      }
      double src_ratio = (double)width / (double)height;
      double cal_ratio = (double)se->scale_width / (double)se->scale_height;

      if(cal_ratio > src_ratio){
	status = MagickResizeImage(magick_wand, se->scale_width, (se->scale_width * height / width), TriangleFilter, 1.0);
        if (status == MagickFalse){
          encode_stat = encode_error(se, result, "imagemagick_resize_error");
          (void)DestroyMagickWand(magick_wand);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
        if(se->crop == 1){
          width = MagickGetImageWidth(magick_wand);
          height = MagickGetImageHeight(magick_wand);

	  new_height = ((height + se->scale_height)/2) - ((height - se->scale_height)/2);

	  status = MagickCropImage(magick_wand, width, new_height, 0, (height - se->scale_height)/2);
          if (status == MagickFalse){
            encode_stat = encode_error(se, result, "imagemagick_crop_error");
            (void)DestroyMagickWand(magick_wand);
            free(se->from);
            free(se->tag);
            return encode_stat;
          }
        }
      } else if(cal_ratio < src_ratio){
	status = MagickResizeImage(magick_wand, se->scale_height * width / height, se->scale_height, TriangleFilter, 1.0);
        if (status == MagickFalse){
          encode_stat = encode_error(se, result, "imagemagick_resize_error");
          (void)DestroyMagickWand(magick_wand);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
        if(se->crop == 1){
          width = MagickGetImageWidth(magick_wand);
          height = MagickGetImageHeight(magick_wand);

	  new_width = ((width + se->scale_width)/2) - ((width -  se->scale_width)/2);
	  status = MagickCropImage(magick_wand, new_width, height, (width -  se->scale_width)/2, 0);
          if (status == MagickFalse){
            encode_stat = encode_error(se, result, "imagemagick_crop_error");
            (void)DestroyMagickWand(magick_wand);
            free(se->from);
            free(se->tag);
            return encode_stat;
          }
	}
      } else {
	status = MagickResizeImage(magick_wand, se->scale_width, se->scale_height, TriangleFilter, 1.0);
        if (status == MagickFalse){
          encode_stat = encode_error(se, result, "imagemagick_resize_error");
          (void)DestroyMagickWand(magick_wand);
          free(se->from);
          free(se->tag);
          return encode_stat;
        }
      }
      status = MagickSetImageCompressionQuality(magick_wand, 95);
      if (status == MagickFalse){
        encode_stat = encode_error(se, result, "imagemagick_compress_error");
        (void)DestroyMagickWand(magick_wand);
        free(se->from);
        free(se->tag);
        return encode_stat;
      }
    }
  }

  size_t output_len = 0;
  unsigned char *output = MagickGetImageBlob(magick_wand, &output_len);

  if (ei_x_new_with_version(result) || ei_x_encode_tuple_header(result, 2)
	|| ei_x_encode_binary(result, se->tag, se->tag_size)
	|| ei_x_encode_binary(result, output, output_len))
    encode_stat = encode_error(se, result, "binary_encoding_error");

  (void)DestroyMagickWand(magick_wand);
  MagickWandTerminus();

  if(se->watermark_size > 0){
    free(se->watermark);
  }
  free(se->from);
  free(se->tag);
  free(output);
  return encode_stat;
}

/*
    parse_transform -- parses encoded erlang term
    Example of expected Erlang term
    [
	{from, Data},        % image data
	{to, jpeg},          % output format
	{watermark, W},      % optional image data
	{scale_width, 1024}, % optional width to resize to
	{scale_height, 768}  % and height
    ]

    ``buf``    -- raw data
    ``offset`` -- offset of list element to start parsing from
    ``arity``  -- the number of elements in list
    ``se``     -- structure to fill result to
    ``result`` -- should contain status
*/
int parse_transform(unsigned char * buf, int offset, int arity, transform_se *se, ei_x_buff result){
  int tmp_arity = 0;
  int encode_stat = 0;
  int type = 0;
  char last_atom[MAXATOMLEN] = "";

  se->from_size = 0;
  se->watermark_size = 0;
  se->tag_size = 0;
  se->scale_width = 0;
  se->scale_height = 0;
  se->crop = 1;
  se->just_get_size = 0;

  int i;
  for (i = 0; i < arity; i++){
    (void)ei_get_type((char *) buf, &offset, &type, (int *) &tmp_arity);
    if(ERL_SMALL_TUPLE_EXT != type){
	encode_stat = encode_error(se, &result, "unexpected_type");
	break;
    }
    if (OK != ei_decode_tuple_header((const char *) buf, &offset, &tmp_arity)){
	encode_stat = encode_error(se, &result, "tuple_decode_error");
	break;
    }
    if(tmp_arity != 2){
	encode_stat = encode_error(se, &result, "tuple_value_decode_error");
	break;
    }
    if (ei_decode_atom((const char *) buf, &offset, last_atom)){
	encode_stat = encode_error(se, &result, "atom_decode_error");
	break;
    }
    if(strncmp("from", last_atom, strlen(last_atom)) == 0){
	(void)ei_get_type((char *) buf, &offset, &type, (int *) &(se->from_size));
	if(ERL_BINARY_EXT != type){
	    encode_stat = encode_error(se, &result, "binary_decode_error");
	    break;
	}
	se->from = malloc(se->from_size);
	if (NULL == se->from)
	    return -1;
	memset(se->from, 0, se->from_size);
	if (OK != ei_decode_binary((const char *) buf, &offset, se->from, (long *) &(se->from_size))){
	    encode_stat = encode_error(se, &result, "binary_decode_error");
	    break;
	}
    } else if(strncmp("to", last_atom, strlen(last_atom)) == 0){
	if (ei_decode_atom((const char *) buf, &offset, last_atom)){
	    encode_stat = encode_error(se, &result, "atom_decode_error");
	    break;
	}
	if(strlen(last_atom) > 4 && strcmp(last_atom, "webp") != 0 && strcmp(last_atom, "jpeg") != 0) {
	  encode_stat = encode_error(se, &result, "unk_dst_format");
	  break;
	}
    } else if(strncmp("watermark", last_atom, strlen(last_atom)) == 0){
	(void)ei_get_type((char *) buf, &offset, &type, (int *) &(se->watermark_size));
	if(ERL_BINARY_EXT != type){
	    encode_stat = encode_error(se, &result, "watermark_binary_decode_error");
	    break;
	}
	se->watermark = malloc(se->watermark_size);
	if (NULL == se->watermark)
	    return -1;
	memset(se->watermark, 0, se->watermark_size);
	if (OK != ei_decode_binary((const char *) buf, &offset, se->watermark, (long *) &(se->watermark_size))){
	    encode_stat = encode_error(se, &result, "watermark_binary_decode_error");
	    break;
	}
    } else if(strncmp("scale_width", last_atom, strlen(last_atom)) == 0){
	(void)ei_decode_ulong((const char *) buf, &offset, &(se->scale_width));
    } else if(strncmp("scale_height", last_atom, strlen(last_atom)) == 0){
	(void)ei_decode_ulong((const char *) buf, &offset, &(se->scale_height));
    } else if(strncmp("crop", last_atom, strlen(last_atom)) == 0){
	(void)ei_decode_boolean((const char *) buf, &offset, &(se->crop));
    } else if(strncmp("just_get_size", last_atom, strlen(last_atom)) == 0){
	(void)ei_decode_boolean((const char *) buf, &offset, &(se->just_get_size));
    } else if(strncmp("ping", last_atom, strlen(last_atom)) == 0){
	if (ei_decode_atom((const char *) buf, &offset, last_atom)){
	    encode_stat = encode_error(se, &result, "atom_decode_error");
	    break;
	}
	encode_stat = encode_ping_response(se, &result, "ping");
    } else if(strncmp("tag", last_atom, strlen(last_atom)) == 0){
	(void)ei_get_type((char *) buf, &offset, &type, (int *) &(se->tag_size));
	if(ERL_BINARY_EXT != type){
	    encode_stat = encode_error(se, &result, "tag_binary_decode_error");
	    break;
	}
	se->tag = malloc(se->tag_size);
	if (NULL == se->tag)
	    return -1;
	memset(se->tag, 0, se->tag_size);
	if (OK != ei_decode_binary((const char *) buf, &offset, se->tag, (long *) &(se->tag_size))){
	    encode_stat = encode_error(se, &result, "tag_binary_decode_error");
	    break;
	}
    };
  } // forloop

  return encode_stat;
}

static void int_handler(int dummy) {
    /* async safe ? */
    (void)close(STDIN_FILENO);
    (void)close(STDOUT_FILENO);
}

static ssize_t read_exact(unsigned char * buf, ssize_t len) {
    ssize_t i, got = 0;
    do {
        if ((i = read(STDIN_FILENO, buf + got, len - got)) <= 0) {
            return i;
        }
        got += i;
    } while (got < len);
    return len;
}

static ssize_t read_cmd(unsigned char * buf, ssize_t size) {
    ssize_t len;
    if (read_exact(buf, 4) != 4)
        return (-1);

    len = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];

    if (len > size) {
        unsigned char* tmp = (unsigned char *) realloc(buf, len);
        if (tmp == NULL)
            return -1;
        else
            buf = tmp;
    }
    return read_exact(buf, len);
}

int main(void) {
  (void)signal(SIGINT, int_handler);

  int encode_stat = 0;
  int result_stat = 1;
  int version = 0;
  int offset = 0;
  int arity = 0;

  ei_x_buff result;
  result.buffsz = MAXATOMLEN+10;
  result.buff = malloc(result.buffsz);
  result.index = 0;
  if (NULL == result.buff){
    fprintf(stderr, "Memory allocation error.\n");
    return -1;
  }
  memset(result.buff, 0, result.buffsz);

  unsigned char * buf;
  buf = (unsigned char *) malloc(sizeof(char) * BUF_SIZE);
  if (NULL == buf){
    fprintf(stderr, "Memory allocation error.\n");
    return -1;
  }
  memset(buf, 0, sizeof(char) * BUF_SIZE);

  transform_se se;
  do {
    result_stat = 0;
    (void)read_cmd(buf, BUF_SIZE);
    if (OK != ei_decode_version((const char *) buf, &offset, &version)){
      continue;
    } else if (OK != ei_decode_list_header((const char *) buf, &offset, &arity)){
      fprintf(stderr, "Failed to decode list.\n");
      continue;
    } else {
      encode_stat = parse_transform(buf, offset, arity, &se, result);
      if(OK == encode_stat)
	encode_stat = process_image(&se, &result);
    }
    if (OK != encode_stat){
      fprintf(stderr, "Failed to encode reply\n");
    } else {
      (void)write_cmd(&result);
      result_stat = 1;
    }
    memset(buf, 0, sizeof(char) * BUF_SIZE);
    result.index = 0;
    memset(result.buff, 0, result.buffsz);
    offset = 0;
  } while(result_stat==1);

  free(buf);
  (void)ei_x_free(&result);
  return 0;
}
