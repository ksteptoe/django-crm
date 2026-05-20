# django-crm — Developer Architecture & Orientation Guide

Audience: an expert Python programmer who is **not** a Django expert and is new to this
codebase. This skips Python basics and explains Django *as this project actually wires it*,
with `file:line` citations you can click. When something is convention vs. a local quirk,
it says so. Verified against the code at the commit you're reading; if a citation drifts,
trust the code.

---

## 1. Big picture

django-crm is an **admin-centric** CRM: there is almost no bespoke front-end. The UI *is*
Django's admin, but mounted on a **custom `AdminSite`** with the app's own index, sidebar,
counters, and login. Think "Django admin as the whole application," not "admin bolted onto
a separate site."

Two facts dominate everything else, and both will mislead you if you read the code naively:

1. **Login and the user-facing app live on a custom admin site (`crm_site`), not the stock
   one.** The stock `admin.site` also exists, at a different secret URL, mostly for the
   superuser. (`crm/site/crmadminsite.py:105`, `crm/urls.py:22`)
2. **`AppConfig.ready()` starts long-running background threads** (IMAP email import,
   mass-mail sender, reminders, snapshots) at process start — in *every* process, including
   `manage.py` commands. Several grab `tendo` single-instance lock files. This is the source
   of the cross-user `manage.py` landmine (§7). (`crm/apps.py:12`, `massmail/apps.py:11`, …)

### Django concepts as used here

| Concept | Stock Django | In this codebase |
|---|---|---|
| Settings module | one `settings.py` | base `webcrm/settings.py` **+** per-app `*/settings.py` star-imported in **+** `webcrm/local_settings.py` host override star-imported last (§3) |
| Root urlconf | flat `urlpatterns` | everything app-facing wrapped in `i18n_patterns` (forces `/en/…`) and behind secret prefixes (§2) |
| Admin site | `django.contrib.admin.site` | a custom `crm_site` subclass owns the app + login; stock `admin.site` coexists at another URL (§2) |
| `AppConfig.ready()` | usually empty / signal wiring | starts daemon threads + queues for email/mailing/reminders (§7) |
| Auth roles | groups you check ad hoc | request-time role flags injected by `UserMiddleware` (`request.user.is_manager`, etc.) (`common/utils/usermiddleware.py:74`) |
| Static/media | `runserver` serves them | gunicorn never serves them; Caddy does, from paths outside the checkout (§3, §5) |

### The Django apps and what each owns

`INSTALLED_APPS` is `webcrm/settings.py:104-122`. The app-facing ones:

| App | Responsibility | Models layout |
|---|---|---|
| `crm` | Core domain: Company, Contact, Lead, Request, Deal, Payment, Shipment, Product, CrmEmail, Country, Currency, Tag. The custom admin site lives here. | `crm/models/` package, one file per entity |
| `common` | Cross-cutting: `UserProfile`, `Reminder`, the base `AdminSite`, both custom middlewares, notification email sender, signal handlers. | `common/models.py` (single file) |
| `massmail` | Mass mailing: `MailingOut`, `EmlMessage`, SMTP/OAuth2 sending, the sender thread. | `massmail/models/` package |
| `tasks` | `Task` and `Memo` workflow. | `tasks/models/` package |
| `analytics` | `IncomeStat`, `RequestStat`; monthly snapshot saver thread. | `analytics/models.py` |
| `chat` | In-record chat/comments. | `chat/models.py` |
| `help` | DB-backed help pages (`Page`), surfaced as context-sensitive help links. | `help/models.py` |
| `quality` | Quality/reference data. | `quality/models/` |
| `settings` | Admin-editable config: `PublicEmailDomain`, `StopPhrase`, etc. | `settings/models.py` |
| `voip` | VoIP click-to-call hooks; has its own non-prefixed URLs. | `voip/models.py` |

Which apps appear on the index page and in what order is **data-driven** by
`APP_ON_INDEX_PAGE` / `MODEL_ON_INDEX_PAGE` (`webcrm/settings.py:212-246`), consumed by the
custom site's `index()` (`common/site/crmsite.py:84-115`).

---

## 2. How a request flows

```
HTTPS :443
  └─ Caddy (TLS termination; serves /static/* and /media/* itself via file_server)
       └─ reverse_proxy → 127.0.0.1:8000
            └─ gunicorn (3 sync workers)  →  webcrm.wsgi:application
                 └─ Django MIDDLEWARE stack (settings.py:124-135)
                      • SecurityMiddleware
                      • SessionMiddleware
                      • LocaleMiddleware      ← reads the /<lang>/ URL prefix, activates it
                      • CommonMiddleware
                      • CsrfViewMiddleware
                      • AuthenticationMiddleware
                      • MessageMiddleware
                      • XFrameOptionsMiddleware
                      • AdminRedirectMiddleware  ← bounces non-superusers off stock admin
                      • UserMiddleware           ← injects role flags + triggers email import
                 └─ ROOT_URLCONF = webcrm.urls (settings.py:137)
```

### Root urlconf — `webcrm/urls.py`

Two tiers. **Non-prefixed, non-i18n** routes first (`webcrm/urls.py:14-22`): `favicon.ico`,
`voip/`, `OAuth-2/authorize/`. Then media via `static()` (`:24-26`, **only active under
`DEBUG`** — see §7), then `rosetta/` if installed (`:28-31`).

The app itself is wrapped in **`i18n_patterns`** (`webcrm/urls.py:33-40`), which prepends a
language segment (`/en/`, `/fr/`, …) to **every** URL inside it. So all CRM/admin URLs carry
a language prefix; `LocaleMiddleware` (`settings.py:127`) reads it back. Inside that block:

| Pattern (after `/en/`) | Include | Resolves to |
|---|---|---|
| `SECRET_CRM_PREFIX` | `common.urls` | shared CRM routes |
| `SECRET_CRM_PREFIX` | `crm.urls` → mounts `crm_site` | **the user-facing app + login** |
| `SECRET_CRM_PREFIX` | `massmail.urls` | mailing routes |
| `SECRET_CRM_PREFIX` | `tasks.urls` | task/memo routes |
| `SECRET_ADMIN_PREFIX` | `admin.site.urls` | **stock** Django admin |
| `contact-form/<uuid>/` | `crm.views.contact_form` | public lead-capture form |

The three secret prefixes are defined in base settings as throwaway placeholders
(`webcrm/settings.py:199-201` → `123/`, `456-admin/`, `789-login/`) and **overridden** by
real, deployment-specific values in `local_settings.py:11-13` (gitignored). With those
overrides applied, the URL structure is:

- App root: `https://<your-domain>/en/<SECRET_CRM_PREFIX>/`
- **Login**: `https://<your-domain>/en/<SECRET_CRM_PREFIX>/<SECRET_LOGIN_PREFIX>`  ← see below for why
- Stock admin: `https://<your-domain>/en/<SECRET_ADMIN_PREFIX>`

The real prefix values are intentionally kept out of this committed doc (they're the whole
point of the obfuscation). Read them from `local_settings.py`, or via
`make shell` → `settings.SECRET_CRM_PREFIX`.

### The custom admin site (the important part)

`crm.urls` mounts the custom site at the include's root: `path('', crm_site.urls)`
(`crm/urls.py:22`). Since `crm.urls` is included under `SECRET_CRM_PREFIX`
(`webcrm/urls.py:35`), the custom site effectively *is* the app root.

`crm_site = CrmAdminSite(name='site')` (`crm/site/crmadminsite.py:105`).
`CrmAdminSite` → `BaseSite` → `django.contrib.admin.AdminSite`
(`crm/site/crmadminsite.py:25`, `common/site/crmsite.py:75`).

**Login is relocated, not stock.** `CrmAdminSite.get_urls()` takes the default admin URLs,
**pops the `login` route**, and re-adds it at `SECRET_LOGIN_PREFIX`
(`crm/site/crmadminsite.py:27-32, 58-61`). That's why the live login URL is
`SECRET_CRM_PREFIX + SECRET_LOGIN_PREFIX`, not a stock `/admin/login/`. The same `get_urls()`
also adds the Excel-importer routes `import_contacts/`, `import-companies/`, `import_leads/`
(`:33-57`).

**Two admin sites coexist — and they're two *views*, not two apps.** Both are
`django.contrib.admin.AdminSite` instances rendered with the same templates, so they look
near-identical, and **most CRM models are registered on both** (e.g. Company/Contact/Deal/…
appear at `crm/admin.py:453-472` on `admin.site` *and* `:474-485` on `crm_site`; the other
apps' `admin.py` do the same). The difference is curation and audience, not the data:

| | `crm_site` (`SECRET_CRM_PREFIX`) | `admin.site` (`SECRET_ADMIN_PREFIX`) |
|---|---|---|
| Role | curated, day-to-day operator UI | raw full Django admin / superuser backdoor |
| Model set | a **subset** | the **superset** — everything `crm_site` has, plus more |
| Index page | only the 6 apps in `APP_ON_INDEX_PAGE`, with live count badges (`common/site/crmsite.py:152+`) | all registered apps via stock `get_app_list` |
| `ModelAdmin` classes | rich custom subclasses (e.g. `companyadmin.CompanyAdmin`) | often plainer classes |
| `delete_selected` | disabled (`crm/site/crmadminsite.py:106`) | enabled |
| Header text | `PROJECT_NAME` → "Django-CRM" (`crmsite.py:76`) | `ADMIN_HEADER` → "ADMIN" (`crmsite.py:31-33`) |

**Models that live ONLY on the stock admin** (your tell for which site you're on): CRM
reference tables `Country`, `Industry`, `LeadSource`, `ProductCategory`, `ClientType`,
`ClosingReason`, `Rate`, `Stage`; internals `Department`, `MassmailSettings`,
`EmlAccountsQueue`, `MassContact`, `IncomeStatSnapshot`, `Permission`, `TaskStage`,
`ProjectStage`, voip `Connection`; and Django's built-in **Users / Groups / Sites**
(auto-registered on the default site only). Quick test: if you see Users/Groups/Stages/
Countries → you're on the stock admin; if you see count badges and only 6 apps → `crm_site`.

`AdminRedirectMiddleware` keeps non-superusers out of the stock admin: if the path contains
`SECRET_ADMIN_PREFIX` and the user isn't a superuser, it rewrites the prefix to
`SECRET_CRM_PREFIX` and redirects (`common/utils/admin_redirect_middleware.py:11-18`). So the
stock admin is effectively superuser-only; everyone else is funneled to `crm_site`.

### The per-request side effect you must know about

`UserMiddleware.__call__` runs on every request and, for an authenticated user, sets
timezone, role flags, and department, then calls
`apps.get_app_config('crm').import_emails(request.user)`
(`common/utils/usermiddleware.py:17-25`). That hands the user to the IMAP import thread
started in `crm/apps.py:ready()` (`crm/apps.py:37-38`). **Translation:** ordinary page loads
kick off email-import work on background threads. The request path is coupled to those
threads existing — see §7.

---

## 3. Settings layering

Effective settings are assembled in three layers, all in `webcrm/settings.py`:

1. **Per-app settings, star-imported at the top** (`webcrm/settings.py:6-10`):
   `from crm.settings import *`, then `common`, `tasks`, `voip`, and `datetime_settings`.
   These hold app-specific constants — e.g. the Excel import/export column lists and IMAP
   tuning live in `crm/settings.py` (`CONTACT_COLUMNS`, `IMAP_NOOP_PERIOD`, …,
   `crm/settings.py:9-64`).
2. **Base Django + CRM settings** — the body of `webcrm/settings.py`.
3. **Host overrides, star-imported last** (`webcrm/settings.py:317-321`):
   `from .local_settings import *` inside a `try/except ImportError`. Because it's last, it
   **wins**.

What `local_settings.py` actually changes (it's gitignored — `.gitignore:135` — and is the
only place real secrets/prod config live):

| Setting | Base default (`settings.py`) | Prod (`local_settings.py`) |
|---|---|---|
| `SECRET_KEY` | published dummy (`:21`) | real key (`:4`) |
| `DEBUG` | `True` (`:60`) | `False` (`:6`) |
| `ALLOWED_HOSTS` | `localhost`,`127.0.0.1` (`:24`) | adds your prod host (`:8`) |
| `SECRET_*_PREFIX` | placeholders (`:199-201`) | real prefixes (`:11-13`) |
| `STATIC_ROOT`/`MEDIA_ROOT` | inside checkout (`:175,178`) | `/opt/django-crm/{static,media}` (`:16-17`) |
| `DATABASES` | bogus sqlite stub (`:27-45`) | sqlite at `/opt/django-crm/db.sqlite3` (`:23-28`) |
| TLS/proxy | off | `CSRF_TRUSTED_ORIGINS`, `SECURE_PROXY_SSL_HEADER` (`:21-22`) |

**Read the effective values** (don't guess from the file) with the Django shell, which the
Makefile runs as the `django` account so it can open the DB:

```bash
make shell
>>> from django.conf import settings
>>> settings.SECRET_CRM_PREFIX, settings.DEBUG, settings.ALLOWED_HOSTS
```

---

## 4. "Where do I change X?"

| I want to… | Edit | Note |
|---|---|---|
| Add/alter a model field | `crm/models/<entity>.py` (or the app's `models.py`) | then migrate — §6 |
| Change how a model looks/behaves in the app UI | the `ModelAdmin` under `crm/site/` registered on **`crm_site`** (`crm/admin.py:474-485`) | not the stock-admin class on `admin.site` |
| Change a reference/config table's admin (City, Country, Rate, Stage…) | the `ModelAdmin` on **`admin.site`** (`crm/admin.py:453-472`) | these aren't on `crm_site` |
| Add a custom page/view in the app | add a view, then a route in the app's `urls.py` (e.g. `crm/urls.py:21`) | wrap staff-only views in `staff_member_required` like the neighbors |
| Change a URL prefix (crm/admin/login) | `local_settings.py:11-13` | base `settings.py:199-201` is just placeholders |
| Move the login URL | `SECRET_LOGIN_PREFIX`; relocation logic at `crm/site/crmadminsite.py:58-61` | |
| Change which apps/models show on the home page | `APP_ON_INDEX_PAGE` / `MODEL_ON_INDEX_PAGE` (`webcrm/settings.py:212-246`) | consumed by `common/site/crmsite.py:84` |
| Change the index counters/badges | `common/site/crmsite.py:152-288` | per-app `get_counters` |
| Add/modify a template | `templates/` (project, `settings.py:142`) or `<app>/templates/` | `APP_DIRS=True` (`:143`) |
| Change email import behavior | `crm/utils/import_emails.py`, `crm/utils/manage_imaps.py`; started in `crm/apps.py:13-28` | runs on background threads |
| Change mass-mail sending | `massmail/utils/sendmassmail.py`; started in `massmail/apps.py:11-17` | tendo-locked |
| Change reminders / monthly snapshots | `common/utils/reminders_sender.py` / `analytics/utils/monthly_snapshot_saving.py`; started in the apps' `ready()` | tendo-locked |
| Add a role/permission flag | `common/utils/usermiddleware.py:74-88` (`set_user_groups`) | flags hang off `request.user` |
| Tune IMAP / import columns | `crm/settings.py` (`:9-64`) | star-imported into global settings |

---

## 5. The reload / deploy model  *(read this before you "just edit and refresh")*

**There is no auto-reload.** In normal Django dev, `manage.py runserver` watches files and
restarts on save. Production here does **not** use `runserver`:

- It runs under **gunicorn**, launched by the **systemd unit** `django-crm.service`:
  `ExecStart=/opt/django-crm/venv/bin/gunicorn -c /opt/django-crm/gunicorn.conf.py
  webcrm.wsgi:application`, as `User=django`, `WorkingDirectory=/opt/django-crm/app`,
  `Restart=on-failure` (verified via `systemctl cat django-crm`).
- `gunicorn.conf.py` is five lines: `bind 127.0.0.1:8000`, `workers = 3`, access/error logs,
  `loglevel info`. **No `reload`, no `preload_app`.** So workers load your code once at boot
  and never re-read it.
- The code tree is read-only to the service account (`750`/`640`, `kevin:django` — see repo
  `CLAUDE.md`), so even `.pyc` files aren't rewritten. Nothing about a file edit reaches the
  running workers on its own.

**Therefore the loop is: edit → restart.**

```bash
# edit code as kevin (you own the tree)
make restart        # = sudo systemctl restart django-crm   (Makefile:163-165)
```

`make restart` does a full gunicorn restart (brief connection drop; `Restart=on-failure`
will also resurrect it if it crashes). There's no graceful `HUP`-reload target — restart is
the supported path.

### Who runs what (the identity split)

Two ways to invoke `manage.py`, both wired in the Makefile (`Makefile:34-38`):

| Class of command | Runs as | Make targets |
|---|---|---|
| Reads/writes the **DB or media** (`migrate`, `collectstatic`, `loaddata`, `createsuperuser`, `dumpdata`, `shell`, dev `serve`) | `django` via `sudo -u django` (`MANAGE_DJ`) | `make migrate / collectstatic / loaddata / superuser / dumpdata / shell / serve` |
| **Read-only or code-only** (`check`, `test`, `makemigrations`) | you, `kevin`, with a private `TMPDIR` (`MANAGE`) | `make check / test / makemigrations` |

`makemigrations` runs as **you** because it writes migration files into the code tree (which
`kevin` owns) and doesn't touch the DB (`Makefile:125-131`). `migrate` runs as **django**
because it writes the DB (`Makefile:141-142`). The private `TMPDIR` for kevin's runs exists
to dodge the tendo lock landmine — §7.

### What each kind of change requires

| Change | Steps |
|---|---|
| Python/template/code edit | `make restart` |
| Static asset (CSS/JS/img) | `make collectstatic` (as django) → published to `/opt/django-crm/static`, served by Caddy. No restart needed. |
| Model change | `make makemigrations` (kevin) → `make migrate` (django) → `make restart` |
| Dependency change | `make bootstrap` (installs into the django-owned venv) → `make restart` |

Static and media are **not** served by gunicorn — `STATIC_ROOT`/`MEDIA_ROOT` point outside
the checkout (`local_settings.py:16-17`) and Caddy serves those paths (per repo `CLAUDE.md`;
the Caddyfile itself is ops config, not in this repo). Note the `static(MEDIA_URL, …)` line
in `webcrm/urls.py:24-26` only serves media when `DEBUG` is on, so it's inert in prod.

---

## 6. Models, ORM, migrations

- **Layout varies by app.** Larger apps use a `models/` *package* with one module per entity
  re-exported through `__init__.py` (e.g. `crm/models/company.py`, `contact.py`, `deal.py`,
  `request.py`, `payment.py`, `crmemail.py`, …); smaller apps use a single `models.py`
  (`common`, `analytics`, `chat`, `help`, `settings`, `voip`).
- **Migration workflow** (Makefile-driven, identity-aware):
  1. `make makemigrations` — as **kevin**; writes migration files into the code tree. The
     target deliberately prints a warning and sleeps, because this fork ships upstream's
     migrations and you should only regenerate when you *intentionally* changed a model
     (`Makefile:127-131`; echoed by `CLAUDE.md`'s "Don't `makemigrations` unless…").
  2. `make migrate` — as **django**; applies to the DB.
  3. `make restart` — load the new model code into the workers.
- **Database:** SQLite at `/opt/django-crm/db.sqlite3`, mode `640 django:django`. Because
  `kevin` can't read it directly, any DB-reading `manage.py` command must go through the
  `django` account — which is exactly why `make dumpdata` and `make shell` use `MANAGE_DJ`
  (`Makefile:136-155`). Postgres/MySQL are stubbed in base settings but unused; don't switch
  engines without being asked (`CLAUDE.md`).

---

## 7. Gotchas / landmines (each grounded in code)

1. **`tendo` single-instance locks break cross-user `manage.py`.** Several `AppConfig.ready()`
   hooks instantiate `tendo.SingleInstance` lock files in `TMPDIR` (default `/tmp`), named by
   entry point, on **every** process start — including `manage.py`. The deploy created those
   `/tmp` lock files as `django`, so a `kevin`-run `manage.py` can't reopen them and dies with
   `PermissionError` (even `check`). The real holders are:
   - `massmail` → `SendMassmail` (`massmail/apps.py:11-17`)
   - `analytics` → `MonthlySnapshotSaving` (`analytics/apps.py:13-20`, guarded by `not TESTING`)
   - `common` → `RemindersSender` (`common/apps.py:20-26`, guarded by `not TESTING`)
   - `crm` → `RatesLoader` (`crm/apps.py:29-35`, guarded by `not TESTING`)

   **Fix:** the Makefile points kevin's runs at a private lock dir
   (`TMPDIR=$HOME/.cache/crm-locks`, `Makefile:32,37`), or run as django via `MANAGE_DJ`.
   ⚠️ The repo `CLAUDE.md` currently says the locks come from "massmail + tasks" — that's
   stale: `tasks/apps.py` has **no `ready()`** and grabs no lock. The list above is what the
   code actually does.

2. **`ready()` starts daemon threads in every process, some unconditionally.** Beyond the
   locked ones above, `crm/apps.py:18-28` starts four IMAP/email threads + queues, and
   `common/apps.py:18-19` starts `NotifEmailSender` — both with **no `TESTING` guard and no
   lock**. So even short CLI commands spin these up. Combined with landmine #4, this is why
   `manage.py` feels heavy.

3. **Page loads trigger email import.** `UserMiddleware` calls `crm` config's
   `import_emails(request.user)` on every authenticated request
   (`common/utils/usermiddleware.py:24-25` → `crm/apps.py:37-38`). The request path depends on
   the import threads from #2 being alive. If you refactor `crm/apps.py:ready()`, you can
   silently break normal browsing, not just a cron job.

4. **`local_settings` import failure fails *open*, not loud.** `settings.py:317-321` swallows
   `ImportError` silently. If `local_settings.py` is missing or has a typo that makes it
   unimportable, Django keeps running on the **published** `SECRET_KEY`, `DEBUG=True`, and the
   placeholder URL prefixes — an insecure prod with no error. Treat any "secret URLs reverted
   to `123/`" symptom as a `local_settings` import failure first.

5. **Stale `LOGIN_URL`.** `settings.py:101` sets `LOGIN_URL = '/admin/login/'`, but the real
   login is the prefixed `crm_site` login (§2). Anything relying on `LOGIN_URL` for an
   auth-required redirect would point at the wrong place. Harmless so far (superusers use the
   stock admin; the `crm_site` flow doesn't depend on it), but fix it if a redirect ever
   misbehaves.

6. **Every app URL carries a language prefix.** `i18n_patterns` (`webcrm/urls.py:33`) means
   reversed URLs include `/en/` automatically, but any hand-built URL or `curl` must include
   it. The routes **outside** `i18n_patterns` (favicon, `voip/`, `OAuth-2/authorize/`,
   `contact-form/<uuid>/`, media) have **no** language prefix — don't add one.

7. **Two admin sites, overlapping registrations.** A model can be registered on both
   `admin.site` and `crm_site`, sometimes with **different** `ModelAdmin` classes
   (`crm/admin.py:453-472` vs `:474-485`). When you "change the admin," confirm which site
   you're editing — the user-facing one is `crm_site`.

8. **`delete_selected` is globally disabled on `crm_site`** (`crm/site/crmadminsite.py:106`).
   If a bulk delete "doesn't appear," that's why.

---

## 8. Unverified / open items

- **Caddy config** (`/etc/caddy/Caddyfile`) is ops configuration outside this repo. The
  static/media routing and TLS described in §2/§5 come from the repo `CLAUDE.md`, not from
  code in this tree — confirm with `sudo cat /etc/caddy/Caddyfile` if you need certainty.
- **File ownership/mode claims** (`750`/`640`, `kevin:django`) come from `CLAUDE.md` and the
  Makefile's comments; verify with `ls -l` / `namei -l` if it matters for a change.
- Everything else in this guide was read directly from the cited source files, including the
  systemd unit (`systemctl cat django-crm`) and `gunicorn.conf.py`.
