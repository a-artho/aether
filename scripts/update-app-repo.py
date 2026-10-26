#!/usr/bin/env python3
"""Update the Aether AltStore manifest after a release has been published."""

import argparse
import json
import pathlib
import sys


def version_key(value: str) -> tuple[int, ...]:
	parts = value.split(".")
	if not parts or any(not part.isdigit() for part in parts):
		raise ValueError(f"Release version must contain only numeric dot-separated parts: {value}")
	return tuple(int(part) for part in parts)


def main() -> int:
	parser = argparse.ArgumentParser()
	parser.add_argument("manifest", type=pathlib.Path)
	parser.add_argument("--version", required=True)
	parser.add_argument("--date", required=True)
	parser.add_argument("--download-url", required=True)
	parser.add_argument("--size", required=True, type=int)
	parser.add_argument("--notes-file", required=True, type=pathlib.Path)
	args = parser.parse_args()

	manifest = json.loads(args.manifest.read_text())
	apps = manifest.get("apps")
	if not isinstance(apps, list):
		raise ValueError("AltStore manifest must contain an apps array")
	aether = next((app for app in apps if app.get("bundleIdentifier") == "com.anfear.aether"), None)
	if aether is None:
		raise ValueError("AltStore manifest does not contain Aether's canonical bundle identifier")

	notes = args.notes_file.read_text().strip()
	entry = {
		"version": args.version,
		"date": args.date,
		"downloadURL": args.download_url,
		"size": args.size,
		"localizedDescription": notes,
	}
	old_versions = aether.get("versions", [])
	if not isinstance(old_versions, list):
		raise ValueError("Aether version history must be an array")
	versions = [version for version in old_versions if version.get("version") != args.version]
	versions.append(entry)
	versions.sort(key=lambda item: (version_key(str(item.get("version", "0"))), str(item.get("date", ""))), reverse=True)

	latest = versions[0]
	aether["versions"] = versions
	aether["version"] = latest["version"]
	aether["versionDate"] = latest.get("date")
	aether["downloadURL"] = latest.get("downloadURL")
	aether["size"] = latest.get("size")
	aether["versionDescription"] = latest.get("localizedDescription", "")

	args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
	return 0


if __name__ == "__main__":
	try:
		sys.exit(main())
	except (OSError, ValueError, json.JSONDecodeError) as error:
		print(f"app-repo update failed: {error}", file=sys.stderr)
		sys.exit(1)
