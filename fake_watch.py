"""Watch side of the bridge inside the Android emulator's Bluetooth (netsim).

A dual-mode Bumble device the Google Pixel Watch app treats as a watch:
- LE: advertises the signal the app filters for during setup, so the
  emulator's pairing dialog lists this device.
- BR/EDR: accepts the classic bonding the app starts after the user picks the
  watch (Secure Simple Pairing, numeric comparison confirmed automatically)
  and offers the Wear OS RFCOMM service.
- With --relay PORT the Wear OS channel is passed through, byte for byte, to
  the Mac helper (mac/run.sh bridge <watch address> PORT), which holds the
  RFCOMM channel to the real watch. Without --relay it only records what the
  phone sends.

Filter seen in the emulator log (CDM AssociationRequest, app 5.1.0):
manufacturer id 0x00E0 (Google), data byte 1 = 0x13 or 0x14,
data byte 6 = 0x80 or 0x81, all other bytes ignored.

Run: .venv/bin/python fake_watch.py [--relay 7700] [--payload 00140000000080]
"""

import argparse
import asyncio
import logging
import pathlib
import sys
import time

from bumble import rfcomm
from bumble.core import UUID, AdvertisingData
from bumble.device import Device, DeviceConfiguration
from bumble.hci import Address, OwnAddressType
from bumble.keys import JsonKeyStore
from bumble.pairing import PairingConfig, PairingDelegate
from bumble.transport import open_transport

DEFAULT_NAME = "Pixel Watch Test"
DEFAULT_PAYLOAD = "00140000000080"  # manufacturer data after the company id
STATIC_ADDRESS = "F0:F1:F2:F3:F4:F5"  # only used if LE falls back to random
GOOGLE_COMPANY_ID = b"\xe0\x00"  # 0x00E0, little endian
CLASS_OF_DEVICE = 0x000704  # major class wearable, minor class wristwatch
KEYS_FILE = pathlib.Path(__file__).with_name("keys.json")
CAPTURE_DIR = pathlib.Path(__file__).with_name("captures")
# RFCOMM service the phone's Wear OS stack connects to on the watch
# (seen in the emulator log: btsock_rfc_connect service_uuid=...).
WEAR_RFCOMM_UUID = UUID("5E8945B0-9525-11E3-A5E2-0800200C9A66")
SDP_HANDLE = 0x00010001


def say(message: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {message}", flush=True)


class Capture:
    """Appends each chunk as <direction byte><4-byte length><data>."""

    def __init__(self) -> None:
        CAPTURE_DIR.mkdir(exist_ok=True)
        self.path = CAPTURE_DIR / f"session_{int(time.time())}.bin"

    def write(self, direction: str, data: bytes) -> None:
        with self.path.open("ab") as file:
            file.write(direction.encode()[:1] + len(data).to_bytes(4, "big") + data)


def make_rfcomm_handler(relay_port: int | None):
    def on_rfcomm_open(dlc: rfcomm.DLC) -> None:
        say(f"rfcomm: phone opened the Wear OS channel ({dlc})")
        capture = Capture()
        dlc.on("close", lambda: say("rfcomm: channel closed"))
        if relay_port is None:

            def record_only(data: bytes) -> None:
                say(f"rfcomm: phone sent {len(data)} bytes {data[:24].hex()}")
                capture.write("p", data)

            dlc.sink = record_only
            return
        asyncio.get_running_loop().create_task(relay(dlc, relay_port, capture))

    return on_rfcomm_open


async def relay(dlc: rfcomm.DLC, port: int, capture: Capture) -> None:
    try:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
    except OSError as error:
        say(f"relay: Mac helper not reachable on port {port}: {error}")
        return
    say(f"relay: connected to the Mac helper on port {port}")

    def phone_to_watch(data: bytes) -> None:
        say(f"relay: phone -> watch {len(data)} bytes {data[:24].hex()}")
        capture.write("p", data)
        writer.write(data)

    dlc.sink = phone_to_watch  # queued phone data is flushed here
    try:
        while data := await reader.read(65536):
            say(f"relay: watch -> phone {len(data)} bytes {data[:24].hex()}")
            capture.write("w", data)
            dlc.write(data)
    finally:
        say("relay: Mac helper closed the connection")
        writer.close()


class AutoConfirm(PairingDelegate):
    """Accepts every pairing and prints the code the app should show."""

    def __init__(self) -> None:
        super().__init__(
            io_capability=PairingDelegate.IoCapability.DISPLAY_OUTPUT_AND_YES_NO_INPUT
        )

    async def accept(self) -> bool:
        say("pairing: accept")
        return True

    async def confirm(self, auto: bool = False) -> bool:
        say(f"pairing: confirm (auto={auto})")
        return True

    async def compare_numbers(self, number: int, digits: int) -> bool:
        say(f"pairing: code {number:0{digits}d}")
        return True

    async def display_number(self, number: int, digits: int) -> None:
        say(f"pairing: display {number:0{digits}d}")


def on_connection(connection) -> None:
    say(f"connected: {connection.peer_address} transport={connection.transport.name}")
    connection.on("pairing", lambda keys: say("pairing: done"))
    connection.on("pairing_failure", lambda reason: say(f"pairing: failed {reason}"))
    connection.on(
        "connection_encryption_change",
        lambda *args: say(f"encryption: {connection.is_encrypted}"),
    )
    connection.on("disconnection", lambda reason: say(f"disconnected: {reason}"))


async def main(args: argparse.Namespace) -> None:
    payload = bytes.fromhex(args.payload)
    config = DeviceConfiguration(
        name=args.name,
        address=Address(STATIC_ADDRESS),
        class_of_device=CLASS_OF_DEVICE,
        classic_enabled=True,
        le_enabled=True,
        le_simultaneous_enabled=True,
        io_capability=PairingDelegate.IoCapability.DISPLAY_OUTPUT_AND_YES_NO_INPUT,
    )
    async with await open_transport("android-netsim") as (hci_source, hci_sink):
        device = Device.from_config_with_hci(config, hci_source, hci_sink)
        device.keystore = JsonKeyStore(filename=str(KEYS_FILE))
        device.pairing_config_factory = lambda connection: PairingConfig(
            sc=True, mitm=True, bonding=True, delegate=AutoConfirm()
        )
        device.on("connection", on_connection)
        rfcomm_server = rfcomm.Server(device)
        channel = rfcomm_server.listen(make_rfcomm_handler(args.relay))
        device.sdp_service_records = {
            SDP_HANDLE: rfcomm.make_service_sdp_records(
                SDP_HANDLE, channel, WEAR_RFCOMM_UUID
            )
        }
        await device.power_on()
        await device.set_discoverable(True)
        await device.set_connectable(True)

        advertising_data = bytes(
            AdvertisingData(
                [
                    (AdvertisingData.FLAGS, bytes([0x02])),  # LE general discoverable
                    (
                        AdvertisingData.MANUFACTURER_SPECIFIC_DATA,
                        GOOGLE_COMPANY_ID + payload,
                    ),
                ]
            )
        )
        scan_response_data = bytes(
            AdvertisingData([(AdvertisingData.COMPLETE_LOCAL_NAME, args.name.encode())])
        )
        await device.start_advertising(
            own_address_type=OwnAddressType.PUBLIC,
            auto_restart=True,
            advertising_data=advertising_data,
            scan_response_data=scan_response_data,
        )
        mode = f"relay to port {args.relay}" if args.relay else "record only"
        say(
            f"advertising as {args.name} ({device.public_address}), "
            f"RFCOMM channel {channel}, {mode}"
        )
        await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--relay", type=int, help="TCP port of the Mac helper")
    parser.add_argument("--payload", default=DEFAULT_PAYLOAD, help="manufacturer data hex")
    parser.add_argument("--name", default=DEFAULT_NAME)
    parser.add_argument("--verbose", action="store_true", help="Bumble debug logs")
    arguments = parser.parse_args()
    logging.basicConfig(
        level=logging.WARNING,
        stream=sys.stdout,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    if arguments.verbose:
        for name in ("bumble.sdp", "bumble.l2cap", "bumble.rfcomm"):
            logging.getLogger(name).setLevel(logging.DEBUG)
    asyncio.run(main(arguments))
