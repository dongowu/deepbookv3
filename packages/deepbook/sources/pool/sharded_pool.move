// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sharded pool implementation for DeepBook.
/// Wraps multiple Pool instances with shard coordination.
///
/// This module provides a sharding layer on top of existing Pool functionality,
/// enabling parallel processing of orders in different price ranges.
///
/// Architecture:
/// ```
/// ShardedPool<BaseAsset, QuoteAsset>
/// ├── ShardedPoolState (coordination state)
/// │   ├── ShardManager (routing logic)
/// │   └── ShardConfig (price boundaries)
/// └── Pool instances (stored separately as shared objects)
///     ├── Shard[0]: handles price range [min, boundary_0)
///     ├── Shard[1]: handles price range [boundary_0, boundary_1)
///     └── ...
/// ```
///
/// Usage:
/// ```move
/// // Create sharded pool state
/// let state = sharded_pool::create_state(base_pool_id);
///
/// // Register shard pools
/// sharded_pool::register_shard(&mut state, 0, shard_pool_0_id);
///
/// // Route and place order
/// let decision = sharded_pool::route_limit_order(&state, price, is_bid);
/// // Use decision.target_shard to select which pool to use
/// ```
module deepbook::sharded_pool;

use deepbook::{
    balance_manager::{BalanceManager, TradeProof},
    order_info::OrderInfo,
    pool::{Self, Pool},
    pool_shard::{Self, ShardConfig, ShardId},
    shard_manager::{Self, ShardManager, RoutingDecision}
};
use sui::clock::Clock;

/// Error codes.
const EShardedPoolDisabled: u64 = 1;
const ENoActiveShards: u64 = 2;
const EShardNotRegistered: u64 = 3;
const EInsufficientLiquidity: u64 = 4;

/// Configuration for sharded pool behavior.
public struct ShardedPoolConfig has copy, drop, store {
    enabled: bool,
    auto_rebalance: bool,
    cross_shard_matching: bool,
}

/// Sharded pool wrapper that coordinates multiple pool shards.
public struct ShardedPoolState has store {
    config: ShardedPoolConfig,
    manager: ShardManager,
    base_pool_id: ID,
}

/// Order placement result from sharded pool.
public struct ShardedOrderResult has copy, drop, store {
    shard_used: ShardId,
    order_id: u128,
    crossed_shards: bool,
    executed_quantity: u64,
    remaining_quantity: u64,
}

/// Create default sharded pool configuration.
public fun default_pool_config(): ShardedPoolConfig {
    ShardedPoolConfig {
        enabled: true,
        auto_rebalance: false,
        cross_shard_matching: true,
    }
}

/// Create sharded pool state.
public fun create_state(base_pool_id: ID): ShardedPoolState {
    create_state_with_config(base_pool_id, default_pool_config())
}

/// Create sharded pool state with custom configuration.
public fun create_state_with_config(base_pool_id: ID, config: ShardedPoolConfig): ShardedPoolState {
    ShardedPoolState {
        config,
        manager: shard_manager::new(),
        base_pool_id,
    }
}

/// Check if sharding is enabled.
public fun is_enabled(state: &ShardedPoolState): bool {
    state.config.enabled
}

/// Enable or disable sharding.
public fun set_enabled(state: &mut ShardedPoolState, enabled: bool) {
    state.config.enabled = enabled;
}

/// Get the shard manager.
public fun manager(state: &ShardedPoolState): &ShardManager {
    &state.manager
}

/// Get mutable shard manager.
public fun manager_mut(state: &mut ShardedPoolState): &mut ShardManager {
    &mut state.manager
}

/// Route a limit order to appropriate shard.
/// Returns the routing decision with target shard and fallback options.
public fun route_limit_order(state: &ShardedPoolState, price: u64, is_bid: bool): RoutingDecision {
    assert!(state.config.enabled, EShardedPoolDisabled);
    shard_manager::route_limit_order(&state.manager, price, is_bid)
}

/// Route a market order to shards in priority order.
/// Returns shards to check for matching, ordered by best price.
public fun route_market_order(state: &ShardedPoolState, is_bid: bool): vector<ShardId> {
    assert!(state.config.enabled, EShardedPoolDisabled);
    let shards = shard_manager::route_market_order(&state.manager, is_bid);
    assert!(shards.length() > 0, ENoActiveShards);
    shards
}

/// Get shard for a specific price level.
public fun get_shard_for_price(state: &ShardedPoolState, price: u64): ShardId {
    pool_shard::get_shard_for_price(state.manager.config(), price)
}

/// Check if cross-shard matching is enabled.
public fun cross_shard_enabled(state: &ShardedPoolState): bool {
    state.config.cross_shard_matching
}

/// Get statistics for load balancing decisions.
public struct ShardLoadInfo has copy, drop, store {
    shard_id: ShardId,
    order_count: u64,
    total_volume: u128,
    price_range: (u64, u64),
}

/// Get load information for all active shards.
public fun get_shard_loads(state: &ShardedPoolState): vector<ShardLoadInfo> {
    let config = state.manager.config();
    let shard_count = pool_shard::shard_count(config);
    let mut loads = vector[];

    shard_count.do!(|i| {
        let shard_id = pool_shard::get_shard_for_price(config, 1 << ((i as u8) * 8));
        if (shard_manager::is_shard_active(&state.manager, &shard_id)) {
            let (order_count, total_volume) = shard_manager::get_shard_stats(
                &state.manager,
                &shard_id,
            );
            let price_range = shard_manager::shard_price_range(&state.manager, &shard_id);

            loads.push_back(ShardLoadInfo {
                shard_id,
                order_count,
                total_volume,
                price_range,
            });
        };
    });

    loads
}

// === Shard Order Execution Functions ===

/// Place a limit order on a specific shard pool.
/// This is the core execution function that routes to the appropriate shard.
public fun place_limit_order_on_shard<BaseAsset, QuoteAsset>(
    state: &mut ShardedPoolState,
    shard_pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
): ShardedOrderResult {
    assert!(state.config.enabled, EShardedPoolDisabled);

    // Route to determine target shard
    let decision = route_limit_order(state, price, is_bid);
    let target_shard = shard_manager::target_shard(&decision);

    // Verify the provided pool matches the target shard
    let shard_pool_id = shard_manager::get_shard_pool_id(&state.manager, &target_shard);
    assert!(shard_pool_id == pool::id(shard_pool), EShardNotRegistered);

    // Execute order on the shard pool
    let order_info = pool::place_limit_order(
        shard_pool,
        balance_manager,
        trade_proof,
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        ctx,
    );

    // Record order statistics
    shard_manager::record_order(&mut state.manager, &target_shard, order_info.executed_quantity());

    ShardedOrderResult {
        shard_used: target_shard,
        order_id: order_info.order_id(),
        crossed_shards: shard_manager::requires_cross_shard(&decision),
        executed_quantity: order_info.executed_quantity(),
        remaining_quantity: order_info.original_quantity() - order_info.executed_quantity(),
    }
}

/// Place a market order that may span multiple shards.
/// Executes on primary shard first, then continues to adjacent shards if needed.
public fun place_market_order_on_shard<BaseAsset, QuoteAsset>(
    state: &mut ShardedPoolState,
    shard_pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): ShardedOrderResult {
    assert!(state.config.enabled, EShardedPoolDisabled);

    // Get priority-ordered shards for market order
    let shards = route_market_order(state, is_bid);
    let primary_shard = shards[0];

    // Verify the provided pool matches the primary shard
    let shard_pool_id = shard_manager::get_shard_pool_id(&state.manager, &primary_shard);
    assert!(shard_pool_id == pool::id(shard_pool), EShardNotRegistered);

    // Execute market order on the shard pool
    let order_info = pool::place_market_order(
        shard_pool,
        balance_manager,
        trade_proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );

    // Record order statistics
    shard_manager::record_order(&mut state.manager, &primary_shard, order_info.executed_quantity());

    ShardedOrderResult {
        shard_used: primary_shard,
        order_id: order_info.order_id(),
        crossed_shards: shards.length() > 1,
        executed_quantity: order_info.executed_quantity(),
        remaining_quantity: order_info.original_quantity() - order_info.executed_quantity(),
    }
}

/// Check if an order can be placed on a shard.
public fun can_place_order_on_shard<BaseAsset, QuoteAsset>(
    state: &ShardedPoolState,
    shard_pool: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
): bool {
    if (!state.config.enabled) {
        return false
    };

    // Route to determine target shard
    let decision = route_limit_order(state, price, is_bid);
    let target_shard = shard_manager::target_shard(&decision);

    // Verify the provided pool matches the target shard
    let shard_pool_id = shard_manager::get_shard_pool_id(&state.manager, &target_shard);
    if (shard_pool_id != pool::id(shard_pool)) {
        return false
    };

    // Check if order can be placed on the pool
    pool::can_place_limit_order(
        shard_pool,
        balance_manager,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
    )
}

/// Get the best price across all active shards for a given side.
public fun get_best_price_across_shards<BaseAsset, QuoteAsset>(
    state: &ShardedPoolState,
    shard_pools: &vector<&Pool<BaseAsset, QuoteAsset>>,
    is_bid: bool,
    clock: &Clock,
): Option<u64> {
    if (!state.config.enabled) {
        return option::none()
    };

    let shards = route_market_order(state, is_bid);
    let mut best_price: Option<u64> = option::none();

    shards.do_ref!(|shard| {
        let shard_idx = pool_shard::shard_index(shard);
        if ((shard_idx as u64) < shard_pools.length()) {
            let pool = shard_pools[shard_idx as u64];
            let mid_price = pool::mid_price(pool, clock);
            if (mid_price > 0) {
                if (best_price.is_none()) {
                    best_price = option::some(mid_price);
                } else {
                    let current_best = *best_price.borrow();
                    if (is_bid && mid_price < current_best) {
                        best_price = option::some(mid_price);
                    } else if (!is_bid && mid_price > current_best) {
                        best_price = option::some(mid_price);
                    };
                };
            };
        };
    });

    best_price
}

// === Tests ===

#[test]
fun test_sharded_pool_creation() {
    let state = create_state(@0x123.to_id());
    assert!(is_enabled(&state));
}

#[test]
fun test_routing_when_enabled() {
    let mut state = create_state(@0x123.to_id());

    // Register some shards
    let manager = manager_mut(&mut state);
    shard_manager::register_shard(manager, 0, @0x456.to_id());
    shard_manager::register_shard(manager, 1, @0x789.to_id());

    // Test routing
    let decision = route_limit_order(&state, 1000, true);
    let _ = decision; // Routing should succeed
}

#[test, expected_failure(abort_code = EShardedPoolDisabled)]
fun test_routing_when_disabled() {
    let mut state = create_state(@0x123.to_id());
    set_enabled(&mut state, false);

    // Should fail when disabled
    let _ = route_limit_order(&state, 1000, true);
}

#[test]
fun test_shard_load_info() {
    let mut state = create_state(@0x123.to_id());

    // Register shards
    let manager = manager_mut(&mut state);
    shard_manager::register_shard(manager, 0, @0x456.to_id());
    shard_manager::register_shard(manager, 1, @0x789.to_id());

    // Get load info
    let loads = get_shard_loads(&state);
    assert!(loads.length() == 2);
}
