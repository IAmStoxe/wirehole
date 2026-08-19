# Contributing

Thank you for the help. This page tells you how to send a useful issue or
a useful pull request.

## Before you open an issue

1. Run the doctor and read its output. It finds the common problems and
   prints the fix:

   ```bash
   ./scripts/wirehole-doctor.sh
   ```

2. Search the existing issues, open and closed.

3. If you upgraded from the old WireHole, read [UPGRADING.md](UPGRADING.md)
   first. The rewrite changed the layout, and most upgrade problems have a
   documented answer there.

When you open the issue, paste the doctor output, your `docker compose ps`,
and the log of the failing service. Remove your public IP address and your
passwords from the paste.

## Pull requests

- Keep one change per pull request. A small pull request gets a fast
  review.
- Run the tests before you push:

  ```bash
  shellcheck scripts/*.sh tests/*.sh
  ./tests/e2e-vpn.sh
  ```

  The end to end test connects real WireGuard clients. It needs Docker and
  a Linux kernel with the WireGuard module. CI runs the same tests on your
  pull request.

- Follow the style of the project:
  - Comments and documentation use short sentences in simple English. One
    sentence gives one fact or one instruction.
  - Plain ASCII only. No em dashes, no emoji, no decorative characters.
  - Shell scripts pass shellcheck and start with `set -uo pipefail`.
- A change to the compose file or to a default value needs a matching
  change in `.env.example` and in the README.
- A new feature needs a test that fails without the feature.

## What gets accepted

The project stays small on purpose. Three containers, one file of
settings, and tests that prove a real client connects. A good change makes
the stack more correct, more secure, or easier to operate. A change that
adds a service or a dependency needs a strong reason.

## Security problems

Do not open a public issue. Read [SECURITY.md](SECURITY.md).
