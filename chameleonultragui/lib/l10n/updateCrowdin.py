import argparse
import json
import os
import sys
import urllib
from typing import Mapping, NamedTuple
from urllib.request import Request, urlopen


PROJECT_ID = 611911
SOURCE_ID = 33
PAGE_SIZE = 500
API_URL = "https://api.crowdin.com/api/v2"
CURRENT_TRANSLATION_URL = (
    "https://raw.githubusercontent.com/GameTec-live/ChameleonUltraGUI/"
    "main~1/chameleonultragui/lib/l10n/app_en.arb"
)
SOURCE_ARB_PATH = "chameleonultragui/lib/l10n/app_en.arb"


class SyncPlan(NamedTuple):
    added: dict[str, str]
    updated: dict[str, str]
    removed: tuple[str, ...]


def source_strings(arb: Mapping[str, object]) -> dict[str, str]:
    return {
        key: value
        for key, value in arb.items()
        if not key.startswith("@") and isinstance(value, str)
    }


def build_sync_plan(
    current_arb: Mapping[str, object], branch_arb: Mapping[str, object]
) -> SyncPlan:
    current = source_strings(current_arb)
    branch = source_strings(branch_arb)
    return SyncPlan(
        added={key: value for key, value in branch.items() if key not in current},
        updated={
            key: value
            for key, value in branch.items()
            if key in current and current[key] != value
        },
        removed=tuple(key for key in current if key not in branch),
    )


def dry_run_payload(plan: SyncPlan) -> dict[str, object]:
    return {
        "add": [
            {"identifier": key, "text": value, "fileId": SOURCE_ID}
            for key, value in plan.added.items()
        ],
        "update": [
            {"identifier": key, "text": value}
            for key, value in plan.updated.items()
        ],
        "remove": list(plan.removed),
    }


def progressbar(it, prefix="", size=60, out=sys.stdout):
    count = len(it)

    def show(j):
        x = int(size * j / count)
        print(
            f"{prefix}[{u'█' * x}{('.' * (size - x))}] {j}/{count}",
            end="\r",
            file=out,
            flush=True,
        )

    show(0)
    for i, item in enumerate(it):
        yield item
        show(i + 1)
    print("\n", flush=True, file=out)


def request(method, url, data=None, decode_data=True):
    if not data:
        data = {}

    result = urlopen(
        Request(
            url,
            method=method,
            data=json.dumps(data).encode(),
            headers={
                "Accept": "application/json",
                "Authorization": "Bearer " + str(os.getenv("CROWDIN_API")),
                "Content-Type": "application/json",
            },
        )
    )
    if decode_data:
        return json.loads(result.read().decode())


def fetch_all_strings():
    strings = []
    offset = 0
    while True:
        page = request(
            "GET",
            f"{API_URL}/projects/{PROJECT_ID}/strings"
            f"?limit={PAGE_SIZE}&offset={offset}",
        )["data"]
        strings.extend(page)
        if len(page) < PAGE_SIZE:
            return strings
        offset += len(page)


def fetch(url):
    return json.loads(urlopen(Request(url, method="GET")).read().decode())


def approve_english_translation(string_id, value):
    translation = request(
        "POST",
        f"{API_URL}/projects/{PROJECT_ID}/translations",
        {"stringId": string_id, "languageId": "en", "text": value},
    )
    request(
        "POST",
        f"{API_URL}/projects/{PROJECT_ID}/approvals",
        {"translationId": translation["data"]["id"]},
    )


def create_source_string(key, value):
    string = request(
        "POST",
        f"{API_URL}/projects/{PROJECT_ID}/strings",
        {"identifier": key, "text": value, "fileId": SOURCE_ID},
    )
    approve_english_translation(string["data"]["id"], value)


def update_source_string(string, value):
    string = request(
        "PATCH",
        f"{API_URL}/projects/{PROJECT_ID}/strings/{string['data']['id']}",
        [{"op": "replace", "path": "/text", "value": value}],
    )
    approve_english_translation(string["data"]["id"], value)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the source-string delta without changing Crowdin",
    )
    args = parser.parse_args(argv)

    current_arb = fetch(CURRENT_TRANSLATION_URL)
    with open(SOURCE_ARB_PATH, encoding="utf-8") as source_file:
        branch_arb = json.load(source_file)
    plan = build_sync_plan(current_arb, branch_arb)

    if args.dry_run:
        print(f"Translatable source strings: {len(source_strings(branch_arb))}")
        print(
            "Ignored ARB metadata entries: "
            f"{sum(key.startswith('@') for key in branch_arb)}"
        )
        print(f"Added: {len(plan.added)}")
        print(f"Updated: {len(plan.updated)}")
        print(f"Removed: {len(plan.removed)}")
        print(json.dumps(dry_run_payload(plan), indent=2, ensure_ascii=False))
        return 0

    if not os.getenv("CROWDIN_API"):
        raise RuntimeError("CROWDIN_API is required to update Crowdin")

    branch_translation = source_strings(branch_arb)
    strings = fetch_all_strings()
    strings_by_identifier = {
        string["data"]["identifier"]: string for string in strings
    }
    changed = plan.added.keys() | plan.updated.keys()

    for key, value in branch_translation.items():
        try:
            existing = strings_by_identifier.get(key)
            if existing is None:
                create_source_string(key, value)
            elif key in changed:
                update_source_string(existing, value)
        except urllib.error.HTTPError as error:
            print(error.reason)

    for key, string in strings_by_identifier.items():
        if key not in branch_translation:
            request(
                "DELETE",
                f"{API_URL}/projects/{PROJECT_ID}/strings/{string['data']['id']}",
                decode_data=False,
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
