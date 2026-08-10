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

Do not include translation files in feature pull requests. Follow the Crowdin
workflow described below.

As app is in early stage of development, expect large codebase changes. 

Complete your PR before submitting it. 

If you implement something big, better create multiple PR for each small part.

Don't add any *.lock files, except pubspec.lock.

## Translations
If you want to collaborate by adding your language to the application, you can do it through [our Crowdin project](https://crowdin.com/project/chameleonultragui). Do not contribute files into `chameleonultragui/lib/l10n/app_*.arb`. All translations should be added only to Crowdin. If your language is missing, you can create issue and ask to enable it. "Chameleon Ultra GUI", "Chameleon" and other trademarks should not be translated.
