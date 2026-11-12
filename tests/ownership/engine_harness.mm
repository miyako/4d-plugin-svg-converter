/*
 * Synthetic 4D engine boundary for SVG Converter ownership regressions.
 *
 * Links the real plugin source (4DPlugin.cpp), the plugin classes
 * (4D Plugin API/Classes) and the bundled, unmodified 4D Plugin API
 * (4DPluginAPI.c). The librsvg/cairo/glib calls are served by
 * render_stubs.c (the static rendering stack is built from source and not
 * committed). Only gCall4D is replaced: it models engine-side allocations
 * (Unistrings, handles, pictures) with malloc/free so ASan reports double
 * frees and use-after-free, and keeps a live set of every engine string,
 * handle and picture so leaks are detected exactly.
 *
 * Engine semantics modelled (SDK contract):
 *  - PA_CreateVariable(eVK_Unistring / eVK_Picture) allocates an empty
 *    engine string / picture (4DPluginAPI.c); PA_SetStringVariable and
 *    PA_SetPictureVariable overwrite the variable shallowly.
 *  - PA_ClearVariable releases what the variable owns.
 *  - Pictures are reference counted: PA_DuplicatePicture(p, 1) retains,
 *    PA_DisposePicture releases one reference.
 *  - A picture created from bytes that start with "<svg" stores one SVG
 *    representation. PA_GetPictureData(p, 1, h) copies it into h and
 *    returns its type list ".svg;image/svg+xml" as a borrowed string (the
 *    SDK does not document ownership of that string; neither the plugin nor
 *    C_PICTURE releases it).
 *  - Commands that write a picture into an output parameter (READ PICTURE
 *    FILE, CREATE THUMBNAIL) release the picture previously held by that
 *    variable (the most forgiving engine model).
 *  - PA_ConvertCharsetToCharset returns the BYTE size written (SDK comment).
 *
 * Inputs are synthetic in-memory SVG strings; nothing is read from or
 * written to disk and no network resource is referenced.
 */

#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"
#include "4DPlugin.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

extern "C" Call4DProcPtr gCall4D;
extern "C" int stub_live_objects(void);
extern "C" int stub_rendered(void);
extern "C" int stub_parsed(void);

namespace {

typedef std::basic_string<PA_Unichar> u16;

struct Handle { char *data; PA_long32 len; };
struct Pic { int refs; std::string svg; };

std::set<void *> g_strings;
std::set<Handle *> g_handles;
std::set<Pic *> g_pics;

u16 g_read_path, g_convert_type;
int g_transform_op = 0, g_thumb_w = 0, g_thumb_h = 0;

[[noreturn]] void die(const char *msg) {
    fprintf(stderr, "ENGINE VIOLATION: %s\n", msg);
    fflush(stderr);
    abort();
}

PA_Unistring new_string(const PA_Unichar *src, size_t len) {
    PA_Unichar *buf = (PA_Unichar *)malloc((len + 1) * sizeof(PA_Unichar));
    if(len) memcpy(buf, src, len * sizeof(PA_Unichar));
    buf[len] = 0;
    g_strings.insert(buf);
    PA_Unistring s;
    s.fLength = (PA_long32)len;
    s.fString = buf;
    s.fReserved1 = 0;
    s.fReserved2 = 0;
    return s;
}

void free_string(PA_Unistring *s) {
    if(!s->fString) return;
    if(!g_strings.erase(s->fString)) die("disposed a string the engine does not own");
    free(s->fString);
    s->fString = 0;
    s->fLength = 0;
}

Handle *new_handle(PA_long32 len) {
    Handle *h = (Handle *)malloc(sizeof(Handle));
    h->data = (char *)calloc(1, len ? len : 1);
    h->len = len;
    g_handles.insert(h);
    return h;
}

Handle *checked(PA_Handle ph) {
    Handle *h = (Handle *)ph;
    if(!g_handles.count(h)) die("used an unknown handle");
    return h;
}

void free_handle(Handle *h) {
    if(!h) return;
    checked((PA_Handle)h);
    g_handles.erase(h);
    free(h->data);
    free(h);
}

Pic *new_pic(const std::string &svg = std::string()) {
    Pic *p = new Pic;
    p->refs = 1;
    p->svg = svg;
    g_pics.insert(p);
    return p;
}

Pic *live_pic(PA_Picture pp) {
    Pic *p = (Pic *)pp;
    if(!g_pics.count(p)) die("used a picture the engine does not own");
    return p;
}

void release_pic(PA_Picture pp) {
    if(!pp) return;
    Pic *p = live_pic(pp);
    if(--p->refs == 0) { g_pics.erase(p); delete p; }
}

void clear_var(PA_Variable *v) {
    switch(v->fType) {
        case eVK_Unistring: free_string(&v->uValue.fString); break;
        case eVK_Picture: release_pic(v->uValue.fPicture); v->uValue.fPicture = 0; break;
        case eVK_ArrayPicture: {
            Handle *h = (Handle *)v->uValue.fArray.fData;
            if(h) {
                PA_Picture *items = (PA_Picture *)checked((PA_Handle)h)->data;
                for(PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i) release_pic(items[i]);
                free_handle(h);
            }
            break;
        }
        case eVK_ArrayLongint:
        case eVK_ArrayReal:
            if(v->uValue.fArray.fData) free_handle((Handle *)v->uValue.fArray.fData);
            break;
        case eVK_ArrayUnicode: {
            Handle *h = (Handle *)v->uValue.fArray.fData;
            if(h) {
                PA_Unistring *items = (PA_Unistring *)checked((PA_Handle)h)->data;
                for(PA_long32 i = 0; i <= v->uValue.fArray.fNbElements; ++i) free_string(&items[i]);
                free_handle(h);
            }
            break;
        }
        default: break;
    }
    v->fType = eVK_Undefined;
}

u16 live_text(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Unistring) die(what);
    if(!g_strings.count(v.uValue.fString.fString)) die("engine received a string it does not own");
    return u16(v.uValue.fString.fString, v.uValue.fString.fLength);
}

void live_picture_var(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Picture || !v.uValue.fPicture) die(what);
    live_pic(v.uValue.fPicture);
}

PA_long32 longint(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Longint) die(what);
    return v.uValue.fLongint;
}

double real(const PA_Variable &v, const char *what) {
    if(v.fType != eVK_Real) die(what);
    return v.uValue.fReal;
}

/* output picture parameter: the engine releases the old value and stores a new picture */
void write_picture(PA_Variable *v) {
    if(v->fType == eVK_Picture) release_pic(v->uValue.fPicture);
    else if(v->fType != eVK_Undefined) die("picture output parameter has a non-picture value");
    v->fType = eVK_Picture;
    v->uValue.fPicture = new_pic();
}

void command(EngineBlock *eb) {
    PA_Variable **v = (PA_Variable **)eb->fPtr1;
    PA_long32 n = (PA_long32)eb->fParam2;
    switch(eb->fParam1) {
        case 678: /* READ PICTURE FILE(path; picture) */
            if(n != 2) die("READ PICTURE FILE parameter count");
            g_read_path = live_text(*v[0], "path parameter is not text");
            write_picture(v[1]);
            break;
        case 1002: /* CONVERT PICTURE(picture; type) */
            if(n != 2) die("CONVERT PICTURE parameter count");
            live_picture_var(*v[0], "CONVERT PICTURE picture");
            g_convert_type = live_text(*v[1], "type parameter is not text");
            break;
        case 988: /* TRANSFORM PICTURE(picture; operator) */
            if(n != 2) die("TRANSFORM PICTURE parameter count");
            live_picture_var(*v[0], "TRANSFORM PICTURE picture");
            g_transform_op = longint(*v[1], "operator is not longint");
            break;
        case 457: /* PICTURE PROPERTIES(picture; width; height) */
            if(n != 3) die("PICTURE PROPERTIES parameter count");
            live_picture_var(*v[0], "PICTURE PROPERTIES picture");
            v[1]->fType = eVK_Longint; v[1]->uValue.fLongint = 640;
            v[2]->fType = eVK_Longint; v[2]->uValue.fLongint = 480;
            break;
        case 679: /* CREATE THUMBNAIL(picture; thumbnail; width; height) */
            if(n != 4) die("CREATE THUMBNAIL parameter count");
            live_picture_var(*v[0], "CREATE THUMBNAIL source");
            g_thumb_w = longint(*v[2], "width is not longint");
            g_thumb_h = longint(*v[3], "height is not longint");
            write_picture(v[1]);
            break;
        default: die("unexpected command");
    }
    eb->fError = 0;
}

void engine(PA_long32 selector, void *p) {
    EngineBlock *eb = (EngineBlock *)p;
    switch(selector) {
        case EX_HANDLE_MANAGER:
            switch(eb->fParam1) {
                case 1: eb->fHandle = (PA_Handle)new_handle((PA_long32)eb->fParam2); eb->fError = 0; return;
                case 2: free_handle((Handle *)eb->fHandle); eb->fError = 0; return;
                case 3: {
                    Handle *h = checked(eb->fHandle);
                    PA_long32 n = (PA_long32)eb->fParam2;
                    h->data = (char *)realloc(h->data, n ? n : 1);
                    if(n > h->len) memset(h->data + h->len, 0, n - h->len);
                    h->len = n; eb->fError = 0; return;
                }
                case 4: eb->fParam2 = checked(eb->fHandle)->len; eb->fError = 0; return;
                case 5: eb->fParam3 = (sLONG_PTR)checked(eb->fHandle)->data; eb->fError = 0; return;
                case 6: checked(eb->fHandle); eb->fError = 0; return;
                default: die("unmodelled handle manager call");
            }
        case EX_CREATE_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_SET_UNISTRING: {
            const PA_Unichar *s = (const PA_Unichar *)eb->fHandle;
            size_t n = 0; while(s[n]) ++n;
            free_string(&eb->fUniString1);
            eb->fUniString1 = new_string(s, n);
            return;
        }
        case EX_DISPOSE_UNISTRING: free_string(&eb->fUniString1); return;
        case EX_CLEAR_VARIABLE: clear_var((PA_Variable *)eb->fPtr1); return;
        case EX_YIELD_ABSOLUTE: return;
        case EX_CREATE_PICTURE: {
            std::string bytes;
            if(eb->fPtr1 && eb->fParam1 > 0) bytes.assign((const char *)eb->fPtr1, (size_t)eb->fParam1);
            eb->fPicture = new_pic(bytes.compare(0, 4, "<svg") == 0 ? bytes : std::string());
            eb->fError = 0;
            return;
        }
        case EX_DISPOSE_PICTURE: release_pic(eb->fPicture); return;
        case EX_DUPLICATE_PICTURE:
            if(eb->fParam1 == 0) live_pic(eb->fPicture)->refs++;
            else eb->fPicture = new_pic(live_pic(eb->fPicture)->svg);
            return;
        case EX_GET_PICTURE_DATA: {
            Pic *pic = live_pic(eb->fPicture);
            memset(&eb->fUniString1, 0, sizeof eb->fUniString1);
            if(pic->svg.empty() || eb->fParam1 != 1) { eb->fError = -1; return; } /* no such format */
            static PA_Unichar types[] = { '.','s','v','g',';','i','m','a','g','e','/','s','v','g','+','x','m','l',0 };
            eb->fUniString1.fString = types; /* borrowed */
            eb->fUniString1.fLength = (PA_long32)(sizeof types / sizeof types[0]) - 1;
            if(eb->fHandle) {
                Handle *h = checked(eb->fHandle);
                h->data = (char *)realloc(h->data, pic->svg.size());
                memcpy(h->data, pic->svg.data(), pic->svg.size());
                h->len = (PA_long32)pic->svg.size();
            }
            eb->fError = 0;
            return;
        }
        case EX_CONVERT_CHARSET_TO_CHARSET: {
            const char *from = (const char *)eb->fPtr1;
            PA_long32 fromSize = (PA_long32)eb->fParam1, toSize = (PA_long32)eb->fParam3, out = 0;
            if(eb->fParam2 == eVTC_UTF_8 && eb->fParam4 == eVTC_UTF_16) {
                PA_Unichar *to = (PA_Unichar *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize && (out + 1) * (PA_long32)sizeof(PA_Unichar) <= toSize; ++i)
                    to[out++] = (unsigned char)from[i];
                eb->fParam3 = out * (PA_long32)sizeof(PA_Unichar); /* byte size */
            } else if(eb->fParam2 == eVTC_UTF_16 && eb->fParam4 == eVTC_UTF_8) {
                const PA_Unichar *f = (const PA_Unichar *)from;
                char *to = (char *)eb->fPtr2;
                for(PA_long32 i = 0; i < fromSize / 2 && out < toSize; ++i) to[out++] = (char)f[i];
                eb->fParam3 = out;
            } else die("unmodelled charset conversion");
            eb->fError = 0;
            return;
        }
        case EX_EXECUTE_COMMAND_BY_ID: command(eb); return;
        default: {
            char msg[64];
            snprintf(msg, sizeof msg, "unmodelled selector %d", (int)selector);
            die(msg);
        }
    }
}

void expect(bool ok, const char *what) {
    if(!ok) {
        fprintf(stderr, "FAIL: %s (live engine strings: %zu, pictures: %zu)\n", what, g_strings.size(), g_pics.size());
        exit(1);
    }
}

void expect_nothing_live(const char *what) {
    expect(g_strings.empty(), what);
    expect(g_pics.empty(), what);
}

u16 to_u16(const char *s) { u16 r; for(; *s; ++s) r.push_back((PA_Unichar)(unsigned char)*s); return r; }

/* ---- SVG Convert / SVG Convert array through PluginMain ---- */

const std::string kSvg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>";

template<typename T> PA_Variable make_array(PA_VariableKind kind, const std::vector<T> &items, T element0 = T()) {
    /* element 0 plus items, as 4D arrays are laid out */
    PA_Variable v;
    memset(&v, 0, sizeof v);
    v.fType = kind;
    Handle *h = new_handle((PA_long32)((items.size() + 1) * sizeof(T)));
    T *data = (T *)h->data;
    data[0] = element0;
    for(size_t i = 0; i < items.size(); ++i) data[i + 1] = items[i];
    v.uValue.fArray.fNbElements = (PA_long32)items.size();
    v.uValue.fArray.fCurrent = 0;
    v.uValue.fArray.fData = (PA_Handle)h;
    return v;
}

struct Call { int code; std::string blob; };

/* param 1 is a picture (SVG Convert) or a picture-array variable (SVG Convert array) */
Call convert(int command, void *param1, PA_long32 format, const char *color) {
    PA_Handle out = 0;
    PA_long32 fmt = format;
    PA_Variable keys = make_array<PA_long32>(eVK_ArrayLongint, { SVG_DPI_X, SVG_DPI_Y, SVG_KEEP_ASPECT_RATIO });
    PA_Variable values = make_array<double>(eVK_ArrayReal, { 72.0, 72.0, 1.0 });
    u16 c = to_u16(color), uri = to_u16("file:///svg-synthetic/");
    PA_Unistring p6 = new_string(c.c_str(), c.size());
    PA_Unistring p7 = new_string(uri.c_str(), uri.size());
    sLONG_PTR ret = 0;
    void *params[7] = { param1, &out, &fmt, &keys, &values, &p6, &p7 };
    PluginBlock pb = { params, &ret, 0 };
    PluginMain(command, &pb);
    Call r = { (int)ret, std::string() };
    if(out) {
        Handle *h = checked(out);
        r.blob.assign(h->data, h->len);
        free_handle(h);
    }
    PA_ClearVariable(&keys);
    PA_ClearVariable(&values);
    free_string(&p6);
    free_string(&p7);
    return r;
}

void expect_balanced(const char *what) {
    expect_nothing_live(what);
    expect(g_handles.empty(), "no engine handles leaked");
    expect(stub_live_objects() == 0, "rsvg/cairo objects released");
}

Call convert_one(const std::string &bytes, PA_long32 format) {
    PA_Picture pic = PA_CreatePicture((void *)bytes.data(), (PA_long32)bytes.size());
    Call r = convert(2, &pic, format, "white");
    PA_DisposePicture(pic);
    return r;
}

void control_convert_png() {
    Call r = convert_one(kSvg, SVG_OUTPUT_PNG);
    expect(r.code == 0 && r.blob == "PNG", "PNG written to the BLOB");
    expect(stub_rendered() == 1, "rendered once");
    expect_balanced("SVG Convert PNG");
}

void control_convert_streams() {
    const PA_long32 formats[] = { SVG_OUTPUT_PDF, SVG_OUTPUT_PS, SVG_OUTPUT_SVG };
    for(PA_long32 f : formats) {
        Call r = convert_one(kSvg, f);
        expect(r.code == 0 && r.blob == "PAGE", "page written to the BLOB");
    }
    expect(stub_rendered() == 3, "rendered three times");
    expect_balanced("SVG Convert PDF/PS/SVG");
}

void control_convert_errors() {
    Call r = convert_one(kSvg, 99);
    expect(r.code == -3 && r.blob.empty(), "invalid format");
    r = convert_one("not an svg", SVG_OUTPUT_PNG);
    expect(r.code == -2 && r.blob.empty(), "picture without SVG data");
    expect(stub_rendered() == 0, "nothing rendered");
    expect_balanced("SVG Convert error paths");
}

void control_convert_output_blob_replaced() {
    PA_Picture pic = PA_CreatePicture((void *)kSvg.data(), (PA_long32)kSvg.size());
    PA_Handle out = PA_NewHandle(8); /* existing BLOB content is released by the plugin */
    PA_long32 fmt = SVG_OUTPUT_PDF;
    PA_Variable keys = make_array<PA_long32>(eVK_ArrayLongint, {});
    PA_Variable values = make_array<double>(eVK_ArrayReal, {});
    PA_Unistring p6 = new_string(0, 0), p7 = new_string(0, 0);
    sLONG_PTR ret = 0;
    void *params[7] = { &pic, &out, &fmt, &keys, &values, &p6, &p7 };
    PluginBlock pb = { params, &ret, 0 };
    PluginMain(2, &pb);
    expect(ret == 0 && checked(out)->len == 4, "new BLOB returned");
    expect(g_handles.size() == 3, "old BLOB released (new BLOB + two arrays live)");
    PA_DisposeHandle(out);
    PA_ClearVariable(&keys);
    PA_ClearVariable(&values);
    free_string(&p6);
    free_string(&p7);
    PA_DisposePicture(pic);
    expect_balanced("SVG Convert output BLOB");
}

void control_convert_array() {
    PA_Picture a = PA_CreatePicture((void *)kSvg.data(), (PA_long32)kSvg.size());
    PA_Picture b = PA_CreatePicture((void *)"not an svg", 10);
    PA_Picture c = PA_CreatePicture((void *)kSvg.data(), (PA_long32)kSvg.size());
    PA_Variable arr = make_array<PA_Picture>(eVK_ArrayPicture, { a, b, c }, PA_CreatePicture(0, 0));
    for(PA_long32 f : { SVG_OUTPUT_PDF, SVG_OUTPUT_PS }) {
        Call r = convert(1, &arr, f, "none");
        expect(r.code == 0 && r.blob == "PAGEPAGE", "two SVG pages written to the BLOB");
    }
    Call r = convert(1, &arr, SVG_OUTPUT_PNG, "none");
    expect(r.code == -3 && r.blob.empty(), "PNG is invalid for arrays");
    expect(stub_parsed() == 4 && stub_rendered() == 4, "each SVG element parsed and rendered");
    expect(g_pics.size() == 4, "array pictures are borrowed");
    PA_ClearVariable(&arr);
    expect_balanced("SVG Convert array");
}

void control_convert_array_undefined() {
    PA_Variable v;
    memset(&v, 0, sizeof v);
    v.fType = eVK_Undefined;
    Call r = convert(1, &v, SVG_OUTPUT_PDF, "");
    expect(r.code == 0 && r.blob.empty(), "undefined treated as empty array");
    expect(v.fType == eVK_Undefined, "caller variable untouched");
    expect_balanced("SVG Convert array undefined");
}

/* Contract 1/2: ARRAY_TEXT fills the array via PA_SetStringInArray and must not dispose. */
void control_array_text_transfer() {
    {
        ARRAY_TEXT a;
        a.appendUTF16String((const PA_Unichar *)u"", 0);
        a.appendUTF16String((const PA_Unichar *)u"x", 1);
        a.appendUTF16String((const PA_Unichar *)u"yz", 2);
        PA_Variable arr = PA_CreateVariable(eVK_ArrayUnicode);
        void *params[1] = { &arr };
        a.toParamAtIndex((PackagePtr)params, 1);
        expect(arr.uValue.fArray.fNbElements == 2, "two elements");
        expect(g_strings.size() == 3, "array owns three strings");
        ARRAY_TEXT b;
        b.fromParamAtIndex((PackagePtr)params, 1);
        CUTF16String s; b.copyUTF16StringAtIndex(&s, 2);
        expect(s == CUTF16String((const PA_Unichar *)u"yz"), "borrowed read");
        PA_ClearVariable(&arr);
    }
    expect_nothing_live("array strings released with the array");
}

/* ---- C_PICTURE methods with no caller in 4DPlugin.cpp ---- */

/* a picture held by C_PICTURE; the harness drops its own reference */
void with_picture(const std::function<void(C_PICTURE &)> &f) {
    {
        C_PICTURE pic;
        PA_Picture src = PA_CreatePicture(0, 0);
        pic.setPicture(src);
        PA_DisposePicture(src);
        expect(g_pics.size() == 1, "one picture held");
        f(pic);
    }
}

void defect_picture_fromfile_ownership() {
    {
        C_PICTURE pic;
        CUTF8String path((const uint8_t *)"/svg-synthetic/does-not-exist.png");
        pic.fromFileAtPath(&path);
        expect(g_read_path == to_u16("/svg-synthetic/does-not-exist.png"), "path delivered");
        expect(g_pics.size() == 1, "only the loaded picture is live");
    }
    expect_nothing_live("READ PICTURE FILE parameters and result released");
}

void defect_picture_setbytes_leak() {
    {
        C_PICTURE pic;
        const uint8_t bytes[] = { 1, 2, 3 };
        pic.setBytes(bytes, sizeof bytes);
        expect(g_pics.size() == 1, "only the held picture is live");
    }
    expect_nothing_live("picture created by setBytes released");
}

void defect_picture_createcopy_ownership() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createCopyPNG();
        expect(g_convert_type == to_u16(".png"), "type delivered");
        expect(p == pic.getPicture(), "retained copy returned");
        PA_DisposePicture(p);
    });
    expect_nothing_live("CONVERT PICTURE parameters released");
}

void defect_picture_grayscale_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture p = pic.createGrayScale();
        expect(g_transform_op == 101, "operator delivered");
        PA_DisposePicture(p);
    });
    expect_nothing_live("TRANSFORM PICTURE parameters released");
}

void defect_picture_getsize_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        unsigned int w = 0, h = 0;
        pic.getSize(&w, &h);
        expect(w == 640 && h == 480, "size delivered");
    });
    expect_nothing_live("PICTURE PROPERTIES parameters released");
}

void defect_picture_thumbnail_owner_leak() {
    with_picture([](C_PICTURE &pic) {
        PA_Picture t = pic.createThumbnail(32, 24);
        expect(g_thumb_w == 32 && g_thumb_h == 24, "size delivered");
        expect(t && t != pic.getPicture() && g_pics.count((Pic *)t), "thumbnail handed to the caller");
        PA_DisposePicture(t);
    });
    expect_nothing_live("CREATE THUMBNAIL parameters released");
}

/* Contract 6 control: C_PICTURE parameter/return transfer. */
void control_picture_param_return() {
    PA_Picture in = PA_CreatePicture(0, 0);
    PA_Picture out = PA_CreatePicture(0, 0);
    PA_Picture ret = 0;
    {
        C_PICTURE pic;
        void *params[2] = { &in, &out };
        pic.fromParamAtIndex((PackagePtr)params, 1);
        pic.toParamAtIndex((PackagePtr)params, 2);
        pic.setReturn((sLONG_PTR *)&ret);
        expect(out == in && ret == in, "same picture retained");
    }
    PA_DisposePicture(in);
    PA_DisposePicture(out);
    PA_DisposePicture(ret);
    expect_nothing_live("all references balanced");
}

const std::map<std::string, std::function<void()>> kTests = {
    { "control_convert_png", control_convert_png },
    { "control_convert_streams", control_convert_streams },
    { "control_convert_errors", control_convert_errors },
    { "control_convert_output_blob_replaced", control_convert_output_blob_replaced },
    { "control_convert_array", control_convert_array },
    { "control_convert_array_undefined", control_convert_array_undefined },
    { "control_array_text_transfer", control_array_text_transfer },
    { "defect_picture_fromfile_ownership", defect_picture_fromfile_ownership },
    { "defect_picture_setbytes_leak", defect_picture_setbytes_leak },
    { "defect_picture_createcopy_ownership", defect_picture_createcopy_ownership },
    { "defect_picture_grayscale_owner_leak", defect_picture_grayscale_owner_leak },
    { "defect_picture_getsize_owner_leak", defect_picture_getsize_owner_leak },
    { "defect_picture_thumbnail_owner_leak", defect_picture_thumbnail_owner_leak },
    { "control_picture_param_return", control_picture_param_return },
};

} // namespace

int main(int argc, char **argv) {
    gCall4D = (Call4DProcPtr)engine;
    if(argc == 2 && std::string(argv[1]) == "--list") {
        for(auto &t : kTests) printf("%s\n", t.first.c_str());
        return 0;
    }
    if(argc != 2 || !kTests.count(argv[1])) { fprintf(stderr, "usage: %s --list | <test>\n", argv[0]); return 2; }
    kTests.at(argv[1])();
    printf("PASS %s\n", argv[1]);
    return 0;
}
