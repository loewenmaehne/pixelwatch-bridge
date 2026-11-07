"""Virtual Pixel Watch inside the Android emulator's Bluetooth (netsim).

Stage 2 of the bridge: a dual-mode device with the Wear OS RFCOMM service.
- LE: advertises the signal the Google Pixel Watch app filters for during
  setup, so the emulator's pairing dialog lists this device.
- BR/EDR: accepts the classic bonding the app starts after the user picks the
  watch (Secure Simple Pairing, numeric comparison confirmed automatically),
  and logs what the app asks for next (SDP, L2CAP, RFCOMM).

Filter seen in the emulator log (CDM AssociationRequest, app 5.1.0):
manufacturer id 0x00E0 (Google), data byte 1 = 0x13 or 0x14,
data byte 6 = 0x80 or 0x81, all other bytes ignored.

Run: .venv/bin/python fake_watch.py
"""

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

NAME = "Pixel Watch Test"
STATIC_ADDRESS = "F0:F1:F2:F3:F4:F5"  # only used if LE falls back to random
GOOGLE_COMPANY_ID = b"\xe0\x00"  # 0x00E0, little endian
SETUP_PAYLOAD = bytes([0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x80])
CLASS_OF_DEVICE = 0x000704  # major class wearable, minor class wristwatch
KEYS_FILE = pathlib.Path(__file__).with_name("keys.json")
CAPTURE_DIR = pathlib.Path(__file__).with_name("captures")
# RFCOMM service the phone's Wear OS stack connects to on the watch
# (seen in the emulator log: btsock_rfc_connect service_uuid=...).
WEAR_RFCOMM_UUID = UUID("5E8945B0-9525-11E3-A5E2-0800200C9A66")
SDP_HANDLE = 0x00010001


def on_rfcomm_open(dlc: rfcomm.DLC) -> None:
    """Logs everything the phone sends on the Wear OS channel; sends nothing."""
    print(f"rfcomm: channel open {dlc}", flush=True)
    CAPTURE_DIR.mkdir(exist_ok=True)
    capture = CAPTURE_DIR / f"phone_to_watch_{int(time.time())}.bin"

    def on_data(data: bytes) -> None:
        print(f"rfcomm: phone sent {len(data)} bytes: {data[:48].hex()}", flush=True)
        with capture.open("ab") as file:
            file.write(len(data).to_bytes(4, "big") + data)

    dlc.sink = on_data
    dlc.on("close", lambda: print("rfcomm: channel closed", flush=True))


class AutoConfirm(PairingDelegate):
    """Accepts every pairing and prints the code the app should show."""

    def __init__(self) -> None:
        super().__init__(
            io_capability=PairingDelegate.IoCapability.DISPLAY_OUTPUT_AND_YES_NO_INPUT
        )

    async def accept(self) -> bool:
        print("pairing: accept", flush=True)
        return True

    async def confirm(self, auto: bool = False) -> bool:
        print(f"pairing: confirm (auto={auto})", flush=True)
        return True

    async def compare_numbers(self, number: int, digits: int) -> bool:
        print(f"pairing: code {number:0{digits}d}", flush=True)
        return True

    async def display_number(self, number: int, digits: int) -> None:
        print(f"pairing: display {number:0{digits}d}", flush=True)


def on_connection(connection) -> None:
    print(
        f"connected: {connection.peer_address} transport={connection.transport.name}",
        flush=True,
    )
    connection.on("pairing", lambda keys: print(f"paired: {keys}", flush=True))
    connection.on(
        "pairing_failure", lambda reason: print(f"pairing failed: {reason}", flush=True)
    )
    connection.on(
        "connection_encryption_change",
        lambda *args: print(f"encryption: {connection.is_encrypted}", flush=True),
    )
    connection.on(
        "disconnection", lambda reason: print(f"disconnected: {reason}", flush=True)
    )


async def main() -> None:
    config = DeviceConfiguration(
        name=NAME,
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
        channel = rfcomm_server.listen(on_rfcomm_open)
        device.sdp_service_records = {
            SDP_HANDLE: rfcomm.make_service_sdp_records(
                SDP_HANDLE, channel, WEAR_RFCOMM_UUID
            )
        }
        print(f"rfcomm: listening on channel {channel}", flush=True)
        await device.power_on()
        await device.set_discoverable(True)
        await device.set_connectable(True)

        advertising_data = bytes(
            AdvertisingData(
                [
                    (AdvertisingData.FLAGS, bytes([0x02])),  # LE general discoverable
                    (
                        AdvertisingData.MANUFACTURER_SPECIFIC_DATA,
                        GOOGLE_COMPANY_ID + SETUP_PAYLOAD,
                    ),
                ]
            )
        )
        scan_response_data = bytes(
            AdvertisingData([(AdvertisingData.COMPLETE_LOCAL_NAME, NAME.encode())])
        )
        await device.start_advertising(
            own_address_type=OwnAddressType.PUBLIC,
            auto_restart=True,
            advertising_data=advertising_data,
            scan_response_data=scan_response_data,
        )
        print(f"advertising as {NAME} ({device.public_address}, LE and BR/EDR)", flush=True)
        await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.WARNING,
        stream=sys.stdout,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    for name in ("bumble.sdp", "bumble.l2cap", "bumble.rfcomm", "bumble.gatt_server"):
        logging.getLogger(name).setLevel(logging.DEBUG)
    asyncio.run(main())
