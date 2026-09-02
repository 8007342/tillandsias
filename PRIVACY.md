# Privacy Policy — Tillandsias

_Last updated: 2026-08-31_

## The short version

**Tillandsias collects nothing.** There is no account to create, no telemetry,
no analytics, and no server operated by us that your installation talks to.
Everything the application produces stays on your own computer.

## What we collect

Nothing. We operate no servers that receive data from this application. There
is no usage reporting, no crash reporting, no analytics SDK, and no identifier
assigned to you or your machine.

We therefore hold no personal data about you, and there is nothing for us to
sell, share, disclose, or lose.

## What stays on your computer

Tillandsias runs locally. It creates a virtual machine and containers on your
own system, and everything it stores lives there:

- **Your projects and their files.** This is the part worth stating plainly,
  because it is the application's main job. When you open a project,
  Tillandsias mounts *that directory* into an isolated workspace running on
  your own machine, so that development tools — editors, compilers, language
  servers, coding agents — can read and write it. That is what the product is
  for; it could not work otherwise.

  What that access is limited to:
  - **only the directories you choose.** Tillandsias does not scan your drive,
    index your documents, or read folders you have not opened with it.
  - **only on your machine.** The workspace is a local virtual machine and
    local containers. Your code is not uploaded to us, because there is no
    "us" for it to be uploaded to — we run no servers.
  - **isolated from the rest of your system.** Each workspace sees the project
    you opened, not your whole filesystem. That isolation exists to protect
    you from the tools, not to hide anything from you.
- **Credentials you provide** (for example, a GitHub login you initiate) are
  stored in a local secret store on your machine.
- **Logs and diagnostics** are written to local files so you can inspect them.
  They stay on disk unless you choose to share them.

You can remove all of it at any time by resetting or uninstalling; the
application is designed to be wiped and rebuilt freely.

## Connections your computer makes

Tillandsias does not connect to us, but it does reach services **at your
direction** in order to work:

- **Software sources** — package repositories and release downloads (for
  example GitHub, Linux distribution mirrors, and language package registries)
  to fetch the software it runs.
- **Services you sign in to** — for example GitHub, when you start a login. Your
  interaction with those services is governed by their own privacy policies,
  not this one.
- **AI providers, only if you configure one.** Tillandsias can run language
  models entirely on your own machine. If you instead configure a remote
  provider, the content you send is transmitted to that provider under their
  terms. That choice is yours and is never made for you.

## Children

Tillandsias is a software development tool and is not directed at children.

## Changes

If this policy changes, the updated version will be published with the
application and the date above will change.

## Contact

Questions about this policy can be raised through the project's public issue
tracker at <https://github.com/8007342/tillandsias>.
