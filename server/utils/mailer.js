import { Resend } from 'resend';
import dotenv from 'dotenv';
dotenv.config();

const resend = new Resend(process.env.RESEND_API_KEY);

export const sendMail = async ({ to, subject, text }) => {
    try {
        await resend.emails.send({
            from: 'Placement Portal <onboarding@resend.dev>',
            to,
            subject,
            text
        });
        return true;
    } catch (error) {
        console.error('❌ Email Error:', error);
        return false;
    }
};
