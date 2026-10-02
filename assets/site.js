if (window.hljs) document.querySelectorAll('pre code').forEach(el => hljs.highlightElement(el));
const dlg = document.getElementById('zoom');
if (dlg) {
  document.querySelectorAll('.shot').forEach(b => b.addEventListener('click', () => { dlg.querySelector('img').src = b.dataset.src; dlg.showModal(); }));
  dlg.addEventListener('click', () => dlg.close());
}