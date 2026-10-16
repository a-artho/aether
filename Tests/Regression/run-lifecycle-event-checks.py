"""Execute production notification bodies after simulated delayed lifecycle delivery."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
def task_body(file, marker):
    s = (repo/file).read_text(); a = s.index('Task { @MainActor in', s.index(marker))
    a = s.index('{', a)+1; b = a; depth = 1
    while depth:
        depth += (s[b] == '{') - (s[b] == '}'); b += 1
    return s[a:b-1].replace("@MainActor in", "", 1)
processing = task_body('Aether/Backend/Observable/DownloadManager.swift', '_backgroundObserver = NotificationCenter')
foreground = task_body('Aether/Backend/Observable/DownloadManager.swift', '_foregroundObserver = NotificationCenter')
installation = task_body('Aether/Backend/Observable/AppInstallationManager.swift', '_backgroundObserver = NotificationCenter')
grants = task_body('Aether/Utilities/BackgroundTaskManager.swift', 'backgroundObserver = BackgroundNotificationToken')
def delivery(body):
    return 'func deliver() { let callback = { [weak self] in\n'+body+'\n}; callback() }\n'
s = r'''
import Foundation
@MainActor final class UIApplication {
 enum State:CaseIterable { case active, inactive, background }
 static let shared=UIApplication();var applicationState=State.active
}
@MainActor final class BackgroundTaskManager {
 static let shared=BackgroundTaskManager()
 func hasExecution(for id:String)->Bool {false}
}
final class Worker {var cancelled=false;func cancel(){cancelled=true}}
final class Download {
 enum State {case processing};let state=State.processing;let id="download"
 var waitingForForeground=false;var interruptionForegroundGeneration:UInt64=0
}
@MainActor final class Processing {
 let downloads=[Download()];var _foregroundGeneration:UInt64=1
 let worker=Worker();var _processingTasks:[String:Worker]=[:];var persisted=0
 init(){_processingTasks["download"]=worker}
 func _persistDownloads(){persisted+=1};func _releaseIdleBackgroundTunnel(){}
 PROCESSING
}
@MainActor final class Foreground {
 var _foregroundGeneration:UInt64=0;var resumes=0
 func _resumeInterruptedProcessing(){resumes+=1}
 FOREGROUND
}
final class Execution {let hasExecution=false}
@MainActor final class Installation {
 let isInstalling=true;let execution:Execution?=nil;let installGeneration=UUID();var interrupted=0
 func _interruptInstallation(generation:UUID){interrupted+=1}
 INSTALLATION
}
@MainActor final class Grants {
 enum Fallback {case invalid}
 final class Work {var task:String?;var fallback=Fallback.invalid}
 let workByToken=["work":Work()];var interrupted=0
 func _interrupt(_ token:String,work:Work,reason:String){interrupted+=1}
 GRANTS
}
@main struct Checks {
 @MainActor static func main() {
  for state in UIApplication.State.allCases {
   UIApplication.shared.applicationState=state
   let processing=Processing(),installation=Installation(),grants=Grants(),foreground=Foreground()
   processing.deliver();installation.deliver();grants.deliver();foreground.deliver()
   let background=state == .background
   precondition(processing.worker.cancelled == background)
   precondition(processing.downloads[0].waitingForForeground == background)
   precondition(processing.persisted == (background ? 1:0))
   precondition(installation.interrupted == (background ? 1:0))
   precondition(grants.interrupted == (background ? 1:0))
   precondition(foreground.resumes == (state == .active ? 1:0))
   precondition(foreground._foregroundGeneration == (state == .active ? 1:0))
  }
  print("Lifecycle event checks passed: delayed foreground/background delivery, processing, installation and execution ownership")
 }
}
'''
for key, value in [('PROCESSING',processing),('FOREGROUND',foreground),('INSTALLATION',installation),('GRANTS',grants)]:
    s = s.replace(key,delivery(value))
with tempfile.TemporaryDirectory(prefix='aether-lifecycle-events-') as d:
    p=pathlib.Path(d);(p/'Checks.swift').write_text(s)
    subprocess.run(['swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
    subprocess.run([str(p/'checks')],check=True)
