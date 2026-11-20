// Teach Dashboard: internes Kosten- und Analytics-Dashboard.
//
// Sicherheit: Im Browser liegen nur die Projekt-URL und der ÖFFENTLICHE
// anon-Key (steckt ohnehin in jeder IPA, siehe Config.swift). Daten gibt es
// ausschließlich über die Edge Function admin-dashboard, die das Login-Token
// über GoTrue prüft und die User-ID gegen ADMIN_USER_IDS abgleicht. Kein
// service_role- oder API-Schlüssel im Browser. Die Sitzung liegt nur in
// sessionStorage (weg, sobald der Tab zu ist).
//
// Alle Daten aus der DB (z. B. Gast-IPs in rate_limit_counters) werden per
// textContent eingesetzt, nie als HTML.
"use strict";

const CONFIG = {
  supabaseUrl: "https://rvpisoibtqxxxpgjdhff.supabase.co",
  // Öffentlicher anon-Key (kein Geheimnis, identisch mit Sources/TeachVoice/Core/Config.swift).
  anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ2cGlzb2lidHF4eHhwZ2pkaGZmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyMTU5NzAsImV4cCI6MjEwMTc5MTk3MH0.DOmcdD3FR8TWFx-RkwO0nXWEx6R9EuTN7X_4SLZ6SUc",
};

// Monatliches Google-Freikontingent je Stimmklasse, nur zur Anzeige. Laut
// Google-Preisseite 1 Mio. Zeichen für Chirp 3 HD; für WaveNet widersprechen
// sich die Angaben (1 bzw. 4 Mio.), daher konservativ 1 Mio. Die Kosten-
// schätzung rechnet das Freikontingent bewusst NICHT ab.
const FREE_CHARS_PER_MONTH = { wavenet: 1_000_000, chirp3_hd: 1_000_000 };

// Feste Reihenfolge = feste Farbe pro Kostenart (Farbe folgt der Sache, nicht dem Rang).
const COST_SERIES = [
  { key: "chirp3_hd", label: "Chirp 3 HD", color: "--s1" },
  { key: "wavenet", label: "WaveNet", color: "--s2" },
  { key: "grading", label: "OpenAI Bewertung", color: "--s3" },
  { key: "extraction", label: "OpenAI Extraktion", color: "--s4" },
  { key: "question_generation", label: "OpenAI PDF-Import", color: "--s5" },
];
const TTS_SERIES = COST_SERIES.slice(0, 2);
const MODE_SERIES = [
  { key: "sprechen", label: "Sprechen", color: "--s1" },
  { key: "tippen", label: "Tippen", color: "--s2" },
];
const RATINGS = [
  { n: 1, label: "Nochmal", color: "--seq-250" },
  { n: 2, label: "Schwer", color: "--seq-400" },
  { n: 3, label: "Gut", color: "--seq-550" },
  { n: 4, label: "Einfach", color: "--seq-700" },
];
const OPERATION_LABELS = { tts: "Vorlesen", grading: "Bewertung", extraction: "Extraktion", question_generation: "PDF-Import" };
const PRICE_CLASS_LABELS = { wavenet: "WaveNet", chirp3_hd: "Chirp 3 HD" };
const WEEKDAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];

const DEMO = new URLSearchParams(location.search).has("demo");
const SESSION_KEY = "teachDashboardSession";
const DAYS_KEY = "teachDashboardDays";

// ---------------------------------------------------------------- Speicher

const sessionStore = {
  get() { try { return JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch { return null; } },
  set(v) { try { sessionStorage.setItem(SESSION_KEY, JSON.stringify(v)); } catch { /* privates Fenster */ } },
  clear() { try { sessionStorage.removeItem(SESSION_KEY); } catch { /* egal */ } },
};
function loadDaysPref() {
  try { const v = Number(localStorage.getItem(DAYS_KEY)); return [7, 30, 90, 365].includes(v) ? v : 30; } catch { return 30; }
}
function saveDaysPref(v) { try { localStorage.setItem(DAYS_KEY, String(v)); } catch { /* egal */ } }

let session = sessionStore.get();
let days = loadDaysPref();
let lastPayload = null;
const charts = {};

// ---------------------------------------------------------------- Helfer

const $ = (id) => document.getElementById(id);

/// Kleiner DOM-Baukasten: Strings werden IMMER als Text eingesetzt.
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "style") el.setAttribute("style", v);
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const child of children.flat()) {
    if (child === undefined || child === null || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

const nf0 = new Intl.NumberFormat("de-DE");
const int = (n) => nf0.format(Math.round(Number(n) || 0));
const compact = (n) => new Intl.NumberFormat("de-DE", { notation: "compact", maximumFractionDigits: 1 }).format(Number(n) || 0);
const pct = (x, digits = 0) => new Intl.NumberFormat("de-DE", { style: "percent", maximumFractionDigits: digits }).format(Number(x) || 0);
function usd(v) {
  const value = Number(v) || 0;
  const abs = Math.abs(value);
  const digits = abs === 0 ? 2 : abs < 0.01 ? 4 : abs < 1 ? 3 : 2;
  return new Intl.NumberFormat("de-DE", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value);
}
const sum = (arr, f) => arr.reduce((acc, x) => acc + (Number(f(x)) || 0), 0);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

function dayRange(from, to) {
  const out = [];
  const end = Date.parse(`${to}T00:00:00Z`);
  for (let t = Date.parse(`${from}T00:00:00Z`); t <= end; t += 86_400_000) out.push(new Date(t).toISOString().slice(0, 10));
  return out;
}
const shortDay = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit", timeZone: "UTC" });
const longDay = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString("de-DE", { weekday: "short", day: "2-digit", month: "2-digit", year: "numeric", timeZone: "UTC" });
const dateTime = (iso) => new Date(iso).toLocaleString("de-DE", { day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" });

function textOn(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex);
  if (!m) return "#ffffff";
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.35 ? "#0b0b0b" : "#ffffff";
}

function statusEl(level, text) { return h("span", { class: `status ${level}` }, text); }

function tile(label, value, note, status) {
  return h("div", { class: "card tile" },
    h("div", { class: "label" }, label),
    h("div", { class: "value" }, value),
    note ? h("div", { class: "note" }, note) : null,
    status || null);
}

function table(headers, rows, numeric = []) {
  return h("table", {},
    h("thead", {}, h("tr", {}, headers.map((t, i) => h("th", { class: numeric.includes(i) ? "num" : null }, t)))),
    h("tbody", {}, rows.map((r) => h("tr", {}, r.map((c, i) => h("td", { class: numeric.includes(i) ? "num" : null }, c))))));
}

function legend(target, series) {
  $(target).replaceChildren(...series.map((s) => h("span", {}, h("i", { style: `--c: var(${s.color})` }), s.label)));
}

function banner(kind, ...content) { $("banners").append(h("div", { class: `banner ${kind}`, role: kind === "error" ? "alert" : null }, ...content)); }
function clearBanners() { $("banners").replaceChildren(); }

// ---------------------------------------------------------------- Tooltip (Heatmap, Notenbalken)

const tip = $("tip");
document.addEventListener("mousemove", (e) => {
  const target = e.target instanceof Element ? e.target.closest("[data-tip]") : null;
  if (!target) { tip.hidden = true; return; }
  tip.textContent = target.getAttribute("data-tip");
  tip.hidden = false;
  const x = Math.min(e.clientX + 12, window.innerWidth - tip.offsetWidth - 8);
  const y = e.clientY + 16 + tip.offsetHeight > window.innerHeight ? e.clientY - tip.offsetHeight - 8 : e.clientY + 16;
  tip.style.left = `${x}px`;
  tip.style.top = `${y}px`;
});

// ---------------------------------------------------------------- Auth (GoTrue)

async function gotrue(path, body, accessToken) {
  const res = await fetch(`${CONFIG.supabaseUrl}/auth/v1/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: CONFIG.anonKey, ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* kein JSON */ }
  if (!res.ok) {
    const err = new Error(json?.error_description || json?.msg || json?.message || `HTTP ${res.status}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

function saveSession(j) {
  session = {
    access_token: j.access_token,
    refresh_token: j.refresh_token,
    expires_at: j.expires_at ?? Math.floor(Date.now() / 1000) + (j.expires_in || 3600),
    user_id: j.user?.id ?? session?.user_id,
    email: j.user?.email ?? session?.email,
  };
  sessionStore.set(session);
}

async function accessToken(forceRefresh = false) {
  if (!session) throw Object.assign(new Error("Nicht angemeldet."), { status: 401 });
  if (forceRefresh || session.expires_at - 60 < Date.now() / 1000) {
    saveSession(await gotrue("token?grant_type=refresh_token", { refresh_token: session.refresh_token }));
  }
  return session.access_token;
}

async function login(email, password) {
  saveSession(await gotrue("token?grant_type=password", { email, password }));
}

async function logout(message) {
  const token = session?.access_token;
  session = null;
  sessionStore.clear();
  if (token) gotrue("logout?scope=local", null, token).catch(() => { /* Token evtl. schon abgelaufen */ });
  showLogin(message);
}

// ---------------------------------------------------------------- Laden

async function callAdmin(forceRefresh) {
  const token = await accessToken(forceRefresh);
  return fetch(`${CONFIG.supabaseUrl}/functions/v1/admin-dashboard?days=${days}`, {
    headers: { apikey: CONFIG.anonKey, Authorization: `Bearer ${token}` },
  });
}

async function loadDashboard() {
  clearBanners();
  setBusy(true);
  try {
    if (DEMO) {
      banner("info", h("strong", {}, "Demo: "), "erfundene Beispieldaten, keine Verbindung zu Supabase. ", h("a", { href: location.pathname }, "Zum Login"));
      renderAll(demoPayload(days));
      return;
    }
    let res;
    try {
      res = await callAdmin(false);
      if (res.status === 401) res = await callAdmin(true);
    } catch (err) {
      if (err.status === 401 || err.status === 400) { logout("Sitzung abgelaufen. Bitte neu anmelden."); return; }
      throw err;
    }
    const body = await res.json().catch(() => ({}));
    if (res.status === 401) { logout("Sitzung abgelaufen. Bitte neu anmelden."); return; }
    if (res.status === 403) {
      $("app").hidden = true;
      banner("error", h("strong", {}, "Kein Zugang. "), "Dieses Konto steht nicht in ADMIN_USER_IDS. Deine User-ID: ", h("code", {}, session?.user_id || "unbekannt"));
      return;
    }
    if (!res.ok) {
      banner("error", h("strong", {}, `Fehler ${res.status}: `), body.error || "Unbekannter Fehler.");
      return;
    }
    renderAll(body);
  } catch (err) {
    // Ist die Function nicht deployt, antwortet Supabase schon auf die
    // CORS-Vorabfrage mit 404 -- der Browser meldet dann nur "Failed to fetch".
    banner("error", h("strong", {}, "admin-dashboard nicht erreichbar. "),
      "Meist heißt das: Die Edge Function admin-dashboard ist noch nicht deployt (oder es gibt kein Netz). ",
      h("code", {}, String(err.message || err)));
  } finally {
    setBusy(false);
  }
}

function setBusy(busy) {
  $("refresh").disabled = busy;
  $("refresh").textContent = busy ? "Lädt …" : "Aktualisieren";
}

// ---------------------------------------------------------------- Ansichten

function showLogin(message) {
  destroyCharts();
  $("topbar").hidden = true;
  $("app").hidden = true;
  clearBanners();
  $("login").hidden = false;
  $("loginErr").textContent = message || "";
  $("email").focus();
}

function showDashboard() {
  $("login").hidden = true;
  $("topbar").hidden = false;
  $("logout").hidden = DEMO;
  for (const b of $("range").querySelectorAll("button")) b.setAttribute("aria-pressed", String(Number(b.dataset.days) === days));
  loadDashboard();
}

$("login").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("loginErr").textContent = "";
  $("loginBtn").disabled = true;
  try {
    await login($("email").value.trim(), $("password").value);
    $("password").value = "";
    showDashboard();
  } catch (err) {
    $("loginErr").textContent = err.status === 400 ? "E-Mail oder Passwort falsch." : `Anmeldung fehlgeschlagen: ${err.message}`;
  } finally {
    $("loginBtn").disabled = false;
  }
});
$("logout").addEventListener("click", () => logout());
$("refresh").addEventListener("click", () => loadDashboard());
$("range").addEventListener("click", (e) => {
  const btn = e.target instanceof Element ? e.target.closest("button[data-days]") : null;
  if (!btn) return;
  days = Number(btn.dataset.days);
  saveDaysPref(days);
  for (const b of $("range").querySelectorAll("button")) b.setAttribute("aria-pressed", String(b === btn));
  loadDashboard();
});
// Hell/Dunkel gewechselt -> Diagramme mit den neuen Farben neu zeichnen.
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { if (lastPayload) renderAll(lastPayload); });

// ---------------------------------------------------------------- Diagramme

function destroyCharts() { for (const k of Object.keys(charts)) { charts[k].destroy(); delete charts[k]; } }

function chartOrFallback(boxId) {
  if (window.Chart) return true;
  $(boxId).replaceChildren(h("div", { class: "empty" }, "Diagramm nicht verfügbar (Chart.js konnte nicht geladen werden). Die Tabelle darunter hat alle Werte."));
  return false;
}

/// Nur das oberste sichtbare Segment eines Stapels bekommt die runde Kappe.
function isTopSegment(ctx) {
  const { chart, dataIndex, datasetIndex } = ctx;
  for (let i = chart.data.datasets.length - 1; i >= 0; i--) {
    if (!chart.isDatasetVisible(i)) continue;
    if ((Number(chart.data.datasets[i].data[dataIndex]) || 0) > 0) return i === datasetIndex;
  }
  return false;
}

function baseOptions(yFormat, { stacked = true, yMax } = {}) {
  const muted = css("--muted");
  const grid = css("--grid");
  return {
    responsive: true,
    maintainAspectRatio: false,
    animation: false,
    interaction: { mode: "index", intersect: false },
    plugins: {
      legend: { display: false },
      tooltip: {
        backgroundColor: css("--ink"),
        titleColor: css("--surface"),
        bodyColor: css("--surface"),
        footerColor: css("--surface"),
        padding: 8,
        boxPadding: 4,
        usePointStyle: true,
        filter: (item) => item.raw !== null && (Number(item.raw) || 0) !== 0,
        callbacks: { label: (item) => ` ${item.dataset.label}: ${yFormat(item.raw)}` },
      },
    },
    scales: {
      x: { stacked, grid: { display: false }, border: { color: css("--axis") }, ticks: { color: muted, maxRotation: 0, autoSkip: true, autoSkipPadding: 12, font: { size: 11 } } },
      y: { stacked, beginAtZero: true, max: yMax, grid: { color: grid, drawTicks: false }, border: { display: false }, ticks: { color: muted, padding: 6, font: { size: 11 }, callback: (v) => yFormat(v, true), maxTicksLimit: 6 } },
    },
  };
}

function stackedBars(key, boxId, labels, series, valuesFor, yFormat) {
  charts[key]?.destroy();
  if (!chartOrFallback(boxId)) return;
  const surface = css("--surface");
  const options = baseOptions(yFormat);
  if (series.length > 1) {
    options.plugins.tooltip.callbacks.footer = (items) => `Summe: ${yFormat(sum(items, (i) => i.raw))}`;
  }
  charts[key] = new Chart($(boxId).querySelector("canvas"), {
    type: "bar",
    data: {
      labels: labels.map(shortDay),
      datasets: series.map((s) => ({
        label: s.label,
        data: labels.map((d) => valuesFor(s.key, d)),
        backgroundColor: css(s.color),
        borderColor: surface,
        borderWidth: { top: series.length > 1 ? 2 : 0, right: 0, bottom: 0, left: 0 },
        borderSkipped: "start",
        borderRadius: (ctx) => (isTopSegment(ctx) ? { topLeft: 4, topRight: 4, bottomLeft: 0, bottomRight: 0 } : 0),
        maxBarThickness: 24,
        categoryPercentage: 0.8,
        barPercentage: 0.9,
      })),
    },
    options,
  });
}

function lineChart(key, boxId, labels, values, label, yFormat, yMax) {
  charts[key]?.destroy();
  if (!chartOrFallback(boxId)) return;
  const color = css("--s1");
  charts[key] = new Chart($(boxId).querySelector("canvas"), {
    type: "line",
    data: {
      labels: labels.map(shortDay),
      datasets: [{
        label,
        data: values,
        borderColor: color,
        backgroundColor: color,
        borderWidth: 2,
        borderCapStyle: "round",
        borderJoinStyle: "round",
        pointRadius: 4,
        pointHoverRadius: 6,
        pointBorderColor: css("--surface"),
        pointBorderWidth: 2,
        spanGaps: false,
        tension: 0,
      }],
    },
    options: baseOptions(yFormat, { stacked: false, yMax }),
  });
}

function dailyTable(target, labels, series, valuesFor, format) {
  const rows = labels.filter((d) => series.some((s) => (Number(valuesFor(s.key, d)) || 0) !== 0)).map((d) => [longDay(d), ...series.map((s) => {
    const v = valuesFor(s.key, d);
    return v === null || v === undefined ? "–" : format(v);
  })]);
  $(target).replaceChildren(rows.length
    ? table(["Tag", ...series.map((s) => s.label)], rows, series.map((_, i) => i + 1))
    : h("div", { class: "empty" }, "Keine Werte im Zeitraum."));
}

// ---------------------------------------------------------------- Rendern

function renderAll(payload) {
  lastPayload = payload;
  const { data, config } = payload;
  $("app").hidden = false;
  const p = data.period;
  $("stamp").textContent = `Stand ${dateTime(data.generated_at)} · Zeitraum ${longDay(p.from_day)} bis ${longDay(p.to_day)} · ${p.tz}`
    + (session?.email && !DEMO ? ` · angemeldet als ${session.email}` : "");
  renderCosts(data, config);
  renderOps(data, config);
  renderLearning(data);
  renderLibrary(data);
}

const costSeriesKey = (row) => (row.provider === "google_tts" ? row.price_class : row.operation);

function renderCosts(data, config) {
  const p = data.period;
  const totals = data.usage_totals || [];
  const daily = data.usage_daily || [];
  const total = sum(totals, (t) => t.cost_usd);
  const tts = totals.filter((t) => t.provider === "google_tts");
  const openai = totals.filter((t) => t.provider === "openai");
  const ttsCost = sum(tts, (t) => t.cost_usd);
  const openaiCost = sum(openai, (t) => t.cost_usd);

  // Untertitel: seit wann gemessen wird, und was die Zahlen sind
  const tp = config.tts_price_per_million_chars_usd || {};
  const op = (config.openai_price_per_million_tokens_usd || {})["gpt-4o-mini"];
  const priceText = `Schätzung aus Listenpreisen (WaveNet ${usd(tp.wavenet)}, Chirp 3 HD ${usd(tp.chirp3_hd)} pro 1 Mio. Zeichen`
    + (op ? `; gpt-4o-mini ${usd(op.input)} / ${usd(op.cachedInput)} / ${usd(op.output)} pro 1 Mio. Token Input/Cache/Output` : "")
    + "), ohne Freikontingent. Offizielle Zahlen: Google-Cloud-Konsole und OpenAI-Usage-Dashboard.";
  $("costsSub").textContent = data.measuring_since
    ? `Gemessen seit ${dateTime(data.measuring_since)}. ${priceText}`
    : priceText;
  if (!data.measuring_since) {
    banner("warn", h("strong", {}, "Noch keine Kostendaten. "),
      "Gemessen wird erst seit dem Deploy der Messung, und seitdem gab es noch keinen bezahlten Aufruf. "
      + "Der erste Eintrag erscheint, sobald die App eine gesprochene Antwort bewertet, einen PDF-Import macht "
      + "oder mit der Google-Stimme etwas Neues vorliest (schon zwischengespeicherte Fragen und die iPhone-Stimme kosten nichts und erscheinen nicht).");
  }

  // Hero + Vergleich mit dem Zeitraum davor
  $("heroCost").textContent = usd(total);
  const prev = sum(Object.values(data.previous_period || {}), (v) => v);
  const deltaEl = $("heroDelta");
  if (prev > 0) {
    const change = (total - prev) / prev;
    deltaEl.textContent = `${change >= 0 ? "▲" : "▼"} ${pct(Math.abs(change))} gegenüber den ${p.days} Tagen davor (${usd(prev)})`;
  } else {
    deltaEl.textContent = `Für die ${p.days} Tage davor gibt es keine Messdaten.`;
  }

  // Kostendeckel
  const ceiling = Number(config.google_cloud_ceiling_usd) || 20;
  const guardTotal = Number(data.spend_guard?.total_usd) || 0;
  const ratio = guardTotal / ceiling;
  $("guardValue").replaceChildren(
    h("div", { class: "value" }, `${usd(guardTotal)} von ${usd(ceiling)}`),
    h("div", { class: "note" }, data.spend_guard ? `${pct(ratio, 1)} verbraucht · zuletzt ${dateTime(data.spend_guard.updated_at)}` : "Noch kein Eintrag (noch nie eine Cloud-Stimme bezahlt)."));
  const fill = $("guardFill");
  fill.style.width = `${Math.min(100, ratio * 100)}%`;
  const level = ratio >= 1 ? "critical" : ratio >= 0.9 ? "critical" : ratio >= 0.75 ? "warning" : "good";
  fill.style.setProperty("--fill", level === "good" ? "var(--accent)" : `var(--${level})`);
  $("guardStatus").replaceChildren(statusEl(level, ratio >= 1 ? "Deckel erreicht: Cloud-Stimme ist gesperrt, die App liest mit der iPhone-Stimme vor."
    : ratio >= 0.9 ? "Fast erreicht: über 90 % verbraucht."
    : ratio >= 0.75 ? "Achtung: über 75 % verbraucht."
    : "Im Rahmen."));

  // Kacheln
  const mtd = data.month_to_date || [];
  const mtdCost = sum(mtd, (m) => m.cost_usd);
  const monthStart = Date.parse(p.month_start);
  const since = data.measuring_since ? Math.max(monthStart, Date.parse(data.measuring_since)) : monthStart;
  const elapsedDays = Math.max(1, (Date.parse(data.generated_at) - since) / 86_400_000);
  const remainingDays = Math.max(0, p.month_days_total - p.month_days_elapsed);
  const forecast = mtdCost + (mtdCost / elapsedDays) * remainingDays;
  const gradings = openai.filter((t) => t.operation === "grading");
  const extractions = openai.filter((t) => t.operation === "extraction");
  const gradingOk = sum(gradings, (t) => t.ok);
  const gradingCost = sum(gradings, (t) => t.cost_usd) + sum(extractions, (t) => t.cost_usd);
  const pdf = openai.filter((t) => t.operation === "question_generation");
  const pdfOk = sum(pdf, (t) => t.ok);
  $("costTiles").replaceChildren(
    tile("Google TTS", usd(ttsCost), `${compact(sum(tts, (t) => t.characters))} Zeichen · ${int(sum(tts, (t) => t.ok))} Aufrufe`),
    tile("OpenAI", usd(openaiCost), `${compact(sum(openai, (t) => t.input_tokens + t.output_tokens))} Token · ${int(sum(openai, (t) => t.ok))} Aufrufe`),
    tile("Prognose diesen Monat", usd(forecast), `bisher ${usd(mtdCost)}, hochgerechnet`),
    tile("Pro bewerteter Antwort", gradingOk ? usd(gradingCost / gradingOk) : "–", `${int(gradingOk)} Bewertungen inkl. Extraktion`),
    tile("Pro PDF-Import", pdfOk ? usd(sum(pdf, (t) => t.cost_usd) / pdfOk) : "–", `${int(pdfOk)} Importe`),
  );

  // Kosten pro Tag
  const labels = dayRange(p.from_day, p.to_day);
  const costMap = new Map();
  const charMap = new Map();
  for (const r of daily) {
    const k = `${costSeriesKey(r)}|${r.day}`;
    costMap.set(k, (costMap.get(k) || 0) + Number(r.cost_usd));
    if (r.provider === "google_tts") charMap.set(k, (charMap.get(k) || 0) + Number(r.characters));
  }
  const costFor = (key, d) => costMap.get(`${key}|${d}`) || 0;
  const charsFor = (key, d) => charMap.get(`${key}|${d}`) || 0;
  legend("costLegend", COST_SERIES);
  stackedBars("cost", "costChartBox", labels, COST_SERIES, costFor, (v) => usd(v));
  dailyTable("costTable", labels, COST_SERIES, costFor, usd);
  legend("charLegend", TTS_SERIES);
  stackedBars("chars", "charChartBox", labels, TTS_SERIES, charsFor, (v, axis) => (axis ? compact(v) : `${int(v)} Zeichen`));
  dailyTable("charTable", labels, TTS_SERIES, charsFor, int);

  // Freikontingent im laufenden Monat
  $("freeTier").replaceChildren(h("h3", {}, "Freikontingent diesen Monat"),
    ...TTS_SERIES.map((s) => {
      const chars = sum(mtd.filter((m) => m.provider === "google_tts" && m.price_class === s.key), (m) => m.characters);
      const free = FREE_CHARS_PER_MONTH[s.key];
      const r = chars / free;
      return h("div", { style: "margin-top:8px" },
        h("div", { class: "note", style: "font-size:12px;color:var(--ink-2)" }, `${s.label}: ${int(chars)} von ${compact(free)} Zeichen (${pct(r, 1)})`),
        h("div", { class: "meter thin" }, h("span", { style: `width:${Math.min(100, r * 100)}%;--fill:var(${s.color})` })));
    }),
    h("p", { class: "desc", style: "margin:8px 0 0" }, "Laut Google-Preisseite; für WaveNet nennt Google teils 4 Mio. Bitte in der Cloud-Konsole prüfen."));

  // Aufschlüsselung
  const seriesByKey = Object.fromEntries(COST_SERIES.map((s) => [s.key, s]));
  const rows = totals.map((t) => {
    const s = seriesByKey[costSeriesKey(t)];
    return [
      h("span", {}, s ? h("span", { class: "key", style: `--c: var(${s.color})` }) : null, t.function_name),
      OPERATION_LABELS[t.operation] || t.operation,
      PRICE_CLASS_LABELS[t.price_class] || t.price_class,
      int(t.calls), int(t.errors), int(t.blocked),
      t.provider === "google_tts" ? int(t.characters) : "–",
      t.provider === "openai" ? `${compact(t.input_tokens)} / ${compact(t.cached_input_tokens)} / ${compact(t.output_tokens)}` : "–",
      t.avg_duration_ms !== null && t.avg_duration_ms !== undefined ? `${int(t.avg_duration_ms)} ms` : "–",
      usd(t.cost_usd),
      t.ok ? usd(t.cost_usd / t.ok) : "–",
    ];
  });
  if (rows.length) {
    rows.push([h("strong", {}, "Summe"), "", "", int(sum(totals, (t) => t.calls)), int(sum(totals, (t) => t.errors)), int(sum(totals, (t) => t.blocked)), "", "", "", h("strong", {}, usd(total)), ""]);
  }
  $("breakdown").replaceChildren(rows.length
    ? table(["Funktion", "Vorgang", "Preisklasse", "Aufrufe", "Fehler", "Blockiert", "Zeichen", "Token", "Ø Dauer", "Kosten", "Ø pro Aufruf"], rows, [3, 4, 5, 6, 7, 8, 9, 10])
    : h("div", { class: "empty" }, "Keine protokollierten Aufrufe im Zeitraum."));
}

function renderOps(data, config) {
  const totals = data.usage_totals || [];
  const calls = sum(totals, (t) => t.calls);
  const errors = sum(totals, (t) => t.errors);
  const blocked = sum(totals, (t) => t.blocked);
  const guests = Number(data.callers?.guest_calls) || 0;
  const gradingCalls = sum(totals.filter((t) => t.operation === "grading"), (t) => t.calls);
  const extractionCalls = sum(totals.filter((t) => t.operation === "extraction"), (t) => t.calls);
  const errRate = calls ? errors / calls : 0;
  $("opsTiles").replaceChildren(
    tile("Fehlerquote", calls ? pct(errRate, 1) : "–", `${int(errors)} von ${int(calls)} Aufrufen`,
      calls ? statusEl(errRate < 0.02 ? "good" : errRate < 0.1 ? "warning" : "critical", errRate < 0.02 ? "normal" : errRate < 0.1 ? "erhöht" : "hoch") : null),
    tile("Gast-Aufrufe", int(guests), "ohne Login, nur per IP gezählt", statusEl(guests === 0 ? "good" : "warning", guests === 0 ? "keine" : "prüfen")),
    tile("Vom Deckel blockiert", int(blocked), "TTS-Aufrufe, die Google nie erreicht haben", statusEl(blocked === 0 ? "good" : "serious", blocked === 0 ? "keine" : "Deckel greift")),
    tile("Extraktions-Quote", gradingCalls ? pct(extractionCalls / gradingCalls) : "–", `${int(extractionCalls)} Extraktionen auf ${int(gradingCalls)} Bewertungen (Karten ohne gespeicherte Kontrollpunkte)`),
    tile("Konten mit API-Nutzung", int(data.callers?.distinct_users), "eingeloggte Konten im Zeitraum"),
  );

  // Jede Zeile wird gegen das Limit IHRER Function verglichen (Bucket-Format
  // siehe supabase/functions/_shared/rateLimit.ts).
  const limits = rateLimitTable(config.rate_limits_per_hour);
  const rows = (data.rate_limits_24h || []).map((r) => {
    const b = parseBucket(r.identity);
    const lim = b.scope ? limits[b.scope] : limits.grade; // alter gemeinsamer Zähler: engstes damaliges Limit
    const limit = b.allGuests ? lim.all_guests : lim.per_identity;
    const level = !limit ? "good" : r.peak_hour >= limit ? "critical" : r.peak_hour >= 0.8 * limit ? "warning" : "good";
    const own = session?.user_id && b.identity === `user:${session.user_id}`;
    const kind = b.allGuests ? "alle Gäste zusammen" : b.identity.startsWith("ip:") ? "Gast (IP)" : b.identity.startsWith("connector:") ? "Konto (Konnektor)" : "Konto";
    const fn = b.scope ? lim.function : "alt: gemeinsamer Zähler";
    return [h("code", {}, b.identity), fn, own ? `${kind} (du)` : kind, int(r.requests), limit ? `${int(r.peak_hour)} / ${int(limit)}` : int(r.peak_hour), int(r.active_hours),
      statusEl(level, level === "good" ? "normal" : level === "warning" ? "nahe am Limit" : "Limit erreicht")];
  });
  $("rateTable").replaceChildren(rows.length
    ? table(["Identität", "Function", "Art", "Anfragen 24 h", "Spitze / Stunde", "Aktive Stunden", "Einordnung"], rows, [3, 4, 5])
    : h("div", { class: "empty" }, "Keine Zähler in den letzten 24 Stunden."));
}

// Fallback, falls ein älteres admin-dashboard noch das alte Format liefert.
const DEFAULT_RATE_LIMITS = {
  tts: { function: "text-to-speech", per_identity: 300, all_guests: 1200 },
  grade: { function: "grade-answer", per_identity: 150, all_guests: 600 },
  generate: { function: "generate-questions", per_identity: 40, all_guests: 150 },
  connector: { function: "teach-mcp", per_identity: 200, all_guests: null },
};
function rateLimitTable(fromConfig) {
  const ok = fromConfig && ["tts", "grade", "generate", "connector"].every((k) => fromConfig[k] && typeof fromConfig[k].per_identity === "number");
  return ok ? fromConfig : DEFAULT_RATE_LIMITS;
}

/// "user:<uuid>:grade" -> { identity: "user:<uuid>", scope: "grade" }.
/// "global:all-guests:tts" -> allGuests. "connector:<uuid>" -> teach-mcp.
/// Ohne Suffix (vor dem 20.11.2026): alter gemeinsamer Zähler, scope null.
function parseBucket(bucket) {
  const m = /^(.*):(tts|grade|generate)$/.exec(bucket);
  if (m) return { identity: m[1], scope: m[2], allGuests: m[1] === "global:all-guests" };
  if (bucket.startsWith("connector:")) return { identity: bucket, scope: "connector", allGuests: false };
  return { identity: bucket, scope: null, allGuests: bucket === "global:all-guests" };
}

function streak(daysList, today) {
  const set = new Set(daysList);
  const prevDay = (d) => new Date(Date.parse(`${d}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);
  // Wie in der App: heute noch nicht gelernt bricht die Serie nicht.
  let cursor = set.has(today) ? today : prevDay(today);
  let n = 0;
  while (set.has(cursor)) { n++; cursor = prevDay(cursor); }
  return n;
}

function renderLearning(data) {
  const p = data.period;
  const s = data.learning_summary || {};
  const daily = data.learning_daily || [];
  const labels = dayRange(p.learning_from_day, p.learning_today);
  const byDay = new Map(daily.map((d) => [d.day, d]));
  const learningDays = daily.filter((d) => d.reviews > 0).length;

  $("learnTiles").replaceChildren(
    tile("Bewertungen", int(s.reviews), `${int(s.sprechen)} Sprechen · ${int(s.tippen)} Tippen`),
    tile("Lerntage", int(learningDays), `von ${p.days} Tagen`),
    tile("Serie", `${int(streak(data.review_days_365 || [], p.learning_today))} Tage`, "Lerntage am Stück"),
    tile("Ø Deckung (Sprechen)", s.avg_deckung !== null && s.avg_deckung !== undefined ? `${String(s.avg_deckung).replace(".", ",")} %` : "–", "getroffene Kontrollpunkte"),
    tile("Karten wiederholt", int(s.cards), "verschiedene Karten"),
    tile("Aktive Lernende", int(data.active_learners), "Konten mit Bewertungen"),
  );

  const reviewsFor = (key, d) => Number(byDay.get(d)?.[key]) || 0;
  legend("reviewLegend", MODE_SERIES);
  stackedBars("reviews", "reviewChartBox", labels, MODE_SERIES, reviewsFor, (v) => int(v));
  dailyTable("reviewTable", labels, MODE_SERIES, reviewsFor, int);

  const deckung = labels.map((d) => { const v = byDay.get(d)?.avg_deckung; return v === null || v === undefined ? null : Number(v); });
  lineChart("deckung", "deckungChartBox", labels, deckung, "Ø Deckung", (v) => `${String(v).replace(".", ",")} %`, 100);
  const deckungFor = (_key, d) => { const v = byDay.get(d)?.avg_deckung; return v === null || v === undefined ? null : Number(v); };
  dailyTable("deckungTable", labels, [{ key: "avg_deckung", label: "Ø Deckung" }], deckungFor, (v) => `${String(v).replace(".", ",")} %`);

  // Notenverteilung als segmentierter Balken je Modus
  legend("ratingLegend", RATINGS);
  const ratings = data.ratings_by_mode || [];
  $("ratingBars").replaceChildren(...MODE_SERIES.map((m) => {
    const counts = RATINGS.map((r) => Number(ratings.find((x) => x.mode === m.key && x.rating === r.n)?.n) || 0);
    const total = counts.reduce((a, b) => a + b, 0);
    const blocks = RATINGS.map((r, i) => {
      if (!counts[i]) return null;
      const share = counts[i] / total;
      const bg = css(r.color);
      return h("div", {
        style: `flex:${counts[i]} 1 0;background:${bg};color:${textOn(bg)}`,
        "data-tip": `${m.label} · ${r.label}: ${int(counts[i])} (${pct(share)})`,
        "aria-label": `${r.label}: ${int(counts[i])} (${pct(share)})`,
      }, share >= 0.09 ? pct(share) : "");
    });
    return h("div", { class: "segrow" },
      h("div", { class: "name" }, h("span", {}, m.label), h("span", {}, `${int(total)} Bewertungen`)),
      total ? h("div", { class: "segbar", role: "img", "aria-label": `${m.label}: ${RATINGS.map((r, i) => `${r.label} ${counts[i]}`).join(", ")}` }, blocks)
        : h("div", { class: "empty", style: "padding:8px 0;text-align:left" }, "Keine Bewertungen im Zeitraum."));
  }));

  // Heatmap Wochentag x Stunde
  const heat = data.heatmap || [];
  const max = Math.max(0, ...heat.map((x) => Number(x.n)));
  const steps = ["--seq-100", "--seq-250", "--seq-400", "--seq-550", "--seq-700"];
  const cells = [h("div", {})];
  for (let hr = 0; hr < 24; hr++) cells.push(h("div", { class: "hourlabel" }, hr % 3 === 0 ? String(hr) : ""));
  for (let dow = 1; dow <= 7; dow++) {
    cells.push(h("div", { class: "rowlabel" }, WEEKDAYS[dow - 1]));
    for (let hr = 0; hr < 24; hr++) {
      const n = Number(heat.find((x) => x.dow === dow && x.hour === hr)?.n) || 0;
      const step = n && max ? steps[Math.min(steps.length - 1, Math.ceil((n / max) * steps.length) - 1)] : null;
      const label = `${WEEKDAYS[dow - 1]}, ${hr}–${hr + 1} Uhr: ${int(n)} Bewertungen`;
      cells.push(h("div", { class: "cell", style: step ? `background:var(${step})` : null, "data-tip": label, "aria-label": label }));
    }
  }
  $("heatmap").replaceChildren(max ? h("div", { class: "heat" }, cells) : h("div", { class: "empty" }, "Keine Bewertungen im Zeitraum."));
}

function renderLibrary(data) {
  const p = data.period;
  const lib = data.library || {};
  const users = data.users || {};
  const withKp = Number(lib.with_kontrollpunkte) || 0;
  $("libTiles").replaceChildren(
    tile("Karten", int(lib.cards), `${int(lib.folders)} Ordner · ${int(lib.subfolders)} Unterordner`),
    tile("Neu", int(lib.new), "noch nie bewertet"),
    tile("Gelernt", int(lib.learned), "mit FSRS-Zustand"),
    tile("Fällig jetzt", int(lib.due_now), `${int(lib.due_7d)} in den nächsten 7 Tagen`),
    tile("Mit Kontrollpunkten", lib.cards ? pct(withKp / lib.cards) : "–", `${int(withKp)} Karten; der Rest braucht bei der ersten Bewertung eine Extraktion`),
    tile("Nutzer", int(users.total), `${int(users.new_in_period)} neu im Zeitraum`),
  );
  const labels = dayRange(p.from_day, p.to_day);
  const created = new Map((data.cards_created_daily || []).map((c) => [c.day, Number(c.n)]));
  const series = [{ key: "n", label: "Neue Karten", color: "--s1" }];
  const createdFor = (_k, d) => created.get(d) || 0;
  stackedBars("cards", "cardsChartBox", labels, series, createdFor, (v) => int(v));
  dailyTable("cardsTable", labels, series, createdFor, int);
}

// ---------------------------------------------------------------- Demo-Daten

function demoPayload(nDays) {
  let seed = 42;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
  const now = new Date();
  const today = now.toISOString().slice(0, 10);
  const from = new Date(now.getTime() - (nDays - 1) * 86_400_000).toISOString().slice(0, 10);
  const range = dayRange(from, today);
  const usageDaily = [];
  const learningDaily = [];
  const created = [];
  for (const [i, day] of range.entries()) {
    const active = rnd() > 0.25;
    if (!active) continue;
    const chirpChars = Math.round(800 + rnd() * 2500);
    const waveChars = rnd() > 0.7 ? Math.round(rnd() * 900) : 0;
    const gradings = Math.round(10 + rnd() * 40);
    const extractions = Math.round(gradings * rnd() * 0.25);
    usageDaily.push({ day, provider: "google_tts", price_class: "chirp3_hd", operation: "tts", calls: Math.round(chirpChars / 70), failed: 0, characters: chirpChars, input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, cost_usd: chirpChars * 30e-6 });
    if (waveChars) usageDaily.push({ day, provider: "google_tts", price_class: "wavenet", operation: "tts", calls: Math.round(waveChars / 70), failed: 0, characters: waveChars, input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, cost_usd: waveChars * 4e-6 });
    usageDaily.push({ day, provider: "openai", price_class: "gpt-4o-mini", operation: "grading", calls: gradings, failed: 0, characters: 0, input_tokens: gradings * 950, cached_input_tokens: gradings * 300, output_tokens: gradings * 140, cost_usd: gradings * (650 * 0.15 + 300 * 0.075 + 140 * 0.6) / 1e6 });
    if (extractions) usageDaily.push({ day, provider: "openai", price_class: "gpt-4o-mini", operation: "extraction", calls: extractions, failed: 0, characters: 0, input_tokens: extractions * 1100, cached_input_tokens: 0, output_tokens: extractions * 120, cost_usd: extractions * (1100 * 0.15 + 120 * 0.6) / 1e6 });
    if (i % 9 === 3) usageDaily.push({ day, provider: "openai", price_class: "gpt-4o-mini", operation: "question_generation", calls: 1, failed: 0, characters: 0, input_tokens: 21000, cached_input_tokens: 0, output_tokens: 2600, cost_usd: (21000 * 0.15 + 2600 * 0.6) / 1e6 });
    const sprechen = gradings;
    const tippen = Math.round(rnd() * 30);
    const reviews = sprechen + tippen;
    const r1 = Math.round(reviews * 0.15), r2 = Math.round(reviews * 0.2), r4 = Math.round(reviews * 0.1);
    learningDaily.push({ day, reviews, sprechen, tippen, r1, r2, r3: reviews - r1 - r2 - r4, r4, cards: Math.round(reviews * 0.8), avg_deckung: Math.round((55 + rnd() * 35) * 10) / 10 });
    if (rnd() > 0.6) created.push({ day, n: Math.round(5 + rnd() * 25) });
  }
  const agg = (pred) => usageDaily.filter(pred);
  const group = (provider, price_class, operation, fn) => {
    const rows = agg((r) => r.provider === provider && r.price_class === price_class && r.operation === operation);
    if (!rows.length) return null;
    return { function_name: fn, operation, provider, price_class, calls: sum(rows, (r) => r.calls), ok: sum(rows, (r) => r.calls) - (operation === "grading" ? 2 : 0), errors: operation === "grading" ? 2 : 0, blocked: 0,
      characters: sum(rows, (r) => r.characters), input_tokens: sum(rows, (r) => r.input_tokens), cached_input_tokens: sum(rows, (r) => r.cached_input_tokens), output_tokens: sum(rows, (r) => r.output_tokens),
      cost_usd: sum(rows, (r) => r.cost_usd), avg_duration_ms: provider === "openai" ? (operation === "question_generation" ? 8400 : 1400) : 420 };
  };
  const totals = [
    group("google_tts", "chirp3_hd", "tts", "text-to-speech"),
    group("google_tts", "wavenet", "tts", "text-to-speech"),
    group("openai", "gpt-4o-mini", "grading", "grade-answer"),
    group("openai", "gpt-4o-mini", "extraction", "grade-answer"),
    group("openai", "gpt-4o-mini", "question_generation", "generate-questions"),
  ].filter(Boolean).sort((a, b) => b.cost_usd - a.cost_usd);
  const ratings = [];
  for (const mode of ["sprechen", "tippen"]) {
    const n = sum(learningDaily, (d) => d[mode]);
    [0.16, 0.22, 0.5, 0.12].forEach((share, idx) => ratings.push({ mode, rating: idx + 1, n: Math.round(n * (mode === "tippen" && idx === 3 ? 0.2 : share)) }));
  }
  const heatmap = [];
  for (let dow = 1; dow <= 7; dow++) for (const hour of [8, 9, 12, 17, 18, 19, 20, 21, 22]) if (rnd() > 0.3) heatmap.push({ dow, hour, n: Math.round(rnd() * (hour >= 18 ? 60 : 20)) });
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const mtdRows = usageDaily.filter((r) => Date.parse(`${r.day}T00:00:00Z`) >= monthStart.getTime());
  const mtd = ["chirp3_hd", "wavenet", "gpt-4o-mini"].map((pc) => {
    const rows = mtdRows.filter((r) => r.price_class === pc);
    return { provider: pc === "gpt-4o-mini" ? "openai" : "google_tts", price_class: pc, characters: sum(rows, (r) => r.characters), tokens: sum(rows, (r) => r.input_tokens + r.output_tokens), cost_usd: sum(rows, (r) => r.cost_usd) };
  });
  const daysInMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0)).getUTCDate();
  return {
    data: {
      generated_at: now.toISOString(),
      period: { days: nDays, tz: "Europe/Berlin", from: `${from}T00:00:00Z`, from_day: from, to_day: today, learning_from_day: from, learning_today: today, month_start: monthStart.toISOString(), month_days_elapsed: now.getUTCDate(), month_days_total: daysInMonth },
      measuring_since: new Date(now.getTime() - 400 * 86_400_000).toISOString(),
      spend_guard: { total_usd: 6.4821, updated_at: now.toISOString() },
      usage_totals: totals,
      usage_daily: usageDaily,
      previous_period: { google_tts: sum(totals.filter((t) => t.provider === "google_tts"), (t) => t.cost_usd) * 0.8, openai: sum(totals.filter((t) => t.provider === "openai"), (t) => t.cost_usd) * 1.1 },
      month_to_date: mtd,
      callers: { guest_calls: 0, user_calls: sum(totals, (t) => t.calls), distinct_users: 1 },
      rate_limits_24h: [
        { identity: "user:11111111-2222-3333-4444-555555555555:tts", requests: 168, peak_hour: 71, active_hours: 4 },
        { identity: "user:11111111-2222-3333-4444-555555555555:grade", requests: 112, peak_hour: 48, active_hours: 4 },
        { identity: "connector:11111111-2222-3333-4444-555555555555", requests: 14, peak_hour: 9, active_hours: 2 },
        { identity: "user:11111111-2222-3333-4444-555555555555:generate", requests: 3, peak_hour: 2, active_hours: 1 },
      ],
      learning_daily: learningDaily,
      learning_summary: { reviews: sum(learningDaily, (d) => d.reviews), sprechen: sum(learningDaily, (d) => d.sprechen), tippen: sum(learningDaily, (d) => d.tippen), cards: 412, avg_deckung: 71.4 },
      ratings_by_mode: ratings,
      heatmap,
      review_days_365: learningDaily.map((d) => d.day),
      active_learners: 1,
      library: { folders: 6, subfolders: 31, cards: 846, learned: 512, new: 334, due_now: 47, due_7d: 163, with_kontrollpunkte: 702 },
      cards_created_daily: created,
      users: { total: 1, new_in_period: 0 },
    },
    config: {
      time_zone: "Europe/Berlin",
      google_cloud_ceiling_usd: 20,
      tts_price_per_million_chars_usd: { wavenet: 4, chirp3_hd: 30 },
      openai_price_per_million_tokens_usd: { "gpt-4o-mini": { input: 0.15, cachedInput: 0.075, output: 0.6 } },
      rate_limits_per_hour: DEFAULT_RATE_LIMITS,
    },
  };
}

// ---------------------------------------------------------------- Start

if (window.Chart) {
  Chart.defaults.font.family = 'system-ui, -apple-system, "Segoe UI", sans-serif';
}
if (DEMO || session) showDashboard();
else showLogin();
