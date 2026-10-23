// Decorative desktop framing, informed by Apple's Mac User Guide:
// https://support.apple.com/guide/mac-help/desktop-menu-bar-and-dock-mchlws12345m2/27/mac/27
// Dock image: user-supplied reference, extracted to transparency with ImageGen.
// The menu and Dock are scenery: no launch actions, focus targets, sounds, or timers.
const COPY = {
  en: { finder: 'Finder', file: 'File', edit: 'Edit', view: 'View', go: 'Go', window: 'Window', help: 'Help', date: 'Fri 23 Oct', time: '9:41' },
  ru: { finder: 'Finder', file: 'Файл', edit: 'Правка', view: 'Вид', go: 'Переход', window: 'Окно', help: 'Справка', date: 'Пт, 23 окт.', time: '9:41' },
};
const apple = `<svg class="md-apple" viewBox="0 0 18 21" fill="currentColor"><path d="M11.2 3.4c.8-1 1.1-2.1 1-3.1-1.1.1-2.3.7-3 1.5-.7.8-1.1 1.9-1 3 1.2 0 2.3-.5 3-1.4ZM15.3 10.5c0-2 1.6-3 1.7-3.1-1-1.4-2.4-1.6-3-1.7-1.3-.1-2.6.8-3.2.8-.7 0-1.7-.8-2.8-.8C5.2 5.7 3 8 3 11c0 1.8.6 3.6 1.5 4.9.7 1.1 1.5 2.4 2.7 2.3 1.1 0 1.5-.7 2.9-.7 1.3 0 1.7.7 2.9.7 1.2 0 2-1.1 2.7-2.2.7-1 1-2 1.1-2.2-.1 0-1.5-.6-1.5-3.3Z"/></svg>`;
const wifi = `<svg class="md-wifi" viewBox="0 0 20 16" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round"><path d="M1.5 4a13.5 13.5 0 0 1 17 0M4.3 7.3a9 9 0 0 1 11.4 0M7.2 10.5a4.5 4.5 0 0 1 5.6 0"/><circle cx="10" cy="13.5" r="1" fill="currentColor" stroke="none"/></svg>`;
const battery = `<svg class="md-battery" viewBox="0 0 25 13" fill="none" stroke="currentColor" stroke-width="1.1"><rect x=".8" y="1" width="20.4" height="11" rx="2.3"/><path d="M23 4v5" stroke-linecap="round"/><rect x="3" y="3.2" width="15.9" height="6.6" rx=".8" fill="currentColor" stroke="none"/></svg>`;
const controls = `<svg class="md-controls" viewBox="0 0 20 18" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="2" y="2" width="16" height="5.5" rx="2.75"/><circle cx="6" cy="4.75" r="1.45" fill="currentColor" stroke="none"/><rect x="2" y="10.5" width="16" height="5.5" rx="2.75" fill="currentColor"/><circle cx="14" cy="13.25" r="1.45" fill="#ddd8e5" stroke="none"/></svg>`;

export function mountMacDesktop(scene, options = {}) {
  if (!(scene instanceof HTMLElement)) throw new TypeError('A desktop scene element is required.');
  let language = options.language === 'ru' ? 'ru' : 'en';
  let destroyed = false;
  const chrome = document.createElement('div');
  chrome.className = 'md-desktop-chrome';
  chrome.setAttribute('aria-hidden', 'true');
  chrome.inert = true;
  chrome.innerHTML = `<div class="md-menubar"><div class="md-menu-left">${apple}<strong data-label="finder" class="md-active-app"></strong>${['file', 'edit', 'view', 'go', 'window', 'help'].map(key => `<span class="md-menu-word md-menu-${key}" data-label="${key}"></span>`).join('')}</div><div class="md-menu-camera-gap"></div><div class="md-menu-right"><span class="md-status-wifi">${wifi}</span><span class="md-status-battery">${battery}</span><span class="md-status-controls">${controls}</span><span class="md-menu-date" data-label="date"></span><span class="md-menu-time" data-label="time"></span></div></div><div class="md-dock"><img src="${new URL('./assets/mac-dock-reference.png', import.meta.url).href}" width="1942" height="809" alt="" draggable="false" decoding="async"></div>`;
  scene.append(chrome);
  function render() {
    if (destroyed) return;
    chrome.querySelectorAll('[data-label]').forEach(element => { element.textContent = COPY[language][element.dataset.label]; });
  }
  render();
  return {
    setLanguage(value) { if (!destroyed) { language = value === 'ru' ? 'ru' : 'en'; render(); } },
    destroy() { if (!destroyed) { destroyed = true; chrome.remove(); } },
  };
}
