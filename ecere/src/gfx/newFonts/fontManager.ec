/* *****************************************************************************
 * Original Version Copyright (c) 2007-2014 Alexis Naveros.
 *
 * Ecere Corporation has unlimited/unrestricted rights.
 * *****************************************************************************/
import "LinkList"
import "File"

import "atlasBuilder"

#include <stdlib.h>
#include <math.h>

#include "cc.h"

static inline uint32 decodeUTF8( uint32 b, uint32 *state, unichar *retCodePoint ) { return ccUtf8ToUnicode(b, state, (uint *)retCodePoint); }

////

// Based on Exponential blur, Jani Huhtanen, 2006

#define APREC 16
#define ZPREC 7

static void blurCols( byte *dst, int w, int h, int stride, int alpha )
{
   int y;
   for( y = 0 ; y < h ; y++ )
   {
      int x, z = 0;
      for( x = 1 ; x < w ; x++ )
      {
         z += ( alpha * ( ( (int)( dst[x] ) << ZPREC ) - z ) ) >> APREC;
         dst[x] = (byte)( z >> ZPREC );
      }
      for( x = w-2 ; x >= 0 ; x-- )
      {
         z += ( alpha * ( ( (int)( dst[x] ) << ZPREC ) - z ) ) >> APREC;
         dst[x] = (byte)( z >> ZPREC );
      }
      dst += stride;
   }
}

static void blurRows( byte *dst, int w, int h, int stride, int alpha )
{
   int x;
   for( x = 0 ; x < w ; x++ )
   {
      int y, z = 0;
      for( y = stride ; y < h*stride ; y += stride )
      {
         z += ( alpha * ( ( (int)( dst[y] ) << ZPREC ) - z ) ) >> APREC;
         dst[y] = (byte)( z >> ZPREC );
      }
      for( y = (h-2)*stride ; y >= 0 ; y -= stride )
      {
         z += ( alpha * ( ( (int)( dst[y] ) << ZPREC ) - z ) ) >> APREC;
         dst[y] = (byte)( z >> ZPREC );
      }
      dst++;
   }
}

static void blur( byte *dst, int width, int height, int stride, int radius )
{
   if( radius >= 1 )
   {
      int boxcount = 2;
      // Calculate the alpha such that 90% of the kernel is within the radius. (Kernel extends to infinity)
      float radiusrange = (float)radius * ( 1.0f / sqrtf( 3 ) );
      uint32 alpha = (uint32)roundf( ( 1 << APREC ) * ( 1.0f - expf( -2.3f / ( radiusrange + 1.0f ) ) ) );
      for( ; boxcount ; boxcount-- )
      {
         blurRows( dst, width, height, stride, alpha );
         blurCols( dst, width, height, stride, alpha );
      }
  }
}

#undef APREC
#undef ZPREC


#define APREC 12
#define ZPREC 7
#define SPREC (31-(APREC+ZPREC+8))

static void blurCols32( int *dst, int w, int h, int stride, int alpha )
{
   int y;
   for( y = 0 ; y < h ; y++ )
   {
      int x, z = 0;
      for( x = 1 ; x < w ; x++ )
      {
         z += ( alpha * ( dst[x] - z ) ) >> APREC;
         dst[x] = z;
      }
      for( x = w - 2 ; x >= 0 ; x-- )
      {
         z += ( alpha * ( dst[x] - z ) ) >> APREC;
         dst[x] = z;
      }
      dst += stride;
   }
}

static void blurRows32( int *dst, int w, int h, int stride, int alpha )
{
  int x;
  for( x = 0 ; x < w ; x++ )
  {
    int y, z = 0;
    for( y = 1 * stride ; y < h * stride ; y += stride )
    {
      z += ( alpha * ( dst[y] - z ) ) >> APREC;
      dst[y] = z;
    }
    for( y = ( h - 2 ) * stride ; y >= 0 ; y -= stride )
    {
      z += ( alpha * ( dst[y] - z ) ) >> APREC;
      dst[y] = z;
    }
    dst++;
  }
}

static void blurScale( byte *dst, int width, int height, int stride, int radius, int scale )
{
   if( radius >= 1 )
   {
      int x, y, boxcount;
      float radiusrange;
      int alpha;
      int *buffer, *bufferrow;
      byte *dstrow;

      if( scale > ( 1 << SPREC ) )
         scale = 1 << SPREC;

      buffer = malloc( width * height * sizeof(int) );
      for( y = 0 ; y < height ; y++ )
      {
         dstrow = &dst[y*stride];
         bufferrow = &buffer[y*width];
         for( x = 0 ; x < width ; x++ )
            bufferrow[x] = ( (int)dstrow[x] << ZPREC ) * scale;
      }

      boxcount = 3;

      /* Calculate the alpha such that 90% of the kernel is within the radius. (Kernel extends to infinity) */
      radiusrange = (float)radius * 0.3f;
      alpha = (uint32)roundf( ( 1 << APREC ) * ( 1.0f - expf( -2.3f / ( radiusrange + 1.0f ) ) ) );
      for( ; boxcount ; boxcount-- )
      {
         blurRows32( buffer, width, height, width, alpha );
         blurCols32( buffer, width, height, width, alpha );
      }

      for( y = 0 ; y < height ; y++ )
      {
         dstrow = &dst[y*stride];
         bufferrow = &buffer[y*width];
         for( x = 0 ; x < width ; x++ )
            dstrow[x] = (byte)Min(255, bufferrow[x] >> ZPREC);
      }
      free( buffer );
   }
}

#undef APREC
#undef ZPREC
#undef SPREC


////

static void buildCursorGlyph( byte *dst, int glyphwidth, int glyphheight, int dststride )
{
  int x, y, hbarheight, hgap, hline, vline;
  byte *dstrow;

  if( glyphwidth >= 3 )
  {
    hbarheight = 1 + ( glyphheight >> 6 );
    hgap = ( glyphwidth - ( 1 + ( glyphheight >> 6 ) ) ) >> 1;
    hline = hgap + glyphwidth - ( hgap << 1 );
    vline = glyphheight - ( hbarheight << 1 );
    for( y = 0 ; y < hbarheight ; y++ )
    {
      dstrow = dst;
      for( x = 0 ; x < glyphwidth ; x++ )
        dstrow[x] = 255;
      dst += dststride;
    }
    for( y = 0 ; y < vline ; y++ )
    {
      dstrow = dst;
      for( x = 0 ; x < hgap ; x++ )
        dstrow[x] = 0;
      for( ; x < hline ; x++ )
        dstrow[x] = 255;
      for( ; x < glyphwidth ; x++ )
        dstrow[x] = 0;
      dst += dststride;
    }
    for( y = 0 ; y < hbarheight ; y++ )
    {
      dstrow = dst;
      for( x = 0 ; x < glyphwidth ; x++ )
        dstrow[x] = 255;
      dst += dststride;
    }
  }
  else
  {
    for( y = 0 ; y < glyphheight ; y++ )
    {
      dstrow = dst;
      for( x = 0 ; x < glyphwidth ; x++ )
        dstrow[x] = 255;
      dst += dststride;
    }
  }

  return;
}

static inline void addGlyphAdvance( int *x, int *subpixel, FMGlyph *glyph )
{
   *subpixel += glyph->advance;
#if FM_SUBPIXEL_ROUNDING_RANGE
   *subpixel = ( *subpixel + (FM_SUBPIXEL_ROUNDING_RANGE>>1) ) & ~(FM_SUBPIXEL_ROUNDING_RANGE-1);
#endif
   *x += *subpixel >> 6;
   *subpixel &= 0x3f;
}

public class FontManagerRenderer
{
public:
   FontManager fm;

   virtual bool init();

   // Create, resize or update texture data ; rect is [minx,maxx,miny,maxy]
   virtual int createTexture( int width, int height );
   virtual int resizeTexture( int width, int height );
   virtual void updateTexture( int *rect, const byte *data );

   // If the renderer does any buffering of drawImage(), flush it all right now (texture may change immediately after)
   virtual void flush( );

   // If the renderer records per-image data, return an imageIndex passed to drawImage()
   virtual int registerImage( int offsetx, int offsety, int width, int height );
   // Draw an image, imageIndex passed as the value previously returned by registerImage()
   virtual void drawImage( int targetx, int targety, int imageIndex );
   // Draw an image, called instead of drawImage() for text cursors, can point to exactly the same function
   virtual void drawImageCursor( int targetx, int targety, int imageIndex );
   // If drawImage is zero, then this alternate function is called, passing everything required to render the glyph
   virtual void drawImageAlt( byte *texdata, int targetx, int targety, int offsetx, int offsety, int width, int height );
   // Draw a non-aligned image, imageIndex passed as the value previously returned by registerImage()
   virtual void drawImageFloat( float targetx, float targety, float angsin, float angcos, int imageIndex );

   // The renderer must flush all recorded images, registerImage() will be called for new images
   virtual void resetImages( );
};


////


#include <ft2build.h>

#include FT_FREETYPE_H
#include FT_ADVANCES_H


////


#define FM_SUPPORT_GLYPH_ROTATION (1)


////


#define FM_ENABLE_HINTING (1)
#define FM_SUBPIXEL_ROUNDING_RANGE (16)
#if FM_SUPPORT_GLYPH_ROTATION
 #define FM_TEXTURE_PADDING (1)
#else
 #define FM_TEXTURE_PADDING (0)
#endif
#define FM_DEBUG_WHITERECT (0)


#define FM_HASH_TABLE_SIZE (4096)
#define FM_INIT_GLYPHS (1024)
#define FM_INIT_ATLAS_NODES (512)

#define FM_MAX_STATES (16)


////

struct FMFreeTypeFont
{
   FT_Face face;

   static inline int ::init()
   {
     FT_Error ftError;
     ftError = FT_Init_FreeType( &ftLibrary2 );
     return ftError == 0;
   }

   static inline int loadFont( byte *data, int dataSize )
   {
     FT_Error ftError = FT_New_Memory_Face( ftLibrary2, (const FT_Byte*)data, dataSize, 0, &face );
     return ftError == 0;
   }

   void free()
   {
      FT_Done_Face( face );
   }

   static inline void getFontVMetrics( float *ascent, float *descent, float *lineHeight, float *limitminy, float *limitmaxy )
   {
     *ascent = (float)face->ascender;
     *descent = (float)face->descender;
     *lineHeight = (float)face->height / (float)face->units_per_EM;
     *limitminy = (float)face->bbox.yMin / (float)face->units_per_EM;
     *limitmaxy = (float)face->bbox.yMax / (float)face->units_per_EM;
   }

   static inline int getGlyphIndex( unichar codepoint )
   {
     return FT_Get_Char_Index( this.face, codepoint );
   }

   static int buildGlyphBitmap( int glyph, int size, int subpixel, int *advance, int *x0, int *y0, int *x1, int *y1 )
   {
     FT_Error ftError;
     FT_GlyphSlot glyphslot;
     FT_Vector subvector;

     ftError = FT_Set_Pixel_Sizes( this.face, 0, (FT_UInt)size );
     if( ftError )
       return 0;

     subvector.x = subpixel;
     subvector.y = 0;
     FT_Set_Transform( face, 0, &subvector );

   #if FM_ENABLE_HINTING
     ftError = FT_Load_Glyph( face, glyph, FT_LOAD_RENDER );
   #else
     ftError = FT_Load_Glyph( face, glyph, FT_LOAD_RENDER | FT_LOAD_NO_HINTING );
   #endif
     if( ftError )
       return 0;

     glyphslot = face->glyph;
     *advance = glyphslot->metrics.horiAdvance;
     *x0 = glyphslot->bitmap_left;
     *x1 = glyphslot->bitmap_left + glyphslot->bitmap.width;
     *y0 = -glyphslot->bitmap_top;
     *y1 = -glyphslot->bitmap_top + glyphslot->bitmap.rows;

     return 1;
   }

   static void copyGlyphBitmap( byte *dst, int glyphwidth, int glyphheight, int dststride, int glyphindex )
   {
     int x, y;
     byte *dstrow, *src;
     FT_GlyphSlot glyphslot;

     glyphslot = face->glyph;
     src = glyphslot->bitmap.buffer;
     for( y = 0 ; y < glyphslot->bitmap.rows ; y++ )
     {
       dstrow = &dst[ y * dststride ];
       for( x = 0 ; x < glyphslot->bitmap.width ; x++ )
         dstrow[ x ] = src[ x ];
       src += glyphslot->bitmap.width;
     }
     return;
   }

   static inline int getGlyphKernAdvance( int glyph1, int glyph2 )
   {
     FT_Vector ftKerning;
     FT_Get_Kerning( face, glyph1, glyph2, FT_KERNING_DEFAULT, &ftKerning );
     return ftKerning.x;
   }
};

#define FM_DEF_CODEPOINT_BITS (32)
#define FM_DEF_SIZE_BITS (12)
#define FM_DEF_SUBPIXEL_BITS (6)
#define FM_DEF_BLURRADIUS_BITS (8)
#define FM_DEF_BLURSCALE_BITS (6)

#define FM_DEF_CODEPOINT_SHIFT (0)
#define FM_DEF_SIZE_SHIFT (FM_DEF_CODEPOINT_BITS)
#define FM_DEF_SUBPIXEL_SHIFT (FM_DEF_CODEPOINT_BITS+FM_DEF_SIZE_BITS)
#define FM_DEF_BLURRADIUS_SHIFT (FM_DEF_CODEPOINT_BITS+FM_DEF_SIZE_BITS+FM_DEF_SUBPIXEL_BITS)
#define FM_DEF_BLURSCALE_SHIFT (FM_DEF_CODEPOINT_BITS+FM_DEF_SIZE_BITS+FM_DEF_SUBPIXEL_BITS+FM_DEF_BLURRADIUS_BITS)

#define FM_GLYPH_COMPUTE_DEF(codepoint,size,subpixel,blurradius,blurscale) ( (((uint64)(codepoint))<<FM_DEF_CODEPOINT_SHIFT) | (((uint64)(size))<<FM_DEF_SIZE_SHIFT) | (((uint64)(subpixel))<<FM_DEF_SUBPIXEL_SHIFT) | (((uint64)(blurradius))<<FM_DEF_BLURRADIUS_SHIFT) | (((uint64)(blurscale))<<FM_DEF_BLURSCALE_SHIFT) )

#define FM_SIZE_MAX ((1<<FM_DEF_SIZE_BITS)-1)
#define FM_BLUR_RADIUS_MAX ((1<<FM_DEF_BLURRADIUS_BITS)-1)
#define FM_BLUR_SCALE_MAX ((1<<FM_DEF_BLURSCALE_BITS)-1)

#define FM_GLYPH_CODEPOINT_CURSOR (0x1)
#define FM_GLYPH_CODEPOINT_REPLACEMENT (0xfffd)

public enum VerticalAlignment { baseline, top, middle, bottom };

public class FMTextAlignment : uint16
{
public:
   Alignment horzAlignment:2;
   VerticalAlignment vertAlignment:2;
};

public struct FMPathDraw
{
  int prevGlyphIndex;
  float middleAlign;
};

struct FMQuad { int x0, y0, x1, y1; };

struct FMGlyph
{
   int glyphindex;
   uint64 glyphdef;
   short x0, y0, x1, y1;
   short advance, offsetx, offsety;
   int imageIndex;
   int listnext;

   static void getQuad( float x, float y, FMQuad q )
   {
      int rx = (int)(x + offsetx);
      int ry = (int)(y + offsety);
      q = { rx, ry, rx + x1 - x0, ry + y1 - y0 };
   }
};

public class FMFont : struct
{
   public LinkElement link;
   FMFreeTypeFont ftFont;
   void *fontdata;
   float ascender;
   float descender;
   float middleAlign;
   float lineHeight;
   float limitminy, limitmaxy;
   FMGlyph *glyphs;
   int glyphalloc;
   int glyphcount;
   int hashtable[FM_HASH_TABLE_SIZE];

   ~FMFont()
   {
      ftFont.free();
      delete fontdata;
      delete glyphs;
   }

   static FMGlyph *allocGlyph( )
   {
      if( glyphcount >= glyphalloc )
      {
         glyphalloc <<= 1;
         if( !(glyphs = renew glyphs FMGlyph[glyphalloc]) )
            return null;
      }
      return &glyphs[ glyphcount++ ];
   }

   ////

   static float getVertAlign( FMTextAlignment align, int size )
   {
     if( align.vertAlignment == top )
       return ascender * size;
     else if( align.vertAlignment == middle )
       return middleAlign * size;
     else if( align.vertAlignment == bottom )
       return descender * (float)size;
     return 0.0f;
   }

   static inline void addKerning( int prevGlyphIndex, FMGlyph *glyph, int *x, int *subpixel )
   {
     if( prevGlyphIndex != -1 )
     {
       *subpixel += ftFont.getGlyphKernAdvance( prevGlyphIndex, glyph->glyphindex );
   #if FM_SUBPIXEL_ROUNDING_RANGE
       *subpixel = ( *subpixel + (FM_SUBPIXEL_ROUNDING_RANGE>>1) ) & ~(FM_SUBPIXEL_ROUNDING_RANGE-1);
   #endif
       *x += *subpixel >> 6;
       *subpixel &= 0x3f;
     }
   }

};

struct FMState
{
   FMFont font;
   uint16 size;
   FMTextAlignment align;
   uint16 blurradius;
   uint16 blurscale;
};

////


static FT_Library ftLibrary2;

public class FontManager
{
  FontManagerRenderer renderer;
  int width, height;
  float widthinv, heightinv;

  AtlasBuilder atlas { };
  byte *texdata;
  int dirtyrect[4];

  LinkList<FMFont, link = link> fontList { };

  FMState states[FM_MAX_STATES];
  int nstates;

   #if FM_DEBUG_WHITERECT
   static void addWhiteRect( int w, int h )
   {
     int gx, gy;
     if( atlas.addRect( w, h, &gx, &gy ) )
     {
        // Rasterize
        byte * dst = &texdata[ gx + ( gy * width ) ];
        int x, y;
        for( y = 0 ; y < h ; y++)
        {
          for( x = 0 ; x < w ; x++ )
            dst[x] = 0xff;
          dst += width;
        }

        dirtyrect[0] = Min( dirtyrect[0], gx );
        dirtyrect[1] = Min( dirtyrect[1], gy );
        dirtyrect[2] = Max( dirtyrect[2], gx + w );
        dirtyrect[3] = Max( dirtyrect[3], gy + h );
     }
   }
   #endif

   static FMGlyph *getGlyph( FMFont font, unichar codepoint, int size, int subpixel, int blurradius, int blurscale )
   {
     int i, glyphindex, advance, x0, y0, x1, y1, glyphwidth, glyphheight, gx, gy;
   #if FM_TEXTURE_PADDING >= 1
     int x, y;
   #endif
     uint64 glyphdef;
     FMGlyph *glyph;
     uint32 hashindex;
     int padding, added;
     byte *bdst;
     byte *dst;

     glyph = 0;
     if( size < 0.2 )
       return 0;
     padding = blurradius + FM_TEXTURE_PADDING;

     /* Find code point and size. */
     glyphdef = FM_GLYPH_COMPUTE_DEF( codepoint, size, subpixel, blurradius, blurscale );
     hashindex = ccHash32Int64Inline( glyphdef ) & ( FM_HASH_TABLE_SIZE - 1 );
     i = font.hashtable[hashindex];
     while( i != -1 )
     {
       if( glyphdef == font.glyphs[i].glyphdef )
         return &font.glyphs[i];
       i = font.glyphs[i].listnext;
     }

     /* Could not find glyph, create it. */
     if( codepoint == FM_GLYPH_CODEPOINT_CURSOR )
     {
       glyphindex = -1;
       advance = 0;
   #if 0
       x0 = 0;
       x1 = 1;
   #else
       x0 = -2;
       x1 = 3;
   #endif
       y0 = -(int)ceilf( font.limitmaxy * (float)size );
       y1 = -(int)floorf( font.limitminy * (float)size );
       glyphheight = y1 - y0;
       i = ( glyphheight - size ) / 3;
       y0 += i;
       y1 -= i;
     }
     else
     {
       glyphindex = font.ftFont.getGlyphIndex( codepoint );
       if( !( font.ftFont.buildGlyphBitmap( glyphindex, size, subpixel, &advance, &x0, &y0, &x1, &y1 ) ) )
       {
         if( codepoint != FM_GLYPH_CODEPOINT_REPLACEMENT )
           return getGlyph(font, FM_GLYPH_CODEPOINT_REPLACEMENT, size, subpixel, blurradius, blurscale );
         return 0;
       }
     }
     glyphwidth = ( x1 - x0 ) + ( padding << 1 );
     glyphheight = ( y1 - y0 ) + ( padding << 1 );

     // Find free spot for the rect in the atlas
     added = atlas.addRect( glyphwidth, glyphheight, &gx, &gy );
     if( !( added ) && ( onAtlasFull ) )
     {
       /* Atlas is full, let the user to resize the atlas (or not), and try again. */
       onAtlasFull();
       added = atlas.addRect( glyphwidth, glyphheight, &gx, &gy );
     }
     if( !( added ) )
       return 0;

     /* Build the glyph */
     glyph = font.allocGlyph();
     glyph->glyphdef = glyphdef;
     glyph->glyphindex = glyphindex;
     glyph->x0 = (short)gx;
     glyph->y0 = (short)gy;
     glyph->x1 = (short)( glyph->x0 + glyphwidth );
     glyph->y1 = (short)( glyph->y0 + glyphheight );
     glyph->advance = (short)advance;
     glyph->offsetx = (short)( x0 - padding );
     glyph->offsety = (short)( y0 - padding );
     glyph->listnext = 0;
     glyph->imageIndex = -1;
     if( renderer.registerImage )
       glyph->imageIndex = renderer.registerImage( gx, gy, glyphwidth, glyphheight );

     /* Add char to hash table */
     glyph->listnext = font.hashtable[hashindex];
     font.hashtable[hashindex] = font.glyphcount - 1;

     /* Rasterize */
     dst = &texdata[ ( glyph->x0 + padding ) + ( ( glyph->y0 + padding ) * this.width ) ];
     if( codepoint == FM_GLYPH_CODEPOINT_CURSOR )
       buildCursorGlyph( dst, glyphwidth - ( padding << 1 ), glyphheight - ( padding << 1 ), this.width );
     else
       font.ftFont.copyGlyphBitmap( dst, glyphwidth - ( padding << 1 ), glyphheight - ( padding << 1 ), this.width, glyphindex );

     /* Blur */
     if( blurradius > 0 )
     {
       bdst = &texdata[ glyph->x0 + ( glyph->y0 * this.width ) ];
       if( blurscale == 1 )
         blur(bdst, glyphwidth, glyphheight, this.width, blurradius );
       else
         blurScale(bdst, glyphwidth, glyphheight, this.width, blurradius, blurscale );
     }

   #if FM_TEXTURE_PADDING >= 1
     dst = &texdata[ glyph->x0 + ( glyph->y0 * this.width ) ];
     for( y = 0 ; y < glyphheight ; y++ )
     {
       dst[ y * this.width] = 0;
       dst[ ( glyphwidth - 1 ) + ( y * this.width ) ] = 0;
     }
     for( x = 0 ; x < glyphwidth ; x++ )
     {
       dst[ x ] = 0;
       dst[ x + ( ( glyphheight - 1 ) * this.width ) ] = 0;
     }
   #endif

     dirtyrect[0] = Min( dirtyrect[0], glyph->x0 );
     dirtyrect[1] = Min( dirtyrect[1], glyph->y0 );
     dirtyrect[2] = Max( dirtyrect[2], glyph->x1 );
     dirtyrect[3] = Max( dirtyrect[3], glyph->y1 );

     return glyph;
   }

   static inline void drawTextGlyph( FMFont font, FMGlyph *glyph, int x, int y )
   {
      int ptx = x + glyph->offsetx;
      int pty = y + glyph->offsety;
      if( renderer.drawImage )
         renderer.drawImage( ptx, pty, glyph->imageIndex );
      else if( renderer.drawImageAlt )
         renderer.drawImageAlt( texdata, ptx, pty, glyph->x0, glyph->y0, glyph->x1 - glyph->x0, glyph->y1 - glyph->y0 );
   }

   static inline void drawTextCursorGlyph( FMFont font, FMGlyph *glyph, int x, int y )
   {
     int ptx, pty;
     ptx = x + glyph->offsetx;
     pty = y + glyph->offsety;
     if( renderer.drawImageCursor )
       renderer.drawImageCursor( ptx, pty, glyph->imageIndex );
     else if( renderer.drawImageAlt )
       renderer.drawImageAlt( texdata, ptx, pty, glyph->x0, glyph->y0, glyph->x1 - glyph->x0, glyph->y1 - glyph->y0 );
   }

   static inline void drawTextGlyphFloat( FMFont font, FMGlyph *glyph, float x, float y, float vectorx, float vectory, float offsetx, float offsety )
   {
      float vectx = (float)glyph->offsetx + offsetx;
      float vecty = (float)glyph->offsety + offsety;
      float ptx = x + ( vectorx * vectx ) - ( vectory * vecty );
      float pty = y + ( vectorx * vecty ) + ( vectory * vectx );
      renderer.drawImageFloat( ptx, pty, vectory, vectorx, glyph->imageIndex );
   }

public:

   property FontManagerRenderer renderer { set { renderer = value; } get { return renderer; } }\

   // When notified of a full atlas, you should call fmExpandAtlas() or fmResetAtlas() within the callback
   virtual void (*onAtlasFull)();

   // Create and destroy font manager
   bool create( int width, int height, FontManagerRenderer renderer)
   {
      bool result = false;

      this.renderer = renderer;
      incref renderer;
      renderer.init();

      // Initialize implementation library
      if(FMFreeTypeFont::init() )
      {
         this.width = width;
         this.height = height;
         if(renderer.createTexture( width, height ))
         {
            if((atlas.create( this.width, this.height, FM_INIT_ATLAS_NODES )))
            {
               // Create texture for the cache.
               widthinv = 1.0f / width;
               heightinv = 1.0f / height;
               texdata = new byte[width * height];
               if(texdata)
               {
                  memset( texdata, 0, width * height );

                  dirtyrect[0] = this.width;
                  dirtyrect[1] = this.height;
                  dirtyrect[2] = 0;
                  dirtyrect[3] = 0;

               // Add white rect at 0,0 for debug drawing.
               #if FM_DEBUG_WHITERECT
                 fmAddWhiteRect(2, 2 );
               #endif

                 pushState();
                 clearState();

                 result = true;
               }
            }
         }
      }
      return result;
   }

   ~FontManager()
   {
     delete renderer;

     fontList.Free();

     delete atlas;
     delete texdata;
   }


   ////

   // State setting
   void setState( FMFont font, int size, int align, int blurradius, int blurscale )
   {
     FMState *state;
     if( size >= FM_SIZE_MAX )
       size = FM_SIZE_MAX;
     if( blurradius >= FM_BLUR_RADIUS_MAX )
       blurradius = FM_BLUR_RADIUS_MAX;
     else if( blurradius < 0 )
       blurradius = 0;
     if( blurscale >= FM_BLUR_SCALE_MAX )
       blurscale = FM_BLUR_SCALE_MAX;
     else if( blurscale < 1 )
       blurscale = 1;
     state = &states[ nstates - 1 ];
     state->font = font;
     state->size = (uint16)size;
     state->align = (uint16)align;
     state->blurradius = (uint16)blurradius;
     state->blurscale = (uint16)blurscale;
     return;
   }

   void setFont( FMFont font )
   {
     states[ nstates - 1 ].font = font;
   }

   void setSize( int size )
   {
     if( size >= FM_SIZE_MAX )
       size = FM_SIZE_MAX;

     states[ nstates - 1 ].size = (uint16)size;
   }

   void setAlign( int align )
   {
     states[ nstates - 1 ].align = (uint16)align;
   }

   void setBlur( int radius, int scale )
   {
     if( radius >= FM_BLUR_RADIUS_MAX )
       radius = FM_BLUR_RADIUS_MAX;
     else if( radius < 0 )
       radius = 0;
     if( scale >= FM_BLUR_SCALE_MAX )
       scale = FM_BLUR_SCALE_MAX;
     else if( scale < 1 )
       scale = 1;
     states[ nstates - 1 ].blurradius = (uint16)radius;
     states[ nstates - 1 ].blurscale = (uint16)scale;
   }


   // State handling
   void pushState( )
   {
      if(nstates < FM_MAX_STATES)
      {
         if( nstates > 0 )
            memcpy( &states[nstates], &states[nstates-1], sizeof(FMState) );
         nstates++;
      }
   }

   void popState()
   {
      if(nstates > 1)
         nstates--;
   }

   void clearState()
   {
     FMState *state = &states[ nstates - 1 ];
     state->size = 12;
     state->font = 0;
     state->blurradius = 0;
     state->blurscale = 1;
     state->align = { left, baseline };
   }


   ////

   static void freeFont(FMFont font)
   {
     if(font)
     {
        fontList.Remove((IteratorPointer)font);
        delete font;
     }
   }

   // Add font from file
   FMFont addFont(const String path )
   {
      FMFont font = null;
      File f = FileOpen(path, read);
      if(f)
      {
         // Read in the font data
         int dataSize = f.GetSize();
         byte *data = new byte[dataSize];
         if(data)
         {
            f.Read(data, 1, dataSize);
            font = addFontData(data, dataSize );
            if(!font)
               delete data;
         }
         delete f;
      }
      return font;
   }

   // Add font from data ; do not free( data ), the font manager will do that when removing the font
   FMFont addFontData( byte *data, int dataSize )
   {
     FMFont font
     {
        glyphs = new FMGlyph[FM_INIT_GLYPHS];
        glyphalloc = FM_INIT_GLYPHS;
     };
     if(font)
     {
         int i;
         float ascent, descent, fontHeight;

         fontList.Add(font);

         // Init hash lookup
         for( i = 0 ; i < FM_HASH_TABLE_SIZE ; i++ )
            font.hashtable[i] = -1;

         // Init font
         if(!font.ftFont.loadFont(data, dataSize))
         {
            freeFont(font );
            return 0;
         }

         // Store normalized line height. The real line height is got by multiplying by font size.
         font.ftFont.getFontVMetrics( &ascent, &descent, &font.lineHeight, &font.limitminy, &font.limitmaxy );
         fontHeight = ascent - descent;
         font.ascender = ascent / fontHeight;
         font.descender = descent / fontHeight;
         font.middleAlign = 0.5f * ( font.ascender + font.descender );
         font.fontdata = data;
      }
      return font;
   }

   // Free font
   void removeFont( FMFont font )
   {
      freeFont(font );
   }

   // Draw text
   int drawText( int x, int y, const char *string, int stringlength )
   {
     int subpixel, index;
     FMState *state;
     unichar codepoint;
     uint32 utf8state;
     FMGlyph *glyph;
     int prevGlyphIndex;
     int blurradius, blurscale;
     FMFont font;

     state = &states[ nstates - 1 ];
     glyph = 0;
     utf8state = 0;
     prevGlyphIndex = -1;
     blurradius = state->blurradius;
     blurscale = state->blurscale;
     if( !( state->font ) )
       return x;
     font = state->font;
     if( !( stringlength ) )
       stringlength = strlen( string );

     // Align horizontally
     if( state->align.horzAlignment == right )
       x -= getTextWidth(string, stringlength );
     else if( state->align.horzAlignment == center )
       x -= getTextWidth(string, stringlength ) >> 1;

     // Align vertically
     y += roundf( font.getVertAlign(state->align, state->size ) );

     subpixel = 0;
     for( index = 0 ; index < stringlength ; index++ )
     {
       if( decodeUTF8( (byte)string[index], &utf8state, &codepoint ) )
         continue;
       glyph = getGlyph(font, codepoint, state->size, subpixel, blurradius, blurscale );
       if( glyph )
       {
         font.addKerning(prevGlyphIndex, glyph, &x, &subpixel );
         drawTextGlyph(font, glyph, x, y );
         addGlyphAdvance( &x, &subpixel, glyph );
       }
       prevGlyphIndex = ( glyph ? glyph->glyphindex : -1 );
     }

     return x + ( subpixel >= 32 );
   }

   int drawTextWithCursor( int x, int y, const char *string, int stringlength, int cursoroffset )
   {
     int subpixel, index;
     FMState *state;
     unichar codepoint;
     uint32 utf8state;
     FMGlyph *glyph;
     int prevGlyphIndex;
     int blurradius, blurscale;
     FMFont font;

     state = &states[ nstates - 1 ];
     glyph = 0;
     utf8state = 0;
     prevGlyphIndex = -1;
     blurradius = state->blurradius;
     blurscale = state->blurscale;
     if( !( state->font ) )
       return x;
     font = state->font;
     if( !( stringlength ) )
       stringlength = strlen( string );

     // Align horizontally
     if( state->align.horzAlignment == right )
       x -= getTextWidth(string, stringlength );
     else if( state->align.horzAlignment == center )
       x -= getTextWidth(string, stringlength ) >> 1;

     // Align vertically
     y += roundf( font.getVertAlign(state->align, state->size ) );

     subpixel = 0;
     for( index = 0 ; ; index++ )
     {
       if( index == cursoroffset )
       {
         glyph = getGlyph(font, FM_GLYPH_CODEPOINT_CURSOR, state->size, subpixel, blurradius, blurscale );
         if( glyph )
           drawTextCursorGlyph(font, glyph, x, y );
       }
       if( index >= stringlength )
         break;
       if( decodeUTF8( (byte)string[index], &utf8state, &codepoint ) )
         continue;
       glyph = getGlyph(font, codepoint, state->size, subpixel, blurradius, blurscale );
       if( glyph )
       {
         font.addKerning(prevGlyphIndex, glyph, &x, &subpixel );
         drawTextGlyph(font, glyph, x, y );
         addGlyphAdvance( &x, &subpixel, glyph );
       }
       prevGlyphIndex = ( glyph ? glyph->glyphindex : -1 );
     }

     return x + ( subpixel >= 32 );
   }

   int drawTextTruncate( int x, int y, int truncatewidth, const char *string, int stringlength, char *extstring, int extwidth )
   {
     int subpixel, index, textwidth, truncatepoint;
     FMState *state;
     unichar codepoint;
     uint32 utf8state;
     FMGlyph *glyph;
     int prevGlyphIndex;
     int blurradius, blurscale;
     FMFont font;

     state = &states[ nstates - 1 ];
     glyph = 0;
     utf8state = 0;
     prevGlyphIndex = -1;
     blurradius = state->blurradius;
     blurscale = state->blurscale;
     if( !( state->font ) )
       return x;
     font = state->font;
     if( !( stringlength ) )
       stringlength = strlen( string );
     textwidth = getTextWidthTruncate(string, stringlength, truncatewidth );

     truncatepoint = x + truncatewidth;
     if( textwidth <= truncatewidth )
       extstring = 0;
     else
     {
       if( extwidth >= truncatewidth )
         return x;
       truncatepoint -= extwidth;
     }

     // Align horizontally
     if( state->align.horzAlignment == right )
       x -= textwidth;
     else if( state->align.horzAlignment == center )
       x -= textwidth >> 1;

     // Align vertically
     y += roundf( font.getVertAlign(state->align, state->size ) );

     subpixel = 0;
     for( index = 0 ; index < stringlength ; index++ )
     {
       if( decodeUTF8( (byte)string[index], &utf8state, &codepoint ) )
         continue;
       glyph = getGlyph(font, codepoint, state->size, subpixel, blurradius, blurscale );
       if( glyph )
       {
         font.addKerning(prevGlyphIndex, glyph, &x, &subpixel );
         drawTextGlyph(font, glyph, x, y );
         addGlyphAdvance( &x, &subpixel, glyph );
         if( x > truncatepoint )
           break;
       }
       prevGlyphIndex = ( glyph ? glyph->glyphindex : -1 );
     }
     x += ( subpixel >= 32 );
     if( extstring )
       drawText(x, y, extstring, 0 );

     return x;
   }


   ////


   // Measure text
   int getTextWidth( const char *string, int stringlength )
   {
     return getTextWidthTruncate(string, stringlength, ( (unsigned)1 << ( ( sizeof(int) * CHAR_BIT ) - 1 ) ) - 1 );
   }


   int getTextWidthTruncate( const char *string, int stringlength, int truncatewidth )
   {
     int subpixel, index, advance;
     FMState *state;
     unichar codepoint;
     uint32 utf8state;
     FMGlyph *glyph;
     int prevGlyphIndex;
     int blurradius, blurscale;
     FMFont font;

     state = &states[ nstates - 1 ];
     glyph = 0;
     utf8state = 0;
     prevGlyphIndex = -1;
     blurradius = state->blurradius;
     blurscale = state->blurscale;
     if( !( state->font ) )
       return 0;
     font = state->font;
     if( !( stringlength ) )
       stringlength = strlen( string );

     advance = 0;
     subpixel = 0;
     for( index = 0 ; index < stringlength ; index++ )
     {
       if( decodeUTF8( (byte)string[index], &utf8state, &codepoint ) )
         continue;
       glyph = getGlyph(font, codepoint, state->size, subpixel, blurradius, blurscale );
       if( glyph )
       {
         font.addKerning(prevGlyphIndex, glyph, &advance, &subpixel );
         addGlyphAdvance( &advance, &subpixel, glyph );
         if( advance > truncatewidth )
           break;
       }
       prevGlyphIndex = ( glyph ? glyph->glyphindex : -1 );
     }

     return advance + ( subpixel >= 32 );
   }

   int getTextBounds( int x, int y, const char *string, int stringlength, int *bounds )
   {
     int subpixel, index;
     FMState *state;
     unichar codepoint;
     uint32 utf8state;
     FMQuad q;
     FMGlyph *glyph;
     int prevGlyphIndex;
     int blurradius, blurscale;
     FMFont font;
     int startx, advance;
     int minx, miny, maxx, maxy;

     state = &states[ nstates - 1 ];
     glyph = 0;
     utf8state = 0;
     prevGlyphIndex = -1;
     blurradius = state->blurradius;
     blurscale = state->blurscale;
     if( !( state->font ) )
       return x;
     font = state->font;
     if( !( stringlength ) )
       stringlength = strlen( string );

     // Align vertically
     y += font.getVertAlign(state->align, state->size );

     minx = maxx = x;
     miny = maxy = y;
     startx = x;

     subpixel = 0;
     for( index = 0 ; index < stringlength ; index++ )
     {
       if( decodeUTF8( (byte)string[index], &utf8state, &codepoint ) )
         continue;
       glyph = getGlyph(font, codepoint, state->size, subpixel, blurradius, blurscale );
       if( glyph )
       {
         font.addKerning(prevGlyphIndex, glyph, &x, &subpixel );
         glyph->getQuad(x, y, q);
         if( q.x0 < minx )
           minx = q.x0;
         if( q.x1 > maxx )
           maxx = q.x1;
         if( q.y0 < miny )
           miny = q.y0;
         if( q.y1 > maxy )
           maxy = q.y1;
         addGlyphAdvance( &x, &subpixel, glyph );
       }
       prevGlyphIndex = ( glyph ? glyph->glyphindex : -1 );
     }

     advance = x - startx;

     /* Align horizontally */
     if( state->align.horzAlignment == right )
     {
       minx -= advance;
       maxx -= advance;
     }
     else if( state->align.horzAlignment == center )
     {
       minx -= advance * 0.5f;
       maxx -= advance * 0.5f;
     }

     if( bounds )
     {
       bounds[0] = minx;
       bounds[1] = maxx;
       bounds[2] = miny;
       bounds[3] = maxy;
     }

     return advance + ( subpixel >= 32 );
   }

   // Find text offset up to truncatewidth
   int getTextTruncateOffset( int truncatewidth, const char *string, int stringlength, int extwidth, int *retextflag, int *retfullwidth )
   {
     int subpixel, index, advance, truncatewidthext, truncateindex, extflag, fullwidth = 0;
     FMState *state;
     unichar codepoint;
     uint32 utf8state;
     FMGlyph *glyph;
     int prevGlyphIndex;
     int blurradius, blurscale;
     FMFont font;

     state = &states[ nstates - 1 ];
     if( retextflag )
       *retextflag = 0;
     if( retfullwidth )
       *retfullwidth = 0;
     if( extwidth >= truncatewidth )
       return 0;
     glyph = 0;
     utf8state = 0;
     prevGlyphIndex = -1;
     blurradius = state->blurradius;
     blurscale = state->blurscale;
     if( !( state->font ) )
       return 0;
     font = state->font;
     if( stringlength <= 0 )
       stringlength = strlen( string );

     truncatewidthext = truncatewidth - extwidth;

     advance = 0;
     subpixel = 0;
     truncateindex = 0;
     extflag = 0;
     for( index = 0 ; ; index++ )
     {
       if( index >= stringlength )
       {
         truncateindex = index;
         fullwidth = advance + ( subpixel >= 32 );
         break;
       }
       if( decodeUTF8( (byte)string[index], &utf8state, &codepoint ) )
         continue;
       glyph = getGlyph(font, codepoint, state->size, subpixel, blurradius, blurscale );
       if( glyph )
       {
         font.addKerning(prevGlyphIndex, glyph, &advance, &subpixel );
         addGlyphAdvance( &advance, &subpixel, glyph );
         if( advance > truncatewidth )
         {
           extflag = 1;
           break;
         }
         if( advance <= truncatewidthext )
         {
           truncateindex = index + 1;
           fullwidth = advance + ( subpixel >= 32 );
         }
       }
       prevGlyphIndex = ( glyph ? glyph->glyphindex : -1 );
     }

     if( retfullwidth )
     {
       if( extflag )
         *retfullwidth = fullwidth;
       else
         *retfullwidth = fullwidth;
     }
     if( retextflag )
       *retextflag = extflag;

     return truncateindex;
   }

   // Find text offset nearest to the given width
   int getTextNearestOffset( int targetwidth, const char *string, int stringlength )
   {
     int subpixel, index, advance, truncateindex, distance, bestdistance;
     FMState *state;
     unichar codepoint;
     uint32 utf8state;
     FMGlyph *glyph;
     int prevGlyphIndex;
     int blurradius, blurscale;
     FMFont font;

     state = &states[ nstates - 1 ];
     glyph = 0;
     utf8state = 0;
     prevGlyphIndex = -1;
     blurradius = state->blurradius;
     blurscale = state->blurscale;
     if( !( state->font ) )
       return 0;
     font = state->font;
     if( stringlength <= 0 )
       stringlength = strlen( string );

     advance = 0;
     subpixel = 0;
     truncateindex = 0;
     bestdistance = abs( targetwidth );
     for( index = 0 ; index < stringlength ; index++ )
     {
       if( decodeUTF8( (byte)string[index], &utf8state, &codepoint ) )
         continue;
       glyph = getGlyph(font, codepoint, state->size, subpixel, blurradius, blurscale );
       if( glyph )
       {
         font.addKerning(prevGlyphIndex, glyph, &advance, &subpixel );
         addGlyphAdvance( &advance, &subpixel, glyph );
         distance = abs( targetwidth - ( advance + ( subpixel >= 32 ) ) );
         if( distance > bestdistance )
           break;
         bestdistance = distance;
         truncateindex = index + 1;
       }
       prevGlyphIndex = ( glyph ? glyph->glyphindex : -1 );
     }

     return truncateindex;
   }

   ////

   static void flush( bool rendererFlush )
   {
      // Flush texture updates
      if( ( dirtyrect[0] < dirtyrect[2] ) && ( dirtyrect[1] < dirtyrect[3] ) )
      {
         renderer.updateTexture( dirtyrect, texdata );
         // Reset dirty rect
         dirtyrect[0] = width;
         dirtyrect[1] = height;
         dirtyrect[2] = 0;
         dirtyrect[3] = 0;
      }
      // Flush buffered glyphs
      if( rendererFlush ) renderer.flush( );
   }

   // Flush buffered texture updates, renderer->updateTexture()
   void flushUpdate( )
   {
      flush(false );
   }

   ////

   // Text metrics

   void getFontExtent( int *retascent, int *retdescent )
   {
     FMFont font;
     FMState *state = &states[ nstates - 1 ];
     if(state->font)
     {
         font = state->font;

         if( retascent )
            *retascent = -(int)ceilf( font.ascender * (float)state->size );
         if( retdescent )
            *retdescent = -(int)floorf( font.descender * (float)state->size );
      }
   }

   void fmGetFontLimits( int *retlimitminy, int *retlimitmaxy )
   {
     FMFont font;
     FMState *state;

     state = &states[ nstates - 1 ];
     if( !( state->font ) )
       return;
     font = state->font;

     if( retlimitminy )
       *retlimitminy = -(int)ceilf( font.limitmaxy * state->size );
     if( retlimitmaxy )
       *retlimitmaxy = -(int)floorf( font.limitminy * state->size );

     return;
   }

   int getFontLineHeight( )
   {
     FMFont font;
     FMState *state;

     state = &states[ nstates - 1 ];
     if( !( state->font ) )
       return 0 ;
     font = state->font;
     return (int)ceilf( font.lineHeight * state->size );
   }


   ////

   // Pull texture changes
   const byte *getTextureData( int *width, int *height )
   {
      if( width )
         *width = this.width;
      if( height )
         *height = this.height;
      return texdata;
   }

   // Retrieve the dirty rectangle, telling fontmanager you will manually perform the update, returns 0 if no part of the texture requires an update
   bool validateTexture( int *retdirtyrect )
   {
      if( ( dirtyrect[0] < dirtyrect[2] ) && ( dirtyrect[1] < dirtyrect[3] ) )
      {
         retdirtyrect[0] = dirtyrect[0];
         retdirtyrect[1] = dirtyrect[1];
         retdirtyrect[2] = dirtyrect[2];
         retdirtyrect[3] = dirtyrect[3];
         // Reset dirty rect
         dirtyrect[0] = width;
         dirtyrect[1] = height;
         dirtyrect[2] = 0;
         dirtyrect[3] = 0;
         return true;
      }
      return false;
   }

   // Returns current atlas size
   void getAtlasSize( int *retwidth, int *retheight )
   {
     *retwidth = this.width;
     *retheight = this.height;
     return;
   }

   // Expands the atlas size
   bool expandAtlas( int width, int height )
   {
      width = Max( width, this.width );
      height = Max( height, this.height );

      if( ( width == this.width ) && ( height == this.height ) )
         return true;

      // Flush all pending glyphs
      flush(true);

      // Create new texture
      if( renderer.resizeTexture( width, height ) )
      {
         byte *data;
         int i;

         // Copy old texture data over.
         if( !( data = (byte *)malloc( width * height ) ) )
            return false;
         for( i = 0 ; i < this.height ; i++ )
         {
            byte * dst = &data[ i * width ];
            byte * src = &this.texdata[ i * this.width ];
            memcpy( dst, src, this.width );
            if( width > this.width )
               memset( dst+this.width, 0, width - this.width );
         }
         if( height > this.height )
            memset( &data[ this.height * width ], 0, ( height - this.height ) * width );

         delete this.texdata;
         texdata = data;

         // Increase atlas size
         atlas.expand( width, height );

         // Add existing data as dirty.
         dirtyrect[0] = 0;
         dirtyrect[1] = 0;
         dirtyrect[2] = this.width;
         dirtyrect[3] = atlas.getAtlasMaxHeight();

         this.width = width;
         this.height = height;
         widthinv = 1.0f / this.width;
         heightinv = 1.0f / this.height;

         return true;
      }
      return false;
   }

   // Reset the whole fm
   bool resetAtlas( int width, int height )
   {
      // Flush all pending glyphs
      flush(true);

      // Create new texture
      if(renderer.resizeTexture( width, height ) )
      {
         // Reset atlas
         atlas.reset( width, height );

         // Clear texture data.
         texdata = renew texdata byte[width * height];
         if(!texdata) return 0;
         memset( this.texdata, 0, width * height );

         // Reset dirty rect
         dirtyrect[0] = width;
         dirtyrect[1] = height;
         dirtyrect[2] = 0;
         dirtyrect[3] = 0;

         // Reset cached glyphs
         for(font : fontList)
         {
            int i;
            font.glyphcount = 0;
            for( i = 0 ; i < FM_HASH_TABLE_SIZE ; i++ )
               font.hashtable[i] = -1;
         }
         renderer.resetImages( );

         this.width = width;
         this.height = height;
         this.widthinv = 1.0f / this.width;
         this.heightinv = 1.0f / this.height;

         // Add white rect at 0,0 for debug drawing.
      #if FM_DEBUG_WHITERECT
         fmAddWhiteRect(2, 2 );
      #endif

         return true;
      }
      return false;
   }

   ////
   bool initPathDraw( FMPathDraw pathdraw )
   {
     FMState *state = &states[ nstates - 1 ];
     FMFont font = state->font;
     if(font)
     {
        pathdraw.prevGlyphIndex = -1;
        pathdraw.middleAlign = font.middleAlign * (float)state->size;
        return true;
     }
     return false;
   }

   float pathDrawCharacter( FMPathDraw pathdraw, float x, float y, float vectorx, float vectory, int unicode )
   {
      int subpixel;
      FMState *state = &states[ nstates - 1 ];
      int blurradius = state->blurradius;
      int blurscale = state->blurscale;
      FMFont font = state->font;
      FMGlyph *glyph = getGlyph(font, unicode, state->size, 0, blurradius, blurscale );
      if( glyph )
      {
         subpixel = font.ftFont.getGlyphKernAdvance( pathdraw.prevGlyphIndex, glyph->glyphindex );
         drawTextGlyphFloat(font, glyph, x, y, vectorx, vectory, (float)subpixel * (1.0f/64.0f), pathdraw.middleAlign );
         subpixel += glyph->advance;
         pathdraw.prevGlyphIndex = glyph->glyphindex;
      }
      else
      {
         subpixel = 0;
         pathdraw.prevGlyphIndex = -1;
      }

      return (float)subpixel * (1.0f/64.0f);
   }

   float pathDrawPredictAdvance( FMPathDraw pathdraw, unichar unicode )
   {
      int subpixel = 0;
      FMState *state = &states[ nstates - 1 ];
      FMFont font = state->font;
      int blurradius = state->blurradius;
      int blurscale = state->blurscale;
      FMGlyph *glyph = getGlyph(font, unicode, state->size, 0, blurradius, blurscale );
      if( glyph )
      {
         subpixel = font.ftFont.getGlyphKernAdvance( pathdraw.prevGlyphIndex, glyph->glyphindex );
         subpixel += glyph->advance;
      }
      return (float)subpixel * (1.0f/64.0f);
   }
}
