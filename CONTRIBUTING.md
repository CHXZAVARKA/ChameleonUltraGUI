# Contributing 

## Community fork workflow

Discuss user-visible features, architecture changes, and other sweeping changes
in an issue before implementation. Agree on the problem, the smallest useful
scope, and the acceptance checks first.

Keep each pull request focused on one reviewable change. Explain in your own
words why the change is needed, what it changes, what it deliberately excludes,
and how you verified it.

If AI tools contributed to the change, disclose where they were used and the
extent of their contribution. The author remains responsible for reviewing the
diff, testing the behavior, and answering questions about the implementation.

Community feature pull requests may add required English source strings to
`chameleonultragui/lib/l10n/app_en.arb`. Do not edit non-English `app_*.arb`
files or commit generated localization output. Keep translation work separate
from the feature pull request.

The public Crowdin project belongs to upstream. Do not upload community-only
strings to it. For changes intended for upstream, follow the upstream policy:
discuss the localization path with the maintainers and do not include
localization files unless they request them.

As app is in early stage of development, expect large codebase changes. 

Complete your PR before submitting it. 

Don't add any *.lock files, except pubspec.lock.

## Translations
The [Crowdin project](https://crowdin.com/project/chameleonultragui) is managed
by upstream. It is not a publication path for fork-only strings. If your change
is intended for upstream, follow their current localization instructions.
"Chameleon Ultra GUI", "Chameleon" and other trademarks should not be
translated.
