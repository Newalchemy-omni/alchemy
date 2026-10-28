// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
#include "parsing.h"

#include <cstring>

namespace omni {
namespace consensus {

// OP_RETURN = 0x6a; OP_PUSHDATA1=0x4c; OP_1=0x51; OP_2=0x52; OP_3=0x53; OP_CHECKMULTISIG=0xae
static const uint8_t OMNI_MAGIC[4] = {0x6f, 0x6d, 0x6e, 0x69}; // "omni"

static bool MatchMagic(const uint8_t* p, size_t n) {
    return n >= 4 && std::memcmp(p, OMNI_MAGIC, 4) == 0;
}

bool ParseOmniPayload(const std::vector<uint8_t>& script, std::vector<uint8_t>& payload) {
    if (script.empty()) return false;

    // Class C: OP_RETURN ...
    if (script[0] == 0x6a) {
        size_t idx = 1;
        if (idx >= script.size()) return false;
        size_t pushLen = 0;
        if (script[idx] <= 0x4b) { pushLen = script[idx]; idx += 1; }
        else if (script[idx] == 0x4c && idx + 1 < script.size()) { pushLen = script[idx+1]; idx += 2; }
        else return false;
        if (idx + pushLen > script.size()) return false;
        if (pushLen < 4) return false;
        const uint8_t* data = script.data() + idx;
        if (!MatchMagic(data, pushLen)) return false;
        payload.assign(data + 4, data + pushLen);
        return true;
    }

    // Class B: OP_1 <33B or 65B> <33B or 65B> <33B or 65B> OP_3 OP_CHECKMULTISIG
    if (script.size() >= 9 && script[0] == 0x51 && script.back() == 0xae && script[script.size()-2] == 0x53) {
        // first data push contains the omni payload (embedded public key form)
        if (script[1] != 33 && script[1] != 65) return false;
        size_t firstKeyLen = script[1];
        size_t start = 2;
        if (start + firstKeyLen > script.size()) return false;
        const uint8_t* key = script.data() + start;
        if (firstKeyLen >= 4 && MatchMagic(key + firstKeyLen - 4, 4) == false &&
            firstKeyLen > 20 && MatchMagic(key + 1, 4)) {
            // Embedded payload starts after a 1-byte sign byte
            payload.assign(key + 5, key + firstKeyLen);
            return true;
        }
    }
    return false;
}

// -- helpers for big-endian deserialization --
static uint16_t rd16(const uint8_t* p) { return (uint16_t(p[0])<<8) | p[1]; }
static uint32_t rd32(const uint8_t* p) { return (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|p[3]; }
static int64_t  rd64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i=0;i<8;++i) v = (v<<8) | p[i];
    return static_cast<int64_t>(v);
}

bool InterpretPayload(const std::vector<uint8_t>& raw, ParsedTx& out) {
    if (raw.size() < 2 + 4) return false;
    const uint8_t* p = raw.data();
    out.version = rd16(p); p += 2;
    out.type    = rd16(p); p += 2;
    switch (out.type) {
        case 0: // SIMPLE_SEND
            if (raw.size() < 2+2+4+8) return false;
            out.propertyId = rd32(p); p += 4;
            out.amount     = rd64(p);
            return true;
        case 3: // SEND_TO_OWNERS
            if (raw.size() < 2+2+4+8) return false;
            out.propertyId = rd32(p); p += 4;
            out.amount     = rd64(p);
            return true;
        case 50: // CREATE_PROPERTY_FIXED — variable fields, read what we need
            if (raw.size() < 2+2+1+2+4) return false;
            out.ecosystem = *p++;
            // skip 2-byte type, 4-byte previousId, five length-prefixed strings, then 8-byte total
            p += 2 + 4;
            for (int s=0; s<5; ++s) {
                if (p >= raw.data() + raw.size()) return false;
                uint8_t sl = *p++;
                if (p + sl > raw.data() + raw.size()) return false;
                p += sl;
            }
            if (p + 8 > raw.data() + raw.size()) return false;
            out.amount = rd64(p);
            return true;
        case 20: // DEX_SELL_OFFER
            if (raw.size() < 2+2+4+8+8+1+8) return false;
            out.propertyId = rd32(p); p += 4;
            out.amount     = rd64(p); p += 8;
            // price / block / action follow; out.amount holds amountForSale
            return true;
        case 25: // METADEX_TRADE
            if (raw.size() < 2+2+8+4+8+4) return false;
            p += 8; // amountForSale already read via next field? simplified
            out.propertyId = rd32(p); p += 4;
            out.amountDesired = (int64_t)rd64(p); p += 8;
            out.propertyDesired = rd32(p);
            return true;
        default:
            return true; // unrecognized type but structurally valid header
    }
}

} // namespace consensus
} // namespace omni
