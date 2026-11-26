# Synthetic university development dataset

## Scope and counts

This is disposable synthetic data for local development, demos and integration tests. It adds exactly 20 phone-only STUDENT accounts with verified synthetic STUDENT identities, 10 phone-only FACULTY accounts with verified synthetic FACULTY identities, and 10 phone-only demo administrator accounts with local `private.platform_admins` grants. The original four synthetic GRADUATE demo accounts remain unchanged.

No ADMIN identity type exists. Student-only, faculty-only and administrator accounts do not receive a `graduate_profiles` row. All new identities and academic rows carry the explicit `SYNTHETIC_SEED` marker. A verified status here means simulated local demo verification, never real institutional verification.

## GPA and academic tracks

GPA is a fixture-level demonstration convention on a 4.0 scale, with twenty distinct values in the inclusive range 0.00–4.00. It does not describe or imply the actual grading policy of any university. Student academic data is typed in `public.student_academic_records`: institution reference, department, major, academic track, academic level, GPA and scale.

| Track | Students |
|---|---:|
| Software Engineering | 4 |
| Artificial Intelligence | 3 |
| Data Science and Analytics | 3 |
| Cybersecurity | 3 |
| Mobile Development | 3 |
| Networks and Cloud | 2 |
| Information Systems | 2 |
| **Total** | **20** |

Faculty records are typed in `public.faculty_academic_records`, including department, specialization and varied academic title. Academic rows are service-role writable and owner-readable through RLS; clients cannot write or change identities.

## Synthetic authentication

New synthetic users have no email and no National ID. Stable fixture keys and institutional references are in `fixtures/university-accounts.json`. Phone numbers use the fictional NANPA 555-0100 through 555-0139 range (`+1 212 555 0100`–`+1 212 555 0139`); NANPA reserves 555-0100 through 555-0199 as fictitious non-working numbers for entertainment/advertising. See https://www.nanpa.com/numbering/555-line-numbers.

No SMS is sent. The local Supabase Auth Admin API sets `phone_confirm: true` while provisioning a disposable local account. Set `DEMO_PASSWORD` in the environment; it must be at least 12 characters. Do not commit it or write it into a fixture, SQL file, documentation, issue comment or build artifact.

## Local commands

Start the disposable local Supabase stack and apply migrations first. The API URL must be a localhost alias on port 54321, and the database URL must be local on port 54322.

```bash
export SUPABASE_URL="http://127.0.0.1:54321"
export DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
export SUPABASE_SERVICE_ROLE_KEY="<local service-role key from supabase status>"
export DEMO_PASSWORD="<temporary local-only password, at least 12 characters>"

npm run build:seed
npm run seed:university:local
```

`npm run seed:university:local` validates both URLs before network or database access, provisions Auth users twice, applies generated `04_university_accounts.sql` twice, and checks exact counts and idempotency. It rejects hosted URLs, arbitrary private IPs, HTTPS API URLs and non-standard ports. The generated SQL additionally refuses to run without the session-local `app.synthetic_seed_allowed=local-only` guard set by the local runner.

The local integration suite runs the same command after the four legacy graduate demos. Use only disposable local keys and discard the environment afterward. Do not run this seed against staging or production.
