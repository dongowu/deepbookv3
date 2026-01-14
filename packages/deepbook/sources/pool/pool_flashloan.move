// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flashloan functionality for DeepBook pools.
/// Provides atomic borrowing and returning of assets within a single transaction.
///
/// Usage pattern from pool.move:
/// ```
/// let pool_inner = self.load_inner_mut();
/// pool_flashloan::borrow_base(
///     &mut pool_inner.vault, pool_inner.pool_id, amount, ctx
/// );
/// ```
module deepbook::pool_flashloan;

use deepbook::vault::{Vault, FlashLoan};
use sui::coin::Coin;

/// Borrow base assets from the pool's vault.
/// Returns the borrowed coins and a hot potato that must be returned.
public(package) fun borrow_base<BaseAsset, QuoteAsset>(
    vault: &mut Vault<BaseAsset, QuoteAsset>,
    pool_id: ID,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, FlashLoan) {
    vault.borrow_flashloan_base(pool_id, amount, ctx)
}

/// Borrow quote assets from the pool's vault.
/// Returns the borrowed coins and a hot potato that must be returned.
public(package) fun borrow_quote<BaseAsset, QuoteAsset>(
    vault: &mut Vault<BaseAsset, QuoteAsset>,
    pool_id: ID,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<QuoteAsset>, FlashLoan) {
    vault.borrow_flashloan_quote(pool_id, amount, ctx)
}

/// Return borrowed base assets to the pool's vault.
/// Consumes the hot potato, ensuring the loan is repaid.
public(package) fun return_base<BaseAsset, QuoteAsset>(
    vault: &mut Vault<BaseAsset, QuoteAsset>,
    pool_id: ID,
    coin: Coin<BaseAsset>,
    flash_loan: FlashLoan,
) {
    vault.return_flashloan_base(pool_id, coin, flash_loan)
}

/// Return borrowed quote assets to the pool's vault.
/// Consumes the hot potato, ensuring the loan is repaid.
public(package) fun return_quote<BaseAsset, QuoteAsset>(
    vault: &mut Vault<BaseAsset, QuoteAsset>,
    pool_id: ID,
    coin: Coin<QuoteAsset>,
    flash_loan: FlashLoan,
) {
    vault.return_flashloan_quote(pool_id, coin, flash_loan)
}
