import json
from pathlib import Path
import tempfile
import unittest

from _training_pairs import group_split


class GroupSplitTests(unittest.TestCase):
    def fixture(self, root, groups):
        pairs, mapping = [], {}
        for group, count in groups.items():
            for index in range(count):
                image = root / f"{group}-field{index}.tif"
                mask = root / f"{group}-field{index}_masks.tif"
                image.write_bytes(image.name.encode())
                mask.write_bytes(b"labels")
                pairs.append((image, mask))
                mapping[image.name] = group
        (root / "groups.json").write_text(json.dumps(mapping))
        return pairs, mapping

    def test_sparse_hash_buckets_move_whole_groups_and_are_order_independent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pairs, mapping = self.fixture(root, {"specimen-a": 7, "specimen-b": 5, "specimen-c": 4})
            splits = group_split(pairs, root)
            self.assertEqual(splits, group_split(list(reversed(pairs)), root))
            self.assertTrue(all(splits))
            seen = {}
            for index, split in enumerate(splits):
                for image, _ in split:
                    group = mapping[image.name]
                    self.assertEqual(seen.setdefault(group, index), index)
            self.assertEqual(sum(map(len, splits)), len(pairs))

    def test_multiple_fields_of_one_specimen_cannot_fill_three_splits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pairs, _ = self.fixture(root, {"one-specimen": 12})
            with self.assertRaisesRegex(ValueError, "three independent specimen groups"):
                group_split(pairs, root)

    def test_duplicate_content_rejected_even_under_different_groups(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pairs, _ = self.fixture(root, {"a": 1, "b": 1, "c": 1})
            pairs[1][0].write_bytes(pairs[0][0].read_bytes())
            with self.assertRaisesRegex(ValueError, "Duplicate image content"):
                group_split(pairs, root)

    def test_patient_prefixes_are_supported_but_arbitrary_names_need_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pairs, _ = self.fixture(root, {"OM-01": 2, "OM-02": 2, "OM-03": 2})
            (root / "groups.json").unlink()
            self.assertTrue(all(group_split(pairs, root)))
            bad = root / "field.tif"
            bad.write_bytes(b"another image")
            with self.assertRaisesRegex(ValueError, "Add groups.json"):
                group_split(pairs + [(bad, pairs[0][1])], root)


if __name__ == "__main__":
    unittest.main()
