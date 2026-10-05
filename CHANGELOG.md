# Syntropd Suite Changelog

## 0.6.2 (2026-10-05) — Sovereign Substrate Boundaries, Core Decoupling & Polkit Suppression

### Substrate Boundary & openOODA Port (`runtimed`)
- **Port Trait Substrate Boundary**: Implemented `SubstratePort` trait boundary in `runtimed-model`, encapsulating direct Candle tensor operations and CUDA kernels (`fp8_gemm`, `marlin_gemv`) inside `CandleSubstrate`.
- **Architecture Decoupling**: Decoupled Qwen2, Gemma4, Granite, and Phi3 decoder architectures and sampling policies from raw candle dependencies.
- **Async-in-Core Elimination**: Decoupled `spawn_psi_monitor` and PipeWire audio capture to `runtimed-daemon`, keeping `runtimed-core` strictly synchronous.

### Sandboxed Action Runner (`toold`)
- **Core Decoupling**: Decoupled async runners, repair loops, and code completers into `toold-daemon`, leaving `toold-core` purely synchronous with zero async runtime dependencies.

### Threat Model Hardening (`syntropctl`)
- **Polkit & Elevated Auth Focus Suppression**: Implemented active window title and process tree inspection to detect elevated authentication dialogs (Polkit, `pkexec`, sudo) and immediately abort automated desktop actuation.

### Suite Synchronization
- Coordinated release `v0.6.2` across all 10 ecosystem repositories with unified workspace dependency alignment.

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
