# Contributing to Shubi

Thanks for helping. Shubi deletes files on people's Macs, so changes are judged first by what they could delete by mistake.

## Report a bug or ask for a feature

Open an [issue](https://github.com/MuchanKim/Shubi/issues). For a bug, include:

- your macOS and Shubi versions
- the section and item involved, with its path if you can share it
- what you expected and what happened

If Shubi deleted something it shouldn't have, say so in the title. That comes before anything else.

## Set up

Follow [Build from source](README.md#build-from-source). Run the tests in both languages before you open a pull request:

```sh
xcodebuild -project Shubi.xcodeproj -scheme Shubi -destination 'platform=macOS' -testLanguage en test
xcodebuild -project Shubi.xcodeproj -scheme Shubi -destination 'platform=macOS' -testLanguage ko test
```

## Changes that delete files

- Every file deletion goes through `Cleaner.isAllowed` in `Shubi/Cleaning/Cleaner.swift`, which only allows paths inside the folder that kind of item lives in. A new kind of item gets its own `Policy`. Don't widen an existing one.
- Add tests to `ShubiTests/CleanerTests.swift` for the paths the new policy allows and the ones it refuses, symlinks included.
- Smart Clean only takes items that apps rebuild on their own. If an item might hold the user's work or settings, list it for review instead.
- Tests delete only fixtures they create themselves, with unique names, as the existing helpers in `CleanerTests` do. Never point a test at files that were already there.

## Code and strings

- Swift 6 language mode with default main-actor isolation. Keep file system work off the main actor.
- Follow the style of the surrounding code. Comments explain why, not what.
- User-facing strings live in `Shubi/Resources/Localizable.xcstrings`. Korean is the source language. Add the English translation in the same change, and look at both languages in the app: language switching is live, under Settings.

## Pull requests

- Branch from `main` as `<type>/<issue-number>-<short-description>`, where the type is one of `feat`, `fix`, `refactor`, `chore`, `docs` or `test`.
- Keep each pull request to one change, and link the issue it closes.
- Write commit messages in English, with a short subject and a body that has `What` and `Why` sections.
- For a UI change, attach a screenshot in the light and dark themes.

By contributing, you agree that your work is released under the [MIT License](LICENSE).
