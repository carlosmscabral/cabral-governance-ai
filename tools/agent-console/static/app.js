/**
 * Agent Console & Wire Inspector — Client Engine (Zero-Build ES6 + Jetski Sidecar Ready)
 */

const state = {
  demos: [],
  activeDemo: null,
  profile: "vertex_stream_query",
  sessionId: "",
  turns: [],
  selectedTurnId: null,
  auth: null,
  leftPanePct: Number(localStorage.getItem("agent_console_split_pct")) || 50,
};

// Sidecar-aware fetch wrapper (attaches X-Sidecar-Token if running inside Jetski AuxPane)
function apiFetch(url, options = {}) {
  const params = new URLSearchParams(window.location.search);
  const sidecarToken = params.get("token");
  const headers = new Headers(options.headers || {});
  if (sidecarToken && !headers.has("X-Sidecar-Token")) {
    headers.set("X-Sidecar-Token", sidecarToken);
  }
  return fetch(url, { ...options, headers });
}

async function safeParseJsonResponse(res) {
  const rawText = await res.text();
  try {
    return JSON.parse(rawText);
  } catch (_err) {
    return {
      ok: false,
      status_code: res.status,
      error: rawText ? rawText.slice(0, 400) : `HTTP ${res.status} ${res.statusText}`,
      wire: {
        response: {
          status_code: res.status,
          headers: {},
          body: { raw_error: rawText.slice(0, 400) },
        },
      },
    };
  }
}

// DOM References
const els = {
  splitLayout: document.getElementById("splitLayout"),
  paneResizer: document.getElementById("paneResizer"),
  demoSelect: document.getElementById("demoSelect"),
  profileSelect: document.getElementById("profileSelect"),
  personaInput: document.getElementById("personaInput"),
  personaList: document.getElementById("personaList"),
  authDrawerBtn: document.getElementById("authDrawerBtn"),
  authStatusDot: document.getElementById("authStatusDot"),
  authStatusText: document.getElementById("authStatusText"),
  httpMethodSelect: document.getElementById("httpMethodSelect"),
  endpointUrlInput: document.getElementById("endpointUrlInput"),
  engineBadge: document.getElementById("engineBadge"),
  sessionBadge: document.getElementById("sessionBadge"),
  activeSessionId: document.getElementById("activeSessionId"),
  createSessionBtn: document.getElementById("createSessionBtn"),
  resetSessionBtn: document.getElementById("resetSessionBtn"),
  clearChatBtn: document.getElementById("clearChatBtn"),
  scenariosGrid: document.getElementById("scenariosGrid"),
  scenarioCountBadge: document.getElementById("scenarioCountBadge"),
  scenarioPresenterNote: document.getElementById("scenarioPresenterNote"),
  autoSendScenarioToggle: document.getElementById("autoSendScenarioToggle"),
  chatFeed: document.getElementById("chatFeed"),
  rawComposerDrawer: document.getElementById("rawComposerDrawer"),
  toggleRawDrawerBtn: document.getElementById("toggleRawDrawerBtn"),
  resetTemplateBtn: document.getElementById("resetTemplateBtn"),
  customHeadersEditor: document.getElementById("customHeadersEditor"),
  customBodyEditor: document.getElementById("customBodyEditor"),
  promptInput: document.getElementById("promptInput"),
  sendBtn: document.getElementById("sendBtn"),
  // Inspector
  inspectorTurnTitle: document.getElementById("inspectorTurnTitle"),
  inspectorMetrics: document.getElementById("inspectorMetrics"),
  metricStatusBadge: document.getElementById("metricStatusBadge"),
  metricTtftBadge: document.getElementById("metricTtftBadge"),
  metricTotalBadge: document.getElementById("metricTotalBadge"),
  metricChunksBadge: document.getElementById("metricChunksBadge"),
  verdictBanner: document.getElementById("verdictBanner"),
  leakWarningBanner: document.getElementById("leakWarningBanner"),
  tabChunkCounter: document.getElementById("tabChunkCounter"),
  reqTimestamp: document.getElementById("reqTimestamp"),
  reqLineBox: document.getElementById("reqLineBox"),
  reqHeadersPre: document.getElementById("reqHeadersPre"),
  reqBodyPre: document.getElementById("reqBodyPre"),
  toolCallsSection: document.getElementById("toolCallsSection"),
  toolCallsContainer: document.getElementById("toolCallsContainer"),
  respConsolidatedPre: document.getElementById("respConsolidatedPre"),
  respHeadersPre: document.getElementById("respHeadersPre"),
  respRawPre: document.getElementById("respRawPre"),
  chunksTimeline: document.getElementById("chunksTimeline"),
  curlPre: document.getElementById("curlPre"),
  // Auth Modal
  authModal: document.getElementById("authModal"),
  closeAuthModalBtn: document.getElementById("closeAuthModalBtn"),
  authModeSelect: document.getElementById("authModeSelect"),
  gcloudConfigInput: document.getElementById("gcloudConfigInput"),
  manualTokenRow: document.getElementById("manualTokenRow"),
  manualTokenInput: document.getElementById("manualTokenInput"),
  authAccountLabel: document.getElementById("authAccountLabel"),
  authMaskedToken: document.getElementById("authMaskedToken"),
  authFetchedAt: document.getElementById("authFetchedAt"),
  authTtlLabel: document.getElementById("authTtlLabel"),
  refreshTokenBtn: document.getElementById("refreshTokenBtn"),
  delegatedEnableToggle: document.getElementById("delegatedEnableToggle"),
  delegatedFields: document.getElementById("delegatedFields"),
  delegatedHeaderName: document.getElementById("delegatedHeaderName"),
  delegatedTokenInput: document.getElementById("delegatedTokenInput"),
  saveAuthConfigBtn: document.getElementById("saveAuthConfigBtn"),
};

// ==============================================================================
// Initialization & Discovery
// ==============================================================================

async function init() {
  applySplitPercentage(state.leftPanePct);
  bindEvents();
  await loadDemosAndAuth();
}

async function loadDemosAndAuth() {
  try {
    const res = await apiFetch("/api/demos");
    const data = await res.json();
    state.demos = data.demos || [];
    state.auth = data.auth || null;

    renderAuthStatus(state.auth);
    populateDemoSelect();
  } catch (err) {
    console.error("Erro ao carregar demos:", err);
  }
}

function populateDemoSelect() {
  els.demoSelect.innerHTML = "";
  state.demos.forEach((d) => {
    const opt = document.createElement("option");
    opt.value = d.id;
    opt.textContent = d.title;
    els.demoSelect.appendChild(opt);
  });
  const customOpt = document.createElement("option");
  customOpt.value = "__custom__";
  customOpt.textContent = "+ Endpoint Customizado (Livre)";
  els.demoSelect.appendChild(customOpt);

  if (state.demos.length > 0) {
    selectDemo(state.demos[0].id);
  } else {
    selectDemo("__custom__");
  }
}

function selectDemo(demoId) {
  const found = state.demos.find((d) => d.id === demoId);
  state.activeDemo = found || null;
  state.sessionId = "";
  renderSessionBadge();

  if (found) {
    state.profile = found.default_profile || "vertex_stream_query";
    els.profileSelect.value = state.profile;
    els.personaInput.value = found.default_user_id || "cliente-demo";

    els.personaList.innerHTML = "";
    (found.personas || []).forEach((p) => {
      const opt = document.createElement("option");
      opt.value = p.id;
      opt.label = p.label || p.id;
      els.personaList.appendChild(opt);
    });

    if (found.engine_id) {
      const agwEgress = found.agent_gateway_egress
        ? found.agent_gateway_egress.split("/").pop()
        : "";
      const agwIngress =
        found.agent_gateway_ingress && found.agent_gateway_ingress !== found.agent_gateway_egress
          ? found.agent_gateway_ingress.split("/").pop()
          : "";
      const agwSuffix = agwEgress
        ? ` • Egress: ${agwEgress}`
        : agwIngress
        ? ` • Ingress: ${agwIngress}`
        : "";
      els.engineBadge.textContent = `Engine: ${found.engine_id}${agwSuffix}`;
      els.engineBadge.title = [
        `Reasoning Engine: ${found.reasoning_engine_name || found.engine_id}`,
        found.agent_gateway_egress ? `Agent Gateway Egress: ${found.agent_gateway_egress}` : "",
        found.mcp_url ? `MCP Backend: ${found.mcp_url}` : "",
      ]
        .filter(Boolean)
        .join("\n");
      els.engineBadge.style.opacity = "1";
    } else {
      els.engineBadge.textContent = "Engine: Não deployado";
      els.engineBadge.style.opacity = "0.65";
    }
  } else {
    els.engineBadge.textContent = "Custom Target";
  }

  applyProfileDefaults();
  renderScenarios();
}

function renderSessionBadge() {
  if (state.sessionId) {
    els.sessionBadge.classList.remove("ephemeral");
    els.activeSessionId.textContent = state.sessionId;
  } else {
    els.sessionBadge.classList.add("ephemeral");
    els.activeSessionId.textContent = "Efêmera (stateless)";
  }
}

function applyProfileDefaults() {
  const d = state.activeDemo;
  const prof = els.profileSelect.value;
  state.profile = prof;

  if (prof === "vertex_stream_query") {
    if (d && d.endpoints?.vertex_stream_query) {
      els.endpointUrlInput.value = d.endpoints.vertex_stream_query;
    }
    const defaultHeaders = d?.project_id
      ? { "x-goog-user-project": d.project_id }
      : {};
    els.customHeadersEditor.value = JSON.stringify(defaultHeaders, null, 2);

    const inputObj = {
      message: "{{PROMPT}}",
      user_id: "{{USER_ID}}",
    };
    if (state.sessionId) {
      inputObj.session_id = "{{SESSION_ID}}";
    }
    els.customBodyEditor.value = JSON.stringify({ input: inputObj }, null, 2);
  } else if (prof === "adk_run_sse") {
    if (d && d.endpoints?.adk_run_sse) {
      els.endpointUrlInput.value = d.endpoints.adk_run_sse;
    }
    const defaultHeaders = d?.project_id
      ? { "x-goog-user-project": d.project_id }
      : {};
    els.customHeadersEditor.value = JSON.stringify(defaultHeaders, null, 2);
    els.customBodyEditor.value = JSON.stringify(
      {
        app_name: "app",
        user_id: "{{USER_ID}}",
        session_id: "{{SESSION_ID}}",
        new_message: {
          role: "user",
          parts: [{ text: "{{PROMPT}}" }],
        },
        streaming: true,
      },
      null,
      2
    );
  } else {
    els.rawComposerDrawer.classList.remove("hidden");
    els.toggleRawDrawerBtn.classList.add("active");
  }
}

function renderScenarios() {
  els.scenariosGrid.innerHTML = "";
  els.scenarioPresenterNote.classList.add("hidden");
  const scenarios = state.activeDemo?.scenarios || [];
  els.scenarioCountBadge.textContent = `${scenarios.length} cenários`;

  if (scenarios.length === 0) {
    els.scenariosGrid.innerHTML = `<div class="hint-text">Nenhum cenário pré-configurado para este alvo. Digite sua consulta abaixo.</div>`;
    return;
  }

  scenarios.forEach((sc) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "scenario-card";
    const cat = sc.category || "safe";
    btn.innerHTML = `
      <div class="scenario-top">
        <span class="scenario-act">${escapeHtml(sc.act || "Cenário")}</span>
        <span class="scenario-badge ${escapeHtml(cat)}">${escapeHtml(sc.badge || "TEST")}</span>
      </div>
      <div class="scenario-name">${escapeHtml(sc.title)}</div>
      <div class="scenario-prompt-preview" title="${escapeHtml(sc.prompt)}">${escapeHtml(sc.prompt)}</div>
    `;
    btn.addEventListener("click", () => {
      if (sc.user_id) {
        els.personaInput.value = sc.user_id;
      }
      els.promptInput.value = sc.prompt;
      if (sc.expected_behavior) {
        els.scenarioPresenterNote.innerHTML = `<strong>💡 O que destacar (${escapeHtml(sc.act)} — ${escapeHtml(sc.title)}):</strong> ${escapeHtml(sc.expected_behavior)}`;
        els.scenarioPresenterNote.classList.remove("hidden");
      }
      if (els.autoSendScenarioToggle.checked) {
        sendMessage(sc);
      } else {
        els.promptInput.focus();
      }
    });
    els.scenariosGrid.appendChild(btn);
  });
}

// ==============================================================================
// Draggable Central Resizer & Split Presets
// ==============================================================================

function applySplitPercentage(pct) {
  const clamped = Math.max(18, Math.min(82, Number(pct) || 50));
  state.leftPanePct = clamped;
  document.documentElement.style.setProperty("--left-pane-pct", `${clamped}%`);
  localStorage.setItem("agent_console_split_pct", String(clamped));

  document.querySelectorAll(".split-preset-btn").forEach((btn) => {
    const target = Number(btn.getAttribute("data-split"));
    btn.classList.toggle("active", Math.abs(target - clamped) <= 3);
  });
}

function setupResizerDrag() {
  let isDragging = false;

  els.paneResizer.addEventListener("mousedown", (e) => {
    e.preventDefault();
    isDragging = true;
    document.body.classList.add("resizing");
    els.paneResizer.classList.add("dragging");
  });

  window.addEventListener("mousemove", (e) => {
    if (!isDragging) return;
    const rect = els.splitLayout.getBoundingClientRect();
    if (rect.width <= 0) return;
    const relX = e.clientX - rect.left;
    const pct = Math.round((relX / rect.width) * 100);
    applySplitPercentage(pct);
  });

  window.addEventListener("mouseup", () => {
    if (!isDragging) return;
    isDragging = false;
    document.body.classList.remove("resizing");
    els.paneResizer.classList.remove("dragging");
  });

  els.paneResizer.addEventListener("dblclick", () => {
    applySplitPercentage(50);
  });

  document.querySelectorAll(".split-preset-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      applySplitPercentage(Number(btn.getAttribute("data-split")));
    });
  });
}

// ==============================================================================
// Sending Requests & Real-Time NDJSON Wire Streaming
// ==============================================================================

function buildRequestBody(promptText, userId) {
  const rawTemplate = els.customBodyEditor.value.trim();
  if (!rawTemplate) {
    const input = { message: promptText, user_id: userId };
    if (state.sessionId) input.session_id = state.sessionId;
    return { input };
  }
  const sessId = state.sessionId || "";
  try {
    const parsed = JSON.parse(rawTemplate);
    const substituted = substitutePlaceholders(parsed, {
      "{{PROMPT}}": promptText,
      "{{USER_ID}}": userId,
      "{{SESSION_ID}}": sessId,
    });
    // Remove empty session_id on vertex_stream_query when running in ephemeral mode
    if (
      state.profile === "vertex_stream_query" &&
      !state.sessionId &&
      substituted?.input &&
      !substituted.input.session_id
    ) {
      delete substituted.input.session_id;
    }
    return substituted;
  } catch (err) {
    const replaced = rawTemplate
      .replaceAll("{{PROMPT}}", JSON.stringify(promptText).slice(1, -1))
      .replaceAll("{{USER_ID}}", userId)
      .replaceAll("{{SESSION_ID}}", sessId);
    try {
      return JSON.parse(replaced);
    } catch (_) {
      return replaced;
    }
  }
}

function substitutePlaceholders(node, map) {
  if (typeof node === "string") {
    let out = node;
    for (const [k, v] of Object.entries(map)) {
      out = out.replaceAll(k, v);
    }
    return out;
  }
  if (Array.isArray(node)) {
    return node.map((item) => substitutePlaceholders(item, map));
  }
  if (node && typeof node === "object") {
    const res = {};
    for (const [k, v] of Object.entries(node)) {
      res[k] = substitutePlaceholders(v, map);
    }
    return res;
  }
  return node;
}

async function sendMessage(scenarioMeta = null) {
  const promptText = els.promptInput.value.trim();
  const method = els.httpMethodSelect.value;
  const url = els.endpointUrlInput.value.trim();
  const userId = els.personaInput.value.trim() || "cliente-demo";

  if (!url) {
    alert("Informe a URL do endpoint antes de enviar.");
    return;
  }
  if (!promptText && state.profile !== "custom_http") {
    els.promptInput.focus();
    return;
  }

  let customHeaders = {};
  try {
    if (els.customHeadersEditor.value.trim()) {
      customHeaders = JSON.parse(els.customHeadersEditor.value);
    }
  } catch (err) {
    alert("Headers Extras inválidos (deve ser um objeto JSON válido).");
    return;
  }

  const bodyPayload = buildRequestBody(promptText, userId);

  const turnNumber = state.turns.length + 1;
  const turn = {
    id: `turn-${turnNumber}-${Date.now()}`,
    number: turnNumber,
    scenarioTitle: scenarioMeta ? `${scenarioMeta.act}: ${scenarioMeta.title}` : `Consulta Manual`,
    userId,
    sessionId: state.sessionId || null,
    prompt: promptText || "(Payload Customizado)",
    status: "streaming",
    request: null,
    responseStart: null,
    chunks: [],
    liveToolCalls: [],
    liveToolResponses: [],
    complete: null,
    error: null,
    accumulatedText: "",
  };
  state.turns.push(turn);
  els.promptInput.value = "";

  renderTurnCard(turn);
  selectTurn(turn.id);

  els.sendBtn.disabled = true;

  try {
    const response = await apiFetch("/api/proxy/stream", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        method,
        url,
        headers: customHeaders,
        body: bodyPayload,
        project_id: state.activeDemo?.project_id || "",
        use_auth: true,
      }),
    });

    if (!response.ok || !response.body) {
      const errText = await response.text();
      turn.status = "error";
      turn.error = `Falha no Proxy Local (${response.status}): ${errText}`;
      updateTurnDOM(turn);
      if (state.selectedTurnId === turn.id) renderInspector(turn);
      return;
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder("utf-8");
    let buffer = "";

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const evt = JSON.parse(line);
          handleWireEvent(turn, evt);
        } catch (parseErr) {
          console.warn("Falha ao parsear evento NDJSON:", line, parseErr);
        }
      }
    }
  } catch (err) {
    turn.status = "error";
    turn.error = String(err);
    updateTurnDOM(turn);
    if (state.selectedTurnId === turn.id) renderInspector(turn);
  } finally {
    els.sendBtn.disabled = false;
  }
}

function handleWireEvent(turn, evt) {
  if (evt.type === "wire_request") {
    turn.request = evt;
  } else if (evt.type === "wire_response_start") {
    turn.responseStart = evt;
  } else if (evt.type === "wire_chunk") {
    turn.chunks.push(evt);
    if (evt.extracted_text) {
      turn.accumulatedText += (turn.accumulatedText ? "\n" : "") + evt.extracted_text;
    }
    if (Array.isArray(evt.tool_calls) && evt.tool_calls.length > 0) {
      turn.liveToolCalls.push(...evt.tool_calls);
    }
    if (Array.isArray(evt.tool_responses) && evt.tool_responses.length > 0) {
      turn.liveToolResponses.push(...evt.tool_responses);
    }
  } else if (evt.type === "wire_complete") {
    turn.status = "done";
    turn.complete = evt;
    if (evt.consolidated_text) {
      turn.accumulatedText = evt.consolidated_text;
    }
  } else if (evt.type === "wire_error") {
    turn.status = "error";
    turn.error = evt.error;
  }

  updateTurnDOM(turn);
  if (state.selectedTurnId === turn.id) {
    renderInspector(turn);
  }
}

// ==============================================================================
// Chat Feed Rendering
// ==============================================================================

function renderTurnCard(turn) {
  const empty = els.chatFeed.querySelector(".empty-state");
  if (empty) empty.remove();

  const card = document.createElement("div");
  card.className = "turn-card";
  card.id = turn.id;
  card.addEventListener("click", () => selectTurn(turn.id));

  els.chatFeed.appendChild(card);
  updateTurnDOM(turn);
  els.chatFeed.scrollTop = els.chatFeed.scrollHeight;
}

function isToolResponseBlocked(tr) {
  if (!tr) return false;
  const blob = JSON.stringify(tr);
  return (
    blob.includes("403 Forbidden") ||
    blob.includes("Egress request is not authorized") ||
    blob.includes("BLOQUEADO PELO AGENT GATEWAY") ||
    blob.includes("BLOQUEADO NA SAÍDA PELO AGENT GATEWAY") ||
    blob.includes("CONEXÃO EXTERNA BLOQUEADA PELO PERÍMETRO DE EGRESS") ||
    (blob.includes("MCP tool execution") && (blob.includes("403") || blob.includes("Forbidden")))
  );
}

function getBlockedToolNames(turn) {
  const names = new Set(turn.complete?.governance_verdict?.blocked_tools || []);
  const resps = turn.complete?.tool_responses || turn.liveToolResponses || [];
  resps.forEach((tr) => {
    if (isToolResponseBlocked(tr) && tr.name) {
      names.add(tr.name);
    }
  });
  return names;
}

function updateTurnDOM(turn) {
  const card = document.getElementById(turn.id);
  if (!card) return;

  const isSelected = state.selectedTurnId === turn.id;
  card.classList.toggle("selected", isSelected);

  const timeLabel = turn.request?.timestamp_brt || "enviando...";
  const activeTools = turn.complete?.tool_calls || turn.liveToolCalls || [];
  const blockedTools = getBlockedToolNames(turn);
  const verdict = turn.complete?.governance_verdict || null;
  const verdictCode = verdict?.code || "";
  const isEgressBlock = verdict?.stage === "EGRESS_GATEWAY" || blockedTools.size > 0;
  const isBlocked =
    verdictCode.includes("BLOCK") ||
    isEgressBlock ||
    turn.complete?.status_code >= 400;

  card.classList.toggle("turn-blocked", isBlocked);

  let agentDisplay = turn.accumulatedText;
  if (!agentDisplay) {
    if (turn.status === "streaming") {
      if (activeTools.length > 0) {
        const toolNames = activeTools.map((t) => `${t.name}(${JSON.stringify(t.args || {})})`).join(" ➔ ");
        agentDisplay = `⚙️ Executando tools em tempo real: ${toolNames} ...`;
      } else {
        agentDisplay = "⏳ Aguardando chunks do endpoint...";
      }
    } else if (turn.error) {
      agentDisplay = `❌ Erro: ${turn.error}`;
    } else if (turn.complete?.stream_error) {
      const se = turn.complete.stream_error;
      agentDisplay = `🛑 [HTTP ${se.code || 403} ${se.status || ""}] ${se.message || JSON.stringify(se)}`;
    } else if (turn.complete?.raw_body && turn.complete.raw_body.length < 400) {
      agentDisplay = turn.complete.raw_body;
    } else {
      agentDisplay = "(Sem texto final — inspecione os chunks no painel direito)";
    }
  }

  const badges = [];
  if (verdict) {
    badges.push(`<span class="pill-badge ${escapeHtml(verdict.severity)}">${escapeHtml(verdict.label)}</span>`);
  } else if (turn.status === "streaming" && blockedTools.size > 0) {
    badges.push(`<span class="pill-badge danger">🛑 BLOQUEADO NO EGRESS (403 Forbidden)</span>`);
  }

  const statusCode = turn.complete?.status_code || turn.responseStart?.status_code;
  if (statusCode) {
    if (statusCode < 400 && isEgressBlock) {
      const egressCode = verdict?.egress_status_code || 403;
      badges.push(
        `<span class="pill-badge warning" title="O stream SSE cliente→agente permaneceu aberto (HTTP ${statusCode}), enquanto a chamada de saída (Egress) do agente foi bloqueada pelo Agent Gateway (HTTP ${egressCode})">SSE ${statusCode} • Egress ${egressCode}</span>`
      );
    } else {
      const cls = statusCode >= 400 ? "danger" : "neutral";
      badges.push(`<span class="pill-badge ${cls}">HTTP ${statusCode}</span>`);
    }
  }
  if (turn.sessionId) {
    badges.push(`<span class="pill-badge neutral">sess=${escapeHtml(turn.sessionId)}</span>`);
  }
  if (turn.complete?.total_ms != null) {
    badges.push(
      `<span class="pill-badge neutral">TTFT ${turn.complete.ttft_ms ?? "--"}ms • Total ${turn.complete.total_ms}ms</span>`
    );
  }
  activeTools.forEach((tc) => {
    const tName = tc.name || "functionCall";
    if (blockedTools.has(tName)) {
      badges.push(`<span class="pill-badge danger">🛑 tool bloqueada (403): ${escapeHtml(tName)}</span>`);
    } else {
      badges.push(`<span class="pill-badge tool">🔧 tool: ${escapeHtml(tName)}</span>`);
    }
  });

  card.innerHTML = `
    <div class="turn-meta-top">
      <span><strong>#${turn.number}</strong> • ${escapeHtml(turn.scenarioTitle)} • <code>user_id=${escapeHtml(turn.userId)}</code></span>
      <span>${escapeHtml(timeLabel)}</span>
    </div>
    <div class="turn-user-bubble">${escapeHtml(turn.prompt)}</div>
    <div class="turn-agent-bubble ${isBlocked ? "blocked" : ""}">${escapeHtml(agentDisplay)}</div>
    <div class="turn-footer-badges">${badges.join("")}</div>
  `;
}

function selectTurn(turnId) {
  state.selectedTurnId = turnId;
  document.querySelectorAll(".turn-card").forEach((el) => {
    el.classList.toggle("selected", el.id === turnId);
  });
  const turn = state.turns.find((t) => t.id === turnId);
  if (turn) {
    renderInspector(turn);
  }
}

// ==============================================================================
// Wire Inspector Rendering
// ==============================================================================

function renderInspector(turn) {
  els.inspectorTurnTitle.textContent = `Turno #${turn.number} — ${turn.scenarioTitle}`;
  els.inspectorMetrics.classList.remove("hidden");

  const statusCode = turn.complete?.status_code || turn.responseStart?.status_code || "...";
  const reason = turn.complete?.reason_phrase || turn.responseStart?.reason_phrase || "";
  const blockedTools = getBlockedToolNames(turn);
  const v = turn.complete?.governance_verdict;
  const isEgressBlock = v?.stage === "EGRESS_GATEWAY" || blockedTools.size > 0;
  if (Number(statusCode) < 400 && isEgressBlock) {
    els.metricStatusBadge.textContent = `SSE ${statusCode} • Egress 403`;
    els.metricStatusBadge.classList.add("err");
  } else {
    els.metricStatusBadge.textContent = `${statusCode} ${reason}`.trim();
    els.metricStatusBadge.classList.toggle("err", Number(statusCode) >= 400);
  }

  const ttft = turn.complete?.ttft_ms ?? turn.responseStart?.ttft_ms ?? "--";
  const total = turn.complete?.total_ms ?? "...";
  els.metricTtftBadge.textContent = `TTFT: ${ttft} ms`;
  els.metricTotalBadge.textContent = `Total: ${total} ms`;
  els.metricChunksBadge.textContent = `Chunks: ${turn.chunks.length}`;
  els.tabChunkCounter.textContent = String(turn.chunks.length);

  // Governance Verdict & Audit Leak Warning Banners
  if (v) {
    els.verdictBanner.className = `verdict-banner ${v.severity}`;
    els.verdictBanner.textContent = v.label;
    els.verdictBanner.classList.remove("hidden");

    if (v.leak_warning) {
      els.leakWarningBanner.textContent = v.leak_warning;
      els.leakWarningBanner.classList.remove("hidden");
    } else {
      els.leakWarningBanner.classList.add("hidden");
    }
  } else {
    els.verdictBanner.classList.add("hidden");
    els.leakWarningBanner.classList.add("hidden");
  }

  // TAB 1: Request
  if (turn.request) {
    els.reqTimestamp.textContent = turn.request.timestamp_brt;
    els.reqLineBox.textContent = `${turn.request.method} ${turn.request.url}`;
    els.reqHeadersPre.textContent = JSON.stringify(turn.request.headers, null, 2);
    els.reqBodyPre.textContent =
      typeof turn.request.body === "object"
        ? JSON.stringify(turn.request.body, null, 2)
        : String(turn.request.body ?? "");
    els.curlPre.textContent = turn.request.curl || "";
  }

  // TAB 2: Response
  els.respHeadersPre.textContent = turn.responseStart?.headers
    ? JSON.stringify(turn.responseStart.headers, null, 2)
    : "{}";
  els.respConsolidatedPre.textContent =
    turn.accumulatedText || turn.complete?.raw_body || (turn.error ? `Erro: ${turn.error}` : "Aguardando...");
  els.respRawPre.textContent = turn.complete?.raw_body || turn.chunks.map((c) => c.raw_line).join("\n");

  const tCalls = turn.complete?.tool_calls || turn.liveToolCalls || [];
  const tResps = turn.complete?.tool_responses || turn.liveToolResponses || [];
  if (tCalls.length > 0 || tResps.length > 0) {
    els.toolCallsSection.classList.remove("hidden");
    const itemsHtml = [];
    tCalls.forEach((tc) => {
      const tName = tc.name || "unknown";
      const wasBlocked = blockedTools.has(tName);
      itemsHtml.push(`
        <div class="tool-card ${wasBlocked ? "blocked" : ""}">
          <div class="tool-card-header">${wasBlocked ? "🛑" : "➡️"} functionCall: ${escapeHtml(tName)}${wasBlocked ? " (BLOQUEADA NO EGRESS)" : ""}</div>
          <pre>${escapeHtml(JSON.stringify(tc.args || tc, null, 2))}</pre>
        </div>
      `);
    });
    tResps.forEach((tr) => {
      const trBlocked = isToolResponseBlocked(tr);
      itemsHtml.push(`
        <div class="tool-card ${trBlocked ? "blocked" : ""}">
          <div class="tool-card-header">${trBlocked ? "🛑 functionResponse (403 EGRESS BLOCKED)" : "⬅️ functionResponse"}: ${escapeHtml(tr.name || "unknown")}</div>
          <pre>${escapeHtml(JSON.stringify(tr.response || tr, null, 2))}</pre>
        </div>
      `);
    });
    els.toolCallsContainer.innerHTML = itemsHtml.join("");
  } else {
    els.toolCallsSection.classList.add("hidden");
  }

  // TAB 3: Chunks Timeline
  if (turn.chunks.length === 0) {
    els.chunksTimeline.innerHTML = `<div class="empty-inline">Nenhum chunk recebido para esta chamada.</div>`;
  } else {
    els.chunksTimeline.innerHTML = turn.chunks
      .map((c) => {
        const pretty = c.parsed_json ? JSON.stringify(c.parsed_json, null, 2) : c.raw_line;
        const deltas = [];
        const hasBlockedToolResp =
          Array.isArray(c.tool_responses) && c.tool_responses.some((tr) => isToolResponseBlocked(tr));
        const isErrChunk = Boolean(c.error_info) || hasBlockedToolResp;
        if (c.extracted_text) {
          deltas.push(`${isErrChunk ? "🛑" : "💬"} ${escapeHtml(c.extracted_text)}`);
        }
        if (Array.isArray(c.tool_calls) && c.tool_calls.length > 0) {
          deltas.push(
            `🔧 function_call: ${escapeHtml(c.tool_calls.map((t) => `${t.name}(${JSON.stringify(t.args || {})})`).join(", "))}`
          );
        }
        if (Array.isArray(c.tool_responses) && c.tool_responses.length > 0) {
          deltas.push(
            `${hasBlockedToolResp ? "🛑 function_response (403 BLOCKED)" : "📦 function_response"}: ${escapeHtml(
              c.tool_responses.map((t) => t.name).join(", ")
            )}`
          );
        }
        const deltaHtml =
          deltas.length > 0
            ? `<div class="chunk-delta ${isErrChunk ? "err" : ""}">${deltas.join(" &bull; ")}</div>`
            : "";
        return `
          <div class="chunk-item">
            <div class="chunk-head">
              <span><strong>Chunk #${c.index}</strong> ${c.is_sse ? "(SSE data)" : "(HTTP frame)"}</span>
              <span>+${c.elapsed_ms} ms • ${escapeHtml(c.timestamp_brt)}</span>
            </div>
            ${deltaHtml}
            <div class="chunk-raw">${escapeHtml(pretty)}</div>
          </div>
        `;
      })
      .join("");
  }
}

// ==============================================================================
// Dual-Path Session Management (Create & Reset across Vertex :query & ADK /sessions)
// ==============================================================================

async function createNewSession() {
  const d = state.activeDemo;
  const userId = els.personaInput.value.trim() || "cliente-demo";
  const endpointUrl = els.endpointUrlInput.value.trim();
  const vertexQueryUrl =
    d?.endpoints?.vertex_query ||
    (endpointUrl.includes(":streamQuery") ? `${endpointUrl.split(":streamQuery")[0]}:query` : "");
  const sessionsUrl = (d?.endpoints?.adk_sessions_template || "").replace("{user_id}", encodeURIComponent(userId));

  els.createSessionBtn.disabled = true;
  els.createSessionBtn.textContent = "⏳ Criando...";
  try {
    const res = await apiFetch("/api/sessions/create", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        demo_id: d?.id || "",
        profile: state.profile,
        user_id: userId,
        project_id: d?.project_id || "",
        endpoint_url: endpointUrl,
        vertex_query_url: vertexQueryUrl,
        sessions_url: sessionsUrl,
      }),
    });
    const data = await safeParseJsonResponse(res);
    if (data.session_id) {
      state.sessionId = data.session_id;
      renderSessionBadge();
      applyProfileDefaults();
    }

    const turnNumber = state.turns.length + 1;
    const errText = data.error || JSON.stringify(data.wire?.response?.body || data);
    const sessTurn = {
      id: `turn-${turnNumber}-${Date.now()}`,
      number: turnNumber,
      scenarioTitle: `Nova Sessão (${data.mechanism || state.profile})`,
      userId,
      sessionId: data.session_id || null,
      prompt: `Criar sessão para user_id="${userId}" via ${data.mechanism || "API"}`,
      status: "done",
      request: data.wire?.request,
      responseStart: {
        status_code: data.status_code,
        reason_phrase: data.ok ? "OK" : "Error",
        headers: data.wire?.response?.headers || {},
        ttft_ms: data.elapsed_ms,
      },
      chunks: [],
      liveToolCalls: [],
      liveToolResponses: [],
      complete: {
        status_code: data.status_code,
        reason_phrase: data.ok ? "OK" : "Error",
        ttft_ms: data.elapsed_ms,
        total_ms: data.elapsed_ms,
        raw_body: JSON.stringify(data.wire?.response?.body || data, null, 2),
        consolidated_text: data.session_id
          ? `✅ Nova sessão criada no Agent Runtime: session_id="${data.session_id}". As próximas mensagens enviarão esse session_id automaticamente.`
          : `⚠️ Falha ao criar sessão: ${errText}`,
        governance_verdict: {
          code: data.ok ? "SESSION_CREATED" : "SESSION_ERROR",
          label: data.ok ? `✅ SESSÃO ATIVA (${data.session_id})` : `⚠️ ERRO AO CRIAR SESSÃO (${data.status_code})`,
          severity: data.ok ? "success" : "danger",
        },
      },
      accumulatedText: data.session_id
        ? `✅ Nova sessão criada no Agent Runtime: session_id="${data.session_id}". As próximas mensagens enviarão esse session_id automaticamente.`
        : `⚠️ Falha ao criar sessão: ${errText}`,
    };
    state.turns.push(sessTurn);
    renderTurnCard(sessTurn);
    selectTurn(sessTurn.id);
  } catch (err) {
    alert(`Erro ao criar sessão: ${err}`);
  } finally {
    els.createSessionBtn.disabled = false;
    els.createSessionBtn.textContent = "+ Nova Sessão";
  }
}

async function resetActiveSession() {
  const d = state.activeDemo;
  const userId = els.personaInput.value.trim() || "cliente-demo";
  const oldSessionId = state.sessionId;
  const endpointUrl = els.endpointUrlInput.value.trim();
  const vertexQueryUrl =
    d?.endpoints?.vertex_query ||
    (endpointUrl.includes(":streamQuery") ? `${endpointUrl.split(":streamQuery")[0]}:query` : "");

  els.resetSessionBtn.disabled = true;
  els.resetSessionBtn.textContent = "⏳ Zerando...";
  try {
    const res = await apiFetch("/api/sessions/reset", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        demo_id: d?.id || "",
        profile: state.profile,
        user_id: userId,
        session_id: oldSessionId,
        project_id: d?.project_id || "",
        endpoint_url: endpointUrl,
        vertex_query_url: vertexQueryUrl,
        create_new: false,
      }),
    });
    const data = await safeParseJsonResponse(res);
    state.sessionId = "";
    renderSessionBadge();
    applyProfileDefaults();

    if (data.delete_wire) {
      const turnNumber = state.turns.length + 1;
      const delTurn = {
        id: `turn-${turnNumber}-${Date.now()}`,
        number: turnNumber,
        scenarioTitle: `Sessão Zerada (delete_session)`,
        userId,
        sessionId: oldSessionId,
        prompt: `Deletar session_id="${oldSessionId}" no Agent Runtime e voltar ao modo Efêmero`,
        status: "done",
        request: data.delete_wire.request,
        responseStart: {
          status_code: data.delete_wire.status_code,
          reason_phrase: "OK",
          headers: data.delete_wire.response?.headers || {},
          ttft_ms: data.delete_wire.elapsed_ms,
        },
        chunks: [],
        liveToolCalls: [],
        liveToolResponses: [],
        complete: {
          status_code: data.delete_wire.status_code,
          reason_phrase: "OK",
          ttft_ms: data.delete_wire.elapsed_ms,
          total_ms: data.delete_wire.elapsed_ms,
          raw_body: JSON.stringify(data.delete_wire.response?.body || {}, null, 2),
          consolidated_text: `🧹 Sessão anterior (${oldSessionId}) removida no servidor. Canal voltou para modo Efêmero (stateless).`,
          governance_verdict: {
            code: "SESSION_RESET",
            label: "🧹 SESSÃO ZERADA (Modo Efêmero Ativo)",
            severity: "info",
          },
        },
        accumulatedText: `🧹 Sessão anterior (${oldSessionId}) removida no servidor. Canal voltou para modo Efêmero (stateless).`,
      };
      state.turns.push(delTurn);
      renderTurnCard(delTurn);
      selectTurn(delTurn.id);
    }
  } catch (err) {
    console.error("Erro ao zerar sessão:", err);
  } finally {
    els.resetSessionBtn.disabled = false;
    els.resetSessionBtn.textContent = "🔄 Zerar Sessão";
  }
}

// ==============================================================================
// Auth & 3LO Modal Management
// ==============================================================================

function renderAuthStatus(auth) {
  if (!auth) return;
  const t = auth.transport_auth || {};
  els.authStatusDot.className = `status-dot ${t.ok ? "ok" : "err"}`;
  const ttlMin = t.ttl_remaining_s != null ? `${Math.round(t.ttl_remaining_s / 60)}m` : "";
  els.authStatusText.textContent = `${t.source || "auth"} ${ttlMin ? `• ${ttlMin}` : ""}`.trim();

  els.authModeSelect.value = auth.token_type || "access";
  els.gcloudConfigInput.value = auth.gcloud_config || "argolis";
  els.manualTokenRow.classList.toggle("hidden", auth.token_type !== "manual");
  els.authAccountLabel.textContent = t.account || "(não identificado)";
  els.authMaskedToken.textContent = t.masked || "--";
  els.authFetchedAt.textContent = t.fetched_at_brt || "--";
  els.authTtlLabel.textContent = t.ttl_remaining_s != null ? `TTL ~${t.ttl_remaining_s}s` : "TTL: n/a";

  const del = auth.delegated_context || {};
  els.delegatedEnableToggle.checked = Boolean(del.enabled);
  els.delegatedFields.classList.toggle("hidden", !del.enabled);
  if (del.header_name) els.delegatedHeaderName.value = del.header_name;
}

async function saveAuthConfig() {
  const payload = {
    token_type: els.authModeSelect.value,
    gcloud_config: els.gcloudConfigInput.value.trim() || "argolis",
    delegated_context: {
      enabled: els.delegatedEnableToggle.checked,
      header_name: els.delegatedHeaderName.value.trim() || "X-Forwarded-Authorization",
    },
  };
  if (els.manualTokenInput.value.trim()) {
    payload.manual_token = els.manualTokenInput.value.trim();
  }
  if (els.delegatedTokenInput.value.trim()) {
    payload.delegated_context.subject_token = els.delegatedTokenInput.value.trim();
  }

  const res = await apiFetch("/api/auth/config", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const err = await res.json();
    alert(`Erro de configuração: ${err.detail || res.statusText}`);
    return;
  }
  const updated = await res.json();
  state.auth = updated;
  renderAuthStatus(updated);
  els.authModal.classList.add("hidden");
}

// ==============================================================================
// Event Bindings & Utilities
// ==============================================================================

function bindEvents() {
  setupResizerDrag();

  els.demoSelect.addEventListener("change", (e) => selectDemo(e.target.value));
  els.profileSelect.addEventListener("change", () => applyProfileDefaults());
  els.sendBtn.addEventListener("click", () => sendMessage());
  els.promptInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });

  els.toggleRawDrawerBtn.addEventListener("click", () => {
    els.rawComposerDrawer.classList.toggle("hidden");
    els.toggleRawDrawerBtn.classList.toggle("active");
  });

  els.resetTemplateBtn.addEventListener("click", () => applyProfileDefaults());
  els.createSessionBtn.addEventListener("click", () => createNewSession());
  els.resetSessionBtn.addEventListener("click", () => resetActiveSession());

  els.clearChatBtn.addEventListener("click", () => {
    state.turns = [];
    state.selectedTurnId = null;
    els.chatFeed.innerHTML = `
      <div class="empty-state">
        <div class="empty-icon">💬</div>
        <h3>Histórico Limpo</h3>
        <p>Selecione um cenário acima ou envie uma nova mensagem.</p>
      </div>
    `;
    els.inspectorTurnTitle.textContent = "Nenhuma chamada selecionada";
    els.inspectorMetrics.classList.add("hidden");
    els.verdictBanner.classList.add("hidden");
    els.leakWarningBanner.classList.add("hidden");
  });

  // Inspector Tabs
  document.querySelectorAll(".tab-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const targetTab = btn.getAttribute("data-tab");
      document.querySelectorAll(".tab-btn").forEach((b) => b.classList.toggle("active", b === btn));
      document.querySelectorAll(".tab-panel").forEach((p) => {
        p.classList.toggle("active", p.id === `tab-${targetTab}`);
      });
    });
  });

  // Copy Buttons
  document.querySelectorAll(".btn-copy").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const targetId = btn.getAttribute("data-copy-target");
      const targetEl = document.getElementById(targetId);
      if (!targetEl) return;
      await navigator.clipboard.writeText(targetEl.textContent || "");
      const orig = btn.textContent;
      btn.textContent = "✅ Copiado!";
      setTimeout(() => {
        btn.textContent = orig;
      }, 1200);
    });
  });

  // Auth Modal
  els.authDrawerBtn.addEventListener("click", () => els.authModal.classList.remove("hidden"));
  els.closeAuthModalBtn.addEventListener("click", () => els.authModal.classList.add("hidden"));
  els.authModeSelect.addEventListener("change", (e) => {
    els.manualTokenRow.classList.toggle("hidden", e.target.value !== "manual");
  });
  els.delegatedEnableToggle.addEventListener("change", (e) => {
    els.delegatedFields.classList.toggle("hidden", !e.target.checked);
  });
  els.refreshTokenBtn.addEventListener("click", async () => {
    els.refreshTokenBtn.textContent = "⏳ Renovando...";
    try {
      const res = await apiFetch("/api/auth/refresh", { method: "POST" });
      const data = await res.json();
      state.auth = data;
      renderAuthStatus(data);
    } finally {
      els.refreshTokenBtn.textContent = "🔄 Renovar Token Agora";
    }
  });
  els.saveAuthConfigBtn.addEventListener("click", () => saveAuthConfig());

  window.addEventListener("message", (event) => {
    if (event.data && event.data.type === "agent_console_oauth_callback") {
      loadDemosAndAuth();
    }
  });
}

function escapeHtml(str) {
  return String(str ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

document.addEventListener("DOMContentLoaded", init);
