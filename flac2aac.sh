#!/usr/bin/env bash

DELETE=0
DRYRUN=0
CLEANUP_ONLY=0
COPY=0
SRC_DIR=""
DEST_DIR=""

print_help() {
  echo "Usage: $0 <source_dir> <destination_dir> [options]"
  echo ""
  echo "Required:"
  echo "  <source_dir>       Root folder containing .flac files"
  echo "  <destination_dir>  Destination root for .m4a output"
  echo ""
  echo "Options:"
  echo "  --dry-run          Show what would happen (no conversion or deletes)"
  echo "  --with-delete      Convert and delete .flac after successful conversion"
  echo "  --cleanup-only     Skip conversion, just delete .flac if .m4a is newer"
  echo "  --and-copy-to-ipod-if-successful"
  echo "                     After a completely successful conversion,"
  echo "                     copy the output folder to any mounted USB devices"
  echo "  --help, -h         Show this help"
  echo ""
}

# Stop immediately on Ctrl+C
trap 'echo -e "\n🚨 Aborted by user. Exiting..."; exit 130' SIGINT

if [[ "$#" -lt 2 ]]; then
  print_help
  read -p "Would you like to run a dry-run conversion? [y/N]: " run_convert
  if [[ "$run_convert" =~ ^[Yy]$ ]]; then
    read -p "Enter source dir: " SRC_DIR
    read -p "Enter destination dir: " DEST_DIR
    exec "$0" "$SRC_DIR" "$DEST_DIR" --dry-run
  fi
  exit 0
fi

SRC_DIR="$1"
DEST_DIR="$2"
shift 2

for arg in "$@"; do
  case "$arg" in
    --with-delete) DELETE=1 ;;
    --cleanup-only) CLEANUP_ONLY=1 ;;
    --dry-run) DRYRUN=1 ;;
    --and-copy-to-ipod-if-successful) COPY=1 ;;
    --help|-h) print_help; exit 0 ;;
    *) echo "Unknown option: $arg" && print_help && exit 1 ;;
  esac
done

if [[ ! -d "$SRC_DIR" ]]; then
  echo "❌ Source directory not found: $SRC_DIR"
  exit 1
fi

mkdir -p "$DEST_DIR"
unconverted_files=()
deleted_files=()
FAIL=0

find "$SRC_DIR" -type f -name '*.flac' -print0 | while IFS= read -r -d '' src_file; do
  rel_path="$(realpath --relative-to="$SRC_DIR" "$src_file")"
  dest_file="$DEST_DIR/${rel_path%.flac}.m4a"
  dest_dir="$(dirname "$dest_file")"
  cover_file="$(mktemp --suffix=.jpg)"

  if [[ -f "$dest_file" && "$dest_file" -nt "$src_file" ]]; then
    if [[ "$CLEANUP_ONLY" -eq 1 ]]; then
      if [[ "$DRYRUN" -eq 1 ]]; then
        echo "🗑️ Would delete: $src_file"
      else
        echo "🗑️ Deleting: $src_file"
        rm "$src_file"
        deleted_files+=("$src_file")
      fi
    else
      echo "⏩ Skipping up-to-date: $rel_path"
    fi
    continue
  fi

  if [[ "$CLEANUP_ONLY" -eq 1 ]]; then
    echo "❌ Unconverted .flac: $rel_path"
    unconverted_files+=("$rel_path")
    continue
  fi

  echo "🎵 Converting: $rel_path"

  if [[ "$DRYRUN" -eq 1 ]]; then
    echo "⚙️ Would convert: $src_file"
    echo "   → Encode audio to .m4a using libfdk_aac (VBR 5)"
    echo "   → Extract and embed cover art (as attached picture)"
    echo "   → Use .mp4 muxer and rename output to .m4a"
    echo "   → Output path: $dest_file"
    continue
  fi

  mkdir -p "$dest_dir"

  ./ffmpeg -nostdin -y -i "$src_file" -an -vcodec copy "$cover_file" 2>/dev/null
  has_cover=$?

  tmp_m4a="$(mktemp --suffix=.m4a)"
  if ./ffmpeg -nostdin -y -i "$src_file" -map 0:a -vn -c:a libfdk_aac -vbr 5 -map_metadata 0 -movflags +faststart "$tmp_m4a"; then
    if [[ "$has_cover" -eq 0 && -s "$cover_file" ]]; then
      tmp_mp4="$(mktemp --suffix=.mp4)"
      if ./ffmpeg -nostdin -y \
        -i "$tmp_m4a" \
        -i "$cover_file" \
        -map 0 -map 1 \
        -c copy \
        -disposition:v:0 attached_pic \
        "$tmp_mp4"; then
        mv "$tmp_mp4" "$dest_file"
      else
        echo "❌ Failed to embed album art: $rel_path"
        rm -f "$tmp_mp4"
        mv "$tmp_m4a" "$dest_file"
      fi
    else
      mv "$tmp_m4a" "$dest_file"
    fi
    rm -f "$tmp_m4a" "$cover_file"
    if [[ "$DELETE" -eq 1 && -f "$dest_file" ]]; then
      echo "🗑️ Deleting: $src_file"
      rm "$src_file"
      deleted_files+=("$src_file")
    fi
  else
    echo "❌ Conversion failed: $rel_path"
    FAIL=1
    rm -f "$tmp_m4a" "$cover_file"
  fi

done

#— if requested and no failures, copy output to any removable USB device
if [[ "$COPY" -eq 1 && "$CLEANUP_ONLY" -eq 0 && "$FAIL" -eq 0 ]]; then
  echo ""
  echo "⏩ Copying '$DEST_DIR' to removable USB devices..."
  # detect removable mounts via lsblk
  mapfile -t USBS < <(
    lsblk -lp -o MOUNTPOINT,RM \
    | awk '$2=="1" && $1!="" { print $1 }'
  )
  for dev in "${USBS[@]}"; do
    # only devices with a Music folder at root
    if [[ -d "$dev/Music" ]]; then
      if [[ "$DRYRUN" -eq 1 ]]; then
        echo "⚙️ Would copy '$DEST_DIR' → '$dev/Music/'"
      else
        read -p "Copy to device at $dev? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          echo "📋 rsync → $dev/Music/"
          rsync -a --info=progress2 "$DEST_DIR" "$dev/Music/"
        else
          echo "⏭️ Skipping $dev"
        fi
      fi
    fi
  done
fi

if [[ "$CLEANUP_ONLY" -eq 1 && "$DRYRUN" -eq 0 && "${#unconverted_files[@]}" -gt 0 ]]; then
  echo ""
  echo "⚠️ Some .flac files were not deleted because they are unconverted."
  read -p "Would you like to dry-run a conversion to see what needs to be done? [y/N]: " do_dryconvert
  if [[ "$do_dryconvert" =~ ^[Yy]$ ]]; then
    exec "$0" "$SRC_DIR" "$DEST_DIR" --dry-run
  fi
fi

if [[ "$DELETE" -eq 0 && "$DRYRUN" -eq 0 && "$CLEANUP_ONLY" -eq 0 ]]; then
  echo ""
  read -p "Would you like to dry-run a cleanup to see which .flac files can be deleted? [y/N]: " do_cleanup
  if [[ "$do_cleanup" =~ ^[Yy]$ ]]; then
    exec "$0" "$SRC_DIR" "$DEST_DIR" --cleanup-only --dry-run
  fi
fi

if [[ "$DRYRUN" -eq 1 && "$DELETE" -eq 0 ]]; then
  echo ""
  read -p "Would you like to now perform the actual operation? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    new_args=()
    [[ "$CLEANUP_ONLY" -eq 1 ]] && new_args+=("--cleanup-only")
    [[ "$COPY" -eq 1 ]] && new_args+=("--and-copy-to-ipod-if-successful")
    echo "▶️ Executing real run: $0 \"$SRC_DIR\" \"$DEST_DIR\" ${new_args[*]}"
    exec "$0" "$SRC_DIR" "$DEST_DIR" "${new_args[@]}"
  else
    echo "🚪 Dry-run complete. No changes made."
    exit 0
  fi
fi
