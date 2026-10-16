---
title: Languages for smart contracts
permalink: /explanation/languages/
---
Every Cardano smart contract ultimately runs as
[Untyped Plutus Core (UPLC)]({% link explanation/plutus-core.md %}) on the CEK
machine. UPLC is deliberately small, so almost nobody writes it by hand:
instead, several higher-level languages compile down to it. Plinth is one of
them. This page surveys the main options, explains how they differ, and shows
where Plinth fits.

## How to compare them

The languages target the same on-chain format but make different choices. A few
axes capture most of the differences:

- **Base language and familiarity.** Some are a *subset* of an existing language
  (you write ordinary Haskell or Python), some are *standalone* languages with
  their own syntax, and some are *embedded DSLs* (eDSLs) &mdash; libraries inside
  a host language that build UPLC as a data structure.
- **Abstraction level and control.** High-level languages hide UPLC behind
  familiar constructs. Low-level eDSLs instead expose the structure of the
  generated UPLC, letting you hand-tune it.
- **On-chain efficiency.** The size of the resulting script and the
  [execution units]({% link explanation/plutus-core.md %}) it consumes both feed
  into transaction fees, so how tightly a language optimizes its output matters.
- **Tooling and maturity.** Compiler, editor support, error messages, and
  debugging vary widely.
- **Scope.** Some languages cover only the on-chain validator; others also help
  with the off-chain code that builds and submits transactions.

## The languages

**[Plinth][plinth]** (formerly Plutus Tx) is a subset of Haskell. You write
ordinary Haskell and a GHC plugin translates the relevant definitions to UPLC
&mdash; this fork bakes that plugin into the compiler as `uplc-ghc` (see
[The Plinth standalone compiler]({% link explanation/standalone-compiler.md %})).
It is IOG's
reference implementation, so it tracks the ledger's capabilities closely and
gives access to the full Haskell ecosystem, which suits teams already fluent in
Haskell. Plinth is not limited to on-chain validators: because Plinth code is
just Haskell, the *off-chain* code that builds and submits transactions can be
written in the same language &mdash; even in the same file as the on-chain
contract &mdash; and the compiler ensures that data crossing the
on-chain/off-chain boundary is transferred safely, sharing the same Haskell
types on both sides. The trade-offs: its output is generally less size-optimized
than Aiken or Plutarch, and because compilation happens inside a GHC plugin,
debugging the on-chain code has comparatively limited tooling.

**[Plutarch][plutarch]** is a typed eDSL embedded in Haskell. Rather than hiding UPLC, it
exposes its structure as Haskell values, so you describe quite directly the code
that will be generated. This gives fine control and produces among the smallest,
cheapest scripts available, which makes it popular for fee-critical validators.
The cost is a steeper learning curve and code that is harder to read and reason
about than straight-line Plinth.

**[Aiken][aiken]** is a purpose-built standalone language for on-chain code, with a
modern, functional syntax and a toolchain (compiler, formatter, test runner,
package management) designed for a smooth developer experience. It compiles to
compact, efficient UPLC and has grown a substantial community. It targets the
on-chain validator only, so it is typically paired with a separate off-chain
library to build and submit transactions.

**[OpShin][opshin]** lets you write on-chain code as a subset of valid Python. Its main
appeal is to developers with a Python background, who can reuse familiar syntax
and tooling rather than learning a functional language.

**[plu-ts][plu-ts]** is an eDSL embedded in TypeScript. It targets JavaScript/TypeScript
developers and spans both on-chain and off-chain code, so a web team can stay in
one language across the whole stack.

**[Scalus][scalus]** compiles Scala to UPLC, bringing Cardano development into the JVM
ecosystem. Like plu-ts it covers both on-chain and off-chain code, appealing to
teams already invested in Scala and the JVM.

**[Helios][helios]** is a lightweight standalone language with a JavaScript-like
syntax.
It is designed to be small and self-contained &mdash; often a single file with
no heavy toolchain &mdash; favouring quick starts and easy embedding.

**[Marlowe][marlowe]** is a special-purpose DSL for *financial* contracts, with both a
textual form and a visual editor. It is aimed at domain experts and
non-programmers building well-understood financial instruments, rather than at
general-purpose smart-contract development.

This list is not exhaustive, and the ecosystem keeps growing. If a language you
think belongs here is missing, please [open an issue][issues] so we can add it.

## At a glance

| Language | Base / paradigm | Scope | Notable trait |
|----------|-----------------|-------|---------------|
| Plinth | Subset of Haskell | On- and off-chain | Reference implementation; Haskell ecosystem; shared on-/off-chain types |
| Plutarch | Haskell eDSL (low-level) | On-chain | Fine control; among the smallest scripts |
| Aiken | Standalone functional | On-chain | Modern toolchain and developer experience |
| OpShin | Subset of Python | On-chain | Familiar to Python developers |
| plu-ts | TypeScript eDSL | On- and off-chain | One language for web/full-stack teams |
| Scalus | Scala | On- and off-chain | JVM ecosystem |
| Helios | Standalone (JS-like) | On-chain | Lightweight, self-contained |
| Marlowe | Financial DSL | On-chain | Visual editor; for financial contracts |

## Where Plinth fits

Plinth trades maximal on-chain optimization for Haskell familiarity and for
being the maintained reference implementation that tracks the ledger most
closely. Teams already working in Haskell, or who want the canonical, best-
supported path, tend to reach for Plinth. Projects where script size and fees
are the dominant concern sometimes drop down to Plutarch for tighter control, or
choose Aiken for its dedicated tooling. All of them compile to the same UPLC, so
the choice is about the path to that target, not the target itself.

## Further reading

- [How smart contracts run: Plutus Core and the CEK machine]({% link explanation/plutus-core.md %})
  &mdash; the common compilation target these languages share.
- [The Plinth standalone compiler]({% link explanation/standalone-compiler.md %})
- [Plinth user guide][plinth]
- [Cardano smart-contract languages][devportal] &mdash; the Cardano Developer
  Portal's overview of the options.

[plinth]: https://plutus.cardano.intersectmbo.org/docs/
[plutarch]: https://plutarch-plutus.org/
[aiken]: https://aiken-lang.org/
[opshin]: https://opshin.dev/
[plu-ts]: https://github.com/HarmonicLabs/plu-ts
[scalus]: https://scalus.org/
[helios]: https://helios-lang.io/
[marlowe]: https://marlowe.iohk.io/
[devportal]: https://developers.cardano.org/docs/smart-contracts/
[issues]: https://github.com/ican-group/ghc-plinth/issues
