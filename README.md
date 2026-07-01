# 🎓 IITK Campus Placement Portal

A full-stack campus placement management system built with **Node.js / Express** (REST API), a **single-page web frontend**, and a **MySQL** database hosted on Aiven. It automates the entire placement lifecycle — from student registration and job applications, through interview rounds, to offer acceptance — while enforcing business rules through DB-level triggers, stored procedures, and views.

---

## Table of Contents

1. [Tech Stack](#tech-stack)
2. [Project Structure](#project-structure)
3. [Database Design](#database-design)
   - [Tables](#tables)
   - [Indexes](#indexes)
   - [Triggers](#triggers)
   - [Stored Procedure](#stored-procedure)
   - [Views](#views)
4. [Authentication](#authentication)
5. [API Reference](#api-reference)
   - [Auth](#auth-routes)
   - [Students](#student-routes)
   - [Companies & Job Roles](#company--job-role-routes)
   - [Applications](#application-routes)
   - [Interview Rounds](#interview-round-routes)
   - [Offers](#offer-routes)
6. [Web Frontend](#web-frontend)
7. [CLI Client](#cli-client)
8. [Email Notifications](#email-notifications)
9. [Setup & Running Locally](#setup--running-locally)
10. [Environment Variables](#environment-variables)
11. [Seed Data](#seed-data)

---

## Tech Stack

| Layer | Technology |
|---|---|
| Runtime | Node.js (ESM modules) |
| Web framework | Express.js |
| Database | MySQL 8 (hosted on Aiven) |
| DB driver | `mysql2/promise` (connection pool) |
| Frontend | Vanilla HTML/CSS/JS (single `index.html`) |
| CLI client | Inquirer.js + Axios |
| Email | Nodemailer (Gmail App Password) |
| Deployment | Netlify (frontend) |

---

## Project Structure

```
CS315-Project/
├── client/
│   ├── client.js          # Interactive CLI admin tool
│   ├── client.js.bak      # Backup of CLI client
│   ├── index.html         # Single-page web frontend
│   └── package.json
├── server/
│   ├── server.js          # Express app entry point
│   ├── db/
│   │   └── connection.js  # MySQL connection pool (Aiven-compatible)
│   ├── routes/
│   │   ├── auth.js        # OTP send / verify
│   │   ├── student.js     # Student CRUD + tracker
│   │   ├── company.js     # Company & job role CRUD
│   │   ├── application.js # Applications + analytics queries
│   │   ├── interview.js   # Interview round management
│   │   └── offer.js       # Offer lifecycle management
│   └── utils/
│       ├── mailer.js      # Nodemailer wrapper
│       └── otpService.js  # In-memory OTP store
├── data.sql               # Full schema, triggers, views, procedure, seed data
├── addToDB.sh             # Load data.sql into a local MySQL instance
├── resetDB.sh             # Drop and recreate the local database
└── package.json
```

---

## Database Design

### Tables

| Table | Key Columns | Notes |
|---|---|---|
| `STUDENT` | `student_id`, `roll_no`, `email`, `branch`, `cpi`, `grad_year`, `eligible` | `eligible` flips to `FALSE` once a student accepts an offer |
| `COMPANY` | `company_id`, `name`, `sector`, `hr_contact`, `min_cpi` | `min_cpi` gates applications via trigger |
| `JOB_ROLE` | `role_id`, `company_id`, `title`, `package_lpa`, `openings`, `is_open` | `is_open` auto-closes when all openings are filled |
| `APPLICATION` | `app_id`, `student_id`, `role_id`, `status`, `applied_date` | Status: `applied` → `shortlisted` → `offered` / `rejected` |
| `INTERVIEW_ROUND` | `round_id`, `app_id`, `round_no`, `round_type`, `result`, `round_date` | Round types: Technical, HR, etc.; Result: `pending` / `pass` / `fail` |
| `OFFER` | `offer_id`, `student_id`, `role_id`, `package_offered`, `acceptance_status`, `offer_date` | Status: `pending` → `accepted` / `declined` |

All foreign keys use `ON DELETE CASCADE` so removing a student, company, or role automatically cleans up dependent rows.

### Indexes

```sql
CREATE INDEX idx_application_status  ON APPLICATION(status);
CREATE INDEX idx_application_student ON APPLICATION(student_id);
CREATE INDEX idx_jobrole_company     ON JOB_ROLE(company_id);
CREATE INDEX idx_student_branch      ON STUDENT(branch);
CREATE INDEX idx_student_cpi         ON STUDENT(cpi);
```

### Triggers

#### Trigger 1 — `trg_check_cpi_before_apply` (`BEFORE INSERT ON APPLICATION`)
Validates two rules before any application row is inserted:
- The student's `eligible` flag must be `TRUE` (not already placed).
- The student's `cpi` must meet the company's `min_cpi` requirement.

If either check fails, a `SQLSTATE 45000` signal is raised with a descriptive message, which the backend forwards to the client as a `400` error.

#### Trigger 2 — `trg_auto_reject_on_acceptance` (`AFTER UPDATE ON OFFER`)
Fires when an offer's `acceptance_status` changes to `'accepted'`:
1. Sets all other `applied` / `shortlisted` applications for the same student to `'rejected'`.
2. Sets the student's `eligible` flag to `FALSE` (CDC one-placement policy).

#### Trigger 3 — `trg_close_role_when_full` (`AFTER UPDATE ON OFFER`)
Fires when an offer is accepted. Counts total accepted offers for that role and sets `JOB_ROLE.is_open = FALSE` when the accepted count reaches the number of openings.

### Stored Procedure

#### `accept_placement_offer(p_offer_id INT)`

Wraps offer acceptance in a transaction to avoid a mutating-table conflict between Trigger 2 and itself:

```
START TRANSACTION;
  Step 1 — Decline all OTHER pending offers for the student.
            (No trigger fires on OFFER that touches OFFER here.)
  Step 2 — Accept the chosen offer.
            (Fires trg_auto_reject_on_acceptance → updates APPLICATION + STUDENT.
             Fires trg_close_role_when_full → may close the role.)
COMMIT;
```

An `EXIT HANDLER FOR SQLEXCEPTION` rolls back the entire transaction if anything fails, keeping the database in a consistent state.

### Views

| View | Purpose |
|---|---|
| `placement_dashboard` | Branch-wise totals: total students, placed count, placement %, avg/max package |
| `application_tracker` | Per-student view: every application with the company name, role, status, and latest interview round result |
| `shortlist_view` | Per-role view of shortlisted/offered candidates sorted by CPI — used by companies |
| `company_stats` | Company-wise aggregates: total roles, total offers sent, accepted offers, avg package |

---

## Authentication

Authentication is **OTP-based** — no passwords are stored.

| Step | Endpoint | Behaviour |
|---|---|---|
| 1 | `POST /auth/send-otp` | Generates a 6-digit OTP, sends it via Gmail, stores it in memory |
| 2 | `POST /auth/verify-otp` | Validates the OTP; returns user info + `role` (`admin` or `student`) |

Admin emails are hard-coded in `server/routes/auth.js`. All other emails are looked up against the `STUDENT` table.

OTPs are stored in a server-side `Map` and deleted immediately after successful verification (one-time use).

---

## API Reference

All responses use JSON. Error responses follow `{ "error": "<message>" }`.

### Auth Routes (`/auth`)

| Method | Path | Body | Description |
|---|---|---|---|
| POST | `/auth/send-otp` | `{ email }` | Send a 6-digit OTP to the email |
| POST | `/auth/verify-otp` | `{ email, otp }` | Verify OTP; returns `{ user: { ...fields, role } }` |

### Student Routes (`/student`)

| Method | Path | Body / Params | Description |
|---|---|---|---|
| GET | `/student` | — | List all students ordered by CPI desc |
| GET | `/student/:roll_no` | — | Get a single student by roll number |
| GET | `/student/:roll_no/tracker` | — | Full application tracker for a student (uses `application_tracker` view) |
| GET | `/student/shortlist/:role_id` | — | Shortlisted candidates for a role (uses `shortlist_view`) |
| POST | `/student` | `{ roll_no, name, email, branch, cpi, grad_year }` | Add a new student |
| DELETE | `/student/:student_id` | — | Delete student; reopens any roles they had accepted offers for and restores rejected applications |

### Company & Job Role Routes (`/company`)

| Method | Path | Body / Params | Description |
|---|---|---|---|
| GET | `/company` | — | List all companies |
| GET | `/company/stats` | — | Company analytics (uses `company_stats` view) |
| GET | `/company/roles/open` | — | All open job roles across all companies, sorted by package |
| GET | `/company/:company_id/roles` | — | All roles for a specific company |
| POST | `/company` | `{ name, sector?, hr_contact?, min_cpi? }` | Add a new company |
| POST | `/company/:company_id/roles` | `{ title, package_lpa, openings, location? }` | Add a job role |
| DELETE | `/company/:company_id` | — | Delete company + cascade; re-eligibilises placed students and restores affected applications |
| DELETE | `/company/roles/:role_id` | — | Delete a role; re-eligibilises students placed via that role |

### Application Routes (`/application`)

| Method | Path | Body / Params | Description |
|---|---|---|---|
| GET | `/application` | — | All applications (with student, company, and role details) |
| GET | `/application/dashboard` | — | Branch-wise placement stats (uses `placement_dashboard` view) |
| POST | `/application` | `{ student_id, role_id }` | Submit an application (CPI trigger fires here) |
| PUT | `/application/:app_id/status` | `{ status }` | Update application status (`applied`, `shortlisted`, `rejected`, `offered`) |
| GET | `/application/queries/tech-pass-hr-fail` | — | Students who passed Technical but failed HR round |
| GET | `/application/queries/no-offer` | — | Students with 3+ applications but no accepted offer |
| GET | `/application/queries/company-ranking/:company_id` | — | CPI-based rank of applicants per role (window function `RANK() OVER`) |

### Interview Round Routes (`/interview`)

| Method | Path | Body / Params | Description |
|---|---|---|---|
| GET | `/interview/application/:app_id` | — | All rounds for a given application |
| POST | `/interview` | `{ app_id, round_no, round_type, result?, round_date? }` | Add an interview round |
| PUT | `/interview/:round_id/result` | `{ result }` | Update round result (`pending`, `pass`, `fail`) |

### Offer Routes (`/offer`)

| Method | Path | Body / Params | Description |
|---|---|---|---|
| GET | `/offer` | — | All offers with student, company, and role details |
| GET | `/offer/my/:student_id` | — | All offers for a specific student |
| GET | `/offer/applicants/:role_id` | — | Eligible applicants for a role (for cascading offer modal) |
| POST | `/offer` | `{ student_id, role_id, package_offered }` | Create an offer (validates no duplicate, no rejected applicant, not already placed) |
| PUT | `/offer/:offer_id/accept` | — | Accept offer via `CALL accept_placement_offer(?)` stored procedure; sends confirmation email |
| PUT | `/offer/:offer_id/decline` | — | Decline an offer |

---

## Web Frontend

The entire web interface is a single self-contained file: `client/index.html`.

**Login flow:**
1. Enter your IITK email address.
2. Click **Send OTP** — a 6-digit code is emailed to you.
3. Enter the OTP to log in.
4. The UI adapts based on your role:
   - **Admin** sees all management panels.
   - **Student** sees only their own tracker, open roles, and personal offers.

**Sidebar navigation:**

| Section | Panel | Description |
|---|---|---|
| Overview | Dashboard | Branch-wise placement statistics |
| Overview | Company Stats | Company recruitment analytics |
| Manage | Students | Add / delete students; view CPI rankings |
| Manage | Companies | Add / delete companies and job roles |
| Manage | Applications | View all applications; update statuses |
| Manage | Interviews | Add and update interview round results |
| Manage | Offers | Create offers; accept/decline with trigger demo |
| Analytics | Special Queries | 3 advanced SQL queries exposed via buttons |
| My Portal | My Applications | Student's personal application tracker |
| My Portal | Open Roles | Browse open positions; apply with one click |
| My Portal | My Offers | Student's offer list with accept/decline actions |

---

## CLI Client

`client/client.js` is a terminal-based admin tool built with **Inquirer.js**:

```bash
cd client
npm install
node client.js
```

Menu options:
1. **View Placement Dashboard** — fetches and table-prints branch-wise stats.
2. **View Company Analytics** — fetches and table-prints company stats.
3. **Track Specific Student** — prompts for a roll number and prints their application tracker.
4. **Demo Trigger: Accept an Offer** — accepts an offer by ID to demonstrate the auto-reject trigger.
5. **Exit**

> The CLI connects to `http://localhost:5000` — the backend must be running first.

---

## Email Notifications

The project uses **Nodemailer** (Gmail) for two purposes:

| Event | Recipient | Content |
|---|---|---|
| OTP login | User's email | 6-digit OTP with a note not to share it |
| Offer accepted | Student's email | Confirmation with company name, role title, package, and a note that other applications have been withdrawn |

Mail failures are caught silently so they never break the API response.

---

## Setup & Running Locally

### Prerequisites
- Node.js ≥ 18
- MySQL 8 (local) **or** an Aiven MySQL instance
- A Gmail account with an [App Password](https://support.google.com/accounts/answer/185833) enabled

### 1. Clone & install dependencies

```bash
git clone https://github.com/SmartCheese22/CS315-Project.git
cd CS315-Project
npm install
```

### 2. Configure environment variables

Create a `.env` file in the project root (see [Environment Variables](#environment-variables) below).

### 3. Load the database schema and seed data

**Local MySQL:**
```bash
bash addToDB.sh          # runs: mysql -u root -p placement_portal < data.sql
```

To start fresh:
```bash
bash resetDB.sh          # drops and recreates the database
bash addToDB.sh
```

**Aiven (remote):** import `data.sql` via the Aiven Console or using the mysql CLI with your Aiven connection string.

### 4. Start the server

```bash
npm run server           # node server/server.js  →  http://localhost:5000
```

### 5. Open the frontend

Open `client/index.html` directly in a browser, or serve it via any static server.

### 6. (Optional) Run the CLI client

```bash
cd client
npm install
node client.js
```

---

## Environment Variables

Create a `.env` file in the project root:

```env
# Database (Aiven or local MySQL)
DB_HOST=your-mysql-host
DB_PORT=3306
DB_USER=your-db-user
DB_PASSWORD=your-db-password
DB_NAME=defaultdb          # or "placement_portal" for local

# Gmail (for OTP and offer confirmation emails)
EMAIL=your-gmail@gmail.com
EMAIL_PASSWORD=your-16-char-app-password

# Server
PORT=5000
```

## Seed Data

`data.sql` includes 20 sample students (branches: CSE, EE, ME, CE), 8 companies (Tech, Finance, Core, Consulting), and 12 job roles with realistic packages and locations. This lets you explore the full feature set immediately after running `addToDB.sh`.
