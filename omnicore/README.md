# Omni Core (Omni Layer)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![C++](https://img.shields.io/badge/C%2B%2B-17-00599C?logo=cplusplus)](https://isocpp.org/)
[![Bitcoin](https://img.shields.io/badge/Bitcoin-Layer-ff9900?logo=bitcoin)](https://bitcoin.org/)

> Omni Core is a fast, portable implementation of the Omni protocol — a second-layer token & smart-contract platform anchored to Bitcoin. This repository packages the Omni-layer consensus engine, RPC interface, DEX, crowdsale and metadata logic as a standalone library suitable for embedding into Bitcoin Core (as in the official `OmniLayer/omnicore` fork), indexers, or block explorers.

## About Omni Layer

Omni (originally "Mastercoin") was the first token layer on Bitcoin. It uses Bitcoin's
`OP_RETURN` (and previously `multisig`-encumbered) outputs to encode asset-creation,
transfer, decentralized-exchange, crowdsale and "send-to-owners" transactions. All Omni
transactions are embedded in ordinary Bitcoin transactions and inherit Bitcoin's security
guarantees.

Key features:

- **Smart Property** — create fixed / managable / crowdsale tokens on Bitcoin
- **Crowdsales** — on-chain participatory token launches
- **Distributed Token Exchange** — on-chain order book between any Omni property and BTC / OMNI
- **Send-To-Owners (STO)** — pro-rata distributions to all token holders
- **Meta-DEx** — the original on-chain DEX
- **Freeze / Granular Freeze** — compliance-grade controls for regulated issuers
- **Cross-chain** — anchored on Bitcoin, with bridge logic for OmniBOLT / Omni on other chains

## Repository layout

```
├── configure.ac / Makefile.am   # autotools build (mirrors upstream Omni Core)
├── doc/                         # protocol spec & release notes
├── include/omni/                # public C++ headers
└── src/
    ├── consensus/               # tx parsing & consensus rules
    │   ├── parsing.cpp          #   Class C / Class B / Class D payload decoders
    │   ├── tx.cpp               #   apply transactions to the state
    │   ├── metadex.cpp          #   distributed exchange matching
    │   ├── crowdsale.cpp        #   crowdsale participation / close-out
    │   ├── sto.cpp              #   send-to-owners distribution math
    │   ├── properties.cpp       #   property / ecosystem registry
    │   └── freeze.cpp           #   granular freeze
    ├── rpc/                     # Bitcoin-RPC command handlers
    ├── omnicore.cpp             # entry / init / shutdown
    ├── wallet.cpp               # wallet hooks (spend creation, coin selection)
    ├── persistence.cpp          # leveldb-backed state persistence
    ├── dex.cpp                  # DEX order book & RPC helpers
    ├── version.cpp
    └── bitcoin_hooks.h          # minimal Bitcoin Core integration surface
```

## Building

```bash
./autogen.sh
./configure
make -j$(nproc)
sudo make install
```

To embed into Bitcoin Core, build with `--enable-bitcoin-embed` and link the resulting
`libomnicore.a` against the Bitcoin Core source tree; `src/bitcoin_hooks.h` defines the
small integration surface (block connected/disconnected callbacks, RPC registration,
wallet access, logging).

## RPC surface

Omni Core exposes a rich RPC. A small subset:

| Call | Description |
|------|-------------|
| `omni_getinfo` | node & consensus info |
| `omni_listproperties` | list all smart properties |
| `omni_getproperty` | get property metadata |
| `omni_getbalance` | get balance for an address/property |
| `omni_send` | create a simple send |
| `omni_senddexsell` | place a DEx sell offer |
| `omni_sendsto` | send-to-owners |
| `omni_sendcrowdsale` | participate in a crowdsale |
| `omni_getactivecrowdsales` | list active crowdsales |
| `omni_gettransaction` | decode an Omni transaction |

## Tags / metadata

- `bitcoin`
- `omni`
- `omni-layer`
- `omnicore`
- `mastercoin`
- `tokens`
- `smart-property`
- `dex`

## Relationship to upstream

This repository is a clean-room repackaging of the Omni layer logic found in the
upstream [`OmniLayer/omnicore`](https://github.com/OmniLayer/omnicore) Bitcoin fork,
made available as a standalone library so that the consensus engine can be embedded
in non-Bitcoin-Core hosts (indexers, explorers, academic research, alternative nodes).
Consensus behavior is byte-compatible with upstream Omni Core at the referenced
height (see `doc/spec.md`).

## License

MIT (same as upstream Omni Core).
