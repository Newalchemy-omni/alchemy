// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
// Crowdsale participation & closeout (type 53 / 54).

#include "../bitcoin_hooks.h"
#include <map>
#include <mutex>
#include <string>

namespace omni {
namespace consensus {

struct Crowdsale {
    uint32_t propertyId;
    uint32_t desiredProperty;
    int64_t  tokensPerUnit;
    uint64_t deadline;
    uint8_t  earlyBonusPct;
    bool     closed;
    int64_t  tokensIssued;
};

namespace {
std::map<uint32_t, Crowdsale> g_sales;
std::mutex g_mu;
}

void RegisterCrowdsale(uint32_t propertyId, uint32_t desired, int64_t rate,
                       uint64_t deadline, uint8_t bonusPct) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_sales[propertyId] = Crowdsale{propertyId, desired, rate, deadline, bonusPct, false, 0};
}

/// Calculate how many tokens a participant receives for `amountIn` of the desired
/// property, applying the per-week early-bonus schedule.
int64_t Participate(uint32_t propertyId, int64_t amountIn, uint64_t now, int64_t& bonusOut) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_sales.find(propertyId);
    if (it == g_sales.end() || it->second.closed || now > it->second.deadline) return 0;
    Crowdsale& c = it->second;
    // early bonus: up to earlyBonusPct in the first week, linear over 10 weeks (legacy rule)
    uint64_t remaining = (c.deadline > now) ? c.deadline - now : 0;
    uint64_t total = c.deadline - (c.deadline - 7*86400*10); // weeks_total
    uint64_t elapsed = 0;
    if (remaining < 10*7*86400) elapsed = (10*7*86400 - remaining);
    uint64_t pct = 0;
    if (c.earlyBonusPct > 0) {
        uint64_t weeksElapsed = elapsed / (7*86400);
        if (weeksElapsed > 10) weeksElapsed = 10;
        pct = c.earlyBonusPct - (c.earlyBonusPct * weeksElapsed / 10);
    }
    int64_t tokens = amountIn * c.tokensPerUnit;
    int64_t bonus = (tokens * (int64_t)pct) / 100;
    tokens += bonus;
    c.tokensIssued += tokens;
    bonusOut = bonus;
    return tokens;
}

void CloseCrowdsale(uint32_t propertyId) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_sales.find(propertyId);
    if (it != g_sales.end()) it->second.closed = true;
}

} // namespace consensus
} // namespace omni
