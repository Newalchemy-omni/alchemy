// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
// Send-To-Owners (type 3): pro-rata distribution to all holders of a property.
//
// STO uses an integer-math distribution rule:
//   - totalSupply S of the property is cached at block time
//   - amount A is distributed
//   - each holder with balance h_i receives floor(A * h_i / S)
//   - dust from rounding is added back to the sender (Omni Foundation spec)
// To keep per-block cost bounded, Omni Core distributes the STO over a sliding
// window; this skeleton implements the core math only.

#include <map>
#include <vector>
#include <cstdint>

namespace omni {
namespace consensus {

struct STODistribution {
    uint32_t propertyId;
    int64_t  totalAmount;
    int64_t  totalSupplySnapshot;
    std::map<std::string, int64_t> balancesSnapshot; // holder -> balance
    std::vector<std::pair<std::string, int64_t>> payouts;
};

int64_t ComputeSTO(STODistribution& dist) {
    if (dist.totalSupplySnapshot <= 0) return 0;
    int64_t distributed = 0;
    for (auto& kv : dist.balancesSnapshot) {
        int64_t share = (dist.totalAmount * kv.second) / dist.totalSupplySnapshot;
        if (share > 0) {
            dist.payouts.emplace_back(kv.first, share);
            distributed += share;
        }
    }
    int64_t remainder = dist.totalAmount - distributed;
    return remainder; // caller adds remainder back to sender
}

} // namespace consensus
} // namespace omni
