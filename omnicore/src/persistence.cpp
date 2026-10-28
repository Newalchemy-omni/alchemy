// Copyright (c) 2013-2024 The Omni Core developers
// SPDX-License-Identifier: MIT
//
// LevelDB-backed persistence layer. Uses leveldb's C API via a simple wrapper.
// The real upstream Omni Core uses a bespoke LevelDB wrapper; this file presents
// the same interface using a minimal RAII helper to keep the embeddable build
// self-contained.

#include "persistence.h"
#include <leveldb/db.h>
#include <leveldb/write_batch.h>

#include <memory>
#include <mutex>
#include <string>

namespace omni {
namespace persistence {

static std::unique_ptr<leveldb::DB> g_db;
static std::mutex g_mu;

bool Init(const std::string& dataDir) {
    leveldb::Options opts;
    opts.create_if_missing = true;
    leveldb::DB* db = nullptr;
    leveldb::Status s = leveldb::DB::Open(opts, dataDir + "/omnicore", &db);
    if (!s.ok()) return false;
    g_db.reset(db);
    return true;
}

void Flush() {
    // leveldb compaction happens implicitly; no extra action.
    g_db.reset();
}

static std::string MakeKey(const std::string& bucket, const std::string& key) {
    return bucket + "/" + key;
}

bool Put(const std::string& bucket, const std::string& key, const std::string& value) {
    if (!g_db) return false;
    std::lock_guard<std::mutex> lk(g_mu);
    return g_db->Put(leveldb::WriteOptions(), MakeKey(bucket, key), value).ok();
}

bool Get(const std::string& bucket, const std::string& key, std::string& out) {
    if (!g_db) return false;
    std::lock_guard<std::mutex> lk(g_mu);
    return g_db->Get(leveldb::ReadOptions(), MakeKey(bucket, key), &out).ok();
}

bool Del(const std::string& bucket, const std::string& key) {
    if (!g_db) return false;
    std::lock_guard<std::mutex> lk(g_mu);
    return g_db->Delete(leveldb::WriteOptions(), MakeKey(bucket, key)).ok();
}

} // namespace persistence
} // namespace omni
