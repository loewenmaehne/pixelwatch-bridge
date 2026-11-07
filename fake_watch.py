"""Virtual Pixel Watch inside the Android emulator's Bluetooth (netsim).

Step 1 of the bridge: advertise the BLE signal the Google Pixel Watch app
filters for during setup, so the emulator's pairing dialog lists this device.

Filter seen in the emulator log (CDM AssociationRequest, app 5.1.0):
manufacturer id 0x00E0 (Google), data byte 1 = 0x13 or 0x14,
data byte 6 = 0x80 or 0x81, all other bytes ignored.

Run: .venv/bin/python fake_watch.py
"""

import asyncio
import logging
import sys

from bumble.core import AdvertisingData
from bumble.device import Device
from bumble.hci import Address
from bumble.transport import open_transport

NAME = "Pixel Watch Test"
ADDRESS = "F0:F1:F2:F3:F4:F5"  # static random address
GOOGLE_COMPANY_ID = b"\xe0\x00"  # 0x00E0, little endian
SETUP_PAYLOAD = bytes([0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x80])


async def main() -> None:
    async with await open_transport("android-netsim") as (hci_source, hci_sink):
        device = Device.with_hci(NAME, Address(ADDRESS), hci_source, hci_sink)
        device.on("connection", lambda c: print(f"connected: {c}", flush=True))
        device.on("disconnection", lambda r: print(f"disconnected: {r}", flush=True))
        await device.power_on()

        advertising_data = bytes(
            AdvertisingData(
                [
                    (AdvertisingData.FLAGS, bytes([0x06])),
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
            auto_restart=True,
            advertising_data=advertising_data,
            scan_response_data=scan_response_data,
        )
        print(f"advertising as {NAME} ({ADDRESS})", flush=True)
        await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
    asyncio.run(main())
