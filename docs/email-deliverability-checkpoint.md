# Guest reply email investigation — paused 2026-10-01

Resume only when the user requests it. Keep the current production guest-email worker, secure chat links, templates and sending configuration unchanged during the UI work.

- Resend Tokyo sending domain omgworks24.com is verified; open/click tracking is disabled.
- DMARC TXT is `v=DMARC1; p=none;`. Actual Gmail headers now report SPF, DKIM and DMARC pass.
- Gmail still placed the current guest reply notification in Spam.
- Two controlled notifications to the same authorized test mailbox, same sender/subject/template, differed only by inclusion of the existing secure chat link. Both landed in Spam. Outbound servers differed within the same SES region/pool.
- An additional minimal plain-text notification, without HTML, links or custom notification headers, also landed in Spam. Therefore removing the chat link or HTML alone has not resolved the issue. The precise Gmail classifier cause is unknown.
- Prior initial simple SMTP connectivity mail landed in Inbox in a different authorized mailbox; that does not isolate a template effect because the recipient differed.
- At the initial diagnostic snapshot: six messages delivered, no reported bounces, complaints, failures or delays. Delivered includes mail accepted into Spam.
- Google Safe Browsing reported no unsafe content for the domain (its result was last updated September 25). Spamhaus lookup was blocked by a Cloudflare browser verification loop; no clean/listed conclusion was obtained.

Next: controlled comparison in another user-authorized mailbox; provider investigation of sender domain/SES pool reputation using sending IDs and sanitized authentication headers. Avoid claiming an identified cause or guaranteed fix, removing the guest reply link from production, or treating a single account's Not Spam action as proof of general deliverability.
