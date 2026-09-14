from __future__ import annotations

import unittest
from pathlib import Path


class InterfaceAssetPolicyTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[2]

    def test_interface_assets_do_not_include_svg_or_generated_raster_artwork(
        self,
    ) -> None:
        roots = (self.root / "Sources", self.root / "Resources")
        forbidden_suffixes = {".svg", ".png", ".jpg", ".jpeg", ".gif", ".tiff"}
        forbidden = sorted(
            path.relative_to(self.root)
            for root in roots
            if root.exists()
            for path in root.rglob("*")
            if path.is_file() and path.suffix.lower() in forbidden_suffixes
        )
        self.assertEqual(forbidden, [])

    def test_the_only_packaged_interface_image_is_the_application_icon(self) -> None:
        packaged_icons = sorted(
            path.relative_to(self.root)
            for path in (self.root / "Sources").rglob("*.icns")
        )
        self.assertEqual(
            packaged_icons,
            [Path("Sources/OpenJoystickDriver/Resources/OpenJoystickDriver.icns")],
        )


if __name__ == "__main__":
    unittest.main()
