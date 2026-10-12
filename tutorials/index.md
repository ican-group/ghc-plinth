---
title: Tutorials
permalink: /tutorials/
---
*Learning-oriented lessons.* Tutorials take you by the hand through a complete,
guaranteed-to-work experience so you can learn by doing. They are for newcomers
who want to get started, not for looking up specific facts.

- [Your first smart contract with Plinth]({% link tutorials/first-smart-contract.md %})
  &mdash; targets Linux and macOS; it links to a Windows version.
- [Lock and unlock funds on a local chain (Linux)]({% link tutorials/lock-and-unlock.md %})
  &mdash; write a real validator, deploy it on a local Cardano network with
  Yaci DevKit, and spend from it with `cardano-cli`.
- [Lock and unlock funds from GHCi (Linux)]({% link tutorials/lock-and-unlock-ghci.md %})
  &mdash; the same chain interaction, done from Haskell with `cardano-api`
  and a GHCi session.
- [Lock and unlock funds with the experimental cardano-api (Linux)]({% link tutorials/lock-and-unlock-ghci-exp.md %})
  &mdash; the same GHCi helpers, rebuilt on `Cardano.Api.Experimental`, the
  successor of the deprecated transaction-building interface.
- [Run an auction on a local chain (Linux)]({% link tutorials/auction.md %})
  &mdash; a contract with a state that changes many times: bids, refunds,
  and a payout after the end time.
