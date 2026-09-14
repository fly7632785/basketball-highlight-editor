// Remember an explicit language choice while keeping both language URLs shareable.
(function () {
  const key = "bhe-language";
  document.querySelectorAll("[data-language]").forEach((link) => {
    link.addEventListener("click", () => {
      localStorage.setItem(key, link.dataset.language);
    });
  });
})();
