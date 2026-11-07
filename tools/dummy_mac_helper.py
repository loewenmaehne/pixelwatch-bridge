"""Stand-in for `mac/run.sh bridge` while the real watch is not there.

Listens on 127.0.0.1:<port> like the Mac helper and prints what arrives from
the phone. It never answers, so the phone waits for the watch's reply.

Run: .venv/bin/python tools/dummy_mac_helper.py 7700
"""

import asyncio
import sys
import time


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    print(f"{time.strftime('%H:%M:%S')} dummy: relay connected", flush=True)
    while data := await reader.read(65536):
        print(
            f"{time.strftime('%H:%M:%S')} dummy: got {len(data)} bytes {data[:24].hex()}",
            flush=True,
        )
    print(f"{time.strftime('%H:%M:%S')} dummy: relay closed", flush=True)
    writer.close()


async def main(port: int) -> None:
    server = await asyncio.start_server(handle, "127.0.0.1", port)
    print(f"{time.strftime('%H:%M:%S')} dummy: listening on {port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 7700))
