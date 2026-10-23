import { mountCompanion } from './assets/companions/companions.js?v=5';
import { mountNotchDemo } from './notch-demo.js?v=5';
import { mountUsageDemo } from './usage-demo.js?v=5';
import { mountMacDesktop } from './mac-desktop.js?v=5';

const copy = {
  en: {},
  ru: {
    notchHint: 'Наведите курсор на чёлку или нажмите.',
    navUsage: 'Лимиты и токены', usageKicker: 'ИСПОЛЬЗОВАНИЕ', usageTitle: 'Видно, куда <br>уходят токены.',
    usageCopy: 'Расход по задачам, сессиям и подагентам. <br>Лимиты аккаунта и время до их сброса.',
    usageFootnote: 'Доступная статистика зависит от подключённого агента.', stateIdle: 'На передышке', stateWorking: 'За работой', stateDone: 'Маленькая победа', skip: 'Перейти к содержимому', navFeatures: 'Всё в деталях', navPets: 'Наши питомцы',
    downloadShort: 'Скачать <span aria-hidden="true">↗</span>',
    eyebrow: 'Маленький дом для ваших ИИ-агентов',
    heroTitle: 'Большие идеи. <br><em>Маленькая компания.</em>',
    heroCopy: 'Агенты работают. Чёлка держит вас в курсе. <br>Живые задачи, важные детали и маленький друг рядом.',
    download: 'Скачать для Mac', meetLink: 'Знакомьтесь: ваши новые соседи <span aria-hidden="true">↓</span>',
    compatibility: 'macOS 14+ · Apple Silicon · Бесплатно',
    screenshotCaption: 'Снимок приложения',
    agentsTitle: 'Разные агенты. Одно привычное место.', agentsFootnote: 'И ваши собственные инструменты — через локальный API.',
    featuresKicker: 'МЕНЬШЕ ПРОВЕРОК. БОЛЬШЕ ДЕЛА.', featuresTitle: 'Оставайтесь в потоке. <br>Замечайте важное.',
    featuresCopy: 'Взгляд — и виден прогресс. Клик — и есть контекст. <br>si-notch собирает агентов рядом, оставляя рабочий стол вам.',
    tabSessions: '<span>01 /</span> <span>Всё под рукой</span>', tabSettings: '<span>02 /</span> <span>По-вашему</span>', tabCompanions: '<span>03 /</span> <span>В компании</span>',
    enlarge: 'Нажмите, чтобы рассмотреть <span aria-hidden="true">↗</span>',
    nativeTitle: 'Как дома, на Mac.', nativeCopy: 'SwiftUI и AppKit. Горячие клавиши, несколько дисплеев и своё место в строке меню.',
    connectTitle: 'Рядом и на расстоянии.', connectCopy: 'Локальные агенты и подключения по SSH — вместе. Подключите привычные инструменты.',
    historyTitle: 'Чуть больше контекста.', historyCopy: 'Локальная история и доступная статистика использования. Сохраняйте полезное в пределах своих лимитов.',
    petsKicker: 'СЕРЬЁЗНЫЕ ДЕЛА. КРОШЕЧНЫЕ ДРУЗЬЯ.', petsTitle: 'Кое-кто за вас болеет.',
    petsCopy: 'Четыре характера, собранные из пикселей. <br>Наведите курсор, чтобы поздороваться. Нажмите, чтобы погладить.',
    robotCopy: 'Ваш карманный напарник.', catCopy: 'Проверяет качество. Чаще спит.', sproutCopy: 'Растёт вместе с вашими идеями.', ghostCopy: 'Любит тихие ночные посиделки.',
    petsFootnote: 'Четыре спутника si-notch. Их настроение меняется вместе с задачами.',
    downloadKicker: 'МАЛЕНЬКОЕ ПРИЛОЖЕНИЕ. ПРИЯТНЕЕ ДЕНЬ.', downloadTitle: 'У вашей чёлки <br>хорошая компания.',
    downloadCopy: 'Скачайте. Перенесите в Applications. Подключите агентов. <br>Найдите немного места для si-notch.',
    downloadMeta: 'Всегда актуальный стабильный релиз на GitHub. <br>macOS 14+ · Apple Silicon',
    installSummary: 'Небольшая заметка об установке',
    installNote: 'Текущая сборка имеет локальную подпись и пока не нотарифицирована Apple. macOS может попросить разрешить запуск в разделе «Конфиденциальность и безопасность». Скачивайте приложение только из официальных GitHub Releases. Работа на Intel не проверена.',
    readInstall: 'Подробнее об установке ↗', footerCare: 'С заботой от',
    openSource: 'Открытый код на GitHub', source: 'GitHub', setup: 'Подключение агентов', license: 'Лицензия'
  }
};
document.querySelectorAll('[data-i18n]').forEach(el => { copy.en[el.dataset.i18n] = el.innerHTML; });

const features = {
  sessions: {
    image: 'sessions', number: '01',
    en: { title: 'The big picture, <br>at a small scale.', text: 'See what is working, waiting, or done. Open a task for messages, tool activity, and subagents — without losing your place.', tags: ['Live sessions', 'Agent availability'], alt: 'si-notch showing three tasks from Codex, Claude Code, and Hermes' },
    ru: { title: 'Вся картина. <br>В одном окне.', text: 'Видно, что в работе, ждёт внимания или уже готово. Откройте задачу, чтобы увидеть сообщения, инструменты и подагентов.', tags: ['Живые задачи', 'Статус агентов'], alt: 'Три задачи Codex, Claude Code и Hermes в si-notch' }
  },
  settings: {
    image: 'settings-general', number: '02',
    en: { title: 'Your Mac. <br>Your kind of quiet.', text: 'Find a setting in a few keystrokes. Choose how the notch appears, what deserves your attention, and how much stays on screen.', tags: ['Searchable settings', 'Native macOS controls'], alt: 'The redesigned si-notch General settings with search and native controls' },
    ru: { title: 'Ваш Mac. <br>Ваш ритм.', text: 'Пара нажатий — и нужная настройка найдена. Выбирайте, как чёлка появляется, что заслуживает внимания и сколько деталей показывать.', tags: ['Поиск настроек', 'Нативный интерфейс'], alt: 'Обновлённые основные настройки si-notch с поиском и нативными элементами управления' }
  },
  companions: {
    image: 'settings-companions', number: '03',
    en: { title: 'A small personality. <br>A familiar presence.', text: 'Pick Robot, Cat, Sprout, or Ghost. Your companion follows the mood of your tasks — working, waiting, celebrating. Give it a click to say hello.', tags: ['Four companions', 'A greeting on click'], alt: 'si-notch companion settings with Robot, Cat, Sprout, and Ghost' },
    ru: { title: 'Свой характер. <br>Всегда рядом.', text: 'Выберите робота, кота, росток или призрака. Питомец работает, ждёт и радуется вместе с задачами. Нажмите на него, чтобы поздороваться.', tags: ['Четыре питомца', 'Приветствие по клику'], alt: 'Выбор питомцев si-notch: робот, кот, росток и призрак' }
  }
};

let language = 'en';
try { language = localStorage.getItem('si-notch-language') || (navigator.language.startsWith('ru') ? 'ru' : 'en'); } catch { /* Storage is optional. */ }
if (!copy[language]) language = 'en';
let selectedFeature = 'sessions';
const featureImage = document.querySelector('#feature-shot');
const dialog = document.querySelector('#image-dialog');
const petNames = { en: ['Robot', 'Cat', 'Sprout', 'Ghost'], ru: ['Робот', 'Кот', 'Росток', 'Призрак'] };
const petBubbles = { en: ['beep, friend.', 'prrr…', 'you’ve got this.', 'boo. but kindly.'], ru: ['бип, дружище.', 'мур-р-р…', 'у тебя получится.', 'бу. по-доброму.'] };
const coarsePointer = matchMedia('(hover: none)');
const notchDemo = mountNotchDemo(document.querySelector('#notch-demo'), {
  language,
  onSettings() {
    showFeature('settings');
    document.querySelector('#tab-settings').focus({preventScroll: true});
    document.querySelector('#features').scrollIntoView({behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth', block: 'start'});
  }
});
const usageDemo = mountUsageDemo(document.querySelector('#usage-demo'), {language});
const macDesktop = mountMacDesktop(document.querySelector('.desktop-scene'), {language});
const petButtons = [...document.querySelectorAll('.pet')];
const pets = petButtons.map((button, index) => {
  button.addEventListener('click', () => {
    button.classList.add('is-greeting');
    clearTimeout(button.greetingTimer);
    button.greetingTimer = setTimeout(() => button.classList.remove('is-greeting'), 900);
    document.querySelector('#pet-announcement').textContent = language === 'ru' ? `${petNames.ru[index]} радуется вам.` : `${petNames.en[index]} says hello.`;
  });
  return mountCompanion(button.querySelector('canvas'), {
    button, style: button.dataset.pet, status: 'working',
    onError: () => { button.querySelector('.pet-personality').textContent = language === 'ru' ? 'Не удалось загрузить питомца.' : 'The companion could not load.'; }
  });
});

document.querySelectorAll('[data-pet-state]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-pet-state]').forEach(other => other.setAttribute('aria-pressed', String(other === button)));
    pets.forEach(pet => pet.setStatus(button.dataset.petState));
  });
});

function showFeature(key) {
  selectedFeature = key;
  const feature = features[key];
  const translated = feature[language];
  document.querySelectorAll('[data-feature]').forEach(button => {
    const selected = button.dataset.feature === key;
    button.setAttribute('aria-selected', String(selected));
    button.tabIndex = selected ? 0 : -1;
  });
  document.querySelector('#feature-panel').setAttribute('aria-labelledby', `tab-${key}`);
  document.querySelector('#feature-number').textContent = feature.number;
  document.querySelector('#feature-title').replaceChildren(...translated.title.split('<br>').map(line => {
    const span = document.createElement('span'); span.className = 'heading-line'; span.textContent = line.trim(); return span;
  }));
  document.querySelector('#feature-copy').textContent = translated.text;
  document.querySelector('#feature-tags').replaceChildren(...translated.tags.map(text => {
    const span = document.createElement('span'); span.textContent = text; return span;
  }));
  featureImage.src = `assets/showcase-${feature.image}-${language}.png`;
  featureImage.alt = translated.alt;
  featureImage.width = key === 'sessions' ? 680 : 920;
  featureImage.height = key === 'sessions' ? 470 : 748;
}
document.querySelectorAll('[data-feature]').forEach(button => {
  button.addEventListener('click', () => showFeature(button.dataset.feature));
  button.addEventListener('keydown', event => {
    const keys = Object.keys(features);
    let index = keys.indexOf(selectedFeature);
    if (event.key === 'ArrowRight') index = (index + 1) % keys.length;
    else if (event.key === 'ArrowLeft') index = (index + keys.length - 1) % keys.length;
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = keys.length - 1;
    else return;
    event.preventDefault(); showFeature(keys[index]); document.querySelector(`#tab-${keys[index]}`).focus();
  });
});

function setLanguage(value) {
  language = value;
  document.documentElement.lang = value;
  document.querySelectorAll('[data-i18n]').forEach(el => { el.innerHTML = copy[value][el.dataset.i18n] ?? copy.en[el.dataset.i18n]; });
  const toggle = document.querySelector('#language');
  toggle.textContent = value === 'ru' ? 'EN' : 'RU';
  toggle.setAttribute('aria-label', value === 'ru' ? 'Switch to English' : 'Переключить на русский');
  notchDemo.setLanguage(value);
  usageDemo.setLanguage(value);
  macDesktop.setLanguage(value);
  if (coarsePointer.matches) document.querySelector('[data-i18n="notchHint"]').textContent = value === 'ru' ? 'Нажмите на чёлку. Она откроется.' : 'Give the notch a tap. There’s more inside.';
  document.querySelector('#expand-screenshot').setAttribute('aria-label', value === 'ru' ? 'Увеличить снимок приложения' : 'Enlarge app screenshot');
  document.querySelector('.dialog-close').setAttribute('aria-label', value === 'ru' ? 'Закрыть снимок' : 'Close screenshot');
  document.querySelector('nav').setAttribute('aria-label', value === 'ru' ? 'Основная навигация' : 'Main navigation');
  document.querySelector('.feature-tabs').setAttribute('aria-label', value === 'ru' ? 'Возможности si-notch' : 'Explore si-notch');
  document.querySelector('.pet-state-picker').setAttribute('aria-label', value === 'ru' ? 'Настроение питомцев' : 'Companion mood');
  dialog.setAttribute('aria-label', value === 'ru' ? 'Увеличенный снимок приложения' : 'Enlarged app screenshot');
  document.querySelector('.site-header .wordmark').setAttribute('aria-label', value === 'ru' ? 'si-notch — главная' : 'si-notch home');
  document.querySelector('nav a[href="https://disroot.website/"]').setAttribute('aria-label', value === 'ru' ? 'Сайт разработчика dis/root' : 'Developer dis/root website');
  petButtons.forEach((button, index) => {
    button.querySelector('.pet-name').firstChild.textContent = petNames[value][index];
    button.querySelector('.pet-bubble').textContent = petBubbles[value][index];
    button.setAttribute('aria-label', value === 'ru' ? `Погладить: ${petNames[value][index]}` : `Say hello to ${petNames[value][index]}`);
  });
  document.title = value === 'ru' ? 'si-notch — Большие идеи. Маленькая компания.' : 'si-notch — A little company for your big ideas';
  showFeature(selectedFeature);
  try { localStorage.setItem('si-notch-language', value); } catch { /* Keep working without storage. */ }
}
document.querySelector('#language').addEventListener('click', () => setLanguage(language === 'en' ? 'ru' : 'en'));
document.querySelector('#expand-screenshot').addEventListener('click', () => {
  const image = document.querySelector('#dialog-image'); image.src = featureImage.src; image.alt = featureImage.alt;
  dialog.showModal();
});
document.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', event => { if (event.target === dialog && (event.clientX < dialog.getBoundingClientRect().left || event.clientX > dialog.getBoundingClientRect().right || event.clientY < dialog.getBoundingClientRect().top || event.clientY > dialog.getBoundingClientRect().bottom)) dialog.close(); });
document.addEventListener('visibilitychange', () => { if (document.hidden) petButtons.forEach(button => { clearTimeout(button.greetingTimer); button.classList.remove('is-greeting'); }); });
setLanguage(language);
