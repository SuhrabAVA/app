/* =========================================================
   Аналитика производства — демо-логика
   Хранение: localStorage.
   Структура готова для будущего подключения Supabase/Firebase/API.
   ========================================================= */

const STORAGE_KEY = "productionAnalyticsDB_v2";

const machineSeed = [
  { id: "m_c2_listov", name: "С 2х листов", unit: "шт", coefficient: 2.4 },
  { id: "m_flex", name: "Флексопечать", unit: "м", coefficient: 3.8 },
  { id: "m_listorezka", name: "Листорезка", unit: "шт", coefficient: 1.5 },
  { id: "m_dnoskleika", name: "Дносклейка", unit: "шт", coefficient: 2.1 },
  { id: "m_vyrubka", name: "Вырубка", unit: "шт", coefficient: 1.7 },
  { id: "m_truba_sbor", name: "Сборка трубы", unit: "шт", coefficient: 2.0 },
  { id: "m_vysechka_a2", name: "Высечка A2", unit: "шт", coefficient: 1.8 },
  { id: "m_handle_flat", name: "Ручка-склейка плоская", unit: "шт", coefficient: 1.2 },
  { id: "m_vysechka_a1", name: "Высечка A1", unit: "шт", coefficient: 1.9 },
  { id: "m_okno", name: "Окно", unit: "шт", coefficient: 1.4 },
  { id: "m_fri", name: "Фри", unit: "шт", coefficient: 1.3 },
  { id: "m_bottom_cold", name: "Склейка дна (Холодная)", unit: "шт", coefficient: 2.3 },
  { id: "m_scotch", name: "Скотч", unit: "шт", coefficient: 0.8 },
  { id: "m_bottom_hot", name: "Склейка дна (Горячая)", unit: "шт", coefficient: 2.6 },
  { id: "m_bobbin", name: "Бабинорезка", unit: "м", coefficient: 2.9 },
  { id: "m_handle_manual", name: "Ручка-склейка ручная", unit: "шт", coefficient: 1.1 },
  { id: "m_handle_twisted", name: "Ручка-склейка крученая", unit: "шт", coefficient: 1.25 },
  { id: "m_rezka", name: "Резка", unit: "шт", coefficient: 1.0 },
  { id: "m_auto_small", name: "Автомат маленький", unit: "шт", coefficient: 3.0 },
  { id: "m_card_insert", name: "Вставка картона", unit: "шт", coefficient: 1.6 },
  { id: "m_bottom_card", name: "Сборка дно+картон", unit: "шт", coefficient: 2.2 },
  { id: "m_card_cut", name: "Резка картона", unit: "шт", coefficient: 1.1 },
  { id: "m_bottom_manual", name: "Склейка дна(ручная)", unit: "шт", coefficient: 1.9 },
  { id: "m_tube", name: "Труба", unit: "шт", coefficient: 2.7 },
  { id: "m_pack", name: "Упаковка", unit: "пачка", coefficient: 0.9 },
  { id: "m_auto_big", name: "Автомат большой", unit: "шт", coefficient: 3.4 },
];

const employeeSeed = [
  { id: "e1", name: "Алихан М.", position: "Оператор", status: "", baseDaySalary: 16000 },
  { id: "e2", name: "Диана С.", position: "Оператор флексопечати", status: "Стажер", baseDaySalary: 18000 },
  { id: "e3", name: "Руслан К.", position: "Наладчик", status: "Начальник смены", baseDaySalary: 19000 },
  { id: "e4", name: "Мадина Т.", position: "Упаковщик", status: "Стажер", baseDaySalary: 13500 },
  { id: "e5", name: "Ернар Б.", position: "Оператор", status: "", baseDaySalary: 15500 },
  { id: "e6", name: "Сауле Н.", position: "Контролёр качества", status: "", baseDaySalary: 14500 },
];
const employeeRoleById = Object.fromEntries(employeeSeed.map((employee) => [employee.id, employee.status]));
const oldLiveStatuses = new Set(["Работает", "Пауза", "Проблема", "Выходной"]);


const eventSeed = [
  {
    id: "ev1",
    employeeId: "e1",
    machineId: "m_auto_big",
    date: "2026-05-01",
    shift: "day",
    orderName: "Заказ №1045 / Azimut Green",
    qty: 1240,
    setupQty: 34,
    totalQty: 1274,
    start: "08:00",
    end: "11:20",
    status: "work",
    reason: "Основная работа по заказу",
    usefulMinutes: 200,
  },
  {
    id: "ev2",
    employeeId: "e1",
    machineId: "m_auto_big",
    date: "2026-05-01",
    shift: "day",
    orderName: "Пауза",
    qty: 0,
    setupQty: 0,
    totalQty: 0,
    start: "11:20",
    end: "11:45",
    status: "pause",
    reason: "Проверка заготовок и ожидание мастера",
    usefulMinutes: 0,
  },
  {
    id: "ev3",
    employeeId: "e1",
    machineId: "m_pack",
    date: "2026-05-01",
    shift: "day",
    orderName: "Заказ №1045 / Упаковка",
    qty: 62,
    setupQty: 0,
    totalQty: 62,
    start: "11:45",
    end: "13:10",
    status: "work",
    reason: "Упаковка готовой продукции",
    usefulMinutes: 85,
  },
  {
    id: "ev4",
    employeeId: "e2",
    machineId: "m_flex",
    date: "2026-05-01",
    shift: "day",
    orderName: "Заказ №1047 / Печать",
    qty: 3200,
    setupQty: 120,
    totalQty: 3320,
    start: "08:30",
    end: "12:10",
    status: "work",
    reason: "Флексопечать, 2 краски",
    usefulMinutes: 220,
  },
  {
    id: "ev5",
    employeeId: "e2",
    machineId: "m_flex",
    date: "2026-05-01",
    shift: "day",
    orderName: "Проблема",
    qty: 0,
    setupQty: 0,
    totalQty: 0,
    start: "12:10",
    end: "13:00",
    status: "problem",
    reason: "Засорение подачи краски",
    usefulMinutes: 0,
  },
  {
    id: "ev6",
    employeeId: "e3",
    machineId: "m_bobbin",
    date: "2026-05-01",
    shift: "night",
    orderName: "Заказ №1051 / Бобинорезка",
    qty: 5100,
    setupQty: 70,
    totalQty: 5170,
    start: "20:00",
    end: "02:30",
    status: "work",
    reason: "Ночная смена",
    usefulMinutes: 390,
  },
  {
    id: "ev7",
    employeeId: "e5",
    machineId: "m_listorezka",
    date: "2026-05-02",
    shift: "day",
    orderName: "Заказ №1052 / Листорезка",
    qty: 4200,
    setupQty: 90,
    totalQty: 4290,
    start: "08:00",
    end: "14:30",
    status: "work",
    reason: "Пакет с 2х листов",
    usefulMinutes: 390,
  },
  {
    id: "ev8",
    employeeId: "e6",
    machineId: "m_okno",
    date: "2026-05-02",
    shift: "day",
    orderName: "Проблема качества",
    qty: 0,
    setupQty: 0,
    totalQty: 0,
    start: "10:10",
    end: "10:55",
    status: "problem",
    reason: "Претензия: неровное окно на партии",
    usefulMinutes: 0,
  },
  {
    id: "ev9",
    employeeId: "e4",
    machineId: "m_pack",
    date: "2026-05-03",
    shift: "night",
    orderName: "Заказ №1055 / Упаковка",
    qty: 88,
    setupQty: 0,
    totalQty: 88,
    start: "20:20",
    end: "02:00",
    status: "work",
    reason: "Упаковка ночной партии",
    usefulMinutes: 340,
  },
];

function createSeedDB() {
  const schedules = {};
  employeeSeed.forEach((employee, index) => {
    schedules[employee.id] = {};
    for (let d = 1; d <= 31; d += 1) {
      const pattern = (d + index) % 6;
      schedules[employee.id][d] = pattern <= 3 ? "day" : pattern === 4 ? "night" : "off";
    }
  });

  const scheduleTimes = {};
  employeeSeed.forEach((employee) => {
    scheduleTimes[employee.id] = {};
    for (let d = 1; d <= 31; d += 1) {
      scheduleTimes[employee.id][d] = defaultShiftTime(schedules[employee.id][d]);
    }
  });

  return {
    machines: machineSeed,
    employees: employeeSeed,
    events: eventSeed,
    salaries: Object.fromEntries(employeeSeed.map((employee) => [
      employee.id,
      salaryDefaults(),
    ])),
    settings: {
      nightPercent: 30,
      mealPortion: 0,
    },
    schedules,
    scheduleTimes,
    selected: {
      view: "employees",
      employeeId: "e1",
      machineId: "m_auto_big",
      selectedDay: 1,
      selectedMachineFilter: "all",
    },
    filters: {
      month: "2026-05",
      search: "",
    },
  };
}

let db = loadDB();

if (!db.filters) db.filters = {};
if (!db.filters.month) {
  db.filters.month = (db.filters.dateFrom || "2026-05-01").slice(0, 7);
}

function loadDB() {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (!stored) {
    const seed = createSeedDB();
    localStorage.setItem(STORAGE_KEY, JSON.stringify(seed));
    return seed;
  }

  try {
    const parsed = JSON.parse(stored);
    const seed = createSeedDB();
    return normalizeAnalyticsDB({
      ...seed,
      ...parsed,
      selected: { ...seed.selected, ...(parsed.selected || {}) },
      filters: { ...seed.filters, ...(parsed.filters || {}) },
      salaries: { ...seed.salaries, ...(parsed.salaries || {}) },
      settings: { ...seed.settings, ...(parsed.settings || {}) },
      schedules: { ...seed.schedules, ...(parsed.schedules || {}) },
      scheduleTimes: { ...seed.scheduleTimes, ...(parsed.scheduleTimes || {}) },
    });
  } catch (error) {
    console.error(error);
    const seed = createSeedDB();
    localStorage.setItem(STORAGE_KEY, JSON.stringify(seed));
    return seed;
  }
}


function injectSchedulePrettyStyles() {
  if (document.getElementById("schedule-pretty-styles")) return;
  const style = document.createElement("style");
  style.id = "schedule-pretty-styles";
  style.textContent = `
    /* ===== Нормальный компактный график работы ===== */
    .schedule-table {
      min-width: 2550px;
      border-spacing: 0;
      table-layout: fixed;
    }

    .schedule-table th,
    .schedule-table td {
      padding: 7px 6px !important;
    }

    .schedule-table th:first-child,
    .schedule-table td:first-child {
      position: sticky;
      left: 0;
      z-index: 4;
      width: 220px;
      min-width: 220px;
      max-width: 220px;
      background: #121a2e;
      box-shadow: 10px 0 22px rgba(2, 6, 23, .35);
    }

    .schedule-table td:first-child {
      background: #0f172a;
    }

    .schedule-table th:not(:first-child),
    .schedule-table td:not(:first-child) {
      width: 74px;
      min-width: 74px;
      max-width: 74px;
      text-align: center;
    }

    .schedule-cell {
      padding: 4px !important;
      vertical-align: middle;
      background: rgba(2, 6, 23, .14);
    }

    .schedule-daybox {
      width: 66px;
      height: 76px;
      min-height: 76px;
      display: grid;
      grid-template-rows: 1fr auto 18px 18px;
      gap: 0;
      justify-items: center;
      align-items: center;
      padding: 5px;
      overflow: hidden;
      border-radius: 14px;
      border: 1px solid rgba(148, 163, 184, 0.18);
      background: #172033;
      box-shadow: inset 0 1px 0 rgba(255,255,255,.07), 0 5px 12px rgba(0,0,0,.18);
      transition: transform .14s ease, border-color .14s ease, box-shadow .14s ease, filter .14s ease;
    }

    .schedule-cell:hover .schedule-daybox {
      transform: translateY(-1px);
      filter: brightness(1.03);
      border-color: rgba(56, 189, 248, 0.48);
      box-shadow: inset 0 1px 0 rgba(255,255,255,.10), 0 8px 17px rgba(0,0,0,.24);
    }

    .schedule-daybox.day {
      color: #101827;
      border-color: rgba(250, 204, 21, .45);
      background: linear-gradient(180deg, #facc15 0%, #f3bc0b 100%);
    }

    .schedule-daybox.night {
      color: #f8fafc;
      border-color: rgba(148, 163, 184, .22);
      background: linear-gradient(180deg, #040817 0%, #0b1220 100%);
    }

    .schedule-daybox.off {
      color: #cbd5e1;
      border-color: rgba(148, 163, 184, .19);
      background: linear-gradient(180deg, #253149 0%, #182238 100%);
    }

    .schedule-time-pill {
      width: 100%;
      height: 20px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 1px;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,.09);
      background: rgba(2, 6, 23, .22);
      color: inherit;
      cursor: text;
      box-shadow: inset 0 1px 0 rgba(255,255,255,.04);
    }

    .schedule-time-pill.arrival::before {
      content: "↘";
      font-size: 8px;
      line-height: 1;
      font-weight: 950;
      opacity: .86;
    }

    .schedule-time-pill.departure::before {
      content: "↗";
      font-size: 8px;
      line-height: 1;
      font-weight: 950;
      opacity: .86;
    }

    .schedule-daybox.day .schedule-time-pill {
      background: rgba(120, 86, 0, .20);
      border-color: rgba(120, 86, 0, .10);
    }

    .schedule-daybox.night .schedule-time-pill {
      background: rgba(2, 6, 23, .72);
      border-color: rgba(148, 163, 184, .18);
    }

    .schedule-daybox.off .schedule-time-pill {
      background: rgba(15, 23, 42, .70);
      border-color: rgba(148, 163, 184, .16);
    }

    .schedule-time-input {
      width: 38px;
      height: 15px;
      border: 0;
      outline: none;
      background: transparent;
      color: inherit;
      font-size: 11px;
      font-weight: 950;
      text-align: center;
      padding: 0;
      letter-spacing: .01em;
    }

    .schedule-time-input::placeholder {
      color: currentColor;
      opacity: .72;
    }

    .schedule-shift-button {
      width: 100% !important;
      height: 32px !important;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0;
      border: 0 !important;
      border-radius: 10px !important;
      background: transparent !important;
      color: inherit !important;
      box-shadow: none !important;
      cursor: pointer;
      transition: transform .14s ease, filter .14s ease;
    }

    .schedule-shift-button:hover {
      transform: scale(1.03);
      filter: brightness(1.05);
    }

    .schedule-date-number {
      display: block;
      font-size: 21px;
      font-weight: 950;
      line-height: .92;
      letter-spacing: -.04em;
    }

    .schedule-shift-name {
      display: block;
      font-size: 8.5px;
      line-height: 1;
      font-weight: 950;
      text-transform: lowercase;
      letter-spacing: .05em;
      opacity: .88;
    }

    .schedule-daybox.off .schedule-shift-name {
      color: #cbd5e1;
    }

    /* ===== Календарь внутри карточки сотрудника и рабочего места: широкий, аккуратный, без пустых зон ===== */
    .calendar-grid {
      display: grid;
      grid-template-columns: repeat(7, minmax(82px, 1fr)) !important;
      gap: 10px !important;
      width: 100%;
      justify-content: stretch;
      align-items: start;
    }

    .calendar-day {
      width: auto !important;
      min-width: 0 !important;
      height: 84px !important;
      min-height: 84px !important;
      padding: 6px 6px !important;
      border-radius: 16px !important;
      text-align: center !important;
      overflow: hidden;
      box-shadow: inset 0 1px 0 rgba(255,255,255,.08), 0 5px 12px rgba(0,0,0,.16);
    }

    .calendar-day:hover,
    .calendar-day.selected {
      transform: translateY(-1px) !important;
      border-color: rgba(56, 189, 248, .75) !important;
      box-shadow: inset 0 1px 0 rgba(255,255,255,.12), 0 0 0 2px rgba(56,189,248,.12), 0 8px 16px rgba(0,0,0,.22) !important;
    }

    .calendar-day.day {
      color: #101827 !important;
      border-color: rgba(250, 204, 21, .45) !important;
      background: linear-gradient(180deg, #facc15 0%, #f3bc0b 100%) !important;
    }

    .calendar-day.night {
      color: #f8fafc !important;
      border-color: rgba(148, 163, 184, .22) !important;
      background: linear-gradient(180deg, #040817 0%, #0b1220 100%) !important;
    }

    .calendar-day.off {
      color: #cbd5e1 !important;
      border-color: rgba(148, 163, 184, .18) !important;
      background: linear-gradient(180deg, #253149 0%, #182238 100%) !important;
    }

    .calendar-day-inner {
      height: 100%;
      display: grid;
      grid-template-rows: 1fr auto 18px 18px;
      align-items: center;
      gap: 0;
    }

    .calendar-time {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 20px;
      height: 20px;
      padding: 0 4px;
      border-radius: 10px;
      font-size: 11px;
      font-weight: 950;
      line-height: 1;
      background: rgba(2, 6, 23, .22);
      border: 1px solid rgba(255,255,255,.10);
      white-space: nowrap;
      color: inherit;
    }

    .calendar-day.day .calendar-time {
      background: rgba(120, 86, 0, .20);
      border-color: rgba(120, 86, 0, .10);
    }

    .calendar-day.night .calendar-time,
    .calendar-day.off .calendar-time {
      background: rgba(2, 6, 23, .58);
      border-color: rgba(148, 163, 184, .18);
    }

    .calendar-day .num,
    .calendar-day .type {
      text-align: center;
    }

    .calendar-day .num {
      align-self: end;
    }

    .calendar-day .type {
      align-self: start;
      margin-top: -2px;
    }

    .calendar-day .num {
      display: block;
      font-size: 22px !important;
      font-weight: 950 !important;
      line-height: .92;
      letter-spacing: -.04em;
    }

    .calendar-day .type {
      display: block;
      margin-top: 0 !important;
      font-size: 8.5px !important;
      font-weight: 950 !important;
      text-transform: lowercase;
      letter-spacing: .05em;
      color: inherit !important;
      opacity: .88;
    }
  `;
  document.head.appendChild(style);
}

function defaultShiftTime(type) {
  if (type === "day") return { arrival: "08:00", departure: "20:00" };
  if (type === "night") return { arrival: "20:00", departure: "08:00" };
  return { arrival: "", departure: "" };
}

function salaryDefaults() {
  return {
    compensation: 0,
    social: 0,
    meal: 0,
    advance: 0,
    cashless: 0,
    discipline: 0,
    defect: 0,
  };
}

function getNightPercent() {
  const value = Number(db.settings?.nightPercent ?? 30);
  return Number.isFinite(value) ? value : 30;
}

function getMealPortion() {
  const value = Number(db.settings?.mealPortion ?? 0);
  return Number.isFinite(value) ? value : 0;
}

function normalizeAnalyticsDB(data) {
  data.scheduleTimes = data.scheduleTimes || {};
  data.schedules = data.schedules || {};
  data.salaries = data.salaries || {};
  data.settings = { nightPercent: 30, mealPortion: 0, ...(data.settings || {}) };

  data.employees.forEach((employee) => {
    const allowed = new Set(["", "Стажер", "Начальник смены"]);
    if (oldLiveStatuses.has(employee.status) || !allowed.has(employee.status || "")) {
      employee.status = employeeRoleById[employee.id] || "";
    }

    data.salaries[employee.id] = {
      ...salaryDefaults(),
      ...(data.salaries[employee.id] || {}),
    };

    data.schedules[employee.id] = data.schedules[employee.id] || {};
    data.scheduleTimes[employee.id] = data.scheduleTimes[employee.id] || {};

    for (let d = 1; d <= 31; d += 1) {
      const type = data.schedules[employee.id][d] || "off";
      const fallback = defaultShiftTime(type);
      data.scheduleTimes[employee.id][d] = {
        arrival: data.scheduleTimes[employee.id][d]?.arrival ?? fallback.arrival,
        departure: data.scheduleTimes[employee.id][d]?.departure ?? fallback.departure,
      };
    }
  });
  return data;
}

function getScheduleTime(employeeId, day) {
  db.scheduleTimes = db.scheduleTimes || {};
  db.scheduleTimes[employeeId] = db.scheduleTimes[employeeId] || {};

  const type = db.schedules[employeeId]?.[day] || "off";
  const fallback = defaultShiftTime(type);
  db.scheduleTimes[employeeId][day] = {
    arrival: db.scheduleTimes[employeeId][day]?.arrival ?? fallback.arrival,
    departure: db.scheduleTimes[employeeId][day]?.departure ?? fallback.departure,
  };

  return db.scheduleTimes[employeeId][day];
}

function timeOrDash(value) {
  return value || "—";
}

function saveDB() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(db));
}

function resetDB() {
  localStorage.removeItem(STORAGE_KEY);
  db = loadDB();
  hydrateGlobalControls();
  showToast("Демо-данные сброшены");
  render();
}

function money(value) {
  return new Intl.NumberFormat("ru-RU", {
    style: "currency",
    currency: "KZT",
    maximumFractionDigits: 0,
  }).format(Math.round(value || 0));
}

function number(value) {
  return new Intl.NumberFormat("ru-RU").format(Math.round(value || 0));
}

function minutesToHours(minutes) {
  const h = Math.floor((minutes || 0) / 60);
  const m = Math.round((minutes || 0) % 60);
  return `${h} ч ${m} мин`;
}

function parseTimeToMinutes(time) {
  const [h, m] = time.split(":").map(Number);
  let result = h * 60 + m;
  if (h < 8) result += 24 * 60;
  return result;
}

function durationMinutes(event) {
  return Math.max(0, parseTimeToMinutes(event.end) - parseTimeToMinutes(event.start));
}

function getMachine(id) {
  return db.machines.find((machine) => machine.id === id);
}

function getEmployee(id) {
  return db.employees.find((employee) => employee.id === id);
}

function eventsInFilter() {
  const month = db.filters.month;
  return db.events.filter((event) => !month || event.date.startsWith(month));
}

function employeeEvents(employeeId) {
  return eventsInFilter().filter((event) => event.employeeId === employeeId);
}

function machineEvents(machineId) {
  return eventsInFilter().filter((event) => event.machineId === machineId);
}

function searchText() {
  return (db.filters.search || "").trim().toLowerCase();
}

function employeeSummary(employeeId) {
  const employee = getEmployee(employeeId);
  const events = employeeEvents(employeeId);
  const workEvents = events.filter((event) => event.status === "work");
  const pauses = events.filter((event) => event.status === "pause");
  const problems = events.filter((event) => event.status === "problem");

  const totalUsefulMinutes = workEvents.reduce((sum, event) => sum + (event.usefulMinutes || durationMinutes(event)), 0);
  const totalTime = events.reduce((sum, event) => sum + durationMinutes(event), 0);
  const pauseTime = pauses.reduce((sum, event) => sum + durationMinutes(event), 0);
  const problemTime = problems.reduce((sum, event) => sum + durationMinutes(event), 0);
  const qty = workEvents.reduce((sum, event) => sum + event.qty, 0);
  const setupQty = workEvents.reduce((sum, event) => sum + event.setupQty, 0);
  const totalQty = workEvents.reduce((sum, event) => sum + event.totalQty, 0);
  const days = new Set(events.filter((event) => event.shift === "day").map((event) => event.date)).size;
  const nights = new Set(events.filter((event) => event.shift === "night").map((event) => event.date)).size;
  const shifts = days + nights;
  const claims = problems.length;

  const productionPay = workEvents.reduce((sum, event) => {
    const machine = getMachine(event.machineId);
    return sum + event.qty * (machine?.coefficient || 0);
  }, 0);

  const baseShiftPay = shifts * (employee?.baseDaySalary || 0);
  const averagePiecePay = shifts ? productionPay / shifts : 0;
  const nightShiftPay = averagePiecePay * nights * (getNightPercent() / 100);
  const mealDeduction = shifts * getMealPortion();
  const grossSalary = baseShiftPay + productionPay + nightShiftPay;
  const adjustments = { ...salaryDefaults(), ...(db.salaries[employeeId] || {}) };
  const deductions =
    (adjustments.social || 0) +
    mealDeduction +
    (adjustments.advance || 0) +
    (adjustments.cashless || 0) +
    (adjustments.discipline || 0) +
    (adjustments.defect || 0);
  const totalSalary = grossSalary - deductions + (adjustments.compensation || 0);

  return {
    events,
    workEvents,
    pauses,
    problems,
    totalUsefulMinutes,
    totalTime,
    pauseTime,
    problemTime,
    qty,
    setupQty,
    totalQty,
    days,
    nights,
    shifts,
    claims,
    productionPay,
    baseShiftPay,
    averagePiecePay,
    nightShiftPay,
    grossSalary,
    salary: grossSalary,
    mealDeduction,
    totalSalary,
    kpd: totalTime ? Math.round((totalUsefulMinutes / totalTime) * 100) : 0,
  };
}

function machineSummary(machineId) {
  const events = machineEvents(machineId);
  const workEvents = events.filter((event) => event.status === "work");
  const pauses = events.filter((event) => event.status === "pause");
  const problems = events.filter((event) => event.status === "problem");
  const totalTime = events.reduce((sum, event) => sum + durationMinutes(event), 0);
  const workTime = workEvents.reduce((sum, event) => sum + durationMinutes(event), 0);
  const pauseTime = pauses.reduce((sum, event) => sum + durationMinutes(event), 0);
  const problemTime = problems.reduce((sum, event) => sum + durationMinutes(event), 0);
  const qty = workEvents.reduce((sum, event) => sum + (event.qty || 0), 0);
  const setupQty = workEvents.reduce((sum, event) => sum + (event.setupQty || 0), 0);

  let qtyTime = 0;
  let setupTime = 0;
  workEvents.forEach((event) => {
    const useful = event.usefulMinutes || durationMinutes(event);
    const qtyPart = event.qty || 0;
    const setupPart = event.setupQty || 0;
    const totalUnits = qtyPart + setupPart;
    if (!totalUnits) return;
    qtyTime += useful * (qtyPart / totalUnits);
    setupTime += useful * (setupPart / totalUnits);
  });

  const uniqueOrders = new Set(workEvents.map((event) => event.orderName).filter(Boolean));
  const claims = events.filter((event) => `${event.reason || ""} ${event.orderName || ""}`.toLowerCase().includes("претенз")).length;
  const shiftDays = new Set(events.map((event) => event.date)).size;
  const qtySpeed = qtyTime ? qty / qtyTime : 0;
  const setupSpeed = setupTime ? setupQty / setupTime : 0;
  const currentMonthSpeed = workTime ? qty / workTime : 0;
  const previousAverageSpeed = Number(getMachine(machineId)?.previousAverageSpeed || currentMonthSpeed || 0);
  const kpdPercent = previousAverageSpeed ? (currentMonthSpeed / previousAverageSpeed) * 100 : 0;

  return {
    events,
    workEvents,
    pauses,
    problems,
    totalTime,
    workTime,
    pauseTime,
    problemTime,
    qty,
    setupQty,
    qtyTime,
    setupTime,
    avgQtyTime: qty ? qtyTime / qty : 0,
    avgSetupTime: setupQty ? setupTime / setupQty : 0,
    qtySpeed,
    setupSpeed,
    currentMonthSpeed,
    previousAverageSpeed,
    ordersCount: uniqueOrders.size,
    claims,
    shifts: shiftDays,
    kpd: totalTime ? Math.round((workTime / totalTime) * 100) : 0,
    kpdPercent: Math.round(kpdPercent),
  };
}

function setView(view) {
  db.selected.view = view;
  saveDB();
  document.querySelectorAll(".tab-button").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.view === view);
  });
  render();
}

function setDetailView(view) {
  document.querySelectorAll(".view").forEach((el) => el.classList.remove("active"));
  document.getElementById(view).classList.add("active");
}

function render() {
  hydrateGlobalControls();
  document.querySelectorAll(".tab-button").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.view === db.selected.view);
  });

  if (db.selected.view === "employees") {
    renderEmployees();
    setDetailView("employeesView");
  }

  if (db.selected.view === "employeeDetail") {
    renderEmployeeDetail();
    setDetailView("employeeDetailView");
  }

  if (db.selected.view === "machines") {
    renderMachines();
    setDetailView("machinesView");
  }

  if (db.selected.view === "machineDetail") {
    renderMachineDetail();
    setDetailView("machineDetailView");
  }

  if (db.selected.view === "schedule") {
    renderSchedule();
    setDetailView("scheduleView");
  }
}

function hydrateGlobalControls() {
  const selectedMonth = document.getElementById("selectedMonth");
  if (selectedMonth) selectedMonth.value = db.filters.month || "2026-05";
}

function renderKpis(target, items) {
  const html = items.map((item) => `
    <div class="kpi-card ${item.cardClass || ""}">
      <div class="kpi-label">${item.label}</div>
      <div class="kpi-value ${item.valueClass || ""}">${item.value}</div>
      <div class="kpi-sub">${item.sub || ""}</div>
    </div>
  `).join("");
  target.insertAdjacentHTML("beforeend", `<div class="dashboard-grid">${html}</div>`);
}

function employeeMachineStats(employeeId, machineId) {
  const events = employeeEvents(employeeId).filter((event) => event.machineId === machineId);
  const workEvents = events.filter((event) => event.status === "work");
  const setupQty = workEvents.reduce((sum, event) => sum + (event.setupQty || 0), 0);
  const qty = workEvents.reduce((sum, event) => sum + (event.qty || 0), 0);
  const totalQty = workEvents.reduce((sum, event) => sum + (event.totalQty || 0), 0);
  const workTime = workEvents.reduce((sum, event) => sum + durationMinutes(event), 0);
  return { events, workEvents, setupQty, qty, totalQty, workTime };
}


function machineEmployeeRatings(machineId) {
  return db.employees.map((employee) => {
    const stats = employeeMachineStats(employee.id, machineId);
    const usefulMinutes = stats.workEvents.reduce((sum, event) => sum + (event.usefulMinutes || durationMinutes(event)), 0);
    const qty = stats.workEvents.reduce((sum, event) => sum + (event.qty || 0), 0);
    return {
      employee,
      usefulMinutes,
      qty,
      minutesPerQty: qty ? usefulMinutes / qty : 0,
    };
  }).filter((row) => row.qty > 0).sort((a, b) => a.minutesPerQty - b.minutesPerQty);
}

function employeeWorkplaceColumns(rows) {
  let maxCount = 0;
  rows.forEach(({ employee }) => {
    const count = employeeWorkplaceStats(employee.id).length;
    if (count > maxCount) maxCount = count;
  });
  return Math.max(maxCount, 1);
}

function employeeWorkplaceStats(employeeId) {
  const orderedMachineIds = [];
  employeeEvents(employeeId).forEach((event) => {
    if (event.status === "work" && !orderedMachineIds.includes(event.machineId)) {
      orderedMachineIds.push(event.machineId);
    }
  });

  return orderedMachineIds.map((machineId) => {
    const machine = getMachine(machineId);
    const stats = employeeMachineStats(employeeId, machineId);
    return {
      machineId,
      machine,
      ...stats,
    };
  }).sort((a, b) => b.workTime - a.workTime);
}

function renderEmployeeWorkplaceCell(workplace) {
  if (!workplace) {
    return `<td class="machine-work-cell empty-machine">—</td>`;
  }

  return `
    <td class="machine-work-cell sketch-workplace-cell">
      <div class="mini-machine-name">${workplace.machine?.name || "—"}</div>
      <div class="workplace-mini-line">
        <span><b>П:</b> ${number(workplace.setupQty)}</span>
        <span><b>К:</b> ${number(workplace.qty)} ${workplace.machine?.unit || ""}</span>
        <span><b>В:</b> ${minutesToHours(workplace.workTime)}</span>
      </div>
    </td>
  `;
}

function renderEmployeeWorkplacesColumn(workplaces) {
  if (!workplaces?.length) {
    return `<td class="machine-work-cell empty-machine">—</td>`;
  }

  return `
    <td class="machine-work-cell single-workplaces-cell">
      ${workplaces.map((workplace) => `
        <div class="workplace-simple-row">
          <span class="workplace-simple-name">${workplace.machine?.name || "—"}:</span>
          <span class="workplace-simple-values">${number(workplace.qty)} ${workplace.machine?.unit || ""} | ${number(workplace.setupQty)} | ${minutesToHours(workplace.workTime)}</span>
        </div>
      `).join("")}
    </td>
  `;
}

function renderInlineMoneyInput(employeeId, key) {
  const salary = { ...salaryDefaults(), ...(db.salaries[employeeId] || {}) };
  return `
    <input
      class="inline-money-input"
      type="number"
      value="${salary[key] || 0}"
      min="0"
      step="100"
      onclick="event.stopPropagation()"
      onfocus="event.stopPropagation()"
      onchange="updateSalary('${employeeId}', '${key}', this.value)"
    />
  `;
}

function openStatement(event, employeeId) {
  event.stopPropagation();
  const employee = getEmployee(employeeId);
  showToast(`Ведомость для ${employee?.name || "сотрудника"} пока в разработке`);
}


function renderEmployeeStatus(employee) {
  if (!employee.status) return "";
  if (employee.status === "Стажер") {
    return `<button class="table-role-line trainee" onclick="toggleTraineeStatus(event, '${employee.id}')" title="Нажми, чтобы снять статус стажёра">Стажер</button>`;
  }
  return `<span class="table-role-line">${employee.status}</span>`;
}

function toggleTraineeStatus(event, employeeId) {
  event.stopPropagation();
  const employee = getEmployee(employeeId);
  if (!employee || employee.status !== "Стажер") return;
  if (!window.confirm(`Снять статус стажёра у ${employee.name}?`)) return;
  employee.status = "";
  saveDB();
  render();
  showToast("Статус стажёра снят");
}

function renderMealCell(summary) {
  return `
    <strong>${money(summary.mealDeduction || 0)}</strong>
    <div class="cell-sub">${summary.shifts} порц. × ${money(getMealPortion())}</div>
  `;
}

function employeeTableTotals(rows) {
  const sum = (getter) => rows.reduce((total, row) => total + (getter(row) || 0), 0);
  const shifts = sum((row) => row.summary.shifts);
  const productionPay = sum((row) => row.summary.productionPay);
  return {
    shifts,
    days: sum((row) => row.summary.days),
    nights: sum((row) => row.summary.nights),
    qty: sum((row) => row.summary.qty),
    setupQty: sum((row) => row.summary.setupQty),
    workTime: sum((row) => row.summary.totalUsefulMinutes),
    pauses: sum((row) => row.summary.pauses.length),
    pauseTime: sum((row) => row.summary.pauseTime),
    problems: sum((row) => row.summary.problems.length),
    problemTime: sum((row) => row.summary.problemTime),
    claims: sum((row) => row.summary.claims),
    productionPay,
    baseShiftPay: sum((row) => row.summary.baseShiftPay),
    averagePiecePay: shifts ? productionPay / shifts : 0,
    nightShiftPay: sum((row) => row.summary.nightShiftPay),
    compensation: sum((row) => (db.salaries[row.employee.id]?.compensation || 0)),
    social: sum((row) => (db.salaries[row.employee.id]?.social || 0)),
    meal: sum((row) => row.summary.mealDeduction || 0),
    advance: sum((row) => (db.salaries[row.employee.id]?.advance || 0)),
    cashless: sum((row) => (db.salaries[row.employee.id]?.cashless || 0)),
    discipline: sum((row) => (db.salaries[row.employee.id]?.discipline || 0)),
    defect: sum((row) => (db.salaries[row.employee.id]?.defect || 0)),
    totalSalary: sum((row) => row.summary.totalSalary),
  };
}

function renderEmployeeTotalsFooter(rows) {
  const totals = employeeTableTotals(rows);
  return `
    <tfoot>
      <tr>
        <td class="sticky-employee-column totals-cell"><strong>Общий итог</strong></td>
        <td><strong>${totals.shifts}</strong><div class="cell-sub">смен</div></td>
        <td><strong>${totals.days}</strong></td>
        <td><strong>${totals.nights}</strong></td>
        <td class="machine-work-cell single-workplaces-cell totals-workplace">
          <strong>Всего:</strong> ${number(totals.qty)} / приладка ${number(totals.setupQty)} / ${minutesToHours(totals.workTime)}
        </td>
        <td><strong>${totals.pauses}</strong><div class="cell-sub">${minutesToHours(totals.pauseTime)}</div></td>
        <td><strong>${totals.problems}</strong><div class="cell-sub">${minutesToHours(totals.problemTime)}</div></td>
        <td><strong>${totals.claims}</strong></td>
        <td><strong>${money(totals.productionPay + totals.baseShiftPay)}</strong></td>
        <td><strong>${money(totals.averagePiecePay)}</strong></td>
        <td><strong>${money(totals.nightShiftPay)}</strong></td>
        <td><strong>${money(totals.compensation)}</strong></td>
        <td><strong>${money(totals.social)}</strong></td>
        <td><strong>${money(totals.meal)}</strong></td>
        <td><strong>${money(totals.advance)}</strong></td>
        <td><strong>${money(totals.cashless)}</strong></td>
        <td><strong>${money(totals.discipline)}</strong></td>
        <td><strong>${money(totals.defect)}</strong></td>
        <td><strong>${money(totals.totalSalary)}</strong></td>
        <td>—</td>
      </tr>
    </tfoot>
  `;
}

function renderEmployees() {
  const root = document.getElementById("employeesView");
  root.innerHTML = "";

  const filtered = db.employees.map((employee) => ({ employee, summary: employeeSummary(employee.id) }));

  const totalSalary = filtered.reduce((sum, row) => sum + row.summary.totalSalary, 0);
  const totalUseful = filtered.reduce((sum, row) => sum + row.summary.totalUsefulMinutes, 0);
  const avgKpd = filtered.length ? Math.round(filtered.reduce((sum, row) => sum + row.summary.kpd, 0) / filtered.length) : 0;

  renderKpis(root, [
    { label: "Сотрудников", value: filtered.length, sub: "в выбранном периоде" },
    { label: "Полезное время", value: minutesToHours(totalUseful), sub: "работа + наладка" },
    { label: "Средний КПД", value: `${avgKpd}%`, sub: "по всем сотрудникам" },
    { label: "Итоговая ЗП", value: money(totalSalary), sub: "после удержаний" },
  ]);

  root.insertAdjacentHTML("beforeend", `
    <div class="content-card">
      <div class="card-header">
        <div>
          <h2>Сотрудники</h2>
          <p>Колонка сотрудника закреплена слева. Питание считается автоматически: смены × стоимость порции.</p>
        </div>
        <div class="header-actions">
          <button class="small-button" onclick="openDrawer()">Настроить оплату</button>
          <button class="small-button pdf-button" onclick="downloadPagePDF()">Скачать PDF</button>
        </div>
      </div>
      <div class="table-wrap employees-table-wrap">
        <table class="analytics-table employees-analytics-table">
          <thead>
            <tr>
              <th class="sticky-employee-column">Сотрудник</th>
              <th>Смены</th>
              <th>Дни</th>
              <th>Ночи</th>
              <th class="machine-work-th single-workplaces-header">Рабочие места</th>
              <th>Паузы</th>
              <th>Проблемы</th>
              <th>Претензии</th>
              <th>Сдельно / оклад</th>
              <th>Средняя сдельная</th>
              <th>Оплата ночных</th>
              <th>Компенсация</th>
              <th>Соцотчисления</th>
              <th>Питание</th>
              <th>Аванс</th>
              <th>ЗП без нал</th>
              <th>Дисциплина</th>
              <th>Браки</th>
              <th>Итог ЗП</th>
              <th>Ведомость</th>
            </tr>
          </thead>
          <tbody>
            ${filtered.map(({ employee, summary }) => {
              const workplaces = employeeWorkplaceStats(employee.id);
              return `
              <tr class="clickable-row" onclick="openEmployee('${employee.id}')">
                <td class="sticky-employee-column">
                  <div class="employee-cell employee-main-info one-column-identity">
                    <div class="avatar">${employee.name.slice(0,1)}</div>
                    <div>
                      <div class="cell-title employee-name-main">${employee.name}</div>
                      ${renderEmployeeStatus(employee)}
                    </div>
                  </div>
                </td>
                <td><strong>${summary.shifts}</strong><div class="cell-sub">смен</div></td>
                <td>${summary.days}</td>
                <td>${summary.nights}</td>
                ${renderEmployeeWorkplacesColumn(workplaces)}
                <td><strong>${summary.pauses.length}</strong><div class="cell-sub">${minutesToHours(summary.pauseTime)}</div></td>
                <td><strong>${summary.problems.length}</strong><div class="cell-sub">${minutesToHours(summary.problemTime)}</div></td>
                <td>${summary.claims}</td>
                <td><span class="pay-type-chip">${payTypeLabel(employee, summary)}</span></td>
                <td><strong>${money(summary.averagePiecePay)}</strong></td>
                <td><strong>${money(summary.nightShiftPay)}</strong><div class="cell-sub">${summary.nights} ноч. · ${getNightPercent()}%</div></td>
                <td>${renderInlineMoneyInput(employee.id, "compensation")}</td>
                <td>${renderInlineMoneyInput(employee.id, "social")}</td>
                <td>${renderMealCell(summary)}</td>
                <td>${renderInlineMoneyInput(employee.id, "advance")}</td>
                <td>${renderInlineMoneyInput(employee.id, "cashless")}</td>
                <td>${renderInlineMoneyInput(employee.id, "discipline")}</td>
                <td>${renderInlineMoneyInput(employee.id, "defect")}</td>
                <td><strong>${money(summary.totalSalary)}</strong></td>
                <td><button class="statement-button" onclick="openStatement(event, '${employee.id}')">Ведомость</button></td>
              </tr>`;
            }).join("")}
          </tbody>
          ${renderEmployeeTotalsFooter(filtered)}
        </table>
      </div>
    </div>
  `);
}

function statusBadge(status) {
  return status ? `<span class="badge role">${status}</span>` : "";
}

function payTypeLabel(employee, summary) {
  const isSalary = employee?.payType === "salary" || ((summary?.productionPay || 0) <= 0 && employee?.payType !== "piece");
  const label = isSalary ? "Оклад" : "Сдельно";
  const amount = isSalary ? (summary?.baseShiftPay || 0) : (summary?.productionPay || 0);
  return `${label}: ${money(amount)}`;
}


function openEmployee(employeeId) {
  db.selected.employeeId = employeeId;
  db.selected.view = "employeeDetail";
  db.selected.selectedMachineFilter = "all";
  saveDB();
  render();
}

function renderEmployeeDetail() {
  const root = document.getElementById("employeeDetailView");
  const employee = getEmployee(db.selected.employeeId) || db.employees[0];
  db.selected.employeeId = employee.id;
  const summary = employeeSummary(employee.id);
  const machineIds = [...new Set(summary.workEvents.map((event) => event.machineId))];
  const selectedMachine = db.selected.selectedMachineFilter || "all";
  const selectedDay = db.selected.selectedDay || 1;
  const dayDate = `2026-05-${String(selectedDay).padStart(2, "0")}`;
  const dayEvents = summary.events.filter((event) => event.date === dayDate && (selectedMachine === "all" || event.machineId === selectedMachine));

  root.innerHTML = `
    <div class="detail-toolbar">
      <div>
        <button class="back-link" onclick="setView('employees')">← Назад к сотрудникам</button>
        <h2 class="detail-title">${employee.name}</h2>
        <p class="detail-subtitle">${statusBadge(employee.status)}</p>
      </div>
      <div class="detail-controls">
        <div class="filter-group">
          <label>Быстро сменить сотрудника</label>
          <select onchange="openEmployee(this.value)">
            ${db.employees.map((item) => `<option value="${item.id}" ${item.id === employee.id ? "selected" : ""}>${item.name}</option>`).join("")}
          </select>
        </div>
        <button class="ghost-button" onclick="openDrawer()">ЗП / удержания</button>
        <button class="ghost-button pdf-button" onclick="downloadPagePDF()">Скачать PDF</button>
      </div>
    </div>

    <div class="detail-layout">
      <div class="stack">
        <div class="detail-card">
          <h3>Рабочие места сотрудника</h3>
          <div class="workplace-grid">
            ${machineIds.length ? machineIds.map((machineId) => workplaceEmployeeCard(employee.id, machineId, selectedMachine)).join("") : empty("Пока нет работ в выбранном периоде")}
          </div>
        </div>

        <div class="detail-card">
          <h3>График работы за месяц</h3>
          ${renderCalendar(employee.id, selectedDay)}
          <div class="legend">
            <span class="legend-item"><span class="legend-dot day"></span>дневная смена</span>
            <span class="legend-item"><span class="legend-dot night"></span>ночная смена</span>
            <span class="legend-item"><span class="legend-dot off"></span>выходной</span>
          </div>
        </div>

        <div class="detail-card timeline-card">
          <div class="timeline-head">
            <div>
              <h3>Линия дня: ${String(selectedDay).padStart(2, "0")}.05.2026</h3>
              <p>Показывает фактическое время работы за выбранный день. Если была переработка, шкала автоматически удлиняется.</p>
            </div>
          </div>
          ${renderMachineChips(machineIds, selectedMachine, "employee")}
          ${renderTimeline(dayEvents)}
        </div>

        <div class="detail-card">
          <h3>Заказы и работы выбранного дня</h3>
          ${renderEventList(dayEvents)}
        </div>
      </div>

      <aside class="side-panel">
        <div class="summary-card">
          <h3>Расчёт зарплаты</h3>
          ${renderSalaryEditor(employee.id, summary)}
        </div>

        <div class="summary-card green-summary">
          <h3>Общий итог</h3>
          <div class="stat-row"><span>Дни / ночи</span><strong>${summary.days} / ${summary.nights}</strong></div>
          <div class="stat-row"><span>Полезное время</span><strong>${minutesToHours(summary.totalUsefulMinutes)}</strong></div>
          <div class="stat-row"><span>Паузы</span><strong>${summary.pauses.length} · ${minutesToHours(summary.pauseTime)}</strong></div>
          <div class="stat-row"><span>Проблемы</span><strong>${summary.problems.length} · ${minutesToHours(summary.problemTime)}</strong></div>
          <div class="stat-row"><span>Сделано</span><strong>${number(summary.qty)}</strong></div>
          <div class="total-box">
            <span>К выплате</span>
            <strong>${money(summary.totalSalary)}</strong>
          </div>
        </div>
      </aside>
    </div>
  `;
}

function workplaceEmployeeCard(employeeId, machineId, selectedMachine) {
  const machine = getMachine(machineId);
  const events = employeeEvents(employeeId).filter((event) => event.machineId === machineId);
  const workEvents = events.filter((event) => event.status === "work");
  const pauses = events.filter((event) => event.status === "pause");
  const problems = events.filter((event) => event.status === "problem");
  const pauseTime = pauses.reduce((sum, event) => sum + durationMinutes(event), 0);
  const problemTime = problems.reduce((sum, event) => sum + durationMinutes(event), 0);
  const workTime = workEvents.reduce((sum, event) => sum + durationMinutes(event), 0);
  const qty = workEvents.reduce((sum, event) => sum + (event.qty || 0), 0);
  const speed = workTime ? qty / workTime : 0;
  return `
    <div class="workplace-stat ${selectedMachine === machineId ? "active" : ""}">
      <button onclick="selectMachineFilter('${machineId}')">
        <div class="workplace-name">${machine?.name || "—"}</div>
        <div class="stat-row"><span>Паузы</span><strong>${pauses.length} · ${minutesToHours(pauseTime)}</strong></div>
        <div class="stat-row"><span>Проблемы</span><strong>${problems.length} · ${minutesToHours(problemTime)}</strong></div>
        <div class="stat-row"><span>Сделано</span><strong>${number(qty)} ${machine?.unit || ""} · ${minutesToHours(workTime)}</strong></div>
        <div class="stat-row"><span>Скорость</span><strong>${speed ? speed.toFixed(2) : '0'} ${machine?.unit || 'ед.'}/мин</strong></div>
      </button>
    </div>
  `;
}

function selectMachineFilter(machineId) {
  db.selected.selectedMachineFilter = db.selected.selectedMachineFilter === machineId ? "all" : machineId;
  saveDB();
  render();
}

function selectDay(day) {
  db.selected.selectedDay = Number(day);
  saveDB();
  render();
}

function renderCalendar(employeeId, selectedDay) {
  const schedule = db.schedules[employeeId] || {};
  let html = `<div class="calendar-grid">`;
  for (let d = 1; d <= 31; d += 1) {
    const type = schedule[d] || "off";
    const time = getScheduleTime(employeeId, d);
    html += `
      <button class="calendar-day ${type} ${selectedDay === d ? "selected" : ""}" onclick="selectDay(${d})">
        <span class="calendar-day-inner bottom-times">
          <span class="num">${d}</span>
          <span class="type">${type === "day" ? "день" : type === "night" ? "ночь" : "выходной"}</span>
          <span class="calendar-time arrival">↘ ${timeOrDash(time.arrival)}</span>
          <span class="calendar-time departure">↗ ${timeOrDash(time.departure)}</span>
        </span>
      </button>
    `;
  }
  html += `</div>`;
  return html;
}

function renderMachineChips(machineIds, selectedMachine, context) {
  if (!machineIds.length) return "";
  return `
    <div class="machine-chips">
      <button class="chip ${selectedMachine === "all" ? "active" : ""}" onclick="selectMachineFilter('all')">Все</button>
      ${machineIds.map((id) => {
        const machine = getMachine(id);
        return `<button class="chip ${selectedMachine === id ? "active" : ""}" onclick="selectMachineFilter('${id}')">${machine?.name || id}</button>`;
      }).join("")}
    </div>
  `;
}

function renderTimeline(events) {
  const baseStart = 8 * 60;
  const defaultEnd = 20 * 60;
  const filtered = [...events].sort((a, b) => normalizeTimelineMinutes(a.start, baseStart) - normalizeTimelineMinutes(b.start, baseStart));
  const normalized = filtered.map((event) => {
    let eventStart = normalizeTimelineMinutes(event.start, baseStart);
    let eventEnd = normalizeTimelineMinutes(event.end, baseStart);
    if (eventEnd <= eventStart) eventEnd += 24 * 60;
    return { ...event, startMin: eventStart, endMin: eventEnd };
  });

  const timelineEnd = Math.max(defaultEnd, ...normalized.map((event) => event.endMin || defaultEnd));
  const segments = [];
  let cursor = baseStart;

  normalized.forEach((event) => {
    if (event.startMin > cursor) {
      segments.push({ status: "idle", startMin: cursor, endMin: event.startMin, title: "Простой", reason: "Нет активной работы в системе" });
    }
    segments.push(event);
    cursor = Math.max(cursor, event.endMin);
  });

  if (cursor < timelineEnd) {
    segments.push({ status: "idle", startMin: cursor, endMin: timelineEnd, title: "Простой", reason: "Нет активной работы в системе" });
  }

  const html = segments.map((seg) => {
    const width = Math.max(1.5, ((seg.endMin - seg.startMin) / (timelineEnd - baseStart)) * 100);
    const label = seg.status === "work" ? "Работа" : seg.status === "pause" ? "Пауза" : seg.status === "problem" ? "Проблема" : "";
    return `<div class="segment ${seg.status}" style="width:${width}%">${width > 7 ? label : ""}</div>`;
  }).join("");

  const labels = [];
  for (let tick = baseStart; tick <= timelineEnd; tick += 60) {
    labels.push(formatMinutes(tick));
  }

  return `
    <div class="legend" style="margin-bottom:12px">
      <span class="legend-item"><span class="legend-dot idle"></span>серый — простой</span>
      <span class="legend-item"><span class="legend-dot work"></span>синий — работа</span>
      <span class="legend-item"><span class="legend-dot pause"></span>жёлтый — пауза</span>
      <span class="legend-item"><span class="legend-dot problem"></span>красный — проблема</span>
    </div>
    <div class="timeline">${html}</div>
    <div class="time-scale" style="grid-template-columns: repeat(${labels.length}, 1fr)">
      ${labels.map((label) => `<span>${label}</span>`).join("")}
    </div>
  `;
}

function normalizeTimelineMinutes(timeValue, baseStart = 8 * 60) {
  let mins = parseTimeToMinutes(timeValue);
  if (mins < baseStart) mins += 24 * 60;
  return mins;
}

function showSegmentInfo(encoded) {
  return;
}

function renderInfoBoard(event) {
  return "";
}

function infoBoardHTML(event) {
  if (!event) {
    return `
      <div class="info-board compact-info-board">
        ${["Заказ", "Время", "Количество", "Описание"].map((label) => `
          <div class="info-tile compact"><span>${label}</span><strong>—</strong></div>
        `).join("")}
      </div>
    `;
  }

  const machine = getMachine(event.machineId);
  const employee = getEmployee(event.employeeId);
  const title = event.orderName || event.title || "Простой";
  const start = event.start || formatMinutes(event.startMin || event.start);
  const end = event.end || formatMinutes(event.endMin || event.end);
  const qty = event.qty ? `${number(event.qty)} ${machine?.unit || ""}` : "—";

  return `
    <div class="info-board compact-info-board">
      <div class="info-tile compact"><span>Заказ</span><strong>${title}</strong></div>
      <div class="info-tile compact"><span>Время</span><strong>${start} – ${end}</strong></div>
      <div class="info-tile compact"><span>Количество</span><strong>${qty}</strong></div>
      <div class="info-tile compact"><span>Описание</span><strong>${event.reason || "—"}</strong></div>
      <div class="info-tile compact"><span>Сотрудник</span><strong>${employee?.name || "—"}</strong></div>
      <div class="info-tile compact"><span>Рабочее место</span><strong>${machine?.name || "—"}</strong></div>
      <div class="info-tile compact"><span>Статус</span><strong>${translateStatus(event.status)}</strong></div>
      <div class="info-tile compact"><span>Длительность</span><strong>${minutesToHours(durationMinutes(event))}</strong></div>
    </div>
  `;
}

function translateStatus(status) {
  return status === "work" ? "Работа" : status === "pause" ? "Пауза" : status === "problem" ? "Проблема" : "Простой";
}

function formatMinutes(total) {
  if (typeof total !== "number") return total || "—";
  const normalized = total % (24 * 60);
  const h = String(Math.floor(normalized / 60)).padStart(2, "0");
  const m = String(normalized % 60).padStart(2, "0");
  return `${h}:${m}`;
}

function renderEventList(events) {
  if (!events.length) return empty("На выбранный день нет событий.");

  const groupsMap = new Map();
  events.forEach((event) => {
    const key = `${event.orderName || event.title || "Без названия"}__${event.machineId || "no-machine"}`;
    if (!groupsMap.has(key)) {
      groupsMap.set(key, {
        title: event.orderName || event.title || "Без названия",
        machineId: event.machineId,
        events: [],
      });
    }
    groupsMap.get(key).events.push(event);
  });

  const groups = [...groupsMap.values()].map((group) => {
    const machine = getMachine(group.machineId);
    const qty = group.events.reduce((sum, e) => sum + (e.qty || 0), 0);
    const startMin = Math.min(...group.events.map((e) => normalizeTimelineMinutes(e.start)));
    const endMin = Math.max(...group.events.map((e) => {
      let end = normalizeTimelineMinutes(e.end);
      let start = normalizeTimelineMinutes(e.start);
      if (end <= start) end += 24 * 60;
      return end;
    }));
    const descriptions = [...new Set(group.events.map((e) => e.reason).filter(Boolean))].join("; ") || "—";
    return {
      title: group.title,
      machine,
      qty,
      start: formatMinutes(startMin),
      end: formatMinutes(endMin),
      duration: endMin - startMin,
      description: descriptions,
    };
  }).sort((a, b) => normalizeTimelineMinutes(a.start) - normalizeTimelineMinutes(b.start));

  return `
    <div class="day-order-board simple-order-board">
      ${groups.map((group) => `
        <div class="single-order-line-card">
          <div class="single-order-line-grid">
            <div class="single-order-col single-order-main">
              <span>Заказчик / рабочее место</span>
              <strong>${group.title}</strong>
              <b>${group.machine?.name || "—"}</b>
            </div>
            <div class="single-order-col">
              <span>Время</span>
              <strong>${group.start}–${group.end}</strong>
            </div>
            <div class="single-order-col">
              <span>Длительность</span>
              <strong>${group.duration} мин</strong>
            </div>
            <div class="single-order-col">
              <span>Количество</span>
              <strong>${number(group.qty)} ${group.machine?.unit || ""}</strong>
            </div>
            <div class="single-order-col single-order-description">
              <span>Описание</span>
              <strong>${group.description}</strong>
            </div>
          </div>
        </div>
      `).join("")}
    </div>
  `;
}

function renderSalaryEditor(employeeId, summary) {
  const salary = { ...salaryDefaults(), ...(db.salaries[employeeId] || {}) };
  const rows = [
    ["compensation", "Компенсация", "+"],
    ["social", "Соцотчисления", "−"],
    ["advance", "Аванс", "−"],
    ["cashless", "ЗП без нал.", "−"],
    ["discipline", "Дисциплина", "−"],
    ["defect", "Браки", "−"],
  ];

  return `
    <div class="salary-list">
      <div class="stat-row"><span>Сдельно</span><strong>${money(summary.productionPay)}</strong></div>
      <div class="stat-row"><span>Оклад за смены</span><strong>${money(summary.baseShiftPay)}</strong></div>
      <div class="stat-row"><span>Средняя сдельная</span><strong>${money(summary.averagePiecePay)}</strong></div>
      <div class="stat-row"><span>Ночные ${summary.nights} × ${getNightPercent()}%</span><strong>${money(summary.nightShiftPay)}</strong></div>
      <div class="stat-row"><span>Питание ${summary.shifts} порц. × ${money(getMealPortion())}</span><strong>−${money(summary.mealDeduction)}</strong></div>
      <div class="stat-row"><span>Начислено</span><strong>${money(summary.salary)}</strong></div>
      <div class="stat-row"><span>КПД</span><strong>${summary.kpd}%</strong></div>
      ${rows.map(([key, label, sign]) => `
        <div class="money-row">
          <label>${label} (${sign})</label>
          <input type="number" value="${salary[key] || 0}" min="0" step="100" onchange="updateSalary('${employeeId}', '${key}', this.value)" />
        </div>
      `).join("")}
      <div class="total-box">
        <span>Итоговая зарплата</span>
        <strong>${money(summary.totalSalary)}</strong>
      </div>
    </div>
  `;
}

function updateSalary(employeeId, key, value) {
  db.salaries[employeeId] = db.salaries[employeeId] || {};
  db.salaries[employeeId][key] = Number(value) || 0;
  saveDB();
  render();
}


function formatSpeed(value, unit = "шт") {
  if (!value || !Number.isFinite(value)) return "—";
  return `${value.toFixed(2)} ${unit}/мин`;
}

function productTypeForEvent(event, machine) {
  const text = `${event.reason || ""} ${event.orderName || ""} ${machine?.name || ""}`.toLowerCase();
  if (text.includes("2х лист") || text.includes("2 х лист")) return "пакет_из_2х_листов";
  if (text.includes("v_образ") || text.includes("v-образ") || text.includes("в-образ")) return "v_образный_пакет";
  if (text.includes("п-образ") || text.includes("p_образ")) return "п-образный_пакет";
  if (text.includes("листорез") || text.includes("листы")) return "листы";
  if (text.includes("упаков")) return "упаковка";
  if (text.includes("флекс") || text.includes("печать")) return "печать";
  return (machine?.name || "продукция").toLowerCase().replaceAll(" ", "_");
}

function productionBreakdown(rows) {
  const map = new Map();
  rows.forEach(({ machine, summary }) => {
    summary.workEvents.forEach((event) => {
      if (!event.qty) return;
      const key = productTypeForEvent(event, machine);
      const item = map.get(key) || { qty: 0, unit: machine.unit || "ед." };
      item.qty += event.qty;
      map.set(key, item);
    });
  });
  return [...map.entries()]
    .map(([name, item]) => ({ name, qty: item.qty, unit: item.unit }))
    .sort((a, b) => b.qty - a.qty);
}

function productionBreakdownHTML(rows) {
  const items = productionBreakdown(rows);
  if (!items.length) return "—";
  return `
    <div class="production-breakdown-list">
      ${items.map((item) => `
        <div class="production-breakdown-row">
          <span class="production-name">${item.name}</span>
          <strong class="production-qty">${number(item.qty)} ${item.unit}</strong>
        </div>
      `).join("")}
    </div>
  `;
}

function totalUniqueOrders(rows) {
  const orders = new Set();
  rows.forEach(({ summary }) => {
    summary.workEvents.forEach((event) => {
      if (event.orderName) orders.add(event.orderName);
    });
  });
  return orders.size;
}

function renderMachines() {
  const root = document.getElementById("machinesView");
  root.innerHTML = "";

  const filtered = db.machines.map((machine) => ({ machine, summary: machineSummary(machine.id) }));

  const useful = filtered.reduce((sum, row) => sum + row.summary.workTime, 0);
  const pauseCount = filtered.reduce((sum, row) => sum + row.summary.pauses.length, 0);
  const pauseTime = filtered.reduce((sum, row) => sum + row.summary.pauseTime, 0);
  const problemCount = filtered.reduce((sum, row) => sum + row.summary.problems.length, 0);
  const problemTime = filtered.reduce((sum, row) => sum + row.summary.problemTime, 0);

  renderKpis(root, [
    { label: "Рабочих мест", value: filtered.length, sub: "из встроенной базы" },
    { label: "Количество заказов", value: totalUniqueOrders(filtered), sub: "уникальные заказы" },
    { label: "Количество продукции", value: productionBreakdownHTML(filtered), sub: "по видам продукции", cardClass: "kpi-card-products", valueClass: "kpi-value-products" },
    { label: "Полезных часов", value: minutesToHours(useful), sub: "рабочее время" },
    { label: "Проблемы", value: `${problemCount} / ${minutesToHours(problemTime)}`, sub: "количество и время" },
    { label: "Паузы", value: `${pauseCount} / ${minutesToHours(pauseTime)}`, sub: "количество и время" },
  ]);

  root.insertAdjacentHTML("beforeend", `
    <div class="content-card">
      <div class="card-header">
        <div>
          <h2>Рабочие места</h2>
          <p>Нажми на рабочее место, чтобы открыть его детальную аналитику.</p>
        </div>
        <button class="small-button pdf-button" onclick="downloadPagePDF()">Скачать PDF</button>
      </div>
      <div class="table-wrap">
        <table class="analytics-table">
          <thead>
            <tr>
              <th>Рабочее место</th>
              <th>Количество / Время / Средняя скорость</th>
              <th>Наладки / Время / Средняя скорость</th>
              <th>Заказы (Кол-во)</th>
              <th>Пауза / время</th>
              <th>Проблема / время</th>
              <th>Претензии</th>
              <th>КПД</th>
            </tr>
          </thead>
          <tbody>
            ${filtered.map(({ machine, summary }) => `
              <tr class="clickable-row" onclick="openMachine('${machine.id}')">
                <td>
                  <div class="employee-cell">
                    <div class="avatar green">${machine.name.slice(0,1)}</div>
                    <div>
                      <div class="cell-title">${machine.name}</div>
                      <div class="cell-sub">единица: ${machine.unit}</div>
                    </div>
                  </div>
                </td>
                <td><strong>${number(summary.qty)} ${machine.unit}</strong><div class="cell-sub">${minutesToHours(summary.qtyTime)} / скорость ${formatSpeed(summary.qtySpeed, machine.unit)}</div></td>
                <td><strong>${number(summary.setupQty)}</strong><div class="cell-sub">${minutesToHours(summary.setupTime)} / скорость ${formatSpeed(summary.setupSpeed, "нал")}</div></td>
                <td><strong>${summary.ordersCount}</strong><div class="cell-sub">уникальных заказов</div></td>
                <td><strong>${summary.pauses.length}</strong><div class="cell-sub">${minutesToHours(summary.pauseTime)}</div></td>
                <td><strong>${summary.problems.length}</strong><div class="cell-sub">${minutesToHours(summary.problemTime)}</div></td>
                <td><strong>${summary.claims}</strong></td>
                <td>
                  <strong>${summary.kpdPercent}%</strong>
                  <div class="cell-sub">скорость месяца / средняя прошлых месяцев</div>
                </td>
              </tr>
            `).join("")}
          </tbody>
        </table>
      </div>
    </div>
  `);
}

function openMachine(machineId) {
  db.selected.machineId = machineId;
  db.selected.view = "machineDetail";
  saveDB();
  render();
}

function renderMachineDetail() {
  const root = document.getElementById("machineDetailView");
  const machine = getMachine(db.selected.machineId) || db.machines[0];
  db.selected.machineId = machine.id;
  const summary = machineSummary(machine.id);
  const ratings = machineEmployeeRatings(machine.id);
  const selectedDay = db.selected.selectedDay || 1;
  const dayDate = `2026-05-${String(selectedDay).padStart(2, "0")}`;
  const dayEvents = summary.events.filter((event) => event.date === dayDate);

  root.innerHTML = `
    <div class="detail-toolbar">
      <div>
        <button class="back-link" onclick="setView('machines')">← Назад к рабочим местам</button>
        <h2 class="detail-title">${machine.name}</h2>
        <p class="detail-subtitle">единица измерения: ${machine.unit}</p>
      </div>
      <div class="detail-controls">
        <div class="filter-group">
          <label>Быстро сменить рабочее место</label>
          <select onchange="openMachine(this.value)">
            ${db.machines.map((item) => `<option value="${item.id}" ${item.id === machine.id ? "selected" : ""}>${item.name}</option>`).join("")}
          </select>
        </div>
        <button class="ghost-button pdf-button" onclick="downloadPagePDF()">Скачать PDF</button>
      </div>
    </div>

    <div class="detail-layout">
      <div class="stack">
        <div class="detail-card">
          <h3>График активности рабочего места</h3>
          ${renderMachineCalendar(machine.id, selectedDay)}
          <div class="legend">
            <span class="legend-item"><span class="legend-dot day"></span>есть дневная работа</span>
            <span class="legend-item"><span class="legend-dot night"></span>есть ночная работа</span>
            <span class="legend-item"><span class="legend-dot off"></span>нет событий</span>
          </div>
        </div>

        <div class="detail-card timeline-card">
          <div class="timeline-head">
            <div>
              <h3>Линия рабочего места: ${String(selectedDay).padStart(2, "0")}.05.2026</h3>
              <p>Показывает фактическое время работы рабочего места за выбранный день. При переработке шкала автоматически удлиняется.</p>
            </div>
          </div>
          ${renderTimeline(dayEvents)}
        </div>

        <div class="detail-card">
          <h3>Заказы и работы по рабочему месту</h3>
          ${renderEventList(dayEvents)}
        </div>
      </div>

      <aside class="side-panel">
        <div class="summary-card green-summary">
          <h3>Итог по рабочему месту</h3>
          <div class="stat-row"><span>Количество</span><strong>${number(summary.qty)} ${machine.unit}</strong></div>
          <div class="stat-row"><span>Время на количество</span><strong>${minutesToHours(summary.qtyTime)}</strong></div>
          <div class="stat-row"><span>Наладки</span><strong>${summary.setupQty} · ${minutesToHours(summary.setupTime)}</strong></div>
          <div class="stat-row"><span>Паузы</span><strong>${summary.pauses.length} · ${minutesToHours(summary.pauseTime)}</strong></div>
          <div class="stat-row"><span>Проблемы</span><strong>${summary.problems.length} · ${minutesToHours(summary.problemTime)}</strong></div>
          <div class="stat-row"><span>Заказы / претензии</span><strong>${summary.ordersCount} / ${summary.claims}</strong></div>
          <div class="total-box">
            <span>КПД</span>
            <strong>${summary.kpdPercent}%</strong>
            <small>скорость месяца / средняя прошлых месяцев</small>
          </div>
        </div>

        <div class="summary-card">
          <h3>Рейтинг сотрудников</h3>
          <p class="cell-sub">Формула: полезное время сотрудника / сделанное количество на этом рабочем месте. Чем меньше минут на 1 единицу, тем выше место.</p>
          <div class="rating-list">
            ${ratings.length ? ratings.map((row, index) => `
              <div class="rating-row">
                <div class="rating-place">#${index + 1}</div>
                <div class="rating-main">
                  <div class="rating-name">${row.employee.name}</div>
                  <div class="rating-sub">${minutesToHours(row.usefulMinutes)} / ${number(row.qty)} ${machine.unit}</div>
                </div>
                <div class="rating-metric">${row.minutesPerQty.toFixed(2)} мин</div>
              </div>
            `).join("") : `<div class="cell-sub">Нет данных для рейтинга.</div>`}
          </div>
        </div>
      </aside>
    </div>
  `;
}

function renderMachineCalendar(machineId, selectedDay) {
  let html = `<div class="calendar-grid">`;
  for (let d = 1; d <= 31; d += 1) {
    const date = `2026-05-${String(d).padStart(2, "0")}`;
    const events = machineEvents(machineId).filter((event) => event.date === date);
    const type = events.some((event) => event.shift === "night") ? "night" : events.length ? "day" : "off";
    html += `
      <button class="calendar-day ${type} ${selectedDay === d ? "selected" : ""}" onclick="selectDay(${d})">
        <span class="num">${d}</span>
        <span class="type">${events.length ? `${events.length} событ.` : "нет"}</span>
      </button>
    `;
  }
  html += `</div>`;
  return html;
}

function renderSchedule() {
  const root = document.getElementById("scheduleView");
  const days = Array.from({ length: 31 }, (_, i) => i + 1);

  root.innerHTML = `
    <div class="content-card">
      <div class="card-header">
        <div>
          <h2>Графики работы</h2>
          <p>В каждой ячейке сверху время прихода, по центру день и тип смены, снизу время ухода. ЛКМ по числу переключает День → Ночь → Выходной, ПКМ по ячейке быстро открывает ввод времени прихода.</p>
        </div>
        <div class="legend">
          <span class="legend-item"><span class="legend-dot day"></span>День</span>
          <span class="legend-item"><span class="legend-dot night"></span>Ночь</span>
          <span class="legend-item"><span class="legend-dot off"></span>Выходной</span>
        </div>
      </div>
      <div class="table-wrap">
        <table class="analytics-table schedule-table">
          <thead>
            <tr>
              <th>Сотрудник</th>
              ${days.map((day) => `<th>${day}</th>`).join("")}
            </tr>
          </thead>
          <tbody>
            ${db.employees.map((employee) => `
              <tr>
                <td>
                  <div class="employee-cell">
                    <div class="avatar orange">${employee.name.slice(0,1)}</div>
                    <div>
                      <div class="cell-title">${employee.name}</div>
                      
                    </div>
                  </div>
                </td>
                ${days.map((day) => {
                  const type = db.schedules[employee.id]?.[day] || "off";
                  const time = getScheduleTime(employee.id, day);
                  return `
                    <td
                      class="schedule-cell"
                      oncontextmenu="focusScheduleTimeInput(event, this); return false;"
                      title="ПКМ — быстро вписать время прихода"
                    >
                      <div class="schedule-daybox ${type}">
                        <button
                          class="shift-button schedule-shift-button ${type}"
                          onclick="event.stopPropagation(); cycleShift('${employee.id}', ${day})"
                          title="ЛКМ — переключить смену"
                        >
                          <span class="schedule-date-number">${day}</span>
                          <span class="schedule-shift-name">${type === "day" ? "день" : type === "night" ? "ночь" : "выходной"}</span>
                        </button>
                        <label class="schedule-time-pill arrival" title="Время прихода">
                          <input
                            class="schedule-time-input schedule-arrival-input"
                            type="text"
                            inputmode="numeric"
                            maxlength="5"
                            placeholder="—"
                            value="${time.arrival}"
                            onclick="event.stopPropagation()"
                            oncontextmenu="event.stopPropagation()"
                            onchange="updateScheduleTime('${employee.id}', ${day}, 'arrival', this.value)"
                          />
                        </label>
                        <label class="schedule-time-pill departure" title="Время ухода">
                          <input
                            class="schedule-time-input schedule-departure-input"
                            type="text"
                            inputmode="numeric"
                            maxlength="5"
                            placeholder="—"
                            value="${time.departure}"
                            onclick="event.stopPropagation()"
                            oncontextmenu="event.stopPropagation()"
                            onchange="updateScheduleTime('${employee.id}', ${day}, 'departure', this.value)"
                          />
                        </label>
                      </div>
                    </td>
                  `;
                }).join("")}
              </tr>
            `).join("")}
          </tbody>
        </table>
      </div>
    </div>
  `;
}

function cycleShift(employeeId, day) {
  db.schedules[employeeId] = db.schedules[employeeId] || {};
  db.scheduleTimes = db.scheduleTimes || {};
  db.scheduleTimes[employeeId] = db.scheduleTimes[employeeId] || {};

  const current = db.schedules[employeeId][day] || "off";
  const next = current === "day" ? "night" : current === "night" ? "off" : "day";
  db.schedules[employeeId][day] = next;
  db.scheduleTimes[employeeId][day] = defaultShiftTime(next);

  saveDB();
  render();
  showToast("График сохранён");
}

function normalizeScheduleTime(value) {
  const raw = String(value || "").trim();
  if (!raw || raw === "—") return "";

  const digits = raw.replace(/[^0-9]/g, "");
  if (digits.length === 1 || digits.length === 2) {
    const hours = Math.min(Number(digits), 23);
    return `${String(hours).padStart(2, "0")}:00`;
  }

  if (digits.length === 3 || digits.length === 4) {
    const normalized = digits.padStart(4, "0");
    const hours = Math.min(Number(normalized.slice(0, 2)), 23);
    const minutes = Math.min(Number(normalized.slice(2, 4)), 59);
    return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
  }

  const match = raw.match(/^(\d{1,2})[:.\- ](\d{1,2})$/);
  if (match) {
    const hours = Math.min(Number(match[1]), 23);
    const minutes = Math.min(Number(match[2]), 59);
    return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
  }

  return raw.slice(0, 5);
}

function updateScheduleTime(employeeId, day, field, value) {
  db.scheduleTimes = db.scheduleTimes || {};
  db.scheduleTimes[employeeId] = db.scheduleTimes[employeeId] || {};
  db.scheduleTimes[employeeId][day] = {
    ...getScheduleTime(employeeId, day),
    [field]: normalizeScheduleTime(value),
  };
  saveDB();
  render();
  showToast("Время смены сохранено");
}

function focusScheduleTimeInput(event, cell) {
  event.preventDefault();
  event.stopPropagation();
  const input = cell.querySelector(".schedule-arrival-input");
  if (!input) return;
  input.focus();
  input.select?.();
}

function updateNightPercent(value) {
  db.settings = db.settings || {};
  db.settings.nightPercent = Number(value) || 0;
  saveDB();
  render();
  showToast("Процент ночных смен сохранён");
}

function updateMealPortion(value) {
  db.settings = db.settings || {};
  db.settings.mealPortion = Number(value) || 0;
  saveDB();
  render();
  showToast("Стоимость порции сохранена");
}

function updateMachineCoefficient(machineId, value) {
  const machine = getMachine(machineId);
  if (!machine) return;
  machine.coefficient = Number(value) || 0;
  saveDB();
  render();
  showToast("Коэффициент сохранён");
}

function openDrawer() {
  const drawer = document.getElementById("drawer");
  const content = document.getElementById("drawerContent");

  content.innerHTML = `
    <div class="detail-card" style="margin-bottom:14px">
      <h3>Ночные смены</h3>
      <div class="night-percent-card">
        <div>
          <div class="coeff-name">Процент оплаты за ночные смены</div>
          <div class="coeff-unit">Формула: средняя сдельная × ночные смены × процент</div>
        </div>
        <div class="percent-input-wrap">
          <input type="number" value="${getNightPercent()}" min="0" max="300" step="1" onchange="updateNightPercent(this.value)" />
          <span>%</span>
        </div>
      </div>
    </div>

    <div class="detail-card" style="margin-bottom:14px">
      <h3>Питание</h3>
      <div class="night-percent-card">
        <div>
          <div class="coeff-name">За порцию</div>
          <div class="coeff-unit">Формула: количество смен × стоимость порции. Даже половина смены считается как целая порция.</div>
        </div>
        <div class="percent-input-wrap money-portion-input">
          <input type="number" value="${getMealPortion()}" min="0" step="100" onchange="updateMealPortion(this.value)" />
          <span>₸</span>
        </div>
      </div>
    </div>

    <div class="detail-card">
      <h3>Коэффициенты рабочих мест</h3>
      <p class="cell-sub drawer-note">Коэффициент влияет на сдельную оплату сотрудников. Его можно менять здесь, без лишнего списка сотрудников.</p>
      <div class="coeff-grid drawer-coeff-grid">
        ${db.machines.map((machine) => `
          <div class="coeff-card">
            <div>
              <div class="coeff-name">${machine.name}</div>
              <div class="coeff-unit">единица: ${machine.unit}</div>
            </div>
            <input type="number" value="${machine.coefficient}" step="0.1" min="0" onchange="updateMachineCoefficient('${machine.id}', this.value)" />
          </div>
        `).join("")}
      </div>
    </div>
  `;

  drawer.classList.add("open");
  drawer.setAttribute("aria-hidden", "false");
}

function closeDrawer() {
  const drawer = document.getElementById("drawer");
  drawer.classList.remove("open");
  drawer.setAttribute("aria-hidden", "true");
}


async function downloadPagePDF() {
  const activeView = document.querySelector(".view.active");
  const target = document.querySelector(".app-shell") || document.body;
  const fileName = `analytics-${(activeView?.id || "page")}-${new Date().toISOString().slice(0, 10)}.pdf`;

  if (!window.html2canvas || !window.jspdf?.jsPDF) {
    document.body.classList.add("exporting-pdf");
    window.print();
    setTimeout(() => document.body.classList.remove("exporting-pdf"), 600);
    showToast("Библиотеки PDF не загрузились, открыт режим печати");
    return;
  }

  showToast("Готовлю нормальный PDF всей страницы...");

  const previousScrollX = window.scrollX;
  const previousScrollY = window.scrollY;
  const previousTitle = document.title;
  document.title = fileName.replace(".pdf", "");
  document.body.classList.add("exporting-pdf");
  window.scrollTo(0, 0);

  const tables = [...document.querySelectorAll(".table-wrap")];
  const savedTableStyles = tables.map((table) => ({
    element: table,
    style: table.getAttribute("style") || "",
  }));

  tables.forEach((table) => {
    table.style.overflow = "visible";
    table.style.maxHeight = "none";
    table.style.width = `${table.scrollWidth}px`;
  });

  try {
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));

    const width = Math.ceil(Math.max(target.scrollWidth, target.offsetWidth, document.documentElement.scrollWidth));
    const height = Math.ceil(Math.max(target.scrollHeight, target.offsetHeight, document.documentElement.scrollHeight));

    const canvas = await window.html2canvas(target, {
      scale: Math.min(2, window.devicePixelRatio || 1.5),
      useCORS: true,
      allowTaint: true,
      backgroundColor: "#0f172a",
      width,
      height,
      windowWidth: width,
      windowHeight: height,
      scrollX: 0,
      scrollY: 0,
      logging: false,
      ignoreElements: (element) => element.classList?.contains("toast") || element.classList?.contains("drawer"),
    });

    const orientation = canvas.width >= canvas.height ? "l" : "p";
    const pdf = new window.jspdf.jsPDF({
      orientation,
      unit: "px",
      format: [canvas.width, canvas.height],
      compress: true,
      hotfixes: ["px_scaling"],
    });

    pdf.addImage(canvas.toDataURL("image/png"), "PNG", 0, 0, canvas.width, canvas.height, undefined, "FAST");
    pdf.save(fileName);
    showToast("PDF скачан полностью, без обрезки");
  } catch (error) {
    console.error(error);
    showToast("Не получилось собрать PDF автоматически, открыт режим печати");
    window.print();
  } finally {
    savedTableStyles.forEach(({ element, style }) => {
      if (style) element.setAttribute("style", style);
      else element.removeAttribute("style");
    });
    document.body.classList.remove("exporting-pdf");
    document.title = previousTitle;
    window.scrollTo(previousScrollX, previousScrollY);
  }
}

function empty(text) {
  return `<div class="empty-state">${text}</div>`;
}

function showToast(text) {
  const toast = document.getElementById("toast");
  toast.textContent = text;
  toast.classList.add("show");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove("show"), 2200);
}

document.addEventListener("DOMContentLoaded", () => {
  injectSchedulePrettyStyles();

  document.querySelectorAll(".tab-button").forEach((button) => {
    button.addEventListener("click", () => setView(button.dataset.view));
  });

  document.getElementById("selectedMonth").addEventListener("change", (event) => {
    db.filters.month = event.target.value || "2026-05";
    saveDB();
    render();
  });

  const closeDrawerButton = document.getElementById("closeDrawer");
  if (closeDrawerButton) closeDrawerButton.addEventListener("click", closeDrawer);

  const drawer = document.getElementById("drawer");
  if (drawer) {
    drawer.addEventListener("click", (event) => {
      if (event.target.id === "drawer") closeDrawer();
    });
  }

  render();
});

/* Делаем функции доступными для onclick в HTML */
window.setView = setView;
window.openEmployee = openEmployee;
window.openMachine = openMachine;
window.openDrawer = openDrawer;
window.closeDrawer = closeDrawer;
window.selectDay = selectDay;
window.selectMachineFilter = selectMachineFilter;
window.showSegmentInfo = showSegmentInfo;
window.updateSalary = updateSalary;
window.updateMachineCoefficient = updateMachineCoefficient;
window.updateMealPortion = updateMealPortion;
window.toggleTraineeStatus = toggleTraineeStatus;
window.downloadPagePDF = downloadPagePDF;
window.updateScheduleTime = updateScheduleTime;
window.focusScheduleTimeInput = focusScheduleTimeInput;
window.cycleShift = cycleShift;
