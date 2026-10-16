Plinth Standalone Compiler
==========================

This is a fork of [GHC][ghc] that embeds the [Plinth][plinth] compiler, used
to write smart contracts for the [Cardano][cardano] blockchain. Plinth
(formerly known as Plutus Tx) is a subset of Haskell compiled to Plutus Core
via a GHC Core plugin shipped here as a built-in static plugin. The build
produces `uplc-ghc`, a compiler that installs alongside your normal GHC and
never replaces it.

Documentation
=============

The documentation lives on the documentation site:

  **<https://ican-group.github.io/ghc-plinth/>**

It covers the installation of `uplc-ghc` (via ghcup), its use in a project,
the build from source, the tests, and background on how the compiler works.

Making a release
================

Releases are cut from **Actions -> CI -> Run workflow**, with
`release_version` set and `publish` ticked. See Note [ghcup release channel]
in `.github/workflows/ci.yml` for the details.

  [ghc]: https://www.haskell.org/ghc/ "www.haskell.org/ghc/"
  [plinth]: https://plutus.cardano.intersectmbo.org/docs/
          "Plinth and Plutus Core Documentation"
  [cardano]: https://cardano.org/ "cardano.org"
