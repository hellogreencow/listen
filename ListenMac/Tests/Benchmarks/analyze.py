#!/usr/bin/env python3
"""Summarize end-to-end dictation benchmark JSONL without dependencies."""

import argparse
import json
import re
import statistics
from collections import defaultdict

REFERENCES = {
    "short": "Send the revised launch plan before lunch.",
    "medium": "Listen turns speech into text wherever you type. Hold the right option key, speak naturally, and release. Your words appear automatically without changing apps or breaking your focus.",
    "technical": "The deployment uses a notarized universal binary, a stable bundle identifier, and explicit microphone permissions. Please compare release to paste latency, word error rate, memory use, and cold start behavior across five repeated trials.",
}


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


def edit_distance(left: list[str], right: list[str]) -> int:
    row = list(range(len(right) + 1))
    for index, left_word in enumerate(left, 1):
        next_row = [index]
        for column, right_word in enumerate(right, 1):
            next_row.append(min(
                next_row[-1] + 1,
                row[column] + 1,
                row[column - 1] + (left_word != right_word),
            ))
        row = next_row
    return row[-1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("results", help="JSONL produced by BenchmarkKeyDriver")
    args = parser.parse_args()
    grouped = defaultdict(list)
    with open(args.results, encoding="utf-8") as stream:
        for line in stream:
            result = json.loads(line)
            grouped[(result["app"], result["clip"])].append(result)

    print("app\tclip\truns\tmedian_ms\tmin_ms\tmax_ms\tWER")
    for (app, clip), results in grouped.items():
        latencies = [item["end_to_end_ms"] for item in results if item.get("end_to_end_ms") is not None]
        errors = sum(edit_distance(words(REFERENCES[clip]), words(item.get("pasted_text") or ""))
                     for item in results)
        reference_words = len(words(REFERENCES[clip])) * len(results)
        print(f"{app}\t{clip}\t{len(results)}\t{statistics.median(latencies):.0f}\t"
              f"{min(latencies)}\t{max(latencies)}\t{100 * errors / reference_words:.1f}%")


if __name__ == "__main__":
    main()
