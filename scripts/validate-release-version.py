#!/usr/bin/env python3
"""The stable release channel requires increasing numeric x.y.z versions."""
import re
import sys


def validate(version, build, previous):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('Stable releases require x.y.z without a prerelease suffix')
    if build != version:
        raise ValueError('CFBundleVersion must match the stable release version')
    previous = previous.removeprefix('v')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', previous):
        raise ValueError('Cannot verify the previous stable release version')
    if tuple(map(int, version.split('.'))) <= tuple(map(int, previous.split('.'))):
        raise ValueError('Release version must be newer than the latest published release')


if __name__ == '__main__':
    validate(*sys.argv[1:])
    print('OK: monotonically increasing stable release version')
