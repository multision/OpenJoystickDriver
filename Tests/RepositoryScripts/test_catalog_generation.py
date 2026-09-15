from __future__ import annotations

import base64
import hashlib
import json
import unittest
import urllib.error
from email.message import Message
from unittest.mock import patch

from Scripts.Catalog import generate_controller_catalog as catalog


class CatalogGenerationTests(unittest.TestCase):
    def test_rate_limited_download_uses_authenticated_github_fallback(self) -> None:
        source = "static const int xpad_device[] = {0};\n"
        linux = {
            "repository": "torvalds/linux",
            "commit": "a" * 40,
            "files": {
                "xpad": {
                    "path": "drivers/input/joystick/xpad.c",
                    "sha256": hashlib.sha256(source.encode()).hexdigest(),
                }
            },
        }
        rate_limit = urllib.error.HTTPError(
            "https://raw.githubusercontent.com",
            429,
            "Too Many Requests",
            Message(),
            None,
        )
        response = json.dumps({"content": base64.b64encode(source.encode()).decode()})

        with (
            patch.object(catalog.urllib.request, "urlopen", side_effect=rate_limit),
            patch.object(catalog, "run_gh", return_value=response) as run_gh,
        ):
            files = catalog.load_locked_linux_files(linux)

        self.assertEqual(files, {"xpad": source})
        run_gh.assert_called_once_with(
            [
                "api",
                "-X",
                "GET",
                "repos/torvalds/linux/contents/drivers/input/joystick/xpad.c",
                "-f",
                f"ref={'a' * 40}",
            ],
            catalog.CatalogError,
        )
