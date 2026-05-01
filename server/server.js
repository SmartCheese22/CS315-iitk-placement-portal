import express from 'express';
import dotenv from 'dotenv';
import cors from 'cors';
import db from './db/connection.js';

import student     from './routes/student.js';
import company     from './routes/company.js';
import application from './routes/application.js';
import interview   from './routes/interview.js';
import offer       from './routes/offer.js';
import auth        from './routes/auth.js'

dotenv.config();

const app  = express();
const PORT = process.env.PORT || 5000;

app.use(cors());
app.use(express.json());

// Health check
app.get('/', (req, res) => res.json({ message: 'Placement Portal API running' }));

// Routes
app.use('/student',     student);
app.use('/company',     company);
app.use('/application', application);
app.use('/interview',   interview);
app.use('/offer',       offer);
app.use('/auth', auth)

// Test DB then start
db.getConnection()
    .then(conn => {
        console.log(' MySQL connected — placement_portal');
        conn.release();
        app.listen(PORT, () => {
            console.log(` Server running at http://localhost:${PORT}`);
        });
    })
    .catch(err => {
        console.error(' DB connection failed:', err.message);
        process.exit(1);
    });
