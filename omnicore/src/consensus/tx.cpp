// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// Apply an Omni transaction against the global state. This is the single
// entry point called by ConnectBlock after the payload has been decoded.
//
// Real Omni Core has many edge cases (cross-property sends, ecosystem
// segregation, fee caching, fee distribution, etc.). This file implements
// the high-level dispatch so modules stay decoupled.

#include "parsing.h"
#include "../bitcoin_hooks.h"
#include "../persistence.h"
#include <omni/consensus.h>
#include <omni/dex.h>

#include <map>
#include <mutex>
#include <string>

namespace omni {
namespace consensus {

namespace {
// (address, property) -> Balance
std::map<std::pair<std::string, uint32_t>, Balance> g_balances;
std::mutex g_mu;

std::string Key(const std::string& a, uint32_t p) { return a + "|" + std::to_string(p); }
}

bool Init() { return true; }

Balance GetBalance(const std::string& address, uint32_t propertyId) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_balances.find({address, propertyId});
    if (it == g_balances.end()) return Balance{};
    return it->second;
}

namespace {
void AddBalance(const std::string& addr, uint32_t prop, int64_t amt) {
    auto& b = g_balances[{addr, prop}];
    b.available += amt;
    persistence::Put("balance", Key(addr, prop),
                     std::to_string(b.available) + "/" +
                     std::to_string(b.reserved) + "/" +
                     std::to_string(b.frozen));
}
void SubBalance(const std::string& addr, uint32_t prop, int64_t amt) {
    auto& b = g_balances[{addr, prop}];
    b.available -= amt;
    persistence::Put("balance", Key(addr, prop),
                     std::to_string(b.available) + "/" +
                     std::to_string(b.reserved) + "/" +
                     std::to_string(b.frozen));
}
} // namespace

bool ApplyTx(const ParsedTx& ptx) {
    std::lock_guard<std::mutex> lk(g_mu);
    switch (ptx.type) {
        case 0: { // SIMPLE_SEND
            if (ptx.amount <= 0) return false;
            SubBalance(ptx.sender,    ptx.propertyId, ptx.amount);
            AddBalance(ptx.reference, ptx.propertyId, ptx.amount);
            btc::LogPrintf("omni: SIMPLE_SEND %d amt=%d from %s to %s\n",
                           ptx.propertyId, ptx.amount, ptx.sender.c_str(), ptx.reference.c_str());
            return true;
        }
        case 3:   // SEND_TO_OWNERS handled in sto.cpp
        case 25:  // METADEX_TRADE handled in metadex.cpp
        case 50:  // CREATE_PROPERTY_FIXED handled in properties.cpp
        case 185: // FREEZE
            return true;
        default:
            return true; // unknown types are parsed but not applied (forward compat)
    }
}

bool ConnectBlock(int /*blockHeight*/, uint32_t /*blockTime*/,
                  const std::vector<std::vector<uint8_t>>& /*txHexes*/) {
    // In a full host, walk every transaction in the block, extract inputs to
    // determine the "sender" (first non-OP_RETURN input's prevout owner), extract
    // the Omni payload from Class B/C outputs, identify reference outputs, then
    // dispatch to ApplyTx. The reference skeleton exposes ApplyTx directly so
    // hosts can drive it from their own transaction-indexing loop.
    return true;
}

bool DisconnectBlock(int /*blockHeight*/) {
    // undo via undo data (omni treats consensus as append-only with rollback
    // records flushed per block).
    return true;
}

} // namespace consensus
} // namespace omni
