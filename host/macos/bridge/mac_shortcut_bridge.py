#!/usr/bin/env python3
"""Bridge AI Passport wireless/USB microphone audio to macOS."""

from __future__ import annotations

import argparse
import array
import ctypes
import glob
import json
import os
import queue
import select
import signal
import struct
import sys
import termios
import time
import tty
import wave
from datetime import date, datetime

from configuration import DEFAULT_CONFIG, load_config
from providers import MetricMonitor, load_provider


KEY_RETURN = 0x24
KEY_ESCAPE = 0x35
KEY_DELETE = 0x33
KEY_LEFT_COMMAND = 0x37
KEY_LEFT_CONTROL = 0x3B
CG_HID_EVENT_TAP = 0
CG_EVENT_FLAG_MASK_CONTROL = 1 << 18
CG_EVENT_FLAG_MASK_COMMAND = 1 << 20
CG_EVENT_SOURCE_STATE_HID_SYSTEM = 1
AUDIO_MAGIC = bytes((0xA5, ord("A"), ord("I"), ord("P"), ord("C"), ord("M"), ord("1"), 0x5A))
AUDIO_HEADER = struct.Struct("<8sHH")
AUDIO_SAMPLE_RATE = 16000
AUDIO_OUTPUT_SAMPLE_RATE = 48000
AUDIO_OUTPUT_CHANNELS = 2
AUDIO_FRAME_SAMPLES = 320
BLE_HID_USAGE_PAGE = 0xFF00
BLE_AUDIO_REPORT_ID = 2
BLE_HOST_STATUS_REPORT_ID = 3
BLE_SHORTCUT_KEYMAP_MARKER = ord("K")
BLE_AUDIO_REPORT_BYTES = 176
BLE_AUDIO_PACKET_HEADER_BYTES = 4
BLE_AUDIO_PACKET_START = 1
BLE_AUDIO_PACKET_PCM = 2
BLE_AUDIO_PACKET_STOP = 3
METRIC_REMAINING_UNKNOWN = 0x7F
METRIC_DAILY_UNIT = 10_000_000
METRIC_DAILY_UNKNOWN = 0x7F
HOST_STATUS_EPOCH = date(2020, 1, 1)
HID_MODIFIERS = {
    "left_control": 0x01,
    "left_shift": 0x02,
    "left_option": 0x04,
    "left_command": 0x08,
    "right_control": 0x10,
    "right_shift": 0x20,
    "right_option": 0x40,
    "right_command": 0x80,
}
HID_KEYS = {
    "return": 0x28,
    "escape": 0x29,
    "delete": 0x2A,
    "space": 0x2C,
}
BRIDGE_STATUS_PATH = os.path.expanduser(
    "~/Library/Application Support/AI Passport Bridge/status.json"
)


def write_bridge_status(state: str, detail: str) -> None:
    """Atomically publish bridge state for the macOS menu-bar helper."""
    directory = os.path.dirname(BRIDGE_STATUS_PATH)
    os.makedirs(directory, exist_ok=True)
    temporary = f"{BRIDGE_STATUS_PATH}.{os.getpid()}.tmp"
    payload = {
        "state": state,
        "detail": detail,
        "pid": os.getpid(),
        "updated_at": time.time(),
    }
    with open(temporary, "w", encoding="utf-8") as status_file:
        json.dump(payload, status_file, ensure_ascii=False)
    os.replace(temporary, BRIDGE_STATUS_PATH)


class Pcm16MonoToStereo48k:
    """Convert 8/16 kHz mono PCM to BlackHole's 48 kHz stereo."""

    def __init__(self, input_rate: int = AUDIO_SAMPLE_RATE) -> None:
        if input_rate not in (8000, 16000):
            raise ValueError(f"Unsupported input sample rate: {input_rate}")
        self._factor = AUDIO_OUTPUT_SAMPLE_RATE // input_rate
        self._previous: int | None = None

    def reset(self) -> None:
        self._previous = None

    def convert(self, pcm: bytes) -> bytes:
        if len(pcm) % 2:
            raise ValueError("PCM16 payload must contain whole samples")

        samples = array.array("h")
        samples.frombytes(pcm)
        if sys.byteorder != "little":
            samples.byteswap()
        if not samples:
            return b""

        previous = samples[0] if self._previous is None else self._previous
        stereo = array.array("h")
        for sample in samples:
            # Both supported rates divide 48 kHz exactly. Interpolate between
            # adjacent samples and duplicate each value into left/right.
            for step in range(self._factor):
                value = (
                    (self._factor - step) * previous + step * sample
                ) // self._factor
                stereo.extend((value, value))
            previous = sample
        self._previous = previous
        if sys.byteorder != "little":
            stereo.byteswap()
        return stereo.tobytes()


def pcm_s8_to_pcm16(pcm: bytes) -> bytes:
    """Expand signed 8-bit PCM to little-endian signed 16-bit PCM."""
    source = array.array("b")
    source.frombytes(pcm)
    expanded = array.array("h", (sample << 8 for sample in source))
    if sys.byteorder != "little":
        expanded.byteswap()
    return expanded.tobytes()


class MacAudioSink:
    """Continuously expose queued board audio through a Core Audio output."""

    def __init__(self, device_name: str) -> None:
        try:
            import sounddevice as sd
        except ImportError as exc:
            raise RuntimeError(
                "sounddevice is missing; install host/macos/bridge/requirements.txt"
            ) from exc

        matches = [
            (index, device)
            for index, device in enumerate(sd.query_devices())
            if device_name.casefold() in str(device["name"]).casefold()
            and int(device["max_output_channels"]) >= AUDIO_OUTPUT_CHANNELS
        ]
        if not matches:
            raise RuntimeError(f"No Core Audio output device matching {device_name!r}")

        self._sd = sd
        self._device_index, device = matches[0]
        self._resampler = Pcm16MonoToStereo48k()
        self._blocks: queue.Queue[bytes] = queue.Queue(maxsize=8)
        self._block_bytes = 960 * AUDIO_OUTPUT_CHANNELS * 2
        self._silence = bytes(self._block_bytes)
        self._pending = bytearray()
        self._reported_status = False
        self._stream = sd.RawOutputStream(
            samplerate=AUDIO_OUTPUT_SAMPLE_RATE,
            blocksize=960,
            device=self._device_index,
            channels=AUDIO_OUTPUT_CHANNELS,
            dtype="int16",
            latency="low",
            callback=self._callback,
        )
        self._stream.start()
        print(
            f"Audio output ON: {device['name']} "
            f"({AUDIO_OUTPUT_SAMPLE_RATE} Hz, stereo)",
            flush=True,
        )

    def _callback(self, outdata: object, frames: int, _time: object, status: object) -> None:
        if status and not self._reported_status:
            print(f"WARN Core Audio status: {status}", flush=True)
            self._reported_status = True
        expected_bytes = frames * AUDIO_OUTPUT_CHANNELS * 2
        try:
            block = self._blocks.get_nowait()
        except queue.Empty:
            block = self._silence
        if len(block) != expected_bytes:
            block = block[:expected_bytes].ljust(expected_bytes, b"\0")
        outdata[:] = block

    def start_segment(self, input_rate: int = AUDIO_SAMPLE_RATE) -> None:
        self._resampler = Pcm16MonoToStereo48k(input_rate)
        self._pending.clear()
        while True:
            try:
                self._blocks.get_nowait()
            except queue.Empty:
                break

    def write(self, pcm: bytes) -> None:
        self._pending.extend(self._resampler.convert(pcm))
        while len(self._pending) >= self._block_bytes:
            block = bytes(self._pending[: self._block_bytes])
            del self._pending[: self._block_bytes]
            try:
                self._blocks.put_nowait(block)
            except queue.Full:
                self._blocks.get_nowait()
                self._blocks.put_nowait(block)
                print("WARN audio queue full; dropped oldest frame", flush=True)

    def close(self) -> None:
        self._stream.stop()
        self._stream.close()


class MacKeyInjector:
    """Post physical-key-style events through CoreGraphics.

    macOS requires Accessibility permission for the terminal or process running
    this bridge. Modifiers are always released during shutdown.
    """

    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled
        self._voice_down = False
        self._event_source = None
        self._app_services = None
        if not enabled:
            return
        self._app_services = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/ApplicationServices.framework/"
            "ApplicationServices"
        )
        self._app_services.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        self._app_services.CGEventCreateKeyboardEvent.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint16,
            ctypes.c_bool,
        ]
        self._app_services.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        self._app_services.CGEventSourceCreate.restype = ctypes.c_void_p
        self._app_services.CGEventSourceCreate.argtypes = [ctypes.c_int32]
        self._app_services.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._app_services.CFRelease.argtypes = [ctypes.c_void_p]
        self._app_services.AXIsProcessTrusted.restype = ctypes.c_bool
        if not self._app_services.AXIsProcessTrusted():
            raise RuntimeError(
                "Accessibility permission is required for real key injection"
            )
        self._event_source = self._app_services.CGEventSourceCreate(
            CG_EVENT_SOURCE_STATE_HID_SYSTEM
        )
        if not self._event_source:
            raise RuntimeError("CGEventSourceCreate failed")

    def _post(self, key_code: int, down: bool, flags: int = 0) -> None:
        if not self.enabled:
            return
        event = self._app_services.CGEventCreateKeyboardEvent(
            self._event_source, key_code, down
        )
        if not event:
            raise RuntimeError("CGEventCreateKeyboardEvent failed")
        self._app_services.CGEventSetFlags(event, flags)
        self._app_services.CGEventPost(CG_HID_EVENT_TAP, event)
        self._app_services.CFRelease(event)

    def voice_down(self) -> None:
        if self._voice_down:
            return
        print("ACTION voice shortcut DOWN (left Control + left Command)", flush=True)
        self._post(KEY_LEFT_CONTROL, True, CG_EVENT_FLAG_MASK_CONTROL)
        self._post(
            KEY_LEFT_COMMAND,
            True,
            CG_EVENT_FLAG_MASK_CONTROL | CG_EVENT_FLAG_MASK_COMMAND,
        )
        self._voice_down = True

    def voice_up(self) -> None:
        if not self._voice_down:
            return
        print("ACTION voice shortcut UP", flush=True)
        self._post(KEY_LEFT_COMMAND, False, CG_EVENT_FLAG_MASK_CONTROL)
        self._post(KEY_LEFT_CONTROL, False)
        self._voice_down = False

    def tap(self, key_code: int, name: str, flags: int = 0) -> None:
        print(f"ACTION tap {name}", flush=True)
        self._post(key_code, True, flags)
        self._post(key_code, False, flags)

    def close(self) -> None:
        self.voice_up()
        if self._event_source:
            self._app_services.CFRelease(self._event_source)
            self._event_source = None


def discover_port(explicit: str | None) -> str:
    if explicit:
        return explicit
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        raise RuntimeError("No /dev/cu.usbmodem* device found")
    return ports[-1]


def open_serial(port: str) -> int:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    attrs[2] |= termios.CLOCAL | termios.CREAD
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def send_host_status(fd: int) -> None:
    now = datetime.now().strftime("%H:%M")
    os.write(fd, f"HOST:HELLO\nHOST:TIME,{now}\n".encode())


def hid_host_status_report(
    audio_ready: bool,
    remaining_percent: int | None = None,
    daily_total: int | None = None,
    now: datetime | None = None,
) -> bytes:
    current = now or datetime.now()
    remaining = (
        METRIC_REMAINING_UNKNOWN
        if remaining_percent is None
        else max(0, min(100, remaining_percent))
    )
    daily_bucket = (
        METRIC_DAILY_UNKNOWN
        if daily_total is None
        else min(126, max(0, round(daily_total / METRIC_DAILY_UNIT)))
    )
    days = max(0, min(0x3FFF, (current.date() - HOST_STATUS_EPOCH).days))
    minutes = current.hour * 60 + current.minute
    packed = (
        days
        | (minutes << 14)
        | (int(audio_ready) << 25)
        | (remaining << 26)
        | (daily_bucket << 33)
    )
    # Keep the existing 8-byte HID Output payload so bonded Macs do not need
    # to rediscover a changed report descriptor. "AD" identifies this packed
    # date-aware format; firmware still accepts the earlier "AI" payload.
    header = bytes((BLE_HOST_STATUS_REPORT_ID, 0xA5, ord("A"), ord("D")))
    return header + packed.to_bytes(5, "little")


def crc8_atm(data: bytes | bytearray) -> int:
    """Return the CRC used by the firmware's atomic shortcut record."""
    crc = 0
    for value in data:
        crc ^= value
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def shortcut_chord(config: object, action: str) -> tuple[int, int]:
    """Translate one human-readable shortcut into a USB HID chord."""
    if not isinstance(config, dict):
        raise ValueError(f"shortcuts.{action} must be an object")
    modifiers = config.get("modifiers", [])
    if not isinstance(modifiers, list) or not all(
        isinstance(value, str) for value in modifiers
    ):
        raise ValueError(f"shortcuts.{action}.modifiers must be a string list")
    modifier_byte = 0
    for name in modifiers:
        try:
            modifier_byte |= HID_MODIFIERS[name]
        except KeyError as exc:
            raise ValueError(
                f"unsupported shortcuts.{action} modifier: {name}"
            ) from exc

    key_name = config.get("key")
    if key_name is None:
        key_code = 0
    elif isinstance(key_name, str) and key_name in HID_KEYS:
        key_code = HID_KEYS[key_name]
    elif isinstance(key_name, int) and 0 <= key_name <= 0x65:
        key_code = key_name
    else:
        raise ValueError(f"unsupported shortcuts.{action} key: {key_name}")
    if modifier_byte == 0 and key_code == 0:
        raise ValueError(f"shortcuts.{action} cannot be empty")
    return modifier_byte, key_code


def hid_shortcut_keymap_report(config: object) -> bytes:
    """Encode all three actions in one Output Report 3 NVS transaction."""
    if not isinstance(config, dict):
        raise ValueError("shortcuts must be an object")
    payload = bytearray((BLE_SHORTCUT_KEYMAP_MARKER,))
    for action in ("voice", "send", "clear"):
        payload.extend(shortcut_chord(config.get(action), action))
    payload.append(crc8_atm(payload))
    return bytes((BLE_HOST_STATUS_REPORT_ID,)) + bytes(payload)


def parse_ble_audio_report(raw: bytes) -> tuple[int, int, bytes]:
    """Return packet type, sequence and payload from one vendor HID report."""
    if len(raw) >= BLE_AUDIO_REPORT_BYTES + 1 and raw[0] == BLE_AUDIO_REPORT_ID:
        raw = raw[1:]
    if len(raw) < BLE_AUDIO_PACKET_HEADER_BYTES:
        raise ValueError("short BLE audio HID report")
    packet_type = raw[0]
    sequence = raw[1] | (raw[2] << 8)
    payload_bytes = raw[3]
    if payload_bytes > BLE_AUDIO_REPORT_BYTES - BLE_AUDIO_PACKET_HEADER_BYTES:
        raise ValueError("invalid BLE audio payload length")
    end = BLE_AUDIO_PACKET_HEADER_BYTES + payload_bytes
    if len(raw) < end:
        raise ValueError("truncated BLE audio payload")
    return packet_type, sequence, raw[BLE_AUDIO_PACKET_HEADER_BYTES:end]


def discover_hid_path(product_name: str = "AI Passport") -> bytes:
    try:
        import hid
    except ImportError as exc:
        raise RuntimeError(
            "hidapi is missing; install host/macos/bridge/requirements.txt"
        ) from exc

    # macOS reports Bluetooth HID vendor/product IDs as zero in some paths, so
    # identify the collection by its product string and vendor usage page.
    devices = hid.enumerate()

    # hidapi defaults to seizing a device exclusively on macOS. That cannot
    # work for this composite device because macOS already owns its keyboard
    # collection. Switch subsequent opens to shared mode after enumerate()
    # has initialized hidapi (hid_init resets this option on first use).
    hid_library = ctypes.CDLL(hid.__file__)
    set_shared = hid_library.hid_darwin_set_open_exclusive
    set_shared.argtypes = [ctypes.c_int]
    set_shared.restype = None
    set_shared(0)

    vendor_devices = [
        item
        for item in devices
        if str(item.get("product_string") or "").casefold()
        == product_name.casefold()
        and int(item.get("usage_page") or 0) == BLE_HID_USAGE_PAGE
    ]
    if not vendor_devices:
        raise RuntimeError(
            f"{product_name} wireless-audio HID collection not found; pair the "
            "keyboard first"
        )
    return vendor_devices[0]["path"]


def open_hid(path: bytes) -> object:
    import hid

    device = hid.device()
    device.open_path(path)
    device.set_nonblocking(False)
    return device


def run_ble_hid(
    audio_wav: str | None,
    audio_device: str | None,
    product_name: str,
    provider_name: str,
    provider_settings: dict[str, object],
    shortcuts: dict[str, object],
) -> None:
    """Receive microphone packets over the paired BLE HID connection."""
    audio_sink = MacAudioSink(audio_device) if audio_device else None
    metrics = MetricMonitor(load_provider(provider_name, provider_settings))
    metrics.start()
    running = True
    wav: wave.Wave_write | None = None
    wav_rate: int | None = None
    expected_sequence: int | None = None
    bits_per_sample: int | None = None
    audio_frames = 0

    def stop(_signum: int, _frame: object) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    write_bridge_status("waiting", f"Waiting for {product_name}")
    print(f"Waiting for paired {product_name} wireless audio HID...", flush=True)

    try:
        while running:
            device = None
            try:
                device = open_hid(discover_hid_path(product_name))
                # macOS updates the Output Report value but ESP-IDF does not
                # always emit an output callback. Keep this record current for
                # one 500 ms firmware polling period before writing status.
                device.write(hid_shortcut_keymap_report(shortcuts))
                time.sleep(0.6)
                snapshot = metrics.snapshot
                device.write(
                    hid_host_status_report(
                        True,
                        snapshot.remaining_percent,
                        snapshot.daily_total,
                    )
                )
                write_bridge_status("connected", audio_device or "audio disabled")
                print("Wireless audio ON; keyboard and microphone share BLE HID", flush=True)
                next_time_sync = time.monotonic() + 2.0
                while running:
                    if time.monotonic() >= next_time_sync:
                        snapshot = metrics.snapshot
                        device.write(
                            hid_host_status_report(
                                True,
                                snapshot.remaining_percent,
                                snapshot.daily_total,
                            )
                        )
                        next_time_sync = time.monotonic() + 30.0
                    values = device.read(BLE_AUDIO_REPORT_BYTES + 1, 1000)
                    if not values:
                        continue
                    report = bytes(values)
                    # This IOHIDDevice receives every input report in the
                    # composite HID collection. Report 1 is the keyboard;
                    # only report 2 carries microphone packets.
                    if report[0] != BLE_AUDIO_REPORT_ID:
                        continue
                    packet_type, sequence, payload = parse_ble_audio_report(report)
                    if packet_type == BLE_AUDIO_PACKET_START:
                        if len(payload) < 5 or payload[0] != 1:
                            print("WARN unsupported wireless audio format", flush=True)
                            continue
                        sample_rate = payload[1] | (payload[2] << 8)
                        bits_per_sample = payload[3]
                        if (payload[4] != 1 or bits_per_sample not in (8, 16)
                                or sample_rate not in (8000, 16000)):
                            print("WARN unsupported wireless PCM parameters", flush=True)
                            continue
                        expected_sequence = None
                        if audio_sink:
                            audio_sink.start_segment(sample_rate)
                        if audio_wav and wav is None:
                            wav = wave.open(audio_wav, "wb")
                            wav.setnchannels(1)
                            wav.setsampwidth(2)
                            wav.setframerate(sample_rate)
                            wav_rate = sample_rate
                            print(f"Saving board microphone PCM to {audio_wav}", flush=True)
                        elif wav and wav_rate != sample_rate:
                            raise RuntimeError("sample rate changed while WAV capture was open")
                        print(
                            f"AUDIO START {sample_rate} Hz/"
                            f"{bits_per_sample}-bit/mono",
                            flush=True,
                        )
                        write_bridge_status(
                            "recording",
                            f"{sample_rate} Hz/{bits_per_sample}-bit/mono",
                        )
                    elif packet_type == BLE_AUDIO_PACKET_PCM:
                        if expected_sequence is not None and sequence != expected_sequence:
                            print(
                                f"WARN wireless audio sequence jump "
                                f"{expected_sequence} -> {sequence}",
                                flush=True,
                            )
                        expected_sequence = (sequence + 1) & 0xFFFF
                        audio_frames += 1
                        if bits_per_sample == 8:
                            payload = pcm_s8_to_pcm16(payload)
                        elif bits_per_sample != 16:
                            continue
                        if wav:
                            wav.writeframesraw(payload)
                        if audio_sink:
                            audio_sink.write(payload)
                    elif packet_type == BLE_AUDIO_PACKET_STOP:
                        print("AUDIO STOP", flush=True)
                        write_bridge_status(
                            "connected", audio_device or "audio disabled"
                        )
            except Exception as exc:
                if running:
                    write_bridge_status("waiting", f"Waiting for {product_name}")
                    print(f"Wireless audio waiting: {exc}", flush=True)
                    time.sleep(1.0)
            finally:
                if device is not None:
                    try:
                        snapshot = metrics.snapshot
                        device.write(
                            hid_host_status_report(
                                False,
                                snapshot.remaining_percent,
                                snapshot.daily_total,
                            )
                        )
                    except Exception:
                        pass
                    try:
                        device.close()
                    except Exception:
                        pass
    finally:
        metrics.close()
        write_bridge_status("stopped", "Bridge stopped")
        if wav:
            wav.close()
            print(f"Saved {audio_frames} wireless audio packets", flush=True)
        if audio_sink:
            audio_sink.close()


def handle_device_line(line: str, injector: MacKeyInjector) -> None:
    if not line.startswith("AIPASS:"):
        return
    print(f"DEVICE {line}", flush=True)
    message = line.removeprefix("AIPASS:")
    if message == "VOICE,DOWN":
        injector.voice_down()
    elif message == "VOICE,UP":
        injector.voice_up()
    elif message == "KEY,RETURN":
        injector.tap(KEY_RETURN, "Return")
    elif message == "KEY,ESCAPE":
        injector.tap(KEY_ESCAPE, "Escape")
    elif message == "KEY,CLEAR":
        injector.tap(KEY_DELETE, "Command+Delete", CG_EVENT_FLAG_MASK_COMMAND)


def run(
    port: str,
    inject: bool,
    audio_wav: str | None,
    audio_device: str | None,
) -> None:
    injector = MacKeyInjector(enabled=inject)
    audio_sink = MacAudioSink(audio_device) if audio_device else None
    fd = open_serial(port)
    running = True

    def stop(_signum: int, _frame: object) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f"Connected to {port}; key injection={'ON' if inject else 'DRY RUN'}", flush=True)
    print(
        "Shortcut mapping: hold voice = left Control + left Command; "
        "send = Return; clear = Command+Delete"
    )

    buffer = bytearray()
    wav = wave.open(audio_wav, "wb") if audio_wav else None
    if wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(AUDIO_SAMPLE_RATE)
        print(f"Saving board microphone PCM to {audio_wav}", flush=True)
    audio_frames = 0
    expected_sequence: int | None = None
    next_time_sync = time.monotonic() + 2.0
    try:
        while running:
            now = time.monotonic()
            if now >= next_time_sync:
                send_host_status(fd)
                next_time_sync = now + 30.0

            readable, _, _ = select.select([fd], [], [], 0.2)
            if not readable:
                continue
            chunk = os.read(fd, 4096)
            if not chunk:
                continue
            buffer.extend(chunk)
            while buffer:
                magic_at = buffer.find(AUDIO_MAGIC)
                newline_at = buffer.find(b"\n")

                if magic_at == 0:
                    if len(buffer) < AUDIO_HEADER.size:
                        break
                    _, payload_bytes, sequence = AUDIO_HEADER.unpack_from(buffer)
                    frame_bytes = AUDIO_HEADER.size + payload_bytes
                    if payload_bytes > 4096:
                        del buffer[0]
                        continue
                    if len(buffer) < frame_bytes:
                        break
                    pcm = bytes(buffer[AUDIO_HEADER.size:frame_bytes])
                    del buffer[:frame_bytes]
                    if expected_sequence is not None and sequence != expected_sequence:
                        print(
                            f"WARN audio sequence jump {expected_sequence} -> {sequence}",
                            flush=True,
                        )
                    expected_sequence = (sequence + 1) & 0xFFFF
                    audio_frames += 1
                    if wav:
                        wav.writeframesraw(pcm)
                    if audio_sink:
                        audio_sink.write(pcm)
                    continue

                if newline_at >= 0 and (magic_at < 0 or newline_at < magic_at):
                    raw = bytes(buffer[:newline_at]).rstrip(b"\r")
                    del buffer[:newline_at + 1]
                    line = raw.decode("utf-8", "replace")
                    if line == "AIPASS:READY":
                        send_host_status(fd)
                        next_time_sync = time.monotonic() + 30.0
                    if line == "AIPASS:AUDIO,START,16000,16,1":
                        expected_sequence = None
                        if audio_sink:
                            audio_sink.start_segment()
                    handle_device_line(line, injector)
                    continue

                if magic_at > 0:
                    raw = bytes(buffer[:magic_at]).decode("utf-8", "replace")
                    if raw.strip():
                        print(f"DEVICE {raw.strip()}", flush=True)
                    del buffer[:magic_at]
                    continue

                if len(buffer) > 8192:
                    del buffer[:-AUDIO_HEADER.size]
                break
    finally:
        injector.close()
        if wav:
            wav.close()
            print(f"Saved {audio_frames} audio frames", flush=True)
        if audio_sink:
            audio_sink.close()
        os.close(fd)


def self_test() -> None:
    from providers.codex import extract_remaining, find_codex, token_delta_for_local_day

    assert DEFAULT_CONFIG["provider"]["name"] == "none"
    assert find_codex("/explicit/codex") == "/explicit/codex"

    injector = MacKeyInjector(enabled=False)
    for line in (
        "AIPASS:READY",
        "AIPASS:VOICE,DOWN",
        "AIPASS:VOICE,UP",
        "AIPASS:KEY,RETURN",
        "AIPASS:KEY,ESCAPE",
        "AIPASS:KEY,CLEAR",
    ):
        handle_device_line(line, injector)
    injector.close()
    source = array.array("h", (0, 300, -300)).tobytes()
    for sample_rate, factor in ((16000, 3), (8000, 6)):
        converter = Pcm16MonoToStereo48k(sample_rate)
        converted = array.array("h")
        converted.frombytes(converter.convert(source))
        assert len(converted) == 3 * factor * AUDIO_OUTPUT_CHANNELS
        assert all(
            converted[index] == converted[index + 1]
            for index in range(0, len(converted), 2)
        )

    payload = bytes(range(32))
    report = bytes((BLE_AUDIO_REPORT_ID, BLE_AUDIO_PACKET_PCM, 0x34, 0x12,
                    len(payload))) + payload
    report = report.ljust(BLE_AUDIO_REPORT_BYTES + 1, b"\0")
    packet_type, sequence, parsed = parse_ble_audio_report(report)
    assert packet_type == BLE_AUDIO_PACKET_PCM
    assert sequence == 0x1234
    assert parsed == payload
    assert pcm_s8_to_pcm16(bytes((0x80, 0x00, 0x7F))) == struct.pack(
        "<hhh", -32768, 0, 32512
    )
    sample_now = datetime(2026, 8, 31, 12, 34)
    status = hid_host_status_report(True, 86, 100_000_000, sample_now)
    packed_status = int.from_bytes(status[4:], "little")
    assert len(status) == 9
    assert status[1:4] == bytes((0xA5, ord("A"), ord("D")))
    assert packed_status & 0x3FFF == (sample_now.date() - HOST_STATUS_EPOCH).days
    assert (packed_status >> 14) & 0x7FF == 12 * 60 + 34
    assert (packed_status >> 25) & 1 == 1
    assert (packed_status >> 26) & 0x7F == 86
    assert (packed_status >> 33) & 0x7F == 10
    unknown_status = int.from_bytes(
        hid_host_status_report(False, None, None, sample_now)[4:], "little"
    )
    assert (unknown_status >> 25) & 1 == 0
    assert (unknown_status >> 26) & 0x7F == METRIC_REMAINING_UNKNOWN
    assert (unknown_status >> 33) & 0x7F == METRIC_DAILY_UNKNOWN
    keymap = hid_shortcut_keymap_report(DEFAULT_CONFIG["shortcuts"])
    assert len(keymap) == 9
    assert keymap[0] == BLE_HOST_STATUS_REPORT_ID
    assert keymap[1] == BLE_SHORTCUT_KEYMAP_MARKER
    assert keymap[-1] == crc8_atm(keymap[1:-1])
    sample_day = datetime.now().astimezone().date()
    assert token_delta_for_local_day(
        {
            "timestamp": datetime.now().astimezone().isoformat(),
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"total_tokens": 1234}},
            },
        },
        sample_day,
    ) == 1234
    assert extract_remaining(
        {
            "result": {
                "rateLimitsByLimitId": {
                    "codex": {"primary": {"usedPercent": 14}}
                }
            }
        }
    ) == 86
    print("SELF TEST PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        help="JSON configuration; defaults to the installed config when present",
    )
    parser.add_argument("--port", help="serial device; defaults to /dev/cu.usbmodem*")
    parser.add_argument(
        "--transport",
        choices=("auto", "ble", "usb"),
        default="auto",
        help="audio transport; auto prefers wireless BLE HID unless --port is set",
    )
    parser.add_argument(
        "--inject",
        action="store_true",
        help="post real macOS key events (default is a safe dry run)",
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--audio-wav",
        help="save 16 kHz mono board-microphone audio to this WAV file",
    )
    parser.add_argument(
        "--audio-device",
        help="send board audio to a matching Core Audio output, e.g. BlackHole 2ch",
    )
    parser.add_argument(
        "--no-audio",
        action="store_true",
        help="disable the virtual-microphone audio sink",
    )
    parser.add_argument("--device-name", help="BLE HID product name")
    parser.add_argument(
        "--provider",
        help="metric provider plugin name or fully qualified Python module",
    )
    parser.add_argument(
        "--print-effective-config",
        action="store_true",
        help="print resolved configuration and exit",
    )
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    try:
        config, config_path = load_config(args.config)
        provider_config = config.get("provider")
        if not isinstance(provider_config, dict):
            raise ValueError("provider configuration must be an object")
        product_name = args.device_name or str(config["device_name"])
        audio_device = None if args.no_audio else (
            args.audio_device
            if args.audio_device is not None
            else config.get("audio_device")
        )
        if audio_device is not None:
            audio_device = str(audio_device)
        provider_name = args.provider or str(provider_config.get("name", "none"))
        provider_settings = provider_config.get("settings", {})
        if not isinstance(provider_settings, dict):
            raise ValueError("provider.settings must be an object")
        shortcuts = config.get("shortcuts")
        if not isinstance(shortcuts, dict):
            raise ValueError("shortcuts must be an object")
        # Validate the complete map before touching the BLE device.
        hid_shortcut_keymap_report(shortcuts)
        if args.print_effective_config:
            print(
                json.dumps(
                    {
                        "config_path": str(config_path) if config_path else None,
                        "device_name": product_name,
                        "audio_device": audio_device,
                        "provider": {
                            "name": provider_name,
                            "settings": provider_settings,
                        },
                        "shortcuts": shortcuts,
                    },
                    indent=2,
                )
            )
            return 0
        transport = "usb" if args.transport == "auto" and args.port else args.transport
        if transport in ("auto", "ble"):
            run_ble_hid(
                args.audio_wav,
                audio_device,
                product_name,
                provider_name,
                provider_settings,
                shortcuts,
            )
        else:
            run(discover_port(args.port), args.inject, args.audio_wav, audio_device)
    except Exception as exc:
        write_bridge_status("error", str(exc))
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
