import importlib.util
from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
import unittest
from unittest import mock


SCRIPT_PATH = Path(__file__).parents[1] / "lib" / "l10n" / "updateCrowdin.py"
SPEC = importlib.util.spec_from_file_location("update_crowdin", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
update_crowdin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_crowdin)


class CrowdinSourceSyncTest(unittest.TestCase):
    def test_source_strings_exclude_arb_metadata(self):
        arb = {
            "@@locale": "en",
            "write_complete": "Complete: {count}",
            "@write_complete": {
                "description": "Completion message",
                "placeholders": {"count": {"type": "int"}},
            },
        }

        self.assertEqual(
            update_crowdin.source_strings(arb),
            {"write_complete": "Complete: {count}"},
        )

    def test_sync_plan_preserves_icu_and_placeholders_verbatim(self):
        icu = (
            "Complete: {count, plural, one {{count} block written and verified} "
            "other {{count} blocks written and verified}}."
        )
        branch_arb = {
            "@@locale": "en",
            "write_complete": icu,
            "@write_complete": {
                "placeholders": {"count": {"type": "int"}},
            },
        }

        plan = update_crowdin.build_sync_plan({}, branch_arb)

        self.assertEqual(plan.added, {"write_complete": icu})
        self.assertEqual(plan.updated, {})
        self.assertEqual(plan.removed, ())

    def test_all_crowdin_source_pages_are_loaded(self):
        first_page = [
            {"data": {"id": index, "identifier": f"key_{index}"}}
            for index in range(500)
        ]
        second_page = [
            {"data": {"id": 500, "identifier": "key_500"}},
            {"data": {"id": 501, "identifier": "key_501"}},
        ]

        def fake_request(method, url, data=None, decode_data=True):
            self.assertEqual(method, "GET")
            if "offset=500" in url:
                return {"data": second_page}
            return {"data": first_page}

        with mock.patch.object(update_crowdin, "request", side_effect=fake_request):
            strings = update_crowdin.fetch_all_strings()

        self.assertEqual(len(strings), 502)
        self.assertEqual(strings[-1]["data"]["identifier"], "key_501")

    def test_dry_run_reports_source_delta_without_calling_crowdin(self):
        branch_arb = {
            "@@locale": "en",
            "new_label": "New label",
            "@new_label": {"description": "A label"},
        }
        output = StringIO()

        with (
            mock.patch.object(update_crowdin, "fetch", return_value={}),
            mock.patch(
                "builtins.open", mock.mock_open(read_data=json.dumps(branch_arb))
            ),
            mock.patch.object(update_crowdin, "request") as crowdin_request,
            redirect_stdout(output),
        ):
            result = update_crowdin.main(["--dry-run"])

        self.assertEqual(result, 0)
        crowdin_request.assert_not_called()
        self.assertIn("Translatable source strings: 1", output.getvalue())
        self.assertIn("Ignored ARB metadata entries: 2", output.getvalue())
        self.assertIn("Added: 1", output.getvalue())


if __name__ == "__main__":
    unittest.main()
