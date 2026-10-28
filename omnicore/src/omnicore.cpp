// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
#include <omni/omnicore.h>
#include <omni/consensus.h>
#include <omni/version.h>

#include "bitcoin_hooks.h"
#include "persistence.h"
#include "rpc/rpcregister.h"

#include <atomic>
#include <iostream>

namespace omni {

static std::atomic<bool> g_running{false};

bool Start(const std::string& dataDir) {
    if (g_running) return true;
    btc::LogPrintf("%s initializing...\n", Version());
    if (!persistence::Init(dataDir)) {
        std::cerr << "omni: persistence init failed\n";
        return false;
    }
    if (!consensus::Init()) return false;
    rpc::Register();
    g_running = true;
    btc::LogPrintf("omni: started.\n");
    return true;
}

void Stop() {
    if (!g_running) return;
    persistence::Flush();
    rpc::Unregister();
    g_running = false;
    btc::LogPrintf("omni: stopped.\n");
}

bool IsRunning() { return g_running; }

} // namespace omni
