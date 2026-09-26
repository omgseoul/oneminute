import { createNotificationHandler } from './handler.mjs';
Deno.serve(createNotificationHandler({ env: (name: string) => Deno.env.get(name) }));
