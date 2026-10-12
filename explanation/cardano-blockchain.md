---
title: The Cardano blockchain
permalink: /explanation/cardano-blockchain/
---
This page gives the background needed to understand *why* Plinth exists. It
explains what a distributed ledger is, what makes [Cardano][cardano]'s ledger
distinctive (the extended UTXO model), and where smart contracts fit in. No
prior blockchain knowledge is assumed.

## A distributed ledger

At its core, a blockchain is a **ledger**: a record of who owns what. What makes
it a *distributed* ledger is that no single party holds the authoritative copy.
Instead, the ledger is replicated across many independent computers (*nodes*),
and the network agrees on its contents through a **consensus** protocol &mdash;
Cardano uses a proof-of-stake protocol called Ouroboros.

The ledger is built from **transactions**, which are grouped into **blocks** and
chained together in order. A few properties follow from this design:

- **Append-only.** New transactions are added; past ones are never edited.
- **Replicated.** Every node can independently check and store the full history.
- **No central authority.** Agreement comes from the consensus protocol rather
  than from a trusted operator.

Because every node must agree on the outcome, the rules for deciding whether a
transaction is valid have to be **deterministic**: the same transaction, checked
against the same ledger state, must always give the same answer on every node.

## What is special about Cardano: the extended UTXO model

How a blockchain represents "who owns what" is a central design choice. Two
broad families exist:

- **Account-based** (used by Ethereum, for example). The ledger is a set of
  accounts with balances, much like bank accounts. A transaction mutates those
  balances.
- **UTXO-based** (used by Bitcoin). The ledger is instead a set of *unspent
  transaction outputs* (UTXOs). Each output carries a **value** (an amount of
  ada, and possibly other tokens) and an **address** saying who may spend it.

In the UTXO model there are no balances stored anywhere: your "balance" is just
the sum of the UTXOs you control. A transaction **consumes** some existing
outputs as its *inputs* and **produces** new outputs. An output can be spent
exactly once; once consumed it is gone, and new outputs take its place.

Cardano uses the **extended UTXO (EUTXO)** model ([formalised in this
paper][eutxo-paper]), which generalises plain UTXO in two ways:

- **Outputs can carry arbitrary data (a *datum*).** A plain UTXO only holds a
  value and an address. An EUTXO output can additionally attach a piece of
  application data, letting a UTXO represent the state of an on-chain
  application rather than just a coin.
- **Outputs can be locked by a *script* instead of a public key.** A plain UTXO
  is unlocked by a signature from the owning key. An EUTXO output can instead be
  guarded by a program &mdash; a **validator script** &mdash; that decides
  whether a given transaction is allowed to spend it.

Crucially, EUTXO keeps the determinism of plain UTXO. A validator only sees the
transaction it is validating and that transaction's own data; it cannot depend
on global, mutable state. This means the outcome of validation can be computed
**off-chain, in advance** &mdash; you can know whether your transaction will
succeed before you submit it, and what it will cost.

## Why smart contracts are needed

A signature-locked output answers only one question: "did the right person sign
this?" That is enough to send coins from one party to another, but not enough to
express richer conditions &mdash; for example, "these funds may be spent only by
the highest bidder, and only after the auction has closed."

**Smart contracts** fill that gap. On Cardano a smart contract is, concretely, a
**validator script** attached to an EUTXO output. When a transaction tries to
spend that output, every node runs the validator as part of checking the
transaction. The validator is given:

- the **datum** attached to the output being spent (the on-chain state),
- a **redeemer** supplied by the transaction (the spender's argument, such as
  "I am bidding 100 ada"), and
- the **script context** &mdash; a view of the transaction itself: its inputs,
  outputs, signatures, validity interval, and so on.

From these the validator returns success or failure. If it fails, the whole
transaction is rejected and the output stays put. In other words, the contract
does not "move funds" itself; it decides whether a *proposed* transaction is
allowed to. This keeps validation local and deterministic, exactly as the EUTXO
model requires.

Spending is not the only thing scripts guard. Cardano also has **native
tokens** &mdash; assets other than ada &mdash; and a transaction that *mints*
(creates) or *burns* (destroys) them must satisfy a **minting policy**: a script
that decides whether that minting or burning is allowed. A minting policy runs
much like a validator, but it is given only a redeemer and the script context
&mdash; there is no output being spent, so no datum. Its script hash serves as
the token's **policy id**, the identifier that namespaces the assets it governs.

Spending and minting are the most common, but they are not the only **script
purposes**. The same machinery &mdash; a script attached through a credential,
run when a transaction performs the action it guards, and given a redeemer and
the script context &mdash; also covers:

- **reward withdrawal**: an address's staking credential can be a script, run
  when staking rewards are withdrawn from it;
- **certificates**: a script can authorise registering, deregistering, or
  delegating a stake credential it controls;
- **governance voting and proposing** (since the Conway era): a script can act
  as a vote-casting credential, such as a delegate representative or a
  constitutional-committee member, or as the constitution's "guardrails" that
  gate proposals like treasury withdrawals and protocol-parameter changes.

Of these, only the spending validator is also handed a datum, because only it is
tied to a specific output carrying state.

This is where Plinth comes in: it is the language you write these scripts in.
Plinth code is compiled down to **Plutus Core**, the low-level language the
Cardano ledger actually executes.

## Example: state across transactions

The auction of the previous section needs state: the highest bid so far. A
transaction cannot change an output. It can only spend outputs and create new
ones. So the contract keeps its state in the datum of one output at the script
address. Each step spends that output and creates the next one, with the new
state in its datum. This new output is the **continuing output**. The validator
checks it: it must go back to the same script address, with the correct datum
and value.

An auction keeps its data in three places:

- the **parameters** of the validator, which are compiled into the script: the
  seller, the item, the minimum bid and the end time;
- the **datum** of the auction output: the highest bid so far and the key of
  the bidder (no bid at the start);
- the **value** of the auction output: the item, and the ada of the highest
  bid, which the contract holds until the end.

![An auction as a chain of outputs at one script address: each bid transaction spends the current auction output, creates the next one with the new highest bid in its datum, and refunds the previous bidder.]({{ '/assets/images/auction-state.svg' | relative_url }})

To bid, the bidder builds a transaction off-chain. The transaction:

1. spends the current auction output, with a redeemer that gives the new bid;
2. creates the continuing output, with the new bid and the bidder's key in its
   datum, and the item and the new bid in its value;
3. pays the previous bid back to the previous bidder;
4. has a validity interval that ends before the end time.

The validator accepts the transaction only if the new bid is higher than the
previous one (or, for the first bid, at least the minimum bid), the continuing
output is correct, and the previous bidder gets the refund. After the end time,
a payout transaction spends the last auction output. It sends the item to the
highest bidder and the ada to the seller.

Some properties follow from this design:

- **The address does not change.** A script address is the hash of the
  validator script, which includes its parameters. The datum and the value are
  not part of it. So all the states of one auction are at the same address. An
  auction with different parameters has a different address.
- **A refund needs no notification.** The refund is a usual output to the
  address of the previous bidder. A wallet finds the outputs at its addresses
  in the UTXO set, so the previous bidder's wallet shows the refund. Only the
  key of that address can spend it.
- **Only one bid per state.** All the bids spend the same output. If two
  bidders build on the same state, only the first transaction in a block is
  valid. The node rejects the second one because its input is already spent,
  and the bidder pays no fee. The second bidder must build a new bid on the
  new state.
- **A token identifies the real auction.** Anyone can send an output with any
  datum to the script address, for example with a false "highest bid". So a
  real contract mints a unique token (an NFT, the *thread token*) into the
  first auction output, and the validator requires the token in each
  continuing output. Bidders use the output that holds the token, and ignore
  the other outputs at the address.

## Further reading

- [How smart contracts run: Plutus Core and the CEK machine]({% link explanation/plutus-core.md %})
  &mdash; what validators are compiled to, and how the ledger evaluates them.
- [The Plinth standalone compiler]({% link explanation/standalone-compiler.md %})
- [The Extended UTXO Model][eutxo-paper] &mdash; the paper formalising the EUTXO
  model that Cardano is built on.
- [Cardano][cardano]

[cardano]: https://cardano.org/
[eutxo-paper]: https://www.iog.io/papers/the-extended-utxo-model
