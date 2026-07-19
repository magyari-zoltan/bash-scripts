#!/usr/bin/env bash

# ==============================================================================
# Requirements and installation
# ==============================================================================
#
# Arch Linux
#
#   sudo pacman -S ffmpeg python
#   python -m venv ~/.venvs/whisper
#
#   source ~/.venvs/whisper/bin/activate
#   pip install --upgrade pip
#   pip install -U openai-whisper
#   deactivate
#
# ==============================================================================

set -u

# Constants
WORK_DIR="./recording"
WHISPER_VENV="$HOME/.venvs/whisper"
RECORDING_FINISHED_FILE="$WORK_DIR/recording.finished"

# Script arguments
AUDIO_SOURCE=""
LANGUAGE=""
TASK=""
CONTINUE_RECORDING=false

# Process IDs and flags
VENV_ACTIVATED_BY_SCRIPT=false

FFMPEG_PID=""
RECORDING_STOP_REQUESTED=false

WHISPER_PID=""
WHISPER_STOP_REQUESTED=false

RECORDING_UI_PID=""
RECORDING_UI_ACTIVE=false

# Terminal control sequences
ESC=$'\033'
CARRIAGE_RETURN=$'\r'
CLEAR_LINE="${ESC}[2K"
CLEAR_SCREEN="${ESC}[2J"
CURSOR_HOME="${ESC}[H"
ALT_BUFFER_ENTER="${ESC}[?1049h"
ALT_BUFFER_EXIT="${ESC}[?1049l"
CURSOR_HIDE="${ESC}[?25l"
CURSOR_SHOW="${ESC}[?25h"
TEXT_DIM="${ESC}[2m"
TEXT_RESET="${ESC}[0m"
TEXT_BRIGHT_RED="${ESC}[91m"
TEXT_YELLOW="${ESC}[33m"
TEXT_CYAN="${ESC}[36m"

usage() {
    cat <<EOF
This utility captures audio and transcribes it into text.

Usage:

    $0 --language <language> --task <task> [--audio-source <source>] [--continue-recording]

Examples:

    Start a new recording:

        $0 --language Romanian --task transcribe

    Continue an existing recording:

        $0 --language Romanian --task transcribe --continue-recording

    Use a specific audio source:

        $0 --language Romanian --task transcribe --audio-source alsa_output.pci-0000_00_1f.3.hdmi-stereo.monitor

Options:

    -l, --language             Audio language
    -t, --task                 Whisper task: transcribe or translate
        --audio-source         Audio source to record
                               Defaults to: '$(pactl get-default-sink)'
                               Find available sources with: 'pactl list short sources'
        --continue-recording   Continue recording after existing audio segments
    -h, --help                 Show this help

Signal handling:

    First Ctrl+C:
        Stop the FFmpeg recording.
        If recording has already finished, stop Whisper.

    Second Ctrl+C:
        Stop Whisper processing and exit the script.

    Interrupted Whisper processing is resumed automatically
    the next time the script is started.
EOF
}

# ─────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--language)
            LANGUAGE="${2:-}"
            shift 2
            ;;

        -t|--task)
            TASK="${2:-}"
            shift 2
            ;;

        --audio-source)
            AUDIO_SOURCE="${2:-}"
            shift 2
            ;;

        --continue-recording)
            CONTINUE_RECORDING=true
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done


if [[ -z "$LANGUAGE" ]]; then
    echo "Error: --language is required." >&2
    exit 1
fi


if [[ "$TASK" != "transcribe" && "$TASK" != "translate" ]]; then
    echo "Error: --task must be either 'transcribe' or 'translate'." >&2
    exit 1
fi

if [[ -z "$AUDIO_SOURCE" ]]; then
    default_sink="$(pactl get-default-sink 2>/dev/null || true)"

    if [[ -z "$default_sink" ]]; then
        echo "Error: could not determine the default audio sink." >&2
        exit 1
    fi

    AUDIO_SOURCE="${default_sink}.monitor"
fi


mkdir -p "$WORK_DIR"


# ─────────────────────────────────────────────
# Virtual environment
# ─────────────────────────────────────────────

activate_whisper_venv() {
    if [[ "${VIRTUAL_ENV:-}" == "$WHISPER_VENV" ]]; then
        return
    fi

    if [[ ! -f "$WHISPER_VENV/bin/activate" ]]; then
        echo "Error: Whisper virtual environment not found:" >&2
        echo "  $WHISPER_VENV" >&2
        exit 1
    fi

    echo "Activating Whisper virtual environment..."

    # shellcheck disable=SC1091
    source "$WHISPER_VENV/bin/activate"

    # Set a flag to indicate that the virtual environment was activated by this script.
    VENV_ACTIVATED_BY_SCRIPT=true
}


deactivate_whisper_venv() {
    if [[ "$VENV_ACTIVATED_BY_SCRIPT" == true ]] &&
       declare -F deactivate &>/dev/null; then

        echo "Deactivating Whisper virtual environment..."
        deactivate
    fi
}


activate_whisper_venv

# Check if the whisper command is available after activating the virtual environment
if ! command -v whisper &>/dev/null; then
    echo "Error: whisper command not found." >&2
    exit 1
fi

# ─────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────

get_audio_file() {
    printf "%s/audio_%03d.wav" "$WORK_DIR" "$1"
}


get_output_file() {
    printf "%s/audio_%03d.txt" "$WORK_DIR" "$1"
}


get_ready_file() {
    printf "%s/audio_%03d.ready" "$WORK_DIR" "$1"
}


get_segment_time() {
    local index="$1"

    case "$index" in
        1)
            echo 300
            ;;

        2)
            echo 600
            ;;

        3)
            echo 1200
            ;;

        *)
            echo 1800
            ;;
    esac
}


has_existing_recordings() {
    local audio_files

    shopt -s nullglob
    audio_files=("$WORK_DIR"/audio_*.wav)
    shopt -u nullglob

    (( ${#audio_files[@]} > 0 ))
}


has_pending_transcriptions() {
    local audio_file
    local output_file

    shopt -s nullglob

    for audio_file in "$WORK_DIR"/audio_*.wav; do
        output_file="${audio_file%.wav}.txt"

        if [[ ! -f "$output_file" ]]; then
            shopt -u nullglob
            return 0
        fi
    done

    shopt -u nullglob
    return 1
}


get_next_recording_index() {
    local index=1
    local audio_file

    while true; do
        audio_file="$(get_audio_file "$index")"

        if [[ ! -e "$audio_file" ]]; then
            echo "$index"
            return
        fi

        ((index++))
    done
}


concatenate_transcripts() {
    rm -f "$WORK_DIR/audio_all.txt"
    printf '%s\n' "$WORK_DIR"/audio_*.txt | sort -V | xargs cat > "$WORK_DIR/audio_all.txt"
}


# ─────────────────────────────────────────────
# Diplay script status in the terminal
# ─────────────────────────────────────────────

start_recording_animation() {
    local frame_index=0
    local frames=("·" "•" "●" "•")

    if [[ ! -t 1 ]]; then
        return
    fi

    RECORDING_UI_ACTIVE=true

    # Switch to the terminal's alternate screen buffer.
    printf '%s' "$ALT_BUFFER_ENTER"
    # Hide the cursor while the recording status is animated.
    printf '%s' "$CURSOR_HIDE"
    # Clear the alternate screen before drawing the status line.
    printf '%s%s' "$CURSOR_HOME" "$CLEAR_SCREEN"

    (
        while true; do
            # Rewrite the same line with the next spinner frame.
            printf '%s%s%s%sRecording in progress: %s%s%s%s' \
                "$CARRIAGE_RETURN" \
                "$CLEAR_LINE" \
                "$TEXT_RESET" \
                "$TEXT_DIM" \
                "$TEXT_RESET" \
                "$TEXT_BRIGHT_RED" \
                "${frames[frame_index % 4]}" \
                "$TEXT_RESET"
            sleep 0.2
            ((frame_index++))
        done
    ) &

    RECORDING_UI_PID=$!
}


stop_recording_animation() {
    if [[ -n "$RECORDING_UI_PID" ]] &&
       kill -0 "$RECORDING_UI_PID" 2>/dev/null; then

        kill "$RECORDING_UI_PID"
        wait "$RECORDING_UI_PID" 2>/dev/null || true
    fi

    if [[ "$RECORDING_UI_ACTIVE" == true ]]; then
        # Clear the status line, show the cursor, and return to the main buffer.
        printf '%s%s%s%s' \
            "$CARRIAGE_RETURN" \
            "$CLEAR_LINE" \
            "$CURSOR_SHOW" \
            "$ALT_BUFFER_EXIT"
        RECORDING_UI_ACTIVE=false
    fi

    RECORDING_UI_PID=""
}


# ─────────────────────────────────────────────
# Signal handling and cleanup
# ─────────────────────────────────────────────

stop_recording() {
    echo
    echo "Stop requested..."

    if [[ "$RECORDING_STOP_REQUESTED" == false ]] &&
       [[ -n "$FFMPEG_PID" ]] &&
       kill -0 "$FFMPEG_PID" 2>/dev/null; then

        RECORDING_STOP_REQUESTED=true
        echo "Stopping FFmpeg..."
        kill -INT "$FFMPEG_PID"
        return
    fi

    if [[ -n "$WHISPER_PID" ]] &&
       kill -0 "$WHISPER_PID" 2>/dev/null; then

        WHISPER_STOP_REQUESTED=true
        echo "Stopping Whisper..."
        kill -INT "$WHISPER_PID"
    fi
}


cleanup() {
    stop_recording_animation
    deactivate_whisper_venv
}


trap stop_recording INT TERM
trap cleanup EXIT

# ─────────────────────────────────────────────
# Whisper worker
# ─────────────────────────────────────────────

transcribe_worker() {
    local index=1
    local audio_file
    local output_file
    local ready_file

    while true; do
        if [[ "$WHISPER_STOP_REQUESTED" == true ]]; then
            break
        fi

        audio_file="$(get_audio_file "$index")"
        output_file="$(get_output_file "$index")"
        ready_file="$(get_ready_file "$index")"

        # Skip already processed segments
        if [[ -f "$output_file" ]]; then
            ((index++))
            continue
        fi

        # Process completed audio segments
        if [[ -f "$ready_file" && -s "$audio_file" ]]; then
            if [[ "$WHISPER_STOP_REQUESTED" == true ]]; then
                break
            fi

            echo
            echo "Processing with Whisper:"
            echo "  $audio_file"

            if whisper "$audio_file" \
                --model medium \
                --output_format txt \
                --output_dir "$WORK_DIR" \
                --verbose False \
                --fp16 False \
                --threads 6 \
                --task "$TASK" \
                --language "$LANGUAGE" \
                >/dev/null 2>&1
            then
                rm -f "$ready_file"
                ((index++))
                continue
            fi

            echo "Error processing audio segment:" >&2
            echo "  $audio_file" >&2

            sleep 5
            continue
        fi

        # Exit when recording has finished and no work remains
        if [[ -f "$RECORDING_FINISHED_FILE" ]]; then

            if ! has_pending_transcriptions; then
                break
            fi

            if [[ ! -e "$audio_file" ]]; then
                ((index++))
                continue
            fi
        fi

        sleep 2
    done
}


# ─────────────────────────────────────────────
# Restore interrupted state
# ─────────────────────────────────────────────

restore_existing_segments() {
    local audio_file
    local output_file
    local ready_file

    shopt -s nullglob

    for audio_file in "$WORK_DIR"/audio_*.wav; do

        output_file="${audio_file%.wav}.txt"
        ready_file="${audio_file%.wav}.ready"

        if [[ ! -f "$output_file" && -s "$audio_file" ]]; then
            touch "$ready_file"
        fi

    done

    shopt -u nullglob
}

restore_existing_segments

# ─────────────────────────────────────────────
# Determine operating mode
# ─────────────────────────────────────────────

if ! has_existing_recordings; then
    echo "No existing audio segments found."
    echo "Starting a new recording..."

    CONTINUE_RECORDING=true

elif [[ "$CONTINUE_RECORDING" == false ]]; then
    touch "$RECORDING_FINISHED_FILE"

    if has_pending_transcriptions; then
        echo "Existing recording detected."
        echo "Audio recording will not continue."
        echo "Whisper will process the remaining segments."

        transcribe_worker
    else
        echo "No audio segments are waiting for processing."
    fi

    exit 0
else
    echo "Existing recording detected."
    echo "Continuing audio recording and Whisper processing."
fi

# ─────────────────────────────────────────────
# Start or continue recording
# ─────────────────────────────────────────────

rm -f "$RECORDING_FINISHED_FILE"

start_recording_animation
transcribe_worker &
WHISPER_PID=$!

index="$(get_next_recording_index)"

while [[ "$RECORDING_STOP_REQUESTED" == false ]]; do

    segment_time="$(get_segment_time "$index")"

    audio_file="$(get_audio_file "$index")"
    ready_file="$(get_ready_file "$index")"

    # Move the cursor to the top and clear the alternate screen before printing.
    printf '%s%s' "$CURSOR_HOME" "$CLEAR_SCREEN"

    printf '\n%sStarting audio segment:%s\n' "$TEXT_DIM" "$TEXT_RESET"
    printf '  File:     %s%s%s\n' "$TEXT_YELLOW" "$audio_file" "$TEXT_RESET"
    printf '  Duration: %s%s minutes%s\n' \
        "$TEXT_CYAN" \
        "$((segment_time / 60))" \
        "$TEXT_RESET"

    ffmpeg \
        -f pulse \
        -i "$AUDIO_SOURCE" \
        -t "$segment_time" \
        -ac 1 \
        -ar 16000 \
        -hide_banner \
        -loglevel error \
        -nostats \
        "$audio_file" >/dev/null 2>&1 &

    FFMPEG_PID=$!

    wait "$FFMPEG_PID"

    FFMPEG_PID=""

    # A segment interrupted with Ctrl+C is still considered valid
    if [[ -s "$audio_file" ]]; then
        touch "$ready_file"
    fi

    ((index++))
done

# ─────────────────────────────────────────────
# Finish remaining Whisper processing
# ─────────────────────────────────────────────

touch "$RECORDING_FINISHED_FILE"

stop_recording_animation

echo "Audio recording stopped."
echo "Whisper will continue processing the remaining segments."

wait "$WHISPER_PID"
WHISPER_STATUS=$?

if [[ "$WHISPER_STOP_REQUESTED" == true ]]; then
    echo
    echo "Whisper processing stopped."
    exit "$WHISPER_STATUS"
fi

concatenate_transcripts

echo
echo "All audio segments have been processed."
