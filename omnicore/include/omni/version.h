// Copyright (c) 2013-2024 The Omni Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or https://opensource.org/licenses/MIT.

#ifndef OMNICORE_VERSION_H
#define OMNICORE_VERSION_H

#define OMNICORE_VERSION_MAJOR     0
#define OMNICORE_VERSION_MINOR    12
#define OMNICORE_VERSION_PATCH     0
#define OMNICORE_VERSION_BUILD     0

#define OMNICORE_VERSION_STRING "0.12.0"

namespace omni {
/// Returns a human-readable version string ("Omni Core v0.12.0").
const char* Version();
unsigned int Major();
unsigned int Minor();
unsigned int Patch();
} // namespace omni

#endif
