#!/usr/bin/env python3
"""Keep three published GitHub Releases, always including the current Latest.

Defaults to a dry run. Deletes release records and their assets, never Git tags.
Requires an authenticated GitHub CLI; --apply requires Contents write permission.
"""

import argparse
from datetime import datetime
import json
import re
import subprocess
import sys


KEEP = 3


def api(repository, endpoint='', *, method='GET', paginate=False):
    command = ['gh', 'api', '--hostname', 'github.com', '--method', method,
               f'repos/{repository}/releases{endpoint}']
    if paginate:
        command += ['--paginate', '--slurp']
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f'GitHub {method} failed: {result.stderr.strip()}')
    return json.loads(result.stdout) if method == 'GET' else None


def published_release(value):
    if (not isinstance(value, dict) or type(value.get('id')) is not int
            or value['id'] <= 0 or type(value.get('draft')) is not bool):
        raise ValueError('Invalid release identity or draft status')
    if value['draft']:
        return None
    tag = value.get('tag_name')
    if not isinstance(tag, str) or not tag.strip() or type(value.get('prerelease')) is not bool:
        raise ValueError('Invalid published release tag or prerelease status')
    timestamp = value.get('published_at')
    if not isinstance(timestamp, str):
        raise ValueError('Missing release publication time')
    published = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    if published.tzinfo is None:
        raise ValueError('Release publication time must include a timezone')
    return dict(id=value['id'], tag=tag, prerelease=value['prerelease'], published=published)


def snapshot(repository):
    pages = api(repository, '?per_page=100', paginate=True)
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise ValueError('Invalid paginated release response')
    releases = []
    for page in pages:
        for value in page:
            release = published_release(value)
            if release:
                releases.append(release)
    if (len({r['id'] for r in releases}) != len(releases)
            or len({r['tag'] for r in releases}) != len(releases)):
        raise ValueError('Duplicate releases; inventory may have changed during pagination')
    latest = None
    if any(not r['prerelease'] for r in releases):
        # A missing/failed Latest response is an error, never permission to delete it.
        latest = published_release(api(repository, '/latest'))
        if latest is None or latest['prerelease'] or latest not in releases:
            raise ValueError('Latest does not match the published stable releases; retry')
    return sorted(releases, key=lambda r: (r['published'], r['id']), reverse=True), latest


def retained_ids(releases, latest):
    keep = {latest['id']} if latest else set()
    for release in releases:
        if len(keep) == KEEP:
            break
        keep.add(release['id'])
    return keep


def prune(repository, *, apply=False):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Repository must be OWNER/REPO')
    releases, latest = snapshot(repository)
    keep = retained_ids(releases, latest)
    print('Keep: ' + (', '.join(r['tag'] for r in releases if r['id'] in keep) or '(none)'))
    if not apply:
        for candidate in reversed(releases):
            if candidate['id'] in keep:
                continue
            print(f'Would delete release and assets: {candidate["tag"]} (id {candidate["id"]})')
        print('Dry run; use --apply to delete old releases.')
        return
    while True:
        keep = retained_ids(releases, latest)
        # Oldest first. Re-read the complete inventory and Latest before every deletion.
        candidate = next((r for r in reversed(releases) if r['id'] not in keep), None)
        if candidate is None:
            print('Retained: ' + (', '.join(r['tag'] for r in releases) or '(none)'))
            return
        current, current_latest = snapshot(repository)
        release = next((r for r in current if r['id'] == candidate['id']), None)
        releases, latest = current, current_latest
        if release is None:
            continue
        if release != candidate:
            raise ValueError('Release metadata changed; stopping cleanup, retry with a fresh plan')
        if candidate['id'] in retained_ids(current, current_latest):
            print(f'Keep newly protected release: {candidate["tag"]}')
            continue
        api(repository, f'/{candidate["id"]}', method='DELETE')
        print(f'Deleted release and assets: {candidate["tag"]} (id {candidate["id"]})')
        releases = [r for r in current if r['id'] != candidate['id']]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, help='GitHub OWNER/REPO')
    parser.add_argument('--apply', action='store_true', help='Delete old releases and assets')
    args = parser.parse_args()
    try:
        prune(args.repo, apply=args.apply)
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f'Release cleanup stopped: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
