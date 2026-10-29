#!/usr/bin/env python3
"""Regression checks for Aether's built-in update catalog and release feed."""

import json
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
manifest_path = repo / "app-repo.json"
manifest = json.loads(manifest_path.read_text())
manifest_app = manifest["apps"][0]
assert manifest_app["bundleIdentifier"] == "com.anfear.aether"
assert manifest_app["version"] == manifest_app["versions"][0]["version"]
assert manifest_app["downloadURL"].endswith(f"/v{manifest_app['version']}/Aether.ipa")
assert manifest_app["iconURL"].endswith("AetherPrimaryPreview.imageset/AetherPrimaryPreview.png")
assert len(manifest_app["versions"]) >= 2
assert all(entry.get("size", 0) > 0 for entry in manifest_app["versions"])

current_parts = list(map(int, manifest_app["version"].split(".")))
next_parts = current_parts[:-1] + [current_parts[-1] + 1]
next_version = ".".join(map(str, next_parts))

with tempfile.TemporaryDirectory(prefix="aether-app-repo-") as temp:
	work = pathlib.Path(temp)
	copy = work / "app-repo.json"
	copy.write_text(json.dumps(manifest))
	notes = work / "notes.md"
	notes.write_text("Aether 2.0.9 release notes")
	updater = repo / "scripts/update-app-repo.py"
	def update(version: str, url: str, size: int, note: str) -> None:
		notes.write_text(note)
		subprocess.run([
			"python3", str(updater), str(copy), "--version", version,
			"--date", "2026-10-26T12:00:00Z", "--download-url", url,
			"--size", str(size), "--notes-file", str(notes),
		], check=True)

	update(next_version, f"https://example.test/v{next_version}/Aether.ipa", 1234, f"Aether {next_version} release notes")
	data = json.loads(copy.read_text())
	app = data["apps"][0]
	assert app["version"] == next_version and app["downloadURL"].endswith(f"v{next_version}/Aether.ipa")
	assert [item["version"] for item in app["versions"][:2]] == [next_version, manifest_app["version"]]
	assert len([item for item in app["versions"] if item["version"] == next_version]) == 1

	# Re-uploading the same release replaces its metadata rather than duplicating it.
	update(next_version, f"https://example.test/v{next_version}/rebuilt.ipa", 5678, "Rebuilt release")
	data = json.loads(copy.read_text())
	app = data["apps"][0]
	assert app["version"] == next_version and app["size"] == 5678
	assert len([item for item in app["versions"] if item["version"] == next_version]) == 1

	# A rerun for an older tag may refresh history but cannot move current backward.
	update(manifest_app["version"], f"https://example.test/v{manifest_app['version']}/rebuilt.ipa", 9999, "Older rebuild")
	data = json.loads(copy.read_text())
	assert data["apps"][0]["version"] == next_version
	assert data["apps"][0]["versions"][0]["version"] == next_version

sources_view_model = (repo / "Aether/Views/Sources/SourcesViewModel.swift").read_text()
assert 'static let key = "builtin:aether"' in sources_view_model
assert 'https://raw.githubusercontent.com/a-artho/aether/main/app-repo.json' in sources_view_model
assert "private func _requests(for userRequests: [SourceRequest], refresh: Bool)" in sources_view_model
assert "if refresh || (builtInAetherSnapshot == nil && builtInRetryIsDue)" in sources_view_model
assert "private var _lastBuiltInAttempt: Date?" in sources_view_model
assert "_lastBuiltInAttempt = Date()" in sources_view_model
assert "builtInAetherSnapshot = snapshot" in sources_view_model
assert "Logger.misc.notice(\"Built-in Aether update feed unavailable" in sources_view_model
assert "refreshErrors[key] = error" in sources_view_model  # normal repository failures stay intact
assert "!userRequests.isEmpty && userRequests.allSatisfy" in sources_view_model
assert "!isRefreshRequested else { return }" in sources_view_model

updates_store = (repo / "Aether/Backend/Observable/LibraryUpdatesStore.swift").read_text()
assert "builtInAetherUpdateContext(" in updates_store and "installedBundleIdentifier: Bundle.main.bundleIdentifier" in updates_store
assert "userContexts.count == sources.count" in updates_store
assert "InstalledAppUpdateCatalog.shared.updates(" in updates_store

update_catalog = (repo / "Aether/Backend/Observable/InstalledAppUpdateCatalog.swift").read_text()
assert "aetherBundleIdentifiers.contains(identifier)" in update_catalog
assert "context.sourceObjectURI == AetherBuiltInRepository.key" in update_catalog
assert "preferredAether.version, than: installedVersion" in update_catalog
assert "Self.isNewer(app.currentVersion, than: installed)" in update_catalog

download_button = (repo / "Aether/Views/Sources/Apps/DownloadButtonView.swift").read_text()
assert "downloadManager.startDownload(" in download_button
for forbidden in ("startSigning", "startInstall", "SigningHandler", "FR.signPackageFile"):
	assert forbidden not in download_button

release_workflow = (repo / ".github/workflows/release.yml").read_text()
assert "release:\n    types: [published]" in release_workflow
assert "group: release-${{ github.ref }}" in release_workflow
assert "github.event_name == 'release'" in release_workflow
assert release_workflow.index("- name: Publish release") < release_workflow.index("- name: Update Aether app repository manifest")
assert "permissions:\n  contents: write" in release_workflow
assert "gh release view \"$TAG\" --json publishedAt" in release_workflow
assert "git -C \"$MANIFEST_WORKTREE\" push origin HEAD:main" in release_workflow
assert "for attempt in 1 2 3" in release_workflow
assert not (repo / ".github/workflows/update_repo.yml").exists()

print("Aether built-in update and release-manifest checks passed")

# Execute the production version selection and row label against mixed catalogs.
def declaration(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')

library_view = (repo / 'Aether/Views/Library/LibraryView.swift').read_text()
checks = r'''
import Foundation
struct App {var currentVersion:String?}
struct Repo {var apps:[App]}
struct SourceAppCatalogContext {var repository:Repo}
enum Catalog {
CATALOG
}
struct Installed {var version:String?;var build:String?}
struct Row {
 var app:Installed
 var latestAvailableVersion:String? = nil
ROW
}
func context(_ versions:[String?])->SourceAppCatalogContext {
 SourceAppCatalogContext(repository:Repo(apps:versions.map {App(currentVersion:$0)}))
}
let catalogs=[context(["2.9","2.10",nil,"invalid","2.10.0"]),context(["2.11","2.8","2.11"])]
precondition(Catalog.latestVersion(in:catalogs,newerThan:"2.9") == "2.11")
precondition(Catalog.latestVersion(in:[context(["2.9","2.10"])],newerThan:"2.8") == "2.10",
 "Version ordering must be numeric, not lexicographic")
precondition(Catalog.latestVersion(in:[context(["2.8","2.9","invalid",nil])],newerThan:"2.9") == nil)
precondition(Catalog.latestVersion(in:[],newerThan:"2.9") == nil)
precondition(Catalog.latestVersion(in:catalogs,newerThan:nil) == nil)
precondition(Row(app:Installed(version:"2.9",build:"100"),latestAvailableVersion:"2.11")._versionText == "2.9 → 2.11")
precondition(Row(app:Installed(version:"2.9",build:"100"))._versionText == "2.9",
 "All Apps rows preserve their installed-version presentation")
precondition(Row(app:Installed(version:nil,build:"100"))._versionText == "100")
print("Updates row checks passed: numeric latest across sources, invalid/empty catalogs and installed-to-latest label")
'''
methods = '\n'.join(declaration(update_catalog, marker) for marker in (
    'static func latestVersion(', 'static func isNewer(', 'private static func components('))
checks = checks.replace('CATALOG', methods).replace('ROW', declaration(library_view, 'private var _versionText:'))
with tempfile.TemporaryDirectory(prefix='aether-update-row-') as temporary:
    temporary = pathlib.Path(temporary)
    swift = temporary / 'Checks.swift'
    swift.write_text(checks)
    executable = temporary / 'checks'
    subprocess.run(['swiftc', '-swift-version', '6', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
