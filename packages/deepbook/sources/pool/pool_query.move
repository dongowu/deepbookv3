// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Query functionality for DeepBook pools.
/// Contains helper functions for read-only pool operations.
///
/// Usage pattern from pool.move:
/// ```
/// let pool_inner = self.load_inner();
/// pool_query::get_available_balances<BaseAsset, QuoteAsset>(
///     &pool_inner.state, balance_manager
/// );
/// ```
module deepbook::pool_query;

use deepbook::{
    balance_manager::BalanceManager,
    balances::{Self, Balances},
    book::Book,
    deep_price::DeepPrice,
    math,
    order::Order,
    state::State
};
use token::deep::DEEP;

/// Check if limit order parameters are valid.
public(package) fun validate_limit_order_params(
    book: &Book,
    price: u64,
    quantity: u64,
    expire_timestamp: u64,
    timestamp_ms: u64,
): bool {
    book.check_limit_order_params(price, quantity, expire_timestamp, timestamp_ms)
}

/// Check if market order parameters are valid.
public(package) fun validate_market_order_params(book: &Book, quantity: u64): bool {
    book.check_market_order_params(quantity)
}

/// Calculate locked balance from open orders.
/// Returns (locked_base, locked_quote, locked_deep).
public(package) fun calculate_locked_balance(
    state: &State,
    orders: &vector<Order>,
): (u64, u64, u64) {
    let mut base_quantity = 0u64;
    let mut quote_quantity = 0u64;
    let mut deep_quantity = 0u64;

    orders.do_ref!(|order| {
        let maker_fee = state.history().historic_maker_fee(order.epoch());
        let locked = order.locked_balance(maker_fee);
        base_quantity = base_quantity + locked.base();
        quote_quantity = quote_quantity + locked.quote();
        deep_quantity = deep_quantity + locked.deep();
    });

    (base_quantity, quote_quantity, deep_quantity)
}

/// Get settled balances for a balance manager.
public(package) fun get_settled_balances(state: &State, balance_manager_id: ID): Balances {
    if (!state.account_exists(balance_manager_id)) {
        balances::empty()
    } else {
        state.account(balance_manager_id).settled_balances()
    }
}

/// Calculate required balances for a limit order.
/// Returns (required_base, required_quote, required_deep).
public(package) fun calculate_limit_order_requirements(
    taker_fee: u64,
    deep_price: &DeepPrice,
    quantity: u64,
    price: u64,
    is_bid: bool,
    pay_with_deep: bool,
    whitelisted: bool,
): (u64, u64, u64) {
    let order_deep_price = if (pay_with_deep) {
        deep_price.get_order_deep_price(whitelisted)
    } else {
        deep_price.empty_deep_price()
    };

    let quote_quantity = math::mul(quantity, price);
    let fee_balances = order_deep_price.fee_quantity(quantity, quote_quantity, is_bid);

    let mut required_base = 0u64;
    let mut required_quote = 0u64;
    let mut required_deep = 0u64;

    if (is_bid) {
        required_quote = quote_quantity;
        if (pay_with_deep) {
            required_deep = math::mul(fee_balances.deep(), taker_fee);
        } else {
            let fee_quote = math::mul(fee_balances.quote(), taker_fee);
            required_quote = required_quote + fee_quote;
        };
    } else {
        required_base = quantity;
        if (pay_with_deep) {
            required_deep = math::mul(fee_balances.deep(), taker_fee);
        } else {
            let fee_base = math::mul(fee_balances.base(), taker_fee);
            required_base = required_base + fee_base;
        };
    };

    (required_base, required_quote, required_deep)
}

/// Get available balances for a balance manager including settled amounts.
/// Returns (available_base, available_quote, available_deep).
public(package) fun get_available_balances<BaseAsset, QuoteAsset>(
    state: &State,
    balance_manager: &BalanceManager,
): (u64, u64, u64) {
    let settled = get_settled_balances(state, balance_manager.id());
    let available_base = balance_manager.balance<BaseAsset>() + settled.base();
    let available_quote = balance_manager.balance<QuoteAsset>() + settled.quote();
    let available_deep = balance_manager.balance<DEEP>() + settled.deep();

    (available_base, available_quote, available_deep)
}

/// Check if a balance manager has sufficient balance for a limit order.
public(package) fun can_afford_limit_order<BaseAsset, QuoteAsset>(
    state: &State,
    taker_fee: u64,
    deep_price: &DeepPrice,
    balance_manager: &BalanceManager,
    quantity: u64,
    price: u64,
    is_bid: bool,
    pay_with_deep: bool,
    whitelisted: bool,
): bool {
    let (required_base, required_quote, required_deep) = calculate_limit_order_requirements(
        taker_fee,
        deep_price,
        quantity,
        price,
        is_bid,
        pay_with_deep,
        whitelisted,
    );

    let (available_base, available_quote, available_deep) = get_available_balances<
        BaseAsset,
        QuoteAsset,
    >(state, balance_manager);

    available_base >= required_base &&
        available_quote >= required_quote &&
        available_deep >= required_deep
}
