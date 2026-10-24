"""Test production route, log retention, and audio lifecycle with platform doubles."""
import pathlib, sys
repo = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(sys.argv[1])
def declaration(path, start):
    text = (repo / path).read_text()
    p = text.index(start); b = text.index('{', p); e = b + 1; depth = 1
    while depth:
        depth += (text[e] == '{') - (text[e] == '}'); e += 1
    return text[p:e]
locator = declaration('Aether/Backend/Observable/SourcesRouter.swift', 'struct AppLocator:')
publish = declaration('Aether/Backend/Observable/DebugLogManager.swift', 'private func flushPendingEntries(').replace('private func', 'func', 1)
audio = declaration('Aether/Utilities/BackgroundAudioManager.swift', 'final class BackgroundAudioManager')
fixture = r'''
import Foundation
import XCTest
enum DiagnosticLog { static func error(_ message:String, category:String) {} }
struct ASRepository {
 struct App: Hashable {
  let uuid: UUID, id: String?, version: String, downloadURL: URL, description: String
 }
}
struct DebugLogItem { let id: UUID }
final class LogFixture {
 var entries = [DebugLogItem]()
 var pendingEntries = [DebugLogItem]()
 var publicationScheduled = false
 func _publish(_ item: DebugLogItem) { pendingEntries.append(item); flushPendingEntries() }
 var _publishedEntryIDs = Set<UUID>()
 let _maxPublishedCount = 1000
 PUBLISH
}
typealias OSStatus = Int32
let noErr: OSStatus = 0
struct AudioBufferList {}
struct AudioBuffer { let mData: UnsafeMutableRawPointer?; let mDataByteSize: UInt32 }
func UnsafeMutableAudioBufferListPointer(_ list: UnsafeMutablePointer<AudioBufferList>) -> [AudioBuffer] { [] }
final class AVAudioSourceNode {
 init(_ render: @escaping (Int, Int, Int, UnsafeMutablePointer<AudioBufferList>) -> OSStatus) {}
}
final class AVAudioSession {
 struct Options: OptionSet { let rawValue: Int; static let mixWithOthers = Options(rawValue:1); static let notifyOthersOnDeactivation = Options(rawValue:2) }
 enum Category { case playback }
 static let instance = AVAudioSession()
 static func sharedInstance() -> AVAudioSession { instance }
 var isActive = false
 var failActivation = false
 var failDeactivation = false
 func setCategory(_ category: Category, options: Options) throws {}
 func setActive(_ active: Bool, options: Options = []) throws {
  if active && failActivation { throw NSError(domain:"activation",code:1) }
  if !active && failDeactivation { throw NSError(domain:"deactivation",code:1) }
  isActive = active
 }
}
final class AVAudioEngine {
 static var failStart = false
 static var nodeCount = 0
 var isRunning = false
 let mainMixerNode = 0
 func attach(_ node: AVAudioSourceNode) { Self.nodeCount += 1 }
 func connect(_ node: AVAudioSourceNode, to mixer: Int, format: Int?) {}
 func start() throws { if Self.failStart { throw NSError(domain:"engine",code:1) }; isRunning = true }
 func stop() { isRunning = false }
 func disconnectNodeOutput(_ node: AVAudioSourceNode) {}
 func detach(_ node: AVAudioSourceNode) { Self.nodeCount -= 1 }
}
struct Transaction { var disablesAnimations = false }
func withTransaction(_ transaction: Transaction, _ body: () -> Void) { body() }
final class AuditFixTests: XCTestCase {
 override func setUp() {
  BackgroundAudioManager.shared.stopAll()
  AVAudioEngine.failStart = false
  AVAudioSession.instance.failActivation = false
  AVAudioSession.instance.failDeactivation = false
 }
 override func tearDown() { BackgroundAudioManager.shared.stopAll() }
 func testVariantWithSharedBundleAndVersionKeepsExactSelectedEntry() {
  let url = URL(string:"https://example.com/app.ipa")!
  let first = ASRepository.App(uuid:UUID(),id:"com.example.app",version:"1.0",downloadURL:url,description:"Variant A")
  let second = ASRepository.App(uuid:UUID(),id:first.id,version:first.version,downloadURL:url,description:"Variant B")
  let route = AppLocator.locator(for:second)
  XCTAssertEqual(route.app, second)
  XCTAssertNotEqual(route.app, first)
  XCTAssertNotEqual(route, AppLocator.locator(for:first))
 }
 func testMissingBundleIDStillPreservesSelectedVariant() {
  let app = ASRepository.App(uuid:UUID(),id:nil,version:"2.0",downloadURL:URL(string:"https://example.com/b.ipa")!,description:"Variant")
  XCTAssertEqual(AppLocator.locator(for:app).app,app)
 }
 func testPublishedLogsStayBoundedAndNewestFirst() {
  let logs = LogFixture()
  let items = (0..<1500).map { _ in DebugLogItem(id:UUID()) }
  for item in items { logs._publish(item) }
  XCTAssertEqual(logs.entries.count,1000)
  XCTAssertEqual(logs._publishedEntryIDs.count,1000)
  XCTAssertEqual(logs.entries.map(\.id),items.suffix(1000).reversed().map(\.id))
  logs._publish(items.last!)
  XCTAssertEqual(logs.entries.count,1000)
  XCTAssertEqual(logs.entries.first?.id,items.last!.id)
 }
 func testBatchedLogPublicationDeduplicatesAndKeepsNewest() {
  let logs = LogFixture()
  let items = (0..<1500).map { _ in DebugLogItem(id:UUID()) }
  logs.pendingEntries = items + [items.last!]
  logs.flushPendingEntries()
  XCTAssertEqual(logs.entries.count,1000)
  XCTAssertEqual(logs.entries.first?.id,items.last!.id)
  XCTAssertTrue(logs.pendingEntries.isEmpty)
 }
 func testFailedAudioStartupDetachesNodeAndDeactivatesSession() {
  AVAudioEngine.failStart = true
  BackgroundAudioManager.shared.start("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertFalse(AVAudioSession.instance.isActive)
  AVAudioEngine.failStart = false
  BackgroundAudioManager.shared.start("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,1)
  XCTAssertTrue(AVAudioSession.instance.isActive)
  BackgroundAudioManager.shared.stop("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertFalse(AVAudioSession.instance.isActive)
 }
 func testAudioActivationFailureAndRepeatedStopAreClean() {
  AVAudioSession.instance.failActivation = true
  BackgroundAudioManager.shared.start("server")
  BackgroundAudioManager.shared.stop("server")
  BackgroundAudioManager.shared.stopAll()
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertFalse(AVAudioSession.instance.isActive)
 }
 func testAudioDeactivationFailureCanBeRetriedWithoutLeakingNode() {
  BackgroundAudioManager.shared.start("server")
  AVAudioSession.instance.failDeactivation = true
  BackgroundAudioManager.shared.stop("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertTrue(AVAudioSession.instance.isActive)
  AVAudioSession.instance.failDeactivation = false
  BackgroundAudioManager.shared.stopAll()
  XCTAssertFalse(AVAudioSession.instance.isActive)
 }
 func testAudioStaysActiveUntilLastRequesterStops() {
  BackgroundAudioManager.shared.start("first")
  BackgroundAudioManager.shared.start("second")
  XCTAssertEqual(AVAudioEngine.nodeCount,1)
  BackgroundAudioManager.shared.stop("first")
  XCTAssertTrue(AVAudioSession.instance.isActive)
  BackgroundAudioManager.shared.stop("second")
  XCTAssertFalse(AVAudioSession.instance.isActive)
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
 }
}
'''.replace(' PUBLISH',publish)
route = declaration('Aether/Views/Installed/AllInstalledAppsView.swift', 'enum InstalledAppsRoute:')
delete = declaration('Aether/Views/Installed/AllInstalledAppsView.swift', 'private func delete(').replace('private func', 'func', 1).replace('DebugLogManager', 'AuditDebugLogManager')
delete_checks = r'''
struct InstalledApp { let bundleIdentifier:String; var id:String { bundleIdentifier } }
@MainActor final class DeleteStore {
 var apps=[InstalledApp(bundleIdentifier:"installed.fixture")]
 var shouldFail=false
 var calls=0
 func delete(app:InstalledApp) async throws {
  calls += 1
  if shouldFail { throw NSError(domain:"uninstall",code:1) }
  apps.removeAll { $0.id == app.id }
 }
}
@MainActor final class AuditDebugLogManager {
 enum Level { case error }
 static let shared=AuditDebugLogManager()
 func log(_ message:String, category:String, level:Level) {}
}
@MainActor final class DeleteFixture {
 let store=DeleteStore()
 var deletingIDs=Set<String>()
 var deletionError:String?
 DELETE
}
final class InstalledRowDeletionTests:XCTestCase {
 @MainActor func testSuccessfulUninstallRemovesAppAndReleasesBusyState() async {
  let view=DeleteFixture(), app=InstalledApp(bundleIdentifier:"installed.fixture")
  await view.delete(app)
  XCTAssertTrue(view.store.apps.isEmpty)
  XCTAssertTrue(view.deletingIDs.isEmpty)
  XCTAssertNil(view.deletionError)
 }
 @MainActor func testFailedUninstallKeepsAppAndAllowsRetry() async {
  let view=DeleteFixture(), app=InstalledApp(bundleIdentifier:"installed.fixture")
  view.store.shouldFail=true
  await view.delete(app)
  XCTAssertEqual(view.store.apps.map(\.id),[app.id])
  XCTAssertTrue(view.deletingIDs.isEmpty)
  XCTAssertNotNil(view.deletionError)
 }
 @MainActor func testInFlightUninstallCannotBeStartedTwice() async {
  let view=DeleteFixture(), app=InstalledApp(bundleIdentifier:"installed.fixture")
  view.deletingIDs.insert(app.id)
  await view.delete(app)
  XCTAssertEqual(view.store.calls,0)
  XCTAssertEqual(view.store.apps.map(\.id),[app.id])
 }
}
'''.replace(' DELETE',delete)
open_settings = declaration('Aether/Backend/Observable/AppTabManager.swift', 'func openSettings(')
settings_page = declaration('Aether/Backend/Observable/AppTabManager.swift', 'enum SettingsPage:')
open_search = declaration('Aether/Backend/Observable/AppTabManager.swift', 'func openSearch()')
consume_settings = declaration('Aether/Views/Settings/SettingsView.swift', 'private func _presentRequestedPageIfNeeded()').replace('private func', 'func', 1)
tab_list = declaration('Aether/Views/TabView/TabEnum.swift', 'static var defaultTabs:')
settings_checks = r'''
extension String { fileprivate static func localized(_ key:String)->String {key} }
enum TabEnum {case sources,library,settings; TAB_LIST }
@MainActor final class SourcesRouter {
 static let shared=SourcesRouter()
 enum Target {case root}
 var path=[String]();var searchTarget=Target.root
 func openSearchForVisibleScreen(){}
}
@MainActor final class SettingsRoutingFixture {
 SETTINGS_PAGE
 var requestedSettingsPage:SettingsPage?
 var selectedTab=TabEnum.library
 var isSettingsSearchPresented=false
 var isLibrarySearchPresented=false
 func switchTo(_ tab:TabEnum) {selectedTab=tab}
 OPEN_SEARCH
 OPEN_SETTINGS
}
@MainActor final class SettingsOwnerFixture {
 let _tabManager=SettingsRoutingFixture()
 var _settingsPath=[SettingsRoutingFixture.SettingsPage]()
 var isSpoofingPresented=false
 var searchFocused=false
 CONSUME_SETTINGS
}
final class SettingsRoutingTests:XCTestCase {
 func testSettingsIsAlwaysThirdTab() {
  XCTAssertEqual(TabEnum.defaultTabs,[.sources,.library,.settings])
 }
 @MainActor func testSettingsOpensRequestedPageInTab() async {
  let routing=SettingsRoutingFixture()
  routing.openSettings(page:.tunnel)
  XCTAssertEqual(routing.selectedTab,.settings)
  XCTAssertEqual(routing.requestedSettingsPage,.tunnel)
 }
 @MainActor func testOpeningSettingsWithoutPageRequestsRoot() async {
  let routing=SettingsRoutingFixture();routing.openSettings()
  XCTAssertEqual(routing.requestedSettingsPage,.root)
 }
 @MainActor func testSearchFromNestedSettingsRoutesToRootAndFocuses() async {
  let view=SettingsOwnerFixture();view._tabManager.selectedTab = .settings
  view._settingsPath=[.appearance];view._tabManager.openSearch()
  view._presentRequestedPageIfNeeded()
  XCTAssertTrue(view._settingsPath.isEmpty);XCTAssertTrue(view.searchFocused)
 }
 @MainActor func testSpoofingRequestOpensControlsFromSettingsRoot() async {
  let view=SettingsOwnerFixture();view._tabManager.openSettings(page:.spoofing)
  view._presentRequestedPageIfNeeded()
  XCTAssertTrue(view.isSpoofingPresented);XCTAssertTrue(view._settingsPath.isEmpty)
  XCTAssertNil(view._tabManager.requestedSettingsPage)
 }
 @MainActor func testInactiveSettingsTabWaitsUntilSelected() async {
  let view=SettingsOwnerFixture();view._tabManager.requestedSettingsPage = .tunnel
  view._presentRequestedPageIfNeeded()
  XCTAssertEqual(view._tabManager.requestedSettingsPage,.tunnel)
  view._tabManager.selectedTab = .settings;view._presentRequestedPageIfNeeded()
  XCTAssertEqual(view._settingsPath,[.tunnel])
 }
}
'''.replace(' SETTINGS_PAGE',settings_page).replace(' OPEN_SEARCH',open_search).replace(' OPEN_SETTINGS',open_settings).replace(' CONSUME_SETTINGS',consume_settings).replace(' TAB_LIST',tab_list)
(out/'AuditFixTests.swift').write_text((fixture+'\n'+locator+'\n'+audio+'\n'+route+'\n'+delete_checks+'\n'+settings_checks+'\n').replace('.localized(', '.auditLocalized(').replace('static func localized(', 'static func auditLocalized('))
