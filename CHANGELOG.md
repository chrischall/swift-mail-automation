# Changelog

## [1.2.0](https://github.com/chrischall/swift-mail-automation/compare/v1.1.4...v1.2.0) (2026-08-15)


### Features

* **search:** read Mail's Envelope Index, and never report a timeout as zero results ([#52](https://github.com/chrischall/swift-mail-automation/issues/52)) ([ae265e8](https://github.com/chrischall/swift-mail-automation/commit/ae265e881d54cd96f5ec0aa9238e0bb8374121f7))


### Bug Fixes

* **search:** make sinceDaysAgo&lt;=0 mean the same thing on every backend ([#55](https://github.com/chrischall/swift-mail-automation/issues/55)) ([f1b91ed](https://github.com/chrischall/swift-mail-automation/commit/f1b91ed50430bbad752450ef4a37c0cbda7edfbe))

## [1.1.4](https://github.com/chrischall/swift-mail-automation/compare/v1.1.3...v1.1.4) (2026-08-10)


### Bug Fixes

* parse offset-less ISO timestamps as local wall-clock time ([#49](https://github.com/chrischall/swift-mail-automation/issues/49)) ([bd25c3a](https://github.com/chrischall/swift-mail-automation/commit/bd25c3ad223a3ed17bc19b5b035bca58ff292401))

## [1.1.3](https://github.com/chrischall/swift-mail-automation/compare/v1.1.2...v1.1.3) (2026-08-09)


### Bug Fixes

* run AppleScript on the main thread so cross-application scripts stop stalling ([#45](https://github.com/chrischall/swift-mail-automation/issues/45)) ([4cf7d73](https://github.com/chrischall/swift-mail-automation/commit/4cf7d73b4e73a63eb7d15221b5bbcfe62e6a279f))

## [1.1.2](https://github.com/chrischall/swift-mail-automation/compare/v1.1.1...v1.1.2) (2026-07-27)


### Documentation

* getMessageScript emits eight fields, not seven ([#42](https://github.com/chrischall/swift-mail-automation/issues/42)) ([3522d3f](https://github.com/chrischall/swift-mail-automation/commit/3522d3fad62b22fafffad372b3bbb1e9760b4e8c))

## [1.1.1](https://github.com/chrischall/swift-mail-automation/compare/v1.1.0...v1.1.1) (2026-07-19)


### Documentation

* replace duplicated fleet policy with a pointer ([#39](https://github.com/chrischall/swift-mail-automation/issues/39)) ([bc900da](https://github.com/chrischall/swift-mail-automation/commit/bc900da700978f94f31bdcc160410268c7478b03))

## [1.1.0](https://github.com/chrischall/swift-mail-automation/compare/v1.0.6...v1.1.0) (2026-07-14)


### Features

* add full-message get, message ids, and offset pagination ([#35](https://github.com/chrischall/swift-mail-automation/issues/35)) ([32d7ec6](https://github.com/chrischall/swift-mail-automation/commit/32d7ec67b3c6b549f6e17ecc45be5739962ee3c9))

## [1.0.6](https://github.com/chrischall/swift-mail-automation/compare/v1.0.5...v1.0.6) (2026-07-13)


### Bug Fixes

* sanitize mailbox/account names and distinguish cancelled CI runs ([#33](https://github.com/chrischall/swift-mail-automation/issues/33)) ([620a7ee](https://github.com/chrischall/swift-mail-automation/commit/620a7eeaed2d2ae8cc07c822e6915cde61974b25))

## [1.0.5](https://github.com/chrischall/swift-mail-automation/compare/v1.0.4...v1.0.5) (2026-07-08)


### Bug Fixes

* **security:** escape backslashes in AppleScript and sanitize output fields ([#28](https://github.com/chrischall/swift-mail-automation/issues/28)) ([e20d78c](https://github.com/chrischall/swift-mail-automation/commit/e20d78cc90ee1c1c3ffdedafbad72e759d5ba603))

## [1.0.4](https://github.com/chrischall/swift-mail-automation/compare/v1.0.3...v1.0.4) (2026-06-21)


### Documentation

* add auto-review follow-up convention to CLAUDE.md ([#26](https://github.com/chrischall/swift-mail-automation/issues/26)) ([75f554d](https://github.com/chrischall/swift-mail-automation/commit/75f554d94bec1dd37d63455a276340cbd06802f6))
* require Conventional Commit PR titles; correct squash-merge guidance ([#24](https://github.com/chrischall/swift-mail-automation/issues/24)) ([ecf5275](https://github.com/chrischall/swift-mail-automation/commit/ecf527591154dc82bc3b4b8fb52008dce8e669e7))

## [1.0.3](https://github.com/chrischall/swift-mail-automation/compare/v1.0.2...v1.0.3) (2026-06-13)


### Documentation

* add license badge to README ([#18](https://github.com/chrischall/swift-mail-automation/issues/18)) ([2c22c48](https://github.com/chrischall/swift-mail-automation/commit/2c22c4845cb1f95486a42ee4bdf192b21a030bc4))

## [1.0.2](https://github.com/chrischall/swift-mail-automation/compare/v1.0.1...v1.0.2) (2026-05-29)


### Bug Fixes

* **ci:** auto-merge arm guards ([#16](https://github.com/chrischall/swift-mail-automation/issues/16)) ([4ba2b33](https://github.com/chrischall/swift-mail-automation/commit/4ba2b330e8b8a9884ca9a93189566f922c5fc76c))
* **ci:** switch auto-merge to squash and label-gated design ([#11](https://github.com/chrischall/swift-mail-automation/issues/11)) ([a7bff71](https://github.com/chrischall/swift-mail-automation/commit/a7bff713a49684dbb19f1be98aec6161ba10cc21))

## [1.0.1](https://github.com/chrischall/swift-mail-automation/compare/v1.0.0...v1.0.1) (2026-05-25)


### Bug Fixes

* **ci:** prevent labeled event from cancelling auto-review ([#12](https://github.com/chrischall/swift-mail-automation/issues/12)) ([d34fa81](https://github.com/chrischall/swift-mail-automation/commit/d34fa81f9728b01274d16a9e276b324038bdde8a))
