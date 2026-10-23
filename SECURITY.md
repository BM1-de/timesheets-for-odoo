# Security Policy

## Supported versions

Security fixes are made on the branch `main` and released as a new version of the app. Only the
latest release is supported.

## Reporting a vulnerability

Please do not report security problems in public issues, pull requests or discussions.

- Preferably use the private vulnerability reporting of GitHub: tab _Security_, _Report a
  vulnerability_ in
  [BM1-de/timesheets-for-odoo](https://github.com/BM1-de/timesheets-for-odoo/security).
- Or write an e-mail to the maintainer, Phillip Baumgärtner <baumgaertner@bm1.de>, with the
  subject "Security timesheets-for-odoo".

Describe the problem, the affected version, how to reproduce it and its possible impact. Do not
send real API keys or personal data; use a test database for the example.

We confirm the receipt, examine the report, keep you informed and publish a fix together with a
security notice in `CHANGELOG.md`. We credit you unless you prefer not to be named.

## Scope

In scope:

- handling of the Odoo API key: it must only be stored in the macOS Keychain, only be sent to the
  configured Odoo server and never be logged;
- network traffic: only to the configured server, encrypted unless the server is `localhost`;
  redirects are not followed;
- data written to Odoo beyond new timesheet lines and the user's own attendances;
- updates: the app must only install updates whose DMG carries the project's EdDSA signature and
  whose app is signed with the project's Developer ID.

Out of scope are vulnerabilities of Odoo itself (please report them to Odoo S.A.) and the access
rights a user has in Odoo: the app only acts with the rights of the signed-in user.
