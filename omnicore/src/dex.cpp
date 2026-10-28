// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// Distributed Token Exchange (DEx) + MetaDEx in-memory order book.
// The real implementation persists orders across blocks and matches by
// price/time priority; this file exposes the canonical state machine.

#include <omni/dex.h>
#include <map>
#include <mutex>
#include <vector>

namespace omni {
namespace dex {

namespace {
struct OfferKey {
    uint32_t propertyId;
    std::string seller;
    bool operator<(const OfferKey& o) const {
        if (propertyId != o.propertyId) return propertyId < o.propertyId;
        return seller < o.seller;
    }
};
std::map<OfferKey, SellOffer> g_offers;
std::vector<MetaOrder> g_meta;
std::mutex g_mu;
} // namespace

bool AddSellOffer(const SellOffer& o) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (o.action == 3 /* cancel */) {
        g_offers.erase({o.propertyId, o.seller});
        return true;
    }
    g_offers[{o.propertyId, o.seller}] = o;
    return true;
}

bool AcceptSellOffer(const std::string& buyer, uint32_t propertyId, int64_t amount) {
    std::lock_guard<std::mutex> lk(g_mu);
    // Match against the cheapest offer first (price ascending). A full
    // implementation would sort the book; for the reference skeleton we
    // walk and fill against the first offer with enough remaining.
    for (auto& kv : g_offers) {
        if (kv.first.propertyId != propertyId) continue;
        SellOffer& offer = kv.second;
        if (offer.amountRemaining < amount) continue;
        offer.amountRemaining -= amount;
        if (offer.amountRemaining == 0) g_offers.erase(kv.first);
        return true;
    }
    return false; // no matching offer
}

bool AddMetaOrder(const MetaOrder& o, bool* wasFilled) {
    std::lock_guard<std::mutex> lk(g_mu);
    // Attempt to match against an existing inverse order.
    for (auto it = g_meta.begin(); it != g_meta.end(); ++it) {
        if (it->propertyForSale == o.propertyDesired &&
            it->propertyDesired == o.propertyForSale) {
            // price matches iff (it.amountDesired/it.amountForSale) ==
            //                  (o.amountForSale/o.amountDesired) — simplified:
            if (it->amountForSale * o.amountDesired == it->amountDesired * o.amountForSale) {
                g_meta.erase(it);
                if (wasFilled) *wasFilled = true;
                return true;
            }
        }
    }
    g_meta.push_back(o);
    if (wasFilled) *wasFilled = false;
    return true;
}

bool CancelMetaOrder(const std::string& maker, uint32_t propSale, uint32_t propDesired) {
    std::lock_guard<std::mutex> lk(g_mu);
    for (auto it = g_meta.begin(); it != g_meta.end(); ++it) {
        if (it->maker == maker && it->propertyForSale == propSale && it->propertyDesired == propDesired) {
            g_meta.erase(it);
            return true;
        }
    }
    return false;
}

} // namespace dex
} // namespace omni
