#!/usr/bin/env python3
"""Exercise production search state, anchor/focus ownership and appearance change gates."""
from pathlib import Path
import subprocess, tempfile
repo=Path(__file__).resolve().parents[2]
field=(repo/'Aether/Views/Shared/ToolbarSearchField.swift').read_text()
overlay=(repo/'Aether/Views/Shared/SearchHeaderOverlay.swift').read_text()
def declaration(source,marker):
 a=source.index(marker);b=source.index('{',a)+1;depth=1
 while depth:
  depth+=(source[b]=='{')-(source[b]=='}');b+=1
 return source[a:b].replace('private ', '')
transition=declaration(field,'final class SearchToolbarTransition:')
owner=declaration(field,'final class SearchTextFieldOwner {')
text_field=field[field.index('final class SearchTextField:'):]
publish=declaration(text_field,'private func publishFocus()')
active=declaration(text_field,'func setScreenActive(')
frame_publish=declaration(overlay,'private func publish(_ anchor:')
measurement=declaration(overlay,'func updateMeasurementID(')
s=r'''
import Foundation
import SwiftUI
import Combine
@MainActor enum UIAccessibility {static var isReduceMotionEnabled=false}
@MainActor
TRANSITION
final class Window {}
@MainActor
OWNER
@MainActor final class SearchTextField {
 var isFirstResponder=false;var isScreenActive=false;var hasKeyboardSession=false;var focusGeneration=0
 weak var fieldOwner:SearchTextFieldOwner?
 var focusChanged:((Bool)->Void)?
 var window:Window?=Window()
 @discardableResult func resignFirstResponder()->Bool {isFirstResponder=false;return true}
 func updateKeyboardObserver(){}
 func prepareForRemoval(){setScreenActive(false);fieldOwner?.unregister(self);fieldOwner=nil;focusChanged=nil}
 ACTIVE
 PUBLISH
}
struct WindowFrameAnchor:Equatable {let frame:CGRect;let windowID:ObjectIdentifier}
@MainActor final class Reporter {
 var lastAnchor:WindowFrameAnchor?;var generation=0;var measurementID:String?
 var window:Window?=Window();var onChange:((WindowFrameAnchor?)->Void)?
 MEASUREMENT
 FRAME_PUBLISH
}
@main struct Checks {
 @MainActor static func drain() async {for _ in 0..<100 {await Task.yield()}}
 @MainActor static func main() async throws {
  let closing=SearchToolbarTransition();closing.restore(isPresented:true)
  var query="anki";closing.setPresented(false,keyboardExpected:true);closing.afterCollapse{query=""}
  closing.cancelPendingKeyboardTransition();closing.restore(isPresented:false)
  try await Task.sleep(for:.milliseconds(150))
  precondition(query.isEmpty && !closing.expanded,"Navigation must finish cleanup for a search that was already closing")
  let restored=SearchToolbarTransition();restored.restore(isPresented:true)
  query="anki";restored.setPresented(false);restored.afterCollapse{query=""};restored.restore(isPresented:false)
  precondition(query.isEmpty,"Restore cannot discard pending closed-search cleanup")
  let retained=SearchToolbarTransition();retained.restore(isPresented:true);query="anki"
  retained.cancelPendingKeyboardTransition();retained.restore(isPresented:true)
  precondition(retained.expanded && query=="anki","Opening details retains the parent's open search and query")
  retained.setPresented(false);retained.afterCollapse{query=""};retained.setPresented(true);retained.restore(isPresented:true)
  precondition(query=="anki","Rapid reopening invalidates an older collapse cleanup")
  let late=SearchToolbarTransition();late.setPresented(true);late.keyboardWillChange(duration:0.25,curve:0)
  late.cancelPendingKeyboardTransition();late.restore(isPresented:false);await drain()
  precondition(!late.expanded,"An old queued keyboard callback cannot reopen search after navigation")
  let hardware=SearchToolbarTransition();hardware.setPresented(true)
  try await Task.sleep(for:.milliseconds(150));precondition(hardware.expanded,"Hardware keyboard fallback still expands search")
  UIAccessibility.isReduceMotionEnabled=true
  let reduced=SearchToolbarTransition();reduced.setPresented(true)
  try await Task.sleep(for:.milliseconds(150));precondition(reduced.expanded && reduced.animation == nil)
  UIAccessibility.isReduceMotionEnabled=false

  let field=SearchTextField(),owner=SearchTextFieldOwner();owner.register(field)
  var focused=false;field.focusChanged={focused=$0};field.isFirstResponder=true;field.publishFocus();await drain()
  precondition(focused,"Active field focus updates remain functional")
  field.isFirstResponder=false;field.publishFocus();owner.setScreenActive(false);focused=true;await drain()
  precondition(focused,"An inactive field cannot overwrite destination focus")
  owner.setScreenActive(true);field.publishFocus();field.setScreenActive(false);field.setScreenActive(true);focused=true;await drain()
  precondition(focused,"Callbacks cannot cross a deactivate/reactivate generation")
  field.publishFocus();let replacement=SearchTextField();owner.register(replacement);focused=true;await drain()
  precondition(focused && !field.isScreenActive && owner.owns(replacement),"Replacing a field retires the old focus owner")
  var replacementFocus=true;replacement.focusChanged={replacementFocus=$0};replacement.isFirstResponder=false
  replacement.publishFocus();await drain();precondition(!replacementFocus,"Keyboard dismissal on the current field still publishes")
  replacement.publishFocus();replacement.window=Window();replacementFocus=true;await drain()
  precondition(replacementFocus,"A queued callback cannot cross windows")

  let reporter=Reporter();var anchor:WindowFrameAnchor?;var reports=0
  reporter.onChange={anchor=$0;reports+=1}
  let frame=WindowFrameAnchor(frame:CGRect(x:280,y:60,width:44,height:44),windowID:ObjectIdentifier(reporter.window!))
  let configurations=["right|left","right|center","right|hidden","pageTitle|left","pageTitle|center"]
  for configuration in configurations {
   anchor=nil;reporter.updateMeasurementID(configuration);reporter.publish(frame);await drain()
   precondition(anchor==frame,"An unchanged frame must repopulate a parent anchor after a configuration change")
   let count=reports;reporter.updateMeasurementID(configuration);reporter.publish(frame);await drain()
   precondition(reports==count,"Unchanged inputs do not cause repeated frame publications")
  }
  reporter.updateMeasurementID("inactive");reporter.publish(frame)
  reporter.updateMeasurementID("active");reporter.publish(frame);await drain()
  precondition(anchor==frame,"Only the latest active measurement is delivered")
  print("Search lifecycle checks passed: interrupted close, retained/reopened search, keyboard timing, focus ownership and all five anchor configurations")
 }
}
'''
for key,value in {'TRANSITION':transition,'OWNER':owner,'ACTIVE':active,'PUBLISH':publish,
                  'MEASUREMENT':measurement,'FRAME_PUBLISH':frame_publish}.items():
 s=s.replace('\n'+key+'\n','\n'+value+'\n').replace('\n '+key+'\n','\n'+value+'\n')
with tempfile.TemporaryDirectory(prefix='aether-search-navigation-') as directory:
 directory=Path(directory);swift=directory/'Checks.swift';swift.write_text(s)
 subprocess.run(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',str(swift),'-o',str(directory/'checks')],check=True)
 subprocess.run([str(directory/'checks')],check=True)

assert 'if enabled {\n\t\t\t\t\tSearchHeaderOverlay' in field
assert 'if !isScreenActive { transition.cancelPendingKeyboardTransition() }' in field
assert field.count('WindowFrameReader(measurementID: anchorMeasurementID)')==3
assert 'view.updateMeasurementID(measurementID)' in overlay
assert '.onChange(of: dynamicTypeSize)' in field

# Run the production global-style gate against controlled navigation bars.
appearance=declaration(field,'private enum NavigationTitleAppearance {')
style=r'''
import Foundation
extension NSAttributedString.Key {
 static let foregroundColor=Self("foregroundColor")
 static let font=Self("font")
}
@MainActor enum Probe {static var visited=0;static var fontScale:CGFloat=1}
@MainActor final class UIColor {
 let name:String
 init(_ name:String){self.name=name}
 static let label=UIColor("label"),secondaryLabel=UIColor("secondary")
 func isEqual(_ other:UIColor)->Bool {name==other.name}
}
@MainActor final class UIFont {
 enum TextStyle {case headline,largeTitle};enum Weight {case bold}
 let pointSize:CGFloat
 init(_ size:CGFloat){pointSize=size}
 static func preferredFont(forTextStyle style:TextStyle)->UIFont {UIFont((style == .headline ? 17:34)*Probe.fontScale)}
 static func systemFont(ofSize size:CGFloat,weight:Weight)->UIFont {UIFont(size)}
 func isEqual(_ other:UIFont)->Bool {pointSize==other.pointSize}
}
@MainActor class UIView {
 var children:[UIView]=[]
 var subviews:[UIView] {Probe.visited+=1;return children}
}
@MainActor final class UINavigationBarAppearance {
 var titleTextAttributes:[NSAttributedString.Key:Any]=[:]
 var largeTitleTextAttributes:[NSAttributedString.Key:Any]=[:]
 var backgroundToken="native glass"
 func copy()->Any {let result=UINavigationBarAppearance();result.titleTextAttributes=titleTextAttributes;result.largeTitleTextAttributes=largeTitleTextAttributes;result.backgroundToken=backgroundToken;return result}
}
@MainActor final class UINavigationBar:UIView {
 static let proxy=UINavigationBar()
 static func appearance()->UINavigationBar {proxy}
 var titleTextAttributes:[NSAttributedString.Key:Any]=[:]
 var largeTitleTextAttributes:[NSAttributedString.Key:Any]=[:]
 var writes=0
 var standardAppearance=UINavigationBarAppearance() {didSet{writes+=1}}
 var compactAppearance:UINavigationBarAppearance?=UINavigationBarAppearance() {didSet{writes+=1}}
 var scrollEdgeAppearance:UINavigationBarAppearance?=UINavigationBarAppearance() {didSet{writes+=1}}
 var compactScrollEdgeAppearance:UINavigationBarAppearance?=UINavigationBarAppearance() {didSet{writes+=1}}
}
@MainActor final class UIWindowScene {var windows:[UIView]=[]}
@MainActor final class UIApplication {static let shared=UIApplication();var connectedScenes:[AnyObject]=[]}
@MainActor
APPEARANCE
@main struct Checks {
 @MainActor static func main() {
  let first=UINavigationBar(),modal=UINavigationBar(),window=UIView(),scene=UIWindowScene()
  window.children=[first,modal];scene.windows=[window];UIApplication.shared.connectedScenes=[scene]
  first.standardAppearance.titleTextAttributes[NSAttributedString.Key("unrelated")]="kept"
  for muted in [false,true] {
   for bold in [false,true] {
    NavigationTitleAppearance.apply(muted:muted,bold:bold)
    let visits=Probe.visited,writes=first.writes+modal.writes
    NavigationTitleAppearance.apply(muted:muted,bold:bold)
    precondition(Probe.visited==visits && first.writes+modal.writes==writes,"Unchanged styles must perform no window traversal or appearance writes")
    for bar in [first,modal] {
     let color=bar.standardAppearance.titleTextAttributes[.foregroundColor] as! UIColor
     precondition(color.name == (muted ? "secondary":"label"),"Global changes reach existing modal bars")
     let font=bar.standardAppearance.titleTextAttributes[.font] as? UIFont
     precondition((font != nil)==bold)
     precondition(bar.standardAppearance.backgroundToken=="native glass","Styling must preserve native glass backgrounds")
    }
   }
  }
  let beforeTypeChange=Probe.visited
  Probe.fontScale=1.5;NavigationTitleAppearance.apply(muted:true,bold:true)
  precondition(Probe.visited>beforeTypeChange && (first.standardAppearance.titleTextAttributes[.font] as! UIFont).pointSize==25.5,
   "Changed Dynamic Type invalidates the bold-font style cache")
  precondition(first.standardAppearance.titleTextAttributes[NSAttributedString.Key("unrelated")] as? String == "kept")
  let unchanged=Probe.visited
  NavigationTitleAppearance.apply(muted:true,bold:true)
  precondition(Probe.visited==unchanged)
  print("Navigation appearance checks passed: zero unchanged-style sweeps, all title styles, live modal updates and Dynamic Type")
 }
}
'''.replace('APPEARANCE',appearance)
with tempfile.TemporaryDirectory(prefix='aether-navigation-appearance-') as directory:
 directory=Path(directory);swift=directory/'Checks.swift';swift.write_text(style)
 subprocess.run(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',str(swift),'-o',str(directory/'checks')],check=True)
 subprocess.run([str(directory/'checks')],check=True)
