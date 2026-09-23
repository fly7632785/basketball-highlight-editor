// Remember an explicit language choice while keeping both language URLs shareable.
(function () {
  const languageKey = "bhe-language";
  document.querySelectorAll("[data-language]").forEach((link) => {
    link.addEventListener("click", () => {
      localStorage.setItem(languageKey, link.dataset.language);
    });
  });

  const video = document.getElementById("bhe-demo-video");
  const dialog = document.getElementById("star-prompt");
  const promptKey = "bhe-star-prompt-shown";
  if (!video || !dialog || localStorage.getItem(promptKey) === "1") return;

  const close = () => dialog.close();
  dialog.querySelector(".star-prompt-close").addEventListener("click", close);
  dialog.querySelector("[data-star-later]").addEventListener("click", close);
  dialog.querySelector("[data-star-share]").addEventListener("click", async () => {
    const chinese = document.documentElement.lang.startsWith("zh");
    const shareData = {
      title: "Basketball Highlight Editor",
      text: chinese
        ? "我在用 BHE 整理篮球比赛集锦，推荐你看看："
        : "I use BHE to put together basketball highlights. Take a look:",
      url: "https://github.com/fly7632785/basketball-highlight-editor",
    };
    if (navigator.share) {
      await navigator.share(shareData).catch(() => {});
    } else {
      await navigator.clipboard.writeText(shareData.url);
    }
    close();
  });
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) close();
  });
  video.addEventListener("ended", () => {
    if (dialog.open || localStorage.getItem(promptKey) === "1") return;
    localStorage.setItem(promptKey, "1");
    dialog.showModal();
  }, { once: true });
})();
