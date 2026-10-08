#!/usr/bin/env python3
"""Verify native progress doesn't change resource hashes or ad-hoc signature output."""
import pathlib, subprocess, tempfile, plistlib, shutil
repo=pathlib.Path(__file__).resolve().parents[2]
openssl=pathlib.Path(subprocess.check_output(['brew','--prefix','openssl@3'],text=True).strip())
zsign=repo/'Zsign'
source=r'''
#include "bundle.h"
#include "signing_progress.h"
#include "sha.h"
#include "mach-o.h"
#include "signing.h"
#include <cassert>
#include <thread>
#include <iostream>
int main(int argc, char** argv) {
 std::string root=argv[1], expected1,expected256,actual1,actual256;
 assert(ZSHA::SHAFile((root+"/plain.app/Large.dat").c_str(),expected1,expected256));
 std::vector<double> fileProgress;
 {
  ZSigningProgress::Scope outer([&](double v){fileProgress.push_back(v);});
  ZSigningProgress::Scope inner(0.2,0.8);
  assert(ZSHA::SHAFile((root+"/plain.app/Large.dat").c_str(),actual1,actual256));
  std::thread isolated([] {assert(!ZSigningProgress::callback);}); isolated.join();
 }
 assert(!ZSigningProgress::callback);
 assert(expected1==actual1 && expected256==actual256);
 assert(fileProgress.size()>=4 && fileProgress.front()>0.2 && fileProgress.back()==0.8);
 for (size_t i=1;i<fileProgress.size();++i) assert(fileProgress[i]>=fileProgress[i-1]);
 // Exercise the actual page-hashing loop with a large executable code region.
 std::vector<uint8_t> code(8 * 1024 * 1024 + 123, 0x5a);
 for (bool alternate : {false,true}) {
  std::string plain,reported,hash(alternate ? 32 : 20, '\0');
  auto build = [&](std::string& output) {
   return ZSign::SlotBuildCodeDirectory(alternate,code.data(),uint32_t(code.size()),nullptr,0,0,0,
    "test.progress","",hash,hash,hash,hash,hash,true,true,output);
  };
  assert(build(plain));
  std::vector<double> pages;
  { ZSigningProgress::Scope progress([&](double v){pages.push_back(v);}); assert(build(reported)); }
  assert(plain==reported && pages.size()>4 && pages.back()==1);
  for (size_t i=1;i<pages.size();++i) assert(pages[i]>=pages[i-1]);
 }
 for (auto name : {"plain.app","progress.app"}) {
  ZSignAsset asset;assert(asset.Init("","","","","",true,false,false));
  ZBundle bundle; std::vector<double> reports;
  if (std::string(name)=="progress.app") bundle.progress=[&](double v){reports.push_back(v);};
  assert(bundle.SignFolder(&asset,root+"/"+name,"","","",{}, {},true,false,false,false));
  if (!reports.empty()) {
   assert(reports.front()==0 && reports.back()==1);
   assert(reports.size()>10);
   for(size_t i=1;i<reports.size();++i) assert(reports[i]>=reports[i-1] && reports[i]<=1);
  }
 }
 std::cout << "Native signing / hashing progress checks passed\n";
}
'''
with tempfile.TemporaryDirectory(prefix='aether-native-signing-progress-') as d:
 root=pathlib.Path(d);app=root/'plain.app';app.mkdir()
 (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.progress','CFBundleExecutable':'Main','CFBundleName':'Fixture','CFBundleVersion':'1'}))
 (app/'Large.dat').write_bytes(b'progress-fixture-'*(1024*1024))
 main=root/'main.c';main.write_text('int main(void) { return 0; }\n')
 subprocess.run(['clang',str(main),'-o',str(app/'Main')],check=True)
 shutil.copytree(app,root/'progress.app')
 runner=root/'checks.cpp';runner.write_text(source)
 files=['archo.cpp','bundle.cpp','macho.cpp','openssl.cpp','signing.cpp','common/base64.cpp','common/fs.cpp','common/json.cpp','common/log.cpp','common/sha.cpp','common/timer.cpp','common/util.cpp']
 subprocess.run(['clang++','-std=c++17','-Wno-deprecated-declarations','-I',str(zsign/'src'),'-I',str(zsign/'src/common'),'-I',str(openssl/'include'),str(runner),*[str(zsign/'src'/f) for f in files],'-L',str(openssl/'lib'),'-lcrypto','-o',str(root/'checks')],check=True)
 subprocess.run([str(root/'checks'),str(root)],check=True,stdout=subprocess.DEVNULL)
 for filename in ['Main','_CodeSignature/CodeResources']:
  assert (app/filename).read_bytes()==(root/'progress.app'/filename).read_bytes(), filename+' changed with progress enabled'
 print('Native signing progress checks passed: identical hashes, signature and resource seal')
