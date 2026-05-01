-- ============================================================
-- data.sql : schema + triggers + views + seed data
-- ============================================================

USE defaultdb;

-- Drop everything first
DROP VIEW IF EXISTS placement_dashboard;
DROP VIEW IF EXISTS application_tracker;
DROP VIEW IF EXISTS shortlist_view;
DROP VIEW IF EXISTS company_stats;

DROP TABLE IF EXISTS OFFER;
DROP TABLE IF EXISTS INTERVIEW_ROUND;
DROP TABLE IF EXISTS APPLICATION;
DROP TABLE IF EXISTS JOB_ROLE;
DROP TABLE IF EXISTS COMPANY;
DROP TABLE IF EXISTS STUDENT;
-- ── TABLES ──────────────────────────────────────────────────

CREATE TABLE STUDENT (
    student_id   INT AUTO_INCREMENT PRIMARY KEY,
    roll_no      VARCHAR(20) UNIQUE NOT NULL,
    name         VARCHAR(100) NOT NULL,
    email        VARCHAR(100) UNIQUE NOT NULL,
    branch       VARCHAR(50) NOT NULL,
    cpi          DECIMAL(4,2) NOT NULL,
    grad_year    INT NOT NULL,
    eligible     BOOLEAN DEFAULT TRUE
);

CREATE TABLE COMPANY (
    company_id   INT AUTO_INCREMENT PRIMARY KEY,
    name         VARCHAR(100) NOT NULL,
    sector       VARCHAR(50),
    hr_contact   VARCHAR(100),
    min_cpi      DECIMAL(4,2) DEFAULT 0.00
);

CREATE TABLE JOB_ROLE (
    role_id      INT AUTO_INCREMENT PRIMARY KEY,
    company_id   INT NOT NULL,
    title        VARCHAR(100) NOT NULL,
    package_lpa  DECIMAL(6,2) NOT NULL,
    location     VARCHAR(100),
    openings     INT NOT NULL,
    is_open      BOOLEAN DEFAULT TRUE,
    FOREIGN KEY (company_id) REFERENCES COMPANY(company_id) ON DELETE CASCADE
);

CREATE TABLE APPLICATION (
    app_id       INT AUTO_INCREMENT PRIMARY KEY,
    student_id   INT NOT NULL,
    role_id      INT NOT NULL,
    status       ENUM('applied','shortlisted','rejected','offered') DEFAULT 'applied',
    applied_date DATE NOT NULL,
    UNIQUE (student_id, role_id),
    FOREIGN KEY (student_id) REFERENCES STUDENT(student_id) ON DELETE CASCADE,
    FOREIGN KEY (role_id)    REFERENCES JOB_ROLE(role_id)  ON DELETE CASCADE
);

CREATE TABLE INTERVIEW_ROUND (
    round_id     INT AUTO_INCREMENT PRIMARY KEY,
    app_id       INT NOT NULL,
    round_no     INT NOT NULL,
    round_type   VARCHAR(50) NOT NULL,
    result       ENUM('pending','pass','fail') DEFAULT 'pending',
    round_date   DATE,
    FOREIGN KEY (app_id) REFERENCES APPLICATION(app_id) ON DELETE CASCADE
);

CREATE TABLE OFFER (
    offer_id          INT AUTO_INCREMENT PRIMARY KEY,
    student_id        INT NOT NULL,
    role_id           INT NOT NULL,
    package_offered   DECIMAL(6,2) NOT NULL,
    acceptance_status ENUM('pending','accepted','declined') DEFAULT 'pending',
    offer_date        DATE NOT NULL,
    FOREIGN KEY (student_id) REFERENCES STUDENT(student_id) ON DELETE CASCADE,
    FOREIGN KEY (role_id)    REFERENCES JOB_ROLE(role_id)  ON DELETE CASCADE
);

-- ── INDEXES ─────────────────────────────────────────────────

CREATE INDEX idx_application_status  ON APPLICATION(status);
CREATE INDEX idx_application_student ON APPLICATION(student_id);
CREATE INDEX idx_jobrole_company     ON JOB_ROLE(company_id);
CREATE INDEX idx_student_branch      ON STUDENT(branch);
CREATE INDEX idx_student_cpi         ON STUDENT(cpi);

-- ── TRIGGERS ────────────────────────────────────────────────

DELIMITER $$

-- TRIGGER 1: CPI eligibility check before a student applies
CREATE TRIGGER trg_check_cpi_before_apply
BEFORE INSERT ON APPLICATION
FOR EACH ROW
BEGIN
    DECLARE student_cpi   DECIMAL(4,2);
    DECLARE required_cpi  DECIMAL(4,2);
    DECLARE is_eligible   BOOLEAN;

    SELECT cpi, eligible INTO student_cpi, is_eligible
    FROM STUDENT WHERE student_id = NEW.student_id;

    SELECT min_cpi INTO required_cpi
    FROM COMPANY c JOIN JOB_ROLE jr ON c.company_id = jr.company_id
    WHERE jr.role_id = NEW.role_id;

    IF NOT is_eligible THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Student is marked ineligible for placement.';
    END IF;

    IF student_cpi < required_cpi THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Student CPI is below the company minimum requirement.';
    END IF;
END$$

-- TRIGGER 2: When offer is accepted : auto-reject other applications + mark student placed
-- NOTE: This trigger does NOT touch the OFFER table at all.
--       Declining other pending offers is handled BEFORE this trigger fires,
--       inside the accept_placement_offer stored procedure (Step 1 of the procedure).
--       By the time this trigger runs (Step 2), all other offers are already declined,
CREATE TRIGGER trg_auto_reject_on_acceptance
AFTER UPDATE ON OFFER
FOR EACH ROW
BEGIN
    IF NEW.acceptance_status = 'accepted' AND OLD.acceptance_status != 'accepted' THEN

        -- Reject all other pending/shortlisted applications for this student
        UPDATE APPLICATION
        SET status = 'rejected'
        WHERE student_id = NEW.student_id
          AND role_id    != NEW.role_id
          AND status IN ('applied', 'shortlisted');

        -- Mark student as placed (no longer eligible for further applications)
        UPDATE STUDENT
        SET eligible = FALSE
        WHERE student_id = NEW.student_id;

    END IF;
END$$

-- TRIGGER 3: Auto-close role when all openings are filled
CREATE TRIGGER trg_close_role_when_full
AFTER UPDATE ON OFFER
FOR EACH ROW
BEGIN
    DECLARE accepted_count INT;
    DECLARE total_openings INT;

    IF NEW.acceptance_status = 'accepted' THEN
        SELECT COUNT(*) INTO accepted_count
        FROM OFFER
        WHERE role_id = NEW.role_id AND acceptance_status = 'accepted';

        SELECT openings INTO total_openings
        FROM JOB_ROLE WHERE role_id = NEW.role_id;

        IF accepted_count >= total_openings THEN
            UPDATE JOB_ROLE SET is_open = FALSE WHERE role_id = NEW.role_id;
        END IF;
    END IF;
END$$

-- ── STORED PROCEDURE ────────────────────────────────────────

-- Called by the backend instead of a raw UPDATE OFFER SET accepted.
--
-- Execution order :
--   Step 1 — Decline all OTHER pending offers for this student first.
--             At this point no trigger fires on OFFER that touches OFFER,
--             so there is no conflict.
--   Step 2 — Accept the chosen offer. This fires trg_auto_reject_on_acceptance,
--             which updates APPLICATION and STUDENT only. By this point OFFER
--             is already clean (Step 1 handled it), so the trigger has nothing
--             left to do on OFFER.
--
-- The EXIT HANDLER ensures a full rollback if anything fails mid-way,
-- keeping APPLICATION, STUDENT, OFFER, and JOB_ROLE in a consistent state.

CREATE PROCEDURE accept_placement_offer(IN p_offer_id INT)
BEGIN
    DECLARE v_student_id INT;
    DECLARE v_role_id    INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT student_id, role_id
    INTO   v_student_id, v_role_id
    FROM   OFFER
    WHERE  offer_id = p_offer_id;

    START TRANSACTION;

        -- Step 1: Decline all other pending offers for this student FIRST.
        --         Do this before the acceptance update so that when the
        --         trigger fires in Step 2 there is nothing left to update
        --         in OFFER.
        UPDATE OFFER
        SET    acceptance_status = 'declined'
        WHERE  student_id        = v_student_id
          AND  offer_id         != p_offer_id
          AND  acceptance_status = 'pending';

        -- Step 2: Accept the chosen offer.
        --         Fires trg_auto_reject_on_acceptance : updates APPLICATION
        --         (rejects other apps) and STUDENT (sets eligible = FALSE).
        --         Also fires trg_close_role_when_full : closes role if full.
        UPDATE OFFER
        SET    acceptance_status = 'accepted'
        WHERE  offer_id = p_offer_id;

    COMMIT;
END$$

DELIMITER ;

-- ── VIEWS ───────────────────────────────────────────────────

-- VIEW 1: Branch-wise placement dashboard
CREATE VIEW placement_dashboard AS
SELECT
    s.branch,
    COUNT(DISTINCT s.student_id)                                      AS total_students,
    COUNT(DISTINCT CASE WHEN o.acceptance_status = 'accepted'
                        THEN o.student_id END)                        AS placed_students,
    ROUND(COUNT(DISTINCT CASE WHEN o.acceptance_status = 'accepted'
                              THEN o.student_id END)
          * 100.0 / COUNT(DISTINCT s.student_id), 2)                  AS placement_pct,
    ROUND(AVG(CASE WHEN o.acceptance_status = 'accepted'
                   THEN o.package_offered END), 2)                    AS avg_package_lpa,
    MAX(CASE WHEN o.acceptance_status = 'accepted'
             THEN o.package_offered END)                              AS max_package_lpa
FROM STUDENT s
LEFT JOIN OFFER o ON s.student_id = o.student_id
GROUP BY s.branch;

-- VIEW 2: Per-student application tracker
CREATE VIEW application_tracker AS
SELECT
    s.name          AS student_name,
    s.roll_no,
    s.branch,
    c.name          AS company_name,
    jr.title        AS role_title,
    jr.package_lpa  AS role_package,
    a.status        AS app_status,
    a.applied_date,
    ir.round_no     AS latest_round,
    ir.round_type   AS latest_round_type,
    ir.result       AS latest_round_result
FROM APPLICATION a
JOIN STUDENT s       ON a.student_id = s.student_id
JOIN JOB_ROLE jr     ON a.role_id    = jr.role_id
JOIN COMPANY c       ON jr.company_id = c.company_id
LEFT JOIN INTERVIEW_ROUND ir
    ON ir.app_id = a.app_id
    AND ir.round_no = (
        SELECT MAX(round_no) FROM INTERVIEW_ROUND
        WHERE app_id = a.app_id
    );

-- VIEW 3: Shortlist view per role (for company use)
CREATE VIEW shortlist_view AS
SELECT
    jr.title        AS role_title,
    c.name          AS company_name,
    s.name          AS student_name,
    s.roll_no,
    s.branch,
    s.cpi,
    a.status
FROM APPLICATION a
JOIN STUDENT s   ON a.student_id = s.student_id
JOIN JOB_ROLE jr ON a.role_id    = jr.role_id
JOIN COMPANY c   ON jr.company_id = c.company_id
WHERE a.status IN ('shortlisted', 'offered')
ORDER BY jr.role_id, s.cpi DESC;

-- VIEW 4: Company-wise offer stats
CREATE VIEW company_stats AS
SELECT
    c.name                                        AS company_name,
    c.sector,
    COUNT(DISTINCT jr.role_id)                    AS total_roles,
    COUNT(o.offer_id)                             AS total_offers,
    SUM(CASE WHEN o.acceptance_status = 'accepted'
             THEN 1 ELSE 0 END)                   AS accepted_offers,
    ROUND(AVG(o.package_offered), 2)              AS avg_package_offered
FROM COMPANY c
LEFT JOIN JOB_ROLE jr ON c.company_id    = jr.company_id
LEFT JOIN OFFER o     ON jr.role_id      = o.role_id
GROUP BY c.company_id, c.name, c.sector;

-- ── SEED DATA ───────────────────────────────────────────────

INSERT INTO STUDENT (roll_no, name, email, branch, cpi, grad_year, eligible) VALUES
('22B0101', 'Aarav Sharma',     '22B0101@iitk.ac.in',       'CSE', 9.20, 2026, TRUE),
('22B0102', 'Priya Mehta',      '22B0102@iitk.ac.in',       'CSE', 8.75, 2026, TRUE),
('22B0103', 'Rohan Gupta',      '22B0103@iitk.ac.in',       'EE',  7.90, 2026, TRUE),
('22B0104', 'Sneha Iyer',       '22B0104@iitk.ac.in',       'ME',  8.10, 2026, TRUE),
('22B0105', 'Karan Patel',      '22B0105@iitk.ac.in',       'CSE', 9.50, 2026, TRUE),
('22B0106', 'Ananya Singh',     '22B0106@iitk.ac.in',       'EE',  7.60, 2026, TRUE),
('22B0107', 'Vikram Nair',      '22B0107@iitk.ac.in',       'CSE', 8.30, 2026, TRUE),
('22B0108', 'Pooja Reddy',      '22B0108@iitk.ac.in',       'CE',  7.80, 2026, TRUE),
('22B0109', 'Arjun Verma',      '22B0109@iitk.ac.in',       'CSE', 9.10, 2026, TRUE),
('22B0110', 'Meera Joshi',      '22B0110@iitk.ac.in',       'ME',  8.60, 2026, TRUE),
('22B0111', 'Dev Agarwal',      '22B0111@iitk.ac.in',       'CSE', 7.20, 2026, TRUE),
('22B0112', 'Tanvi Sharma',     '22B0112@iitk.ac.in',       'EE',  8.90, 2026, TRUE),
('22B0113', 'Rahul Khanna',     '22B0113@iitk.ac.in',       'CSE', 9.30, 2026, TRUE),
('22B0114', 'Ishita Bose',      '22B0114@iitk.ac.in',       'CE',  7.60, 2026, TRUE),
('22B0115', 'Nikhil Soni',      '22B0115@iitk.ac.in',       'ME',  8.40, 2026, TRUE),
('22B0116', 'Divya Pillai',     '22B0116@iitk.ac.in',       'CSE', 8.00, 2026, TRUE),
('22B0117', 'Aditya Kumar',     '22B0117@iitk.ac.in',       'EE',  7.55, 2026, TRUE),
('22B0118', 'Shreya Tiwari',    '22B0118@iitk.ac.in',       'CSE', 9.70, 2026, TRUE),
('22B0119', 'Manish Dubey',     '22B0119@iitk.ac.in',       'CE',  7.30, 2026, TRUE),
('22B0120', 'Kavya Menon',      '22B0120@iitk.ac.in',       'CSE', 8.85, 2026, TRUE),
('22ADMIN', 'Prathamesh',       'smartcheese176@gmail.com', 'CSE', 9.99, 2026, TRUE);

INSERT INTO COMPANY (name, sector, hr_contact, min_cpi) VALUES
('Google',         'Tech',    'hr@google.com',       8.50),
('Microsoft',      'Tech',    'hr@microsoft.com',    7.50),
('Goldman Sachs',  'Finance', 'hr@gs.com',           8.00),
('Tata Steel',     'Core',    'hr@tatasteel.com',    6.50),
('Amazon',         'Tech',    'hr@amazon.com',       7.00),
('McKinsey',       'Consult', 'hr@mckinsey.com',     8.50),
('Samsung R&D',    'Tech',    'hr@samsung.com',      7.50),
('DE Shaw',        'Finance', 'hr@deshaw.com',       8.00);

INSERT INTO JOB_ROLE (company_id, title, package_lpa, location, openings) VALUES
(1, 'SWE',                  45.00, 'Bangalore',  2),
(1, 'SWE Intern + FTE',     40.00, 'Hyderabad',  1),
(2, 'SDE-1',                35.00, 'Hyderabad',  3),
(2, 'PM',                   30.00, 'Bangalore',  1),
(3, 'Analyst',              28.00, 'Mumbai',     2),
(3, 'Quant',                35.00, 'Mumbai',     1),
(4, 'Graduate Engineer',    12.00, 'Jamshedpur', 4),
(5, 'SDE-1',                32.00, 'Bangalore',  3),
(5, 'Data Engineer',        28.00, 'Hyderabad',  2),
(6, 'Business Analyst',     26.00, 'Delhi',      2),
(7, 'R&D Engineer',         18.00, 'Noida',      3),
(8, 'Quant Researcher',     50.00, 'Hyderabad',  2);

INSERT INTO APPLICATION (student_id, role_id, status, applied_date) VALUES
(1,  1,  'shortlisted', '2026-01-10'),
(1,  8,  'applied',     '2026-01-12'),
(2,  3,  'shortlisted', '2026-01-10'),
(2,  5,  'applied',     '2026-01-11'),
(3,  3,  'applied',     '2026-01-10'),
(3,  7,  'applied',     '2026-01-13'),
(4,  7,  'applied',     '2026-01-10'),
(4,  11, 'applied',     '2026-01-14'),
(5,  1,  'offered',     '2026-01-10'),
(5,  12, 'offered',     '2026-01-11'),
(6,  11, 'applied',     '2026-01-10'),
(7,  3,  'shortlisted', '2026-01-10'),
(7,  8,  'applied',     '2026-01-12'),
(8,  7,  'applied',     '2026-01-10'),
(9,  1,  'shortlisted', '2026-01-10'),
(9,  12, 'applied',     '2026-01-11'),
(10, 5,  'applied',     '2026-01-11'),
(11, 8,  'applied',     '2026-01-12'),
(12, 6,  'shortlisted', '2026-01-10'),
(13, 1,  'shortlisted', '2026-01-10'),
(13, 12, 'shortlisted', '2026-01-11'),
(14, 7,  'applied',     '2026-01-13'),
(15, 11, 'applied',     '2026-01-14'),
(16, 3,  'applied',     '2026-01-10'),
(17, 11, 'applied',     '2026-01-14'),
(18, 1,  'offered',     '2026-01-10'),
(18, 12, 'shortlisted', '2026-01-11'),
(19, 7,  'applied',     '2026-01-13'),
(20, 3,  'shortlisted', '2026-01-10'),
(20, 8,  'applied',     '2026-01-12'),
(21, 1,  'offered',     '2026-01-10'),
(21, 12, 'shortlisted', '2026-01-11');

INSERT INTO INTERVIEW_ROUND (app_id, round_no, round_type, result, round_date) VALUES
(1,  1, 'Online Assessment', 'pass', '2026-01-15'),
(1,  2, 'Technical',         'pass', '2026-01-20'),
(3,  1, 'Online Assessment', 'pass', '2026-01-15'),
(3,  2, 'Technical',         'pass', '2026-01-20'),
(9,  1, 'Online Assessment', 'pass', '2026-01-15'),
(9,  2, 'Technical',         'pass', '2026-01-18'),
(9,  3, 'HR',                'pass', '2026-01-22'),
(10, 1, 'Online Assessment', 'pass', '2026-01-16'),
(12, 1, 'Online Assessment', 'pass', '2026-01-15'),
(12, 2, 'Technical',         'pass', '2026-01-19'),
(15, 1, 'Online Assessment', 'pass', '2026-01-15'),
(15, 2, 'Technical',         'pass', '2026-01-20'),
(19, 1, 'Online Assessment', 'pass', '2026-01-15'),
(19, 2, 'Technical',         'pass', '2026-01-19'),
(21, 1, 'Online Assessment', 'pass', '2026-01-16'),
(26, 1, 'Online Assessment', 'pass', '2026-01-15'),
(26, 2, 'Technical',         'pass', '2026-01-18'),
(26, 3, 'HR',                'pass', '2026-01-22'),
(29, 1, 'Online Assessment', 'pass', '2026-01-15'),
(29, 2, 'Technical',         'pass', '2026-01-20');

INSERT INTO OFFER (student_id, role_id, package_offered, acceptance_status, offer_date) VALUES
(5,  1, 45.00, 'accepted', '2026-01-25'),
(18, 1, 45.00, 'pending',  '2026-01-25'),  -- Shreya: Google offer pending
(21, 1, 45.00, 'pending',  '2026-01-26');  -- Prathamesh: Google offer pending

-- Manually mark Karan as ineligible (placed) after his historical data is seeded
UPDATE STUDENT SET eligible = FALSE WHERE student_id = 5;
