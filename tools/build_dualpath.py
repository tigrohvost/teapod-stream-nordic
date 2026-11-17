#!/usr/bin/env python3
"""Build the transport adapter and verify the pinned Naive Android plugin."""
import argparse,hashlib,io,json,os,pathlib,subprocess,urllib.request,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--go',default='go');p.add_argument('--abi',action='append');args=p.parse_args()
 lock=json.loads((ROOT/'native/runtime.lock.json').read_text())
 for abi in args.abi or list(lock['naive']):
  item=lock['naive'][abi]
  with urllib.request.urlopen(item['url'],timeout=90) as response: data=response.read(item['size']+1)
  if len(data)!=item['size'] or hashlib.sha256(data).hexdigest()!=item['sha256']:raise ValueError('Naive archive verification failed')
  with zipfile.ZipFile(io.BytesIO(data)) as z:binary=z.read('lib/'+abi+'/libnaive.so')
  output=ROOT/'android/app/src/main/jniLibs'/abi;output.mkdir(parents=True,exist_ok=True)
  (output/'libteapod_naive.so').write_bytes(binary)
  env={**os.environ,'GOOS':'android','GOARCH':{'arm64-v8a':'arm64','armeabi-v7a':'arm','x86_64':'amd64'}[abi],'CGO_ENABLED':'0'}
  if abi=='armeabi-v7a':env['GOARM']='7'
  if abi!='arm64-v8a':
   sdk=pathlib.Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
   target={'armeabi-v7a':'armv7a-linux-androideabi','x86_64':'x86_64-linux-android'}[abi]
   env.update(CGO_ENABLED='1',CC=str(sdk/'ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin'/f'{target}29-clang'))
  subprocess.run([args.go,'build','-trimpath','-ldflags=-s -w','-o',str(output/'libteapod_dualpath.so'),'.'],cwd=ROOT/'native/dualpath',env=env,check=True)
  for path in output.glob('libteapod_*.so'):path.chmod(0o755)
  print('Built verified DualPath runtime:',abi)
if __name__=='__main__':main()
