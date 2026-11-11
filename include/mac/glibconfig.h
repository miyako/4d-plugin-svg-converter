/* glibconfig.h differs between the slices of the universal build */
#if defined(__x86_64__)
#include "glibconfig-x86_64.h"
#elif defined(__arm64__) || defined(__aarch64__)
#include "glibconfig-arm64.h"
#else
#error "glibconfig.h: unsupported architecture"
#endif
