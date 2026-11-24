# Contributing

Thanks for helping. Useful contributions include bug reports, reports of which DVR models and firmware work (or do not), documentation fixes, and code.

## Reporting a problem

Open an issue and include: the DVR model and firmware if known, which cloud it uses (InstaOn or Easy4ip), your host OS, and the relevant lines from `journalctl -u nvr-tunnel` or `journalctl -u nvr-recorder@N`. **Remove your DVR serial, passwords, tokens and public IP addresses** before pasting anything.

## Development

See the "Development" section of the [README](README.md). Before opening a pull request, run:

```bash
python3 -m unittest discover -s viewer     # viewer tests
scripts/test-retention.sh                  # retention tests
docker run --rm -v "$PWD":/src -w /src p2p-dvr-dev swift test   # Swift tests (after building Dockerfile.dev)
```

CI runs the same checks on every push and pull request.

## Pull requests

- Keep a change focused; explain the problem it solves in the description.
- Add or update a test when behaviour changes.
- Never commit credentials, serials, recordings or captures (`.gitignore` covers the common cases).
- By contributing you agree your work is released under the project's [MIT License](LICENSE).
