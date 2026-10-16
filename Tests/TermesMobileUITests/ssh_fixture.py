"""Loopback SSH fixture with isolated SFTP storage and synthetic monitoring; no shell."""

import os
import posixpath
import re
import socket
import tempfile
import threading
import uuid
import paramiko

key = paramiko.RSAKey.generate(2048)
sample_lock = threading.Lock()
sample_count = 0
storage = tempfile.TemporaryDirectory(prefix='termes-sftp-fixture-')
storage_root = os.path.realpath(storage.name)
with open(os.path.join(storage.name, 'README.txt'), 'w') as document:
    document.write('Termes SFTP fixture\nEdit this UTF-8 document.\n')


class FileHandle(paramiko.SFTPHandle):
    def stat(self):
        try:
            return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def chattr(self, attr):
        try:
            if attr.st_mode is not None:
                os.fchmod(self.readfile.fileno(), attr.st_mode)
            if attr.st_uid is not None and attr.st_gid is not None:
                os.fchown(self.readfile.fileno(), attr.st_uid, attr.st_gid)
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)


class Files(paramiko.SFTPServerInterface):
    def canonicalize(self, path):
        return posixpath.normpath('/' + path.lstrip('/'))

    def local(self, path):
        candidate = os.path.realpath(os.path.join(storage_root, self.canonicalize(path).lstrip('/')))
        if os.path.commonpath([storage_root, candidate]) != storage_root:
            raise PermissionError(13, 'Outside fixture storage')
        return candidate

    def list_folder(self, path):
        try:
            entries = []
            for name in os.listdir(self.local(path)):
                entry = paramiko.SFTPAttributes.from_stat(os.lstat(self.local(posixpath.join(path, name))))
                entry.filename = name
                entries.append(entry)
            return entries
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(os.stat(self.local(path)))
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    lstat = stat

    def open(self, path, flags, attr):
        try:
            descriptor = os.open(self.local(path), flags, attr.st_mode or 0o644)
            mode = 'r+b' if flags & os.O_RDWR else 'wb' if flags & os.O_WRONLY else 'rb'
            stream = os.fdopen(descriptor, mode)
            handle = FileHandle(flags)
            handle.readfile = stream
            handle.writefile = stream
            return handle
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def mutate(self, operation, *paths):
        try:
            operation(*(self.local(path) for path in paths))
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def mkdir(self, path, attr):
        return self.mutate(lambda path: os.mkdir(path, attr.st_mode or 0o755), path)

    def rmdir(self, path):
        return self.mutate(os.rmdir, path)

    def remove(self, path):
        return self.mutate(os.unlink, path)

    def rename(self, source, destination):
        if os.path.exists(self.local(destination)):
            return paramiko.SFTP_FAILURE
        return self.mutate(os.rename, source, destination)

    def posix_rename(self, source, destination):
        return self.mutate(os.replace, source, destination)

    def chattr(self, path, attr):
        try:
            paramiko.SFTPServer.set_file_attr(self.local(path), attr)
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)


class FileServer(paramiko.SFTPServer):
    def _send_server_version(self):
        packet, payload = self._read_packet()
        if packet != paramiko.sftp.CMD_INIT:
            raise paramiko.SSHException('Expected SFTP initialization')
        reply = paramiko.Message()
        reply.add_int(3)
        reply.add_string('posix-rename@openssh.com')
        reply.add_string('1')
        self._send_packet(paramiko.sftp.CMD_VERSION, reply)
        return int.from_bytes(payload[:4], 'big')


def monitoring_response(command):
    """Return the collector's framed protocol, without evaluating its shell script."""
    text = command.decode('utf-8', errors='replace')
    match = re.search(r'TERMESMON1:([A-Za-z0-9-]+):%s', text)
    if match is None or not text.startswith('/bin/sh -c '):
        return None
    nonce = match.group(1)
    try:
        uuid.UUID(nonce)
    except ValueError:
        return None
    names = ('system', 'kernel', 'architecture', 'hostname', 'os', 'boot',
             'cpu', 'memory', 'disks', 'network', 'load', 'uptime')
    if any(f'termes_monitor_emit {name} ' not in text for name in names):
        return None
    if f'TERMESMON1:{nonce}:END' not in text:
        return None

    global sample_count
    with sample_lock:
        sample_count += 1
        index = sample_count
    sections = {
        'system': 'Linux\n',
        'kernel': '6.8.0-termes-fixture\n',
        'architecture': 'aarch64\n',
        'hostname': 'monitor-fixture-host\n',
        'os': 'NAME=TermesFixture\nPRETTY_NAME="Termes Fixture Linux"\n',
        'boot': '11099d6c-f728-4d18-a827-7112d85b46c2\n',
        'cpu': f'cpu  {1000 + index * 30} 0 {500 + index * 20} {20000 + index * 50} 100 0 0 0 0 0\n',
        'memory': 'MemTotal: 4194304 kB\nMemAvailable: 1572864 kB\nSwapTotal: 1048576 kB\nSwapFree: 786432 kB\n',
        'disks': 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 41943040 12582912 29360128 30% /\n',
        'network': (
            'Inter-|   Receive                                                |  Transmit\n'
            ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n'
            f'  eth0: {1000000 + index * 65536} 1000 0 0 0 0 0 0 {500000 + index * 16384} 500 0 0 0 0 0 0\n'
        ),
        'load': '0.25 0.50 0.75 1/128 1024\n',
        'uptime': f'{86400 + index * 5}.00 72000.00\n',
    }
    frames = [f'\x1eTERMESMON1:{nonce}:{name}\n{sections[name]}\n\x1f0\n' for name in names]
    frames.append(f'\x1eTERMESMON1:{nonce}:END\n')
    print('MONITOR SAMPLE', index, flush=True)
    return ''.join(frames).encode()

class Server(paramiko.ServerInterface):
    def __init__(self):
        self.requests = {}
        self.request_lock = threading.Lock()

    def request(self, channel):
        with self.request_lock:
            return self.requests.setdefault(channel.get_id(), {'ready': threading.Event()})

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == 'root' and password == 'test-password' else paramiko.AUTH_FAILED
    def get_allowed_auths(self, username):
        return 'password'
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        print('PTY', width, height, flush=True)
        return True
    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        print('RESIZE', width, height, flush=True)
        return True
    def check_channel_shell_request(self, channel):
        request = self.request(channel)
        request['kind'] = 'shell'
        request['ready'].set()
        return True

    def check_channel_subsystem_request(self, channel, name):
        accepted = super().check_channel_subsystem_request(channel, name)
        if accepted:
            request = self.request(channel)
            request['kind'] = 'sftp'
            request['ready'].set()
        return accepted

    def check_channel_exec_request(self, channel, command):
        request = self.request(channel)
        request['kind'] = 'exec'
        request['command'] = command
        request['ready'].set()
        return True


def serve_channel(channel, server, transport):
    stream_stopped = threading.Event()
    try:
        request = server.request(channel)
        if not request['ready'].wait(20):
            return
        if request['kind'] == 'sftp':
            while transport.is_active() and not channel.closed:
                stream_stopped.wait(0.2)
            return
        if request['kind'] == 'exec':
            response = monitoring_response(request['command'])
            if response is None:
                channel.send_stderr(b'Unsupported fixture command\n')
                channel.send_exit_status(127)
            else:
                channel.sendall(response)
                channel.send_exit_status(0)
            channel.shutdown_write()
            return
        write_lock = threading.Lock()

        def send(data):
            # Interactive echo and the notice stream share one SSH channel.
            with write_lock:
                channel.sendall(data)

        def stream_notice_output():
            try:
                for index in range(1, 31):
                    if stream_stopped.wait(0.5) or channel.closed:
                        return
                    send(f'notice {index:02d}\r\n'.encode())
            except (EOFError, OSError):
                pass  # The test may close the session before the stream finishes.

        send(b'\r\nTermes SSH integration fixture\r\nroot@loopback:~ $ ')
        line = bytearray()
        while transport.is_active():
            data = channel.recv(4096)
            if not data:
                break
            for byte in data:
                if byte in (10, 13):
                    if not line:
                        continue
                    text = line.decode('utf-8', errors='replace')
                    print('INPUT', repr(text), flush=True)
                    send(b'\r\n')
                    if text in ('echo mobile-ssh-ok', 'echo mobile-after-monitor-ok', 'echo mobile-foreground-ok'):
                        send(text.removeprefix('echo ').encode() + b'\r\n')
                    elif text == 'mobile-notice-stream':
                        send(b''.join(f'history {index:03d}\r\n'.encode() for index in range(1, 201)))
                        threading.Thread(target=stream_notice_output, daemon=True).start()
                    send(b'root@loopback:~ $ ')
                    line.clear()
                elif byte in (8, 127):
                    if line:
                        line.pop()
                else:
                    line.append(byte)
                    send(bytes([byte]))
    except Exception as error:
        print(type(error).__name__, str(error), flush=True)
    finally:
        stream_stopped.set()
        channel.close()


def serve(client):
    transport = paramiko.Transport(client)
    try:
        transport.add_server_key(key)
        transport.set_subsystem_handler('sftp', FileServer, Files)
        server = Server()
        transport.start_server(server=server)
        # Monitoring uses its own connection and one exec channel per sample.
        # Keep accepting channels while the interactive transport stays alive.
        while transport.is_active():
            channel = transport.accept(1)
            if channel is not None:
                threading.Thread(target=serve_channel, args=(channel, server, transport), daemon=True).start()
    except Exception as error:
        print(type(error).__name__, str(error), flush=True)
    finally:
        transport.close()

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 37937))
listener.listen(8)
print('READY 37937', flush=True)
while True:
    client, _ = listener.accept()
    threading.Thread(target=serve, args=(client,), daemon=True).start()
