#!/usr/bin/env python3
"""Exercise source-app routing and guard its UIKit/SwiftUI activation ownership."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def declaration(path: str, marker: str) -> str:
    source = (ROOT / path).read_text()
    start = source.index(marker)
    brace = source.index("{", start)
    end = brace + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


router_path = "Aether/Backend/Observable/SourcesRouter.swift"
collection_route = declaration(router_path, "enum CollectionRoute: Hashable")
route = declaration(router_path, "enum Route: Hashable")
locator = declaration(router_path, "struct AppLocator: Hashable")
open_app = declaration(router_path, "func openResolvedApp(")

cell_path = "Aether/Views/Sources/Apps/SourceAppsCellView.swift"
cell_source = (ROOT / cell_path).read_text()
selection_wrapper = declaration(cell_path, "private func _selectableContent<Content: View>")
assert ".accessibilityAction(.default)" in selection_wrapper, "App details lost VoiceOver activation"
table_branch = selection_wrapper.split("case .tableView:", 1)[1]
assert "Button(" not in table_branch, "Hosted SwiftUI button competes with UIKit row selection"
assert "DownloadButtonView" in cell_source, "Separate download control was removed"
assert "SourceAppBodyText.body" in cell_source, "Extended description was removed"

table_path = "Aether/Views/Sources/Apps/UIKit/SourceAppsTableRepresentableView.swift"
table_source = (ROOT / table_path).read_text()
did_select = declaration(table_path, "func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)")
assert "onSelect(" in did_select, "UITableView no longer owns touch navigation"
assert "selectionOwner: .tableView" in table_source
shutdown = declaration(table_path, "func shutdown(from tableView: UITableView)")
assert "_prepareTask?.cancel()" in shutdown and "_generation += 1" in shutdown
assert "_displayed = nil" in shutdown and "_previousDisplay = nil" in shutdown
assert "sourceContexts.removeAll" in shutdown and "onSelect = { _ in }" in shutdown
assert "!self._isShutdown, self.uiTableView === table,\n\t\t\t\t\tself._generation == generation" in table_source, \
    "A stale diffable-data-source completion can still modify a detached table"

overlay_path = "Aether/Views/Shared/SearchHeaderOverlay.swift"
overlay_source = (ROOT / overlay_path).read_text()
assert "private func firstSearchTextField" not in overlay_source, \
    "Search field cleanup must not depend on UIHostingConfiguration subviews"
assert "let searchFieldOwner = SearchTextFieldOwner()" in overlay_source
deactivate = declaration(overlay_path, "func deactivateAndDetach()")
teardown = declaration(overlay_path, "func tearDown()")
assert "searchFieldOwner.setScreenActive(false)" in deactivate
assert "searchFieldOwner.prepareForRemoval()" in teardown
report_frame = declaration(overlay_path, "func reportFrame()")
assert "publish(nil)" in report_frame, "Invalid window-frame measurements must clear stale anchors"
assert "sourceAnchor.windowID == barAnchor.windowID" in overlay_source

field_path = "Aether/Views/Shared/ToolbarSearchField.swift"
field_source = (ROOT / field_path).read_text()
assert "guard isScreenActive, window != nil else" in field_source
assert "self.isFirstResponder || self.hasKeyboardSession" in field_source
assert "transition?.isWaitingForKeyboard == true" in field_source

swift = f'''import Foundation
struct ASRepository {{ struct App: Hashable {{ let identifier: String }} }}
{collection_route}
{route}
{locator}
@MainActor final class RouterFixture {{
    var path: [Route] = []
    var pendingAppRequest: String? = "pending"
    {open_app}
}}
@MainActor func verifyRoutes() {{
    let router = RouterFixture()
    let parent = CollectionRoute.source(objectURI: "repo://one")
    let firstApp = AppLocator.locator(for: ASRepository.App(identifier: "com.example.first"))
    router.openResolvedApp(parent: parent, sourceObjectURI: "repo://one", appLocator: firstApp)
    let expected = router.path
    precondition(expected.count == 2, "Opening an app must produce parent + detail")

    router.pendingAppRequest = "duplicate request"
    router.openResolvedApp(parent: parent, sourceObjectURI: "repo://one", appLocator: firstApp)
    precondition(router.path == expected, "Opening the current detail route must not mutate the path")
    precondition(router.pendingAppRequest == nil, "Resolved requests must be cleared")

    let secondApp = AppLocator.locator(for: ASRepository.App(identifier: "com.example.second"))
    router.openResolvedApp(parent: parent, sourceObjectURI: "repo://one", appLocator: secondApp)
    precondition(router.path == [.collection(parent), .app(parent: parent, sourceObjectURI: "repo://one", appLocator: secondApp)],
        "A different app in the same repository must replace the detail route")

    let secondParent = CollectionRoute.source(objectURI: "repo://two")
    router.openResolvedApp(parent: secondParent, sourceObjectURI: "repo://two", appLocator: firstApp)
    precondition(router.path == [.collection(secondParent), .app(parent: secondParent, sourceObjectURI: "repo://two", appLocator: firstApp)],
        "Opening an app from another repository must replace the parent and detail routes")
}}
@main struct NavigationCheck {{
    @MainActor static func main() {{
        verifyRoutes()
        print("Navigation hardening checks passed")
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix="aether-navigation-check-") as temp:
    source = pathlib.Path(temp) / "navigation-check.swift"
    binary = pathlib.Path(temp) / "navigation-check"
    source.write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", "-o", str(binary), str(source)], check=True)
    subprocess.run([str(binary)], check=True)
