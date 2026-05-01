import express from 'express';
import db from '../db/connection.js';
import { sendOTP, verifyOTP } from '../utils/otpService.js';

const router = express.Router();

// 1. Send OTP
router.post('/send-otp', async (req, res) => {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'Email is required' });

    try {
        const [student] = await db.query('SELECT * FROM STUDENT WHERE email = ?', [email]);
        if (student.length === 0) {
            return res.status(404).json({ error: 'No student found with this email.' });
        }

        const otpSent = await sendOTP(email);
        if (!otpSent) return res.status(500).json({ error: 'Failed to send OTP email. Check Gmail App Password.' });

        console.log(`📩 OTP successfully sent to ${email}`);
        res.status(200).json({ message: 'OTP sent successfully to ' + email });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// 2. Verify OTP & Login
router.post('/verify-otp', async (req, res) => {
    const { email, otp } = req.body;
    if (!email || !otp) return res.status(400).json({ error: 'Email and OTP are required' });

    try {
        const isValid = verifyOTP(email, otp);
        if (!isValid) return res.status(400).json({ error: 'Invalid or expired OTP' });

        const [student] = await db.query('SELECT student_id, roll_no, name, branch, cpi, email FROM STUDENT WHERE email = ?', [email]);
        
        console.log(`🔐 System Auth: ${student[0].name} logged in successfully via OTP.`);
        res.status(200).json({ message: 'Login successful', user: student[0] });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

export default router;
