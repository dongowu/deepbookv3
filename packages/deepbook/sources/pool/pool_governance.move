// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Governance functionality for DeepBook pools.
/// Provides helper functions for staking, proposals, voting, and rebate claiming.
///
/// Usage pattern from pool.move:
/// ```
/// let self = self.load_inner_mut();
/// pool_governance::stake_impl(&mut self.state, &mut self.vault, self.pool_id, ...);
/// ```
module deepbook::pool_governance;

use deepbook::{
    balance_manager::{BalanceManager, TradeProof},
    balances::{Self, Balances},
    state::State,
    vault::Vault
};

/// Process a stake operation and settle balances.
public(package) fun stake_impl<BaseAsset, QuoteAsset>(
    state: &mut State,
    vault: &mut Vault<BaseAsset, QuoteAsset>,
    pool_id: ID,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    amount: u64,
    ctx: &TxContext,
) {
    let (settled, owed) = state.process_stake(pool_id, balance_manager.id(), amount, ctx);
    vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

/// Process an unstake operation and settle balances.
public(package) fun unstake_impl<BaseAsset, QuoteAsset>(
    state: &mut State,
    vault: &mut Vault<BaseAsset, QuoteAsset>,
    pool_id: ID,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &TxContext,
) {
    let (settled, owed) = state.process_unstake(pool_id, balance_manager.id(), ctx);
    vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

/// Process a proposal submission.
public(package) fun proposal_impl(
    state: &mut State,
    pool_id: ID,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    balance_manager.validate_proof(trade_proof);
    state.process_proposal(
        pool_id,
        balance_manager.id(),
        taker_fee,
        maker_fee,
        stake_required,
        ctx,
    );
}

/// Process a vote on a proposal.
public(package) fun vote_impl(
    state: &mut State,
    pool_id: ID,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    proposal_id: ID,
    ctx: &TxContext,
) {
    balance_manager.validate_proof(trade_proof);
    state.process_vote(pool_id, balance_manager.id(), proposal_id, ctx);
}

/// Process rebate claiming and settle balances.
public(package) fun claim_rebates_impl<BaseAsset, QuoteAsset>(
    state: &mut State,
    vault: &mut Vault<BaseAsset, QuoteAsset>,
    pool_id: ID,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &TxContext,
) {
    let (settled, owed) = state.process_claim_rebates<BaseAsset, QuoteAsset>(
        pool_id,
        balance_manager,
        ctx,
    );
    vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

/// Get settled balances for a balance manager.
public(package) fun get_settled_balances(state: &State, balance_manager_id: ID): Balances {
    if (!state.account_exists(balance_manager_id)) {
        balances::empty()
    } else {
        state.account(balance_manager_id).settled_balances()
    }
}
