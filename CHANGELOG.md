# Syntropd Suite Changelog

## 0.6.0 (2026-10-04) — Accelerated Hardware Pipelines & Ada Lovelace Tensor Cores

### Neural Inference Engine (`runtimed`)
- **In-VRAM 4-Bit Marlin GEMV**: Repacked 128-bit Marlin INT4 tiles and custom asynchronous PTX CUDA kernels (`marlin_gemv_kernel`) yielding sub-millisecond per-token generation latencies.
- **Ada Lovelace FP8 Tensor Core Pipeline**: Native F8E4M3 hardware matrix multiplication with dynamic per-channel scaling factors targeting NVIDIA Ada Lovelace / Hopper Tensor Cores.
- **Quantized Paged KV-Cache**: 16-token page tables with dynamic FP8 / INT8 quantization per head, reducing KV cache resident footprint by up to 50% while preserving accuracy.
- **Dual-GPU Speculative Offload**: Transparent gang-scheduled speculative decoding running draft models on `cuda:1` and primary target models on `cuda:0` with automated fallback.

### Suite Components
- **Systemd Deployment**: Coordinated release `v0.6.0` across `syntropd`, `syntropctl`, `inferenced`, `modeld`, `contextd`, `toold`, `runtimed`, `sentry`, and `routerd`.
- **Fleet Installer**: Updated `install.sh` to v0.6.0 with automated NVIDIA Ada Lovelace / Hopper GPU detection, device node permissions, and drop-in configurations.
- **Operator Documentation**: Updated operator manual and landing page with hardware acceleration benchmarks and Varlink interface specifications.

## 0.5.0 (2026-10-03) — Fleet Integration, Shell Completions & QA Consolidation
- Native shell completions for `syn` and `syntropctl`.
- CAS envelope sizing and dynamic memory lease management.
- Causal chronology and drift inspection.
- Autonomous supervisor and crash watchdog.
