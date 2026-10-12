# Example projects

Working copies of the projects built in the website tutorials
(https://input-output-hk.github.io/ghc-plinth/tutorials/). Keep each project's
files byte-identical to the code blocks of its tutorial page.

- `add/`: "Your first smart contract with Plinth". Compiles an addition
  function and writes it as readable UPLC text (`add.uplc`).
- `lock/`: "Lock and unlock funds on a local chain". Compiles a Plutus V3
  lock/unlock validator and writes it as a cardano-cli text envelope
  (`lock.plutus`), used against a Yaci DevKit devnet.
- `lock-ghci/`: "Lock and unlock funds from GHCi". Off-chain cardano-api
  helpers to use the lock validator interactively. Builds with a standard
  GHC 9.6.7, not with uplc-ghc; reads the `lock.plutus` that `lock/` wrote.
- `lock-ghci-exp/`: "Lock and unlock funds with the experimental
  cardano-api". The same helpers as `lock-ghci/`, rebuilt on
  Cardano.Api.Experimental.
- `auction/`: "Run an auction on a local chain". Compiles the auction
  validator, without its parameters, to `auction.plutus`.
- `auction-ghci/`: the off-chain helpers of the same tutorial. They apply the
  parameters to the validator, and run an auction from GHCi with three
  wallets. Builds with a standard GHC 9.6.7; reads the `auction.plutus` that
  `auction/` wrote.

`add/`, `lock/` and `auction/` build with the uplc-ghc release named in their
`cabal.project` (`with-compiler`). Install it with
`ghcup install plinth <version>`. The `ghc-plinth-plutus` tag in the same
file is the commit that this release is built from: change the two
together.

`test-tutorials.sh` tests all of it, including the GHCi sessions against a
real devnet; CI runs it (.github/workflows/tutorials.yml) on changes to
examples/ and weekly.
