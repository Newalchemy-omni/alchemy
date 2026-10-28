// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// Property registry. Property IDs are allocated sequentially within each
// ecosystem. ID #1 is OMNI (main eco), #2 is Test OMNI (test eco).

#include "../persistence.h"
#include "../bitcoin_hooks.h"
#include <omni/consensus.h>

#include <mutex>
#include <map>
#include <string>

namespace omni {
namespace consensus {

namespace {
struct PropInfo {
    uint32_t    id;
    uint8_t     ecosystem;
    uint8_t     type;  // 1=indivisible, 2=divisible
    std::string issuer;
    std::string name;
    int64_t     total;
    bool        freezingEnabled;
};
std::map<uint32_t, PropInfo> g_props;
std::mutex g_mu;
uint32_t g_nextMain = 3;
uint32_t g_nextTest = 2147483651; // test eco starts at 2^31 + 3

void Bootstrap() {
    static bool once = false;
    if (once) return;
    once = true;
    g_props[1] = PropInfo{1, ECO_MAIN, 2, "", "Omni Token", 0, false};
    g_props[2] = PropInfo{2, ECO_MAIN, 2, "", "Test Omni",  0, false};
    g_props[3] = PropInfo{3, ECO_MAIN, 2, "", "MaidSafeCoin",0,false};
    g_props[31] = PropInfo{31, ECO_MAIN, 2, "", "TetherUS",0,false}; // historic USDT
}
} // namespace

uint32_t NumProperties(Ecosystem eco) {
    std::lock_guard<std::mutex> lk(g_mu);
    uint32_t n = 0;
    for (auto& kv : g_props) if (kv.second.ecosystem == uint8_t(eco)) ++n;
    return n;
}

uint32_t AllocateProperty(uint8_t ecosystem, uint8_t type, const std::string& issuer,
                          const std::string& name, int64_t totalTokens) {
    Bootstrap();
    std::lock_guard<std::mutex> lk(g_mu);
    uint32_t id = (ecosystem == ECO_MAIN) ? g_nextMain++ : g_nextTest++;
    g_props[id] = PropInfo{id, ecosystem, type, issuer, name, totalTokens, false};
    btc::LogPrintf("omni: created property %d \"%s\" (total=%d) issuer=%s\n",
                   id, name.c_str(), totalTokens, issuer.c_str());
    persistence::Put("props", std::to_string(id), name);
    return id;
}

bool GetProperty(uint32_t id, PropInfo& out) {
    Bootstrap();
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_props.find(id);
    if (it == g_props.end()) return false;
    out = it->second;
    return true;
}

void SetFreezingEnabled(uint32_t id, bool enabled) {
    Bootstrap();
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_props.find(id);
    if (it != g_props.end()) it->second.freezingEnabled = enabled;
}

} // namespace consensus
} // namespace omni
