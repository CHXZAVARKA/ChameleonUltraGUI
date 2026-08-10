import importlib.util
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
from pathlib import Path
import unittest
from unittest import mock
import urllib.error


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
            self.assertIn(f"fileId={update_crowdin.SOURCE_ID}", url)
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

    def test_foreign_file_strings_are_rejected_by_mutation_helpers(self):
        foreign_string = {
            "data": {
                "id": 91,
                "fileId": update_crowdin.SOURCE_ID + 1,
                "identifier": "foreign_label",
            }
        }

        with mock.patch.object(update_crowdin, "request") as crowdin_request:
            with self.assertRaises(update_crowdin.CrowdinSyncError):
                update_crowdin.update_source_string(foreign_string, "Changed")
            with self.assertRaises(update_crowdin.CrowdinSyncError):
                update_crowdin.approve_english_translation(
                    foreign_string, "Changed"
                )
            with self.assertRaises(update_crowdin.CrowdinSyncError):
                update_crowdin.delete_source_string(foreign_string)

        crowdin_request.assert_not_called()

    def test_foreign_file_strings_returned_by_api_are_never_updated_or_deleted(self):
        branch_arb = {"shared_label": "Changed"}
        foreign_strings = [
            {
                "data": {
                    "id": 91,
                    "fileId": update_crowdin.SOURCE_ID + 1,
                    "identifier": "shared_label",
                }
            },
            {
                "data": {
                    "id": 92,
                    "fileId": update_crowdin.SOURCE_ID + 1,
                    "identifier": "foreign_only",
                }
            },
        ]

        with (
            mock.patch.object(
                update_crowdin, "fetch", return_value={"shared_label": "Old"}
            ),
            mock.patch(
                "builtins.open", mock.mock_open(read_data=json.dumps(branch_arb))
            ),
            mock.patch.dict("os.environ", {"CROWDIN_API": "test-token"}),
            mock.patch.object(
                update_crowdin, "fetch_all_strings", return_value=foreign_strings
            ),
            mock.patch.object(update_crowdin, "create_source_string") as create,
            mock.patch.object(update_crowdin, "update_source_string") as update,
            mock.patch.object(update_crowdin, "delete_source_string") as delete,
        ):
            result = update_crowdin.main([])

        self.assertEqual(result, 0)
        create.assert_called_once_with("shared_label", "Changed")
        update.assert_not_called()
        delete.assert_not_called()

    def test_create_update_and_approval_http_errors_stop_before_deletion(self):
        scenarios = {
            "create": ({"obsolete": "Old"}, {"new_label": "New"}),
            "update": (
                {"changed_label": "Old", "obsolete": "Old"},
                {"changed_label": "New"},
            ),
            "approval": ({"obsolete": "Old"}, {"new_label": "New"}),
        }

        for failing_stage, (current_arb, branch_arb) in scenarios.items():
            with self.subTest(failing_stage=failing_stage):
                strings = [
                    {
                        "data": {
                            "id": 1,
                            "fileId": update_crowdin.SOURCE_ID,
                            "identifier": "obsolete",
                        }
                    }
                ]
                if failing_stage == "update":
                    strings.append(
                        {
                            "data": {
                                "id": 2,
                                "fileId": update_crowdin.SOURCE_ID,
                                "identifier": "changed_label",
                            }
                        }
                    )
                requests = []

                def fake_request(method, url, data=None, decode_data=True):
                    requests.append((method, url))
                    if failing_stage == "create" and url.endswith("/strings"):
                        raise self._http_error()
                    if failing_stage == "update" and method == "PATCH":
                        raise self._http_error()
                    if failing_stage == "approval":
                        if url.endswith("/strings"):
                            return {
                                "data": {
                                    "id": 3,
                                    "fileId": update_crowdin.SOURCE_ID,
                                    "identifier": "new_label",
                                }
                            }
                        if url.endswith("/translations"):
                            return {"data": {"id": 4}}
                        if url.endswith("/approvals"):
                            raise self._http_error()
                    self.fail(f"Unexpected request: {method} {url}")

                error_output = StringIO()
                with (
                    mock.patch.object(
                        update_crowdin, "fetch", return_value=current_arb
                    ),
                    mock.patch(
                        "builtins.open",
                        mock.mock_open(read_data=json.dumps(branch_arb)),
                    ),
                    mock.patch.dict(
                        "os.environ", {"CROWDIN_API": "secret-test-token"}
                    ),
                    mock.patch.object(
                        update_crowdin, "fetch_all_strings", return_value=strings
                    ),
                    mock.patch.object(
                        update_crowdin, "request", side_effect=fake_request
                    ),
                    redirect_stdout(error_output),
                    redirect_stderr(error_output),
                ):
                    result = update_crowdin.main([])

                self.assertNotEqual(result, 0)
                self.assertFalse(
                    any(method == "DELETE" for method, _ in requests),
                    requests,
                )
                self.assertNotIn("secret-test-token", error_output.getvalue())
                expected_action = (
                    "updating" if failing_stage == "update" else "creating"
                )
                self.assertIn(expected_action, error_output.getvalue())

    @staticmethod
    def _http_error():
        return urllib.error.HTTPError(
            "https://api.crowdin.com/test",
            503,
            "Service Unavailable",
            hdrs=None,
            fp=None,
        )


if __name__ == "__main__":
    unittest.main()
