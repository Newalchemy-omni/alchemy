// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
#include <omni/version.h>
#include <sstream>

namespace omni {

unsigned int Major() { return OMNICORE_VERSION_MAJOR; }
unsigned int Minor() { return OMNICORE_VERSION_MINOR; }
unsigned int Patch() { return OMNICORE_VERSION_PATCH; }

const char* Version() {
    static const std::string v = []{
        std::ostringstream oss;
        oss << "Omni Core v" << OMNICORE_VERSION_STRING;
        return oss.str();
    }();
    return v.c_str();
}

} // namespace omni
