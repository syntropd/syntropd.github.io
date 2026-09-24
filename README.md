# syntropd.github.io

Official website, documentation portal, and Varlink protocol specifications for the **syntropd** project ([https://syntropd.github.io](https://syntropd.github.io)).

> **"Baking AI into systemd as native OS primitives, keeping PID 1 inviolable."**

## Overview

`syntropd.github.io` is a zero-dependency, pure vanilla HTML5, CSS3, and modern ES6 JavaScript static site. It requires zero Node.js/npm dependencies, zero build steps, and relies on zero external CDNs, making it 100% self-contained, high-performance, and friendly to text-mode browsers (`lynx`, `w3m`).

## Architecture & Features

- **High-Contrast Dark Mode Aesthetic**: Inspired by `systemd.io` and `kernel.org`.
- **Interactive System Topology**: Responsive vector (SVG) diagram of Linux kernel primitives, daemons, and client tooling.
- **Emergency Triage Flow Walkthrough**: Step-by-step interactive stepper demonstrating sub-200ms automated service failure diagnosis and rollback checkpointing.
- **Zero-Idle Socket Activation Visualizer**: Illustrates the 0 MB idle RAM footprint lifecycle powered by systemd socket activation.
- **Varlink IDL Browser**: Interactive documentation viewer with syntax-highlighted Varlink interface definitions, method signatures, JSON schemas, and `varlinkctl` command-line invocations.
- **Operator Manual**: Complete `syntropctl(1)` reference and systemd drop-in configuration guide.

## Automated Verification

Run the built-in verification suite:

```bash
python3 scripts/verify_site.py
```

The script audits:
- HTML5 conformance, doctype, and tag balancing.
- 100% link and anchor integrity across all local references.
- Absence of external CDN references (strict offline/self-contained integrity).
- CSS root variables and responsive media queries.
- JavaScript initialization hooks and DOM binding.
- Favicon and SVG valid XML parsing.

## Deployment

Deployments are automated on every push to `main` via GitHub Actions (`.github/workflows/deploy.yml`), publishing directly to GitHub Pages.

## License

Dual-licensed under Apache-2.0 or MIT.
