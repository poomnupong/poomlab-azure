import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/select-region-image.py"
SPEC = importlib.util.spec_from_file_location("region_image", SCRIPT)
images = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(images)


def image(name, date, region, blessed="true", state="Succeeded"):
    return {
        "id": f"/gallery/versions/{name}",
        "name": name,
        "tags": {"blessed": blessed},
        "provisioningState": state,
        "publishingProfile": {"publishedDate": date, "targetRegions": [{"name": region}]},
    }


class RegionImageTests(unittest.TestCase):
    def test_latest_blessed_image_must_be_ready_in_target_region(self):
        versions = [
            image("1.0.0", "2026-01-01T00:00:00Z", "West Europe"),
            image("2.0.0", "2026-02-01T00:00:00Z", "South Central US"),
            image("3.0.0", "2026-03-01T00:00:00Z", "West Europe", blessed="false"),
            image("4.0.0", "2026-04-01T00:00:00Z", "West Europe", state="Updating"),
        ]
        self.assertEqual(images.select_image(versions, "westeurope")["name"], "1.0.0")

    def test_new_region_defers_until_image_replication_exists(self):
        self.assertIsNone(images.select_image([
            image("1.0.0", "2026-01-01T00:00:00Z", "South Central US"),
        ], "westeurope"))

    def test_publication_dates_are_compared_as_instants(self):
        versions = [
            image("1.0.0", "2026-01-01T01:00:00+02:00", "West Europe"),
            image("2.0.0", "2026-01-01T00:00:00Z", "West Europe"),
        ]
        self.assertEqual(images.select_image(versions, "westeurope")["name"], "2.0.0")

    def test_invalid_metadata_fails_instead_of_becoming_pending(self):
        for value in ({}, [None], [{
            "tags": {"blessed": "true"}, "provisioningState": "Succeeded",
        }]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                images.select_image(value, "southcentralus")


if __name__ == "__main__":
    unittest.main()
