// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
// Granular & global freeze handling (types 185-188).

#include "../persistence.h"
#include <map>
#include <mutex>
#include <string>

namespace omni {
namespace consensus {

namespace {
struct FreezeKey {
    uint32_t propertyId;
    std::string address;
    bool operator<(const FreezeKey& o) const {
        if (propertyId != o.propertyId) return propertyId < o.propertyId;
        return address < o.address;
    }
};
std::map<FreezeKey, int64_t> g_frozen;
std::map<uint32_t, bool> g_allFrozen;
std::mutex g_mu;
}

bool FreezeAddress(uint32_t propertyId, const std::string& addr, int64_t amount) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_frozen[{propertyId, addr}] += amount;
    return persistence::Put("freeze", std::to_string(propertyId)+"/"+addr,
                            std::to_string(g_frozen[{propertyId, addr}]));
}

bool UnfreezeAddress(uint32_t propertyId, const std::string& addr, int64_t amount) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto& bal = g_frozen[{propertyId, addr}];
    bal -= amount;
    if (bal < 0) bal = 0;
    return persistence::Put("freeze", std::to_string(propertyId)+"/"+addr, std::to_string(bal));
}

int64_t GetFrozenBalance(uint32_t propertyId, const std::string& addr) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_allFrozen[propertyId]) return INT64_MAX;
    return g_frozen[{propertyId, addr}];
}

void SetFreezeAll(uint32_t propertyId, bool frozen) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_allFrozen[propertyId] = frozen;
}

} // namespace consensus
} // namespace omni
