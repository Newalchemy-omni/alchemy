// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// RPC registration shim. When embedded into Bitcoin Core this file registers
// the omni_* RPC commands against the Bitcoin RPC table; when built standalone
// it's a no-op (consumers drive consensus directly via the C++ API).

#include "rpcregister.h"
#include "../bitcoin_hooks.h"
#include <cstdio>

namespace omni {
namespace rpc {

static bool g_registered = false;

void Register() {
    if (g_registered) return;
    g_registered = true;
    btc::LogPrintf("omni: RPC commands registered (standalone stub).\n");
}

void Unregister() {
    if (!g_registered) return;
    g_registered = false;
    btc::LogPrintf("omni: RPC commands unregistered.\n");
}

} // namespace rpc
} // namespace omni
