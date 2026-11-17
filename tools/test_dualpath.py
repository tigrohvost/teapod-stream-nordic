#!/usr/bin/env python3
"""Real TLS/KCP/smux/SOCKS integration: integrity, FIN, UDP and path loss."""
import argparse,contextlib,hashlib,json,os,pathlib,secrets,socket,struct,subprocess,tempfile,threading,time

def exact(s,n):
 out=b''
 while len(out)<n:
  b=s.recv(n-len(out))
  if not b:raise EOFError((len(out),n))
  out+=b
 return out
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def addr(p):return b'\x01\x7f\x00\x00\x01'+struct.pack('!H',p)
def auth(p,password=b'local-password-12345'):
 s=socket.create_connection(('127.0.0.1',p),timeout=25);s.sendall(b'\x05\x01\x02');assert exact(s,2)==b'\x05\x02'
 s.sendall(b'\x01\x04user'+bytes([len(password)])+password);reply=exact(s,2)
 if reply!=b'\x01\x00':s.close();return None
 return s
def connect(p,target):
 s=auth(p);s.sendall(b'\x05\x01\x00'+addr(target));assert exact(s,10)[:2]==b'\x05\x00';return s
class Relay:
 def __init__(self,target):
  self.target=target;self.enabled=True;self.connections=[];self.l=socket.socket();self.l.bind(('127.0.0.1',0));self.port=self.l.getsockname()[1];self.l.listen();threading.Thread(target=self.run,daemon=True).start()
 def cut(self):
  self.enabled=False
  for s in self.connections:
   with contextlib.suppress(OSError):s.shutdown(socket.SHUT_RDWR)
   s.close()
  self.connections=[]
 def run(self):
  while True:
   try:a,_=self.l.accept()
   except OSError:return
   if not self.enabled:a.close();continue
   try:b=socket.create_connection(('127.0.0.1',self.target))
   except OSError:a.close();continue
   self.connections += [a,b]
   def pipe(src,dst):
    try:
     while data:=src.recv(65536):dst.sendall(data)
    except OSError:pass
    finally:
     with contextlib.suppress(OSError):dst.shutdown(socket.SHUT_WR)
   threading.Thread(target=pipe,args=(a,b),daemon=True).start();threading.Thread(target=pipe,args=(b,a),daemon=True).start()
 def close(self):self.cut();self.l.close()
def tcp_server(handler):
 l=socket.socket();l.bind(('127.0.0.1',0));l.listen()
 def run():
  while True:
   try:s,_=l.accept()
   except OSError:return
   def call(s):
    try:handler(s)
    finally:s.close()
   threading.Thread(target=call,args=(s,),daemon=True).start()
 threading.Thread(target=run,daemon=True).start();return l
def main():
 p=argparse.ArgumentParser();p.add_argument('--binary',required=True);args=p.parse_args();processes=[];logs=[];relays=[];listeners=[]
 with tempfile.TemporaryDirectory(prefix='teapod-dualpath-test-') as tmp:
  d=pathlib.Path(tmp)
  subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem'),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost'],check=True,capture_output=True)
  server=port();client=port();token=secrets.token_hex(32)
  def launch(name,c):
   config=d/(name+'.json');config.write_text(json.dumps(c));config.chmod(0o600);f=open(d/(name+'.log'),'wb');logs.append(f)
   process=subprocess.Popen([args.binary,'--config',str(config)],stdout=f,stderr=f,env={**os.environ,'GORACE':'halt_on_error=1'});processes.append(process);return process
  def echo(s):
   while b:=s.recv(65536):s.sendall(b)
  def half(s):
   h=hashlib.sha256()
   while b:=s.recv(65536):h.update(b)
   s.sendall(h.digest()+b'R'*131072)
  el=tcp_server(echo);hl=tcp_server(half);listeners += [el,hl]
  udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',0));listeners.append(udp)
  def udp_echo():
   try:
    while True:b,a=udp.recvfrom(65535);udp.sendto(b,a)
   except OSError:pass
  threading.Thread(target=udp_echo,daemon=True).start()
  try:
   launch('server',{'role':'server','listen':f'127.0.0.1:{server}','token':token,'cert':str(d/'cert.pem'),'key':str(d/'key.pem'),'allow_private':True})
   a=Relay(server);b=Relay(server);relays += [a,b]
   launch('client',{'role':'proxy','listen':f'127.0.0.1:{client}','token':token,'ca':str(d/'cert.pem'),'target_a':f'127.0.0.1:{a.port}','target_b':f'127.0.0.1:{b.port}','server_a':'localhost','server_b':'localhost','socks_user':'user','socks_password':'local-password-12345','mode':'adaptive'})
   for _ in range(100):
    try:s=auth(client);s.close();break
    except OSError:time.sleep(.1)
   assert auth(client,b'incorrect-password') is None
   payload=bytes(range(256))*8192
   with connect(client,hl.getsockname()[1]) as s:
    s.sendall(payload);s.shutdown(socket.SHUT_WR);assert exact(s,32+131072)==hashlib.sha256(payload).digest()+b'R'*131072;assert s.recv(1)==b''
   print('PASS 2 MiB TCP, SHA-256 and half-close',flush=True)
   errors=[]
   def concurrent(i):
    try:
     with connect(client,el.getsockname()[1]) as s:
      msg=bytes([i])*65536;s.sendall(msg);assert exact(s,len(msg))==msg
    except Exception as e:errors.append(repr(e))
   threads=[threading.Thread(target=concurrent,args=(i,)) for i in range(8)]
   for t in threads:t.start()
   for t in threads:t.join(30);assert not t.is_alive()
   assert not errors,errors;print('PASS 8 simultaneous TCP connections',flush=True)
   with auth(client) as control:
    control.sendall(b'\x05\x03\x00'+addr(0));reply=exact(control,10);assert reply[:2]==b'\x05\x00';up=struct.unpack('!H',reply[8:])[0]
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
     s.settimeout(10)
     for n in [1,1200,16000]:
      msg=secrets.token_bytes(n);packet=b'\x00\x00\x00'+addr(udp.getsockname()[1])+msg;s.sendto(packet,('127.0.0.1',up));assert s.recv(65535)==packet
   print('PASS UDP datagrams preserve boundaries and contents',flush=True)
   def failover():
    time.sleep(1);a.cut();time.sleep(2);a.enabled=True;time.sleep(2);b.cut();time.sleep(2);b.enabled=True
   thread=threading.Thread(target=failover);thread.start()
   with connect(client,el.getsockname()[1]) as s:
    for i in range(200):
     msg=struct.pack('!I',i)*256;s.sendall(msg);assert exact(s,len(msg))==msg;time.sleep(.05)
   thread.join();print('PASS same TCP connection survives cuts of A and B',flush=True)
   a.cut()
   with connect(client,hl.getsockname()[1]) as s:s.sendall(b'one-path');s.shutdown(socket.SHUT_WR);assert exact(s,32)==hashlib.sha256(b'one-path').digest()
   print('PASS new stream with only B available',flush=True)
   for process in processes:assert process.poll() is None
  finally:
   for process in processes:process.terminate()
   for process in processes:
    try:process.wait(5)
    except subprocess.TimeoutExpired:process.kill();process.wait()
   for r in relays:r.close()
   for l in listeners:l.close()
   for f in logs:f.close()
   for f in d.glob('*.log'):
    txt=f.read_text();assert 'DATA RACE' not in txt,txt[-4000:]
    pathlib.Path('/tmp/teapod-dualpath-'+f.name).write_text(txt)
    if any(p.returncode not in [0,-15] for p in processes):print(f.name,txt[-3000:])
if __name__=='__main__':main()
