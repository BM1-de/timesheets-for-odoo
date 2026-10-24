#!/bin/zsh
# Zeiterfassung für Odoo – Test-Odoo starten
# Copyright (C) 2026 Baumgärtner Marketing GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Startet Odoo 19 mit Demodaten auf http://localhost:8079 (nur dieser Rechner), installiert
# Zeiterfassung und Anwesenheiten und legt API-Schlüssel für drei Testbenutzer an:
#
#   admin           Administrator, darf stempeln
#   mitarbeiter     Mitarbeiter nur mit Grundrechten; die App zeigt die Anwesenheit nur an
#   sachbearbeiter  genehmigt die Anwesenheiten von „mitarbeiter“ und hat dadurch „Sachbearbeiter:
#                   Anwesenheiten verwalten“, ist aber nicht sein eigener Anwesenheitsgenehmiger.
#                   Das Recht scheint da, Odoo lehnt sein eigenes Stempeln aber ab.
#   zweifirmen      hat Mitarbeiter in zwei Firmen („YourCompany“ und „Testfirma Foto“); dazu gibt es
#                   ein Projekt der zweiten Firma („Fotoprojekt“) und eines für alle Firmen.
#
# Die Schlüssel stehen danach in dev/.env (nicht im Repository). Erneut aufrufen legt neue
# Schlüssel an. Aufräumen: docker compose -p zeiterfassung-test down -v

set -euo pipefail
cd "${0:A:h}"
export COMPOSE_PROJECT_NAME=zeiterfassung-test
DB=zeiterfassung

docker compose up -d db
until docker compose exec -T db pg_isready -U odoo >/dev/null 2>&1; do sleep 1; done

if ! docker compose exec -T db psql -U odoo -lqt | cut -d'|' -f1 | grep -qw "$DB"; then
  echo "Lege die Datenbank $DB mit Demodaten an (dauert einige Minuten) …"
  docker compose run --rm -T odoo odoo -d "$DB" -i hr_timesheet,hr_attendance --with-demo \
    --load-language=de_DE --stop-after-init >/dev/null
fi

docker compose up -d odoo

docker compose run --rm -T odoo odoo shell -d "$DB" --no-http --log-level=warn <<'PY' | grep -E '^(ADMIN|EMPLOYEE|OFFICER|MULTI)_' > .env.new
from datetime import datetime, timedelta
from odoo import Command
admin = env.ref('base.user_admin')
admin.write({'lang': 'de_DE', 'tz': 'Europe/Berlin'})

# Mitarbeiter nur mit Grundrechten: interne Benutzerin plus „Zeiterfassung: eigene Einträge“.
employee_user = env['res.users'].search([('login', '=', 'mitarbeiter')], limit=1)
if not employee_user:
    employee_user = env['res.users'].with_context(no_reset_password=True).create({
        'name': 'Erika Mustermann',
        'login': 'mitarbeiter',
        'lang': 'de_DE',
        'tz': 'Europe/Berlin',
        'group_ids': [(6, 0, [env.ref('base.group_user').id, env.ref('hr_timesheet.group_hr_timesheet_user').id])],
    })
    env['hr.employee'].create({'name': 'Erika Mustermann', 'user_id': employee_user.id})

# Sachbearbeiter: Genehmiger für Erika. Odoo gibt ihm dafür selbst das Recht „Sachbearbeiter:
# Anwesenheiten verwalten“; für die eigenen Anwesenheiten ist niemand eingetragen.
officer_user = env['res.users'].search([('login', '=', 'sachbearbeiter')], limit=1)
if not officer_user:
    officer_user = env['res.users'].with_context(no_reset_password=True).create({
        'name': 'Max Beispiel',
        'login': 'sachbearbeiter',
        'lang': 'de_DE',
        'tz': 'Europe/Berlin',
        'group_ids': [(6, 0, [env.ref('base.group_user').id, env.ref('hr_timesheet.group_hr_timesheet_user').id])],
    })
    env['hr.employee'].create({'name': 'Max Beispiel', 'user_id': officer_user.id})
    employee_user.employee_id.attendance_manager_id = officer_user

# Zwei Firmen: Zora hat in jeder einen Mitarbeiter. Odoo bucht ihre Einträge in der Firma des Projekts.
main_company = env.ref('base.main_company')
second_company = env['res.company'].search([('name', '=', 'Testfirma Foto')], limit=1) \
    or env['res.company'].create({'name': 'Testfirma Foto'})
multi_user = env['res.users'].search([('login', '=', 'zweifirmen')], limit=1)
if not multi_user:
    multi_user = env['res.users'].with_context(no_reset_password=True).create({
        'name': 'Zora Zweifirmen',
        'login': 'zweifirmen',
        'lang': 'de_DE',
        'tz': 'Europe/Berlin',
        'company_id': main_company.id,
        'company_ids': [Command.set([main_company.id, second_company.id])],
        'group_ids': [Command.set([env.ref('base.group_user').id, env.ref('hr_timesheet.group_hr_timesheet_user').id])],
    })
for company in (main_company, second_company):
    if not env['hr.employee'].search([('user_id', '=', multi_user.id), ('company_id', '=', company.id)]):
        env['hr.employee'].with_company(company).create(
            {'name': 'Zora Zweifirmen', 'user_id': multi_user.id, 'company_id': company.id})
if not env['project.project'].search([('name', '=', 'Fotoprojekt')]):
    env['project.project'].with_company(second_company).create(
        {'name': 'Fotoprojekt', 'company_id': second_company.id, 'allow_timesheets': True})
if not env['project.project'].search([('name', '=', 'Gemeinsames Projekt')]):
    env['project.project'].create({'name': 'Gemeinsames Projekt', 'company_id': False, 'allow_timesheets': True})

expiry = datetime.now() + timedelta(days=30)
keys = env['res.users.apikeys']
admin_key = keys.with_user(admin).sudo()._generate('rpc', 'Zeiterfassung für Odoo (Test)', expiry)
employee_key = keys.with_user(employee_user).sudo()._generate('rpc', 'Zeiterfassung für Odoo (Test)', expiry)
officer_key = keys.with_user(officer_user).sudo()._generate('rpc', 'Zeiterfassung für Odoo (Test)', expiry)
multi_key = keys.with_user(multi_user).sudo()._generate('rpc', 'Zeiterfassung für Odoo (Test)', expiry)
env.cr.commit()
print(f"ADMIN_KEY={admin_key}")
print(f"ADMIN_LOGIN={admin.login}")
print(f"EMPLOYEE_KEY={employee_key}")
print(f"EMPLOYEE_LOGIN={employee_user.login}")
print(f"OFFICER_KEY={officer_key}")
print(f"OFFICER_LOGIN={officer_user.login}")
print(f"MULTI_KEY={multi_key}")
print(f"MULTI_LOGIN={multi_user.login}")
PY

{
  echo "URL=http://localhost:8079"
  echo "DB=$DB"
  cat .env.new
} > .env
rm -f .env.new
chmod 600 .env
echo "Test-Odoo läuft auf http://localhost:8079 (Datenbank $DB). Schlüssel in dev/.env."
