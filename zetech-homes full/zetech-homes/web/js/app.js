/* Zetech Homes - shared helpers: Supabase connection, formatting, page chrome.
   Every page imports this one file. */
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.0/+esm";

const cfg = window.ZH_CONFIG || {};
export const configured = Boolean(
  cfg.SUPABASE_URL && cfg.SUPABASE_KEY &&
  !cfg.SUPABASE_URL.includes("YOUR-PROJECT") && !cfg.SUPABASE_KEY.includes("YOUR-")
);

/** The one connection to your Supabase project. */
export const sb = configured
  ? createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
    })
  : null;

/* ------------------------------------------------------------ formatting */
export const esc = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const kes = (n) => "KES " + Number(n || 0).toLocaleString("en-KE", { maximumFractionDigits: 0 });
export const num = (n) => Number(n || 0).toLocaleString("en-KE", { maximumFractionDigits: 0 });

const dtf = new Intl.DateTimeFormat("en-GB", { timeZone: "Africa/Nairobi", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
const df = new Intl.DateTimeFormat("en-GB", { timeZone: "Africa/Nairobi", day: "2-digit", month: "short", year: "numeric" });
export const when = (ts) => (ts ? dtf.format(new Date(ts)) : "-");
export const day = (ts) => (ts ? df.format(new Date(ts + (String(ts).length === 10 ? "T00:00:00" : ""))) : "-");

export const STATUS_LABEL = { AVAILABLE: "Available", RESERVED: "Reserved", SOLD: "Sold" };
export const badge = (status, extra = "") =>
  `<span class="badge status-${esc(String(status).toLowerCase())}" ${extra}>${esc(STATUS_LABEL[status] || status)}</span>`;

export const ACTION_LABEL = {
  INSERT_ENTRY: "Listing created", STATUS_UPDATE: "Status change", PRICE_EDIT: "Price edit",
  DETAILS_EDIT: "Details edit", ARCHIVE: "Listing archived", DUPLICATE_BLOCKED: "Duplicate blocked",
  MVCC_CONFLICT: "Concurrent update conflict", LOGIN: "Staff login",
};

export const displayId = (staff) => (staff ? `${staff.role === "MANAGER" ? "MGR" : "AGT"}-${String(staff.staff_no).padStart(4, "0")}` : "system");
export const propId = (id) => `PROP-${String(id).padStart(5, "0")}`;

export const imageUrl = (path) =>
  path ? `${cfg.SUPABASE_URL}/storage/v1/object/public/property-images/${path.split("/").map(encodeURIComponent).join("/")}` : "";

export const param = (name) => new URLSearchParams(location.search).get(name);

const HOUSE_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 11 12 3l9 8"/><path d="M5 10v10h14V10"/><path d="M10 20v-6h4v6"/></svg>';
export const photoOrPlaceholder = (path, id, alt = "") =>
  path ? `<img src="${esc(imageUrl(path))}" alt="${esc(alt)}" loading="lazy">`
       : `<div class="ph tone-${Math.abs(Number(id)) % 10}">${HOUSE_SVG}</div>`;

/* ------------------------------------------------------------ messages */
export function toast(message, type = "ok") {
  let wrap = document.querySelector(".toast-wrap");
  if (!wrap) { wrap = document.createElement("div"); wrap.className = "toast-wrap"; wrap.setAttribute("role", "status"); document.body.appendChild(wrap); }
  const el = document.createElement("div");
  el.className = "toast" + (type === "error" ? " error" : "");
  el.textContent = message;
  wrap.appendChild(el);
  setTimeout(() => el.remove(), 5000);
}

export function notice(target, type, html) {
  const el = typeof target === "string" ? document.querySelector(target) : target;
  if (!el) return;
  el.innerHTML = html ? `<ul class="messages" role="status"><li class="${type}">${html}</li></ul>` : "";
}

export const loading = (text = "Loading...") => `<div class="loading"><div class="spinner"></div>${esc(text)}</div>`;

export function configBanner() {
  if (configured) return;
  const bar = document.createElement("div");
  bar.className = "config-banner";
  bar.innerHTML = "Supabase is not connected yet. Open <code>web/config.js</code> and paste your project URL and anon key, then reload.";
  document.body.prepend(bar);
}

/* ------------------------------------------------------------ database calls */
/** Calls a database function (rpc_*) and always returns { ok, code, message, ... }. */
export async function rpc(name, args = {}) {
  if (!sb) return { ok: false, code: "config", message: "Supabase is not connected yet (see config.js)." };
  const { data, error } = await sb.rpc(name, args);
  if (error) {
    if (/JWT|expired|not authenticated/i.test(error.message)) { goLogin(); }
    return { ok: false, code: "error", message: error.message };
  }
  return data ?? { ok: false, code: "empty", message: "No response from the server." };
}

export function goLogin(reason) {
  const base = location.pathname.includes("/staff/") ? "login.html" : "staff/login.html";
  location.href = base + (reason ? `?msg=${encodeURIComponent(reason)}` : "");
}

/* ------------------------------------------------------------ lookups (cached per page) */
let lookupCache;
export async function lookups() {
  if (lookupCache) return lookupCache;
  const [c, s, t] = await Promise.all([
    sb.from("counties").select("id,name").order("name"),
    sb.from("sub_counties").select("id,county_id,name").order("name"),
    sb.from("property_types").select("id,name").order("name"),
  ]);
  lookupCache = { counties: c.data || [], subCounties: s.data || [], types: t.data || [] };
  return lookupCache;
}

export const options = (rows, selected, blank) =>
  (blank ? `<option value="">${esc(blank)}</option>` : "") +
  rows.map((r) => `<option value="${esc(r.id)}" ${String(r.id) === String(selected) ? "selected" : ""}>${esc(r.name)}</option>`).join("");

/* ------------------------------------------------------------ public site chrome */
const LOGO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 11 12 3l9 8"/><path d="M5 10v10h14V10"/><path d="M10 20v-6h4v6"/></svg>';

export function publicChrome(active) {
  configBanner();
  const cls = (name) => (active === name ? 'class="active"' : "");
  document.getElementById("site-header").outerHTML = `
    <header class="site-header"><div class="container">
      <a class="brand" href="index.html">${LOGO} Zetech Homes</a>
      <button class="nav-toggle" type="button" aria-label="Menu">&#9776;</button>
      <nav class="site-nav" aria-label="Main">
        <a href="index.html" ${cls("browse")}>Browse properties</a>
        <a href="status.html" ${cls("status")}>Check a listing</a>
        <a class="btn" href="staff/login.html">Staff login</a>
      </nav>
    </div></header>`;
  const footer = document.getElementById("site-footer");
  if (footer) footer.outerHTML = `<footer class="site-footer"><div class="container"><strong>Zetech Homes</strong> &middot; Every listing shows its live status, checked against the agency's records.<br>Diploma in Business Information Technology project &middot; Zetech University</div></footer>`;
  document.querySelector(".nav-toggle")?.addEventListener("click", () => document.querySelector(".site-nav").classList.toggle("open"));
}

/** Property card used on the home/browse page. */
export function card(p) {
  const available = p.status === "AVAILABLE";
  return `
  <article class="card">
    <a class="card-media" href="property.html?id=${p.id}" aria-label="${esc(p.title)}">
      ${photoOrPlaceholder(p.image_path, p.id, p.title)}
      ${badge(p.status, `data-live-status data-lr="${esc(p.lr_number)}"`).replace('<span class="badge', '<span style="position:absolute;top:.8rem;left:.8rem" class="badge')}
    </a>
    <div class="card-body">
      <p class="card-price">${kes(p.price)}</p>
      <h3><a href="property.html?id=${p.id}">${esc(p.title)}</a></h3>
      <p class="muted small" style="margin:0">${esc(p.location)} &middot; ${esc(p.sub_county)}, ${esc(p.county)}</p>
      <ul class="facts"><li>${p.bedrooms ? p.bedrooms + " bed" : "Studio"}</li><li>${p.bathrooms} bath</li><li class="mono">${esc(p.lr_number)}</li></ul>
      <div class="card-actions">
        ${available
          ? `<a class="btn btn-sm" href="property.html?id=${p.id}#request">Schedule a visit</a><a class="btn btn-ghost btn-sm" href="property.html?id=${p.id}">Details</a>`
          : `<a class="btn btn-ghost btn-sm" href="property.html?id=${p.id}">Reserved &ndash; join waiting list</a>`}
      </div>
    </div>
  </article>`;
}

/** Keeps every status badge on the page current (customers see changes within ~12 s). */
export function startLiveStatus({ onChange } = {}) {
  if (!sb) return;
  const tick = async () => {
    const badges = [...document.querySelectorAll("[data-live-status]")];
    if (!badges.length) return;
    const lrs = [...new Set(badges.map((b) => b.dataset.lr))];
    const { data } = await sb.from("public_listings").select("lr_number,status").in("lr_number", lrs);
    (data || []).forEach((row) => {
      badges.filter((b) => b.dataset.lr === row.lr_number).forEach((b) => {
        const now = row.status.toLowerCase();
        if (!b.classList.contains("status-" + now)) {
          b.className = b.className.replace(/status-\w+/, "status-" + now) + " flash";
          b.textContent = STATUS_LABEL[row.status] || row.status;
          if (onChange) onChange(row);
        }
      });
    });
  };
  setInterval(tick, 12000);
}

/* ------------------------------------------------------------ staff shell */
/** Checks the login, loads the staff profile and draws the sidebar.
    Returns { session, me, unread } or redirects to the login page. */
export async function staffPage({ active = "", manager = false } = {}) {
  configBanner();
  if (!sb) { document.getElementById("main").innerHTML = '<div class="empty">Connect Supabase in <code>web/config.js</code> first.</div>'; throw new Error("not configured"); }
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { goLogin(); throw new Error("no session"); }

  const { data: me, error } = await sb.from("staff").select("*").eq("id", session.user.id).maybeSingle();
  if (error || !me || !me.is_active) {
    await sb.auth.signOut();
    goLogin("This account is not an active staff account.");
    throw new Error("not staff");
  }
  if (manager && me.role !== "MANAGER") {
    document.getElementById("main").innerHTML = '<div class="panel" style="max-width:520px;margin:2rem auto;text-align:center"><h1 style="font-size:1.8rem">Access denied</h1><p class="muted">This page is for System Managers only.</p><a class="btn" href="index.html">Back to my dashboard</a></div>';
    renderSidebar(me, active, 0);
    throw new Error("forbidden");
  }
  const { count } = await sb.from("notifications").select("id", { count: "exact", head: true }).eq("is_read", false);
  renderSidebar(me, active, count || 0);
  return { session, me, unread: count || 0 };
}

function renderSidebar(me, active, unread) {
  const link = (key, href, label, pill) =>
    `<a href="${href}" class="${active === key ? "active" : ""}">${label}${pill ? `<span class="count-pill">${pill}</span>` : ""}</a>`;
  document.getElementById("sidebar").innerHTML = `
    <a class="brand" href="index.html">${LOGO} Zetech Homes</a>
    <nav>
      ${link("dashboard", "index.html", "Dashboard")}
      ${link("properties", "properties.html", "Properties")}
      ${link("add", "property-form.html", "Add property")}
      ${link("viewing", "viewing.html", "Viewing requests")}
      ${link("notifications", "notifications.html", "Notifications", unread || "")}
      ${me.role === "MANAGER" ? `<div class="nav-label">Management</div>${link("audit", "audit.html", "Audit log")}${link("reports", "reports.html", "Reports")}${link("users", "users.html", "Staff accounts")}` : ""}
      <div class="nav-label">Public site</div>
      <a href="../index.html" target="_blank" rel="noopener">View customer portal</a>
    </nav>
    <div class="me">
      <strong>${esc(me.full_name)}</strong>
      <span>${me.role === "MANAGER" ? "System Manager" : "Estate Agent"} &middot; ${esc(displayId(me))}</span>
      <button class="btn btn-ghost btn-sm btn-block" id="logout" style="color:#fff;border-color:rgba(255,255,255,.4)" type="button">Log out</button>
    </div>`;
  document.getElementById("logout").addEventListener("click", async () => {
    await rpc("rpc_log_logout");
    await sb.auth.signOut();
    location.href = "../index.html";
  });
  document.querySelector("[data-sidebar-toggle]")?.addEventListener("click", () => document.getElementById("sidebar").classList.toggle("open"));
}

/** Staff list of people, used to show "agent" names (RLS lets every staff member read these). */
export async function staffMap() {
  const { data } = await sb.from("staff").select("id,staff_no,full_name,role,is_active");
  return Object.fromEntries((data || []).map((s) => [s.id, s]));
}

/* ------------------------------------------------------------ misc */
export function paginationHtml(page, pageSize, total) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (pages <= 1) return "";
  return `<nav class="pagination" aria-label="Pages">
    <button class="btn btn-ghost btn-sm" data-page="${page - 1}" ${page <= 1 ? "disabled" : ""}>&larr; Previous</button>
    <span class="muted small">Page ${page} of ${pages}</span>
    <button class="btn btn-ghost btn-sm" data-page="${page + 1}" ${page >= pages ? "disabled" : ""}>Next &rarr;</button>
  </nav>`;
}

export function csvDownload(filename, headers, rows) {
  const cell = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const text = [headers, ...rows].map((r) => r.map(cell).join(",")).join("\r\n");
  const blob = new Blob(["﻿" + text], { type: "text/csv;charset=utf-8" });
  const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: filename });
  document.body.appendChild(a); a.click(); a.remove();
}

export async function pdfDownload(filename, title, headers, rows) {
  const load = (src) => new Promise((res, rej) => { const s = document.createElement("script"); s.src = src; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
  if (!window.jspdf) {
    await load("https://cdn.jsdelivr.net/npm/jspdf@2.5.1/dist/jspdf.umd.min.js");
    await load("https://cdn.jsdelivr.net/npm/jspdf-autotable@3.8.2/dist/jspdf.plugin.autotable.min.js");
  }
  const doc = new window.jspdf.jsPDF({ orientation: "landscape", unit: "pt", format: "a4" });
  doc.setFontSize(16); doc.text(`Zetech Homes - ${title}`, 40, 40);
  doc.setFontSize(9); doc.text(`Generated ${dtf.format(new Date())} (EAT) - ${rows.length} rows`, 40, 56);
  doc.autoTable({ head: [headers], body: rows.map((r) => r.map((c) => String(c ?? ""))), startY: 70,
    styles: { fontSize: 7, cellPadding: 3 }, headStyles: { fillColor: [20, 81, 63] } });
  doc.save(filename);
}
