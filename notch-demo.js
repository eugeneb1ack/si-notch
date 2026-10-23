import { mountCompanion } from './assets/companions/companions.js?v=4';

// A local, deliberately fictional preview of IslandView / SessionCard / HistoryView.
// Provider colors match ProviderStyle.swift. This module never contacts an agent.
const COPY = {
  en: {
    open: 'Open si-notch, 4 sessions', region: 'si-notch panel',
    sessions: 'Sessions', agents: 'Agents', online: '5 online', count: '4 sessions',
    all: 'All', working: 'Working', attention: 'Attention', done: 'Done', history: 'History',
    search: 'Search sessions', searchHistory: 'Search history', settings: 'Settings',
    collapse: 'Collapse panel', usage: 'Usage',
    latest: 'Latest update', result: 'Last result', task: 'Task', activity: 'Activity',
    tokens: 'Task tokens', reply: 'Reply in agent', previewReply: 'Open the task in the app to reply.',
    empty: 'No matching sessions', historyEmpty: 'No matching conversations',
    waiting: 'Waiting for a reply', completed: 'Done', ended: 'Ended', idle: 'Ready',
    local: 'Local agents', remote: 'Studio Mac', remoteHint: 'SSH · 2 profiles',
    available: 'Online', manage: 'Connection guide ↗', back: 'Back to history',
    user: 'You', assistant: 'Agent', command: 'Command', records: '2 conversations · 4.2 KB',
    today: 'Today, 10:42', yesterday: 'Yesterday, 16:20', usageTitle: 'Usage overview',
    usageSubtitle: 'Token usage across your tasks.', input: 'Input tokens',
    output: 'Output tokens', total: 'Total tokens', usageNote: 'Available usage details depend on the connected agent.',
    details: 'Show task details', closeDetails: 'Hide task details', greeting: 'Say hello to Cat',
    now: 'now', minute: '1m ago', minutes: '3m ago', taskComplete: 'Completed', taskPending: 'In progress',
    remoteDescription: 'Remote availability is separate from task status.',
  },
  ru: {
    open: 'Открыть чёлку, 4 сессии', region: 'Панель si-notch',
    sessions: 'Сессии', agents: 'Агенты', online: '5 на связи', count: '4 сессии',
    all: 'Все', working: 'В работе', attention: 'Внимание', done: 'Готово', history: 'История',
    search: 'Поиск сессий', searchHistory: 'Поиск истории', settings: 'Настройки',
    collapse: 'Свернуть панель', usage: 'Использование',
    latest: 'Последнее обновление', result: 'Последний результат', task: 'Задача', activity: 'Активность',
    tokens: 'Токены задачи', reply: 'Ответить в агенте', previewReply: 'Откройте задачу в приложении, чтобы отправить ответ.',
    empty: 'Подходящих сессий нет', historyEmpty: 'Подходящих диалогов нет',
    waiting: 'Ждёт ответа', completed: 'Готово', ended: 'Завершена', idle: 'Готов',
    local: 'Локальные агенты', remote: 'Studio Mac', remoteHint: 'SSH · 2 профиля',
    available: 'На связи', manage: 'Инструкция по подключению ↗', back: 'Назад к истории',
    user: 'Вы', assistant: 'Агент', command: 'Команда', records: '2 диалога · 4,2 КБ',
    today: 'Сегодня, 10:42', yesterday: 'Вчера, 16:20', usageTitle: 'Обзор использования',
    usageSubtitle: 'Расход токенов по задачам.', input: 'Входящие токены',
    output: 'Исходящие токены', total: 'Всего токенов', usageNote: 'Доступная статистика зависит от подключённого агента.',
    details: 'Раскрыть подробности', closeDetails: 'Скрыть подробности', greeting: 'Поздороваться с котом',
    now: 'сейчас', minute: '1 мин', minutes: '3 мин', taskComplete: 'Готово', taskPending: 'В работе',
    remoteDescription: 'Доступность подключения и состояние задачи показаны отдельно.',
  },
};
Object.assign(COPY.en, {
  contextAll: 'All active tasks, in one place. Open a card for updates, steps, and tool activity.',
  contextWorking: 'These agents are still working. Their status and latest update stay visible at a glance.',
  contextAttention: 'A task needs your reply. The orange status keeps it distinct from background work.',
  contextDone: 'Completed tasks keep their last result here, ready to review.',
  contextHistory: 'History keeps selected conversation text locally. Open a record to read the messages.',
  contextAgents: 'See which agents are available. Expand the SSH connection to inspect its remote profiles.',
  contextUsage: 'Task tokens describe work already done. Account limits show how much allowance remains.',
  contextScopedUsage: 'Recorded usage for the selected task or conversation.', backToTask: 'Back to task', backToConversation: 'Back to conversation',
  contextSettings: 'Adjust the panel’s appearance and behavior.',
  settingsTitle: 'Settings', appearance: 'Appearance', showCompanion: 'Show companion',
  showCompanionHelp: 'Keep a little companion in the compact notch and panel header.',
  notifications: 'Attention', attentionReveal: 'Reveal when a task needs attention',
  attentionHelp: 'Choose whether an incoming question opens the panel for you.',
  tryAttention: 'Try an attention event', attentionEnabled: 'Attention reveal is on. The waiting task opens so you can review its question.',
  attentionDisabled: 'Attention reveal is off. A task is waiting, but your current view stays in place.',
  fullSettings: 'See the full app settings', backToTasks: 'Back to sessions',
  limits: 'Codex account limits', fiveHours: '5-hour window', week: 'Weekly window',
  remaining: 'remaining', resets: 'Resets in', hours: '2h 18m', days: '4d 2h',
  limitsHelp: 'The Mac app refreshes available account limits automatically.',
  refresh: 'Refresh', refreshNote: 'Updated. Refreshing checks the allowance; it does not reset a limit.',
  refreshed: 'Updated',
});
Object.assign(COPY.ru, {
  contextAll: 'Все активные задачи в одном месте. Раскройте карточку: внутри обновления, шаги и активность инструментов.',
  contextWorking: 'Эти агенты ещё работают. Статус и последнее обновление видны одним взглядом.',
  contextAttention: 'Задача ждёт вашего ответа. Оранжевый статус отличает её от фоновой работы.',
  contextDone: 'Завершённые задачи сохраняют последний результат — его можно открыть и прочитать.',
  contextHistory: 'История хранит выбранный текст диалогов локально. Откройте запись, чтобы прочитать сообщения.',
  contextAgents: 'Здесь видна доступность агентов. Раскройте SSH-подключение, чтобы увидеть удалённые профили.',
  contextUsage: 'Токены показывают объём выполненной работы. Лимиты аккаунта — сколько ресурса ещё осталось.',
  contextScopedUsage: 'Расход только выбранной задачи или диалога.', backToTask: 'Назад к задаче', backToConversation: 'Назад к диалогу',
  contextSettings: 'Настройте оформление и поведение панели.',
  settingsTitle: 'Настройки', appearance: 'Оформление', showCompanion: 'Показывать питомца',
  showCompanionHelp: 'Маленький друг в свёрнутой чёлке и заголовке панели.',
  notifications: 'Внимание', attentionReveal: 'Раскрывать, когда задача требует внимания',
  attentionHelp: 'Выберите, должна ли панель открываться при новом вопросе агента.',
  tryAttention: 'Попробовать событие внимания', attentionEnabled: 'Автораскрытие включено. Открылась задача, чтобы вы могли прочитать вопрос.',
  attentionDisabled: 'Автораскрытие выключено. Задача ждёт ответа, но текущий раздел остаётся на месте.',
  fullSettings: 'Посмотреть все настройки приложения', backToTasks: 'Назад к сессиям',
  limits: 'Лимиты аккаунта Codex', fiveHours: 'Окно 5 часов', week: 'Недельное окно',
  remaining: 'осталось', resets: 'Сброс через', hours: '2 ч 18 мин', days: '4 д 2 ч',
  limitsHelp: 'Приложение на Mac обновляет доступные лимиты аккаунта автоматически.',
  refresh: 'Обновить', refreshNote: 'Обновлено. Обновление проверяет остаток, но не сбрасывает лимит.',
  refreshed: 'Обновлено',
});
const PROVIDERS = {
  codex: { name: 'Codex', color: '#70D8C2', icon: 'code' },
  claude: { name: 'Claude Code', color: '#F29B78', icon: 'spark' },
  hermes: { name: 'Hermes', color: '#BB9AF7', icon: 'plane' },
  pi: { name: 'Pi', color: '#E8B95B', icon: 'pi' },
  opencode: { name: 'OpenCode', color: '#75C7F2', icon: 'terminal' },
};
const TASKS = [
  { id: 'settings', provider: 'codex', status: 'working', project: 'si-notch', age: 'now', tool: 'SwiftUI', tokens: '18.4K',
    en: { title: 'Polish the settings window', summary: 'Refining the sidebar and native controls.', prompt: 'Make the settings easier to navigate and keep the Mac feeling.', message: 'The sidebar is in place. Checking search, keyboard focus, and compact window sizes.', checklist: ['Organize the sidebar', 'Check keyboard navigation', 'Review smaller windows'], events: ['Checked the settings layout', 'Updated the search results', 'Started the interface review'] },
    ru: { title: 'Обновить окно настроек', summary: 'Дорабатывает боковую панель и нативные элементы.', prompt: 'Сделай настройки понятнее и сохрани привычный стиль Mac.', message: 'Боковая панель готова. Проверяю поиск, навигацию с клавиатуры и небольшие размеры окна.', checklist: ['Упорядочить боковую панель', 'Проверить клавиатуру', 'Проверить маленькие окна'], events: ['Проверена компоновка настроек', 'Обновлён поиск настроек', 'Начата проверка интерфейса'] } },
  { id: 'release', provider: 'hermes', status: 'waiting', project: 'si-notch', age: 'minute', tool: '', tokens: '6.2K',
    en: { title: 'Prepare the release', summary: 'Which appearance should the screenshots use?', prompt: 'Prepare a concise preview of the new release.', message: 'The feature list is ready. Which appearance should the screenshots use: light, dark, or both?', checklist: ['Summarize the visible changes', 'Choose the screenshot appearance'], events: ['Waiting for your reply', 'Prepared the feature list'] },
    ru: { title: 'Подготовить релиз', summary: 'Какое оформление выбрать для скриншотов?', prompt: 'Подготовь короткое превью нового релиза.', message: 'Список изменений готов. Какое оформление использовать на скриншотах: светлое, тёмное или оба?', checklist: ['Собрать заметные изменения', 'Выбрать оформление скриншотов'], events: ['Ожидание вашего ответа', 'Подготовлен список изменений'] } },
  { id: 'shortcuts', provider: 'claude', status: 'completed', project: 'si-notch', age: 'minutes', tool: '', tokens: '9.8K',
    en: { title: 'Review keyboard shortcuts', summary: 'The keyboard flow is ready.', prompt: 'Review how the panel opens and closes from the keyboard.', message: 'Checked opening the panel, moving between tasks, and closing with Escape. The flow is consistent.', checklist: ['Review panel shortcuts', 'Check Escape and focus'], events: ['Review completed', 'Checked keyboard focus'] },
    ru: { title: 'Проверить горячие клавиши', summary: 'Навигация с клавиатуры готова.', prompt: 'Проверь открытие и закрытие панели с клавиатуры.', message: 'Проверены открытие панели, переходы между задачами и закрытие через Escape. Навигация последовательна.', checklist: ['Проверить сочетания клавиш', 'Проверить Escape и фокус'], events: ['Проверка завершена', 'Проверен фокус клавиатуры'] } },
  { id: 'website', provider: 'pi', status: 'working', project: 'website', age: 'now', tool: 'layout', tokens: '4.6K',
    en: { title: 'Check the website layout', summary: 'Checking the page on a smaller screen.', prompt: 'Review the page at desktop and mobile widths.', message: 'The companion section fits both sizes. Checking text wrapping and the download links next.', checklist: ['Review desktop layout', 'Review mobile layout', 'Check the download links'], events: ['Checked the companion section', 'Reviewed mobile spacing'] },
    ru: { title: 'Проверить компоновку сайта', summary: 'Проверяет страницу на небольшом экране.', prompt: 'Проверь страницу на компьютере и телефоне.', message: 'Раздел питомцев помещается на обоих экранах. Теперь проверяю переносы текста и ссылки для скачивания.', checklist: ['Проверить большой экран', 'Проверить телефон', 'Проверить ссылки скачивания'], events: ['Проверен раздел питомцев', 'Проверены мобильные отступы'] } },
];
const HISTORY = [
  { id: 'docs', provider: 'codex', status: 'completed', tokens: '7.1K', date: 'today',
    en: { title: 'Clarify the getting-started guide', messages: [['user', 'Make the first-run instructions shorter and easier to follow.'], ['command', 'Read the installation and connection guide.'], ['assistant', 'The guide now explains the three steps: install the app, open Connection settings, and connect an agent.']] },
    ru: { title: 'Упростить инструкцию запуска', messages: [['user', 'Сократи инструкцию первого запуска и сделай её понятнее.'], ['command', 'Прочитана инструкция установки и подключения.'], ['assistant', 'В инструкции теперь три шага: установить приложение, открыть настройки подключения и подключить агента.']] } },
  { id: 'notes', provider: 'claude', status: 'ended', tokens: '3.3K', date: 'yesterday',
    en: { title: 'Explore a quieter workspace', messages: [['user', 'Explore a quieter way to keep track of background tasks.'], ['assistant', 'Show progress at a glance, reserve expansion for context, and keep the user in control of notifications.']] },
    ru: { title: 'Обсудить спокойное рабочее место', messages: [['user', 'Подумай, как спокойнее следить за фоновыми задачами.'], ['assistant', 'Показывать прогресс одним взглядом, раскрывать детали по запросу и оставлять управление уведомлениями пользователю.']] } },
];
const PATHS = {
  up: 'm6 14 6-6 6 6', down: 'm6 10 6 6 6-6', right: 'm9 6 6 6-6 6', left: 'm15 6-6 6 6 6',
  list: 'M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01',
  chart: 'M5 20V10h3v10m3 0V4h3v16m3 0v-7h3v7',
  search: 'm20 20-5-5M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0',
  gear: 'm9 3-.6 2.1-2 .9-2-.5-1.5 2.6 1.4 1.6-.2 2.3L3 13.5l1.5 2.6 2.1-.4 1.8 1.4.6 2.1h3l.6-2.1 2-1 2 .5 1.5-2.6-1.4-1.6.2-2.3L19 8.5l-1.5-2.6-2.1.4-1.8-1.2L13 3H9Zm5 8a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  terminal: 'M3 5h18v14H3V5Zm4 4 3 3-3 3m6 0h4',
  code: 'm7 6-5 6 5 6m10-12 5 6-5 6m-3-14-4 16',
  spark: 'm12 2 2.5 7.5L22 12l-7.5 2.5L12 22l-2.5-7.5L2 12l7.5-2.5L12 2Z',
  plane: 'm2 11 20-9-7 20-4-8-9-3Zm9 3L22 2',
  pi: 'M5 9h14M8 9v10m8-10v10M12 3v2M3 12h2m14 0h2M12 19v2',
  check: 'm5 12 4 4L19 6', clock: 'M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0',
  folder: 'M3 7V5h7l2 3h9v12H3V7Z', question: 'M9 8a3 3 0 1 1 4 3c-1 .4-1 1-1 2m0 4h.01M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0',
  stop: 'M6 6h12v12H6V6Z', network: 'M8 3h8v6H8V3ZM3 16h6v5H3v-5Zm12 0h6v5h-6v-5ZM12 9v4m-6 3v-3h12v3',
};
const icon = name => `<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="${PATHS[name] || PATHS.terminal}"/></svg>`;
const escapeHTML = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
let instanceCount = 0;

export function mountNotchDemo(container, options = {}) {
  if (!(container instanceof HTMLElement)) throw new TypeError('A notch preview container is required.');
  const prefix = `snd-${++instanceCount}`;
  let language = options.language === 'ru' ? 'ru' : 'en';
  let expanded = false, tab = 'sessions', filter = 'all', selected = null, historySelected = null;
  let remoteExpanded = false, usageShown = false, settingsShown = false, destroyed = false;
  let quotaExpanded = true, quotaRefreshed = false, noticeKey = '';
  let usageSelection = null, usageReturn = null;
  const preferences = { companion: true, attention: true };
  let enterTimer, leaveTimer, inside = false, keyboardFocus = false, touchPinned = false, pointerType = 'mouse';
  const searches = { sessions: '', history: '' };
  const t = key => COPY[language][key] || key;
  container.classList.add('snd-mount');
  container.innerHTML = `<div class="snd-shell"><button type="button" class="snd-trigger" aria-expanded="false" aria-controls="${prefix}-panel"><canvas class="snd-compact-pet" width="40" height="40" aria-hidden="true"></canvas><span class="snd-camera" aria-hidden="true"></span><span class="snd-count" aria-hidden="true">4</span></button><section id="${prefix}-panel" class="snd-panel" hidden inert><header class="snd-header"><button type="button" class="snd-header-pet"><canvas width="40" height="40" aria-hidden="true"></canvas></button><span class="snd-header-label"></span><div class="snd-tools"><button type="button" data-command="usage" aria-pressed="false">${icon('chart')}</button><button type="button" data-command="settings">${icon('gear')}</button><button type="button" data-command="collapse">${icon('up')}</button></div></header><div class="snd-navigation" role="tablist"><button type="button" role="tab" data-tab="sessions" id="${prefix}-sessions" aria-controls="${prefix}-content">${icon('list')}<span></span></button><button type="button" role="tab" data-tab="agents" id="${prefix}-agents" aria-controls="${prefix}-content">${icon('terminal')}<span></span><small></small></button></div><div class="snd-search">${icon('search')}<input type="search" autocomplete="off" spellcheck="false"></div><div class="snd-filters" role="group">${['all', 'working', 'attention', 'done', 'history'].map(key => `<button type="button" data-filter="${key}" aria-pressed="false"></button>`).join('')}</div><div class="snd-body" id="${prefix}-content" role="tabpanel" tabindex="0"></div><footer class="snd-footer"><span class="snd-footer-extra"></span></footer><span class="snd-announcement" role="status" aria-live="polite"></span></section></div>`;
  const shell = container.querySelector('.snd-shell');
  const trigger = container.querySelector('.snd-trigger');
  const panel = container.querySelector('.snd-panel');
  const body = container.querySelector('.snd-body');
  const input = container.querySelector('input');
  const headerPet = container.querySelector('.snd-header-pet');
  const context = document.createElement('p'); context.className = 'snd-context';
  container.querySelector('.snd-navigation').after(context);
  const compactStatus = document.createElement('span'); compactStatus.className = 'snd-compact-status';
  compactStatus.setAttribute('aria-hidden', 'true'); compactStatus.innerHTML = icon('question'); compactStatus.hidden = true;
  trigger.querySelector('canvas').after(compactStatus);
  const companions = [mountCompanion(trigger.querySelector('canvas'), { style: 'cat', status: 'waiting' }),
    mountCompanion(headerPet.querySelector('canvas'), { button: headerPet, style: 'cat', status: 'waiting' })];

  function setExpanded(value, focus = false) {
    if (destroyed) return;
    clearTimeout(enterTimer); clearTimeout(leaveTimer);
    expanded = value;
    shell.classList.toggle('snd-is-open', value);
    trigger.setAttribute('aria-expanded', String(value));
    trigger.hidden = value;
    panel.hidden = !value;
    panel.inert = !value;
    if (value && focus) container.querySelector(`[data-tab="${tab}"]`).focus({ preventScroll: true });
    if (!value) {
      touchPinned = false;
      if (focus || panel.contains(document.activeElement)) trigger.focus({ preventScroll: true });
    }
  }
  function announce(message) { container.querySelector('.snd-announcement').textContent = message; }
  function provider(providerID) {
    const value = PROVIDERS[providerID];
    return `<span class="snd-provider" style="--snd-provider:${value.color}">${icon(value.icon)}${value.name}</span>`;
  }
  function statusIcon(status) { return icon(status === 'completed' ? 'check' : status === 'waiting' ? 'question' : status === 'ended' ? 'stop' : 'terminal'); }
  function taskCard(task) {
    const data = task[language], active = selected === task.id, style = PROVIDERS[task.provider];
    const detailID = `${prefix}-detail-${task.id}`;
    const completeCount = task.status === 'completed' ? data.checklist.length : 1;
    return `<article class="snd-card ${active ? 'snd-card-selected' : ''}" style="--snd-provider:${style.color}"><button type="button" class="snd-card-toggle" data-action="task" data-id="${task.id}" data-key="task-${task.id}" aria-expanded="${active}" aria-controls="${detailID}"><span class="snd-status-dot snd-${task.status}" aria-hidden="true"></span><span class="snd-card-heading"><strong>${escapeHTML(data.title)}</strong><span class="snd-card-meta">${provider(task.provider)}<span class="snd-project">· ${icon('folder')}${task.project}</span><time>${t(task.age)}</time></span></span><span class="snd-chevron">${icon(active ? 'up' : 'down')}</span></button><div class="snd-task-status"><span class="snd-${task.status}">${statusIcon(task.status)}${t(task.status)}</span>${task.tool ? `<span class="snd-tool">· ${escapeHTML(task.tool)}</span>` : ''}<span class="snd-check-count">${completeCount}/${data.checklist.length}</span></div>${active ? '' : `<p class="snd-summary">${escapeHTML(data.summary)}</p>`}<div id="${detailID}" ${active ? '' : 'hidden'} class="snd-task-detail"><button type="button" class="snd-token-row" data-action="usage" data-usage-source="task" data-id="${task.id}" data-key="usage-${task.id}">${icon('chart')}<span>${t('tokens')}</span><strong>${task.tokens}</strong>${icon('right')}</button><div class="snd-detail-text"><h4>${t(task.status === 'completed' ? 'result' : 'latest')}</h4><p>${escapeHTML(data.message)}</p></div>${task.status === 'waiting' ? `<button type="button" class="snd-reply" data-action="reply" data-key="reply-${task.id}">${t('reply')} ↗</button>` : ''}<details class="snd-prompt"><summary>${t('task')}</summary><p>${escapeHTML(data.prompt)}</p></details><ul class="snd-checklist">${data.checklist.map((item, index) => `<li class="${index < completeCount ? 'snd-complete' : ''}"><span aria-label="${t(index < completeCount ? 'taskComplete' : 'taskPending')}">${index < completeCount ? '✓' : '○'}</span>${escapeHTML(item)}</li>`).join('')}</ul><div class="snd-activity"><h4>${t('activity')}</h4>${data.events.map((event, index) => `<p><time>10:${String(42 - index).padStart(2, '0')}</time><span>${escapeHTML(event)}</span></p>`).join('')}</div><p class="snd-path">${icon('folder')}~/Projects/${task.project}</p></div></article>`;
  }
  function agentRow(id, status) {
    return `<div class="snd-agent-row">${provider(id)}<span class="snd-agent-presence"><i aria-hidden="true"></i>${t('available')}</span><span class="snd-agent-activity snd-${status}">· ${t(status)}</span></div>`;
  }
  function agentsContent() {
    return `<div class="snd-agents-list"><p class="snd-group-label">${t('local')}</p>${agentRow('codex', 'working')}${agentRow('claude', 'idle')}${agentRow('pi', 'working')}<button type="button" class="snd-remote-toggle" data-action="remote" data-key="remote" aria-expanded="${remoteExpanded}" aria-controls="${prefix}-remote">${icon(remoteExpanded ? 'down' : 'right')}${icon('network')}<strong>${t('remote')}</strong><span>${t('remoteHint')}</span><i aria-hidden="true"></i></button><div class="snd-remote-children" id="${prefix}-remote" ${remoteExpanded ? '' : 'hidden'}>${agentRow('hermes', 'waiting')}${agentRow('opencode', 'idle')}</div><p class="snd-agent-note">${t('remoteDescription')}</p><a class="snd-manage" href="https://github.com/eugeneb1ack/si-notch/blob/main/docs/agent-integrations.md">${t('manage')}</a></div>`;
  }
  function historyContent() {
    const entry = HISTORY.find(item => item.id === historySelected);
    if (entry) {
      const data = entry[language];
      return `<div class="snd-history-detail"><button type="button" class="snd-history-back" data-action="back" data-key="history-back">${icon('left')}${t('back')}</button><h3>${escapeHTML(data.title)}</h3><div class="snd-history-meta"><span class="snd-${entry.status}">${statusIcon(entry.status)}${t(entry.status)}</span>${provider(entry.provider)}<time>${t(entry.date)}</time></div><button type="button" class="snd-token-row" data-action="usage" data-usage-source="history" data-id="${entry.id}" data-key="history-usage">${icon('chart')}<span>${t('tokens')}</span><strong>${entry.tokens}</strong>${icon('right')}</button>${data.messages.map(([role, message]) => `<section class="snd-message"><h4>${role === 'command' ? icon('terminal') : ''}${t(role)}</h4><p>${escapeHTML(message)}</p></section>`).join('')}</div>`;
    }
    const query = searches.history.toLocaleLowerCase();
    const entries = HISTORY.filter(item => (item[language].title + PROVIDERS[item.provider].name + item[language].messages.flat().join(' ')).toLocaleLowerCase().includes(query));
    return `<div class="snd-history-list">${entries.length ? entries.map(item => `<button type="button" class="snd-history-row" data-action="history" data-id="${item.id}" data-key="history-${item.id}"><span class="snd-history-symbol snd-${item.status}">${statusIcon(item.status)}</span><span class="snd-history-row-content"><strong>${escapeHTML(item[language].title)}</strong><span><span class="snd-${item.status}">${t(item.status)}</span> · ${PROVIDERS[item.provider].name}<time>${t(item.date)}</time></span></span><span class="snd-history-tokens">${item.tokens}</span>${icon('right')}</button>`).join('') : `<p class="snd-empty">${t('historyEmpty')}</p>`}</div>`;
  }
  function usageContent() {
    if (usageSelection) {
      const items = usageSelection.source === 'history' ? HISTORY : TASKS;
      const item = items.find(entry => entry.id === usageSelection.id);
      if (item) return `<div class="snd-usage"><button type="button" class="snd-history-back" data-action="usage-back" data-key="usage-back">${icon('left')}${t(usageSelection.source === 'history' ? 'backToConversation' : 'backToTask')}</button><h3>${escapeHTML(item[language].title)}</h3><div class="snd-usage-total"><span>${t('total')}</span><strong>${item.tokens}</strong></div><div class="snd-usage-provider">${provider(item.provider)}<span class="snd-${item.status}">${t(item.status)}</span></div><p class="snd-usage-note">${t('usageNote')}</p></div>`;
    }
    const windows = [['fiveHours', quotaRefreshed ? 63 : 68, 'hours'], ['week', quotaRefreshed ? 81 : 82, 'days']];
    return `<div class="snd-usage"><button type="button" class="snd-history-back" data-action="tasks" data-key="usage-back">${icon('left')}${t('backToTasks')}</button><h3>${t('usageTitle')}</h3><p>${t('usageSubtitle')}</p><section class="snd-quota"><button type="button" class="snd-quota-toggle" data-action="quota" data-key="quota" aria-expanded="${quotaExpanded}" aria-controls="${prefix}-quota">${icon('chart')}<strong>${t('limits')}</strong>${icon(quotaExpanded ? 'up' : 'down')}</button><div id="${prefix}-quota" ${quotaExpanded ? '' : 'hidden'}><p class="snd-quota-help">${t('limitsHelp')}</p>${windows.map(([label, value, reset]) => `<div class="snd-quota-window"><div><span>${t(label)}</span><strong>${value}% ${t('remaining')}</strong></div><progress max="100" value="${value}" aria-label="${t(label)}: ${value}% ${t('remaining')}"></progress><p>${t('resets')}: ${t(reset)}</p></div>`).join('')}<div class="snd-quota-actions"><button type="button" data-action="refresh" data-key="refresh">${t('refresh')}</button><span>${quotaRefreshed ? t('refreshed') : ''}</span></div></div></section><div class="snd-usage-total"><span>${t('total')}</span><strong>39.0K</strong></div><dl><div><dt>${t('input')}</dt><dd>31.2K</dd></div><div><dt>${t('output')}</dt><dd>7.8K</dd></div></dl>${TASKS.map(task => `<div class="snd-usage-provider">${provider(task.provider)}<span>${task.tokens}</span></div>`).join('')}<p class="snd-usage-note">${t('usageNote')}</p></div>`;
  }
  function settingsContent() {
    return `<div class="snd-settings"><button type="button" class="snd-history-back" data-action="tasks" data-key="settings-back">${icon('left')}${t('backToTasks')}</button><h3>${t('settingsTitle')}</h3><h4>${t('appearance')}</h4><div class="snd-setting-row"><span><strong>${t('showCompanion')}</strong><small>${t('showCompanionHelp')}</small></span><button type="button" class="snd-switch" role="switch" aria-checked="${preferences.companion}" aria-label="${t('showCompanion')}" data-action="companion" data-key="setting-companion"><span></span></button></div><h4>${t('notifications')}</h4><div class="snd-setting-row"><span><strong>${t('attentionReveal')}</strong><small>${t('attentionHelp')}</small></span><button type="button" class="snd-switch" role="switch" aria-checked="${preferences.attention}" aria-label="${t('attentionReveal')}" data-action="attention" data-key="setting-attention"><span></span></button></div><button type="button" class="snd-setting-action" data-action="simulate" data-key="simulate">${t('tryAttention')} ${icon('question')}</button><button type="button" class="snd-setting-action" data-action="usage" data-key="settings-usage">${t('usage')} ${icon('chart')}</button><button type="button" class="snd-full-settings" data-action="full-settings" data-key="full-settings">${t('fullSettings')} ↗</button></div>`;
  }
  function renderBody() {
    const scroll = body.scrollTop;
    const focusedKey = body.contains(document.activeElement) ? document.activeElement.dataset.key : null;
    if (settingsShown) body.innerHTML = settingsContent();
    else if (usageShown) body.innerHTML = usageContent();
    else if (tab === 'agents') body.innerHTML = agentsContent();
    else if (filter === 'history') body.innerHTML = historyContent();
    else {
      const query = searches.sessions.toLocaleLowerCase();
      const matches = TASKS.filter(task => (filter === 'all' || (filter === 'working' && task.status === 'working') || (filter === 'attention' && task.status === 'waiting') || (filter === 'done' && task.status === 'completed')) && (task[language].title + task[language].summary + task.project + PROVIDERS[task.provider].name).toLocaleLowerCase().includes(query));
      body.innerHTML = matches.length ? matches.map(taskCard).join('') : `<p class="snd-empty">${t('empty')}</p>`;
    }
    body.scrollTop = scroll;
    if (focusedKey) (body.querySelector(`[data-key="${focusedKey}"]`) || body.querySelector('button') || body).focus({ preventScroll: true });
  }
  function render() {
    if (destroyed) return;
    trigger.setAttribute('aria-label', t('open'));
    panel.setAttribute('aria-label', t('region'));
    headerPet.setAttribute('aria-label', t('greeting'));
    container.querySelector('.snd-header-label').textContent = settingsShown ? t('settings') : usageShown ? t('usage') : tab === 'agents' ? t('agents') : t('count');
    const contextKey = settingsShown ? 'contextSettings' : usageShown ? (usageSelection ? 'contextScopedUsage' : 'contextUsage') : tab === 'agents' ? 'contextAgents' : `context${filter[0].toUpperCase()}${filter.slice(1)}`;
    context.textContent = t(noticeKey || contextKey);
    trigger.querySelector('canvas').hidden = !preferences.companion; compactStatus.hidden = preferences.companion;
    headerPet.hidden = !preferences.companion;
    container.querySelectorAll('[data-command]').forEach(button => {
      const label = t(button.dataset.command); button.setAttribute('aria-label', label); button.title = label;
    });
    container.querySelector('[data-command="usage"]').setAttribute('aria-pressed', String(usageShown));
    container.querySelector('[data-command="settings"]').setAttribute('aria-pressed', String(settingsShown));
    container.querySelector('.snd-navigation').setAttribute('aria-label', t('region'));
    container.querySelectorAll('[data-tab]').forEach(button => {
      button.querySelector('span').textContent = t(button.dataset.tab);
      const active = button.dataset.tab === tab;
      button.setAttribute('aria-selected', String(active)); button.tabIndex = active ? 0 : -1;
      if (button.querySelector('small')) button.querySelector('small').textContent = t('online');
    });
    if (settingsShown || usageShown) {
      body.removeAttribute('aria-labelledby'); body.setAttribute('aria-label', t(settingsShown ? 'settings' : 'usage'));
    } else {
      body.removeAttribute('aria-label'); body.setAttribute('aria-labelledby', `${prefix}-${tab}`);
    }
    const history = filter === 'history';
    container.querySelector('.snd-search').hidden = tab !== 'sessions' || usageShown || settingsShown || (history && historySelected !== null);
    input.placeholder = t(history ? 'searchHistory' : 'search'); input.setAttribute('aria-label', input.placeholder);
    input.value = searches[history ? 'history' : 'sessions'];
    container.querySelector('.snd-filters').hidden = tab !== 'sessions' || usageShown || settingsShown;
    container.querySelector('.snd-filters').setAttribute('aria-label', t('sessions'));
    container.querySelectorAll('[data-filter]').forEach(button => {
      button.textContent = t(button.dataset.filter); button.setAttribute('aria-pressed', String(filter === button.dataset.filter));
    });
    const showRecords = tab === 'sessions' && history && !usageShown && !settingsShown;
    container.querySelector('.snd-footer').hidden = !showRecords;
    container.querySelector('.snd-footer-extra').textContent = showRecords ? t('records') : '';
    renderBody();
  }
  function openSettings() {
    setExpanded(false);
    options.onSettings?.();
  }
  function click(event) {
    const button = event.target.closest('button');
    if (!button || !container.contains(button)) return;
    if (button === trigger) { keyboardFocus = event.detail === 0; touchPinned = pointerType === 'touch' || pointerType === 'pen'; setExpanded(true, keyboardFocus); return; }
    if (button.dataset.tab) { tab = button.dataset.tab; usageShown = false; settingsShown = false; noticeKey = ''; render(); body.scrollTop = 0; return; }
    if (button.dataset.filter) { filter = button.dataset.filter; historySelected = null; noticeKey = ''; render(); body.scrollTop = 0; return; }
    const action = button.dataset.command || button.dataset.action;
    if (action === 'collapse') setExpanded(false, true);
    else if (action === 'settings') { settingsShown = !settingsShown; usageShown = false; noticeKey = ''; render(); body.scrollTop = 0; }
    else if (action === 'full-settings') openSettings();
    else if (action === 'usage') {
      const source = button.dataset.usageSource;
      if (source === 'task' || source === 'history') {
        usageSelection = { source, id: button.dataset.id };
        usageReturn = { tab, filter, selected, historySelected, scroll: body.scrollTop, key: button.dataset.key };
        usageShown = true;
      } else {
        const showingOverview = usageShown && !usageSelection;
        usageSelection = null; usageReturn = null; usageShown = !showingOverview;
      }
      settingsShown = false; noticeKey = ''; render(); body.scrollTop = 0;
    }
    else if (action === 'usage-back') {
      const previous = usageReturn;
      usageShown = false; usageSelection = null; usageReturn = null; settingsShown = false; noticeKey = '';
      if (previous) { tab = previous.tab; filter = previous.filter; selected = previous.selected; historySelected = previous.historySelected; }
      render(); body.scrollTop = previous?.scroll || 0;
      if (previous?.key) body.querySelector(`[data-key="${previous.key}"]`)?.focus({ preventScroll: true });
    }
    else if (action === 'tasks') { tab = 'sessions'; usageShown = false; settingsShown = false; noticeKey = ''; render(); body.scrollTop = 0; container.querySelector('[data-tab="sessions"]').focus({ preventScroll: true }); }
    else if (action === 'quota') { quotaExpanded = !quotaExpanded; renderBody(); }
    else if (action === 'refresh') { quotaRefreshed = true; noticeKey = 'refreshNote'; render(); announce(t(noticeKey)); }
    else if (action === 'companion') { preferences.companion = !preferences.companion; noticeKey = ''; render(); }
    else if (action === 'attention') { preferences.attention = !preferences.attention; noticeKey = ''; render(); }
    else if (action === 'simulate') {
      noticeKey = preferences.attention ? 'attentionEnabled' : 'attentionDisabled';
      if (preferences.attention) { tab = 'sessions'; filter = 'attention'; selected = 'release'; settingsShown = false; usageShown = false; }
      render(); body.scrollTop = 0; announce(t(noticeKey));
      if (preferences.attention) body.querySelector('[data-key="task-release"]')?.focus({ preventScroll: true });
    }
    else if (action === 'task') { selected = selected === button.dataset.id ? null : button.dataset.id; renderBody(); }
    else if (action === 'remote') { remoteExpanded = !remoteExpanded; renderBody(); }
    else if (action === 'history') { historySelected = button.dataset.id; render(); body.scrollTop = 0; body.querySelector('.snd-history-back')?.focus({ preventScroll: true }); }
    else if (action === 'back') { const previous = historySelected; historySelected = null; render(); body.scrollTop = 0; body.querySelector(`[data-key="history-${previous}"]`)?.focus({ preventScroll: true }); }
    else if (action === 'reply') { noticeKey = 'previewReply'; context.textContent = t(noticeKey); announce(t(noticeKey)); }
  }
  function pointerEnter(event) {
    inside = true; clearTimeout(leaveTimer);
    if (event.pointerType !== 'mouse' || expanded) return;
    enterTimer = setTimeout(() => setExpanded(true), 180);
  }
  function pointerLeave(event) {
    inside = false; clearTimeout(enterTimer);
    if (event.pointerType !== 'mouse') return;
    if (!touchPinned && !keyboardFocus) leaveTimer = setTimeout(() => setExpanded(false), 250);
  }
  function pointerDown(event) {
    pointerType = event.pointerType; keyboardFocus = false;
    clearTimeout(enterTimer); clearTimeout(leaveTimer);
    // A touch can take over an already open hover preview without losing it on release.
    if (pointerType === 'touch' || pointerType === 'pen') touchPinned = true;
  }
  function focusOut(event) {
    if (container.contains(event.relatedTarget)) return;
    keyboardFocus = false;
    if (!inside && !touchPinned) { clearTimeout(leaveTimer); leaveTimer = setTimeout(() => setExpanded(false), 250); }
  }
  function keyDown(event) {
    keyboardFocus = true; clearTimeout(leaveTimer);
    if (event.key === 'Escape' && expanded) { event.preventDefault(); event.stopPropagation(); setExpanded(false, true); return; }
    if (event.target.matches('[data-tab]') && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
      event.preventDefault(); tab = event.key === 'Home' ? 'sessions' : event.key === 'End' ? 'agents' : tab === 'sessions' ? 'agents' : 'sessions';
      usageShown = false; settingsShown = false; noticeKey = ''; render(); container.querySelector(`[data-tab="${tab}"]`).focus();
    }
  }
  function search() { searches[filter === 'history' ? 'history' : 'sessions'] = input.value; renderBody(); body.scrollTop = 0; }
  function outside(event) { if (expanded && touchPinned && !container.contains(event.target)) setExpanded(false); }
  function visibility() { if (document.hidden) { clearTimeout(enterTimer); clearTimeout(leaveTimer); } }
  container.addEventListener('click', click); container.addEventListener('pointerenter', pointerEnter);
  container.addEventListener('pointerleave', pointerLeave); container.addEventListener('pointerdown', pointerDown);
  container.addEventListener('focusout', focusOut); container.addEventListener('keydown', keyDown);
  input.addEventListener('input', search); document.addEventListener('pointerdown', outside);
  document.addEventListener('visibilitychange', visibility);
  render();
  return {
    setLanguage(value) { if (!destroyed) { language = value === 'ru' ? 'ru' : 'en'; announce(''); render(); } },
    destroy() {
      if (destroyed) return; destroyed = true;
      clearTimeout(enterTimer); clearTimeout(leaveTimer); companions.forEach(companion => companion.destroy());
      container.removeEventListener('click', click); container.removeEventListener('pointerenter', pointerEnter);
      container.removeEventListener('pointerleave', pointerLeave); container.removeEventListener('pointerdown', pointerDown);
      container.removeEventListener('focusout', focusOut); container.removeEventListener('keydown', keyDown);
      input.removeEventListener('input', search); document.removeEventListener('pointerdown', outside);
      document.removeEventListener('visibilitychange', visibility); container.replaceChildren(); container.classList.remove('snd-mount');
    },
  };
}
