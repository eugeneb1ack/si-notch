"""Exercise destructive retention without contacting GitHub or deleting real releases."""

import contextlib
import copy
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'release_retention', Path(__file__).resolve().parents[2] / 'scripts/prune-releases.py')
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


def release(number, **changes):
    return dict(id=number, tag_name=f'v{number}', draft=False, prerelease=False,
                published_at=f'2026-10-24T12:{number // 60:02}:{number % 60:02}Z', **changes)


class GitHub:
    def __init__(self, releases, latest=None):
        self.releases = copy.deepcopy(releases)
        self.latest = latest
        self.deleted = []
        self.calls = []
        self.before_list = None

    def api(self, repository, endpoint='', *, method='GET', paginate=False):
        self.calls.append((repository, endpoint, method, paginate))
        if method == 'GET' and endpoint == '?per_page=100':
            if self.before_list:
                self.before_list(self)
            return copy.deepcopy([self.releases[i:i + 100]
                                  for i in range(0, len(self.releases), 100)] or [[]])
        if method == 'GET' and endpoint == '/latest':
            return copy.deepcopy(next(r for r in self.releases if r['id'] == self.latest))
        if method == 'DELETE':
            identity = int(endpoint[1:])
            self.deleted.append(identity)
            self.releases = [r for r in self.releases if r['id'] != identity]
            return None
        raise AssertionError(f'Unexpected request: {endpoint} {method}')


class ReleaseRetentionTests(unittest.TestCase):
    def run_prune(self, github, *, apply=True):
        with patch.object(retention, 'api', side_effect=github.api), contextlib.redirect_stdout(io.StringIO()):
            retention.prune('owner/repo', apply=apply)

    def test_newest_three_by_publication_not_api_order_or_tag(self):
        github = GitHub([release(n) for n in (1, 5, 2, 4, 3)], latest=5)
        self.run_prune(github)
        self.assertEqual(github.deleted, [1, 2])
        self.assertEqual({r['id'] for r in github.releases}, {3, 4, 5})
        self.assertTrue(all(c[1] in ('?per_page=100', '/latest', '/1', '/2') for c in github.calls))

    def test_all_pages_are_counted(self):
        github = GitHub([release(n) for n in range(1, 104)], latest=103)
        self.run_prune(github)
        self.assertEqual(github.deleted, list(range(1, 101)))
        self.assertEqual({r['id'] for r in github.releases}, {101, 102, 103})

    def test_latest_reserves_a_slot_even_after_several_betas(self):
        releases = [release(n) for n in range(1, 7)]
        for item in releases[2:]:
            item['prerelease'] = True
        github = GitHub(releases, latest=2)
        self.run_prune(github)
        self.assertEqual({r['id'] for r in github.releases}, {2, 5, 6})
        self.assertNotIn(2, github.deleted)

    def test_drafts_do_not_count_or_get_deleted(self):
        draft = release(5)
        draft.update(draft=True, published_at=None)
        github = GitHub([release(n) for n in range(1, 5)] + [draft], latest=4)
        self.run_prune(github)
        self.assertEqual(github.deleted, [1])
        self.assertEqual({r['id'] for r in github.releases}, {2, 3, 4, 5})

    def test_zero_to_three_releases_are_unchanged_and_repeat_is_idempotent(self):
        for count in range(4):
            with self.subTest(count=count):
                github = GitHub([release(n) for n in range(1, count + 1)], latest=count or None)
                self.run_prune(github)
                self.run_prune(github)
                self.assertEqual(github.deleted, [])
        github = GitHub([release(n) for n in range(1, 6)], latest=5)
        self.run_prune(github)
        self.run_prune(github)
        self.assertEqual(github.deleted, [1, 2])

    def test_prerelease_only_repository_does_not_require_latest(self):
        releases = [release(n) for n in range(1, 6)]
        for item in releases:
            item['prerelease'] = True
        github = GitHub(releases)
        self.run_prune(github)
        self.assertEqual(github.deleted, [1, 2])
        self.assertFalse(any(c[1] == '/latest' for c in github.calls))

    def test_default_is_dry_run(self):
        github = GitHub([release(n) for n in range(1, 6)], latest=5)
        with patch.object(retention, 'api', side_effect=github.api), \
                patch('sys.argv', ['prune-releases.py', '--repo', 'owner/repo']), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(retention.main(), 0)
        self.assertIn('Would delete release and assets: v1', output.getvalue())
        self.assertIn('Dry run', output.getvalue())
        self.assertEqual(github.deleted, [])

    def test_latest_reassignment_during_cleanup_protects_it(self):
        github = GitHub([release(n) for n in range(1, 6)], latest=5)
        lists = 0

        def change_latest(client):
            nonlocal lists
            lists += 1
            if lists == 2:
                client.latest = 1

        github.before_list = change_latest
        self.run_prune(github)
        self.assertEqual(github.deleted, [2, 3])
        self.assertEqual({r['id'] for r in github.releases}, {1, 4, 5})
        self.assertNotIn(1, github.deleted)

    def test_release_published_during_cleanup_is_never_a_deletion_candidate(self):
        github = GitHub([release(n) for n in range(1, 5)], latest=4)
        lists = 0

        def publish(client):
            nonlocal lists
            lists += 1
            if lists == 2:
                client.releases.append(release(5))
                client.latest = 5

        github.before_list = publish
        self.run_prune(github)
        self.assertEqual(github.deleted, [1, 2])
        # A queued release event can repeat the same cleanup safely.
        self.run_prune(github)
        self.assertEqual({r['id'] for r in github.releases}, {3, 4, 5})

    def test_metadata_change_aborts_before_delete(self):
        github = GitHub([release(n) for n in range(1, 5)], latest=4)
        lists = 0

        def change_tag(client):
            nonlocal lists
            lists += 1
            if lists == 2:
                client.releases[0]['tag_name'] = 'replacement'

        github.before_list = change_tag
        with self.assertRaisesRegex(ValueError, 'metadata changed'):
            self.run_prune(github)
        self.assertEqual(github.deleted, [])

    def test_missing_or_inconsistent_latest_fails_closed(self):
        for latest in (None, release(99), dict(release(4), prerelease=True), dict(release(4), draft=True)):
            github = GitHub([release(n) for n in range(1, 5)], latest=4)
            original = github.api

            def api(repository, endpoint='', **kwargs):
                if endpoint == '/latest':
                    if latest is None:
                        raise RuntimeError('GitHub GET failed: HTTP 404')
                    return latest
                return original(repository, endpoint, **kwargs)

            with self.subTest(latest=latest), patch.object(github, 'api', side_effect=api):
                with self.assertRaises((ValueError, RuntimeError)):
                    self.run_prune(github)
                self.assertEqual(github.deleted, [])

    def test_invalid_metadata_fails_before_any_delete(self):
        for changes in ({'published_at': None}, {'published_at': 'invalid'},
                        {'published_at': '2026-10-24T12:00:00'}, {'id': True},
                        {'draft': None}, {'prerelease': None}, {'tag_name': ''}):
            releases = [release(n) for n in range(1, 5)]
            releases[0].update(changes)
            github = GitHub(releases, latest=4)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.run_prune(github)
            self.assertEqual(github.deleted, [])

    def test_duplicate_inventory_fails_before_any_delete(self):
        github = GitHub([release(1), release(1), release(2), release(3), release(4)], latest=4)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.run_prune(github)
        self.assertEqual(github.deleted, [])

    def test_invalid_page_or_api_failure_fails_closed(self):
        for response in ({'message': 'not a list'}, [[], {'message': 'partial failure'}]):
            with patch.object(retention, 'api', return_value=response) as api:
                with self.assertRaises(ValueError):
                    retention.prune('owner/repo', apply=True)
                api.assert_called_once()
        with patch.object(retention, 'api', side_effect=RuntimeError('HTTP 403')) as api:
            with self.assertRaises(RuntimeError):
                retention.prune('owner/repo', apply=True)
            api.assert_called_once()

    def test_failed_delete_stops_without_trying_another_release(self):
        github = GitHub([release(n) for n in range(1, 6)], latest=5)
        original = github.api

        def api(repository, endpoint='', **kwargs):
            if kwargs.get('method') == 'DELETE':
                raise RuntimeError('HTTP 403')
            return original(repository, endpoint, **kwargs)

        with patch.object(github, 'api', side_effect=api), self.assertRaises(RuntimeError):
            self.run_prune(github)
        self.assertEqual(github.deleted, [])

    def test_github_cli_paginates_and_uses_numeric_release_endpoint_only(self):
        with patch.object(retention.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, stdout='[[], []]')) as run:
            self.assertEqual(retention.api('owner/repo', '?per_page=100', paginate=True), [[], []])
            self.assertIn('--paginate', run.call_args.args[0])
            self.assertIn('--slurp', run.call_args.args[0])
        with patch.object(retention.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, stdout='')) as run:
            retention.api('owner/repo', '/123', method='DELETE')
            self.assertEqual(run.call_args.args[0][-1], 'repos/owner/repo/releases/123')
            self.assertIn('DELETE', run.call_args.args[0])

    def test_github_cli_errors_and_malformed_json_are_not_empty_inventory(self):
        for code, stdout in ((1, '[]'), (0, 'invalid JSON')):
            with self.subTest(code=code), patch.object(retention.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], code, stdout=stdout, stderr='HTTP 500')):
                with self.assertRaises((ValueError, RuntimeError)):
                    retention.api('owner/repo', '?per_page=100', paginate=True)


if __name__ == '__main__':
    unittest.main()
