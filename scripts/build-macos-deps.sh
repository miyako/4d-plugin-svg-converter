#!/bin/bash
# Builds the librsvg stack the Xcode project links from a/, as universal
# (arm64 + x86_64) static archives for macOS 11.5, from pinned upstream
# release tarballs. All of them are autotools projects, built once per arch
# with --host=<arch>-apple-darwin and joined with lipo.
#
#   librsvg    2.40.21  last C-only stable release (2.41+ needs Rust); same C API
#                       as the 2.37.0 dev snapshot the plugin was written for,
#                       incl. the public rsvg_css_parse_color() from rsvg-css.h
#   libcroco   0.6.13   last release (CSS parser for librsvg)
#   gdk-pixbuf 2.36.12  last autotools release; PNG and JPEG loaders built in,
#                       no loadable modules, no loaders.cache
#   pango      1.42.4   last autotools release; CoreText font backend through
#                       cairo-quartz, so no fontconfig/freetype/harfbuzz and no
#                       config files are needed at runtime
#   fribidi    1.0.13   required by pango
#   cairo      1.16.0   last autotools release; quartz + quartz-font, png, pdf,
#                       ps, svg and xml surfaces; no freetype/fontconfig/X11
#   pixman     0.42.2   last autotools release; ARM assembly off (Apple's
#                       assembler rejects it), SSE2/SSSE3 on x86_64
#   glib       2.56.4   last release whose tarball ships a configure script
#                       (2.58.x tarballs are meson-only); internal PCRE
#   libpng     1.6.59
#   libjpeg    9f
#   libintl    stub     no-op gettext (below): glib needs libintl.h and
#                       -lintl, the plugin ships no translations
# From the SDK instead of building: zlib, libxml2, libiconv, libffi
# (libz.tbd, libxml2.tbd, libiconv.tbd, libffi.tbd) and libresolv for gio.
#
# The installed headers of these versions are committed in include/mac (the
# Windows build uses include/win). The script compares them at the end and
# fails if they differ; UPDATE_HEADERS=1 copies them there instead.
#
# usage: scripts/build-macos-deps.sh [output-dir]   (default: a/)
# WORK (default build/deps) holds downloads and per-arch builds; a rerun
# reuses every library whose $WORK/<arch>/prefix/.done-<name> stamp exists. Needs: Xcode command line tools, curl, pkg-config, python3.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/a}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
WORK="${WORK:-$ROOT/build/deps}"
MIN="${MACOSX_DEPLOYMENT_TARGET:-11.5}"
JOBS="$(sysctl -n hw.ncpu)"
ARCHS="arm64 x86_64"

GLIB_URL=https://download.gnome.org/sources/glib/2.56/glib-2.56.4.tar.xz
GLIB_SHA=27f703d125efb07f8a743666b580df0b4095c59fc8750e8890132c91d437504c
RSVG_URL=https://download.gnome.org/sources/librsvg/2.40/librsvg-2.40.21.tar.xz
RSVG_SHA=f7628905f1cada84e87e2b14883ed57d8094dca3281d5bcb24ece4279e9a92ba
CROCO_URL=https://download.gnome.org/sources/libcroco/0.6/libcroco-0.6.13.tar.xz
CROCO_SHA=767ec234ae7aa684695b3a735548224888132e063f92db585759b422570621d4
PIXBUF_URL=https://download.gnome.org/sources/gdk-pixbuf/2.36/gdk-pixbuf-2.36.12.tar.xz
PIXBUF_SHA=fff85cf48223ab60e3c3c8318e2087131b590fd6f1737e42cb3759a3b427a334
PANGO_URL=https://download.gnome.org/sources/pango/1.42/pango-1.42.4.tar.xz
PANGO_SHA=1d2b74cd63e8bd41961f2f8d952355aa0f9be6002b52c8aa7699d9f5da597c9d
FRIBIDI_URL=https://github.com/fribidi/fribidi/releases/download/v1.0.13/fribidi-1.0.13.tar.xz
FRIBIDI_SHA=7fa16c80c81bd622f7b198d31356da139cc318a63fc7761217af4130903f54a2
CAIRO_URL=https://cairographics.org/releases/cairo-1.16.0.tar.xz
CAIRO_SHA=5e7b29b3f113ef870d1e3ecf8adf21f923396401604bda16d44be45e66052331
PIXMAN_URL=https://cairographics.org/releases/pixman-0.42.2.tar.gz
PIXMAN_SHA=ea1480efada2fd948bc75366f7c349e1c96d3297d09a3fe62626e38e234a625e
PNG_URL=https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.59.tar.gz
PNG_SHA=2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5
JPEG_URL=https://www.ijg.org/files/jpegsrc.v9f.tar.gz
JPEG_SHA=04705c110cb2469caa79fb71fba3d7bf834914706e9641a4589485c1f832565b

# keep Homebrew headers, libraries and .pc files out of the build
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
      PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR ACLOCAL_PATH CFLAGS CXXFLAGS \
      CPPFLAGS LDFLAGS || true
export MACOSX_DEPLOYMENT_TARGET="$MIN"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
command -v pkg-config >/dev/null || { echo "::error::pkg-config is required"; exit 1; }
PYTHON="$(command -v python3)" || { echo "::error::python3 is required"; exit 1; }

mkdir -p "$WORK/dl" "$OUT"

# fetch <url> <sha256> <file>: download with retries, verify the checksum
fetch() {
  local f="$WORK/dl/$3" i
  if [ -f "$f" ] && echo "$2  $f" | shasum -a 256 -c - >/dev/null 2>&1; then
    return 0
  fi
  for i in 1 2 3; do
    curl -fsSL --retry 3 -o "$f.tmp" "$1" && break
    [ "$i" = 3 ] && { echo "::error::download failed: $1"; return 1; }
    echo "download $1 failed, retrying"; sleep 10
  done
  echo "$2  $f.tmp" | shasum -a 256 -c - || { echo "::error::checksum mismatch: $1"; rm -f "$f.tmp"; return 1; }
  mv "$f.tmp" "$f"
}

# unpack <archive> <dest dir>: fresh extraction into dest
unpack() {
  rm -rf "${2:?}"; mkdir -p "$2"
  tar -xf "$WORK/dl/$1" -C "$2" --strip-components 1
}

host_for() { case "$1" in arm64) echo aarch64-apple-darwin ;; x86_64) echo x86_64-apple-darwin ;; esac; }
# an explicit --build that differs from --host makes every configure a cross
# build, so the result doesn't depend on whether Rosetta can run x86_64 tests
BUILD="$(uname -m | sed s/arm64/aarch64/)-build-darwin"

fetch "$GLIB_URL"    "$GLIB_SHA"    glib-2.56.4.tar.xz
fetch "$RSVG_URL"    "$RSVG_SHA"    librsvg-2.40.21.tar.xz
fetch "$CROCO_URL"   "$CROCO_SHA"   libcroco-0.6.13.tar.xz
fetch "$PIXBUF_URL"  "$PIXBUF_SHA"  gdk-pixbuf-2.36.12.tar.xz
fetch "$PANGO_URL"   "$PANGO_SHA"   pango-1.42.4.tar.xz
fetch "$FRIBIDI_URL" "$FRIBIDI_SHA" fribidi-1.0.13.tar.xz
fetch "$CAIRO_URL"   "$CAIRO_SHA"   cairo-1.16.0.tar.xz
fetch "$PIXMAN_URL"  "$PIXMAN_SHA"  pixman-0.42.2.tar.gz
fetch "$PNG_URL"     "$PNG_SHA"     libpng-1.6.59.tar.gz
fetch "$JPEG_URL"    "$JPEG_SHA"    jpegsrc.v9f.tar.gz

# conf <srcdir> [args]: configure a static-only cross build into $P
conf() {
  local d="$1"; shift
  (cd "$d" && ./configure --prefix="$P" --host="$(host_for "$A")" --build="$BUILD" \
      --enable-static --disable-shared --disable-dependency-tracking "$@")
}

for A in $ARCHS; do
  P="$WORK/$A/prefix"
  S="$WORK/$A/src"
  mkdir -p "$P/lib/pkgconfig" "$P/include" "$S"
  # an explicit -isysroot also drops /usr/local/include and /usr/local/lib
  # from the default search paths
  export CC="clang -isysroot $SDK -arch $A -mmacosx-version-min=$MIN"
  export CXX="clang++ -isysroot $SDK -arch $A -mmacosx-version-min=$MIN"
  export OBJC="$CC"
  export CFLAGS="-O2 -Werror=implicit-function-declaration -Werror=implicit-int"
  export CXXFLAGS="-O2"
  export OBJCFLAGS="$CFLAGS"
  export CPPFLAGS="-I$P/include"
  export LDFLAGS="-L$P/lib"
  export PKG_CONFIG="pkg-config --static"
  export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig"

  # .pc files for the SDK libraries the GNOME stack looks up with pkg-config
  XMLVER="$(sed -n 's/^#define LIBXML_DOTTED_VERSION "\(.*\)"/\1/p' "$SDK/usr/include/libxml2/libxml/xmlversion.h")"
  cat > "$P/lib/pkgconfig/libxml-2.0.pc" <<EOF
Name: libXML
Description: libxml2 from the macOS SDK
Version: $XMLVER
Libs: -lxml2
Cflags: -I$SDK/usr/include/libxml2
EOF
  cat > "$P/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib from the macOS SDK
Version: 1.2.12
Libs: -lz
Cflags:
EOF
  cat > "$P/lib/pkgconfig/libffi.pc" <<EOF
Name: libffi
Description: libffi from the macOS SDK
Version: 3.4.0
Libs: -lffi
Cflags: -I$SDK/usr/include/ffi
EOF

  # libintl: glib's configure insists on gettext, but nothing here is
  # translated, so the stub returns the untranslated strings
  if [ ! -f "$P/.done-intl" ]; then
    echo "::group::libintl stub $A"
    cat > "$P/include/libintl.h" <<'EOF'
/* no-op gettext for the statically linked GNOME libraries (no translations) */
#ifndef _LIBINTL_H
#define _LIBINTL_H 1
#ifdef __cplusplus
extern "C" {
#endif
/* format_arg, as in GNU libintl.h, keeps -Wformat-nonliteral quiet */
char *gettext (const char *msgid) __attribute__ ((format_arg (1)));
char *dgettext (const char *domainname, const char *msgid) __attribute__ ((format_arg (2)));
char *dcgettext (const char *domainname, const char *msgid, int category) __attribute__ ((format_arg (2)));
char *ngettext (const char *msgid, const char *msgid_plural, unsigned long n)
  __attribute__ ((format_arg (1))) __attribute__ ((format_arg (2)));
char *dngettext (const char *domainname, const char *msgid, const char *msgid_plural, unsigned long n)
  __attribute__ ((format_arg (2))) __attribute__ ((format_arg (3)));
char *dcngettext (const char *domainname, const char *msgid, const char *msgid_plural, unsigned long n, int category)
  __attribute__ ((format_arg (2))) __attribute__ ((format_arg (3)));
char *textdomain (const char *domainname);
char *bindtextdomain (const char *domainname, const char *dirname);
char *bind_textdomain_codeset (const char *domainname, const char *codeset);
#ifdef __cplusplus
}
#endif
#endif
EOF
    cat > "$S/intl.c" <<'EOF'
#include <libintl.h>
char *gettext (const char *m) { return (char *) m; }
char *dgettext (const char *d, const char *m) { (void) d; return (char *) m; }
char *dcgettext (const char *d, const char *m, int c) { (void) d; (void) c; return (char *) m; }
char *ngettext (const char *m, const char *p, unsigned long n) { return (char *) (n == 1 ? m : p); }
char *dngettext (const char *d, const char *m, const char *p, unsigned long n) { (void) d; return (char *) (n == 1 ? m : p); }
char *dcngettext (const char *d, const char *m, const char *p, unsigned long n, int c) { (void) d; (void) c; return (char *) (n == 1 ? m : p); }
static char messages[] = "messages";
char *textdomain (const char *d) { return d ? (char *) d : messages; }
char *bindtextdomain (const char *d, const char *dir) { (void) d; return (char *) dir; }
char *bind_textdomain_codeset (const char *d, const char *c) { (void) d; return (char *) c; }
EOF
    $CC $CFLAGS $CPPFLAGS -c "$S/intl.c" -o "$S/intl.o"
    rm -f "$P/lib/libintl.a"
    ar rcs "$P/lib/libintl.a" "$S/intl.o"
    touch "$P/.done-intl"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-jpeg" ]; then
    echo "::group::libjpeg $A"
    unpack jpegsrc.v9f.tar.gz "$S/jpeg"
    conf "$S/jpeg"
    make -C "$S/jpeg" -j"$JOBS"
    make -C "$S/jpeg" install
    touch "$P/.done-jpeg"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-png" ]; then
    echo "::group::libpng $A"
    unpack libpng-1.6.59.tar.gz "$S/png"
    conf "$S/png" --disable-hardware-optimizations --disable-tools --without-binconfigs
    make -C "$S/png" -j"$JOBS"
    make -C "$S/png" install
    touch "$P/.done-png"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-pixman" ]; then
    echo "::group::pixman $A"
    unpack pixman-0.42.2.tar.gz "$S/pixman"
    conf "$S/pixman" --disable-gtk --disable-libpng --disable-openmp \
      --disable-arm-simd --disable-arm-neon --disable-arm-a64-neon \
      --disable-arm-iwmmxt --disable-arm-iwmmxt2 --disable-mips-dspr2 \
      --disable-loongson-mmi --disable-vmx
    make -C "$S/pixman/pixman" -j"$JOBS"
    make -C "$S/pixman/pixman" install
    make -C "$S/pixman" install-pkgconfigDATA
    touch "$P/.done-pixman"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-glib" ]; then
    echo "::group::glib $A"
    unpack glib-2.56.4.tar.xz "$S/glib"
    # answers for the run tests a cross build can't execute (as a native
    # build on macOS finds them); va_list is an array on x86_64 only
    if [ "$A" = x86_64 ]; then VACOPY=no; else VACOPY=yes; fi
    # g_atomic_pointer_add/and/or/xor: current clang rejects passing a gssize
    # to the gpointer that the __sync builtins deduce from a gpointer*
    # (-Wint-conversion is an error since clang 15); cast the pointer as
    # upstream did later (2.63)
    sed -i '' -e 's/(gssize) __sync_fetch_and_add ((atomic), (val))/(gssize) __sync_fetch_and_add ((volatile gssize *) (atomic), (val))/' \
      -e 's/(gsize) __sync_fetch_and_and ((atomic), (val))/(gsize) __sync_fetch_and_and ((volatile gsize *) (atomic), (val))/' \
      -e 's/(gsize) __sync_fetch_and_or ((atomic), (val))/(gsize) __sync_fetch_and_or ((volatile gsize *) (atomic), (val))/' \
      -e 's/(gsize) __sync_fetch_and_xor ((atomic), (val))/(gsize) __sync_fetch_and_xor ((volatile gsize *) (atomic), (val))/' \
      "$S/glib/glib/gatomic.h"
    [ "$(grep -c '__sync_fetch_and_[a-z]* ((volatile gs*size \*) (atomic), (val))' "$S/glib/glib/gatomic.h")" = 4 ] \
      || { echo "::error::glib gatomic.h patch did not apply"; exit 1; }
    # gdbus-codegen sorts versions with distutils, gone since Python 3.12
    U="$S/glib/gio/gdbus-2.0/codegen/utils.py"
    sed -i '' -e 's/^import distutils\.version$/import re/' \
      -e "s/distutils\.version\.LooseVersion(v)/[int(x) for x in re.findall(r'[0-9]+', v)]/" "$U"
    grep -q 'distutils' "$U" && { echo "::error::glib gdbus-codegen patch did not apply"; exit 1; }
    # --disable-compile-warnings drops glib's own -Werror=... set (C89
    # declarations, format checks) that current clang trips over in 2.56.
    # MSGFMT: only checked for, never run (po/ isn't built)
    conf "$S/glib" --with-pcre=internal --with-libiconv=native --disable-libmount \
      --disable-fam --disable-selinux --disable-libelf --disable-dtrace \
      --disable-systemtap --disable-gtk-doc --disable-man --with-python="$PYTHON" \
      --disable-compile-warnings \
      MSGFMT=/usr/bin/true GMSGFMT=/usr/bin/true \
      glib_cv_stack_grows=no glib_cv_uscore=no glib_cv_rtldglobal_broken=no \
      glib_cv_va_val_copy=$VACOPY glib_cv_compliant_posix_memalign=1 \
      glib_cv_have_strlcpy=yes glib_cv_long_long_format=ll \
      ac_cv_func_posix_getpwuid_r=yes ac_cv_func_posix_getgrgid_r=yes \
      LIBFFI_CFLAGS="-I$SDK/usr/include/ffi" LIBFFI_LIBS="-lffi"
    # poll() on macOS fails on devices; a native configure detects it
    grep -q '^#define BROKEN_POLL' "$S/glib/config.h" && { echo "::error::BROKEN_POLL already set"; exit 1; }
    echo '#define BROKEN_POLL 1' >> "$S/glib/config.h"
    for d in glib gmodule gthread gobject gio; do
      make -C "$S/glib/$d" -j"$JOBS"
    done
    for d in glib gmodule gthread gobject; do
      make -C "$S/glib/$d" install
    done
    # SUBDIRS=. skips installing gdbus-codegen, whose byte-compile step
    # needs the imp module (gone since Python 3.12); nothing here uses it
    make -C "$S/glib/gio" install SUBDIRS=.
    make -C "$S/glib" install-pkgconfigDATA
    touch "$P/.done-glib"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-croco" ]; then
    echo "::group::libcroco $A"
    unpack libcroco-0.6.13.tar.xz "$S/croco"
    conf "$S/croco" --disable-gtk-doc --disable-Bsymbolic
    make -C "$S/croco/src" -j"$JOBS"
    make -C "$S/croco/src" install
    make -C "$S/croco" install-pkgconfigDATA
    touch "$P/.done-croco"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-pixbuf" ]; then
    echo "::group::gdk-pixbuf $A"
    unpack gdk-pixbuf-2.36.12.tar.xz "$S/pixbuf"
    conf "$S/pixbuf" --disable-modules --with-included-loaders=png,jpeg \
      --without-libtiff --without-libjasper --without-x11 --disable-introspection \
      --disable-man --disable-gtk-doc --disable-installed-tests
    make -C "$S/pixbuf/gdk-pixbuf" -j"$JOBS"
    make -C "$S/pixbuf/gdk-pixbuf" install
    make -C "$S/pixbuf" install-pkgconfigDATA
    touch "$P/.done-pixbuf"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-cairo" ]; then
    echo "::group::cairo $A"
    unpack cairo-1.16.0.tar.xz "$S/cairo"
    conf "$S/cairo" --enable-quartz=yes --enable-quartz-font=yes --enable-quartz-image=yes \
      --enable-png=yes --enable-pdf=yes --enable-ps=yes --enable-svg=yes --enable-xml=yes \
      --enable-ft=no --enable-fc=no --enable-xlib=no --enable-xlib-xrender=no \
      --enable-xcb=no --enable-gobject=no --enable-script=no --enable-interpreter=no \
      --enable-trace=no --enable-symbol-lookup=no --enable-gl=no --enable-valgrind=no \
      --disable-valgrind --disable-gtk-doc
    make -C "$S/cairo/src" -j"$JOBS"
    make -C "$S/cairo/src" install
    touch "$P/.done-cairo"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-fribidi" ]; then
    echo "::group::fribidi $A"
    unpack fribidi-1.0.13.tar.xz "$S/fribidi"
    conf "$S/fribidi" --disable-docs
    make -C "$S/fribidi/gen.tab" -j"$JOBS"
    make -C "$S/fribidi/lib" -j"$JOBS"
    make -C "$S/fribidi/lib" install
    make -C "$S/fribidi" install-pkgconfigDATA
    touch "$P/.done-fribidi"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-pango" ]; then
    echo "::group::pango $A"
    unpack pango-1.42.4.tar.xz "$S/pango"
    conf "$S/pango" --disable-Bsymbolic --with-xft=no --disable-introspection --disable-gtk-doc --disable-installed-tests
    grep -q '^#define HAVE_CAIRO_QUARTZ 1' "$S/pango/config.h" || { echo "::error::pango: no cairo-quartz font backend"; exit 1; }
    make -C "$S/pango/pango" -j"$JOBS"
    make -C "$S/pango/pango" install
    make -C "$S/pango" install-pkgconfigDATA
    touch "$P/.done-pango"
    echo "::endgroup::"
  fi

  if [ ! -f "$P/.done-rsvg" ]; then
    echo "::group::librsvg $A"
    unpack librsvg-2.40.21.tar.xz "$S/rsvg"
    # configure requires pangoft2 + fontconfig outside Windows, but the
    # library uses them only for its test-suite font setup
    # (HAVE_PANGOFT2). Give it the real module list without pangoft2 and
    # undefine HAVE_PANGOFT2 after configure.
    RSVG_MODS="gdk-pixbuf-2.0 glib-2.0 gio-2.0 libxml-2.0 pangocairo cairo cairo-png libcroco-0.6"
    conf "$S/rsvg" --disable-Bsymbolic --disable-pixbuf-loader --disable-introspection --disable-vala \
      --disable-tools --disable-gtk-doc --disable-installed-tests \
      LIBRSVG_CFLAGS="$($PKG_CONFIG --cflags $RSVG_MODS)" \
      LIBRSVG_LIBS="$($PKG_CONFIG --libs $RSVG_MODS)" \
      PANGOFT2_CFLAGS=" " PANGOFT2_LIBS=" " FONTCONFIG_CFLAGS=" " FONTCONFIG_LIBS=" "
    sed -i '' -e 's/^#define HAVE_PANGOFT2 1$/#undef HAVE_PANGOFT2/' "$S/rsvg/config.h"
    grep -q '^#undef HAVE_PANGOFT2$' "$S/rsvg/config.h"
    make -C "$S/rsvg" -j"$JOBS" librsvg-2.la
    make -C "$S/rsvg" install-libLTLIBRARIES install-librsvgincHEADERS install-pkgconfigDATA
    touch "$P/.done-rsvg"
    echo "::endgroup::"
  fi
done
unset CC CXX OBJC CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS PKG_CONFIG PKG_CONFIG_LIBDIR

LIBS="librsvg-2 libcroco-0.6 libgdk_pixbuf-2.0 libpangocairo-1.0 libpango-1.0 libfribidi
      libcairo libpixman-1 libpng16 libjpeg libgio-2.0 libgobject-2.0 libgmodule-2.0
      libglib-2.0 libintl"
for L in $LIBS; do
  lipo -create "$WORK"/arm64/prefix/lib/$L.a "$WORK"/x86_64/prefix/lib/$L.a -output "$OUT/$L.a"
done

# headers as committed in include/mac: one tree per package, plus the
# private rsvg-css.h (rsvg_css_parse_color) and the headers it pulls in
HDR="$WORK/include-mac"
rm -rf "${HDR:?}"; mkdir -p "$HDR"
for A in $ARCHS; do
  H="$WORK/$A/include-mac"; I="$WORK/$A/prefix/include"
  rm -rf "${H:?}"; mkdir -p "$H/librsvg-2.0/librsvg"
  cp -R "$I/glib-2.0" "$I/cairo" "$I/pango-1.0" "$I/gdk-pixbuf-2.0" "$H/"
  cp "$WORK/$A/prefix/lib/glib-2.0/include/glibconfig.h" "$H/glibconfig-$A.h"
  cp "$I"/librsvg-2.0/librsvg/*.h "$H/librsvg-2.0/librsvg/"
  for f in rsvg-css.h rsvg-private.h rsvg-defs.h rsvg-size-callback.h; do
    cp "$WORK/$A/src/rsvg/$f" "$H/librsvg-2.0/librsvg/"
  done
done
# both slices must have been configured identically, except glibconfig.h
# (va_list is an array on x86_64; arm64 needs atomic memory barriers),
# which gets a per-arch copy behind a dispatching glibconfig.h
diff -r -x 'glibconfig-*.h' "$WORK/arm64/include-mac" "$WORK/x86_64/include-mac"
cp -R "$WORK/arm64/include-mac/." "$HDR/"
cp "$WORK/x86_64/include-mac/glibconfig-x86_64.h" "$HDR/"
cat > "$HDR/glibconfig.h" <<'EOF'
/* glibconfig.h differs between the slices of the universal build */
#if defined(__x86_64__)
#include "glibconfig-x86_64.h"
#elif defined(__arm64__) || defined(__aarch64__)
#include "glibconfig-arm64.h"
#else
#error "glibconfig.h: unsupported architecture"
#endif
EOF

if [ "${UPDATE_HEADERS:-0}" = 1 ]; then
  rm -rf "${ROOT:?}/include/mac"
  cp -R "$HDR" "$ROOT/include/mac"
  echo "include/mac updated"
elif ! diff -r "$HDR" "$ROOT/include/mac" >/dev/null; then
  diff -rq "$HDR" "$ROOT/include/mac" || true
  echo "::error::include/mac differs from the headers of the pinned versions (rerun with UPDATE_HEADERS=1)"
  exit 1
fi

# every output must carry both slices and target macOS $MIN at most
for L in $LIBS; do
  for A in $ARCHS; do
    lipo "$OUT/$L.a" -verify_arch "$A" || { echo "::error::$L.a lacks $A"; exit 1; }
    # objects without code (no LC_BUILD_VERSION) are skipped
    M="$(otool -arch "$A" -l "$OUT/$L.a" | awk '$1=="minos"{print $2}' | sort -t. -k1,1n -k2,2n | tail -1)"
    if [ -n "$M" ] && [ "$(printf '%s\n%s\n' "$M" "$MIN" | sort -t. -k1,1n -k2,2n | tail -1)" != "$MIN" ]; then
      echo "::error::$L.a ($A) has minos $M > $MIN"; exit 1
    fi
  done
  echo "$L.a: $(lipo -archs "$OUT/$L.a")"
done
