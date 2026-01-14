// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool sharding infrastructure for DeepBook.
/// Provides utilities for price-based order routing and shard management.
///
/// Design Goals:
/// 1. Enable parallel processing of orders in different price ranges
/// 2. Reduce contention on hot price levels
/// 3. Support gradual migration from single-pool to sharded architecture
///
/// Sharding Strategy:
/// - Price space is divided into N shards (default: 8)
/// - Each shard handles a contiguous price range
/// - Orders are routed to appropriate shard based on price
/// - Cross-shard matching is handled by the coordinator
module deepbook::pool_shard;

use deepbook::constants;

/// Number of shards for price partitioning.
const DEFAULT_SHARD_COUNT: u8 = 8;

/// Shard configuration for a pool.
public struct ShardConfig has copy, drop, store {
    shard_count: u8,
    price_boundaries: vector<u64>,
}

/// Identifies which shard an order belongs to.
public struct ShardId has copy, drop, store {
    index: u8,
}

/// Result of routing an order to shards.
public struct RouteResult has copy, drop, store {
    primary_shard: ShardId,
    may_cross_shards: bool,
}

/// Create default shard configuration with logarithmic price distribution.
public fun default_config(): ShardConfig {
    create_config(DEFAULT_SHARD_COUNT)
}

/// Create shard configuration with specified number of shards.
public fun create_config(shard_count: u8): ShardConfig {
    assert!(shard_count >= 2 && shard_count <= 16, 0);

    let min_price = constants::min_price();
    let max_price = constants::max_price();
    let mut boundaries = vector[];

    // Use logarithmic distribution for price boundaries
    // This provides better distribution for typical order book shapes
    let log_min = log2_approx(min_price);
    let log_max = log2_approx(max_price);
    let step = (log_max - log_min) / (shard_count as u64);

    let mut i = 1u8;
    while (i < shard_count) {
        let log_boundary = log_min + step * (i as u64);
        let boundary = exp2_approx(log_boundary);
        boundaries.push_back(boundary);
        i = i + 1;
    };

    ShardConfig { shard_count, price_boundaries: boundaries }
}

/// Get the shard index for a given price.
public fun get_shard_for_price(config: &ShardConfig, price: u64): ShardId {
    let mut index = 0u8;
    config.price_boundaries.do_ref!(|boundary| {
        if (price >= *boundary) {
            index = index + 1;
        };
    });
    ShardId { index }
}

/// Route an order to appropriate shard(s).
/// For limit orders, returns the primary shard.
/// For market orders, indicates if cross-shard matching may be needed.
public fun route_order(
    config: &ShardConfig,
    price: u64,
    is_market_order: bool,
    is_bid: bool,
): RouteResult {
    let primary_shard = get_shard_for_price(config, price);

    // Market orders may cross multiple shards
    let may_cross_shards = if (is_market_order) {
        true
    } else {
        // Limit orders at shard boundaries may cross
        let boundary_index = primary_shard.index;
        if (is_bid && boundary_index > 0) {
            let lower_boundary = config.price_boundaries[(boundary_index - 1) as u64];
            price <= lower_boundary + price_tolerance(price)
        } else if (!is_bid && (boundary_index as u64) < config.price_boundaries.length()) {
            let upper_boundary = config.price_boundaries[boundary_index as u64];
            price >= upper_boundary - price_tolerance(price)
        } else {
            false
        }
    };

    RouteResult { primary_shard, may_cross_shards }
}

/// Get shards that need to be checked for matching a market order.
/// Returns shard indices in order of priority (best price first).
public fun get_matching_shards(config: &ShardConfig, is_bid: bool): vector<ShardId> {
    let mut shards = vector[];
    let count = config.shard_count;

    if (is_bid) {
        // For bids, check asks from lowest price shard to highest
        let mut i = 0u8;
        while (i < count) {
            shards.push_back(ShardId { index: i });
            i = i + 1;
        };
    } else {
        // For asks, check bids from highest price shard to lowest
        let mut i = count;
        while (i > 0) {
            i = i - 1;
            shards.push_back(ShardId { index: i });
        };
    };

    shards
}

/// Check if two shards are adjacent.
public fun are_adjacent(shard1: &ShardId, shard2: &ShardId): bool {
    let diff = if (shard1.index > shard2.index) {
        shard1.index - shard2.index
    } else {
        shard2.index - shard1.index
    };
    diff == 1
}

/// Get shard index value.
public fun shard_index(shard: &ShardId): u8 {
    shard.index
}

/// Get the number of shards in config.
public fun shard_count(config: &ShardConfig): u8 {
    config.shard_count
}

/// Get price range for a shard.
/// Returns (min_price, max_price) for the shard.
public fun shard_price_range(config: &ShardConfig, shard: &ShardId): (u64, u64) {
    let index = shard.index;

    let min_price = if (index == 0) {
        constants::min_price()
    } else {
        config.price_boundaries[(index - 1) as u64]
    };

    let max_price = if ((index as u64) >= config.price_boundaries.length()) {
        constants::max_price()
    } else {
        config.price_boundaries[index as u64] - 1
    };

    (min_price, max_price)
}

// === Internal Helpers ===

/// Approximate log2 for price distribution calculation.
fun log2_approx(x: u64): u64 {
    let mut result = 0u64;
    let mut val = x;
    while (val > 1) {
        val = val >> 1;
        result = result + 1;
    };
    result
}

/// Approximate 2^x for price boundary calculation.
fun exp2_approx(x: u64): u64 {
    if (x >= 63) {
        constants::max_price()
    } else {
        1u64 << (x as u8)
    }
}

/// Price tolerance for boundary detection (0.1% of price).
fun price_tolerance(price: u64): u64 {
    price / 1000
}

// === Tests ===

#[test]
fun test_shard_routing() {
    let config = create_config(4);

    // Test routing at different price levels
    let low_shard = get_shard_for_price(&config, 100);
    let mid_shard = get_shard_for_price(&config, 1_000_000_000);
    let high_shard = get_shard_for_price(&config, 1_000_000_000_000_000);

    assert!(low_shard.index < mid_shard.index);
    assert!(mid_shard.index < high_shard.index);
}

#[test]
fun test_matching_shards_order() {
    let config = create_config(4);

    let bid_shards = get_matching_shards(&config, true);
    let ask_shards = get_matching_shards(&config, false);

    // Bid should get shards 0,1,2,3 (lowest price first)
    assert!(bid_shards[0].index == 0);

    // Ask should get shards 3,2,1,0 (highest price first)
    assert!(ask_shards[0].index == 3);
}

#[test]
fun test_shard_price_range() {
    let config = create_config(4);
    let shard = ShardId { index: 0 };
    let (min_p, max_p) = shard_price_range(&config, &shard);

    assert!(min_p == constants::min_price());
    assert!(max_p < constants::max_price());
}
