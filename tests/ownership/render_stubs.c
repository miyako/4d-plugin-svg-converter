/*
 * Synthetic stand-ins for the librsvg/cairo/glib calls made by 4DPlugin.cpp.
 *
 * The plugin links static librsvg/cairo/glib archives that are built from
 * source by scripts/build-macos-deps.sh and are not committed, so the
 * ownership harness replaces the rendering stack. Signatures come from the
 * bundled headers in include/mac. Every object is malloc'd and counted so
 * the harness can check that the plugin releases what it creates; stream
 * surfaces write a marker through the plugin's write callback.
 */

#include <rsvg.h>
#include <rsvg-css.h>
#include <cairo-ps.h>
#include <cairo-pdf.h>
#include <cairo-svg.h>

#include <stdlib.h>
#include <string.h>

typedef struct { int magic; } stub_handle;
typedef struct { cairo_write_func_t write; void *closure; } stub_surface;
typedef struct { stub_surface *surface; } stub_cr;

static int g_live = 0;      /* rsvg handles + surfaces + contexts */
static int g_rendered = 0;  /* rsvg_handle_render_cairo calls */
static int g_parsed = 0;    /* rsvg_handle_new_from_data successes */

int stub_live_objects(void) { return g_live; }
int stub_rendered(void) { return g_rendered; }
int stub_parsed(void) { return g_parsed; }

void rsvg_set_default_dpi_x_y(double dpi_x, double dpi_y) { (void)dpi_x; (void)dpi_y; }

RsvgHandle *rsvg_handle_new_from_data(const guint8 *data, gsize data_len, GError **error)
{
    (void)error;
    if(!data || data_len < 4 || memcmp(data, "<svg", 4)) return NULL;
    stub_handle *h = (stub_handle *)malloc(sizeof *h);
    h->magic = 0x5356;
    g_live++;
    g_parsed++;
    return (RsvgHandle *)h;
}

void rsvg_handle_set_base_uri(RsvgHandle *handle, const char *base_uri) { (void)handle; (void)base_uri; }

void rsvg_handle_get_dimensions(RsvgHandle *handle, RsvgDimensionData *d)
{
    (void)handle;
    d->width = 10; d->height = 10; d->em = 10; d->ex = 10;
}

guint32 rsvg_css_parse_color(const char *str, gboolean *inherit) { (void)str; (void)inherit; return 0xffffff; }

gboolean rsvg_handle_render_cairo(RsvgHandle *handle, cairo_t *cr) { (void)handle; (void)cr; g_rendered++; return TRUE; }

gboolean rsvg_handle_close(RsvgHandle *handle, GError **error) { (void)handle; (void)error; return TRUE; }

void g_object_unref(gpointer object)
{
    stub_handle *h = (stub_handle *)object;
    if(h->magic != 0x5356) abort();
    h->magic = 0;
    free(h);
    g_live--;
}

void (g_clear_pointer)(gpointer *pp, GDestroyNotify destroy)
{
    gpointer p = *pp;
    *pp = NULL;
    if(p) destroy(p);
}

void g_clear_error(GError **err) { if(err && *err) abort(); }

gint g_ascii_strcasecmp(const gchar *s1, const gchar *s2) { return strcasecmp(s1, s2); }

static cairo_surface_t *new_surface(cairo_write_func_t write, void *closure)
{
    stub_surface *s = (stub_surface *)malloc(sizeof *s);
    s->write = write; s->closure = closure;
    g_live++;
    return (cairo_surface_t *)s;
}

cairo_surface_t *cairo_image_surface_create(cairo_format_t format, int width, int height)
{ (void)format; (void)width; (void)height; return new_surface(NULL, NULL); }

cairo_surface_t *cairo_ps_surface_create_for_stream(cairo_write_func_t w, void *c, double width, double height)
{ (void)width; (void)height; return new_surface(w, c); }

cairo_surface_t *cairo_pdf_surface_create_for_stream(cairo_write_func_t w, void *c, double width, double height)
{ (void)width; (void)height; return new_surface(w, c); }

cairo_surface_t *cairo_svg_surface_create_for_stream(cairo_write_func_t w, void *c, double width, double height)
{ (void)width; (void)height; return new_surface(w, c); }

void cairo_surface_destroy(cairo_surface_t *surface) { free(surface); g_live--; }

cairo_t *cairo_create(cairo_surface_t *target)
{
    stub_cr *cr = (stub_cr *)malloc(sizeof *cr);
    cr->surface = (stub_surface *)target;
    g_live++;
    return (cairo_t *)cr;
}

void cairo_destroy(cairo_t *cr) { free(cr); g_live--; }

void cairo_set_source_rgb(cairo_t *cr, double r, double g, double b) { (void)cr; (void)r; (void)g; (void)b; }
void cairo_rectangle(cairo_t *cr, double x, double y, double w, double h) { (void)cr; (void)x; (void)y; (void)w; (void)h; }
void cairo_fill(cairo_t *cr) { (void)cr; }

void cairo_show_page(cairo_t *cr)
{
    stub_surface *s = ((stub_cr *)cr)->surface;
    if(s->write) s->write(s->closure, (const unsigned char *)"PAGE", 4);
}

cairo_status_t cairo_surface_write_to_png_stream(cairo_surface_t *surface, cairo_write_func_t w, void *closure)
{
    (void)surface;
    return w(closure, (const unsigned char *)"PNG", 3);
}
