---
title: Your first smart contract with Plinth (Windows)
permalink: /tutorials/first-smart-contract-windows/
---
Before writing a real validator, it helps to get the whole toolchain working
end to end with the simplest possible Plinth program: a function that adds two
numbers. In this tutorial you will install `uplc-ghc`, create a tiny project
from scratch, compile it, run it, and read the Plutus Core it produced.

This tutorial targets **Windows**. It mirrors
[the Linux/macOS tutorial]({% link tutorials/first-smart-contract.md %}); the
project files are the same, only the setup and the shell commands differ.

## Before you start

You need on `PATH`:

- [ghcup](https://www.haskell.org/ghcup/) 0.2.1.0 or newer (check with
  `ghcup --version`);
- a recent `cabal` (3.8 or newer);
- [Git for Windows](https://git-scm.com/download/win): cabal uses `git` to
  fetch the `source-repository-package` dependencies of this project;
- ghcup's `bin` directory, `C:\ghcup\bin` by default, where the compiler
  installed in step 1 lands. The standard ghcup setup adds it to `PATH`
  already.

The commands below work in both PowerShell and the classic Command Prompt,
except where noted.

Two Windows settings matter before the first build:

**Enable long paths in Git.** The dependencies fetched by cabal contain paths
longer than the 260-character Windows default, and the checkout fails with
"Filename too long" otherwise:

```console
> git config --global core.longpaths true
```

If the checkout still fails, also lift the limit in Windows itself, with this
registry change from an **administrator** PowerShell:

```console
> New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
```

See [the accepted answer to "Filename too long in Git for
Windows"](https://stackoverflow.com/a/22575737) for the details: why the limit
exists, the system-wide Git alternative (`--system`), and the Microsoft
documentation on `LongPathsEnabled`.

**Smart App Control blocks the build.** The Plinth binaries are not signed
yet. On a Windows 11 system with Smart App Control active, the build stops
with error 4551 when cabal runs them. You must turn Smart App Control off
(Windows Security &gt; App &amp; browser control &gt; Smart App Control
settings) to use this toolchain.

The rest of the tutorial assumes the compiler is available as plain
`uplc-ghc`, which is what step 1 gives you.

## Step 1: Install Plinth

`uplc-ghc` is distributed via ghcup as a custom tool named `plinth` (see
[Install Plinth standalone compiler]({% link how-to/install.md %}) for the
details). Add the Plinth release channel, then install and activate the tool:

```console
> ghcup config add-release-channel https://raw.githubusercontent.com/input-output-hk/ghc-plinth/ghcup-channel/ghcup-plinth.yaml
> ghcup install plinth latest
> ghcup set plinth latest
```

Check that the compiler is on `PATH`:

```console
> uplc-ghc --version
```

If you have already installed it this way, skip to step 2. Make sure the
installed version is 9.6.166.2 or newer: on Windows, older releases do not
work with the `cabal.project` below (they lack the `uplc-ghc-pkg` shim). Run
the two `install`/`set` commands above again to update.

## Step 2: Create the project

Make a new directory and add the three files below. They are identical to the
Linux/macOS tutorial's files.

**`cabal.project`** wires up the build. It points cabal at `uplc-ghc` and its
`ghc-pkg` (installed by ghcup as `uplc-ghc-pkg`, so that it does not collide
with your regular GHC); pulls the
Plinth libraries (`plutus-tx`, `plutus-core`) from the
`ghc-plinth-plutus` fork the compiler was built against; uses the Cardano
package repository (CHaP) for the remaining dependencies; and builds the Cardano
crypto C libraries (`libsodium`, `secp256k1`, `blst`) from source via the
`*-clib` blocks, so you do not need them installed on your system.

The `with-hc-pkg` line is essential on Windows: without it, cabal picks up the
`ghc-pkg.exe` of your regular GHC and fails with a version mismatch (see
[Use uplc-ghc in a project]({% link how-to/use.md %})):

```haskell
with-compiler: uplc-ghc
with-hc-pkg:   uplc-ghc-pkg

packages: .

repository cardano-haskell-packages
  url: https://chap.intersectmbo.org/
  secure: True
  root-keys:
    3e0cce471cf09815f930210f7827266fd09045445d65923e6d0238a6cd15126f
    443abb7fb497a134c343faf52f0b659bd7999bc06b7f63fa76dc99d631f9bea1
    a86a1f6ce86c449c46666bda44268677abf29b5b2d2eb5ec7af903ec2f117a82
    bcec67e8e99cabfa7764d75ad9b158d72bfacf70ca1d0ec8bc6b4406d1bf8413
    c00aae8461a256275598500ea0e187588c35a5d5d7454fb57eac18d9edb86a56
    d4a35cd3121aa00d18544bb0ac01c3e1691d618f462c46129271bccf39f7e8ee

index-state:
  , hackage.haskell.org 2026-08-06T04:37:23Z
  , cardano-haskell-packages 2026-08-05T05:00:53Z

-- The Plinth libraries, from the fork uplc-ghc was built against. The
-- compiler itself is built into uplc-ghc, so plutus-tx-plugin is not needed.
source-repository-package
  type: git
  location: https://github.com/input-output-hk/ghc-plinth-plutus
  tag: f89c66c51e7b382c6574fc7d7887de8ba8ced457
  subdir: plutus-tx
          plutus-core

source-repository-package
  type: git
  location: https://github.com/hsyl20/cardano-base
  tag: 055ebbcc73e1cb234f1fd3fa237a4fb087130183
  subdir: cardano-crypto-class
          cardano-crypto-praos

source-repository-package
  type: git
  location: https://github.com/haskell-cryptography/blst-clib
  tag: 0fd1d38d5ceed5529ac646efae3095b493a97927

source-repository-package
  type: git
  location: https://github.com/haskell-cryptography/libsodium-clib
  tag: 985c18f75a71ff721370940666d71fda53edbb14

source-repository-package
  type: git
  location: https://github.com/haskell-cryptography/secp256k1-clib
  tag: 211b95baad422966c9e719ed70cbc189c58eaae5

package secp256k1-clib
  flags: +schnorrsig +recovery +ecdh +extrakeys

package cardano-crypto-class
  flags: +use-haskell-clibs

package cardano-crypto-praos
  flags: +use-haskell-clibs

package sodium-clib
  -- disable -fPIE: the static boot libraries are not built with it, so the
  -- link phase fails otherwise.
  configure-options: --enable-pie=no
```

Use the `ghc-plinth-plutus` commit that matches your `uplc-ghc`: the compiler and
these libraries are released together as a matched set, built from the same
commit. The commit above matches release 9.6.169.2 (the current ghcup
`latest`); for a different `uplc-ghc`, use the plutus commit it was built
from.

**Not for production.** The vendored crypto C libraries pulled in by the
`*-clib` `source-repository-package`s above have not been audited. Use this
setup for learning and experimentation only &mdash; never for contracts that
handle real funds.
{:.warning}

**`plinth-add.cabal`** describes the single executable. The `ghc-options` are
the flags Plinth needs to compile predictably (turning off optimisations that
would reshape the code before the plugin sees it) and to select the Plutus Core
version to target:

```haskell
cabal-version: 3.0
name:          plinth-add
version:       0.1.0.0
build-type:    Simple

executable plinth-add
  main-is:            Main.hs
  default-language:   Haskell2010
  default-extensions: DataKinds
  build-depends:
    , base
    , text
    , prettyprinter
    , plutus-tx
    , plutus-core
  ghc-options:
    -fexternal-interpreter
    -fobject-code -fno-full-laziness -fno-spec-constr
    -fno-specialise -fno-strictness -fno-unbox-small-strict-fields
    -fno-unbox-strict-fields
    -fplugin-opt Plinth.Plugin:target-version=1.1.0
```

**`Main.hs`** is the whole program. It defines the on-chain function, compiles
it to Plutus Core with a Template Haskell splice, and writes the result out as
readable UPLC:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Main where

import PlutusTx
import qualified PlutusTx.Prelude as Tx
import qualified PlutusTx.Code as Code
import PlutusCore.Pretty (prettyPlcReadableSimple)
import Prettyprinter (defaultLayoutOptions, layoutPretty)
import Prettyprinter.Render.Text (renderStrict)
import Data.Text (unpack)

-- The on-chain function: add two integers.
addTyped :: Integer -> Integer -> Integer
addTyped x y = x Tx.+ y

-- Compile it to Plutus Core at compile time.
addScript :: CompiledCode (Integer -> Integer -> Integer)
addScript = $$(compile [|| addTyped ||])

-- Render compiled code as readable UPLC text.
renderUPLC :: CompiledCode a -> String
renderUPLC =
    unpack
  . renderStrict
  . layoutPretty defaultLayoutOptions
  . prettyPlcReadableSimple
  . Code.getPlcNoAnn

main :: IO ()
main = writeFile "add.uplc" (renderUPLC addScript)
```

The typed quote `[|| addTyped ||]` and the `compile` splice are the only
Plinth-specific pieces; `PlutusTx.Prelude` (imported as `Tx`) supplies the
on-chain `+`, and everything else is ordinary Haskell.

## Step 3: Build it

```console
> cabal update
> cabal build
```

The first run clones and builds the Plinth libraries and the crypto C libraries
from source, so expect it to take a while. Because the Plinth plugin is built
into `uplc-ghc`, no extra plugin configuration is required: the `compile` splice
is translated to Plutus Core as part of the normal build.

If the clone step fails with "Filename too long", or the build stops with
error 4551, go back to [Before you start](#before-you-start).

## Step 4: Run it

```console
> cabal run plinth-add
```

`main` runs and writes the compiled program to `add.uplc` in the current
directory.

## Step 5: Look at the Plutus Core

In the Command Prompt (`cat` only exists in PowerShell):

```console
> type add.uplc
```

You should see something like:

```
program 1.1.0 (\x y -> addInteger x y)
```

That is the [UPLC]({% link explanation/uplc.md %}) your two-line Haskell function
compiled to &mdash; the `+` became the `addInteger` builtin, wrapped in a
`program` with its [language version]({% link explanation/uplc.md %}). This is
exactly the kind of code the Cardano ledger executes, produced from Haskell by
`uplc-ghc`.

## Where to go next

- [Lock and unlock funds on a local chain]({% link tutorials/lock-and-unlock.md %})
  &mdash; the next tutorial: write a real validator, deploy it on a local
  Cardano network, and spend from it with `cardano-cli`. (Linux only for now.)
- [Use uplc-ghc in a project]({% link how-to/use.md %}) &mdash; the same compiler
  setup, described on its own.
- [The Plinth contract language]({% link explanation/plinth-language.md %})
  &mdash; how a real validator is written, beyond this toy function.
- [Generate a blueprint]({% link how-to/generate-blueprint.md %}) &mdash; package
  a compiled script for off-chain tooling. (A tutorial walking through it on a
  small example is coming.)
- [Test a Plinth contract locally]({% link how-to/test.md %}) &mdash; evaluate a
  compiled validator and measure its execution budget, with no node.
