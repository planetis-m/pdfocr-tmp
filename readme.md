# Benchmark Comparison Findings

This section compares the competitor's latest reported benchmark with our latest measured run.

Important: runtime here is network-sensitive. Single-run speed differences should not be treated
as definitive implementation superiority.

## Run Setup

- Input: `test_files/slides.pdf`
- Mode: `--all-pages` (`72` pages)
- Both runs completed successfully and produced full ordered JSONL outputs.

## Reported Runs

- Competitor (latest):
  - Command: `LD_LIBRARY_PATH=./third_party/pdfium/lib /usr/bin/time -v ./src/app test_files/slides.pdf --all-pages`
  - Wall time: `17.04s`
  - Throughput: `~4.23 pages/s`
  - Peak RSS (`time -v`): `73,228 kB` (`71.51 MiB`)
  - Peak RSS (app tracker): `74,985,472 B` (`71.51 MiB`)
  - CPU: user/system `5.01s / 0.09s`, utilization `29%`
  - Exit status: `0`
  - Note from competitor: tracker `occupied/free/total` fields were `0`; `peak_rss` is the reliable memory metric.

- Ours (latest run in this repo):
  - Command: `/usr/bin/time -f 'elapsed_s=%e' env LD_LIBRARY_PATH=/home/ageralis/tmp/third_party/pdfium/lib /tmp/pdfocr_peak_all /home/ageralis/tmp/test_files/slides.pdf --all-pages`
  - Wall time: `28.23s`
  - Throughput: `~2.55 pages/s`
  - Peak RSS (app tracker): `90,484,736 B` (`86.29 MiB`)
  - Exit status: `0`
  - Output validation: `72/72` pages, `0` errors, `0` retries, strictly increasing page order.

## Correct Memory Metric

For peak process memory, use `peak_rss` (OS/process peak RSS).  
`occupied/free/total` are allocator-state snapshots and are not equivalent to process peak usage.

## Side-by-Side Comparison (Current Data)

- Runtime:
  - Competitor: `17.04s`
  - Ours: `28.23s`
  - Current single-run delta: competitor faster by `11.19s` (`~39.6%`).

- Peak process memory:
  - Competitor: `71.51 MiB`
  - Ours: `86.29 MiB`
  - Delta: competitor lower by `14.78 MiB` (`~17.1%` lower vs ours).

## Findings

1. Both implementations are currently correct on this benchmark (`72` pages completed, exit `0`).
2. Based on the currently provided runs, competitor has better wall time and lower peak RSS.
3. Because OCR calls depend strongly on live network/API behavior, performance claims should be
   presented as run-specific observations, not universal conclusions.
