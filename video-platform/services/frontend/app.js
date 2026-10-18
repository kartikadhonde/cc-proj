/**
 * StreamForge — Modern YouTube-Inspired Video Streaming Application
 * Complete Viewing & Uploading Engine
 */

const API_BASE_URL = (window.API_BASE_URL || "http://localhost:8000").replace(/\/$/, "");
const POLL_INTERVAL_MS = 5000;
const RESOLUTIONS = ["720p", "480p"];

// DOM References
const $ = (id) => document.getElementById(id);

// Navigation & Views
const homeView = $("home-view");
const watchView = $("watch-view");
const videoGrid = $("video-grid");
const emptyState = $("empty-state");
const listError = $("list-error");
const syncText = $("sync-text");
const searchInput = $("search-input");
const clearSearchBtn = $("clear-search-btn");
const brandLogo = $("brand-logo");

// Watch View Elements
const watchPlayer = $("watch-player");
const watchTitle = $("watch-title");
const playerResBadge = $("player-res-badge");
const qualityPills = $("quality-pills");
const channelAvatar = $("channel-avatar");
const channelName = $("channel-name");
const subscribeBtn = $("subscribe-btn");
const likeBtn = $("like-btn");
const likeCounter = $("like-counter");
const dislikeBtn = $("dislike-btn");
const shareBtn = $("share-btn");
const downloadBtn = $("download-btn");
const descViews = $("desc-views");
const descDate = $("desc-date");
const descStatusBadge = $("desc-status-badge");
const descText = $("desc-text");
const detailVideoId = $("detail-video-id");
const detailResolutions = $("detail-resolutions");
const toggleDescBtn = $("toggle-desc-btn");
const descBody = $("desc-body");
const commentsCount = $("comments-count");
const commentInput = $("comment-input");
const commentSubmitBtn = $("comment-submit-btn");
const commentCancelBtn = $("comment-cancel-btn");
const commentsList = $("comments-list");
const sidebarQueue = $("sidebar-queue");
const backToBrowseBtn = $("back-to-browse-btn");

// Upload Modal Elements
const uploadModal = $("upload-modal");
const openUploadBtn = $("open-upload-btn");
const emptyUploadBtn = $("empty-upload-btn");
const closeModalBtn = $("close-modal-btn");
const cancelUploadBtn = $("cancel-upload-btn");
const uploadForm = $("upload-form");
const fileInput = $("file-input");
const browseBtn = $("browse-btn");
const dropzone = $("dropzone");
const titleInput = $("title-input");
const fileChosenInfo = $("file-chosen-info");
const chosenFilename = $("chosen-filename");
const chosenFilesize = $("chosen-filesize");
const uploadProgressWrap = $("upload-progress-wrap");
const progressBarFill = $("progress-bar-fill");
const progressPercent = $("progress-percent");
const progressStepText = $("progress-step-text");
const uploadStatus = $("upload-status");
const submitUploadBtn = $("submit-upload-btn");
const toastContainer = $("toast-container");

// Application State
let allVideos = [];
let activeVideo = null;
let currentResolution = "720p";
let currentFilter = "all";
let searchQuery = "";
let isSubscribed = false;
let userLiked = false;
let userDisliked = false;
let descExpanded = false;

// Avatar Gradient Generator
const GRADIENTS = [
  "linear-gradient(135deg, #ef4444, #9333ea)",
  "linear-gradient(135deg, #3b82f6, #06b6d4)",
  "linear-gradient(135deg, #10b981, #3b82f6)",
  "linear-gradient(135deg, #f59e0b, #ef4444)",
  "linear-gradient(135deg, #ec4899, #8b5cf6)",
  "linear-gradient(135deg, #6366f1, #d946ef)",
];

function getAvatarStyle(str) {
  let hash = 0;
  for (let i = 0; i < (str || "").length; i++) {
    hash = str.charCodeAt(i) + ((hash << 5) - hash);
  }
  const index = Math.abs(hash) % GRADIENTS.length;
  return GRADIENTS[index];
}

function getInitials(str) {
  if (!str) return "SF";
  const parts = str.trim().split(/\s+/);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return str.slice(0, 2).toUpperCase();
}

function formatRelativeTime(dateString) {
  if (!dateString) return "Recently";
  const date = new Date(dateString);
  if (isNaN(date.getTime())) return "Recently";
  const now = new Date();
  const diffSec = Math.floor((now - date) / 1000);

  if (diffSec < 60) return "Just now";
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)} minutes ago`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)} hours ago`;
  if (diffSec < 2592000) return `${Math.floor(diffSec / 86400)} days ago`;
  return date.toLocaleDateString();
}

function formatViewCount(id) {
  // Deterministic mock views count for authentic YouTube feel
  let hash = 0;
  for (let i = 0; i < (id || "").length; i++) hash += id.charCodeAt(i);
  const views = (Math.abs(hash * 37) % 8900) + 120;
  if (views >= 1000) return `${(views / 1000).toFixed(1)}K views`;
  return `${views} views`;
}

// Toast System
function showToast(message, type = "info") {
  const toast = document.createElement("div");
  toast.className = `toast ${type === "success" ? "toast-success" : ""}`;
  toast.innerHTML = `
    <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor">
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/>
    </svg>
    <span>${message}</span>
  `;
  toastContainer.appendChild(toast);
  setTimeout(() => {
    toast.style.opacity = "0";
    toast.style.transform = "translateY(10px)";
    setTimeout(() => toast.remove(), 300);
  }, 3200);
}

// API Helper
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

// Presigned S3 Upload via XMLHttpRequest
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

// ==========================================================================
// Video Rendering (Home View Grid)
// ==========================================================================

function createVideoCard(video) {
  const card = document.createElement("article");
  card.className = "yt-card";
  card.setAttribute("data-id", video.video_id);

  // Thumbnail
  const thumbWrap = document.createElement("div");
  thumbWrap.className = "yt-card-thumb-wrap";

  if (video.thumbnail_url) {
    const img = document.createElement("img");
    img.src = video.thumbnail_url;
    img.alt = video.title;
    img.loading = "lazy";
    img.onerror = () => {
      img.replaceWith(renderPlaceholder(video));
    };
    thumbWrap.appendChild(img);
  } else {
    thumbWrap.appendChild(renderPlaceholder(video));
  }

  // Badges on Thumbnail
  const statusBadge = document.createElement("div");
  statusBadge.className = "thumb-badge-top-left";
  statusBadge.innerHTML = `<span class="badge ${video.status}">${video.status === 'processing' ? 'Transcoding' : video.status}</span>`;
  thumbWrap.appendChild(statusBadge);

  const resTag = document.createElement("div");
  resTag.className = "thumb-badge-bottom-right";
  const has720 = video.playback_urls && video.playback_urls["720p"];
  resTag.innerHTML = `<span class="res-tag">${has720 ? "720p HD" : "480p"}</span>`;
  thumbWrap.appendChild(resTag);

  // Hover Overlay with Play Button
  const hoverOverlay = document.createElement("div");
  hoverOverlay.className = "card-hover-overlay";
  hoverOverlay.innerHTML = `
    <div class="play-circle-btn">
      <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor">
        <path d="M8 5v14l11-7z"/>
      </svg>
    </div>
  `;
  thumbWrap.appendChild(hoverOverlay);

  // Card Info (Below thumbnail)
  const infoRow = document.createElement("div");
  infoRow.className = "yt-card-info";

  const authorAvatar = document.createElement("div");
  authorAvatar.className = "author-avatar";
  authorAvatar.style.background = getAvatarStyle(video.title);
  authorAvatar.textContent = getInitials(video.title);

  const metaText = document.createElement("div");
  metaText.className = "card-meta-text";

  const titleEl = document.createElement("h3");
  titleEl.className = "card-video-title";
  titleEl.textContent = video.title;

  const channelRow = document.createElement("div");
  channelRow.className = "card-channel-name";
  channelRow.innerHTML = `
    <span>StreamForge Studio</span>
    <svg viewBox="0 0 24 24" width="13" height="13" fill="#38bdf8" title="Verified">
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/>
    </svg>
  `;

  const statsRow = document.createElement("div");
  statsRow.className = "card-stats-row";
  statsRow.innerHTML = `
    <span>${formatViewCount(video.video_id)}</span>
    <span class="card-dot-sep">•</span>
    <span>${formatRelativeTime(video.created_at)}</span>
  `;

  metaText.appendChild(titleEl);
  metaText.appendChild(channelRow);
  metaText.appendChild(statsRow);

  infoRow.appendChild(authorAvatar);
  infoRow.appendChild(metaText);

  card.appendChild(thumbWrap);
  card.appendChild(infoRow);

  card.addEventListener("click", () => {
    openWatchView(video);
  });

  return card;
}

function renderPlaceholder(video) {
  const wrap = document.createElement("div");
  wrap.className = "thumb-placeholder";
  wrap.innerHTML = `
    <svg viewBox="0 0 24 24" width="36" height="36" fill="currentColor">
      <path d="M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"/>
    </svg>
    <span class="thumb-placeholder-text">${video.status === 'processing' ? 'Generating Thumbnail...' : 'No Thumbnail'}</span>
  `;
  return wrap;
}

function renderGrid() {
  const filtered = allVideos.filter((v) => {
    // Search query filter
    if (searchQuery && !v.title.toLowerCase().includes(searchQuery.toLowerCase())) {
      return false;
    }
    // Category pill filter
    if (currentFilter === "ready") return v.status === "ready";
    if (currentFilter === "processing") return v.status === "processing" || v.status === "uploaded";
    return true;
  });

  if (currentFilter === "recent") {
    filtered.sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
  }

  videoGrid.replaceChildren(...filtered.map(createVideoCard));
  emptyState.hidden = filtered.length > 0;
}

// ==========================================================================
// Watch View (YouTube Cinema Mode)
// ==========================================================================

function openWatchView(video, preferredRes = null) {
  activeVideo = video;
  window.location.hash = `v=${video.video_id}`;

  // Switch UI view
  homeView.hidden = true;
  watchView.hidden = false;
  window.scrollTo({ top: 0, behavior: "smooth" });

  // Update Watch Metadata
  watchTitle.textContent = video.title;
  channelAvatar.style.background = getAvatarStyle(video.title);
  channelAvatar.textContent = getInitials(video.title);
  descViews.textContent = formatViewCount(video.video_id);
  descDate.textContent = formatRelativeTime(video.created_at);

  descStatusBadge.className = `badge ${video.status}`;
  descStatusBadge.textContent = video.status.toUpperCase();

  detailVideoId.textContent = video.video_id;
  const availRes = RESOLUTIONS.filter((r) => video.playback_urls && video.playback_urls[r]);
  detailResolutions.textContent = availRes.length ? availRes.join(", ") : "Pending transcode";

  // Reset interactive controls
  userLiked = false;
  userDisliked = false;
  likeBtn.classList.remove("active");
  dislikeBtn.classList.remove("active");
  likeCounter.textContent = "142";

  // Render Quality Selector Pills
  qualityPills.innerHTML = "";
  if (video.playback_urls && Object.keys(video.playback_urls).length > 0) {
    const defaultRes = preferredRes || (video.playback_urls["720p"] ? "720p" : Object.keys(video.playback_urls)[0]);
    currentResolution = defaultRes;

    RESOLUTIONS.forEach((res) => {
      if (video.playback_urls[res]) {
        const btn = document.createElement("button");
        btn.className = `quality-btn ${res === currentResolution ? "active" : ""}`;
        btn.textContent = res === "720p" ? "720p HD" : "480p SD";
        btn.addEventListener("click", () => switchResolution(res));
        qualityPills.appendChild(btn);
      }
    });

    loadVideoSource(video.playback_urls[currentResolution]);
  } else {
    // If video is still transcoding or uploaded
    const notice = document.createElement("span");
    notice.className = "muted font-sm";
    notice.textContent = video.status === "processing" ? "Transcoding in progress..." : "Queued for processing";
    qualityPills.appendChild(notice);
    watchPlayer.removeAttribute("src");
    playerResBadge.textContent = video.status.toUpperCase();
    showToast(`Video is currently ${video.status}. It will automatically be ready shortly.`);
  }

  // Setup Download link
  if (video.playback_urls && video.playback_urls[currentResolution]) {
    downloadBtn.href = video.playback_urls[currentResolution];
    downloadBtn.style.display = "inline-flex";
  } else {
    downloadBtn.style.display = "none";
  }

  // Render Sidebar "Up Next" Queue
  renderSidebarQueue(video.video_id);

  // Render Comments
  renderComments(video.video_id);
}

function loadVideoSource(url) {
  if (!url) return;
  const currentTime = watchPlayer.currentTime || 0;
  const isPlaying = !watchPlayer.paused && !watchPlayer.ended;

  playerResBadge.textContent = currentResolution === "720p" ? "720p HD" : "480p SD";
  watchPlayer.src = url;

  watchPlayer.addEventListener(
    "loadedmetadata",
    () => {
      if (currentTime > 0) watchPlayer.currentTime = currentTime;
      if (isPlaying) watchPlayer.play().catch(() => {});
    },
    { once: true }
  );

  watchPlayer.play().catch(() => {});
}

function switchResolution(res) {
  if (!activeVideo || !activeVideo.playback_urls || !activeVideo.playback_urls[res]) return;
  currentResolution = res;

  // Update pills
  Array.from(qualityPills.children).forEach((btn) => {
    btn.classList.toggle("active", btn.textContent.includes(res));
  });

  loadVideoSource(activeVideo.playback_urls[res]);
  downloadBtn.href = activeVideo.playback_urls[res];
  showToast(`Switched quality to ${res}`);
}

function closeWatchView() {
  watchPlayer.pause();
  watchPlayer.removeAttribute("src");
  watchPlayer.load();

  activeVideo = null;
  history.pushState("", document.title, window.location.pathname + window.location.search);
  watchView.hidden = true;
  homeView.hidden = false;
}

// Sidebar "Up Next" Queue
function renderSidebarQueue(currentId) {
  const queue = allVideos.filter((v) => v.video_id !== currentId);
  sidebarQueue.innerHTML = "";

  if (queue.length === 0) {
    sidebarQueue.innerHTML = `<p class="muted font-sm">No other videos in your library yet.</p>`;
    return;
  }

  queue.forEach((video) => {
    const card = document.createElement("div");
    card.className = "sidebar-card";

    const thumbWrap = document.createElement("div");
    thumbWrap.className = "sidebar-thumb-wrap";

    if (video.thumbnail_url) {
      const img = document.createElement("img");
      img.src = video.thumbnail_url;
      img.alt = video.title;
      thumbWrap.appendChild(img);
    } else {
      thumbWrap.appendChild(renderPlaceholder(video));
    }

    const meta = document.createElement("div");
    meta.className = "sidebar-meta";

    const title = document.createElement("div");
    title.className = "sidebar-title";
    title.textContent = video.title;

    const channel = document.createElement("div");
    channel.className = "sidebar-channel";
    channel.textContent = "StreamForge Studio";

    const statusRow = document.createElement("div");
    statusRow.className = "sidebar-status-row";
    statusRow.innerHTML = `
      <span class="badge ${video.status}" style="font-size: 0.65rem; padding: 2px 6px;">${video.status}</span>
      <span class="muted font-sm">${formatRelativeTime(video.created_at)}</span>
    `;

    meta.appendChild(title);
    meta.appendChild(channel);
    meta.appendChild(statusRow);

    card.appendChild(thumbWrap);
    card.appendChild(meta);

    card.addEventListener("click", () => {
      openWatchView(video);
    });

    sidebarQueue.appendChild(card);
  });
}

// ==========================================================================
// Interactive Comments
// ==========================================================================

const DEFAULT_COMMENTS = [
  { author: "Alex Rivers", text: "The transcoding speed with FFmpeg and Fargate is lightning fast! Clean 720p output.", time: "1 hour ago", likes: 18 },
  { author: "DevOps Engineer", text: "Direct S3 presigned upload with SQS event notification is such an elegant architecture.", time: "3 hours ago", likes: 9 },
  { author: "Sarah Jenkins", text: "Great player UI! Love the resolution switcher and smooth playback.", time: "5 hours ago", likes: 4 }
];

function getStoredComments(videoId) {
  try {
    const key = `sf_comments_${videoId}`;
    const stored = localStorage.getItem(key);
    return stored ? JSON.parse(stored) : DEFAULT_COMMENTS;
  } catch {
    return DEFAULT_COMMENTS;
  }
}

function saveComments(videoId, comments) {
  try {
    localStorage.setItem(`sf_comments_${videoId}`, JSON.stringify(comments));
  } catch {}
}

function renderComments(videoId) {
  const comments = getStoredComments(videoId);
  commentsCount.textContent = comments.length;
  commentsList.innerHTML = "";

  comments.forEach((c, idx) => {
    const item = document.createElement("div");
    item.className = "comment-item";

    const avatar = document.createElement("div");
    avatar.className = "comment-avatar";
    avatar.style.background = getAvatarStyle(c.author);
    avatar.textContent = getInitials(c.author);

    const body = document.createElement("div");
    body.className = "comment-body";

    const authorRow = document.createElement("div");
    authorRow.className = "comment-author-row";
    authorRow.innerHTML = `
      <span class="comment-author">${c.author}</span>
      <span class="comment-time">${c.time}</span>
    `;

    const text = document.createElement("p");
    text.className = "comment-text";
    text.textContent = c.text;

    const footer = document.createElement("div");
    footer.className = "comment-footer";
    footer.innerHTML = `
      <button class="comment-like-btn">
        <svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor">
          <path d="M1 21h4V9H1v12zm22-11c0-1.1-.9-2-2-2h-6.31l.95-4.57.03-.32c0-.41-.17-.79-.44-1.06L14.17 1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73v-2z"/>
        </svg>
        <span>${c.likes}</span>
      </button>
      <button class="btn-text font-sm" style="padding: 2px 8px;">Reply</button>
    `;

    body.appendChild(authorRow);
    body.appendChild(text);
    body.appendChild(footer);

    item.appendChild(avatar);
    item.appendChild(body);

    commentsList.appendChild(item);
  });
}

// Add New Comment
commentInput.addEventListener("input", () => {
  commentSubmitBtn.disabled = !commentInput.value.trim();
});

commentCancelBtn.addEventListener("click", () => {
  commentInput.value = "";
  commentSubmitBtn.disabled = true;
});

commentSubmitBtn.addEventListener("click", () => {
  const text = commentInput.value.trim();
  if (!text || !activeVideo) return;

  const comments = getStoredComments(activeVideo.video_id);
  comments.unshift({
    author: "You (Developer)",
    text,
    time: "Just now",
    likes: 0
  });

  saveComments(activeVideo.video_id, comments);
  renderComments(activeVideo.video_id);

  commentInput.value = "";
  commentSubmitBtn.disabled = true;
  showToast("Comment added!");
});

// ==========================================================================
// Interactive Actions (Subscribe, Like, Share, Description)
// ==========================================================================

subscribeBtn.addEventListener("click", () => {
  isSubscribed = !isSubscribed;
  if (isSubscribed) {
    subscribeBtn.classList.add("subscribed");
    subscribeBtn.textContent = "Subscribed ✓";
    showToast("Subscribed to StreamForge Studio!");
  } else {
    subscribeBtn.classList.remove("subscribed");
    subscribeBtn.textContent = "Subscribe";
  }
});

likeBtn.addEventListener("click", () => {
  userLiked = !userLiked;
  if (userLiked) {
    likeBtn.classList.add("active");
    likeCounter.textContent = "143";
    if (userDisliked) {
      userDisliked = false;
      dislikeBtn.classList.remove("active");
    }
  } else {
    likeBtn.classList.remove("active");
    likeCounter.textContent = "142";
  }
});

dislikeBtn.addEventListener("click", () => {
  userDisliked = !userDisliked;
  dislikeBtn.classList.toggle("active", userDisliked);
  if (userDisliked && userLiked) {
    userLiked = false;
    likeBtn.classList.remove("active");
    likeCounter.textContent = "142";
  }
});

shareBtn.addEventListener("click", async () => {
  if (!activeVideo) return;
  const shareUrl = `${window.location.origin}${window.location.pathname}#v=${activeVideo.video_id}`;
  try {
    await navigator.clipboard.writeText(shareUrl);
    showToast("Link copied to clipboard!", "success");
  } catch {
    // Fallback prompt
    prompt("Copy video link:", shareUrl);
  }
});

toggleDescBtn.addEventListener("click", () => {
  descExpanded = !descExpanded;
  if (descExpanded) {
    descBody.style.maxHeight = "none";
    toggleDescBtn.textContent = "Show less";
  } else {
    toggleDescBtn.textContent = "Show more";
  }
});

backToBrowseBtn.addEventListener("click", closeWatchView);
brandLogo.addEventListener("click", (e) => {
  e.preventDefault();
  closeWatchView();
});

// ==========================================================================
// Upload Engine (100% Retained & Enhanced)
// ==========================================================================

function openUploadModal() {
  uploadForm.reset();
  fileChosenInfo.hidden = true;
  uploadProgressWrap.hidden = true;
  uploadStatus.textContent = "";
  uploadStatus.className = "status-msg";
  submitUploadBtn.disabled = false;
  uploadModal.showModal();
}

function closeUploadModal() {
  uploadModal.close();
}

openUploadBtn.addEventListener("click", openUploadModal);
if (emptyUploadBtn) emptyUploadBtn.addEventListener("click", openUploadModal);
closeModalBtn.addEventListener("click", closeUploadModal);
cancelUploadBtn.addEventListener("click", closeUploadModal);

// Drag and drop setup
["dragenter", "dragover"].forEach((evt) => {
  dropzone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropzone.classList.add("dragover");
  });
});

["dragleave", "drop"].forEach((evt) => {
  dropzone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropzone.classList.remove("dragover");
  });
});

dropzone.addEventListener("drop", (e) => {
  const files = e.dataTransfer.files;
  if (files && files.length > 0) {
    fileInput.files = files;
    handleFileSelected(files[0]);
  }
});

browseBtn.addEventListener("click", () => fileInput.click());
fileInput.addEventListener("change", () => {
  if (fileInput.files.length > 0) handleFileSelected(fileInput.files[0]);
});

function handleFileSelected(file) {
  if (file.type && file.type !== "video/mp4" && !file.name.endsWith(".mp4")) {
    setUploadStatus("Please choose an .mp4 file.", true);
    fileChosenInfo.hidden = true;
    return;
  }

  chosenFilename.textContent = file.name;
  chosenFilesize.textContent = `${(file.size / (1024 * 1024)).toFixed(1)} MB`;
  fileChosenInfo.hidden = false;

  // Auto-fill title if empty
  if (!titleInput.value.trim()) {
    const rawName = file.name.replace(/\.[^/.]+$/, "").replace(/[-_]/g, " ");
    titleInput.value = rawName.charAt(0).toUpperCase() + rawName.slice(1);
  }
}

function setUploadStatus(text, isError = false) {
  uploadStatus.textContent = text;
  uploadStatus.classList.toggle("error", isError);
}

uploadForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const title = titleInput.value.trim();
  const file = fileInput.files[0];
  if (!title || !file) return;

  submitUploadBtn.disabled = true;
  uploadProgressWrap.hidden = false;
  progressBarFill.style.width = "0%";
  progressPercent.textContent = "0%";
  progressStepText.textContent = "Step 1/3: Registering video metadata...";

  try {
    setUploadStatus("Registering video with API...");
    const { video_id, upload_url } = await api("/videos", {
      method: "POST",
      body: JSON.stringify({ title }),
    });

    progressStepText.textContent = "Step 2/3: Uploading directly to S3...";
    setUploadStatus("Uploading file to S3...");

    await putToS3(upload_url, file, (pct) => {
      progressBarFill.style.width = `${pct}%`;
      progressPercent.textContent = `${pct}%`;
      progressStepText.textContent = `Step 2/3: Uploading to S3... ${pct}%`;
    });

    progressBarFill.style.width = "100%";
    progressPercent.textContent = "100%";
    progressStepText.textContent = "Step 3/3: Transcoding queued via AWS SQS!";
    setUploadStatus("Video uploaded! Transcoder has started.", false);

    showToast(`"${title}" uploaded! Processing started.`, "success");

    setTimeout(() => {
      closeUploadModal();
      refresh();
    }, 1200);
  } catch (err) {
    setUploadStatus(err.message, true);
    submitUploadBtn.disabled = false;
  }
});

// ==========================================================================
// Filter Chips & Search
// ==========================================================================

document.querySelectorAll(".chip").forEach((chip) => {
  chip.addEventListener("click", () => {
    document.querySelectorAll(".chip").forEach((c) => c.classList.remove("active"));
    chip.classList.add("active");
    currentFilter = chip.getAttribute("data-filter");
    renderGrid();
  });
});

searchInput.addEventListener("input", (e) => {
  searchQuery = e.target.value.trim();
  clearSearchBtn.hidden = !searchQuery;
  renderGrid();
});

clearSearchBtn.addEventListener("click", () => {
  searchInput.value = "";
  searchQuery = "";
  clearSearchBtn.hidden = true;
  renderGrid();
});

// ==========================================================================
// Data Polling & Deep Link Handling
// ==========================================================================

let lastVideosJson = "";

async function refresh() {
  try {
    const videos = await api("/videos");
    listError.hidden = true;
    allVideos = videos;

    const snapshot = JSON.stringify(videos);
    if (snapshot !== lastVideosJson) {
      lastVideosJson = snapshot;
      renderGrid();

      // If user is currently in watch view, keep active video updated
      if (activeVideo) {
        const updatedActive = allVideos.find((v) => v.video_id === activeVideo.video_id);
        if (updatedActive) {
          // If status upgraded from processing to ready, refresh player controls
          if (activeVideo.status !== updatedActive.status && updatedActive.status === "ready") {
            openWatchView(updatedActive, currentResolution);
            showToast("Video processing finished! Now ready to stream in HD.", "success");
          } else {
            activeVideo = updatedActive;
            renderSidebarQueue(activeVideo.video_id);
          }
        }
      }
    }
  } catch (err) {
    listError.textContent = `Could not reach video service: ${err.message}`;
    listError.hidden = false;
  }
}

// Hash-based routing for direct watch links: #v={id}
function handleHashRoute() {
  const hash = window.location.hash;
  if (hash.startsWith("#v=")) {
    const videoId = hash.replace("#v=", "");
    const video = allVideos.find((v) => v.video_id === videoId);
    if (video) {
      openWatchView(video);
    }
  } else if (!hash && !watchView.hidden) {
    closeWatchView();
  }
}

window.addEventListener("hashchange", handleHashRoute);

// Initialization
async function init() {
  await refresh();
  handleHashRoute();
  setInterval(refresh, POLL_INTERVAL_MS);
}

init();
