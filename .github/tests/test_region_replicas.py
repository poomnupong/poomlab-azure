import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/remove-region-replicas.py"
SPEC = importlib.util.spec_from_file_location("region_replicas", SCRIPT)
replicas = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replicas)


def version():
    return {
        "name": "20260912.1639.0",
        "location": "southcentralus",
        "provisioningState": "Succeeded",
        "tags": {"blessed": "true", "tier2": "passed"},
        "publishingProfile": {
            "targetRegions": [
                {"name": "South Central US", "regionalReplicaCount": 2, "storageAccountType": "Standard_ZRS"},
                {"name": "Southeast Asia", "regionalReplicaCount": 1, "storageAccountType": "Standard_LRS"},
                {"name": "West Europe", "regionalReplicaCount": 3, "storageAccountType": "Standard_LRS"},
            ],
            "excludeFromLatest": False,
        },
        "safetyProfile": {"allowDeletionOfReplicatedLocations": False, "blockDeletionBeforeEndOfLife": True},
    }


class PlanningTests(unittest.TestCase):
    def plan(self, versions):
        return replicas.plan_removal(versions, {"southeastasia"}, {"southcentralus"})

    def test_preserves_other_regions_metadata_and_source(self):
        original = version()
        snapshot = copy.deepcopy(original)
        plan = self.plan([original])[0]
        self.assertEqual(plan["regions"], [original["publishingProfile"]["targetRegions"][0],
                                           original["publishingProfile"]["targetRegions"][2]])
        self.assertTrue(plan["restore_protection"])
        self.assertEqual(original, snapshot)

    def test_existing_deletion_permission_is_retained(self):
        original = version()
        original["safetyProfile"]["allowDeletionOfReplicatedLocations"] = True
        self.assertFalse(self.plan([original])[0]["restore_protection"])

    def test_implicit_safety_default_is_restored(self):
        original = version()
        del original["safetyProfile"]
        self.assertTrue(self.plan([original])[0]["restore_protection"])

    def test_enabled_region_removal_rejected(self):
        with self.assertRaisesRegex(replicas.ReplicaError, "never enabled"):
            replicas.plan_removal([version()], {"southcentralus"}, {"southcentralus"})

    def test_source_region_removal_rejected_even_if_registry_changes(self):
        with self.assertRaisesRegex(replicas.ReplicaError, "source region"):
            replicas.plan_removal([version()], {"southcentralus"}, {"westus3"})

    def test_noop_when_replica_is_already_removed(self):
        original = version()
        original["publishingProfile"]["targetRegions"].pop(1)
        self.assertEqual(self.plan([original]), [])

    def test_incomplete_or_ambiguous_inventory_rejected_before_mutation(self):
        invalid = [None, {}, [None], [version(), version()]]
        for field, value in (("publishingProfile", None), ("provisioningState", "Failed"),
                             ("location", None), ("name", "../unsafe")):
            item = version()
            item[field] = value
            invalid.append([item])
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(replicas.ReplicaError):
                self.plan(value)

    def test_region_name_normalization_rejects_options_or_paths(self):
        self.assertEqual(replicas.normalize_location("Southeast Asia"), "southeastasia")
        for value in ("../region", "--all", "", None):
            with self.subTest(value=value), self.assertRaises(replicas.ReplicaError):
                replicas.normalize_location(value)


class MutationTests(unittest.TestCase):
    def setUp(self):
        self.plans = replicas.plan_removal([version()], {"southeastasia"}, {"southcentralus"})
        self.azure = Mock()

    def test_only_replica_list_and_temporary_safety_setting_are_updated(self):
        replicas.remove_replicas(self.azure, self.plans)
        self.assertEqual(self.azure.update.call_count, 2)
        name, settings = self.azure.update.call_args_list[0].args
        self.assertEqual(name, "20260912.1639.0")
        self.assertEqual(len(settings), 2)
        self.assertNotIn("Southeast Asia", settings[1])
        self.assertIn("Standard_ZRS", settings[1])
        self.azure.update.assert_called_with(name, ["safetyProfile.allowDeletionOfReplicatedLocations=false"])
        self.azure.wait.assert_called_with(self.plans, protection=True)

    def test_protection_restored_when_update_fails(self):
        self.azure.update.side_effect = [replicas.ReplicaError("update failed"), None]
        with self.assertRaisesRegex(replicas.ReplicaError, "update failed"):
            replicas.remove_replicas(self.azure, self.plans)
        self.assertEqual(self.azure.update.call_count, 2)

    def test_restore_errors_are_not_hidden_by_original_error(self):
        self.azure.update.side_effect = [
            replicas.ReplicaError("update failed"), replicas.ReplicaError("restore failed"),
        ]
        with self.assertRaisesRegex(replicas.ReplicaError, "update failed; restore failed"):
            replicas.remove_replicas(self.azure, self.plans)

    def test_preexisting_opt_in_is_not_overwritten(self):
        self.plans[0]["restore_protection"] = False
        replicas.remove_replicas(self.azure, self.plans)
        self.assertEqual(self.azure.update.call_count, 1)

    def test_explicit_subscription_forwarded_without_account_set(self):
        args = Mock(resource_group="rg", gallery_name="gallery", image_definition="image", subscription="sub")
        azure = replicas.Azure(args)
        with patch.object(replicas.subprocess, "run", return_value=Mock(returncode=0, stdout="[]")) as run:
            self.assertEqual(azure.versions(), [])
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--subscription") + 1], "sub")
        self.assertNotIn("account", command)

    def test_wait_requires_success_and_matching_targets(self):
        args = Mock(resource_group="rg", gallery_name="gallery", image_definition="image", subscription=None)
        azure = replicas.Azure(args)
        updated = version()
        updated["publishingProfile"]["targetRegions"] = self.plans[0]["regions"]
        with patch.object(azure, "versions", side_effect=[[version()], [updated]]), \
                patch.object(replicas.time, "sleep") as sleep:
            azure.wait(self.plans)
            sleep.assert_called_once_with(15)

    def test_wait_rejects_missing_or_failed_versions(self):
        args = Mock(resource_group="rg", gallery_name="gallery", image_definition="image", subscription=None)
        azure = replicas.Azure(args)
        failed = version()
        failed["provisioningState"] = "Failed"
        for inventory in ([], [failed], {}, [None]):
            with self.subTest(inventory=inventory), \
                    patch.object(azure, "versions", return_value=inventory), \
                    self.assertRaises(replicas.ReplicaError):
                azure.wait(self.plans)


if __name__ == "__main__":
    unittest.main()
