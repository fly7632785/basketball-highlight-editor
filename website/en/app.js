// BHE website: render download links and reveal sections as they enter the viewport.
const DOWNLOADS = {
  version: "Latest version",
  ossBase: "https://shengshengniannian.oss-cn-beijing.aliyuncs.com/shengshengniannian/basketball-highlight-editor/releases",
  ghBase: "https://github.com/fly7632785/basketball-highlight-editor/releases",
  files: {
    "mac-arm64": ["BHE-macos-arm64-latest.dmg"],
    "mac-x64": ["BHE-macos-x86_64-latest.dmg"],
    "win-x64": ["BHE-windows-x64-latest.zip"],
    "android-arm64": ["BHE-android-arm64-v8a-latest.apk"],
  },
  direct: {
    "android-arm64": "https://oss.shengshengniannian.com/shengshengniannian/app/android/bhe/latest.apk",
  },
};

function fileNameMeta(name) {
  if (name.endsWith(".dmg")) return { label: "Download .dmg", sub: "Installer" };
  if (name.endsWith(".apk")) return { label: "Download .apk", sub: "Android package" };
  return { label: "Download .zip", sub: "Unzip and run" };
}

function renderDownloads() {
  const versionEl = document.getElementById("dl-version");
  if (versionEl) versionEl.textContent = DOWNLOADS.version;

  document.querySelectorAll(".dl-actions[data-os]").forEach((box) => {
    const files = DOWNLOADS.files[box.dataset.os] || [];
    files.forEach((name) => {
      const meta = fileNameMeta(name);
      const a = document.createElement("a");
      a.className = "btn btn-ball";
      a.href = DOWNLOADS.direct[box.dataset.os] || `${DOWNLOADS.ossBase}/${name}`;
      a.download = name;
      a.textContent = meta.label;
      box.appendChild(a);
    });
    const gh = document.createElement("a");
    gh.className = "dl-link-gh";
    gh.href = DOWNLOADS.ghBase;
    gh.target = "_blank";
    gh.rel = "noopener";
    gh.textContent = "GitHub mirror";
    box.appendChild(gh);
  });
}

function setupReveal() {
  const els = Array.from(document.querySelectorAll(".reveal"));
  if (!els.length) return;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    els.forEach((el) => el.classList.add("in"));
    return;
  }
  const check = () => {
    const vh = window.innerHeight || document.documentElement.clientHeight || 800;
    const line = vh * 0.9;
    for (let i = els.length - 1; i >= 0; i--) {
      if (els[i].getBoundingClientRect().top < line) {
        els[i].classList.add("in");
        els.splice(i, 1);
      }
    }
  };
  window.addEventListener("scroll", check, { passive: true });
  window.addEventListener("resize", check, { passive: true });
  check();
}

renderDownloads();
setupReveal();
