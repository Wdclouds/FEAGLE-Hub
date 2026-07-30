# Security Policy

## APK and device safety

Do not publish, mirror, or attach WeChat APK files to this repository.

A downloadable package source must not be marked `verified` until all of the
following have been independently recorded:

- package name
- version name
- file SHA-256
- signing certificate SHA-256
- supported ABI
- verification date and device profile

The setup tool must stop when a published hash or signer does not match.

## Secrets and personal data

Do not submit:

- Bridge pairing codes or device tokens
- Android device identifiers
- WeChat account data, contacts, sessions, QR codes, or message content
- ADB diagnostic archives that have not been redacted
- Server addresses or private Tailnet information

The project must not silently enable Root, VPN, notification access, module
scope, or other sensitive Android permissions.

## Reporting

Use GitHub private vulnerability reporting or contact the repository owner
privately. Revoke exposed credentials immediately; deleting only the latest
file does not remove a secret from Git history.
