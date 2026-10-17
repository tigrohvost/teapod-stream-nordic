#!/usr/bin/env python3
"""Exercise generated configs against owned loopback servers; no external traffic."""
import argparse
import contextlib
import copy
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import re
import subprocess
import tempfile
import threading
import time


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def field(n, value):
    def varint(v):
        b = bytearray()
        while v > 127:
            b.append((v & 127) | 128)
            v >>= 7
        return b + bytes([v])
    return bytes([(n << 3) | 2]) + varint(len(value)) + value


class Endpoint(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.client_address[0].encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def receive(s, n):
    data = b''
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise ConnectionError('Unexpected EOF')
        data += chunk
    return data


def request(socks, host, target):
    with socket.create_connection(('127.0.0.1', socks), timeout=2) as s:
        s.settimeout(3)
        s.sendall(b'\x05\x01\x00')
        if receive(s, 2) != b'\x05\x00':
            raise ConnectionError('SOCKS greeting')
        name = host.encode()
        s.sendall(b'\x05\x01\x00\x03' + bytes([len(name)]) + name + target.to_bytes(2, 'big'))
        head = receive(s, 4)
        if head[1] != 0:
            raise ConnectionError('SOCKS CONNECT rejected')
        receive(s, {1: 6, 4: 18}[head[3]])
        s.sendall(f'GET / HTTP/1.0\r\nHost: {host}\r\n\r\n'.encode())
        response = b''
        while chunk := s.recv(4096):
            response += chunk
            if b'\r\n\r\n' in response:
                headers, body = response.split(b'\r\n\r\n', 1)
                length = re.search(rb'Content-Length: (\d+)', headers, re.I)
                if length and len(body) >= int(length[1]):
                    return body[:int(length[1])].decode()
        return response.split(b'\r\n\r\n', 1)[1].decode()


@contextlib.contextmanager
def core(binary, config, directory, name, listen, env):
    path = directory / (name + '.json')
    path.write_text(json.dumps(config))
    with (directory / (name + '.log')).open('w+') as log:
        process = subprocess.Popen([binary, 'run', '-c', str(path)], stdout=log, stderr=log, env=env)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    log.seek(0)
                    raise AssertionError(f'{name} failed to load: {log.read()}')
                try:
                    with socket.create_connection(('127.0.0.1', listen), .1):
                        break
                except OSError:
                    time.sleep(.025)
            else:
                raise AssertionError(f'{name} did not listen')
            yield
        finally:
            process.terminate()
            try: process.wait(5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xray', required=True)
    parser.add_argument('--fixtures', required=True)
    args = parser.parse_args()
    fixtures = json.loads(Path(args.fixtures).read_text())
    version = subprocess.check_output([args.xray, 'version'], text=True).splitlines()[0]
    with tempfile.TemporaryDirectory(prefix='teapod-core-fixture-') as temp:
        root = Path(temp)
        # A private CA trusted only by the spawned test process. No OS trust-store changes.
        def openssl(*arguments):
            subprocess.run(['openssl', *arguments], cwd=root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.crt', '-days', '1', '-subj', '/CN=Teapod Test CA')
        openssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'leaf.key', '-out', 'leaf.csr', '-subj', '/CN=localhost')
        (root / 'leaf.ext').write_text('subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
        openssl('x509', '-req', '-in', 'leaf.csr', '-CA', 'ca.crt', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'leaf.crt', '-days', '1', '-extfile', 'leaf.ext')
        der = subprocess.check_output(['openssl', 'x509', '-in', str(root / 'leaf.crt'), '-outform', 'DER'])
        pin = hashlib.sha256(der).hexdigest()
        (root / 'geoip.dat').write_bytes(field(1, field(1, b'TEST') + field(2, field(1, bytes([127, 0, 0, 1])) + bytes([16, 32]))))
        (root / 'geosite.dat').write_bytes(field(1, field(1, b'TEST') + field(2, bytes([8, 2]) + field(2, b'selected.test'))))
        env = {**os.environ, 'XRAY_LOCATION_ASSET': str(root), 'SSL_CERT_FILE': str(root / 'ca.crt')}
        hosts = {'selected.test': '127.0.0.1', 'gosuslugi.ru': '127.0.0.1', 'other.test': '127.0.0.4'}
        endpoint = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
        other = http.server.ThreadingHTTPServer(('127.0.0.4', endpoint.server_port), Endpoint)
        for httpd in [endpoint, other]:
            threading.Thread(target=httpd.serve_forever, daemon=True).start()
        server_port = port()
        server = {'log': {'loglevel': 'debug'}, 'dns': {'hosts': hosts, 'servers': ['localhost']},
                  'inbounds': [{'listen': '127.0.0.1', 'port': server_port, 'protocol': 'trojan',
                                'settings': {'clients': [{'password': 'fixture-secret'}]},
                                'streamSettings': {'network': 'tcp', 'security': 'tls', 'tlsSettings': {
                                    'certificates': [{'certificateFile': str(root / 'leaf.crt'), 'keyFile': str(root / 'leaf.key')}]
                                }}}],
                  'outbounds': [{'protocol': 'freedom', 'sendThrough': '127.0.0.3', 'settings': {
                      'domainStrategy': 'UseIP', 'finalRules': [{'action': 'allow', 'network': 'tcp',
                          'ip': ['127.0.0.0/8'], 'port': str(endpoint.server_port)}]}}]}
        def prepare(config):
            config = copy.deepcopy(config)
            socks_port = port()
            config['inbounds'][0]['port'] = socks_port
            config['dns']['hosts'] = hosts
            config['dns']['servers'] = ['localhost']
            for out in config['outbounds']:
                if out['protocol'] == 'trojan':
                    out['settings']['servers'][0]['port'] = server_port
                    assert out['streamSettings']['tlsSettings']['pinnedPeerCertSha256'] == '01' * 32
                    out['streamSettings']['tlsSettings']['pinnedPeerCertSha256'] = pin
                elif out['protocol'] == 'freedom':
                    out['sendThrough'] = '127.0.0.2'
                    out['settings'] = {'domainStrategy': 'UseIP'}
            return config, socks_port
        try:
            with core(args.xray, server, root, 'server', server_port, env):
                for fixture in fixtures:
                    config, socks_port = prepare(fixture['config'])
                    with core(args.xray, config, root, 'client', socks_port, env):
                        for domain, expected in [(fixture['selected'], fixture['expectedSelected']), ('other.test', fixture['expectedOther'])]:
                            try: actual = request(socks_port, domain, endpoint.server_port)
                            except Exception as exc:
                                raise AssertionError(f'{fixture["name"]} {domain}: {exc}\n{(root / "client.log").read_text()}\n{(root / "server.log").read_text()}') from exc
                            assert actual == expected, (fixture['name'], domain, actual, expected)
                # A CA-valid certificate works without pin; mismatch must still fail.
                for mode in ['ca-valid-no-pin', 'matching-pin', 'mismatching-pin']:
                    config, socks_port = prepare(fixtures[0]['config'])
                    tls = config['outbounds'][0]['streamSettings']['tlsSettings']
                    if mode == 'ca-valid-no-pin': tls.pop('pinnedPeerCertSha256')
                    if mode == 'mismatching-pin': tls['pinnedPeerCertSha256'] = '00' * 32
                    with core(args.xray, config, root, 'client', socks_port, env):
                        try: actual = request(socks_port, 'selected.test', endpoint.server_port)
                        except (OSError, IndexError, ConnectionError): actual = None
                        assert (actual == '127.0.0.3') == (mode != 'mismatching-pin'), (mode, actual)
            print(json.dumps({'core': version, 'routing_fixtures': len(fixtures), 'observed_requests': len(fixtures) * 2,
                              'tls': ['CA valid control', 'pin match accepted', 'pin mismatch rejected'], 'network': 'loopback only'}))
        finally:
            for httpd in [endpoint, other]:
                httpd.shutdown()
                httpd.server_close()

if __name__ == '__main__': main()
