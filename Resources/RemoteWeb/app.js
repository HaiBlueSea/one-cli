(function () {
  const pair = document.getElementById("pair");
  const list = document.getElementById("list");
  const termHost = document.getElementById("term");
  const home = document.getElementById("home");
  const screen = document.getElementById("screen");
  const screenTitle = document.getElementById("screenTitle");
  const screenName = document.getElementById("screenName");
  const hint = document.getElementById("hint");
  const mode = document.getElementById("mode");
  const ack = document.getElementById("ack");
  const draft = document.getElementById("draft");
  const confirmPaste = document.getElementById("confirmPaste");
  const challenge = new URLSearchParams(location.hash.replace(/^#/, "")).get("c") || "";
  if (location.hash) history.replaceState(null, "", location.pathname + location.search);

  let selected = "";
  let revision = "0";
  let lastText = "";
  let screenLines = [];
  let preserveLayout = false;
  const layoutPreferences = new Map();
  let screenGeneration = 0;
  let renderedScreen = "";
  let followTail = true;
  let latestSessions = [];
  let poll = 0;
  let leaseId = "";
  let composing = false;
  let pasteArmed = false;
  let lastRequestId = "";
  let failStreak = 0;
  let authorized = false;
  let lastActivity = Date.now();
  let lastSessions = 0;
  let lastHeartbeat = 0;
  let sessionsPending = null;
  let screenPending = null;
  let inputPending = false;
  let draftRevision = 0;
  let renderedSessions = "";
  const pollDelays = [500, 1000, 2000, 5000];
  let pollLevel = 0;
  let unchangedScreens = 0;
  let activityVersion = 0;
  let lastScreenSignature = null;
  let refreshPending = false;

  function apiFetch(path, options, controller) {
    controller = controller || new AbortController();
    const timeout = setTimeout(function () { controller.abort(); }, 10000);
    return fetch(path, Object.assign({}, options, { signal: controller.signal }))
      .then(async function (response) {
        return { status: response.status, body: await response.text() };
      })
      .finally(function () { clearTimeout(timeout); });
  }

  function markActive() {
    lastActivity = Date.now();
    activityVersion += 1;
    pollLevel = 0;
    unchangedScreens = 0;
    if (authorized && !document.hidden) schedulePoll(pollDelays[0]);
  }

  function refreshNow() {
    markActive();
    refreshPending = true;
    if (authorized && !document.hidden) schedulePoll(0);
  }

  function observeScreen(changed, activity) {
    if (changed) {
      pollLevel = 0;
      unchangedScreens = 0;
    } else if (activity === activityVersion) {
      unchangedScreens += 1;
      if (unchangedScreens >= 3) {
        pollLevel = Math.min(pollLevel + 1, pollDelays.length - 1);
        unchangedScreens = 0;
      }
    }
  }

  ["pointerdown", "keydown", "input", "touchstart", "wheel"].forEach(function (event) {
    document.addEventListener(event, markActive, { passive: true });
  });

  function text(value) {
    return String(value == null ? "" : value);
  }

  function setMode(label) {
    mode.textContent = label;
    document.body.classList.toggle("controlling", !!leaseId);
  }

  function setHint(message, ok) {
    hint.textContent = message;
    hint.className = ok ? "ok" : "";
    if (!ok && !screen.hidden) setAck(message);
  }

  function groupName(cwd) {
    if (/^\/Users\/[^/]+\/?$/.test(cwd) || cwd === "~") return "主目录";
    const parts = cwd.split("/").filter(Boolean);
    return parts.length ? parts[parts.length - 1] : "/";
  }

  const folderIcon = '<svg viewBox="0 0 24 24" width="20" height="20"><path d="M3.5 7.5A1.5 1.5 0 0 1 5 6h4l2 2h8a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/></svg>';
  const chevronIcon = '<svg viewBox="0 0 24 24" width="16" height="16"><path d="M9 5l7 7-7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  const stateLabels = { working: "运行中", idle: "就绪", needsInput: "等待输入", unknown: "状态未知" };

  function span(className, value) {
    const node = document.createElement("span");
    node.className = className;
    node.textContent = value;
    return node;
  }

  function renderSessions(sessions) {
    const signature = JSON.stringify([sessions.map(function (item) {
      return [item.id, item.cwd, item.title, item.state, item.ptyGeneration];
    }), selected, leaseId]);
    if (signature === renderedSessions) return;
    renderedSessions = signature;
    const groups = [];
    const byCwd = {};
    sessions.forEach(function (item) {
      const cwd = text(item.cwd);
      if (!byCwd[cwd]) {
        byCwd[cwd] = { cwd: cwd, items: [] };
        groups.push(byCwd[cwd]);
      }
      byCwd[cwd].items.push(item);
    });
    list.textContent = "";
    groups.forEach(function (group) {
      const box = document.createElement("div");
      box.className = "group";
      const head = document.createElement("div");
      head.className = "group-head";
      head.innerHTML = folderIcon;
      const name = document.createElement("div");
      name.className = "group-name";
      const strong = document.createElement("strong");
      strong.textContent = groupName(group.cwd);
      const small = document.createElement("small");
      small.textContent = group.cwd;
      name.appendChild(strong);
      name.appendChild(small);
      head.appendChild(name);
      head.appendChild(span("group-count", group.items.length + " 个会话"));
      box.appendChild(head);
      const cards = document.createElement("div");
      cards.className = "cards";
      group.items.forEach(function (item) {
        const button = document.createElement("button");
        const controlled = item.id === selected && !!leaseId;
        button.type = "button";
        button.className = (item.id === selected ? "active" : "") + (controlled ? " held" : "");
        const state = text(item.state);
        const dot = span("dot " + (stateLabels[state] ? state : "none"), "");
        if (stateLabels[state]) dot.title = stateLabels[state];
        button.appendChild(dot);
        button.appendChild(span("name", text(item.title)));
        button.appendChild(span("tag", controlled ? "控制中" : "只读"));
        const chev = span("chev", "");
        chev.innerHTML = chevronIcon;
        button.appendChild(chev);
        button.addEventListener("click", function () { openScreen(item.id); });
        cards.appendChild(button);
        if (item.id === selected) {
          screenTitle.textContent = groupName(group.cwd);
          screenName.textContent = text(item.title);
        }
      });
      box.appendChild(cards);
      list.appendChild(box);
    });
  }

  function setAck(message) {
    ack.textContent = message;
  }

  function showPair(status, code) {
    pair.hidden = false;
    pair.textContent = "";
    const line = document.createElement("p");
    line.textContent = status === "pending"
      ? "请在 Mac 确认配对，确认码 " + text(code)
      : status === "ready" ? "已授权。先只读，需要输入时再请求控制。" : "等待配对。";
    pair.appendChild(line);
  }

  function tableColumns(line) {
    const row = line.trim();
    // Only consecutive, consistently separated rows qualify. A border or an
    // indented sentence alone must not turn surrounding prose into a wide block.
    if (/^[+|\u2500-\u257f\s:=\-]+$/u.test(row) && /[─━═=\-]/u.test(row)) return 0;
    if (!/[|│┃║]/u.test(row)) return -1;
    const enclosed = /^[|│┃║].*[|│┃║]$/u.test(row);
    const inner = row.replace(/^[|│┃║]|[|│┃║]$/gu, "").trim();
    const cells = inner.split(/[|│┃║]/u);
    // Outer-only frames do not identify every column; require a column gap.
    if (cells.length === 1 && enclosed) return /\S[ \t]{2,}\S/.test(inner) ? 2 : -1;
    return cells.length >= 2 ? cells.length : -1;
  }

  function readingBlocks(lines) {
    const blocks = [];
    function append(start, end, fixed) {
      const previous = blocks[blocks.length - 1];
      if (!fixed && previous && !previous.fixed && lines[start].trim() && lines[previous.start].trim()) previous.end = end;
      else blocks.push({ start: start, end: end, fixed: fixed });
    }
    for (let i = 0; i < lines.length;) {
      const start = i;
      const opening = /^\s*(`{3,}|~{3,})/.exec(lines[i]);
      if (opening) {
        const fence = opening[1];
        i += 1;
        while (i < lines.length) {
          const closing = /^\s*(`{3,}|~{3,})\s*$/.exec(lines[i++]);
          if (closing && closing[1][0] === fence[0] && closing[1].length >= fence.length) break;
        }
        append(start, i, false);
      } else if (!lines[i].trim()) {
        while (i < lines.length && !lines[i].trim()) i += 1;
        append(start, i, false);
      } else if (tableColumns(lines[i]) >= 0) {
        let columns = 0;
        let rows = 0;
        let bordered = false;
        let enclosed = true;
        while (i < lines.length) {
          const count = tableColumns(lines[i]);
          if (count < 0 || (count > 0 && columns && count !== columns)) break;
          if (count > 0) {
            columns = count;
            rows += 1;
            enclosed = enclosed && /^\s*[|│┃║].*[|│┃║]\s*$/u.test(lines[i]);
          } else bordered = true;
          i += 1;
        }
        append(start, i, rows >= 2 && (bordered || enclosed));
      } else {
        i += 1;
        append(start, i, false);
      }
    }
    return blocks;
  }

  function updateLayoutToggle() {
    const toggle = document.getElementById("preserveLayout");
    toggle.setAttribute("aria-pressed", String(preserveLayout));
    toggle.textContent = preserveLayout ? "原样" : "阅读";
    toggle.setAttribute("aria-label", preserveLayout ? "原样，切换到阅读" : "阅读，切换到原样");
  }

  function compactText(content, value) {
    // Keep source whitespace in textContent without giving blank runs full rows.
    const rows = value.split("\n");
    for (let start = 0; start < rows.length;) {
      const blank = !rows[start].trim();
      let end = start + 1;
      while (end < rows.length && (!rows[end].trim()) === blank) end += 1;
      const run = document.createElement("span");
      run.className = blank ? "blank-lines" : "text-lines";
      if (blank && (start === 0 || end === rows.length)) run.classList.add("edge-space");
      run.textContent = rows.slice(start, end).join("\n");
      if (end < rows.length) {
        const boundary = document.createElement("span");
        boundary.hidden = true;
        boundary.textContent = "\n";
        run.appendChild(boundary);
      }
      content.appendChild(run);
      start = end;
    }
  }

  termHost.addEventListener("scroll", function () {
    followTail = termHost.scrollHeight - termHost.clientHeight - termHost.scrollTop < 24;
  }, { passive: true });
  const termResize = new ResizeObserver(function () {
    if (followTail) termHost.scrollTop = termHost.scrollHeight;
  });
  termResize.observe(termHost);

  function renderReading() {
    const signature = JSON.stringify([preserveLayout, screenLines]);
    if (signature === renderedScreen) return;
    const scrollTop = termHost.scrollTop;
    const atBottom = !renderedScreen || termHost.scrollHeight - termHost.clientHeight - scrollTop < 24;
    const oldBlocks = Array.from(termHost.querySelectorAll(".layout-block"));
    const used = new Set();
    const contentRoot = document.createElement("div");
    contentRoot.className = "term-content";
    const restore = [];
    const blocks = preserveLayout ? [{ start: 0, end: screenLines.length, fixed: true }] : readingBlocks(screenLines);
    blocks.forEach(function (part) {
      const value = screenLines.slice(part.start, part.end).join("\n") + (part.end < screenLines.length ? "\n" : "");
      const content = document.createElement("pre");
      content.className = "reading-text";
      compactText(content, value);
      if (!value.trim()) {
        content.classList.add("blank-lines");
        if (part.start === 0 || part.end === screenLines.length) content.classList.add("edge-space");
      }
      if (part.fixed) {
        const block = document.createElement("div");
        block.className = "layout-block";
        block.appendChild(content);
        // Prefer matching content when an earlier block was inserted or removed.
        let previous = oldBlocks.find(function (old) { return !used.has(old) && old.textContent === value; });
        if (!previous) previous = oldBlocks.find(function (old) { return !used.has(old) && old.dataset.start === String(part.start); });
        if (previous) { used.add(previous); restore.push([block, previous.scrollLeft]); }
        block.dataset.start = String(part.start);
        contentRoot.appendChild(block);
      } else {
        contentRoot.appendChild(content);
      }
    });
    termHost.replaceChildren(contentRoot);
    termHost.setAttribute("aria-busy", "false");
    renderedScreen = signature;
    restore.forEach(function (item) { item[0].scrollLeft = item[1]; });
    followTail = atBottom;
    termHost.scrollTop = atBottom ? termHost.scrollHeight : scrollTop;
  }

  function draw(data) {
    screenLines = data.lines || [];
    lastText = screenLines.join("\n");
    preserveLayout = layoutPreferences.get(selected) || false;
    updateLayoutToggle();
    renderReading();
  }

  document.getElementById("preserveLayout").addEventListener("click", function () {
    preserveLayout = !preserveLayout;
    layoutPreferences.set(selected, preserveLayout);
    updateLayoutToggle();
    renderReading();
  });

  function loadSessions() {
    if (sessionsPending) return sessionsPending;
    lastSessions = Date.now();
    sessionsPending = apiFetch("/api/sessions", { credentials: "same-origin" }).then(function (response) {
      if (response.status === 401) {
        authorized = false;
        setHint("未授权。请重新扫码。");
        dropControl();
        return null;
      }
      return JSON.parse(response.body);
    }).then(function (data) {
      if (!data || !data.sessions) return;
      failStreak = 0;
      authorized = true;
      pair.hidden = true;
      list.hidden = false;
      setHint("已授权 · 手机自动换行，不改变 Mac 终端", true);
      latestSessions = data.sessions;
      const liveIds = new Set(data.sessions.map(function (item) { return item.id; }));
      layoutPreferences.forEach(function (_, id) { if (!liveIds.has(id)) layoutPreferences.delete(id); });
      renderSessions(data.sessions);
    }).catch(function () {
      failStreak += 1;
      dropControl();
      setHint("连接中断，主机状态未知。");
    }).finally(function () { sessionsPending = null; });
    return sessionsPending;
  }

  function openScreen(id) {
    if (selected && id !== selected && leaseId) {
      releaseControl();
    }
    if (screenPending) screenPending.controller.abort();
    screenGeneration += 1;
    setAck("");
    screenLines = [];
    lastText = "";
    renderedScreen = "";
    followTail = true;
    termHost.textContent = "正在读取终端…";
    termHost.setAttribute("aria-busy", "true");
    termHost.scrollTop = 0;
    selected = id;
    preserveLayout = layoutPreferences.get(id) || false;
    updateLayoutToggle();
    const item = latestSessions.find(function (session) { return session.id === id; });
    screenTitle.textContent = item ? groupName(text(item.cwd)) : "终端";
    screenName.textContent = item ? text(item.title) : "";
    revision = "0";
    lastScreenSignature = null;
    home.hidden = true;
    screen.hidden = false;
    window.scrollTo(0, 0);
    lastSessions = 0;
    refreshNow();
  }

  function closeScreen() {
    releaseControl();
    selected = "";
    if (screenPending) screenPending.controller.abort();
    screenGeneration += 1;
    revision = "0";
    screen.hidden = true;
    home.hidden = false;
    lastSessions = 0;
    markActive();
  }

  function pullScreen() {
    if (!selected || screen.hidden) return Promise.resolve();
    if (screenPending && screenPending.generation === screenGeneration) return screenPending.promise;
    const session = selected;
    const generation = screenGeneration;
    const activity = activityVersion;
    const request = { generation: generation, promise: null, controller: new AbortController() };
    screenPending = request;
    function isCurrent() { return session === selected && generation === screenGeneration && !screen.hidden; }
    request.promise = apiFetch("/api/screen?session=" + encodeURIComponent(session) + "&revision=" + encodeURIComponent(revision), {
      credentials: "same-origin"
    }, request.controller).then(function (response) {
      if (!isCurrent()) return null;
      if (response.status === 401) {
        authorized = false;
        setHint("授权已失效。");
        selected = "";
        dropControl();
        return null;
      }
      return JSON.parse(response.body);
    }).then(function (data) {
      if (!isCurrent()) return;
      if (!data || data.error) {
        if (data && data.error) {
          termHost.textContent = "无法读取该终端";
          termHost.setAttribute("aria-busy", "false");
          renderedScreen = "";
        }
        return;
      }
      failStreak = 0;
      revision = text(data.revision || revision);
      if (data.type === "unchanged") {
        observeScreen(false, activity);
        return;
      }
      const signature = JSON.stringify([data.cols, data.rows, data.alternate, data.lines]);
      observeScreen(signature !== lastScreenSignature, activity);
      lastScreenSignature = signature;
      draw(data);
    }).catch(function () {
      if (!isCurrent()) return;
      failStreak += 1;
      dropControl();
      setHint("连接中断，主机状态未知。");
    }).finally(function () { if (screenPending === request) screenPending = null; });
    return request.promise;
  }

  function requestControl() {
    if (!selected) return;
    const session = selected;
    apiFetch("/api/control", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId: session })
    }).then(function (response) { return JSON.parse(response.body); }).then(function (data) {
      if (session !== selected || document.hidden) {
        if (data && data.leaseId) {
          leaseId = data.leaseId;
          releaseControl();
        }
        return;
      }
      if (data && data.leaseId) {
        leaseId = data.leaseId;
        lastHeartbeat = Date.now();
        setMode("控制中");
        setAck("已获得控制权，不会自动重发未确认输入。");
      } else if (data && data.error === "busy") {
        setAck("上一笔输入尚未完成。");
      } else {
        leaseId = "";
        setMode("只读");
        setAck("未能取得控制权。");
      }
    }).catch(function () {
      setAck("连接中断，主机状态未知。");
    });
  }

  function releaseControl() {
    if (!leaseId) {
      setMode("只读");
      return;
    }
    apiFetch("/api/control", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ release: true })
    }).catch(function () {});
    leaseId = "";
    setMode("只读");
    setAck("已交还控制。");
  }

  function dropControl() {
    if (leaseId) releaseControl();
    else setMode("只读");
  }

  function heartbeat() {
    if (!leaseId) return Promise.resolve();
    const lease = leaseId;
    lastHeartbeat = Date.now();
    return apiFetch("/api/control", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ heartbeat: true, leaseId: lease })
    }).then(function (response) { return JSON.parse(response.body); }).then(function (data) {
      if (lease !== leaseId) return;
      if (!data || data.ok !== true) {
        leaseId = "";
        setMode("只读");
        setAck("控制已失效，请重新请求。");
      }
    }).catch(function () {
      if (lease === leaseId) dropControl();
    });
  }

  function postInput(payload) {
    if (inputPending) {
      setAck("上一笔输入尚未完成。");
      return;
    }
    if (!leaseId || !selected) {
      setAck("当前只读，请先请求控制。");
      return;
    }
    const requestId = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now()) + "-" + Math.random();
    lastRequestId = requestId;
    inputPending = true;
    payload.requestId = requestId;
    payload.leaseId = leaseId;
    payload.sessionId = selected;
    markActive();
    clearTimeout(poll);
    poll = 0;
    const submittedRevision = draftRevision;
    const submittedGeneration = screenGeneration;
    apiFetch("/api/input", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    }).then(function (response) { return JSON.parse(response.body); }).then(function (data) {
      const status = text(data && data.status);
      if (status === "written") {
        setAck("已写入 " + text(data.bytes) + " 字节。");
        if ((payload.kind === "text" || payload.kind === "paste") &&
            payload.sessionId === selected && submittedGeneration === screenGeneration &&
            submittedRevision === draftRevision && draft.value === payload.text && !composing) {
          draft.value = "";
        }
      } else if (status === "partial") setAck("部分写入 " + text(data.bytes) + " 字节，未补发。");
      else if (status === "unknown") setAck("结果未知，请核查终端。不会自动重发。");
      else {
        setAck("已拒绝：" + text(data && data.reason));
        if (data && data.reason === "no-control") {
          leaseId = "";
          setMode("只读");
        }
      }
    }).catch(function () {
      dropControl();
      setAck("结果未知，请核查终端。不会自动重发。");
    }).finally(function () {
      inputPending = false;
      if (payload.sessionId === selected && submittedGeneration === screenGeneration) refreshNow();
      else if (authorized && !document.hidden) schedulePoll(pollDelays[pollLevel]);
    });
  }

  function submit(enter) {
    if (composing) return;
    const value = draft.value;
    if (/[\u0000-\u0008\u0009\u000b\u000c\u000e-\u001f\u007f]/.test(value) && value.indexOf("\n") < 0 && value.indexOf("\r") < 0) {
      setAck("含控制字符，已拒绝。");
      return;
    }
    if (value.indexOf("\n") >= 0 || value.indexOf("\r") >= 0) {
      if (!pasteArmed) {
        confirmPaste.hidden = false;
        setAck("多行需要确认粘贴。");
        return;
      }
      postInput({ kind: "paste", text: value, enter: enter });
      pasteArmed = false;
      confirmPaste.hidden = true;
    } else {
      postInput({ kind: "text", text: value, enter: enter });
    }
  }

  document.getElementById("copy").addEventListener("click", function () {
    if (!lastText || !navigator.clipboard) return;
    navigator.clipboard.writeText(lastText).catch(function () {});
  });
  document.getElementById("request").addEventListener("click", requestControl);
  document.getElementById("release").addEventListener("click", releaseControl);
  document.getElementById("back").addEventListener("click", closeScreen);
  document.getElementById("sendEnter").addEventListener("click", function () { submit(true); });
  confirmPaste.addEventListener("click", function () {
    pasteArmed = true;
    confirmPaste.hidden = true;
    setAck("已确认粘贴，再次发送即可。");
  });
  draft.addEventListener("compositionstart", function () { composing = true; });
  draft.addEventListener("compositionend", function () { composing = false; });
  draft.addEventListener("input", function () { draftRevision += 1; });
  document.getElementById("keys").addEventListener("click", function (event) {
    if (composing) return;
    const button = event.target.closest("button[data-key]");
    if (!button) return;
    postInput({
      kind: "key",
      key: button.getAttribute("data-key"),
      modifiers: Number(button.getAttribute("data-mod") || "0"),
      enter: false
    });
  });
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) {
      clearTimeout(poll);
      poll = 0;
      refreshPending = false;
      if (leaseId) releaseControl();
    } else {
      // Resume read-only after returning from the background.
      revision = "0";
      lastSessions = 0;
      refreshNow();
    }
  });
  window.addEventListener("pagehide", function () {
    if (!leaseId) return;
    try {
      navigator.sendBeacon("/api/control", new Blob([JSON.stringify({ release: true })], { type: "application/json" }));
    } catch (error) {}
    leaseId = "";
  });

  let polling = false;

  function schedulePoll(delay) {
    clearTimeout(poll);
    poll = 0;
    if (document.hidden || polling) return;
    poll = setTimeout(tick, delay);
  }

  async function tick() {
    if (polling || document.hidden || inputPending) return;
    polling = true;
    poll = 0;
    try {
      if (!inputPending) {
        if (leaseId && Date.now() - lastHeartbeat >= 30000) await heartbeat();
        const idle = Date.now() - lastActivity >= 30000;
        if (Date.now() - lastSessions >= (idle ? 10000 : 2000)) await loadSessions();
        if (authorized && !inputPending && !document.hidden) {
          // Requests that arrived before this read are covered by it. New ones
          // arriving while it is in flight are coalesced into one follow-up.
          refreshPending = false;
          await pullScreen();
        }
      }
    } finally {
      polling = false;
      const delay = failStreak ? Math.min(10000, 1000 * Math.pow(2, Math.min(failStreak, 4)))
        : refreshPending ? 0 : pollDelays[pollLevel];
      if ((authorized || failStreak) && !inputPending) schedulePoll(delay);
    }
  }

  function redeem() {
    apiFetch("/pair", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ challenge: challenge })
    }).then(function (response) {
      return JSON.parse(response.body);
    }).then(function (data) {
      showPair(data.status, data.confirmCode);
      if (data.status === "ready") {
        authorized = true;
        schedulePoll(0);
      } else if (data.status === "pending") {
        setTimeout(redeem, 1500);
      } else {
        setHint("配对失败，请在 Mac 重新开启远程。");
      }
    }).catch(function () {
      setHint("连不上主机。");
    });
  }

  if (challenge) {
    redeem();
  } else {
    // HttpOnly cookie is sent by the browser; no challenge is needed to resume.
    loadSessions().then(function () {
      if (authorized || failStreak) schedulePoll(0);
    });
  }
})();
