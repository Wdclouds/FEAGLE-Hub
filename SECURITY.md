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

## Android build and Agent safety

- Keep the Gradle Wrapper JAR and distribution SHA-256 pinned to an official
  Gradle release.
- Do not commit `local.properties`, Gradle caches, APK outputs, debug
  keystores, device logs, or Android private application data.
- Installing or updating the Agent requires explicit user confirmation.
- The installer must not uninstall an Agent with a different signer to force
  an update.
- Module enablement, module scope, notification access, and Bridge credentials
  remain user-controlled steps.
- Status checks may report process, package, permission, and redacted log
  markers, but must not read or print the stored Bridge token.

## Reporting

Use GitHub private vulnerability reporting or contact the repository owner
privately. Revoke exposed credentials immediately; deleting only the latest
file does not remove a secret from Git history.
