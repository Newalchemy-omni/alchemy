// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT

#ifndef OMNICORE_DEX_H
#define OMNICORE_DEX_H

#include <cstdint>
#include <string>

namespace omni {
namespace dex {

/// A sell offer on the traditional DEx (property-for-BTC).
struct SellOffer {
    std::string seller;
    uint32_t    propertyId;
    int64_t     amountForSale;
    int64_t     amountRemaining;
    int64_t     bitcoinPricePerCoinDesired;  // satoshis per unit, 8-dec scaled
    uint8_t     action;   // 1=new, 2=update, 3=cancel
    uint32_t    block;
};

/// A MetaDEx (token-vs-token) order.
struct MetaOrder {
    std::string maker;
    uint32_t    propertyForSale;
    int64_t     amountForSale;
    uint32_t    propertyDesired;
    int64_t     amountDesired;
    uint32_t    block;
};

/// Place a traditional DEx sell offer (called by consensus parser).
bool AddSellOffer(const SellOffer& o);

/// Match a traditional DEx accept against the existing book.
/// @param buyer        accepting address
/// @param propertyId   property being bought
/// @param amount       amount to buy
/// @returns true if accepted (reserves funds, opens escrow)
bool AcceptSellOffer(const std::string& buyer, uint32_t propertyId, int64_t amount);

/// Add a MetaDEx order; returns true if matched & settled immediately.
bool AddMetaOrder(const MetaOrder& o, bool* wasFilled);

/// Cancel MetaDEx order.
bool CancelMetaOrder(const std::string& maker, uint32_t propSale, uint32_t propDesired);

} // namespace dex
} // namespace omni

#endif
