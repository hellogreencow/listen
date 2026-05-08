"""Audio recording using native macOS AVAudioRecorder via PyObjC.

Records to AAC/M4A for tiny file sizes (~20x smaller than WAV).
"""

import os
import tempfile
from pathlib import Path
from typing import Optional

from AVFoundation import AVAudioRecorder, NSNumber
from Foundation import NSURL


def _fmt(fourcc: str) -> int:
    return int.from_bytes(fourcc.encode("ascii"), "big")


# AAC / M4A — ~20x smaller than WAV, ElevenLabs accepts it
_AAC_SETTINGS = {
    "AVFormatIDKey": NSNumber.numberWithInt_(_fmt("aac ")),
    "AVSampleRateKey": NSNumber.numberWithFloat_(44100.0),
    "AVNumberOfChannelsKey": NSNumber.numberWithInt_(1),
    "AVEncoderAudioQualityKey": NSNumber.numberWithInt_(127),  # max = 127
    "AVEncoderBitRateKey": NSNumber.numberWithInt_(32000),     # 32 kbps mono
}


class AudioRecorder:
    """Simple wrapper around AVAudioRecorder."""

    def __init__(self):
        self._recorder = None
        self._temp_path: Optional[Path] = None

    def start(self) -> None:
        fd, tmp = tempfile.mkstemp(suffix=".m4a")
        os.close(fd)
        self._temp_path = Path(tmp)

        url = NSURL.fileURLWithPath_(str(self._temp_path))

        result = AVAudioRecorder.alloc().initWithURL_settings_error_(url, _AAC_SETTINGS, None)
        if isinstance(result, tuple):
            self._recorder = result[0]
        else:
            self._recorder = result

        if self._recorder is None:
            raise RuntimeError(
                "Failed to create AVAudioRecorder. "
                "Grant microphone permission in System Settings → Privacy & Security."
            )

        self._recorder.record()

    def stop(self) -> Path:
        if self._recorder is None:
            raise RuntimeError("No recording in progress")

        self._recorder.stop()
        self._recorder = None

        if self._temp_path and self._temp_path.exists():
            return self._temp_path
        raise RuntimeError("No audio data captured")

    def cleanup(self) -> None:
        """Delete temp file if still exists."""
        if self._temp_path and self._temp_path.exists():
            os.unlink(self._temp_path)
        self._temp_path = None
