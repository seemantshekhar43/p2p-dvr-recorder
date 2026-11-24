# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private reporting: **Security > Report a vulnerability** on this repository. Include what you found, how to reproduce it, and the affected version. You can expect an acknowledgement within a few days.

## Scope notes

- The web viewer uses HTTP basic auth and has no TLS of its own. Run it behind HTTPS and a VPN, as described in the README ("Exposing it safely").
- The DVR password is stored in `/etc/nvr-recorder/env` (mode 600) and is passed to ffmpeg in the RTSP URL, so it is visible to other local users in `ps`. Do not run this on a shared multi-user host.
- Recordings are stored unencrypted.
