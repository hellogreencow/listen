"""Static audio and path configuration."""

from pathlib import Path

# Audio settings
SAMPLE_RATE = 44100
CHANNELS = 1
RECORDING_FORMAT = "int16"

# Paths
APP_DIR = Path.home() / ".listen"
APP_DIR.mkdir(exist_ok=True)
TEMP_AUDIO_PATH = APP_DIR / "temp_recording.wav"
