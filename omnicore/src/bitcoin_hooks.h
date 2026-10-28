// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// This is the minimal integration surface expected from the host Bitcoin Core node.
// When built standalone (--disable-bitcoin-embed) we provide no-op stubs.

#ifndef OMNICORE_BITCOIN_HOOKS_H
#define OMNICORE_BITCOIN_HOOKS_H

#include <string>
#include <vector>
#include <cstdint>

namespace omni {
namespace btc {

// --- types expected by consensus callbacks ---------------------------------
struct COutPoint { uint8_t txid[32]; uint32_t vout; };
struct CTxOut {
    int64_t nValue;
    std::vector<uint8_t> scriptPubKey;
};

// --- hooks: implemented by the host (or stubs when standalone) -------------
/// Return pubkeyhash / scripthash / segwit address for a scriptPubKey, if any.
bool AddressFromScript(const std::vector<uint8_t>& scriptPubKey, std::string& out);

/// Return Bitcoin balance (satoshi) at an address — used for crowdsale BTC-side math.
int64_t GetBitcoinBalance(const std::string& address);

/// Look up a transaction output by outpoint.
bool GetTxOut(const COutPoint& out, CTxOut& outVal);

/// Host logger.
void LogPrintf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

} // namespace btc
} // namespace omni

#endif
