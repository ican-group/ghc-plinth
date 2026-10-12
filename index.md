---
title: Overview
permalink: /
---
<!-- The wordmark animation. It plays once and stops on a frame identical to
     plinth-wordmark.png, so the clip and the still are interchangeable once it
     has finished. The poster is the animation's FIRST frame, not the finished
     mark -- see Note [The poster is the FIRST frame] in _logo/make-anim.sh.
     Two sources so there is always a playable one; anyone who has asked for
     less motion gets the still instead, via the swap below.

     width/height give the aspect ratio up front so the page does not jump on
     load. They are presentational hints, and this site has no global
     "height: auto" rule to cancel the height one, hence it in the style. -->
<style>
  .wordmark-still { display: none; }
  @media (prefers-reduced-motion: reduce) {
    .wordmark-anim  { display: none; }
    .wordmark-still { display: inline; }
  }
</style>
<p style="text-align: center; margin: 0 0 1.5rem;">
  <video class="wordmark-anim" autoplay muted playsinline preload="auto"
         aria-label="Plinth"
         poster="{{ '/assets/images/plinth-wordmark-poster.webp' | relative_url }}"
         width="1200" height="467"
         style="width: 100%; max-width: 620px; height: auto;">
    <source src="{{ '/assets/images/plinth-wordmark.webm' | relative_url }}"
            type="video/webm">
    <source src="{{ '/assets/images/plinth-wordmark.mp4' | relative_url }}"
            type="video/mp4">
  </video>
  <img class="wordmark-still" alt="Plinth"
       src="{{ '/assets/images/plinth-wordmark.png' | relative_url }}"
       width="1200" height="467"
       style="width: 100%; max-width: 620px; height: auto;">
</p>

Documentation for the **Plinth** compiler, a language for writing on-chain and
off-chain code for the [Cardano][cardano] blockchain. Plinth (formerly Plutus
Tx) is a subset of [Haskell](https://www.haskell.org/) compiled to **Plutus
Core**.

## Finding your way around

This documentation follows the [Diataxis](https://diataxis.fr/) framework,
which separates docs into four kinds by what you need from them:

- **[Explanation]({% link explanation/index.md %})** &mdash;
  *understanding-oriented.* Background and discussion: what Plinth is and how
  the compiler works.
- **[Tutorials]({% link tutorials/index.md %})** &mdash; *learning-oriented.*
  Start here if you are new: a hands-on lesson that walks you through compiling
  your first smart contract.
- **[How-to guides]({% link how-to/index.md %})** &mdash; *task-oriented.*
  Practical recipes for a specific job: install the compiler, use it in a
  project, and generate a blueprint.
- **[Reference]({% link reference/index.md %})** &mdash; *information-oriented.*
  Dry facts to look up.

[cardano]: https://cardano.org/
