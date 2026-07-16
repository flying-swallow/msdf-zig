// Reference-bitmap dumper for the msdf-zig differential tests.
//
// Generates SDFs with msdfgen (the C++ original) using a pipeline that mirrors
// src/Generator.zig exactly, and writes the raw f32 bitmaps as golden fixtures.
// The Zig test suite compares against those fixtures, so it stays hermetic and
// CI does not need a C++ toolchain. Rerun this only when bumping msdfgen.
//
// See tools/oracle/README.md for the build command.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <msdfgen.h>
#include <msdfgen-ext.h>

using namespace msdfgen;

namespace {

enum SdfType { SDF, PSDF, MSDF, MTSDF };

struct Config {
    const char *name;
    const char *fontPath;
    unicode_t codepoint;
    SdfType type;
    int pxSize;
    int pxRange;
    bool errorCorrection;
    bool geometryPreprocess;
    bool scanlineFillRule;
    FillRule fillRule;
};

int channelsOf(SdfType type) {
    switch (type) {
        case SDF: case PSDF: return 1;
        case MSDF: return 3;
        case MTSDF: return 4;
    }
    return 0;
}

// Mirrors Generator.zig:264-267. Only consulted for orientation == .guess,
// which is the Zig default.
Point2 outOfBoundsPoint(const Shape::Bounds &b) {
    return Point2(b.l-(b.r-b.l)-1, b.b-(b.t-b.b)-1);
}

// Mirrors Generator.zig:758-766 (findDistanceAt).
double distanceAt(const Shape &shape, Point2 p, double pxRange) {
    SignedDistance minDist;
    for (const Contour &contour : shape.contours) {
        for (const EdgeHolder &edge : contour.edges) {
            double dummy = 0;
            SignedDistance d = edge->signedDistance(p, dummy);
            if (d < minDist)
                minDist = d;
        }
    }
    return (minDist.distance+pxRange/2)/pxRange;
}

bool writeFixture(const std::string &path, const std::vector<float> &pixels, int w, int h, int channels) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) {
        fprintf(stderr, "oracle: cannot open %s for writing\n", path.c_str());
        return false;
    }
    // Header: magic, then i32 width, height, channels. Little-endian; the Zig
    // reader asserts on the magic so a stale/corrupt fixture fails loudly.
    const char magic[8] = { 'M', 'S', 'D', 'F', 'Z', 'I', 'G', '1' };
    int32_t dims[3] = { w, h, channels };
    bool ok = fwrite(magic, 1, sizeof(magic), f) == sizeof(magic)
           && fwrite(dims, sizeof(int32_t), 3, f) == 3
           && fwrite(pixels.data(), sizeof(float), pixels.size(), f) == pixels.size();
    fclose(f);
    if (!ok)
        fprintf(stderr, "oracle: short write to %s\n", path.c_str());
    return ok;
}

bool generateOne(const Config &cfg, const std::string &outDir, FreetypeHandle *ft) {
    FontHandle *font = loadFont(ft, cfg.fontPath);
    if (!font) {
        fprintf(stderr, "oracle: cannot load font %s\n", cfg.fontPath);
        return false;
    }

    Shape shape;
    // EM_NORMALIZED == the Zig's `scale = 1.0/unitsPerEM` applied at decompose
    // time (Generator.zig:215). NOT the LEGACY /64 default.
    if (!loadGlyph(shape, font, cfg.codepoint, FONT_SCALING_EM_NORMALIZED)) {
        fprintf(stderr, "oracle: cannot load glyph U+%04X from %s\n", cfg.codepoint, cfg.fontPath);
        destroyFont(font);
        return false;
    }
    destroyFont(font);

    if (!shape.validate()) {
        fprintf(stderr, "oracle: invalid shape for U+%04X\n", cfg.codepoint);
        return false;
    }

    // Order matches Generator.zig:249-250: orient before normalize.
    if (cfg.geometryPreprocess)
        shape.orientContours();
    shape.normalize();

    double pxSize = cfg.pxSize;
    double pxRange = cfg.pxRange/pxSize;

    Shape::Bounds bounds = shape.getBounds();
    if (bounds.l >= bounds.r || bounds.b >= bounds.t)
        bounds.l = 0, bounds.b = 0, bounds.r = 1, bounds.t = 1;

    double tx = -bounds.l+pxRange/2;
    double ty = -bounds.b+pxRange/2;
    int w = (int) ((bounds.r-bounds.l+pxRange)*pxSize);
    int h = (int) ((bounds.t-bounds.b+pxRange)*pxSize);
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "oracle: degenerate bitmap %dx%d for %s\n", w, h, cfg.name);
        return false;
    }

    // The Zig inverts the whole bitmap when the shape reads as inside-out at a
    // far out-of-bounds probe point (Generator.zig:557-558).
    Point2 oob = outOfBoundsPoint(bounds);
    double oobDist = distanceAt(shape, oob, pxRange);
    bool invert = oobDist > 0;
    if (getenv("ORACLE_DEBUG")) {
        fprintf(stderr, "[dbg] %-20s bounds l=%.4f b=%.4f r=%.4f t=%.4f  tx=%.4f ty=%.4f  %dx%d\n",
            cfg.name, bounds.l, bounds.b, bounds.r, bounds.t, tx, ty, w, h);
        fprintf(stderr, "[dbg] %-20s oob=(%.4f, %.4f) oobDist=%.6f invert=%d  contours=%d\n",
            cfg.name, oob.x, oob.y, oobDist, (int) invert, (int) shape.contours.size());
    }

    Projection projection(Vector2(pxSize), Vector2(tx, ty));
    // DistanceMapping(Range) maps distance -> [0,1], which is the direction the
    // generators write. DistanceMapping::inverse(Range) is the other direction
    // ([0,1] -> distance) and would silently produce an all-outside field.
    // Matches how msdfgen's own main.cpp:1264 builds this.
    SDFTransformation transformation(projection, Range(pxRange));

    MSDFGeneratorConfig genConfig;
    genConfig.overlapSupport = false; // msdf-zig has no contour combiners
    genConfig.errorCorrection.mode = cfg.errorCorrection
        ? ErrorCorrectionConfig::EDGE_PRIORITY
        : ErrorCorrectionConfig::DISABLED;
    // msdf-zig's check_distance defaults to ON and is forced OFF when a scanline
    // pass runs (ErrorCorrection.zig:28, 73-76). It runs a single findErrors with
    // the shape-distance check folded into the classifier (ErrorCorrection.zig:109),
    // which is what ALWAYS_CHECK_DISTANCE does here -- CHECK_DISTANCE_AT_EDGE would
    // additionally run the shapeless pass and protectAll.
    genConfig.errorCorrection.distanceCheckMode = cfg.scanlineFillRule
        ? ErrorCorrectionConfig::DO_NOT_CHECK_DISTANCE
        : ErrorCorrectionConfig::ALWAYS_CHECK_DISTANCE;

    int channels = channelsOf(cfg.type);
    std::vector<float> flat;

    // Order matters and mirrors Generator.zig:559-597: the Zig applies the
    // orientation flip inside generate*() and only then runs the scanline sign
    // correction. Inverting afterwards instead gives a fully inverted field for
    // any face whose winding trips the flip (i.e. every CFF/PostScript outline).
    #define APPLY_INVERT(bmp, n) \
        do { \
            if (invert) \
                for (float *p = (float *) bmp, *end = p+(size_t) w*h*(n); p < end; ++p) \
                    *p = 1.f-*p; \
        } while (0)

    // Each branch generates, applies the optional scanline sign correction, and
    // flattens into `flat` with the Zig's row order (row 0 = shape top).
    #define FLATTEN(bmp) \
        do { \
            flat.resize((size_t) w*h*channels); \
            for (int y = 0; y < h; ++y) \
                for (int x = 0; x < w; ++x) \
                    for (int c = 0; c < channels; ++c) \
                        flat[(size_t) (h-y-1)*w*channels + (size_t) x*channels + c] = bmp(x, y)[c]; \
        } while (0)

    if (cfg.type == SDF || cfg.type == PSDF) {
        Bitmap<float, 1> bmp(w, h);
        if (cfg.type == SDF)
            generateSDF(bmp, shape, transformation, genConfig);
        else
            generatePSDF(bmp, shape, transformation, genConfig);
        APPLY_INVERT(bmp, 1);
        if (cfg.scanlineFillRule && !cfg.geometryPreprocess)
            distanceSignCorrection(bmp, shape, projection, .5f, cfg.fillRule);
        FLATTEN(bmp);
    } else if (cfg.type == MSDF) {
        edgeColoringSimple(shape, 3.0, 0);
        Bitmap<float, 3> bmp(w, h);
        generateMSDF(bmp, shape, transformation, genConfig);
        APPLY_INVERT(bmp, 3);
        if (cfg.scanlineFillRule && !cfg.geometryPreprocess)
            distanceSignCorrection(bmp, shape, projection, .5f, cfg.fillRule);
        FLATTEN(bmp);
    } else {
        edgeColoringSimple(shape, 3.0, 0);
        Bitmap<float, 4> bmp(w, h);
        generateMTSDF(bmp, shape, transformation, genConfig);
        APPLY_INVERT(bmp, 4);
        if (cfg.scanlineFillRule && !cfg.geometryPreprocess)
            distanceSignCorrection(bmp, shape, projection, .5f, cfg.fillRule);
        FLATTEN(bmp);
    }
    #undef FLATTEN
    #undef APPLY_INVERT

    if (getenv("ORACLE_DEBUG")) {
        fprintf(stderr, "[dbg] %s bitmap (channel 0, msdf-zig row order):\n", cfg.name);
        for (int y = 0; y < h; ++y) {
            fprintf(stderr, "[dbg] ");
            for (int x = 0; x < w; ++x) {
                float v = flat[(size_t) y*w*channels + (size_t) x*channels];
                fputc(v < .25f ? '.' : v < .5f ? '-' : v < .75f ? '+' : '#', stderr);
            }
            fputc('\n', stderr);
        }
    }

    std::string path = outDir+"/"+cfg.name+".bin";
    if (!writeFixture(path, flat, w, h, channels))
        return false;
    printf("  %-44s %3dx%-3d x%d\n", cfg.name, w, h, channels);
    return true;
}

} // namespace

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <font-dir> <out-dir>\n", argv[0]);
        return 1;
    }
    std::string fontDir = argv[1], outDir = argv[2];

    // Two faces on purpose. DM Serif Display is TrueType: its outlines are
    // entirely quadratic, so it never reaches the cubic code paths. TeX Gyre
    // Termes is CFF, i.e. all-cubic, and is the only thing here that exercises
    // CubicSegment::signedDistance and CubicSegment::bound.
    static std::string fontPaths[] = {
        fontDir+"/DMSerifDisplay-Regular.ttf",
        fontDir+"/texgyretermes-regular.otf",
    };
    const struct { const char *label; const std::string *path; } fonts[] = {
        { "tt", &fontPaths[0] },
        { "cff", &fontPaths[1] },
    };

    // example/generate.zig runs 64/8; the fixtures use half that at the same
    // ratio to keep the committed goldens small. ~400 texels per glyph is still
    // far more than enough to catch a distance-math regression.
    const int PX_SIZE = 32, PX_RANGE = 4;

    std::vector<Config> configs;
    struct GlyphSpec { const char *label; unicode_t cp; };
    // o/e exercise the 1-corner "teardrop" path; A/M multi-corner; @ nested contours.
    const GlyphSpec glyphs[] = {
        { "o", 'o' }, { "e", 'e' }, { "A", 'A' }, { "M", 'M' }, { "at", '@' },
    };
    const struct { const char *label; SdfType type; } types[] = {
        { "sdf", SDF }, { "psdf", PSDF }, { "msdf", MSDF }, { "mtsdf", MTSDF },
    };

    static std::vector<std::string> names; // must outlive `configs`
    names.reserve(1024);
    for (const auto &f : fonts) {
    for (const GlyphSpec &g : glyphs) {
        for (const auto &t : types) {
            for (int ec = 0; ec < 2; ++ec) {
                for (int geom = 0; geom < 2; ++geom) {
                    for (int scan = 0; scan < 2; ++scan) {
                        // Generator.zig:572 — the Zig ignores the fill rule when
                        // geometry preprocessing is on, so that combination is
                        // redundant. Skip it rather than bake in a duplicate.
                        if (scan && geom)
                            continue;
                        // Error correction only applies to MSDF/MTSDF (Generator.zig:547).
                        if (ec && !(t.type == MSDF || t.type == MTSDF))
                            continue;
                        names.push_back(std::string(f.label)+"_"+g.label+"_"+t.label
                            +(ec ? "_ec" : "")+(geom ? "_geom" : "")+(scan ? "_scanline" : ""));
                        Config c = {};
                        c.name = names.back().c_str();
                        c.fontPath = f.path->c_str();
                        c.codepoint = g.cp;
                        c.type = t.type;
                        c.pxSize = PX_SIZE;
                        c.pxRange = PX_RANGE;
                        c.errorCorrection = ec != 0;
                        c.geometryPreprocess = geom != 0;
                        c.scanlineFillRule = scan != 0;
                        c.fillRule = FILL_NONZERO;
                        configs.push_back(c);
                    }
                }
            }
        }
    }
    }

    FreetypeHandle *ft = initializeFreetype();
    if (!ft) {
        fprintf(stderr, "oracle: cannot initialize FreeType\n");
        return 1;
    }
    printf("Writing %zu fixtures to %s\n", configs.size(), outDir.c_str());
    int failed = 0;
    for (const Config &cfg : configs)
        if (!generateOne(cfg, outDir, ft))
            ++failed;
    deinitializeFreetype(ft);

    if (failed) {
        fprintf(stderr, "oracle: %d/%zu fixtures FAILED\n", failed, configs.size());
        return 1;
    }
    printf("oracle: %zu fixtures written\n", configs.size());
    return 0;
}
