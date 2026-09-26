// Supabase dispatch enabled after the send-only FCM connection passed validation.
// Keep the legacy endpoint available for an explicit rollback; never auto-send twice.
window.OMG_NOTIFICATIONS = Object.freeze({
  provider: "supabase",
  supabaseUrl: "https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification",
  firebaseUrl: "https://asia-northeast3-guesthouse-manager-ajh.cloudfunctions.net/appUrgent"
});
