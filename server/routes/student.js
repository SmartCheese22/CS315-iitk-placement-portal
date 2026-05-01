import express from 'express';
import db from '../db/connection.js';

const router = express.Router();

// GET all students
router.get('/', async (req, res) => {
    try {
        const [rows] = await db.query('SELECT * FROM STUDENT ORDER BY cpi DESC');
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET single student by roll_no
router.get('/:roll_no', async (req, res) => {
    try {
        const [rows] = await db.query(
            'SELECT * FROM STUDENT WHERE roll_no = ?',
            [req.params.roll_no]
        );
        if (rows.length === 0) return res.status(404).json({ error: 'Student not found' });
        res.json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// GET student application tracker (uses VIEW application_tracker)
router.get('/:roll_no/tracker', async (req, res) => {
    try {
        const [rows] = await db.query(
            'SELECT * FROM application_tracker WHERE roll_no = ?',
            [req.params.roll_no]
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// POST add a new student
router.post('/', async (req, res) => {
    try {
        // 1. We added 'email' to the destructured body
        const { roll_no, name, email, branch, cpi, grad_year } = req.body;
        
        // 2. Added email to the validation check
        if (!roll_no || !name || !email || !branch || !cpi || !grad_year) {
            return res.status(400).json({ error: 'Missing required fields' });
        }
        
        // 3. Updated the SQL query to insert the email
        const [result] = await db.query(
            'INSERT INTO STUDENT (roll_no, name, email, branch, cpi, grad_year) VALUES (?, ?, ?, ?, ?, ?)',
            [roll_no, name, email, branch, cpi, grad_year]
        );
        res.status(201).json({ message: 'Student added successfully', student_id: result.insertId });
    } catch (err) {
        if (err.code === 'ER_DUP_ENTRY') {
            return res.status(400).json({ error: 'Roll number or Email already exists' });
        }
        res.status(500).json({ error: err.message });
    }
});

// GET shortlist for a role (uses VIEW shortlist_view)
router.get('/shortlist/:role_id', async (req, res) => {
    try {
        const [rows] = await db.query(
            'SELECT * FROM shortlist_view WHERE role_id = ? ORDER BY cpi DESC',
            [req.params.role_id]
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// DELETE a student
router.delete('/:student_id', async (req, res) => {
    try {
        // Get accepted offers before deletion
        const [acceptedOffers] = await db.query(
            'SELECT role_id FROM OFFER WHERE student_id = ? AND acceptance_status = ?',
            [req.params.student_id, 'accepted']
        );

        await db.query('DELETE FROM STUDENT WHERE student_id = ?', [req.params.student_id]);

        for (const offer of acceptedOffers) {
            // Reopen the role
            await db.query(
                'UPDATE JOB_ROLE SET is_open = TRUE WHERE role_id = ?',
                [offer.role_id]
            );
            // Restore other students' rejected applications back to applied
            await db.query(
                `UPDATE APPLICATION SET status = 'applied' 
                 WHERE role_id = ? AND status = 'rejected'`,
                [offer.role_id]
            );
        }

        res.json({ message: 'Student deleted, roles reopened, affected applications restored' });
    } catch(err) {
        res.status(500).json({ error: err.message });
    }
});

export default router;
