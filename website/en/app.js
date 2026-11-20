function setupReveal() {
  const elements = Array.from(document.querySelectorAll('.reveal'));
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    elements.forEach((element) => element.classList.add('in'));
    return;
  }
  const check = () => {
    const line = (window.innerHeight || document.documentElement.clientHeight || 800) * 0.9;
    for (let index = elements.length - 1; index >= 0; index--) {
      if (elements[index].getBoundingClientRect().top < line) {
        elements[index].classList.add('in');
        elements.splice(index, 1);
      }
    }
  };
  window.addEventListener('scroll', check, { passive: true });
  window.addEventListener('resize', check, { passive: true });
  check();
}
setupReveal();
