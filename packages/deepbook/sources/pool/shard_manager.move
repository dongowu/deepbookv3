// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shard manager for coordinating operations across sharded pools.
/// Handles order routing, cross-shard matching, and shard lifecycle.
///
/// Architecture:
/// ```
/// ShardedPool
/// ├── ShardManager (coordinator)
/// │   ├── shard_config: ShardConfig
/// │   └── shard_states: vector<ShardState>
/// └── Shards (separate shared objects)
///     ├── Shard[0]: Pool for price range [min, boundary_0)
///     ├── Shard[1]: Pool for price range [boundary_0, boundary_1)
///     └── ...
/// ```
module deepbook::shard_manager;

use deepbook::pool_shard::{Self, ShardConfig, ShardId, RouteResult};

/// Error codes.
const EShardNotFound: u64 = 1;
const EInvalidShardCount: u64 = 2;
const ECrossShardNotSupported: u64 = 3;

/// State tracking for each shard.
public struct ShardState has copy, drop, store {
    shard_id: ShardId,
    pool_id: ID,
    is_active: bool,
    order_count: u64,
    total_volume: u128,
}

/// Manager for coordinating sharded pool operations.
public struct ShardManager has store {
    config: ShardConfig,
    shard_states: vector<ShardState>,
    total_shards_active: u8,
}

/// Order routing decision.
public struct RoutingDecision has copy, drop, store {
    target_shard: ShardId,
    requires_cross_shard: bool,
    fallback_shards: vector<ShardId>,
}

/// Get the target shard from routing decision.
public fun target_shard(decision: &RoutingDecision): ShardId {
    decision.target_shard
}

/// Check if cross-shard matching is required.
public fun requires_cross_shard(decision: &RoutingDecision): bool {
    decision.requires_cross_shard
}

/// Get fallback shards from routing decision.
public fun fallback_shards(decision: &RoutingDecision): &vector<ShardId> {
    &decision.fallback_shards
}

/// Create a new shard manager with default configuration.
public fun new(): ShardManager {
    new_with_config(pool_shard::default_config())
}

/// Create a new shard manager with custom configuration.
public fun new_with_config(config: ShardConfig): ShardManager {
    let shard_count = config.shard_count();
    let mut shard_states = vector[];

    shard_count.do!(|i| {
        shard_states.push_back(ShardState {
            shard_id: create_shard_id(i),
            pool_id: @0x0.to_id(),
            is_active: false,
            order_count: 0,
            total_volume: 0,
        });
    });

    ShardManager {
        config,
        shard_states,
        total_shards_active: 0,
    }
}

/// Register a pool as a shard.
public fun register_shard(manager: &mut ShardManager, shard_index: u8, pool_id: ID) {
    assert!((shard_index as u64) < manager.shard_states.length(), EShardNotFound);

    let state = &mut manager.shard_states[shard_index as u64];
    if (!state.is_active) {
        manager.total_shards_active = manager.total_shards_active + 1;
    };
    state.pool_id = pool_id;
    state.is_active = true;
}

/// Deactivate a shard (for migration/maintenance).
public fun deactivate_shard(manager: &mut ShardManager, shard_index: u8) {
    assert!((shard_index as u64) < manager.shard_states.length(), EShardNotFound);

    let state = &mut manager.shard_states[shard_index as u64];
    if (state.is_active) {
        state.is_active = false;
        manager.total_shards_active = manager.total_shards_active - 1;
    };
}

/// Route a limit order to the appropriate shard.
public fun route_limit_order(manager: &ShardManager, price: u64, is_bid: bool): RoutingDecision {
    let route = pool_shard::route_order(&manager.config, price, false, is_bid);

    let fallback_shards = if (route.may_cross_shards) {
        get_adjacent_active_shards(manager, &route.primary_shard)
    } else {
        vector[]
    };

    RoutingDecision {
        target_shard: route.primary_shard,
        requires_cross_shard: route.may_cross_shards,
        fallback_shards,
    }
}

/// Route a market order - returns shards to check in priority order.
public fun route_market_order(manager: &ShardManager, is_bid: bool): vector<ShardId> {
    let all_shards = pool_shard::get_matching_shards(&manager.config, is_bid);

    // Filter to only active shards
    let mut active_shards = vector[];
    all_shards.do_ref!(|shard| {
        let index = pool_shard::shard_index(shard);
        if (manager.shard_states[index as u64].is_active) {
            active_shards.push_back(*shard);
        };
    });

    active_shards
}

/// Get the pool ID for a shard.
public fun get_shard_pool_id(manager: &ShardManager, shard: &ShardId): ID {
    let index = pool_shard::shard_index(shard);
    assert!((index as u64) < manager.shard_states.length(), EShardNotFound);
    manager.shard_states[index as u64].pool_id
}

/// Check if a shard is active.
public fun is_shard_active(manager: &ShardManager, shard: &ShardId): bool {
    let index = pool_shard::shard_index(shard);
    if ((index as u64) >= manager.shard_states.length()) {
        return false
    };
    manager.shard_states[index as u64].is_active
}

/// Update shard statistics after an order.
public fun record_order(manager: &mut ShardManager, shard: &ShardId, volume: u64) {
    let index = pool_shard::shard_index(shard);
    if ((index as u64) < manager.shard_states.length()) {
        let state = &mut manager.shard_states[index as u64];
        state.order_count = state.order_count + 1;
        state.total_volume = state.total_volume + (volume as u128);
    };
}

/// Get shard statistics.
public fun get_shard_stats(manager: &ShardManager, shard: &ShardId): (u64, u128) {
    let index = pool_shard::shard_index(shard);
    if ((index as u64) >= manager.shard_states.length()) {
        return (0, 0)
    };
    let state = &manager.shard_states[index as u64];
    (state.order_count, state.total_volume)
}

/// Get total active shards.
public fun active_shard_count(manager: &ShardManager): u8 {
    manager.total_shards_active
}

/// Get the shard configuration.
public fun config(manager: &ShardManager): &ShardConfig {
    &manager.config
}

/// Get price range for a shard.
public fun shard_price_range(manager: &ShardManager, shard: &ShardId): (u64, u64) {
    pool_shard::shard_price_range(&manager.config, shard)
}

// === Internal Helpers ===

fun create_shard_id(index: u8): ShardId {
    pool_shard::get_shard_for_price(
        &pool_shard::create_config(index + 1),
        1, // Just need any shard ID with given index
    )
}

fun get_adjacent_active_shards(manager: &ShardManager, shard: &ShardId): vector<ShardId> {
    let mut adjacent = vector[];
    let index = pool_shard::shard_index(shard);
    let count = manager.shard_states.length();

    // Check previous shard
    if (index > 0) {
        let prev_index = index - 1;
        if (manager.shard_states[prev_index as u64].is_active) {
            adjacent.push_back(manager.shard_states[prev_index as u64].shard_id);
        };
    };

    // Check next shard
    let next_index = index + 1;
    if ((next_index as u64) < count) {
        if (manager.shard_states[next_index as u64].is_active) {
            adjacent.push_back(manager.shard_states[next_index as u64].shard_id);
        };
    };

    adjacent
}

// === Tests ===

#[test]
fun test_shard_manager_creation() {
    let manager = new();
    assert!(active_shard_count(&manager) == 0);
}

#[test]
fun test_shard_registration() {
    let mut manager = new();
    let pool_id = @0x123.to_id();

    register_shard(&mut manager, 0, pool_id);
    assert!(active_shard_count(&manager) == 1);

    let shard = pool_shard::get_shard_for_price(&manager.config, 100);
    assert!(is_shard_active(&manager, &shard));
}

#[test]
fun test_order_routing() {
    let mut manager = new();

    // Register all shards
    8u8.do!(|i| {
        register_shard(&mut manager, i, @0x123.to_id());
    });

    // Route a limit order
    let decision = route_limit_order(&manager, 1_000_000, true);
    assert!(!requires_cross_shard(&decision) || fallback_shards(&decision).length() > 0);

    // Route a market order
    let shards = route_market_order(&manager, true);
    assert!(shards.length() == 8);
}
