// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// Wallet helpers: encode Omni payloads into Bitcoin transactions.
//
// In the upstream Omni Core fork this file integrates with Bitcoin Core's
// CWallet; here we expose a minimal payload builder so any host can craft
// embedding transactions (OP_RETURN with Class C encoding).

#include <vector>
#include <cstdint>
#include <cstring>

namespace omni {
namespace wallet {

// Omni "Class C" (OP_RETURN) prefix: omni marker + version
static const uint8_t OMNI_PREFIX[] = { 'o','m','n','i' };
static const uint16_t OMNI_VERSION = 0x0000;

/// Build an Omni Class C (OP_RETURN) payload for a Simple Send (type 0).
/// Payload format: [4B "omni"][2B version][4B txType][4B propertyId][8B amount]
std::vector<uint8_t> BuildSimpleSend(uint32_t propertyId, int64_t amount) {
    std::vector<uint8_t> out;
    out.insert(out.end(), OMNI_PREFIX, OMNI_PREFIX + 4);
    auto pushU16 = [&](uint16_t v) { out.push_back(v >> 8); out.push_back(v & 0xff); };
    auto pushU32 = [&](uint32_t v) { for (int i=3;i>=0;--i) out.push_back((v >> (i*8)) & 0xff); };
    auto pushI64 = [&](int64_t v) { for (int i=7;i>=0;--i) out.push_back((v >> (i*8)) & 0xff); };
    pushU16(OMNI_VERSION);
    pushU32(0); // SIMPLE_SEND = type 0
    pushU32(propertyId);
    pushI64(amount);
    return out;
}

/// Build payload for Send-To-Owners (type 3).
std::vector<uint8_t> BuildSendToOwners(uint32_t propertyId, int64_t amount) {
    std::vector<uint8_t> out;
    out.insert(out.end(), OMNI_PREFIX, OMNI_PREFIX + 4);
    auto pushU16 = [&](uint16_t v) { out.push_back(v >> 8); out.push_back(v & 0xff); };
    auto pushU32 = [&](uint32_t v) { for (int i=3;i>=0;--i) out.push_back((v >> (i*8)) & 0xff); };
    auto pushI64 = [&](int64_t v) { for (int i=7;i>=0;--i) out.push_back((v >> (i*8)) & 0xff); };
    pushU16(OMNI_VERSION);
    pushU32(3);
    pushU32(propertyId);
    pushI64(amount);
    return out;
}

/// Build payload for Create Property Fixed (type 50).
/// Fields (simplified): ecosystem(1), type(2), previousId(4), category(v), subcategory(v),
///                      name(v), url(v), data(v), total(8)
/// Variable-length strings are 1-byte length + utf-8 bytes (max 255).
std::vector<uint8_t> BuildCreatePropertyFixed(
    uint8_t ecosystem, uint16_t propType,
    const std::string& category, const std::string& subcategory,
    const std::string& name, const std::string& url, const std::string& data,
    int64_t totalTokens)
{
    std::vector<uint8_t> out;
    out.insert(out.end(), OMNI_PREFIX, OMNI_PREFIX + 4);
    auto pushU16 = [&](uint16_t v) { out.push_back(v >> 8); out.push_back(v & 0xff); };
    auto pushU32 = [&](uint32_t v) { for (int i=3;i>=0;--i) out.push_back((v >> (i*8)) & 0xff); };
    auto pushI64 = [&](int64_t v) { for (int i=7;i>=0;--i) out.push_back((v >> (i*8)) & 0xff); };
    auto pushStr = [&](const std::string& s) {
        out.push_back(static_cast<uint8_t>(s.size() > 255 ? 255 : s.size()));
        out.insert(out.end(), s.begin(), s.begin() + (s.size() > 255 ? 255 : s.size()));
    };
    pushU16(OMNI_VERSION);
    pushU32(50);
    out.push_back(ecosystem);
    pushU16(propType);
    pushU32(0); // previousId
    pushStr(category);
    pushStr(subcategory);
    pushStr(name);
    pushStr(url);
    pushStr(data);
    pushI64(totalTokens);
    return out;
}

} // namespace wallet
} // namespace omni
