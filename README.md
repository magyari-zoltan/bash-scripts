# bash-scripts

This repository currently contains a single script:

- `transcribe.sh` — audio recording and Whisper-based transcription

## [transcribe.sh](./transcribe.sh)

This script records PulseAudio / PipeWire audio output, then automatically passes the recorded segments to the `whisper` command.

### What does it do?

- creates WAV files of a fixed duration in the `./recording/` folder
- uses a `.ready` marker file for each segment
- processes finished audio chunks with Whisper
- can resume from an interrupted run
- on the first `Ctrl+C`, stops recording and lets Whisper finish processing
- on the second `Ctrl+C`, stops Whisper too

### Requirements

- `ffmpeg`
- `python`
- `whisper` (`openai-whisper`)
- a working Python virtual environment at `~/.venvs/whisper`

### Installation on Arch Linux

```bash
sudo pacman -S ffmpeg python
python -m venv ~/.venvs/whisper

source ~/.venvs/whisper/bin/activate
pip install --upgrade pip
pip install -U openai-whisper
deactivate
```

### Usage

```bash
./transcribe.sh \
    --language <language> \
    --task <transcribe|translate> \
    [--audio-source <source>]
```

#### Options

| Option                 | Description                                                                                                                                                        |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `-l, --language`       | Audio language.                                                                                                                                                    |
| `-t, --task`           | Valid values: `transcribe` or `translate`.                                                                                                                         |
| `--audio-source`       | Audio source to record.<br>Find available sources with: `pactl list short sources`.<br>If omitted, the script uses the monitor source of `pactl get-default-sink`. |
| `--continue-recording` | Continue an existing recording.                                                                                                                                    |
| `-h, --help`           | Show help.                                                                                                                                                         |

### Examples

Start a new recording in English:

```bash
./transcribe.sh \
    --language English \
    --task transcribe
```

Translate to English:

```bash
./transcribe.sh \
    --language English \
    --task translate
```

Continue an existing recording:

```bash
./transcribe.sh \
    --language English \
    --task transcribe \
    --continue-recording
```

Run only the segments that have not been processed yet:

```bash
./transcribe.sh \
    --language English \
    --task transcribe
```

### Note

If recording has already finished, `Ctrl+C` stops Whisper immediately.

Find available audio sources with:

```bash
pactl list short sources | grep monitor

# Example output
# 74      alsa_output.pci-0000_00_1f.3.hdmi-stereo.monitor          PipeWire        s32le 2ch 48000Hz       SUSPENDED
# 75      alsa_input.pci-0000_00_1f.3.analog-stereo                 PipeWire        s32le 2ch 48000Hz       SUSPENDED
```

If ommitted, the script uses this command to find the default output's monitor source automatically:

```bash
pactl get-default-sink
```
