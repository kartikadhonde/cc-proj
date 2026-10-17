const API_BASE_URL = (window.API_BASE_URL || "http://localhost:8000").replace(/\/$/, "");
const POLL_INTERVAL_MS = 5000;
const RESOLUTIONS = ["720p", "480p"];

const $ = (id) => document.getElementById(id);
const form = $("upload-form");
const uploadBtn = $("upload-btn");
const progress = $("progress");
const uploadStatus = $("upload-status");
const grid = $("grid");
const empty = $("empty");
const listError = $("list-error");
const modal = $("player-modal");
const player = $("player");
const playerTitle = $("player-title");
const resSwitch = $("res-switch");

async function api(path, options = {}) {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  if (!response.ok) {
    throw new Error(`${options.method || "GET"} ${path} failed: HTTP ${response.status}`);
  }
  return response.json();
}

// XMLHttpRequest instead of fetch so we can report upload progress.
function putToS3(url, file, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", url);
    xhr.setRequestHeader("Content-Type", "video/mp4");
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) onProgress(Math.round((e.loaded / e.total) * 100));
    };
    xhr.onload = () =>
      xhr.status >= 200 && xhr.status < 300
        ? resolve()
        : reject(new Error(`S3 upload failed: HTTP ${xhr.status}`));
    xhr.onerror = () => reject(new Error("S3 upload failed: network or CORS error"));
    xhr.send(file);
  });
}

function setStatus(text, isError = false) {
  uploadStatus.textContent = text;
  uploadStatus.classList.toggle("error", isError);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const title = $("title").value.trim();
  const file = $("file").files[0];
  if (!title || !file) return;
  if (file.type && file.type !== "video/mp4") {
    setStatus("Please choose an .mp4 file.", true);
    return;
  }

  uploadBtn.disabled = true;
  progress.hidden = false;
  progress.value = 0;
  try {
    setStatus("Step 1/3: Registering video…");
    const { video_id, upload_url } = await api("/videos", {
      method: "POST",
      body: JSON.stringify({ title }),
    });

    setStatus("Step 2/3: Uploading to S3…");
    await putToS3(upload_url, file, (pct) => {
      progress.value = pct;
      setStatus(`Step 2/3: Uploading to S3… ${pct}%`);
    });

    setStatus(`Step 3/3: Uploaded. Transcoding has been queued (id ${video_id.slice(0, 8)}).`);
    form.reset();
    refresh();
  } catch (err) {
    setStatus(err.message, true);
  } finally {
    uploadBtn.disabled = false;
    setTimeout(() => (progress.hidden = true), 1500);
  }
});

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value);
  }
  for (const child of children) node.append(child);
  return node;
}

function videoCard(video) {
  const thumb = el("div", { class: "thumb" });
  if (video.thumbnail_url) {
    thumb.append(el("img", { src: video.thumbnail_url, alt: "", loading: "lazy" }));
  } else {
    thumb.textContent = video.status === "failed" ? "Processing failed" : "Thumbnail pending";
  }

  const body = el("div", { class: "video-body" }, [
    el("p", { class: "video-title", text: video.title }),
    el("div", { class: "video-meta" }, [
      el("span", { class: `badge ${video.status}`, text: video.status }),
      el("span", { class: "muted", text: new Date(video.created_at).toLocaleString() }),
    ]),
  ]);

  if (video.status === "ready") {
    const row = el("div", { class: "play-row" });
    for (const res of RESOLUTIONS) {
      if (video.playback_urls[res]) {
        row.append(el("button", { text: `Play ${res}`, onclick: () => openPlayer(video, res) }));
      }
    }
    body.append(row);
  }
  if (video.status === "failed" && video.error) {
    body.append(el("p", { class: "err-msg", text: video.error }));
  }
  return el("article", { class: "video-card" }, [thumb, body]);
}

function openPlayer(video, res) {
  playerTitle.textContent = video.title;
  resSwitch.replaceChildren(
    ...RESOLUTIONS.filter((r) => video.playback_urls[r]).map((r) =>
      el("button", {
        text: r,
        class: r === res ? "active" : "",
        onclick: () => openPlayer(video, r),
      })
    )
  );
  // Keep the playback position when switching resolution.
  const resumeAt = modal.open ? player.currentTime : 0;
  player.src = video.playback_urls[res];
  player.addEventListener("loadedmetadata", () => (player.currentTime = resumeAt), { once: true });
  player.play().catch(() => {});
  if (!modal.open) modal.showModal();
}

$("close-modal").addEventListener("click", () => modal.close());
modal.addEventListener("close", () => {
  player.pause();
  player.removeAttribute("src");
  player.load();
});

let lastRender = "";
async function refresh() {
  try {
    const videos = await api("/videos");
    listError.hidden = true;
    const snapshot = JSON.stringify(videos);
    if (snapshot === lastRender) return; // avoid flicker when nothing changed
    lastRender = snapshot;
    grid.replaceChildren(...videos.map(videoCard));
    empty.hidden = videos.length > 0;
  } catch (err) {
    listError.textContent = `Could not load videos: ${err.message}`;
    listError.hidden = false;
  }
}

refresh();
setInterval(refresh, POLL_INTERVAL_MS);
