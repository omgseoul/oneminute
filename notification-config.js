// Switch only after the new endpoint and FCM credentials pass the deployment checks.
// Keeping the legacy provider during preparation avoids interrupting live alarms.
window.OMG_NOTIFICATIONS = Object.freeze({
  provider: "firebase",
  supabaseUrl: "https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification",
  firebaseUrl: "https://asia-northeast3-guesthouse-manager-ajh.cloudfunctions.net/appUrgent"
});
