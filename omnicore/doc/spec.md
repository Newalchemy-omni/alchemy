# Omni Layer Protocol — Specification Summary

This document summarises the Omni Layer transaction serialization used by
Omni Core. For the historical specification, see
<https://github.com/OmniLayer/spec>.

## Encoding Classes

- **Class A** (obsolete): bare `OP_RETURN` with 1-byte marker. No longer used.
- **Class B**: `OP_1 <33B/65B> <33B/65B> <33B/65B> OP_3 OP_CHECKMULTISIG`. The
  first "pubkey" is a 1-byte sign byte (0x00 for mainnet, 0x6f for testnet)
  followed by the 4-byte `"omni"` magic and the payload.
- **Class C**: `OP_RETURN <"omni" + payload>` — the standard encoding since 0.10.

All payloads are big-endian and begin with a 2-byte version (currently `0x0000`)
followed by a 2-byte transaction type.

## Common Transaction Types

| Type | Name | Payload (after 4B header) |
|-----:|------|---------------------------|
|    0 | Simple Send | `propertyId:4 amount:8` |
|    2 | Restricted Send | `propertyId:4 amount:8 recipient(20B hash160 padded)` |
|    3 | Send-To-Owners | `propertyId:4 amount:8` |
|    4 | Send All | `ecosystem:1` |
|   20 | DEx Sell Offer | `propertyId:4 amount:8 price:8 action:1 block:8 minFee:8...` |
|   22 | DEx Accept Offer | `propertyId:4 amount:8 buyer` |
|   25 | MetaDEx Trade | `amountForSale:8 propForSale:4 amountDesired:8 propDesired:4 action:1` |
|   50 | Create Property Fixed | `eco:1 type:2 prevId:4 cat sub name url data total:8` |
|   51 | Create Property Variable | (similar, with issuer-grantable supply) |
|   53 | Create Crowdsale | `eco:1 type:2 prevId:4 ... desiredProp:4 tokensPerUnit:8 deadline:8 ...` |
|   54 | Close Crowdsale | `propertyId:4` |
|   55 | Create Property Manual | (managed supply) |
|   56 | Grant Tokens | `propertyId:4 amount:8 note` |
|   57 | Revoke Tokens | `propertyId:4 amount:8 note` |
|   70 | Change Issuer | `propertyId:4` |
|  185 | Freeze Tokens | `propertyId:4 amount:8 addr(20B)` |
|  186 | Unfreeze Tokens | `propertyId:4 amount:8 addr(20B)` |
|  187 | Enable Freezing | `propertyId:4` |
|  188 | Disable Freezing | `propertyId:4` |

## Identifiers

- Property #1 = OMNI (inherited from MSC)
- Property #2 = Test OMNI (TMSC)
- Property #3 = MaidSafeCoin (historic)
- Property #31 = Tether USD (Omni-era USDT, historic)
- Main ecosystem: IDs `3 .. 2147483647`
- Test ecosystem: IDs `2147483651 .. 4294967295` (i.e. `0x80000003 .. 0xFFFFFFFF`)

## Consensus Rules

- All arithmetic is **integer** (no floating point). Divisible tokens use
  8-decimal fixed point (satoshis-style).
- Send-To-Owners distributes `floor(amount * balance / totalSupply)` to
  each holder; rounding dust returns to the sender.
- Crowdsale early-bonus: linear taper from `bonusPct` (week 0) down to 0%
  at week 10.
- MetaDEx matches if two orders are reciprocal and their implied prices
  cross. Matching is FIFO by price/time priority.
