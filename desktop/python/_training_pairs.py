"""Deterministic specimen-group partitioning for image/_masks folders.

groups.json maps relative image filenames to specimen IDs. Legacy patient
prefixes such as OM-04-field1.tif remain recognized; arbitrary filenames do not
establish biological independence. No individual image is moved across groups.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re

_PATIENT = re.compile(r"^([A-Z]{2,4}-\d+)(?:[-_.]|$)", re.IGNORECASE)


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def group_split(pairs, directory):
    root = Path(directory).resolve()
    manifest = root / "groups.json"
    explicit = json.loads(manifest.read_text(encoding="utf-8")) if manifest.exists() else {}
    if not isinstance(explicit, dict) or any(
            not isinstance(key, str) or not isinstance(value, str) or not value.strip()
            for key, value in explicit.items()):
        raise ValueError("groups.json must map relative image filenames to non-empty specimen IDs")
    groups, hashes = {}, {}
    for image, mask in sorted(pairs, key=lambda pair: str(pair[0])):
        image, mask = Path(image), Path(mask)
        try:
            relative = image.resolve().relative_to(root).as_posix()
            mask.resolve().relative_to(root)
        except ValueError as exc:
            raise ValueError("Training images and masks must stay inside the selected dataset folder") from exc
        match = _PATIENT.match(image.stem)
        group = explicit.get(relative) or (match.group(1).upper() if match else None)
        if not group:
            raise ValueError(
                f"No specimen group for {relative}. Add groups.json mapping relative image "
                "filenames to specimen IDs, or use patient prefixes such as OM-04-field1.tif.")
        group = group.strip().casefold()
        digest = file_hash(image)
        if digest in hashes:
            raise ValueError(f"Duplicate image content: {relative} and {hashes[digest]}")
        hashes[digest] = relative
        groups.setdefault(group, []).append((image, mask))
    if len(groups) < 3:
        raise ValueError("Fine-tuning needs at least three independent specimen groups for train, validation and test")

    def order(group):
        return hashlib.sha256(group.encode("utf-8")).hexdigest()

    partitions = [[], [], []]
    for group in sorted(groups, key=order):
        bucket = int(order(group), 16) % 100
        partitions[0 if bucket < 70 else 1 if bucket < 90 else 2].append(group)
    # Rebalance only WHOLE specimen groups; even small datasets stay disjoint.
    for index in range(3):
        if not partitions[index]:
            donor = max(range(3), key=lambda i: (len(partitions[i]), -i))
            partitions[index].append(partitions[donor].pop())
    return tuple([pair for group in sorted(partition, key=order) for pair in groups[group]]
                 for partition in partitions)
