// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Swap functionality for DeepBook pools.
/// Handles swap calculations and quantity estimations.
///
/// Usage pattern from pool.move:
/// ```
/// let pool_inner = self.load_inner();
/// let (qty, is_bid, proceed) = pool_swap::calculate_swap_params(
///     &pool_inner.book, &pool_inner.state, &pool_inner.deep_price, ...
/// );
/// ```
module deepbook::pool_swap;

use deepbook::{
    balance_manager::BalanceManager,
    balances,
    book::Book,
    constants,
    deep_price::DeepPrice,
    math,
    state::State
};
use token::deep::DEEP;

/// Calculate the swap parameters for a given input.
/// Returns (adjusted_base_quantity, is_bid, should_proceed).
public(package) fun calculate_swap_params(
    book: &Book,
    taker_fee: u64,
    deep_price: &DeepPrice,
    base_quantity: u64,
    quote_quantity: u64,
    pay_with_deep: bool,
    whitelisted: bool,
    timestamp: u64,
): (u64, bool, bool) {
    let input_fee_rate = math::mul(taker_fee, constants::fee_penalty_multiplier());
    let is_bid = quote_quantity > 0;
    let lot_size = book.lot_size();
    let min_size = book.min_size();

    let mut adjusted_base_quantity = base_quantity;

    if (is_bid) {
        let order_deep_price = if (pay_with_deep) {
            deep_price.get_order_deep_price(whitelisted)
        } else {
            deep_price.empty_deep_price()
        };

        (adjusted_base_quantity, _, _) =
            book.get_quantity_out(
                0,
                quote_quantity,
                taker_fee,
                order_deep_price,
                lot_size,
                pay_with_deep,
                timestamp,
            );
    } else {
        if (!pay_with_deep) {
            adjusted_base_quantity =
                math::div(
                    base_quantity,
                    constants::float_scaling() + input_fee_rate,
                );
        };
    };

    adjusted_base_quantity = adjusted_base_quantity - adjusted_base_quantity % lot_size;
    let should_proceed = adjusted_base_quantity >= min_size;

    (adjusted_base_quantity, is_bid, should_proceed)
}

/// Calculate swap parameters for manager-based swap (always pays with DEEP).
/// Returns (adjusted_base_quantity, is_bid, should_proceed).
public(package) fun calculate_swap_params_with_manager(
    book: &Book,
    taker_fee: u64,
    deep_price: &DeepPrice,
    base_quantity: u64,
    quote_quantity: u64,
    whitelisted: bool,
    timestamp: u64,
): (u64, bool, bool) {
    let is_bid = quote_quantity > 0;
    let lot_size = book.lot_size();
    let min_size = book.min_size();

    let mut adjusted_base_quantity = base_quantity;

    if (is_bid) {
        let order_deep_price = deep_price.get_order_deep_price(whitelisted);
        (adjusted_base_quantity, _, _) =
            book.get_quantity_out(
                0,
                quote_quantity,
                taker_fee,
                order_deep_price,
                lot_size,
                true,
                timestamp,
            );
    } else {
        adjusted_base_quantity = adjusted_base_quantity - adjusted_base_quantity % lot_size;
    };

    let should_proceed = adjusted_base_quantity >= min_size;

    (adjusted_base_quantity, is_bid, should_proceed)
}

/// Get available balances for a balance manager including settled amounts.
/// Returns (available_base, available_quote, available_deep).
public(package) fun get_available_balances<BaseAsset, QuoteAsset>(
    state: &State,
    balance_manager: &BalanceManager,
): (u64, u64, u64) {
    let settled = if (!state.account_exists(balance_manager.id())) {
        balances::empty()
    } else {
        state.account(balance_manager.id()).settled_balances()
    };

    let available_base = balance_manager.balance<BaseAsset>() + settled.base();
    let available_quote = balance_manager.balance<QuoteAsset>() + settled.quote();
    let available_deep = balance_manager.balance<DEEP>() + settled.deep();

    (available_base, available_quote, available_deep)
}
