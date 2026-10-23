// Synthetic, local-only examples of native task, session, and quota accounting.
// Input includes cached tokens; total is input + output. Children are counted once.
const TEXT = {
  en: {
    title: 'Usage', navigation: 'Explore usage', tasks: 'Tasks', sessions: 'Sessions & subagents', limits: 'Account limits',
    tasksHelp: 'See the cost of each task. Open one to see who contributed.',
    sessionsHelp: 'See each session’s own usage and its subagents’ contributions. The total counts each session once.',
    limitsHelp: 'Check your remaining Codex allowance and when each window resets.',
    selectedTotal: 'Across 3 tasks', total: 'Total tokens', input: 'Input', output: 'Output', cached: 'Cached input',
    cacheNote: 'Cache is already included in input.', fresh: 'Fresh input', tokenUnit: 'tokens',
    provider: 'Codex', taskSettings: 'Polish the settings', taskNotes: 'Write the release notes', taskChecks: 'Check the install guide',
    settingsDetail: 'A main session and two subagents worked on this task.',
    notesDetail: 'One session turned the changes into a short release note.',
    checksDetail: 'One session checked the installation instructions.',
    main: 'Main session', research: 'Research', review: 'Review', own: 'Own contribution',
    contributors: 'Contributions', includes: 'Includes 2 subagents', single: 'One session', groupedTotal: 'Task total',
    sessionLabel: 'Session', taskLabel: 'Task', viewSessions: 'All sessions & subagents',
    sessionsTotal: 'Across 3 sessions', sessionFamily: 'Main session with subagents',
    once: 'The group total includes these rows. It is not added again.',
    quotaTitle: 'Codex account limits',
    fiveHours: '5-hour window', week: 'Weekly window', remaining: 'remaining', resets: 'Resets in',
    hours: '2h 18m', days: '4d 2h', refresh: 'Refresh',
    refreshed: 'Updated', refreshHelp: 'Refresh reads the latest allowance. It does not reset a limit.',
    accountNote: 'Account allowance is separate from the task tokens shown here.',
  },
  ru: {
    title: 'Использование', navigation: 'Статистика использования', tasks: 'Задачи', sessions: 'Сессии и подагенты', limits: 'Лимиты аккаунта',
    tasksHelp: 'Посмотрите расход по каждой задаче. Раскройте её, чтобы увидеть вклад участников.',
    sessionsHelp: 'Собственный расход каждой сессии и вклад подагентов. Общая сумма без повторного учёта.',
    limitsHelp: 'Проверьте остаток лимитов Codex и время сброса каждого окна.',
    selectedTotal: 'По 3 задачам', total: 'Всего токенов', input: 'Вход', output: 'Выход', cached: 'Кэш входа',
    cacheNote: 'Кэш уже входит во входящие токены.', fresh: 'Новый вход', tokenUnit: 'токенов',
    provider: 'Codex', taskSettings: 'Доработать настройки', taskNotes: 'Написать заметку к релизу', taskChecks: 'Проверить инструкцию установки',
    settingsDetail: 'Над задачей работали основная сессия и два подагента.',
    notesDetail: 'Одна сессия собрала изменения в короткую заметку к релизу.',
    checksDetail: 'Одна сессия проверила инструкцию установки.',
    main: 'Основная сессия', research: 'Исследование', review: 'Проверка', own: 'Собственный вклад',
    contributors: 'Вклад участников', includes: 'Включая 2 подагентов', single: 'Одна сессия', groupedTotal: 'Итого по задаче',
    sessionLabel: 'Сессия', taskLabel: 'Задача', viewSessions: 'Все сессии и подагенты',
    sessionsTotal: 'По 3 сессиям', sessionFamily: 'Основная сессия с подагентами',
    once: 'Итог группы включает эти строки. Повторно он не прибавляется.',
    quotaTitle: 'Лимиты аккаунта Codex',
    fiveHours: 'Окно 5 часов', week: 'Недельное окно', remaining: 'осталось', resets: 'Сброс через',
    hours: '2 ч 18 мин', days: '4 д 2 ч', refresh: 'Обновить',
    refreshed: 'Обновлено', refreshHelp: 'Обновление проверяет актуальный остаток, но не сбрасывает лимит.',
    accountNote: 'Лимиты аккаунта не зависят напрямую от показанных здесь токенов задач.',
  },
};
const TASKS = [
  { id: 'settings', label: 'taskSettings', detail: 'settingsDetail', input: 48000, output: 6000, cached: 30000,
    sessions: [{ id: 'main', label: 'main', input: 32000, output: 4000, cached: 20000 },
      { id: 'research', label: 'research', input: 10000, output: 1200, cached: 6500 },
      { id: 'review', label: 'review', input: 6000, output: 800, cached: 3500 }] },
  { id: 'notes', label: 'taskNotes', detail: 'notesDetail', input: 10000, output: 2000, cached: 8000,
    sessions: [{ id: 'main', label: 'main', input: 10000, output: 2000, cached: 8000 }] },
  { id: 'checks', label: 'taskChecks', detail: 'checksDetail', input: 16000, output: 2000, cached: 12000,
    sessions: [{ id: 'main', label: 'main', input: 16000, output: 2000, cached: 12000 }] },
];
const sum = TASKS.reduce((total, task) => ({ input: total.input + task.input, output: total.output + task.output, cached: total.cached + task.cached }), { input: 0, output: 0, cached: 0 });
// A session can contribute to several tasks. Fold its own contributions once
// across the task journal; the family total is not an additional session row.
const SESSIONS = Object.values(TASKS.reduce((sessions, task) => {
  for (const contribution of task.sessions) {
    const session = sessions[contribution.id] ||= { id: contribution.id, label: contribution.label, input: 0, output: 0, cached: 0 };
    for (const field of ['input', 'output', 'cached']) session[field] += contribution[field];
  }
  return sessions;
}, {}));
const total = counts => counts.input + counts.output;
const escapeHTML = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const paths = {
  down: 'm6 9 6 6 6-6', right: 'm9 6 6 6-6 6', check: 'm5 12 4 4L19 6',
  branch: 'M7 3v10a4 4 0 0 0 4 4h8m-4-4 4 4-4 4',
  task: 'M9 5h11M9 12h11M9 19h11M3 5h1M3 12h1M3 19h1',
  code: 'm7 6-5 6 5 6m10-12 5 6-5 6m-3-14-4 16',
  refresh: 'M20 7V3l-3 3a8 8 0 1 0 3 8M20 7h-5',
};
const icon = key => `<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="${paths[key]}"/></svg>`;
let instanceCount = 0;

export function mountUsageDemo(container, options = {}) {
  if (!(container instanceof HTMLElement)) throw new TypeError('A usage preview container is required.');
  const id = `sud-${++instanceCount}`;
  let language = options.language === 'ru' ? 'ru' : 'en';
  let tab = 'tasks', expandedTask = null, expandedGroups = new Set(['main']);
  let refreshed = false, destroyed = false;
  const t = key => TEXT[language][key] || key;
  const exact = number => number.toLocaleString(language === 'ru' ? 'ru-RU' : 'en-US');
  const compact = number => number >= 1000 ? `${(number / 1000).toLocaleString(language === 'ru' ? 'ru-RU' : 'en-US', { maximumFractionDigits: 1 })}K` : exact(number);
  const count = (value, className = '') => `<span class="sud-number ${className}" title="${exact(value)} ${t('tokenUnit')}" aria-label="${exact(value)} ${t('tokenUnit')}">${compact(value)}</span>`;
  container.classList.add('sud-mount');
  container.innerHTML = `<div class="sud-window"><header class="sud-toolbar"><span class="sud-traffic" aria-hidden="true"><i></i><i></i><i></i></span><span class="sud-window-title"></span></header><div class="sud-tabs" role="tablist">${['tasks', 'sessions', 'limits'].map(key => `<button type="button" role="tab" data-tab="${key}" id="${id}-${key}" aria-controls="${id}-panel"></button>`).join('')}</div><p class="sud-context"></p><section class="sud-content" id="${id}-panel" role="tabpanel" tabindex="0"></section><span class="sud-announcement" role="status" aria-live="polite"></span></div>`;
  const content = container.querySelector('.sud-content');

  function composition(counts) {
    const denominator = total(counts);
    return `<div class="sud-composition" aria-hidden="true"><span class="sud-fresh" style="width:${(counts.input - counts.cached) / denominator * 100}%"></span><span class="sud-cached" style="width:${counts.cached / denominator * 100}%"></span><span class="sud-output" style="width:${counts.output / denominator * 100}%"></span></div>`;
  }
  function summary() {
    return `<div class="sud-summary"><div class="sud-summary-total"><span>${t('selectedTotal')}</span><strong>${count(total(sum))}</strong></div><div class="sud-summary-breakdown"><div class="sud-summary-values"><span><small>${t('input')}</small>${count(sum.input)}</span><span><small>${t('output')}</small>${count(sum.output)}</span><span class="sud-cache-value"><small>${t('cached')}</small>${count(sum.cached)}</span></div>${composition(sum)}<p>${t('cacheNote')}</p></div></div>`;
  }
  function tasksContent() {
    return `${summary()}<div class="sud-task-list">${TASKS.map(task => {
      const expanded = expandedTask === task.id;
      return `<article class="sud-task ${expanded ? 'sud-task-open' : ''}"><button type="button" class="sud-task-toggle" data-task="${task.id}" data-key="task-${task.id}" aria-expanded="${expanded}" aria-controls="${id}-task-${task.id}"><span class="sud-task-icon">${icon('task')}</span><span class="sud-task-title"><strong>${t(task.label)}</strong><small>${t('provider')} · ${t(task.sessions.length > 1 ? 'includes' : 'single')}</small></span>${count(total(task))}<span class="sud-chevron">${icon(expanded ? 'down' : 'right')}</span></button><div class="sud-task-detail" id="${id}-task-${task.id}" ${expanded ? '' : 'hidden'}><p>${t(task.detail)}</p><div class="sud-detail-numbers"><span>${t('input')} ${count(task.input)}</span><span>${t('output')} ${count(task.output)}</span><span>${t('cached')} ${count(task.cached)}</span></div><div class="sud-contributions">${task.sessions.map(session => `<span>${t(session.label)} ${count(total(session))}</span>`).join('')}</div>${task.sessions.length > 1 ? `<button type="button" class="sud-text-action" data-action="sessions" data-key="to-sessions">${t('viewSessions')} ${icon('right')}</button>` : ''}</div></article>`;
    }).join('')}</div>`;
  }
  function sessionsContent() {
    const expanded = expandedGroups.has('main');
    return `<div class="sud-session-overview"><span>${t('sessionsTotal')}</span><strong>${count(total(sum))}</strong></div><div class="sud-session-list"><section class="sud-session-group"><button type="button" class="sud-group-toggle" data-group="main" data-key="group-main" aria-expanded="${expanded}" aria-controls="${id}-group-main"><span class="sud-chevron">${icon(expanded ? 'down' : 'right')}</span><strong>${t('sessionFamily')}</strong><span class="sud-group-count">${count(total(sum))}</span></button><div id="${id}-group-main" class="sud-group-detail" ${expanded ? '' : 'hidden'}><div class="sud-session-table" role="table" aria-label="${t('own')}"><div class="sud-table-header" role="row"><span role="columnheader">${t('sessionLabel')}</span><span role="columnheader">${t('input')}</span><span role="columnheader">${t('output')}</span><span role="columnheader">${t('total')}</span></div>${SESSIONS.map((session, index) => `<div class="sud-session-row ${index ? 'sud-child' : ''}" role="row"><span role="cell">${icon(index ? 'branch' : 'code')}<span>${t(session.label)}</span></span><span role="cell">${count(session.input)}</span><span role="cell">${count(session.output)}</span><span role="cell">${count(total(session))}</span></div>`).join('')}</div><p class="sud-dedup-note">${t('once')}</p></div></section></div>`;
  }
  function limitsContent() {
    const windows = [{ key: 'fiveHours', remaining: refreshed ? 72 : 74, reset: 'hours' }, { key: 'week', remaining: refreshed ? 41 : 42, reset: 'days' }];
    return `<div class="sud-limits"><div class="sud-limits-heading"><span class="sud-provider-mark">${icon('code')}</span><div><h3>${t('quotaTitle')}</h3></div></div><div class="sud-limit-windows">${windows.map(window => `<section class="sud-limit-window"><h4>${t(window.key)}</h4><p class="sud-remaining"><strong>${window.remaining}<span>%</span></strong><span>${t('remaining')}</span></p><progress max="100" value="${window.remaining}" aria-label="${t(window.key)}: ${window.remaining}% ${t('remaining')}"></progress><p class="sud-reset">${t('resets')} <strong>${t(window.reset)}</strong></p></section>`).join('')}</div><div class="sud-refresh-row"><button type="button" data-action="refresh" data-key="refresh">${icon('refresh')}${t('refresh')}</button>${refreshed ? `<span>${t('refreshed')}</span>` : ''}</div><p class="sud-limits-note">${t(refreshed ? 'refreshHelp' : 'accountNote')}</p></div>`;
  }
  function render() {
    if (destroyed) return;
    const focusedKey = content.contains(document.activeElement) ? document.activeElement.dataset.key : null;
    container.querySelector('.sud-window-title').textContent = t('title');
    container.querySelector('.sud-tabs').setAttribute('aria-label', t('navigation'));
    container.querySelectorAll('[data-tab]').forEach(button => {
      button.textContent = t(button.dataset.tab);
      const selected = button.dataset.tab === tab;
      button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1;
    });
    container.querySelector('.sud-context').textContent = t(`${tab}Help`);
    content.setAttribute('aria-labelledby', `${id}-${tab}`);
    content.innerHTML = tab === 'tasks' ? tasksContent() : tab === 'sessions' ? sessionsContent() : limitsContent();
    if (focusedKey) (content.querySelector(`[data-key="${focusedKey}"]`) || container.querySelector(`[data-tab="${tab}"]`)).focus({ preventScroll: true });
  }
  function click(event) {
    const button = event.target.closest('button');
    if (!button || !container.contains(button)) return;
    if (button.dataset.tab) { tab = button.dataset.tab; render(); }
    else if (button.dataset.task) { expandedTask = expandedTask === button.dataset.task ? null : button.dataset.task; render(); }
    else if (button.dataset.group) {
      expandedGroups = expandedGroups.has(button.dataset.group) ? new Set() : new Set([button.dataset.group]);
      render();
    } else if (button.dataset.action === 'sessions') {
      tab = 'sessions'; expandedGroups = new Set(['main']); render();
      container.querySelector('[data-tab="sessions"]').focus({ preventScroll: true });
    } else if (button.dataset.action === 'refresh') {
      refreshed = true; render();
      container.querySelector('.sud-announcement').textContent = t('refreshHelp');
    }
  }
  function keydown(event) {
    if (!event.target.matches('[data-tab]')) return;
    const keys = ['tasks', 'sessions', 'limits']; let index = keys.indexOf(tab);
    if (event.key === 'ArrowRight') index = (index + 1) % keys.length;
    else if (event.key === 'ArrowLeft') index = (index + keys.length - 1) % keys.length;
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = keys.length - 1;
    else return;
    event.preventDefault(); tab = keys[index]; render(); container.querySelector(`[data-tab="${tab}"]`).focus({ preventScroll: true });
  }
  container.addEventListener('click', click); container.addEventListener('keydown', keydown);
  render();
  return {
    setLanguage(value) { if (!destroyed) { language = value === 'ru' ? 'ru' : 'en'; container.querySelector('.sud-announcement').textContent = ''; render(); } },
    destroy() { if (destroyed) return; destroyed = true; container.removeEventListener('click', click); container.removeEventListener('keydown', keydown); container.replaceChildren(); container.classList.remove('sud-mount'); },
  };
}
