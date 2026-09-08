# Contributing

Discuss substantial behavior changes in an issue first. Keep changes focused and preserve queue compatibility, cancellation, hash verification and conservative cleanup behavior.

Use synthetic media and fake device adapters in tests. Never commit photo-library identifiers, actual device serials, account details, private keys, local State, logs, caches or build artifacts. Report issues with redacted diagnostics; never attach your entire photo library or state database.

Run the checks in README before opening a pull request. User-visible copy belongs in the English and Simplified Chinese semantic-key catalogs. Keep the native app aligned with the website's existing visual language.

Forks can build without secrets. Publishing automatic updates requires the fork's own Ed25519 key and HTTPS feed URL; never reuse the upstream feed for a differently signed fork.

Write source comments, developer documentation, commit messages and pull requests in English. Keep user-facing translations in semantic-key locale catalogs. Unicode fixtures and localization assertions may intentionally contain other languages. Chinese user documentation is maintained separately.
