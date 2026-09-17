# Guesthouse Manager

Android employee app for One Minute guesthouse operations.

## Version 0.2

- One-time Firebase device setup for FCM and emergency features
- Staff launch directly into the Supabase PIN login web app
- Successful staff PIN login records the server clock-in time
- Owner/staff role lookup from Firestore
- Supabase-backed attendance report embedded in the app
- Staff-to-owner emergency report
- Repeating alarm/vibration until acknowledgement
- Mission placeholder

The Firebase function must be deployed separately with `firebase deploy --only functions`.
GitHub Actions also requires the repository secret `GOOGLE_SERVICES_JSON`; use
the complete Android configuration downloaded from the Firebase console.
