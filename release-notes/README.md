# Release notes

All of this repo's notes sit under `release-notes/swift-runtime/`, and `release.yml` passes
`--short swift-runtime` to `release-notes.sh`, so that is the only tree it reads. For a release not yet
published, `release-notes/swift-runtime/<full-version>/` holds:

- `changes/<slug>`: one per user-visible change; the slug is `[a-z0-9-]+` and orders the bullets; line 1
  is one sentence and there are no other lines.
- `rebuild` (optional): present means users must rebuild something; line 1 says what.
- `requires/<short>` (optional): a dependency newly required or raised; line 1 is its minimum version.

`release-notes/swift-runtime/notice` (optional) opens every release's footer. Each sentence is checked
by shipyard's `check-release-sentence.sh`; run it on a file before committing it. The `<version>.md` files
beside these are the prose of releases already published, kept as they shipped. `release-notes/swift-toolchain/*.md` is legacy (6.3.3-era prose of a
separate toolchain repo's releases) and no longer read. Do not add your own `##`
title anywhere: the generator emits the title itself.

A repackage (an ingredient bump, no new Swift version) normally has no file here at all: that is a
normal case, not a failure. The generator composes the whole body -- naming which ingredient moved
-- on its own.

The generated file (`dist/RELEASE_NOTES.md`, built fresh every run) is what actually ships: it is
both the Sparkle appcast `<description>` and the GitHub Release body, the same bytes by construction.
