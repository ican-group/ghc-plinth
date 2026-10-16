// ---------------------------------------------------------------------------
// Shared palette, geometry and lighting for the Plinth marks.
//
// Included by plinth-logo.pov (the wordmark) and plinth-icon.pov (the favicon)
// so the two cannot drift apart. Palette taken from the project site,
// ican-group.github.io/ghc-plinth.
//
// Options, set with Declare= on the command line before the include runs:
//   Motif   1 = the I of the wordmark is a plinth in miniature, 0 = plain I
//   Theme   0 = coral on near-white, 1 = white on charcoal
// ---------------------------------------------------------------------------

#version 3.7;

#ifndef (Motif)
  #declare Motif = 1;
#end
#ifndef (Theme)
  #declare Theme = 0;
#end

global_settings {
  assumed_gamma 1.0
  max_trace_level 10
  radiosity {
    pretrace_start 0.08
    pretrace_end   0.01
    count 250
    error_bound 0.35
    recursion_limit 2
    #if (Theme = 0) brightness 0.48 #else brightness 0.85 #end
    nearest_count 8
    low_error_factor 0.5
  }
}

#default { finish { ambient 0 emission 0 } }

// ---------------------------------------------------------------------------
// Note [sRGB hex under assumed_gamma 1.0]
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// The renderer works in linear light, so a hex colour taken from a stylesheet
// has to be de-gamma'd or it comes out washed out and pale. Srgb() applies the
// standard sRGB transfer curve, which lets the palette below be written as the
// literal values from the site's CSS.
// ---------------------------------------------------------------------------
#macro Srgb(V)
  rgb <
    select(V.x - 0.04045, V.x / 12.92, pow((V.x + 0.055) / 1.055, 2.4)),
    select(V.y - 0.04045, V.y / 12.92, pow((V.y + 0.055) / 1.055, 2.4)),
    select(V.z - 0.04045, V.z / 12.92, pow((V.z + 0.055) / 1.055, 2.4))
  >
#end

// --- palette ---------------------------------------------------------------
#declare C_Coral  = Srgb(<0.988, 0.302, 0.314>);   // #fc4d50  accent
#declare C_White  = Srgb(<1.000, 1.000, 1.000>);   // #ffffff
#declare C_Pale   = Srgb(<0.949, 0.949, 0.949>);   // #f2f2f2  page grey
#declare C_Ink    = Srgb(<0.133, 0.133, 0.133>);   // #222222  body text

// Deeper shade of each body colour, used low on the faces so they do not go
// flat where the floor bounce runs out. (Srgb() expands to an "rgb" literal,
// which POV-Ray will not accept as a term inside a larger arithmetic
// expression, so these are written out rather than derived by multiplying.)
#declare C_CoralLo = Srgb(<0.788, 0.227, 0.243>);   // #c93a3e
#declare C_WhiteLo = Srgb(<0.760, 0.775, 0.800>);

// Note [Hitting the brand colour]
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Painting a surface with the brand hex does not render as the brand hex: a
// matte surface returns less than its own albedo, while the neutral fill and
// the sky bounce lift green and blue, so #fc4d50 comes back as a dull #e75a5c.
// C_CoralLit is that measured error divided back out of the albedo, which puts
// the lit faces on #fc4d50. There is one per theme because each theme has its
// own key level and its own amount of bounce, and the correction is only valid
// for the rig it was measured against -- change the lighting and re-measure by
// sampling the dominant coral in the render. C_Coral stays as the true
// stylesheet value, for flat fills that no light touches.
#declare C_CoralLit     = Srgb(<1.000, 0.205, 0.225>);  // #ff343a, light rig
#declare C_CoralLitDark = Srgb(<1.000, 0.138, 0.157>);  // #ff2328, dark rig

#if (Theme = 0)
  #declare C_Body   = C_CoralLit;   // the plain letters
  #declare C_BodyLo = C_CoralLo;
  #declare C_Col    = C_White;      // the plinth, as on the favicon tile
  #declare C_ColLo  = C_WhiteLo;
  #declare C_Ground = C_Pale;
  #declare C_Far    = Srgb(<0.870, 0.875, 0.885>);
  #declare C_SkyLo  = Srgb(<0.780, 0.790, 0.810>);
  #declare C_SkyMid = Srgb(<0.880, 0.888, 0.900>);
  #declare C_SkyHi  = Srgb(<0.960, 0.964, 0.972>);
  #declare Key      = 0.92;
#else
  #declare C_Body   = C_White;
  #declare C_BodyLo = Srgb(<0.560, 0.575, 0.605>);
  #declare C_Col    = C_CoralLitDark;
  #declare C_ColLo  = C_CoralLo;
  #declare C_Ground = C_Ink;
  #declare C_Far    = Srgb(<0.180, 0.184, 0.196>);
  #declare C_SkyLo  = Srgb(<0.090, 0.094, 0.106>);
  #declare C_SkyMid = Srgb(<0.160, 0.165, 0.180>);
  #declare C_SkyHi  = Srgb(<0.235, 0.242, 0.260>);
  #declare Key      = 1.22;
#end

// --- typography ------------------------------------------------------------
#declare FontFile = "/usr/share/fonts/liberation/LiberationSans-Bold.ttf";
#declare Thick    = 0.30;    // extrusion depth, in em
#declare Trk      = 0.075;   // tracking between glyphs, in em
#declare Scl      = 2.40;    // em -> scene units

#declare NC    = 6;
#declare Chars = array[NC] { "P", "L", "I", "N", "T", "H" }
#declare Wid   = array[NC];

// Cap height, and the ink width of every glyph, straight from the outlines.
#declare Probe = text { ttf FontFile "H", Thick, 0 }
#declare CapH  = max_extent(Probe).y;

#declare i = 0;
#while (i < NC)
  #declare Probe  = text { ttf FontFile Chars[i], Thick, 0 }
  #declare Wid[i] = max_extent(Probe).x - min_extent(Probe).x;
  #declare i = i + 1;
#end

#declare ColW = 0.34;                  // the plinth is wider than a plain I
#if (Motif = 1)
  #declare Wid[2] = ColW;
#end

#declare TotW = Trk * (NC - 1);
#declare i = 0;
#while (i < NC)
  #declare TotW = TotW + Wid[i];
  #declare i = i + 1;
#end

// ---------------------------------------------------------------------------
// Note [Faking a bevel on POV-Ray text]
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// text{} extrudes an outline with flat, hard-edged faces and POV-Ray has no
// outline-offset operator. So the chamfer is built by stacking thin, slightly
// shrunken copies of the same glyph on the front and back of a shorter core:
//
//        |####|     <- 0.938 scale, thinnest slice   \
//       |######|    <- 0.972 scale                    |  chamfer
//     |##########|  <- core, 80% of the depth        /
//
// Shrinking is centred on the glyph, so the inset is proportional rather than
// a true offset -- at these amounts (~1% of the glyph) that is invisible, and
// the two extra facets are what catch the highlight along every edge.
// ---------------------------------------------------------------------------
#macro Beveled(Ch)
  #local G0 = text { ttf FontFile Ch, Thick, 0 }
  #local mn = min_extent(G0);
  #local mx = max_extent(G0);
  #local cx = (mn.x + mx.x) / 2;
  #local cy = (mn.y + mx.y) / 2;
  #local G  = object { G0 translate <-cx, -cy, -Thick / 2> }
  merge {
    object { G scale <1.000, 1.000, 0.80> }
    object { G scale <0.972, 0.972, 0.06> translate -z * Thick * 0.43 }
    object { G scale <0.938, 0.938, 0.05> translate -z * Thick * 0.475 }
    object { G scale <0.972, 0.972, 0.06> translate  z * Thick * 0.43 }
    object { G scale <0.938, 0.938, 0.05> translate  z * Thick * 0.475 }
    translate y * cy          // back onto the baseline, centred on x = 0
  }
#end

// A rounded block: SX/SZ are half extents, the block spans [Y0,Y1].
#macro Slab(SX, SZ, Y0, Y1, Round)
  superellipsoid {
    <Round, Round>
    scale <SX, (Y1 - Y0) / 2, SZ>
    translate y * (Y0 + Y1) / 2
  }
#end

// ---------------------------------------------------------------------------
// The plinth itself: base, shaft, cap, standing on y=0 and centred on x=0,
// W wide and D deep, always CapH tall so it lines up with the letters.
//
// Fine=1 adds the two slim transition mouldings. They read at wordmark size,
// but on a 16px favicon they turn to mush, so the icon asks for Fine=0 and a
// chunkier shaft instead -- the proportions of the existing flat mark.
// ---------------------------------------------------------------------------
#macro PlinthColumn(W, D, Fine)
  #local HX  = W / 2;
  #local HZ  = D / 2;
  #local Bh  = CapH * (Fine = 1 ? 0.077 : 0.190);   // base slab height
  #local Ch  = CapH * (Fine = 1 ? 0.070 : 0.165);   // cap slab height
  #local Sw  = W * (Fine = 1 ? 0.50 : 0.44);        // shaft width
  #local CapX = HX - (Fine = 1 ? 0.010 : W * 0.055);// cap reads narrower than base
  #local Trn = CapH * 0.056;                        // transition moulding
  #local S0  = Bh + (Fine = 1 ? Trn : 0);
  #local S1  = CapH - Ch - (Fine = 1 ? Trn : 0);
  union {
    object { Slab(HX, HZ, 0, Bh, 0.06) }
    #if (Fine = 1)
      object { Slab(HX - 0.030, HZ - 0.02, Bh,      S0,        0.16) }
      object { Slab(HX - 0.040, HZ - 0.02, S1,      CapH - Ch, 0.16) }
    #end
    object { Slab(Sw / 2,       HZ - 0.05, S0,      S1,        0.05) }
    object { Slab(CapX,         HZ,        CapH-Ch, CapH,      0.06) }
  }
#end

// --- materials -------------------------------------------------------------
// One matte ceramic, taking its colour and its deeper shade as arguments, so
// the letters and the plinth are the same material in two finishes.
#macro Ceramic(Top, Base, Gloss)
  texture {
    pigment {
      gradient y
      color_map {
        [0.00 Base]
        [0.25 Top]
        [1.00 Top]
      }
      scale CapH * 1.15
    }
    finish {
      // High diffuse: see Note [Hitting the brand colour].
      diffuse 0.82
      brilliance 1.05
      specular albedo Gloss
      roughness 0.040
      reflection { 0.015, 0.09 fresnel on }
      conserve_energy
    }
  }
#end

#declare T_Letter = Ceramic(C_Body, C_BodyLo, 0.30)
#declare T_Column = Ceramic(C_Col,  C_ColLo,  0.42)   // a touch more polished

// ---------------------------------------------------------------------------
// The set: a seamless floor and an open sky, i.e. a soft-box studio.
//
// Visible=0 keeps the floor out of the frame while it still bounces light and
// blocks it, which is what the icon wants: a transparent background but the
// same fill from below as the wordmark gets.
// ---------------------------------------------------------------------------
#macro StudioFloor(Visible)
  plane {
    y, 0
    texture {
      // Note [No horizon]
      // ~~~~~~~~~~~~~~~~~
      // A plain floor plane meets the sky in a hard line right behind the
      // subject. Fading the floor colour into the backdrop colour with
      // distance dissolves that line, giving the sweep of a real studio.
      pigment {
        gradient z
        color_map {
          [0.00 C_Ground]
          [0.62 C_Ground]
          [1.00 C_Far]
        }
        scale 110
      }
      finish {
        diffuse 0.80
        specular albedo 0.10
        roughness 0.10
        reflection { 0.012, 0.10 fresnel on }
        conserve_energy
      }
    }
    interior { ior 1.45 }
    #if (Visible = 0) no_image #end
  }
#end

#macro StudioSky()
  sky_sphere {
    pigment {
      gradient y
      color_map {
        [0.00 C_SkyLo]
        [0.48 C_SkyMid]
        [0.58 C_SkyHi]
        [1.00 C_SkyMid]
      }
      scale 2
      translate -y
    }
  }
#end

// Three lights, scaled by Key. Sizes are in scene units, so a scene that
// frames a smaller subject passes a smaller Spread to keep the shadows
// equally soft relative to the subject.
#macro StudioLights(Spread)
  // key: high front left, big and soft, for one clean shadow
  light_source {
    <-14, 13, -15> * Spread
    color rgb <1.00, 0.99, 0.97> * Key
    area_light x * 6 * Spread, y * 6 * Spread, 5, 5
    adaptive 1
    circular orient
    jitter
  }

  // fill from camera right, keeps the returns open
  light_source {
    <16, 6, -13> * Spread
    color rgb <1.00, 0.96, 0.95> * Key * 0.26
    area_light x * 5 * Spread, y * 5 * Spread, 3, 3
    adaptive 1
    circular orient
    jitter
  }

  // rim from behind, separates the subject from the backdrop
  light_source {
    <5, 9, 14> * Spread
    color rgb <1.00, 0.97, 0.96> * Key * 0.38
    area_light x * 5 * Spread, y * 5 * Spread, 3, 3
    adaptive 1
    circular orient
    jitter
  }
#end
