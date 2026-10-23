/* si-notch companion artwork and browser renderer. See LICENSE.
 * Artwork: the app's real 40×40 sprites, exported by export_companions.py.
 */
import atlas from './companions-data.js';

export const COMPANION_STYLES = Object.freeze(['robot', 'cat', 'sprout', 'ghost']);
export const COMPANION_STATES = Object.freeze(['idle', 'working', 'waiting', 'approval', 'completed', 'failed', 'ended']);

let imagePromise;
function loadImage() {
  if (!imagePromise) imagePromise = new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error('Companion artwork could not be loaded.'));
    image.src = new URL('./companions.png', import.meta.url).href;
  });
  return imagePromise;
}

/**
 * Mount real app artwork into a canvas. The host owns its accessible <button>,
 * labels, layout, and status controls.
 *
 * const pet = mountCompanion(canvas, { button, style: 'cat', status: 'working' });
 * pet.destroy();             // call on unmount/navigation
 */
export function mountCompanion(canvas, options = {}) {
  if (!(canvas instanceof HTMLCanvasElement)) throw new TypeError('Expected a canvas.');
  const context = canvas.getContext('2d', { alpha: true });
  if (!context) throw new Error('Canvas rendering is unavailable.');
  const button = options.button;
  if (button && !(button instanceof HTMLElement)) throw new TypeError('Expected an HTML button element.');
  let style = COMPANION_STYLES.includes(options.style) ? options.style : 'robot';
  let status = COMPANION_STATES.includes(options.status) ? options.status : 'idle';
  let image, timer, destroyed = false, inView = true;
  let greetingStarted = -Infinity;
  let stateStarted = performance.now() / 1000;
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  canvas.width = canvas.height = atlas.cell;
  canvas.style.imageRendering = 'pixelated';
  canvas.setAttribute('aria-hidden', 'true');
  const active = () => inView && document.visibilityState !== 'hidden' && !destroyed;

  function render() {
    clearTimeout(timer);
    if (!image || destroyed) return;
    const time = performance.now() / 1000;
    const greeting = time - greetingStarted < .8;
    const celebrating = status === 'completed' && time - stateStarted < .7;
    const moving = status === 'working' || greeting || celebrating;
    const phase = reduceMotion.matches ? 0 : Math.floor((time % (2 / 3)) * 6) % 4;
    let variant;
    if (reduceMotion.matches) variant = greeting ? 'staticGreeting' : 'static';
    else if (greeting || celebrating) variant = 'greeting';
    else variant = time % 5.6 > 5.43 ? 'blink' : 'normal';
    const index = atlas.frames[`${style}.${status}.${variant}.${phase}`];
    const x = index % atlas.columns * atlas.cell;
    const y = Math.floor(index / atlas.columns) * atlas.cell;
    context.imageSmoothingEnabled = false;
    context.clearRect(0, 0, atlas.cell, atlas.cell);
    context.globalAlpha = status === 'ended' ? .62 : 1;
    context.drawImage(image, x, y, atlas.cell, atlas.cell, 0, 0, atlas.cell, atlas.cell);
    if (!active()) return;
    let next = Infinity;
    if (!reduceMotion.matches) {
      if (moving) next = (Math.floor(time * 6) + 1) / 6 + .001;
      if (status !== 'completed' && status !== 'ended') {
        const cycle = Math.floor(time / 5.6) * 5.6;
        next = Math.min(next, time < cycle + 5.431 ? cycle + 5.431 : cycle + 5.601);
      }
    }
    // Reduced motion keeps the friendly expression, with no movement or sparkles.
    if (greeting) next = Math.min(next, greetingStarted + .801);
    if (celebrating && !reduceMotion.matches) next = Math.min(next, stateStarted + .701);
    if (Number.isFinite(next)) timer = setTimeout(render, Math.max(1, (next - time) * 1000));
  }

  function greet() {
    if (destroyed) return;
    greetingStarted = performance.now() / 1000;
    render();
  }
  function visibility() {
    clearTimeout(timer);
    if (active()) render();
  }
  button?.addEventListener('pointerenter', greet);
  button?.addEventListener('focus', greet);
  button?.addEventListener('click', greet);
  document.addEventListener('visibilitychange', visibility);
  reduceMotion.addEventListener('change', render);
  const observer = typeof IntersectionObserver === 'undefined' ? null : new IntersectionObserver(entries => {
    inView = entries.some(entry => entry.isIntersecting);
    visibility();
  });
  observer?.observe(canvas);
  const ready = loadImage().then(value => {
    if (!destroyed) { image = value; render(); }
    return true;
  }, error => { options.onError?.(error); return false; });

  return {
    ready,
    greet,
    setStyle(value) {
      if (!COMPANION_STYLES.includes(value)) throw new RangeError('Unknown companion style.');
      style = value; render();
    },
    setStatus(value) {
      if (!COMPANION_STATES.includes(value)) throw new RangeError('Unknown companion state.');
      if (value !== status) { status = value; stateStarted = performance.now() / 1000; render(); }
    },
    destroy() {
      destroyed = true;
      clearTimeout(timer);
      observer?.disconnect();
      button?.removeEventListener('pointerenter', greet);
      button?.removeEventListener('focus', greet);
      button?.removeEventListener('click', greet);
      document.removeEventListener('visibilitychange', visibility);
      reduceMotion.removeEventListener('change', render);
    },
  };
}
