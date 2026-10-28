// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
#ifndef OMNICORE_PERSISTENCE_H
#define OMNICORE_PERSISTENCE_H

#include <string>

namespace omni {
namespace persistence {

bool Init(const std::string& dataDir);
void Flush();

/// Key/value store primitives used across consensus modules.
bool Put(const std::string& bucket, const std::string& key, const std::string& value);
bool Get(const std::string& bucket, const std::string& key, std::string& value_out);
bool Del(const std::string& bucket, const std::string& key);

} // namespace persistence
} // namespace omni

#endif
