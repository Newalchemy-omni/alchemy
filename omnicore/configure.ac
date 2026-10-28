AC_PREREQ([2.69])
AC_INIT([omnicore], [0.12.0], [https://github.com/OmniLayer/omnicore/issues])
AC_CONFIG_SRCDIR([src/omnicore.cpp])
AC_CONFIG_HEADERS([config.h])
AC_CONFIG_MACRO_DIRS([m4])

AM_INIT_AUTOMAKE([1.14 foreign subdir-objects -Wall -Werror])
AM_SILENT_RULES([yes])

AC_PROG_CXX
AC_PROG_CC
AX_CXX_COMPILE_STDCXX([17], [noext], [mandatory])

LT_INIT

# --- dependencies ---------------------------------------------------------
AC_CHECK_LIB([leveldb], [leveldb_open], [], [AC_MSG_ERROR([leveldb is required])])
PKG_CHECK_MODULES([BOOST], [boost_system boost_filesystem boost_thread], [],
                  [AC_MSG_ERROR([boost system/filesystem/thread required])])

AC_ARG_ENABLE([bitcoin-embed],
  AS_HELP_STRING([--enable-bitcoin-embed], [Build hooks for embedding into Bitcoin Core]),
  [enable_bitcoin_embed=$enableval], [enable_bitcoin_embed=no])
AM_CONDITIONAL([EMBED_BITCOIN], [test "x$enable_bitcoin_embed" = "xyes"])

AC_CONFIG_FILES([Makefile])
AC_OUTPUT
