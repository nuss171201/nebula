#!/usr/bin/env python3
"""Summarises a Time Profiler export for one process.

Usage: analyze-trace.py <time-profile.xml> <process name> [launch-window-ms]

Input is the XML written by:
  xcrun xctrace export --input <file>.trace \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'

Reports CPU time per thread, how long the main thread ran without a break
(the number that matters for dropped frames), and where the app's own code
spent time on and off the main thread.
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

if len(sys.argv) < 3:
    sys.exit(__doc__)
path, target = sys.argv[1], sys.argv[2]
launch_window_ns = int(sys.argv[3]) * 1_000_000 if len(sys.argv) > 3 else 500_000_000
SAMPLE_GAP_NS = 2_500_000  # samples are 1 ms apart; a larger gap means the thread was idle

tree = ET.parse(path)
by_id = {el.get("id"): el for el in tree.iter() if el.get("id") is not None}


def resolve(element):
    """The export writes each value once and refers back to it by id afterwards."""
    ref = element.get("ref")
    return by_id[ref] if ref is not None else element


def frame_info(frame):
    frame = resolve(frame)
    binary = frame.find("binary")
    return frame.get("name") or "?", resolve(binary).get("name") if binary is not None else ""


samples = []
for row in tree.iter("row"):
    time = thread = process = None
    weight = 0
    frames = []
    for child in row:
        value = resolve(child)
        if value.tag == "sample-time":
            time = int(value.text)
        elif value.tag == "thread":
            thread = value.get("fmt")
            owner = value.find("process")
            process = resolve(owner).get("fmt") if owner is not None else None
        elif value.tag == "weight":
            weight = int(value.text)
        elif value.tag in ("backtrace", "tagged-backtrace"):
            frames = [frame_info(frame) for frame in value]
    if process and process.split(" (")[0] == target:
        samples.append((time, thread, weight, frames))

if not samples:
    sys.exit(f"no samples for a process named {target!r}")

samples.sort(key=lambda sample: sample[0])
start = samples[0][0]
per_thread = Counter()
for _, thread, weight, _ in samples:
    per_thread[thread] += weight
main = next((name for name in per_thread if "Main Thread" in name), max(per_thread, key=per_thread.get))
main_samples = [(time, weight, frames) for time, thread, weight, frames in samples if thread == main]


def ms(nanoseconds):
    return nanoseconds / 1e6


def stretches(thread_samples):
    """Runs of consecutive samples: how long the thread was busy without a pause."""
    result, run_start, previous = [], None, None
    for time, _, _ in thread_samples:
        if previous is None or time - previous > SAMPLE_GAP_NS:
            if previous is not None:
                result.append((run_start, previous - run_start + 1_000_000))
            run_start = time
        previous = time
    if previous is not None:
        result.append((run_start, previous - run_start + 1_000_000))
    return result


def app_frame(frames):
    """The innermost frame that belongs to the app binary itself (its own code and linked packages)."""
    for name, binary in frames:
        if binary and binary.split(".")[0] == target:
            return name
    return None


span = ms(samples[-1][0] - start)
print(f"process: {target}   samples: {len(samples)}   CPU: {ms(sum(per_thread.values())):.0f} ms over {span / 1000:.1f} s")
print("\nCPU time by thread:")
for thread, weight in per_thread.most_common(5):
    print(f"  {ms(weight):7.0f} ms  {thread.split(' (')[0]}")
print(f"  ({len(per_thread)} threads in total)")

runs = stretches(main_samples)
launch = [run for run in runs if run[0] - start <= launch_window_ns]
later = [run for run in runs if run[0] - start > launch_window_ns]
for label, group in ((f"first {ms(launch_window_ns):.0f} ms (launch)", launch), ("afterwards", later)):
    longest = sorted(group, key=lambda run: -run[1])[:3]
    over_8 = sum(1 for _, duration in group if duration > 8_000_000)
    over_16 = sum(1 for _, duration in group if duration > 16_000_000)
    described = ", ".join(f"{ms(d):.0f} ms at +{ms(s - start):.0f}" for s, d in longest) or "none"
    cpu = sum(w for t, w, _ in main_samples if (t - start <= launch_window_ns) == (group is launch))
    print(f"\nMain thread, {label}: {ms(cpu):.0f} ms on CPU")
    print(f"  uninterrupted stretches > 8 ms: {over_8}   > 16 ms: {over_16}")
    print(f"  longest: {described}")

for label, group in (("main thread", main_samples), ("other threads", [(t, w, f) for t, th, w, f in samples if th != main])):
    inclusive = Counter()
    for _, weight, frames in group:
        name = app_frame(frames)
        if name:
            inclusive[name] += weight
    print(f"\nApp code on {label} (innermost app frame, inclusive of what it calls):")
    for name, weight in inclusive.most_common(8):
        print(f"  {ms(weight):6.0f} ms  {name[:110]}")
    if not inclusive:
        print("  none sampled")
