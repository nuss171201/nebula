#!/bin/bash
# Generates the sample media used to test the player. Everything is synthesised
# by ffmpeg (test patterns and sine tones); nothing is downloaded.
#
# Usage: Scripts/make-test-media.sh [--force]
# Output: TestMedia/ (git-ignored). Existing files are kept unless --force is given.
#
#   sdr-h264-1080p.mp4      H.264 8-bit 1080p30 + AAC stereo. The plain case.
#   hdr10-hevc-4k60.mkv     HEVC Main10 2160p60, BT.2020 / PQ, HDR10 mastering metadata + AAC.
#                           The picture is an SDR test pattern tagged as HDR10: it exercises the
#                           10-bit / HDR pipeline, it is not colour-accurate HDR content.
#   hdr10-hevc-4k24-long.mkv  The same kind of picture at 24 frames a second for two and a half minutes
#                           (about 20 Mbit/s): a film's frame rate, and long enough for the player's
#                           stream cache to fill, which the ten-second sample never does.
#   multi-track.mkv         H.264 720p with five audio tracks, two embedded subtitle tracks
#                           and chapters:
#                             a:0 AC-3 5.1    lang=fra  title "Français"
#                             a:1 E-AC-3 5.1  lang=deu  title "Deutsch"
#                             a:2 DTS 5.1     lang=jpn  title "日本語"
#                             a:3 AAC stereo  untagged  title "English"      (title-match case)
#                             a:4 AAC stereo  untagged  no title             (nothing to go on)
#                             s:0 SubRip      lang=spa
#                             s:1 SubRip      lang=eng
#   external-subs.en.srt    External subtitle file matching multi-track.mkv.
#   audio-only.m4a          AAC stereo with a title and an artist and no picture: the mini player's case.
#   long-low-res.mp4        90 seconds of small H.264 + AAC: long enough to have a middle worth resuming in.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="TestMedia"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is not installed (brew install ffmpeg)" >&2; exit 1; }
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FF=(ffmpeg -hide_banner -loglevel error -y)

needs() {
    [[ "$FORCE" == "1" || ! -s "$OUT/$1" ]]
}

if needs sdr-h264-1080p.mp4; then
    echo "==> sdr-h264-1080p.mp4"
    "${FF[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=10" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10" \
        -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
        -c:a aac -b:a 128k -ac 2 -metadata:s:a:0 language=eng \
        -movflags +faststart "$OUT/sdr-h264-1080p.mp4"
fi

if needs hdr10-hevc-4k60.mkv; then
    echo "==> hdr10-hevc-4k60.mkv (4K HEVC 10-bit; this one takes a while)"
    # P3-D65 mastering primaries, 1000 nit peak, in x265's units (0.00002 and 0.0001 cd/m2).
    MASTER="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)"
    "${FF[@]}" -f lavfi -i "testsrc2=size=3840x2160:rate=60:duration=10" \
        -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=10" \
        -c:v libx265 -preset ultrafast -crf 22 -pix_fmt yuv420p10le -tag:v hvc1 \
        -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=$MASTER:max-cll=1000,400:hdr10=1:repeat-headers=1" \
        -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
        -c:a aac -b:a 128k -ac 2 -metadata:s:a:0 language=eng \
        "$OUT/hdr10-hevc-4k60.mkv"
fi

if needs hdr10-hevc-4k24-long.mkv; then
    echo "==> hdr10-hevc-4k24-long.mkv (4K HEVC 10-bit, 150 s; this one takes several minutes)"
    MASTER="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)"
    "${FF[@]}" -f lavfi -i "testsrc2=size=3840x2160:rate=24:duration=150" \
        -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=150" \
        -c:v libx265 -preset ultrafast -crf 22 -pix_fmt yuv420p10le -tag:v hvc1 \
        -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=$MASTER:max-cll=1000,400:hdr10=1:repeat-headers=1" \
        -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
        -c:a aac -b:a 128k -ac 2 -metadata:s:a:0 language=eng \
        "$OUT/hdr10-hevc-4k24-long.mkv"
fi

if needs long-low-res.mp4; then
    echo "==> long-low-res.mp4"
    "${FF[@]}" -f lavfi -i "testsrc2=size=320x180:rate=12:duration=90" \
        -f lavfi -i "sine=frequency=494:sample_rate=48000:duration=90" \
        -c:v libx264 -preset veryfast -crf 28 -g 24 -pix_fmt yuv420p \
        -c:a aac -b:a 64k -ac 2 -movflags +faststart "$OUT/long-low-res.mp4"
fi

if needs audio-only.m4a; then
    echo "==> audio-only.m4a"
    "${FF[@]}" -f lavfi -i "sine=frequency=587:sample_rate=48000:duration=10" \
        -c:a aac -b:a 128k -ac 2 -metadata title="Test Tone" -metadata artist="Signal Generator" \
        "$OUT/audio-only.m4a"
fi

cat >"$WORK/es.srt" <<'EOF'
1
00:00:01,000 --> 00:00:04,000
Subtítulo de prueba uno

2
00:00:06,000 --> 00:00:09,000
Subtítulo de prueba dos

3
00:00:12,000 --> 00:00:16,000
Subtítulo de prueba tres
EOF

cat >"$WORK/en.srt" <<'EOF'
1
00:00:01,000 --> 00:00:04,000
Test subtitle one

2
00:00:06,000 --> 00:00:09,000
Test subtitle two

3
00:00:12,000 --> 00:00:16,000
Test subtitle three
EOF

if needs multi-track.mkv; then
    echo "==> multi-track.mkv"
    cat >"$WORK/chapters.txt" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=5000
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=5000
END=12000
title=Middle
[CHAPTER]
TIMEBASE=1/1000
START=12000
END=20000
title=Ending
EOF
    # A different tone per track makes it audible which one is playing.
    "${FF[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=20" \
        -f lavfi -i "sine=frequency=262:sample_rate=48000:duration=20" \
        -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=20" \
        -f lavfi -i "sine=frequency=392:sample_rate=48000:duration=20" \
        -f lavfi -i "sine=frequency=523:sample_rate=48000:duration=20" \
        -f lavfi -i "sine=frequency=659:sample_rate=48000:duration=20" \
        -i "$WORK/es.srt" -i "$WORK/en.srt" -i "$WORK/chapters.txt" \
        -map 0:v -map 1:a -map 2:a -map 3:a -map 4:a -map 5:a -map 6:s -map 7:s -map_chapters 8 \
        -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
        -c:a:0 ac3 -ac:a:0 6 -b:a:0 384k -metadata:s:a:0 language=fra -metadata:s:a:0 title="Français" \
        -c:a:1 eac3 -ac:a:1 6 -b:a:1 384k -metadata:s:a:1 language=deu -metadata:s:a:1 title="Deutsch" \
        -c:a:2 dca -strict -2 -ac:a:2 6 -b:a:2 768k -metadata:s:a:2 language=jpn -metadata:s:a:2 title="日本語" \
        -c:a:3 aac -ac:a:3 2 -b:a:3 128k -metadata:s:a:3 title="English" \
        -c:a:4 aac -ac:a:4 2 -b:a:4 128k \
        -c:s srt -metadata:s:s:0 language=spa -metadata:s:s:1 language=eng \
        -disposition:a:0 default -disposition:s:0 0 -disposition:s:1 0 \
        "$OUT/multi-track.mkv"
fi

if needs external-subs.en.srt; then
    echo "==> external-subs.en.srt"
    cp "$WORK/en.srt" "$OUT/external-subs.en.srt"
fi

echo
for file in "$OUT"/*; do
    [[ "$file" == *.srt ]] && { printf '%-26s external subtitles\n' "$(basename "$file")"; continue; }
    summary="$(ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,pix_fmt,channels:stream_tags=language \
        -of csv=p=0 "$file" | tr '\n' ' ')"
    printf '%-26s %6s  %s\n' "$(basename "$file")" "$(du -h "$file" | cut -f1)" "$summary"
done
