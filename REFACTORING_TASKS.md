# PURL Refactoring Tasks

**Maqsad:** Production-ready, Enterprise-level kod sifatiga yetkazish
**Boshlangan:** 2025-12-15

---

## Task Holatlari
- [ ] Bajarilmagan
- [x] Bajarilgan
- [~] Jarayonda

---

## FAZA 1: Arxitektura Refaktoring

### 1.1 Backend (Perl)

| # | Task | Holat | Sana |
|---|------|-------|------|
| 1 | Server.pm dan Middleware funksiyalarini ajratish | [x] | 2025-12-15 |
| 2 | Server.pm dan utility funksiyalarini ajratish | [x] | 2025-12-15 |
| 3 | Alert modullaridagi duplikatlarni Base.pm ga ko'chirish | [x] | 2025-12-15 |
| 4 | ClickHouse.pm da result processing helper yaratish | [x] | 2025-12-15 |
| 5 | Middleware.pm ni Server.pm bilan integratsiya qilish | [x] | 2025-12-15 |
| 6 | Server.pm dagi route'larni tozalash | [x] | 2025-12-15 |

### 1.2 Frontend (Svelte)

| # | Task | Holat | Sana |
|---|------|-------|------|
| 7 | Utility funksiyalarni utils.js ga ko'chirish | [x] | 2025-12-15 |
| 8 | SettingsPage.svelte ni komponentlarga bo'lish | [x] | 2025-12-15 |
| 9 | LogTable.svelte ni komponentlarga bo'lish | [x] | 2025-12-15 |
| 10 | API calls uchun markaziy modul yaratish | [x] | 2025-12-15 |

---

## FAZA 2: Kod Duplikatsiyalarni Yo'qotish

| # | Task | Holat | Sana |
|---|------|-------|------|
| 11 | formatNumber() duplikatlarini yo'qotish | [x] | 2025-12-15 |
| 12 | formatTime() duplikatlarini yo'qotish | [x] | 2025-12-15 |
| 13 | CRUD pattern duplikatlarini yo'qotish | [x] | 2025-12-15 |
| 14 | Modal state management standardlashtirish | [x] | 2025-12-15 |

---

## FAZA 3: Xavfsizlik

| # | Task | Holat | Sana |
|---|------|-------|------|
| 15 | Plaintext password supportni olib tashlash | [x] | 2025-12-15 |
| 16 | WebSocket origin validationni qo'shish | [x] | 2025-12-15 |

---

## FAZA 4: Testing

| # | Task | Holat | Sana |
|---|------|-------|------|
| 17 | Perl unit test strukturasini yaratish | [x] | 2025-12-15 |
| 18 | Frontend test strukturasini yaratish | [x] | 2025-12-15 |

---

## Har bir task uchun qadamlar:
1. O'zgartirish qilish
2. `make lint` - lintlarni tekshirish
3. `docker compose build` - build qilish
4. `make up` - local test
5. REFACTORING_TASKS.md ni yangilash

---

## Changelog

### 2025-12-15
- Task fayl yaratildi
- Audit yakunlandi
- **FAZA 1.1 Backend (Perl) yakunlandi:**
  - Task 1: Server.pm dan duplikat `_check_auth` funksiyasi o'chirildi, Middleware funksiyalari ishlatildi
  - Task 2: Purl::Utils modul yaratildi (`format_duration`, `parse_time_range`, `epoch_to_iso`, `url_encode`)
  - Task 3: Alert modullaridan `_http`, `_json`, `send_test` duplikatlari Base.pm ga ko'chirildi
  - Task 4: ClickHouse.pm da `_process_log_results` helper yaratildi
  - Task 5: Server.pm Middleware funksiyalarini to'g'ri ishlatadigan bo'ldi
  - Task 6: Server.pm dagi duplikat kommentlar o'chirildi
- Barcha Perl lintlar muvaffaqiyatli o'tdi
- Docker build muvaffaqiyatli yakunlandi
- **FAZA 1.2 Frontend (Svelte) qisman yakunlandi:**
  - Task 7: `web/src/lib/utils.js` yaratildi (escapeHtml, formatNumber, formatBytes, formatTime, formatTimestamp, formatUptime, getLevelColor, highlightText, highlightPattern, debounce, throttle, memoize, downloadBlob)
  - Task 10: `web/src/lib/api.js` yaratildi (markazlashtirilgan API calls, fetchCsrfToken, searchLogs, fetchStats, fetchTrace, fetchSettings, saveNotification, va boshqalar)
  - Task 11, 12: formatNumber va formatTime duplikatlari lib/utils.js ga ko'chirildi
  - stores/logs.js yangilandi - lib/utils.js va lib/api.js dan re-export
  - LogTable.svelte, AnalyticsPage.svelte, SettingsPage.svelte yangilandi
- Frontend build muvaffaqiyatli yakunlandi
- **FAZA 1.2 Frontend to'liq yakunlandi:**
  - Task 9: LogTable.svelte ni komponentlarga bo'lindi (1062 -> 473 qator)
    - `logtable/TableToolbar.svelte` - ustun sozlamalari menyusi
    - `logtable/EmptyState.svelte` - bo'sh holat ko'rsatish
    - `logtable/LogDetailPanel.svelte` - log tafsilotlari paneli
    - `logtable/ContextPanel.svelte` - kontekst ko'rsatish paneli
- **FAZA 3 Xavfsizlik yakunlandi:**
  - Task 15: Plaintext password support allaqachon olib tashlangan (Middleware.pm faqat hash+salt formatini qo'llab-quvvatlaydi)
  - Task 16: WebSocket `/api/logs/stream` endpointiga origin validation qo'shildi
- **FAZA 2 qisman yakunlandi:**
  - Task 13: CRUD pattern duplikatlarini yo'qotish
    - `lib/api.js` ga SavedSearches va Alerts API funksiyalari qo'shildi (fetchSavedSearches, createSavedSearch, deleteSavedSearch, fetchAlerts, createAlert, updateAlert, deleteAlert, toggleAlertEnabled, checkAlerts)
    - `SavedSearches.svelte` yangilandi - markazlashtirilgan API ishlatadi
    - `AlertsPanel.svelte` yangilandi - markazlashtirilgan API ishlatadi
    - `const API_BASE = '/api'` duplikatlari o'chirildi
  - Task 14: Modal state management standardlashtirildi
    - `ui/Modal.svelte` - reusable modal komponent (Escape key, overlay click, header/body/footer slots)
    - `ui/Button.svelte` - reusable button komponent (default, primary, danger variants)
    - `SavedSearches.svelte` yangilandi - Modal va Button komponentlar ishlatadi
    - `AlertsPanel.svelte` yangilandi - Modal va Button komponentlar ishlatadi
    - Duplikat modal CSS olib tashlandi (~100 qator)
- **FAZA 2 to'liq yakunlandi**
- **FAZA 4 to'liq yakunlandi:**
  - Task 17: Perl unit test strukturasi yaratildi
    - `t/00_utils.t` - Purl::Utils testlari (format_duration, parse_time_range, epoch_to_iso, url_encode)
    - `t/01_middleware.t` - Xavfsizlik testlari (CSRF token, password hashing)
    - `t/02_config.t` - Konfiguratsiya testlari (get, env override, defaults)
    - Makefile `test` target yangilandi
  - Task 18: Frontend test strukturasi yaratildi
    - `web/vitest.config.js` - Vitest konfiguratsiyasi (jsdom environment)
    - `web/src/lib/utils.test.js` - 44 ta test (escapeHtml, sanitizeHtml, formatNumber, formatBytes, formatTimestamp, formatTime, formatUptime, getLevelColor, highlightText, highlightPattern, debounce, throttle)
    - jsdom dev dependency qo'shildi
    - `npm test` va `npm run test:watch` skriptlari
- **Qo'shimcha Route modullar yaratildi (future use):**
  - `lib/Purl/API/Routes/Settings.pm` - Settings management routes
  - `lib/Purl/API/Routes/Config.pm` - Server configuration routes
  - `lib/Purl/API/Routes/Patterns.pm` - Log pattern analysis routes
  - `lib/Purl/API/Routes/SavedSearches.pm` - Saved searches CRUD
  - `lib/Purl/API/Routes/WebSocket.pm` - WebSocket live tail routes
