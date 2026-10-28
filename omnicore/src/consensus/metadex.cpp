// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
// MetaDEx: consensus-facing wrapper that translates ParsedTx into dex:: calls.

#include "parsing.h"
#include <omni/dex.h>

namespace omni {
namespace consensus {

bool ApplyMetaDExTrade(const ParsedTx& ptx) {
    // MetaDEx is price-ratio matching (see dex.cpp); the consensus parser simply
    // forwards the (maker, propForSale, amtForSale, propDesired, amtDesired) tuple.
    omni::dex::MetaOrder o;
    o.maker          = ptx.sender;
    o.propertyForSale = ptx.propertyId;
    o.amountForSale   = ptx.amount;
    o.propertyDesired = ptx.propertyDesired;
    o.amountDesired   = ptx.amountDesired;
    o.block           = 0; // filled by caller
    bool filled = false;
    return omni::dex::AddMetaOrder(o, &filled);
}

} // namespace consensus
} // namespace omni
