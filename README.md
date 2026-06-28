# SCOS Build Package

Official SCOS build package used by **SCOS Builder** to create Windows-based SCOS installation ISOs.

This repository contains the setup files injected into a Windows ISO to install **SCOS Standard**.

## Current build

* SCOS Build Package: `v0.3.6.4`
* Edition: `Standard`
* Channel: `stable`
* Minimum SCOS Builder version: `v0.1.2`

## Purpose

This repository is not the SCOS Builder application itself.

It contains the files that SCOS Builder downloads and merges into an extracted Windows ISO before rebuilding the final SCOS installation ISO.

## Repository structure

```txt
SCOS-Build/
├─ Autounattend.xml
├─ manifest.json
├─ README.md
└─ sources/
   └─ $OEM$/
      └─ $$/
         └─ Setup/
            └─ Scripts/
               ├─ Recovery/
               │  └─ SCOSRecovery.wim
               ├─ disable-controller-audio.ps1
               ├─ RunSCOSSetup.ps1
               ├─ SCOSRecovery.wim
               ├─ SCOSSetupProgress.ps1
               ├─ SetupComplete.cmd
               └─ SteamCursorGuard.exe
```

## Bootstrap password placeholder

`Autounattend.xml` contains this placeholder:

```txt
__SCOS_BOOTSTRAP_PASSWORD__
```

This is intentional.

SCOS Builder must replace every occurrence of this placeholder with a temporary generated bootstrap password before building the ISO.

The bootstrap password is only used during Windows setup to create and auto-log into the temporary SCOS account. During final setup, SCOS replaces it with a unique generated password.

## Public Standard behavior

SCOS Standard is the public edition.

In SCOS Standard:

* Steam Big Picture is used as the main shell.
* Normal Windows desktop access is restricted.
* Windows Settings and `ms-settings` are not part of the Standard experience.
* Sound settings may remain available for Steam and audio device configuration.
* Readable password recovery files are not created in public Standard builds.

## Required files

The following files are required:

```txt
Autounattend.xml
sources/$OEM$/$$/Setup/Scripts/SetupComplete.cmd
sources/$OEM$/$$/Setup/Scripts/RunSCOSSetup.ps1
sources/$OEM$/$$/Setup/Scripts/SCOSSetupProgress.ps1
```

## Recommended files

The following files are recommended for the complete SCOS experience:

```txt
sources/$OEM$/$$/Setup/Scripts/disable-controller-audio.ps1
sources/$OEM$/$$/Setup/Scripts/SteamCursorGuard.exe
sources/$OEM$/$$/Setup/Scripts/Recovery/SCOSRecovery.wim
```

## Recovery environment

`SCOSRecovery.wim` should be placed in:

```txt
sources/$OEM$/$$/Setup/Scripts/Recovery/SCOSRecovery.wim
```

A fallback copy may temporarily exist at:

```txt
sources/$OEM$/$$/Setup/Scripts/SCOSRecovery.wim
```

The fallback copy is temporary and may be removed in a later build package once SCOS Builder reliably copies the recovery image to the `Recovery` folder.

## Notes

This package does not include Windows.

SCOS does not provide, sell, or activate Windows. Windows activation remains separate from SCOS and is the user’s responsibility.

Windows, Steam, EA App, Unified Remote, and other third-party software remain owned by their respective companies.