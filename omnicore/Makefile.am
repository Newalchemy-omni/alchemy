ACLOCAL_AMFLAGS = -I m4

AM_CPPFLAGS = -I$(top_srcdir)/include $(BOOST_CFLAGS) -DLEVELDB_SUPPORT=1
AM_CXXFLAGS = -Wall -Wextra -Wno-unused-parameter -pthread

lib_LTLIBRARIES = libomnicore.la

libomnicore_la_SOURCES = \
    src/version.cpp \
    src/omnicore.cpp \
    src/wallet.cpp \
    src/persistence.cpp \
    src/dex.cpp \
    src/consensus/parsing.cpp \
    src/consensus/tx.cpp \
    src/consensus/metadex.cpp \
    src/consensus/crowdsale.cpp \
    src/consensus/sto.cpp \
    src/consensus/properties.cpp \
    src/consensus/freeze.cpp \
    src/rpc/rpcregister.cpp

libomnicore_la_LIBADD = $(BOOST_LIBS) -lleveldb -lpthread
libomnicore_la_LDFLAGS = -version-info 0:0:0

include_HEADERS = \
    include/omni/omnicore.h \
    include/omni/version.h \
    include/omni/consensus.h \
    include/omni/dex.h

pkgconfigdir = $(libdir)/pkgconfig
pkgconfig_DATA = libomnicore.pc

EXTRA_DIST = doc/spec.md doc/release-notes.md LICENSE
