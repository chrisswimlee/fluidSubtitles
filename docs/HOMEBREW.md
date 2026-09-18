# Homebrew listing

Personal tap files live in a separate `homebrew-fluidsubtitles` repo, not this git tree. Official listing is a later PR to `homebrew/cask`. FluidVoice already owns `brew install --cask fluidvoice`.

## Todo

1. `gh auth login`
2. `./scripts/enable-github-gates.sh` so `chrisswimlee/fluidSubtitles` is public
3. `./build.sh release` with Developer ID and notarization credentials
4. Put the published team ID in `FluidProduct.allowedUpdateTeamIDs`
5. Tag `v1.6.11` (must match `CFBundleShortVersionString`) so `.github/workflows/release.yml` attaches `fluidsubtitles-1.6.11.zip` and `SHA256SUMS`
6. From the tap checkout: `./update-cask.sh 1.6.11 /path/to/fluidSubtitles/dist/SHA256SUMS`
7. Publish the tap:

```bash
cd /path/to/homebrew-fluidsubtitles
git add Casks/fluidsubtitles.rb README.md update-cask.sh .gitignore
git commit -m "Add fluidsubtitles cask."
gh repo create chrisswimlee/homebrew-fluidsubtitles --public --source=. --remote=origin --push
```

8. Verify:

```bash
brew tap chrisswimlee/fluidsubtitles
brew install --cask fluidsubtitles
# Open Theater, allow the microphone, Listen one sentence
brew uninstall --cask fluidsubtitles
```

9. After one launch, refresh zap paths with `brew generate-zap --cask fluidsubtitles` and commit any extras (do not zap FluidVoice or FluidAudio)
10. Add `brew tap chrisswimlee/fluidsubtitles && brew install --cask fluidsubtitles` to the app README Install section
11. After roughly 75 GitHub stars, PR `chrisswimlee-fluidsubtitles` to [Homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask) with a pinned `sha256` (not `:no_check`). Commit message: `chrisswimlee-fluidsubtitles 1.6.11 (new cask)`
