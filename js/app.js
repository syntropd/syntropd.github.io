/**
 * syntropd - Native AI Subsystem for systemd
 * Client Interactivity & Visualizers (Pure ES6, Zero External Dependencies)
 */

document.addEventListener('DOMContentLoaded', () => {
  initMobileNav();
  initCopyButtons();
  initArchInspector();
  initTriageStepper();
  initVarlinkBrowser();
});

/* ---------------- 1. Mobile Navigation ---------------- */
function initMobileNav() {
  const toggleBtn = document.querySelector('.nav-toggle');
  const navLinks = document.querySelector('.nav-links');
  if (toggleBtn && navLinks) {
    toggleBtn.addEventListener('click', () => {
      navLinks.classList.toggle('open');
      const expanded = navLinks.classList.contains('open');
      toggleBtn.setAttribute('aria-expanded', expanded);
    });
  }
}

/* ---------------- 2. Copy to Clipboard ---------------- */
function initCopyButtons() {
  document.querySelectorAll('.copy-btn').forEach(button => {
    button.addEventListener('click', async () => {
      const targetId = button.getAttribute('data-target');
      let textToCopy = '';
      if (targetId) {
        const el = document.getElementById(targetId);
        textToCopy = el ? el.innerText : '';
      } else {
        const pre = button.closest('.code-header') ? button.closest('.code-header').nextElementSibling : null;
        if (pre) textToCopy = pre.innerText;
      }

      if (textToCopy) {
        try {
          await navigator.clipboard.writeText(textToCopy);
          const orig = button.innerText;
          button.innerText = 'Copied!';
          button.style.borderColor = 'var(--teal)';
          button.style.color = 'var(--teal)';
          setTimeout(() => {
            button.innerText = orig;
            button.style.borderColor = '';
            button.style.color = '';
          }, 2000);
        } catch (err) {
          console.error('Clipboard copy failed:', err);
        }
      }
    });
  });
}

/* ---------------- 3. Architecture Node Inspector ---------------- */
const ARCH_NODE_DATA = {
  'inferenced': {
    title: 'inferenced.service (Compute & Arbitration Broker)',
    socket: '/run/syntrop/io.syntrop.Inference1',
    interface: 'io.syntrop.Inference1',
    kernel: 'DRM/accel, cgroups v2 (memory.high, cgroup.freeze), PSI, sealed memfd',
    privilege: 'DynamicUser=yes, ProtectSystem=strict, MemoryDenyWriteExecute=yes',
    desc: 'Discovers heterogeneous accelerators (DRM GPU, NPU, CPU AMX/AVX-512) and arbitrates VRAM/RAM allocations. Issues leases with priority tiers (EmergencyTriage > Interactive > Batch). Preempts batch inference workloads via cgroup.freeze during service incidents. Supports zero-copy tensor passing via sealed memfds across Unix domain sockets.',
    methods: ['GetTopology', 'GetPressure', 'AcquireLease', 'ReleaseLease', 'Freeze', 'Thaw', 'StreamInference']
  },
  'modeld': {
    title: 'modeld.service (Content-Addressable Model Store)',
    socket: '/run/syntrop/io.syntrop.Model1',
    interface: 'io.syntrop.Model1',
    kernel: 'VFS reflinks, fanotify, O_TMPFILE, hardlink CAS deduplication',
    privilege: 'DynamicUser=yes, StateDirectory=syntrop/models, ReadOnlyPaths=/usr',
    desc: 'Content-addressable storage cache under /var/lib/models with SHA-256 integrity verification. Deduplicates weights via ext4/xfs/btrfs reflinks. Manages LRU eviction quotas, pinning for emergency triage models, and atomic model staging.',
    methods: ['List', 'Inspect', 'Pin', 'Unpin', 'Prune', 'GetStorageStats']
  },
  'contextd': {
    title: 'contextd.service (Chronology & Drift Observer)',
    socket: '/run/syntrop/io.syntrop.Context1',
    interface: 'io.syntrop.Context1',
    kernel: 'fanotify, inotify, journald cursor API, ring buffer',
    privilege: 'ProtectHome=yes, ProtectSystem=strict, CapabilityBoundingSet=CAP_SYS_ADMIN',
    desc: 'Watches system configuration paths (/etc/systemd/system, /usr/lib/systemd/system, package manager logs). Tracks config diffs, rpm/dpkg transactions, and correlates failure timelines for rapid causal analysis.',
    methods: ['GetUnitContext', 'ListRecentDiffs', 'ListEvents', 'RecordEvent']
  },
  'toold': {
    title: 'toold.service (Sandboxed Remediation Engine)',
    socket: '/run/syntrop/io.syntrop.Tool1',
    interface: 'io.syntrop.Tool1',
    kernel: 'Landlock LSM, seccomp-bpf filters, unshare namespaces, atomic rollback',
    privilege: 'Polkit authentication (org.syntrop.toold.execute), Landlock ABI 1-4',
    desc: 'Executes strictly allowlisted remediation actions in unprivileged Landlock/seccomp sandboxes. Automatically captures pre-execution filesystem snapshots and provides deterministic one-step rollback.',
    methods: ['ListTools', 'ExecuteTool', 'Rollback', 'ListRollbacks']
  },
  'runtimed': {
    title: 'runtimed.service (Neural Model Execution Runtime)',
    socket: '/run/syntrop/io.syntrop.Runtime1',
    interface: 'io.syntrop.Runtime1',
    kernel: 'memfd_secret, sched_setaffinity, socket activation',
    privilege: 'DynamicUser=yes, MemoryDenyWriteExecute=yes, RestrictAddressFamilies=AF_UNIX',
    desc: 'Pure Rust neural inference runtime. Implements GGUF loading, token generation, and normalized vector embeddings without dynamic C runtime dependencies (no libstdc++, no libgomp). Zero idle footprint via socket activation.',
    methods: ['Generate', 'Embed', 'GetModelStatus', 'UnloadModel', 'ListLoadedModels']
  },
  'syntropctl': {
    title: 'syntropctl (Unified Operator & Automation CLI)',
    socket: 'Connects to all /run/syntrop/*.sock',
    interface: 'Client to all io.syntrop.* interfaces',
    kernel: 'Pure AF_UNIX client, zero daemon footprint',
    privilege: 'Standard user or root with polkit authorization',
    desc: 'Unified CLI utility providing operators and scripts with instant status checks, device telemetry, unit failure explanations, model management, and interactive sandboxed remediation.',
    methods: ['status', 'explain', 'devices', 'models', 'drift', 'run', 'generate', 'embed']
  },
  'sentry': {
    title: 'systemd-sentry (Zero-Trust Autonomous Supervisor)',
    socket: '/run/syntrop/sentry.sock (Internal enclave)',
    interface: 'io.syntrop.Sentry1 / D-Bus UnitStatus monitor',
    kernel: 'cgroups v2 event fd, sd-bus event loop',
    privilege: 'Type=notify, Restart=always, WatchdogSec=10s',
    desc: 'Autonomous crash supervisor that intercepts unit failure signals from systemd PID 1 via D-Bus within 2ms. Orchestrates context gathering, emergency inference lease acquisition, and safe self-healing actions.',
    methods: ['TriageUnit', 'GetIncidentReport', 'ResetCircuitBreaker']
  },
  'routerd': {
    title: 'routerd.service (Multi-Provider LLM Router & Reverse Proxy)',
    socket: '/run/syntrop/io.syntrop.Router1 & 127.0.0.1:32768',
    interface: 'io.syntrop.Router1',
    kernel: 'Dual-stack TCP (32768), Unix domain sockets, kernel PSI (/proc/pressure/memory)',
    privilege: 'Slice=ai.slice, MemoryHigh=24M, MemoryMax=32M, ProtectSystem=strict, NoNewPrivileges=yes',
    desc: 'Intelligent multi-provider LLM reverse proxy and dynamic scoring router. Mediates between client workloads (sentry triage, user requests) and compute destinations (local runtimed/inferenced, LAN Ollama clusters, and cloud LLM APIs). Incorporates kernel PSI pressure feedback to offload execution when host memory spikes.',
    methods: ['GetStatus', 'ListProviders', 'ListModels', 'RouteRequest', 'TestProvider']
  }
};

function initArchInspector() {
  const nodes = document.querySelectorAll('.arch-node');
  const panel = document.getElementById('arch-inspector');
  if (!nodes.length || !panel) return;

  nodes.forEach(node => {
    node.addEventListener('click', () => {
      const nodeId = node.getAttribute('data-node');
      const data = ARCH_NODE_DATA[nodeId];
      if (!data) return;

      // Update active state
      nodes.forEach(n => n.classList.remove('active'));
      node.classList.add('active');

      // Populate Inspector Panel
      panel.innerHTML = `
        <div class="inspector-title">
          <span>${escapeHtml(data.title)}</span>
          <span class="badge" style="background: var(--teal-dim); color: var(--teal); padding: 0.15rem 0.5rem; font-size: 0.75rem; border-radius: 4px; border: 1px solid rgba(0,210,180,0.3);">ACTIVE COMPONENT</span>
        </div>
        <p style="margin: 0.75rem 0; font-size: 0.92rem; color: var(--text-muted);">${escapeHtml(data.desc)}</p>
        <div class="inspector-meta">
          <div class="meta-item">
            <span>Varlink Socket</span>
            <code>${escapeHtml(data.socket)}</code>
          </div>
          <div class="meta-item">
            <span>Primary Interface</span>
            <code>${escapeHtml(data.interface)}</code>
          </div>
          <div class="meta-item">
            <span>Kernel Primitives</span>
            <div style="font-size: 0.8rem; margin-top: 0.2rem; color: var(--text-main);">${escapeHtml(data.kernel)}</div>
          </div>
          <div class="meta-item">
            <span>systemd Security</span>
            <div style="font-size: 0.8rem; margin-top: 0.2rem; color: var(--teal);">${escapeHtml(data.privilege)}</div>
          </div>
        </div>
        <div style="margin-top: 0.75rem;">
          <span style="font-family: var(--font-mono); font-size: 0.75rem; text-transform: uppercase; color: var(--text-dim);">Supported Methods:</span>
          <div style="display: flex; gap: 0.4rem; flex-wrap: wrap; margin-top: 0.4rem;">
            ${data.methods.map(m => `<span style="font-family: var(--font-mono); font-size: 0.78rem; background: var(--bg-surface); border: 1px solid var(--border); padding: 0.15rem 0.5rem; border-radius: 3px; color: var(--cyan);">${escapeHtml(m)}</span>`).join('')}
          </div>
        </div>
      `;
      panel.classList.add('visible');
    });
  });
}

/* ---------------- 4. Triage Stepper Walkthrough ---------------- */
const TRIAGE_STEPS = [
  {
    step: 1,
    title: 'Phase 1: Fault Interception & D-Bus Signal Capture',
    latency: '1.2 ms',
    desc: 'A critical service (e.g., payment-worker.service) experiences an unhandled segmentation fault (SIGSEGV) or unexpected non-zero exit code. systemd PID 1 transitions the unit to failed state and broadcasts a JobRemoved / UnitPropertiesChanged signal on the system D-Bus.',
    systemAction: 'systemd-sentry listens to org.freedesktop.systemd1 and captures the failure event within 1.2ms, halting immediate retry thrashing.',
    cmd: '# Immediate signal captured by sentry:\norg.freedesktop.systemd1.Manager.JobRemoved(uint32 412, objectpath "/org/freedesktop/systemd1/job/412", "payment-worker.service", "failed")'
  },
  {
    step: 2,
    title: 'Phase 2: Micro-Journal Slicing & Cgroup PSI Snapshots',
    latency: '8.4 ms',
    desc: 'sentry immediately slices the exact systemd journal log window (last 64 lines) specific to the failed cgroup scope and captures the /proc/pressure/{cpu,memory,io} statistics to isolate out-of-memory or resource starvation triggers.',
    systemAction: 'Zero-copy journal cursor positioning isolates relevant logs without scanning gigabytes of disk logs.',
    cmd: '$ syntropctl explain payment-worker.service --dry-run\n[JOURNAL SLICE] Captured 42 log lines: "fatal: failed to allocate 4194304 bytes at 0x7f9a12bc"'
  },
  {
    step: 3,
    title: 'Phase 3: Chronology & Configuration Drift Correlation',
    latency: '14.1 ms',
    desc: 'sentry queries contextd over /run/syntrop/io.syntrop.Context1 via GetUnitContext. contextd correlates the crash with recent /etc configuration changes, rpm/deb package transactions, or unit drop-in modifications.',
    systemAction: 'contextd identifies that /etc/systemd/system/payment-worker.service.d/limits.conf was modified 3 minutes prior, reducing MemoryMax from 4G to 256M.',
    cmd: '$ varlinkctl call /run/syntrop/io.syntrop.Context1 io.syntrop.Context1.GetUnitContext \'{"unit":"payment-worker.service","since_seconds":3600}\'\n{\n  "context": {\n    "config_diffs": [{"file_path": "/etc/systemd/system/payment-worker.service.d/limits.conf", "diff": "-MemoryMax=4G\\n+MemoryMax=256M"}],\n    "package_upgrades": []\n  }\n}'
  },
  {
    step: 4,
    title: 'Phase 4: Emergency Triage Compute Lease Allocation',
    latency: '19.5 ms',
    desc: 'sentry requests a dedicated compute lease from inferenced via AcquireLease with priority="EmergencyTriage". inferenced inspects GPU/NPU pressure; if saturated with low-priority batch workloads, it issues cgroup.freeze to batch jobs within 250ms and assigns the accelerator plane to the triage enclave.',
    systemAction: 'Hardware accelerator access guaranteed for critical system diagnostics without failing in out-of-memory situations.',
    cmd: '$ varlinkctl call /run/syntrop/io.syntrop.Inference1 io.syntrop.Inference1.AcquireLease \'{"priority":"EmergencyTriage","memory_bytes":2147483648}\'\n{\n  "lease_id": "lease-98b7-4f11-a832",\n  "plane_id": "gpu-drm-renderD128",\n  "allocated_memory": 2147483648\n}'
  },
  {
    step: 5,
    title: 'Phase 5: High-Precision Remediation Token Generation',
    latency: '142.0 ms',
    desc: 'runtimed is socket-activated by sentry. Loaded with a dedicated compact reasoning model (e.g. qwen2.5-coder or deepseek-r1-distill pinned in modeld CAS store), runtimed processes the prompt containing the sliced journal, PSI stats, and config diff to produce a deterministic root-cause diagnosis and remediation plan.',
    systemAction: 'Root cause identified: "OOM killer triggered due to restrictive 256M cgroup drop-in; recommendation: restore MemoryMax=4G".',
    cmd: '$ varlinkctl call /run/syntrop/io.syntrop.Runtime1 io.syntrop.Runtime1.Generate \'{"model":"qwen-triage:1.5b","prompt":"[TRIAGE PROMPT]...","max_tokens":256,"temperature":0.0}\''
  },
  {
    step: 6,
    title: 'Phase 6: Sandboxed Remediation & Atomic Rollback Checkpoint',
    latency: '168.2 ms',
    desc: 'sentry passes the remediation action to toold over /run/syntrop/io.syntrop.Tool1. toold validates the action against its strict allowlist, enters an unprivileged Landlock/seccomp sandbox, creates a rollback checkpoint, and updates the drop-in file atomically.',
    systemAction: 'Snapshot captured in /var/lib/syntrop/rollbacks/rb-4819.json; limits.conf restored safely.',
    cmd: '$ varlinkctl call /run/syntrop/io.syntrop.Tool1 io.syntrop.Tool1.ExecuteTool \'{"name":"restore_dropin","args":["payment-worker.service","limits.conf"],"target_unit":"payment-worker.service"}\'\n{\n  "result": {"exit_code": 0, "stdout": "Restored 4G allocation."},\n  "rollback_id": "rb-4819-fa92"\n}'
  },
  {
    step: 7,
    title: 'Phase 7: Service Restoration & Deterministic Audit Trail',
    latency: '185.0 ms',
    desc: 'sentry calls systemctl daemon-reload and systemctl restart payment-worker.service. The unit restarts cleanly. sentry records the incident resolution in contextd and logs an audit record accessible via syntropctl explain.',
    systemAction: 'Zero operator intervention required; total elapsed incident recovery time: 185 ms.',
    cmd: '$ syntropctl explain payment-worker.service\n● payment-worker.service - Payment Processing Engine\n     Status: Active (running) since Wed 2026-09-24 05:18:02 UTC; 10s ago\n     Triage Incident #4819: Resolved in 185ms (OOM -> limits.conf restored)\n     Audit Checkpoint: /var/lib/syntrop/rollbacks/rb-4819-fa92'
  }
];

function initTriageStepper() {
  const container = document.getElementById('triage-stepper');
  if (!container) return;

  const tracker = container.querySelector('.step-tracker');
  const card = container.querySelector('.step-content-card');
  if (!tracker || !card) return;

  function renderStep(idx) {
    const data = TRIAGE_STEPS[idx];
    tracker.querySelectorAll('.step-btn').forEach((btn, i) => {
      btn.classList.toggle('active', i === idx);
    });

    card.innerHTML = `
      <div class="step-header">
        <div class="step-title">${escapeHtml(data.title)}</div>
        <div class="step-latency">⏱ ${escapeHtml(data.latency)}</div>
      </div>
      <p style="color: var(--text-main); font-size: 0.95rem; margin-bottom: 0.75rem;">${escapeHtml(data.desc)}</p>
      <div class="callout" style="margin: 0.75rem 0; padding: 0.75rem 1rem;">
        <div class="callout-title" style="font-size: 0.75rem;">SYSTEM ACTION</div>
        <p style="font-size: 0.88rem; color: var(--text-muted);">${escapeHtml(data.systemAction)}</p>
      </div>
      <div class="code-header" style="margin-top: 1rem;">
        <span>TELEMETRY / IPC LOG</span>
        <button class="copy-btn">Copy</button>
      </div>
      <pre><code>${escapeHtml(data.cmd)}</code></pre>
      <div style="display: flex; justify-content: space-between; margin-top: 1rem;">
        <button class="btn btn-secondary prev-step" style="padding: 0.4rem 0.8rem; font-size: 0.85rem;" ${idx === 0 ? 'disabled style="opacity: 0.4; cursor: not-allowed;"' : ''}>← Previous Phase</button>
        <button class="btn btn-primary next-step" style="padding: 0.4rem 0.8rem; font-size: 0.85rem;">${idx === TRIAGE_STEPS.length - 1 ? 'Restart Walkthrough ↻' : 'Next Phase →'}</button>
      </div>
    `;

    // Reattach listeners
    initCopyButtons();
    const prevBtn = card.querySelector('.prev-step');
    const nextBtn = card.querySelector('.next-step');

    if (prevBtn && idx > 0) {
      prevBtn.addEventListener('click', () => renderStep(idx - 1));
    }
    if (nextBtn) {
      nextBtn.addEventListener('click', () => {
        if (idx === TRIAGE_STEPS.length - 1) {
          renderStep(0);
        } else {
          renderStep(idx + 1);
        }
      });
    }
  }

  // Initial render
  renderStep(0);

  // Tracker button clicks
  tracker.querySelectorAll('.step-btn').forEach((btn, idx) => {
    btn.addEventListener('click', () => renderStep(idx));
  });
}

/* ---------------- 5. Varlink Protocol Browser ---------------- */
const VARLINK_SPECS = {
  'inferenced': {
    name: 'io.syntrop.Inference1',
    socket: '/run/syntrop/io.syntrop.Inference1',
    description: 'Hardware compute discovery, multi-accelerator lease arbitration, PSI telemetry, and streaming model inference.',
    idl: `interface io.syntrop.Inference1

type ComputePlane (
  id: string,
  name: string,
  kind: string,
  total_memory: int,
  available_memory: int,
  is_triage_reserved: bool
)

type LeaseInfo (
  id: string,
  plane_id: string,
  allocated_memory: int,
  priority: string,
  state: string,
  client_unit: ?string,
  client_pid: ?int
)

type ModelInfo (
  id: string,
  format: string,
  path: string,
  estimated_memory: int,
  placement: string
)

method GetTopology() -> (
  planes: []ComputePlane,
  total_ram: int,
  available_ram: int,
  cpu_cores: int
)

method GetPressure() -> (
  level: string,
  cpu_some: float,
  memory_some: float,
  io_some: float
)

method AcquireLease(
  priority: string,
  memory_bytes: int,
  plane: ?string,
  unit: ?string,
  pid: ?int
) -> (
  lease_id: string,
  plane_id: string,
  allocated_memory: int
)

method ReleaseLease(lease_id: string) -> ()
method Yield(lease_id: string) -> ()
method Freeze(lease_id: string) -> ()
method Thaw(lease_id: string) -> ()
method ListLeases() -> (leases: []LeaseInfo)
method ListModels() -> (models: []ModelInfo)

method RegisterModel(
  id: string,
  format: string,
  path: string,
  estimated_bytes: int
) -> ()

method StreamInference(
  model: string,
  prompt: string
) -> (
  chunk: string
)

error MethodNotFound (method: string)
error InvalidParameter (parameter: string)
error ResourceExhaustion (plane: string, requested: int, available: int)
error PlaneNotFound (plane: string)
error LeaseNotFound (lease_id: string)
error ModelNotFound (model: string)`,
    exampleCmd: `varlinkctl call unix:/run/syntrop/io.syntrop.Inference1 io.syntrop.Inference1.GetTopology '{}'`,
    exampleOut: `{\n  "planes": [\n    {"available_memory": 15998242816, "id": "drm-renderD128", "is_triage_reserved": false, "kind": "drm_gpu", "name": "NVIDIA GeForce RTX 4090", "total_memory": 25769803776}\n  ],\n  "cpu_cores": 32,\n  "total_ram": 67108864000,\n  "available_ram": 48210948000\n}`
  },

  'modeld': {
    name: 'io.syntrop.Model1',
    socket: '/run/syntrop/io.syntrop.Model1',
    description: 'Content-Addressable Model Store under /var/lib/models with SHA-256 validation, LRU eviction, and triage pinning.',
    idl: `interface io.syntrop.Model1

type ModelEntry (
  id: string,
  digest: string,
  name: ?string,
  tag: ?string,
  size_bytes: int,
  pinned: bool,
  format: string
)

method List() -> (models: []ModelEntry)
method Inspect(id: string) -> (info: ModelEntry, metadata: ?string)
method Pin(id: string) -> ()
method Unpin(id: string) -> ()
method Prune(max_bytes: int) -> (reclaimed_bytes: int)
method GetStorageStats() -> (total_bytes: int, model_count: int, pinned_count: int)

error NoSuchModel(id: string)
error InvalidIdentifier(id: string)
error InvalidParameter(parameter: string, reason: string)
error OperationFailed(reason: string)`,
    exampleCmd: `varlinkctl call unix:/run/syntrop/io.syntrop.Model1 io.syntrop.Model1.List '{}'`,
    exampleOut: `{\n  "models": [\n    {"digest": "sha256:7f9a12bc...", "format": "gguf", "id": "qwen2.5-coder-7b", "name": "qwen2.5-coder", "pinned": true, "size_bytes": 4819000000, "tag": "7b"}\n  ]\n}`
  },

  'contextd': {
    name: 'io.syntrop.Context1',
    socket: '/run/syntrop/io.syntrop.Context1',
    description: 'System chronology, configuration drift tracking, package upgrade transactions, and unit causality analysis.',
    idl: `interface io.syntrop.Context1

type ConfigDiff (
  file_path: string,
  timestamp_us: int,
  diff_content: string
)

type PackageTransaction (
  timestamp_us: int,
  action: string,
  package_name: string,
  version: string
)

type UnitContext (
  unit_name: string,
  config_diffs: []ConfigDiff,
  package_upgrades: []PackageTransaction,
  summary: string
)

type Event (
  id: string,
  timestamp_us: int,
  source: string,
  unit: ?string,
  summary: string,
  details: ?string
)

method GetUnitContext(unit: string, since_seconds: int) -> (context: UnitContext)
method ListRecentDiffs(since_seconds: int) -> (diffs: []ConfigDiff)
method ListEvents(unit: ?string, since_seconds: int, limit: int) -> (events: []Event)
method RecordEvent(source: string, unit: ?string, summary: string, details: ?string) -> (event_id: string)

error InvalidParameter(parameter: string)
error OperationFailed(reason: string)`,
    exampleCmd: `varlinkctl call unix:/run/syntrop/io.syntrop.Context1 io.syntrop.Context1.ListRecentDiffs '{"since_seconds": 3600}'`,
    exampleOut: `{\n  "diffs": [\n    {"diff_content": "--- /etc/systemd/system/app.service\\n+++ /etc/systemd/system/app.service\\n@@ -10,1 +10,1 @@\\n-ExecStart=/usr/bin/app -v\\n+ExecStart=/usr/bin/app -vv", "file_path": "/etc/systemd/system/app.service", "timestamp_us": 1727154982000000}\n  ]\n}`
  },

  'toold': {
    name: 'io.syntrop.Tool1',
    socket: '/run/syntrop/io.syntrop.Tool1',
    description: 'Sandboxed diagnostic and remediation action dispatcher governed by Landlock LSM, seccomp filters, and atomic rollback.',
    idl: `interface io.syntrop.Tool1

type ToolInfo (
  name: string,
  description: string,
  mode: string,
  timeout_ms: int
)

type ExecutionResult (
  command: string,
  exit_code: int,
  stdout: string,
  stderr: string,
  duration_ms: int
)

type RollbackRecord (
  id: string,
  timestamp_us: int,
  target_path: ?string,
  target_unit: ?string,
  summary: string
)

method ListTools() -> (tools: []ToolInfo)
method ExecuteTool(name: string, args: []string, target_unit: ?string) -> (result: ExecutionResult, rollback_id: ?string)
method Rollback(rollback_id: string) -> (restored: RollbackRecord)
method ListRollbacks(since_seconds: int, limit: int) -> (records: []RollbackRecord)

error ToolNotFound(name: string)
error ExecutionFailed(reason: string)
error PermissionDenied(reason: string)
error Timeout(limit_ms: int)
error InvalidParameter(parameter: string)`,
    exampleCmd: `varlinkctl call unix:/run/syntrop/io.syntrop.Tool1 io.syntrop.Tool1.ListTools '{}'`,
    exampleOut: `{\n  "tools": [\n    {"description": "Reload systemd manager configuration", "mode": "safe", "name": "daemon_reload", "timeout_ms": 5000},\n    {"description": "Restart specific failed service unit", "mode": "remediation", "name": "unit_restart", "timeout_ms": 10000}\n  ]\n}`
  },

  'runtimed': {
    name: 'io.syntrop.Runtime1',
    socket: '/run/syntrop/io.syntrop.Runtime1',
    description: 'Neural model execution runtime in pure Rust (Candle/in-process inference), batching, text generation, and embeddings.',
    idl: `interface io.syntrop.Runtime1

type LoadedModel (
  name: string,
  architecture: string,
  parameter_count: int,
  memory_bytes: int,
  context_window: int,
  compute_backend: string
)

type GenerationResult (
  text: string,
  prompt_tokens: int,
  completion_tokens: int,
  finish_reason: string,
  duration_ms: int
)

method Generate(model: string, prompt: string, max_tokens: int, temperature: float) -> (result: GenerationResult)
method Embed(model: string, text: string) -> (embedding: []float)
method GetModelStatus(model: string) -> (status: string, model: ?LoadedModel)
method UnloadModel(model: string) -> (freed_bytes: int)
method ListLoadedModels() -> (models: []LoadedModel)

error ModelNotFound(model: string)
error ContextExceeded(requested: int, max: int)
error GenerationFailed(reason: string)
error InvalidParameter(parameter: string)`,
    exampleCmd: `varlinkctl call unix:/run/syntrop/io.syntrop.Runtime1 io.syntrop.Runtime1.GetModelStatus '{"model": "qwen2.5-coder-7b"}'`,
    exampleOut: `{\n  "status": "loaded",\n  "model": {\n    "architecture": "qwen2",\n    "compute_backend": "cuda",\n    "context_window": 32768,\n    "memory_bytes": 4819000000,\n    "name": "qwen2.5-coder-7b",\n    "parameter_count": 7615000000\n  }\n}`
  },

  'routerd': {
    name: 'io.syntrop.Router1',
    socket: '/run/syntrop/io.syntrop.Router1',
    description: 'Intelligent model routing, multi-provider scoring, latency metrics, and wire protocol reverse proxying.',
    idl: `interface io.syntrop.Router1

type ProviderInfo (
  id: string,
  name: string,
  kind: string,
  base_url: string,
  tier: string,
  is_healthy: bool,
  weight: float,
  models: []string,
  total_requests: int,
  total_errors: int,
  last_latency_ms: float
)

type ScoredCandidateInfo (
  provider_id: string,
  model_name: string,
  total_score: float,
  speed_score: float,
  cost_score: float,
  capability_score: float,
  estimated_cost: float,
  reason: string
)

method GetStatus() -> (
  status: string,
  version: string,
  uptime_seconds: int,
  total_requests: int,
  active_requests: int,
  providers_count: int,
  healthy_providers_count: int,
  psi_level: string,
  psi_memory_some: float,
  rss_bytes: int,
  rss_mb: float
)

method ListProviders() -> (
  providers: []ProviderInfo
)

method ListModels() -> (
  models: []string
)

method RouteRequest(
  model: ?string,
  tier: ?string,
  estimated_tokens: ?int,
  require_stream: ?bool
) -> (
  candidates: []ScoredCandidateInfo
)

method TestProvider(
  provider_id: string
) -> (
  provider_id: string,
  healthy: bool,
  latency_ms: float,
  error: ?string
)`,
    exampleCmd: `varlinkctl call unix:/run/syntrop/io.syntrop.Router1 io.syntrop.Router1.GetStatus '{}'`,
    exampleOut: `{\n  "active_requests": 0,\n  "healthy_providers_count": 3,\n  "providers_count": 3,\n  "psi_level": "normal",\n  "psi_memory_some": 0.0,\n  "rss_mb": 9.12,\n  "status": "operational",\n  "total_requests": 428,\n  "uptime_seconds": 8040,\n  "version": "0.3.0"\n}`
  },

  'service': {
    name: 'org.varlink.service',
    socket: '/run/syntrop/io.syntrop.*',
    description: 'Standard Varlink introspection interface implemented by all syntropd daemons.',
    idl: `interface org.varlink.service

method GetInfo() -> (
  vendor: string,
  product: string,
  version: string,
  url: string,
  interfaces: []string
)

method GetInterfaceDescription(interface: string) -> (description: string)

error InterfaceNotFound (interface: string)
error MethodNotFound (method: string)
error MethodNotImplemented (method: string)
error InvalidParameter (parameter: string)`,
    exampleCmd: `varlinkctl info unix:/run/syntrop/io.syntrop.Inference1`,
    exampleOut: `Vendor: syntropd\nProduct: inferenced\nVersion: 0.1.0\nURL: https://github.com/syntropd/inferenced\nInterfaces:\n  org.varlink.service\n  io.syntrop.Inference1`
  }
};

function initVarlinkBrowser() {
  const browser = document.getElementById('varlink-browser');
  if (!browser) return;

  const links = browser.querySelectorAll('.spec-nav-link');
  const viewTitle = browser.querySelector('#spec-name');
  const viewSocket = browser.querySelector('#spec-socket');
  const viewDesc = browser.querySelector('#spec-desc');
  const viewIdl = browser.querySelector('#spec-idl');
  const viewCmd = browser.querySelector('#spec-cmd');
  const viewOut = browser.querySelector('#spec-out');

  function renderSpec(key) {
    const data = VARLINK_SPECS[key];
    if (!data) return;

    links.forEach(l => l.classList.toggle('active', l.getAttribute('data-spec') === key));
    if (viewTitle) viewTitle.innerText = data.name;
    if (viewSocket) viewSocket.innerText = data.socket;
    if (viewDesc) viewDesc.innerText = data.description;
    if (viewIdl) viewIdl.innerText = data.idl;
    if (viewCmd) viewCmd.innerText = data.exampleCmd;
    if (viewOut) viewOut.innerText = data.exampleOut;
  }

  const hashMap = {
    '#inference': 'inferenced',
    '#model': 'modeld',
    '#context': 'contextd',
    '#tool': 'toold',
    '#runtime': 'runtimed',
    '#router': 'routerd',
    '#service': 'service'
  };

  links.forEach(link => {
    link.addEventListener('click', (e) => {
      const specKey = link.getAttribute('data-spec');
      renderSpec(specKey);
    });
  });

  // Check URL hash or default to inferenced
  const initialHash = window.location.hash;
  if (initialHash && hashMap[initialHash]) {
    renderSpec(hashMap[initialHash]);
  } else {
    renderSpec('inferenced');
  }

  window.addEventListener('hashchange', () => {
    const hash = window.location.hash;
    if (hash && hashMap[hash]) {
      renderSpec(hashMap[hash]);
    }
  });
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
