/// The web app page. State arrives over `/events` (server-sent events), so the page updates live.
let webAppHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ProjectsBar</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 46rem; margin: 0 auto; padding: 1rem; line-height: 1.4; }
  h2 { font-size: 1.1rem; margin-top: 1.5rem; }
  ul { list-style: none; padding: 0; margin: 0; }
  li { display: flex; gap: 0.75rem; align-items: center; padding: 0.5rem 0; border-bottom: 1px solid #ddd; }
  li > div { flex: 1; min-width: 0; }
  .meta { color: #666; font-size: 0.85rem; overflow-wrap: anywhere; }
  .error { color: #b00; }
  input[type=search] { width: 100%; box-sizing: border-box; padding: 0.4rem; font-size: 1rem; }
  button { font-size: 0.9rem; white-space: nowrap; }
</style>
</head>
<body>
<h1>ProjectsBar</h1>
<p id="status" class="meta">Connecting…</p>
<button id="logout">Log out</button>
<p id="error" class="error" hidden></p>
<h2>Sessions</h2>
<ul id="sessions"></ul>
<h2>Projects</h2>
<input id="filter" type="search" placeholder="Filter projects" autocomplete="off">
<ul id="projects"></ul>
<script>
let state = { projects: [], sessions: [] };
const pending = new Set();

const el = (tag, props = {}, ...children) => {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children.filter((child) => child != null));
  return node;
};

const relativeTime = (ms) => {
  const seconds = Math.round((Date.now() - ms) / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  return days < 7 ? `${days}d` : `${Math.floor(days / 7)}w`;
};

const post = async ({ url, body, key }) => {
  pending.add(key);
  render();
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (response.status === 401) return location.reload();
    if (!response.ok) throw new Error(await response.text());
  } catch (error) {
    alert(error.message);
  } finally {
    pending.delete(key);
    render();
  }
};

const renderSessions = () => {
  const list = document.getElementById("sessions");
  const sessions = [...state.sessions].sort((a, b) => b.startedAt - a.startedAt);
  if (sessions.length === 0) {
    list.replaceChildren(el("li", { className: "meta", textContent: "No active sessions" }));
    return;
  }
  list.replaceChildren(...sessions.map((session) => {
    const project = session.cwd.split("/").pop() || session.cwd;
    const status = [session.kind, session.status, session.state, relativeTime(session.startedAt)].filter(Boolean).join(" · ");
    const link = session.remoteURL
      ? el("a", { href: session.remoteURL, target: "_blank", rel: "noopener", textContent: "Open" })
      : session.kind === "background" ? el("span", { className: "meta", textContent: "Connecting…" }) : null;
    const stopKey = `stop:${session.id}`;
    const stop = session.kind === "background" && session.id
      ? el("button", {
          textContent: pending.has(stopKey) ? "Stopping…" : "Stop",
          disabled: pending.has(stopKey),
          onclick: () => confirm(`Stop ${session.name}?`) && post({ url: "/api/sessions/stop", body: { id: session.id }, key: stopKey }),
        })
      : null;
    return el("li", {},
      el("div", {},
        el("div", { textContent: `${project} – ${session.name}` }),
        el("div", { className: "meta", textContent: status })),
      link, stop);
  }));
};

const renderProjects = () => {
  const query = document.getElementById("filter").value.trim().toLowerCase();
  const counts = new Map();
  for (const session of state.sessions) counts.set(session.cwd, (counts.get(session.cwd) ?? 0) + 1);
  const projects = state.projects.filter((project) =>
    !query || project.name.toLowerCase().includes(query) || project.path.toLowerCase().includes(query));
  document.getElementById("projects").replaceChildren(...projects.map((project) => {
    const key = `spawn:${project.path}`;
    const count = counts.get(project.path);
    const meta = [project.path, project.lastOpenedAt && relativeTime(project.lastOpenedAt), count && `${count} active`]
      .filter(Boolean).join(" · ");
    return el("li", {},
      el("div", {},
        el("div", { textContent: project.name }),
        el("div", { className: "meta", textContent: meta })),
      el("button", {
        textContent: pending.has(key) ? "Starting…" : "New session",
        disabled: pending.has(key),
        onclick: () => post({ url: "/api/sessions", body: { path: project.path }, key }),
      }));
  }));
};

const render = () => {
  const error = document.getElementById("error");
  error.hidden = !state.error;
  error.textContent = state.error ?? "";
  renderSessions();
  renderProjects();
};

document.getElementById("filter").addEventListener("input", renderProjects);
document.getElementById("logout").addEventListener("click", async () => {
  await fetch("/api/logout", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
  location.reload();
});

const events = new EventSource("/events");
events.onopen = () => { document.getElementById("status").textContent = "Live"; };
events.onerror = async () => {
  document.getElementById("status").textContent = "Disconnected, reconnecting…";
  // EventSource retries forever, so check whether the session expired and show the login page.
  const response = await fetch("/api/state").catch(() => null);
  if (response?.status === 401) location.reload();
};
events.onmessage = (event) => {
  state = JSON.parse(event.data);
  document.getElementById("status").textContent = `Live · updated ${new Date().toLocaleTimeString()}`;
  render();
};
</script>
</body>
</html>
"""#

/// Served at `/` until the browser has a valid session cookie.
let loginHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ProjectsBar</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 46rem; margin: 0 auto; padding: 1rem; line-height: 1.4; }
  input { font-size: 1rem; padding: 0.4rem; }
  .error { color: #b00; }
</style>
</head>
<body>
<h1>ProjectsBar</h1>
<form id="login">
  <p><input id="password" type="password" placeholder="Password" autocomplete="current-password" autofocus required></p>
  <p><button type="submit">Log in</button></p>
  <p id="error" class="error" hidden></p>
</form>
<script>
document.getElementById("login").addEventListener("submit", async (event) => {
  event.preventDefault();
  const error = document.getElementById("error");
  error.hidden = true;
  const response = await fetch("/api/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password: document.getElementById("password").value }),
  });
  if (response.ok) return location.reload();
  error.textContent = await response.text();
  error.hidden = false;
});
</script>
</body>
</html>
"""#
