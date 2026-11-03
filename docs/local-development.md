# Running a local development build

```bash
./scripts/install-local.sh
```

This builds the working tree, requests a graceful app quit, backs up the installed bundle, installs and launches the new build, repairs helper registration and prints status. Ad-hoc signing is the default and disables helper caller-signature verification; use the signed release for normal distribution. An explicit `ECLAM_SIGN_ID` is supported, but a different developer identity is not automatically compatible with the helper's pinned release identity.

An app that does not quit within 15 seconds is left in place. A failed copy restores the previous bundle. Launch, repair and status failures return a nonzero exit and retain the backup instead of printing success. After success the three most recent replacements remain in `~/.eclam-backups` as `.app.bak` directories. To recover manually, quit the app and move the selected backup back to `/Applications/ElectronicClam.app`.

`ECLAM_INSTALL_DEST`, `ECLAM_BACKUP_DIR` and `ECLAM_QUIT_TIMEOUT` allow an explicit destination, backup directory and bounded wait. Tests use a disposable checkout and fake OS commands; they do not install or restart your app.

```bash
python3 Tests/InstallLocalTests.py
python3 Tests/CaskCleanupTests.py
./scripts/smoke.sh
```

The cask uses Homebrew's [structured uninstall steps](https://docs.brew.sh/Cask-Cookbook#stanza-flight_steps), validated with Homebrew 7.0.9. Update Homebrew before using this cask. Only eclam-marked hooks are removed; malformed configurations are preserved. The cask in this repository and `jadhvank/homebrew-tap` are published separately. Changing this checkout does not update the live tap.

If a signed release helper is already installed, an ad-hoc CLI may correctly report that it cannot connect: it has no release Team ID. In that environment, validate `status` with a locally Developer ID-signed build. Do not disable the installed helper's caller verification or install a different helper just to make the test pass. `ECLAM_SIGN_ID=-` remains useful for build/unit-test work without a signing identity; report the live-helper check separately.
