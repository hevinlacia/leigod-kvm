#!/usr/bin/env python3
import asyncio
import os
import socket
import struct

SOCKS_VERSION = 5


def read_addr(data, offset, atyp):
    if atyp == 1:
        if len(data) < offset + 4:
            return None
        return socket.inet_ntoa(data[offset : offset + 4]), offset + 4
    if atyp == 3:
        if len(data) < offset + 1:
            return None
        addrlen = data[offset]
        offset += 1
        if len(data) < offset + addrlen:
            return None
        return data[offset : offset + addrlen].decode(), offset + addrlen
    if atyp == 4:
        if len(data) < offset + 16:
            return None
        return socket.inet_ntop(
            socket.AF_INET6, data[offset : offset + 16]
        ), offset + 16
    return None


def pack_addr(addr, port):
    try:
        return b"\x01" + socket.inet_aton(addr) + struct.pack(">H", port)
    except OSError:
        pass

    try:
        return (
            b"\x04" + socket.inet_pton(socket.AF_INET6, addr) + struct.pack(">H", port)
        )
    except OSError:
        encoded = addr.encode()
        if len(encoded) > 255:
            raise ValueError("domain too long for SOCKS5")
        return b"\x03" + bytes([len(encoded)]) + encoded + struct.pack(">H", port)


def pack_reply(status, addr="0.0.0.0", port=0):
    return struct.pack("BBB", SOCKS_VERSION, status, 0) + pack_addr(addr, port)


def parse_udp_packet(data):
    if len(data) < 4 or data[0:2] != b"\x00\x00" or data[2] != 0:
        return None

    atyp = data[3]
    parsed = read_addr(data, 4, atyp)
    if not parsed:
        return None
    addr, offset = parsed
    if len(data) < offset + 2:
        return None
    port = struct.unpack(">H", data[offset : offset + 2])[0]
    return addr, port, data[offset + 2 :]


class UDPRelay(asyncio.DatagramProtocol):
    def __init__(self):
        self.transport = None
        self.remote_to_client = {}

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        parsed = parse_udp_packet(data)
        if parsed:
            target_addr, target_port, payload = parsed
            asyncio.create_task(
                self.forward_to_remote(target_addr, target_port, payload, addr)
            )
            return

        client_addr = self.remote_to_client.get(addr)
        if client_addr:
            try:
                packet = b"\x00\x00\x00" + pack_addr(addr[0], addr[1]) + data
                self.transport.sendto(packet, client_addr)
            except Exception:
                pass

    async def forward_to_remote(self, target_addr, target_port, payload, client_addr):
        try:
            loop = asyncio.get_running_loop()
            infos = await loop.getaddrinfo(
                target_addr,
                target_port,
                family=socket.AF_UNSPEC,
                type=socket.SOCK_DGRAM,
            )
            remote = infos[0][4]
            self.remote_to_client[remote] = client_addr
            self.transport.sendto(payload, remote)
        except Exception:
            pass


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle_client(reader, writer):
    remote_writer = None
    try:
        data = await reader.readexactly(2)
        ver, nmethods = data
        if ver != SOCKS_VERSION:
            return
        await reader.readexactly(nmethods)
        writer.write(struct.pack("BB", SOCKS_VERSION, 0))
        await writer.drain()

        header = await reader.readexactly(4)
        ver, cmd, _, atyp = header
        if ver != SOCKS_VERSION or cmd not in (1, 3):
            writer.write(struct.pack("BBBB", SOCKS_VERSION, 7, 0, 1))
            await writer.drain()
            return

        if atyp == 1:
            addr = socket.inet_ntoa(await reader.readexactly(4))
        elif atyp == 3:
            addrlen = (await reader.readexactly(1))[0]
            addr = (await reader.readexactly(addrlen)).decode()
        elif atyp == 4:
            addr = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
        else:
            return

        port = struct.unpack(">H", await reader.readexactly(2))[0]

        if cmd == 3:
            loop = asyncio.get_running_loop()
            udp_bind = os.environ.get("SOCKS5_UDP_BIND", "0.0.0.0")
            transport, _ = await loop.create_datagram_endpoint(
                lambda: UDPRelay(),
                local_addr=(udp_bind, 0),
            )
            udp_port = transport.get_extra_info("sockname")[1]
            tcp_bind = writer.get_extra_info("sockname") or ("0.0.0.0", 0)
            reply_addr = (
                tcp_bind[0] if tcp_bind[0] not in ("::", "0.0.0.0") else "0.0.0.0"
            )
            writer.write(pack_reply(0, reply_addr, udp_port))
            await writer.drain()
            try:
                await reader.read()
            finally:
                transport.close()
            return

        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(addr, port), timeout=15
            )
        except Exception:
            writer.write(pack_reply(5))
            await writer.drain()
            return

        bind = remote_writer.get_extra_info("sockname") or ("0.0.0.0", 0)
        writer.write(pack_reply(0, bind[0], bind[1]))
        await writer.drain()

        await asyncio.gather(
            pipe(reader, remote_writer),
            pipe(remote_reader, writer),
            return_exceptions=True,
        )
    except Exception:
        pass
    finally:
        for w in (writer, remote_writer):
            if w:
                try:
                    w.close()
                except Exception:
                    pass


async def main():
    addr = os.environ.get("SOCKS5_BIND", "0.0.0.0")
    port = int(os.environ.get("SOCKS5_PORT", "1080"))
    server = await asyncio.start_server(handle_client, addr, port, backlog=128)
    print(f"SOCKS5 TCP/UDP listening on {addr}:{port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
