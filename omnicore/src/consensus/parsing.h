// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
#ifndef OMNICORE_CONSENSUS_PARSING_H
#define OMNICORE_CONSENSUS_PARSING_H

#include <cstdint>
#include <string>
#include <vector>

namespace omni {
namespace consensus {

/// Decoded Omni transaction payload.
struct ParsedTx {
    uint16_t version;
    uint16_t type;
    uint32_t propertyId;
    int64_t  amount;
    // extra fields used by other tx types
    uint32_t propertyDesired = 0;
    int64_t  amountDesired   = 0;
    uint64_t deadlineBlock   = 0;
    uint8_t  ecosystem       = 0;
    uint8_t  action          = 0;
    std::string sender;
    std::string reference;   // recipient / property change target
};

/// Detect whether a Bitcoin tx output script carries an Omni payload, and if so,
/// return the embedded payload (Class B multisig, Class C OP_RETURN). Implements
/// the full Omni payload-detection rules:
///   - Class B: bare 1-of-N multisig with N=3 and the first data push being "omni"
///   - Class C: OP_RETURN starting with 0x6f6d6e69 ("omni")
/// @param script   the Bitcoin scriptPubKey
/// @param payload  out: raw Omni payload stripped of the 4-byte "omni" marker
/// @returns        true if an Omni payload was found
bool ParseOmniPayload(const std::vector<uint8_t>& script, std::vector<uint8_t>& payload);

/// Deserialize a payload into a ParsedTx.
bool InterpretPayload(const std::vector<uint8_t>& payload, ParsedTx& out);

} // namespace consensus
} // namespace omni

#endif
