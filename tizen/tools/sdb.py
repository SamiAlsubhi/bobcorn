#!/usr/bin/env python3
"""Install and run Bobcorn on a Samsung TV in Developer Mode, over sdb (Samsung's ADB-like protocol), with no
Tizen Studio. The TV's Developer Mode must have this computer's IP as Host PC IP.

    python3 tizen/tools/sdb.py install 192.168.1.50 build/Bobcorn.wgt
    python3 tizen/tools/sdb.py run 192.168.1.50
    python3 tizen/tools/sdb.py uninstall 192.168.1.50
    python3 tizen/tools/sdb.py shell 192.168.1.50 "0 vd_applist"
"""
import os
import socket
import struct
import sys
import time

PORT = 26101
PACKAGE = 'BobcornApp'
APP_ID = 'BobcornApp.Bobcorn'


def _cmd(name):
    return struct.unpack('<I', name)[0]


CNXN, OPEN, OKAY, WRTE, CLSE = (_cmd(c) for c in (b'CNXN', b'OPEN', b'OKAY', b'WRTE', b'CLSE'))
MAX_DATA = 64 * 1024


class Connection:
    def __init__(self, host, timeout=60):
        self.s = socket.create_connection((host, PORT), timeout=timeout)
        self._send(CNXN, 0x02000000, 0x40000, b'host::\0')
        while self._recv()[0] != CNXN:
            pass
        self.local_id = 0

    def _send(self, c, a0, a1, data=b''):
        self.s.sendall(struct.pack('<6I', c, a0, a1, len(data), sum(data) & 0xffffffff, c ^ 0xffffffff) + data)

    def _exact(self, n):
        b = b''
        while len(b) < n:
            chunk = self.s.recv(n - len(b))
            if not chunk:
                raise EOFError('The TV closed the connection')
            b += chunk
        return b

    def _recv(self):
        c, a0, a1, ln, _, _ = struct.unpack('<6I', self._exact(24))
        return c, a0, a1, self._exact(ln) if ln else b''

    def open(self, service):
        """Opens a stream; returns (local_id, remote_id)."""
        self.local_id += 1
        self._send(OPEN, self.local_id, 0, service.encode() + b'\0')
        while True:
            c, a0, a1, data = self._recv()
            if c == OKAY and a1 == self.local_id:
                return self.local_id, a0
            if c == CLSE:
                raise RuntimeError('The TV refused ' + service.split(':')[0])

    def shell(self, command):
        local, remote = self.open('shell:' + command)
        out = b''
        while True:
            try:
                c, a0, a1, data = self._recv()
            except (EOFError, socket.timeout, OSError):
                break
            if c == WRTE:
                out += data
                try:
                    self._send(OKAY, local, a0)
                except OSError:
                    break
            elif c == CLSE:
                break
        return out.decode(errors='replace')

    def push(self, data, remote_path, mode=0o644):
        """Writes bytes to a file on the TV with the sync protocol (SEND, DATA..., DONE)."""
        local, remote = self.open('sync:')

        def write(payload):
            self._send(WRTE, local, remote, payload)
            while True:   # flow control: each WRTE waits for the TV's OKAY
                c, a0, a1, d = self._recv()
                if c == OKAY:
                    return
                if c == WRTE:
                    self._send(OKAY, local, a0)
                    self.reply = d
                if c == CLSE:
                    raise RuntimeError('The TV closed the transfer')

        self.reply = b''
        spec = ('%s,%d' % (remote_path, mode)).encode()
        write(b'SEND' + struct.pack('<I', len(spec)) + spec)
        for i in range(0, len(data), MAX_DATA):
            chunk = data[i:i + MAX_DATA]
            write(b'DATA' + struct.pack('<I', len(chunk)) + chunk)
        write(b'DONE' + struct.pack('<I', int(time.time())))
        while not self.reply:
            c, a0, a1, d = self._recv()
            if c == WRTE:
                self.reply = d
                self._send(OKAY, local, a0)
        if not self.reply.startswith(b'OKAY'):
            raise RuntimeError('The TV refused the file: ' + self.reply[8:].decode(errors='replace'))
        write(b'QUIT' + struct.pack('<I', 0))

    def close(self):
        self.s.close()


def install(host, wgt):
    with open(wgt, 'rb') as f:
        data = f.read()
    remote = '/home/owner/share/tmp/sdk_tools/%s.wgt' % PACKAGE
    c = Connection(host)
    c.push(data, remote)
    c.close()
    c = Connection(host, timeout=120)
    out = c.shell('0 vd_appinstall %s %s' % (PACKAGE, remote))
    c.close()
    lines = [l for l in out.splitlines() if l.strip() and 'installing[' not in l]
    print('\n'.join(lines))
    if 'install completed' not in out:
        sys.exit('Install failed.')


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, host = sys.argv[1], sys.argv[2]
    if cmd == 'install':
        install(host, sys.argv[3])
    elif cmd == 'run':
        print(Connection(host).shell('0 was_execute %s' % (sys.argv[3] if len(sys.argv) > 3 else APP_ID)))
    elif cmd == 'uninstall':
        print(Connection(host).shell('0 vd_appuninstall %s' % (sys.argv[3] if len(sys.argv) > 3 else PACKAGE)))
    elif cmd == 'shell':
        print(Connection(host).shell(sys.argv[3]))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
