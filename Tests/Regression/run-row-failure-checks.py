"""Exercise the production row error formatter without iOS UI dependencies."""
from pathlib import Path
import subprocess,tempfile
repo=Path(__file__).resolve().parents[2]
s=(repo/'Aether/Utilities/AppRowFailure.swift').read_text().replace('import IDeviceSwift','')
s+='''
extension String {static func localized(_ s:String)->String {s}}
struct InstallationBackgroundError:LocalizedError {var errorDescription:String? {"Full background details"}}
enum SigningFileHandlerError:LocalizedError {case signFailed;var errorDescription:String? {"Signing failed."}}
enum AetherSigningIdentity {enum Failure:Error {case invalidProfile,wildcardProfile,certificateRequired,customEntitlements,removalOptions,notAether,expiredProfile}}
enum BundlePackageWriter {enum Failure:Error {case changedSource(String),archive(String)}}
struct IDeviceSwiftError:LocalizedError {let code:Int32;let message:String;var errorDescription:String? {message}}
@main struct Checks {static func main() {
 precondition(AppRowFailure.text(for:InstallationBackgroundError(),stage:.installation)=="iOS interrupted background installation")
 precondition(AppRowFailure.text(for:AetherSigningIdentity.Failure.wildcardProfile,stage:.signing)=="Profile needs an explicit ID")
 precondition(AppRowFailure.text(for:NSError(domain:NSURLErrorDomain,code:-1202),stage:.download)=="Server certificate untrusted")
 precondition(AppRowFailure.text(for:NSError(domain:NSCocoaErrorDomain,code:640),stage:.signing)=="Not enough storage")
 let native=IDeviceSwiftError(code:42,message:"InstallationProxy: ApplicationVerificationFailed: signature rejected at /very/long/path/to/Some.app")
 precondition(AppRowFailure.text(for:native,stage:.installation)=="App verification failed")
 let nested=IDeviceSwiftError(code:43,message:"Could not connect to AFC: nested transport connection timed out after several attempts")
 precondition(AppRowFailure.text(for:nested,stage:.installation)=="Connection timed out")
 let unknown=IDeviceSwiftError(code:44,message:String(repeating:"technical detail ",count:30))
 precondition(AppRowFailure.text(for:unknown,stage:.installation)=="Installation error (44)")
 precondition(AppRowFailure.text(message:"The download failed with HTTP 404 (not found).",stage:.download)=="HTTP 404")
 precondition(AppRowFailure.text(for:BundlePackageWriter.Failure.changedSource(String(repeating:"path/",count:100)),stage:.export)=="App changed during packaging")
 print("Row failure checks passed: exact interruption wording, specific causes, nested failures and code-preserving fallback")
}}
'''
with tempfile.TemporaryDirectory(prefix='aether-row-failures-') as d:
 p=Path(d);(p/'Checks.swift').write_text(s)
 subprocess.run(['swiftc','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
