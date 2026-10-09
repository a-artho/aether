#!/usr/bin/env python3
"""Exercise production lightweight lookup and pairing checks through a mock C ABI."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
def declaration(path,start):
 s=(repo/path).read_text(); begin=s.index(start); end=s.index('{',begin)+1; depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}'); end+=1
 return s[begin:end]
header=r'''
#include <stdlib.h>
#include <stdint.h>
typedef struct IdeviceFfiError {int32_t code; int32_t sub_code; const char *message;} IdeviceFfiError;
typedef struct InstallationProxyClientHandle InstallationProxyClientHandle;
typedef void *plist_t;
plist_t plist_new_dict(void); plist_t plist_new_array(void); plist_t plist_new_string(const char*);
void plist_free(plist_t); void plist_dict_set_item(plist_t,const char*,plist_t); void plist_array_append_item(plist_t,plist_t);
int plist_to_bin(plist_t,char**,uint32_t*);
IdeviceFfiError *installation_proxy_browse(InstallationProxyClientHandle*,plist_t,plist_t**,size_t*);
IdeviceFfiError *installation_proxy_get_apps(InstallationProxyClientHandle*,const char*,const char*const*,size_t,void**,size_t*);
void idevice_plist_array_free(plist_t*,uintptr_t); void idevice_outer_slice_free(void*,uintptr_t); void idevice_error_free(IdeviceFfiError*);
void mock_partial(int); void mock_set_fixture(const char*,uint32_t); void mock_set_error(int32_t,int32_t); int mock_lookups(void); int mock_attributes(void); int mock_filtered(void);
'''
header += r"""
#include <sys/socket.h>
typedef struct sockaddr idevice_sockaddr;
typedef struct AdapterHandle AdapterHandle; typedef struct RsdHandshakeHandle RsdHandshakeHandle; typedef struct RpPairingFileHandle RpPairingFileHandle;
IdeviceFfiError *tunnel_create_rppairing(const idevice_sockaddr*,socklen_t,const char*,RpPairingFileHandle*,const char*(*)(void*),void*,AdapterHandle**,RsdHandshakeHandle**);
void rp_pairing_file_free(RpPairingFileHandle*);void rsd_handshake_free(RsdHandshakeHandle*);void adapter_free(AdapterHandle*);
void mock_tunnel_port(uint16_t);void mock_tunnel_auth(int);int mock_tunnel_calls(void);
"""
c=r'''
#include "Device.h"
#include <string.h>
static int partial; void mock_partial(int enabled){partial=enabled;}
static char *fixture; static uint32_t length; static int code,sub,lookups,attributes,filtered;
void mock_set_fixture(const char *s,uint32_t n){free(fixture);fixture=malloc(n);memcpy(fixture,s,n);length=n;lookups=attributes=filtered=0;}
void mock_set_error(int32_t c,int32_t s){code=c;sub=s;}
int mock_lookups(void){return lookups;} int mock_attributes(void){return attributes;} int mock_filtered(void){return filtered;}
plist_t plist_new_dict(void){return (void*)1;} plist_t plist_new_array(void){return (void*)1;}
plist_t plist_new_string(const char *s){return (void*)1;} void plist_free(plist_t p){}
void plist_dict_set_item(plist_t p,const char*k,plist_t v){} void plist_array_append_item(plist_t p,plist_t v){attributes++;}
int plist_to_bin(plist_t p,char**s,uint32_t*n){*s=malloc(length);memcpy(*s,fixture,length);*n=length;return 0;}
static IdeviceFfiError *failure(void){IdeviceFfiError *e=malloc(sizeof(*e));e->code=code;e->sub_code=sub;e->message=strdup("mock failure");return e;}
IdeviceFfiError *installation_proxy_browse(InstallationProxyClientHandle*c,plist_t p,plist_t**out,size_t*n){
 if(code)return failure(); *out=calloc(partial?2:1,sizeof(plist_t));(*out)[0]=(void*)1;*n=partial?2:1;return NULL;
}
IdeviceFfiError *installation_proxy_get_apps(InstallationProxyClientHandle*c,const char*t,const char*const*ids,size_t count,void**out,size_t*n){
 lookups++;if(ids&&count==1&&!strcmp(ids[0],"fixture.app"))filtered++;
 plist_t *results=malloc(sizeof(plist_t));results[0]=(void*)1;*out=results;*n=1;return NULL;
}
void idevice_plist_array_free(plist_t*p,uintptr_t n){} void idevice_outer_slice_free(void*p,uintptr_t n){free(p);}
void idevice_error_free(IdeviceFfiError*e){free((void*)e->message);free(e);}
'''
c += r"""
#include <netinet/in.h>
static uint16_t good_port=49152;static int tunnel_calls,tunnel_auth;
void mock_tunnel_port(uint16_t port){good_port=port;tunnel_calls=0;}
void mock_tunnel_auth(int enabled){tunnel_auth=enabled;}
int mock_tunnel_calls(void){return tunnel_calls;}
IdeviceFfiError *tunnel_create_rppairing(const idevice_sockaddr*a,socklen_t n,const char*h,RpPairingFileHandle*p,const char*(*pin)(void*),void*ctx,AdapterHandle**adapter,RsdHandshakeHandle**handshake){
 tunnel_calls++;
 if(tunnel_auth || ntohs(((const struct sockaddr_in*)a)->sin_port)!=good_port){
  int prior=code, prior_sub=sub;code=tunnel_auth?103:1;sub=tunnel_auth?5:0;
  IdeviceFfiError *e=failure();code=prior;sub=prior_sub;return e;
 }
 *adapter=(void*)1;*handshake=(void*)2;return NULL;
}
void rp_pairing_file_free(RpPairingFileHandle*p){}void rsd_handshake_free(RsdHandshakeHandle*p){}void adapter_free(AdapterHandle*p){}
"""
proxy_source=(repo/'IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift').read_text()
# Preserve production imports that are available on macOS, so missing OSLog imports fail.
imports='\n'.join(line for line in proxy_source.splitlines() if line.startswith('import ') and line not in ['import IDevice','import UIKit'])+'\nimport NativeDevice\n'
header += r'''
typedef struct MisagentClientHandle MisagentClientHandle;
IdeviceFfiError *misagent_copy_all(MisagentClientHandle*,uint8_t***,size_t**,size_t*);
void misagent_free_profiles(uint8_t**,size_t*,size_t);void misagent_client_free(MisagentClientHandle*);void installation_proxy_client_free(InstallationProxyClientHandle*);
'''
c += r'''
IdeviceFfiError *misagent_copy_all(MisagentClientHandle*c,uint8_t***p,size_t**sizes,size_t*n){
 if(code)return failure();*n=1;*p=malloc(sizeof(uint8_t*));(*p)[0]=malloc(length);memcpy((*p)[0],fixture,length);*sizes=malloc(sizeof(size_t));(*sizes)[0]=length;return NULL;
}
void misagent_free_profiles(uint8_t**p,size_t*s,size_t n){for(size_t i=0;i<n;i++)free(p[i]);free(p);free(s);}
void misagent_client_free(MisagentClientHandle*c){}void installation_proxy_client_free(InstallationProxyClientHandle*c){}
'''
swift=imports
swift+=declaration('IDeviceKitten/Sources/IDeviceSwift/IDeviceSwiftError.swift','public struct IDeviceSwiftError')+'\n'
swift+=declaration('IDeviceKitten/Sources/IDeviceSwift/IDeviceSwiftError.swift','enum IDeviceConnectionError')+'\n'
swift+=declaration('IDeviceKitten/Sources/IDeviceSwift/Heartbeat/PairingVerification.swift','public struct DeviceConnectionCheck')+'\n'
swift+='''public struct AppInfo: Codable, Sendable { let CFBundleIdentifier: String?; let CFBundleDisplayName: String? }
class InstallationAppProxy {
'''
for start in ['static func readApps(','private static func decodeApps(']: swift+=declaration('IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift',start)+'\n'
swift+='}\nclass HeartbeatManager {\n'+r'''
 typealias AdapterHandle=OpaquePointer;typealias RsdHandshakeHandle=OpaquePointer
 let rsdConnectionLock=NSLock();var rsdAdapter:OpaquePointer?;var rsdHandshake:OpaquePointer?
 var rsdGeneration:UInt64=0;var lastSuccessfulRSDPort:UInt16?
 let ipAddress="10.7.0.1",port_rsd:UInt16=49152
 func getPairingRsd() throws -> OpaquePointer {OpaquePointer(bitPattern:3)!}
 func ensure() throws {try _ensureRSDTunnelLocked()}
'''+declaration('IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat+checks.swift','private func verifiedClient(').replace('private func','func',1)+'\n'
for start in ['static func shouldRetryRSDService(', 'private func connectRSDServiceOnce(', 'private func _ensureRSDTunnelLocked(', 'private func _invalidateRSDTunnelLocked(']:
 swift+=declaration('IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat+start.swift',start)+'\n'
swift+=declaration('IDeviceKitten/Sources/IDeviceSwift/Heartbeat/Heartbeat+start.swift','func withRSDServiceConnection(\n\t\tdiscoveryTimeout:')+'\n}\n'
swift+=r'''
enum RSDPortDiscovery {
 static var calls=0
 static func resolvePorts(timeout:TimeInterval,stopWhen:([UInt16])->Bool)->[UInt16] {calls+=1;_=stopWhen([55000]);return [55000]}
}
'''

swift+=r'''
func check(_ value: @autoclosure () -> Bool,_ label:String){precondition(value(),label)}
let encoder=PropertyListEncoder();encoder.outputFormat = .binary
let bytes=try encoder.encode(AppInfo(CFBundleIdentifier:"fixture.app",CFBundleDisplayName:"Fixture"))
bytes.withUnsafeBytes {mock_set_fixture($0.baseAddress!.assumingMemoryBound(to:CChar.self),UInt32(bytes.count))}
let client=OpaquePointer(bitPattern:1)!
let apps=try InstallationAppProxy.readApps(client:client,applicationType:"User",lightweight:true)
check(apps.first?.CFBundleIdentifier == "fixture.app","Binary plist preserves app identity")
check(mock_attributes() == 12 && mock_lookups() == 0,"Lightweight browse uses requested fields without duplicate lookup")
mock_set_error(21,0)
let fallback=try InstallationAppProxy.readApps(client:client,applicationType:"User",lightweight:true)
check(fallback.count == 1 && mock_lookups() == 1,"Unsupported browse falls back to full lookup")
mock_set_error(103,5)
do { _=try InstallationAppProxy.readApps(client:client,applicationType:"User",lightweight:true);preconditionFailure("Pair rejection swallowed") }
catch let error as IDeviceSwiftError {check(error.code == 103 && error.subCode == 5,"Pair rejection preserved")}
check(mock_lookups() == 1,"Pair rejection never retried through lookup")
let rejected=HeartbeatManager().verifiedClient(client,includeApps:true)
check(rejected.rejectsPairingRecord,"Combined verification/browse rejects invalid pairing")
mock_set_error(0,0)
let readiness=Flag()
let verified=HeartbeatManager().verifiedClient(client,includeApps:true,onVerified:{readiness.set()})
check(verified.isConnected && verified.apps?.count == 1,"Combined verification carries the initial list")
check(readiness.get(),"Authenticated connection publishes readiness")
mock_partial(1)
let priorLookups=mock_lookups()
let complete=try InstallationAppProxy.readApps(client:client,applicationType:"User",lightweight:true)
check(complete.count==1 && mock_lookups()==priorLookups+1,"Partial browse triggers full lookup fallback")
mock_partial(0)
_=try InstallationAppProxy.readApps(client:client,applicationType:"User",bundleIdentifier:"fixture.app")
check(mock_filtered() == 1,"Full details lookup requests just the selected app")
check(!HeartbeatManager.shouldRetryRSDService(IDeviceSwiftError(23,message:"locked")),"Locked service doesn't reset healthy transport")
check(!HeartbeatManager.shouldRetryRSDService(IDeviceSwiftError(103,message:"pair",subCode:5)),"Rejected pairing not retried")
check(HeartbeatManager.shouldRetryRSDService(IDeviceSwiftError(1,message:"socket")),"Broken transport remains recoverable")

mock_set_error(0,0);mock_tunnel_port(49152)
let warm=HeartbeatManager();try warm.ensure();try warm.ensure()
check(mock_tunnel_calls()==1 && RSDPortDiscovery.calls==0,"Healthy RSD handshake reused without discovery")
mock_tunnel_port(55000)
let discovered=HeartbeatManager();try discovered.ensure()
check(discovered.lastSuccessfulRSDPort==55000 && mock_tunnel_calls()==2,"Discovered port authenticated immediately")
mock_tunnel_auth(1)
let invalid=HeartbeatManager()
do {try invalid.ensure();preconditionFailure("Invalid pair accepted")}
catch let e as IDeviceSwiftError {check(e.code==103 && e.subCode==5,"Discovery preserves authentication rejection")}
mock_tunnel_auth(0);mock_tunnel_port(49152);mock_set_error(23,0)
let locked=HeartbeatManager();try locked.ensure();let before=locked.rsdGeneration
var attempts=0
do {try locked.withRSDServiceConnection(discoveryTimeout:1.5) {_,_ in
 attempts+=1;var out:UnsafeMutablePointer<UnsafeMutableRawPointer?>?;var count=0
 return installation_proxy_browse(client,nil,&out,&count)
};preconditionFailure("Locked service accepted")} catch {}
check(attempts==1 && locked.rsdGeneration==before,"Permanent service failure preserves healthy adapter")
mock_set_error(1,0)
final class Flag: @unchecked Sendable {let lock=NSLock();var value=false;func set(){lock.lock();value=true;lock.unlock()};func get()->Bool{lock.lock();defer{lock.unlock()};return value}}
let flag=Flag(), group=DispatchGroup();group.enter()
DispatchQueue.global().asyncAfter(deadline:.now()+0.03){if locked.rsdConnectionLock.try(){flag.set();locked.rsdConnectionLock.unlock()};group.leave()}
attempts=0
try locked.withRSDServiceConnection(discoveryTimeout:1.5) {_,_ in
 attempts+=1;if attempts==2{return nil}
 var out:UnsafeMutablePointer<UnsafeMutableRawPointer?>?;var count=0
 return installation_proxy_browse(client,nil,&out,&count)
}
_=group.wait(timeout:.now()+1)
check(attempts==2 && flag.get(),"Transport retry backoff releases shared lock")
print("Device loading ABI/pairing/RSD checks passed")
'''
with tempfile.TemporaryDirectory(prefix='aether-device-loading-') as directory:
 root=pathlib.Path(directory)
 (root/'Device.h').write_text(header);(root/'Device.c').write_text(c);(root/'main.swift').write_text(swift)
 (root/'Logging.swift').write_text('import OSLog\nextension Logger { static let heartbeat = Logger(subsystem: "aether.regression", category: "Heartbeat") }')
 (root/'module.modulemap').write_text('module NativeDevice { header "Device.h" export * }')
 subprocess.run(['clang','-c',str(root/'Device.c'),'-o',str(root/'Device.o')],check=True)
 subprocess.run(['swiftc','-I',str(root),str(root/'main.swift'),str(root/'Logging.swift'),str(root/'Device.o'),'-o',str(root/'checks')],check=True)
 subprocess.run([str(root/'checks')],check=True)

 # Compile the actual app/profile models and both detached reader workers together.
 reader=imports+declaration('IDeviceKitten/Sources/IDeviceSwift/IDeviceSwiftError.swift','public struct IDeviceSwiftError')+'\n'
 for model in ['InstallationProxy/Models/AppInfo.swift','InstallationProxy/Models/ProvisioningProfileInfo.swift','Utilties/AnyCodable.swift']:
  reader+=(repo/'IDeviceKitten/Sources/IDeviceSwift'/model).read_text()+'\n'
 reader+='class InstallationAppProxy {\n typealias InstallationProxyClientHandle=OpaquePointer; typealias MisagentClientHandle=OpaquePointer\n'
 reader+='func _connectInstallationProxy(client: inout OpaquePointer?) throws {client=OpaquePointer(bitPattern:1)}\nfunc _connectMisagent(client: inout OpaquePointer?) throws {client=OpaquePointer(bitPattern:1)}\n'
 reader+=declaration('IDeviceKitten/Sources/IDeviceSwift/Heartbeat/PairingVerification.swift','public struct DeviceConnectionCheck')+'\n'
 for start in ['public func fetchApps(', 'static func readApps(', 'private static func decodeApps(', 'public func provisioningProfiles(']:
  reader+=declaration('IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallationAppProxy.swift',start)+'\n'
 reader+='}\n'
 reader+=r'''@main struct ReaderChecks {
 static func main() async throws {
  let bytes=try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"fixture.app","CFBundleDisplayName":"Fixture"],format:.binary,options:0)
  bytes.withUnsafeBytes {mock_set_fixture($0.baseAddress!.assumingMemoryBound(to:CChar.self),UInt32(bytes.count))}
  mock_set_error(0,0)
  let proxy=InstallationAppProxy()
  let apps=try await proxy.fetchApps(applicationType:"User",lightweight:true)
  precondition(apps.count==1 && apps[0].CFBundleIdentifier=="fixture.app")
  let profile=try PropertyListSerialization.data(fromPropertyList:["Entitlements":["application-identifier":"TEAM.fixture.app"],"ExpirationDate":Date(timeIntervalSince1970:2000000000)],format:.binary,options:0)
  profile.withUnsafeBytes {mock_set_fixture($0.baseAddress!.assumingMemoryBound(to:CChar.self),UInt32(profile.count))}
  let profiles=try await proxy.provisioningProfiles()
  precondition(profiles.count==1 && profiles[0].applicationIdentifier=="TEAM.fixture.app")
  let bad=Data("malformed profile".utf8)
  bad.withUnsafeBytes {mock_set_fixture($0.baseAddress!.assumingMemoryBound(to:CChar.self),UInt32(bad.count))}
  let invalid=try await proxy.provisioningProfiles()
  precondition(invalid.isEmpty)
  mock_set_error(103,5)
  do {_ = try await proxy.provisioningProfiles();preconditionFailure("Pair rejection swallowed")}
  catch let error as IDeviceSwiftError {precondition(error.code==103 && error.subCode==5)}
  print("Production native app/profile reader checks passed")
 }
}
'''
 (root/'Readers.swift').write_text(reader)
 subprocess.run(['swiftc','-parse-as-library','-I',str(root),str(root/'Readers.swift'),str(root/'Logging.swift'),str(root/'Device.o'),'-o',str(root/'readers')],check=True)
 subprocess.run([str(root/'readers')],check=True)
