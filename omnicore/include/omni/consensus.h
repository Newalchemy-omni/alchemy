// Copyright (c) 2013-2024 The Omni Core developers
// Distributed under the MIT software license.

#ifndef OMNICORE_CONSENSUS_H
#define OMNICORE_CONSENSUS_H

#include <cstdint>
#include <string>
#include <vector>

namespace omni {

/// Omni transaction types (subset; see doc/spec.md for full list).
enum class TxType : uint16_t {
    SIMPLE_SEND          = 0,
    RESTRICTED_SEND      = 2,
    SEND_TO_OWNERS       = 3,
    SEND_ALL             = 4,
    DEX_SELL_OFFER       = 20,
    DEX_ACCEPT_OFFER     = 22,
    METADEX_TRADE        = 25,
    METADEX_CANCEL       = 26,
    CREATE_PROPERTY_FIXED   = 50,
    CREATE_PROPERTY_VAR     = 51,
    CREATE_PROPERTY_CROWD   = 53,
    CLOSE_CROWDSALE         = 54,
    CREATE_PROPERTY_MANUAL  = 55,
    GRANT_PROPERTY_TOKENS   = 56,
    REVOKE_PROPERTY_TOKENS  = 57,
    CHANGE_ISSUER           = 70,
    FREEZE_PROPERTY_TOKENS  = 185,
    UNFREEZE_PROPERTY_TOKENS= 186,
    ENABLE_FREEZING         = 187,
    DISABLE_FREEZING        = 188,
};

/// Ecosystem selector (main / test).
enum Ecosystem : uint8_t { ECO_MAIN = 1, ECO_TEST = 2 };

/// Balance triple (available / reserved / frozen).
struct Balance {
    int64_t available = 0;
    int64_t reserved  = 0;
    int64_t frozen    = 0;
};

/// Public consensus/state entry points. These are the functions that a host
/// (Bitcoin Core, indexer, explorer) must call on new blocks.
namespace consensus {

/// Initialize consensus state (called once at startup).
bool Init();

/// Process all Omni transactions contained in a connected block.
/// @param blockHeight       block height being connected
/// @param blockTime         unix timestamp of the block
/// @param txHexes           serialized bitcoin transactions in the block
/// @returns true on success
bool ConnectBlock(int blockHeight, uint32_t blockTime,
                  const std::vector<std::vector<uint8_t>>& txHexes);

/// Rollback state to before the given block height (disconnect).
bool DisconnectBlock(int blockHeight);

/// Query the balance of an address for a specific property.
Balance GetBalance(const std::string& address, uint32_t propertyId);

/// Return total number of existing properties (ecosystem-wide).
uint32_t NumProperties(Ecosystem eco);

} // namespace consensus
} // namespace omni

#endif
