# bash-scripts

This repository currently contains a single script:

- `transcribe.sh` — audio recording and Whisper-based transcription

## `transcribe.sh`

This script records PulseAudio/PipeWire audio output, then automatically passes the recorded segments to the `whisper` command.

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
./transcribe.sh --language <language> --task <transcribe|translate>
```

#### Options

- `-l, --language` — audio language
- `-t, --task` — `transcribe` or `translate`
- `--continue-recording` — continue an existing recording
- `-h, --help` — show help

### Examples

Start a new recording in English:

```bash
./transcribe.sh --language English --task transcribe
```

Translate to English:

```bash
./transcribe.sh --language English --task translate
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
./transcribe.sh --language English --task transcribe
```

### Note

By default, the script uses the following PulseAudio/PipeWire source:

```bash
alsa_output.pci-0000_00_1f.3.hdmi-stereo.monitor
```

If you want a different audio source, change the `AUDIO_SOURCE` value in the script.
