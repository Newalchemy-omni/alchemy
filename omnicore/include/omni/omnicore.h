// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// Omni Core — embeddable entry points.

#ifndef OMNICORE_OMNICORE_H
#define OMNICORE_OMNICORE_H

#include <string>

namespace omni {

/// Start the Omni Layer engine. Must be called after the host's block index is loaded.
bool Start(const std::string& dataDir);

/// Stop the engine and flush persistence.
void Stop();

/// Returns true between Start() and Stop().
bool IsRunning();

} // namespace omni

#endif
